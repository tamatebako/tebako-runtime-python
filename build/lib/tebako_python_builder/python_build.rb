# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "fileutils"
require "open3"

module TebakoPythonBuilder
  # The relocatable CPython build (tools/build_runtime phases 3-4): the
  # pristine tarball is extracted, configured, and built IN TREE (the
  # extracted copy is this factory's scratch — never a published input),
  # and the spec-17 driver is linked into the python exe by a
  # build-time substitution on the GENERATED Makefile (the ruby factory's
  # config.status MAINLIBS substitution analog — a generated-build-file
  # edit, never a source patch; tamatebako/python ships zero patches):
  #
  #   * Programs/python.o is replaced by Programs/tebako_python.o (the fs
  #     TU — build/resources/tebako_python_main.c — compiled from the
  #     template with the mount root substituted) in the $(BUILDPYTHON)
  #     rule, and $(TEBAKO_LIBS) is appended to its recipe;
  #   * the MODULE_*_LDFLAGS lines (configure's @MODULE_BLOCK@) are
  #     rewritten to absolute .a paths so the static extension set binds
  #     static openssl/zlib (Mlibs);
  #   * Modules/Setup.local pins the static extension set (_ssl _hashlib
  #     zlib binascii) and the deterministic *disabled* list (the
  #     host-asymmetric extensions: _bz2 _lzma _sqlite3 _ctypes readline
  #     _curses _gdbm _dbm nis _tkinter _uuid — the v1 hermetic core;
  #     everything else configure-detected dynamic rides the image).
  #
  # Makefile.pre is the durable substitution target: makesetup regenerates
  # Makefile FROM Makefile.pre on the first make (the _MODLIBS_ copy), so
  # editing Makefile.pre survives the regen; Makefile itself is edited too
  # when present (the pre-regen window). The marker comment makes a repeat
  # pass a no-op; a re-run of configure regenerates Makefile.pre without
  # the marker and the pass re-applies.
  class PythonBuild # rubocop:disable Metrics/ClassLength
    # Modules/Setup.local: the static extension set (the exe carries them;
    # their deps ride Mlibs' rewrites) and the deterministic disabled set
    # (the class comment). Module lines carry no flags — makesetup
    # substitutes $(MODULE_<name>_CFLAGS)/$(MODULE_<name>_LDFLAGS), which
    # the Makefile rewrite then pins to the static archives.
    STATIC_MODULES = ["_ssl _ssl.c", "_hashlib _hashopenssl.c",
                      "zlib zlibmodule.c", "binascii binascii.c"].freeze
    DISABLED_MODULES = %w[_bz2 _lzma _sqlite3 _ctypes _ctypes_test readline
                          _curses _curses_panel _gdbm _dbm nis _tkinter _uuid].freeze

    MARKER = "# --- tebako: the fs TU + driver link (factory substitution) ---"

    def initialize(platform:, python_version:, prefix:, tarball:, src_sha256:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   link_unit:, link_unit_dir:, repo_root:, jobs: nil)
      @platform = platform
      @python_version = python_version
      @prefix = prefix
      @tarball = tarball
      @src_sha256 = src_sha256
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
      @repo_root = repo_root
      @jobs = jobs
    end

    attr_reader :src_dir, :stage_dir

    def run
      extract
      write_setup_local
      configure
      substitute_makefiles
      write_fs_tu
      make
      install
      self
    end

    # The built interpreter exe in the build tree (the driver-linked one).
    # CPython spells BUILDPYTHON "python$(BUILDEXE)", and BUILDEXE is
    # ".exe" only where configure's CaseSensitiveTestDir probe finds the
    # BUILD DIRECTORY case-insensitive (macOS/Windows checkouts — or a
    # POSIX build on a case-insensitive mount). CI's Linux overlayfs is
    # case-sensitive: the exe is plain "python" there. The generated
    # Makefile is the authority on the spelling.
    def exe_path
      File.join(src_dir, "python#{build_exe_ext}")
    end

    # The runtime's abi facet (the release shard's additive `abi` key):
    # the build's own EXT_SUFFIX stem (e.g. "cpython-313-x86_64-linux-gnu")
    # — exactly the string native-extension wheels pin. Read off the BUILT
    # exe itself (the host is the target: no cross), run bare — dev mode,
    # no image — so getpath resolves the build tree.
    def abi
      @abi ||= begin
        env = { "PYTHONHOME" => nil, "PYTHONPATH" => nil }
        out, st = Open3.capture2e(env, exe_path, "-E", "-c",
                                  "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX') or '')",
                                  chdir: src_dir)
        # The linux containers run LANG=C: capture2e tags the bytes
        # US-ASCII and a UTF-8 punctuation byte from the driver's own
        # stderr diagnostics makes strip raise there (macOS tags UTF-8,
        # which is why only the linux legs saw it). Re-tag, scrub, and
        # keep the EXT_SUFFIX-shaped line — stderr noise never parses.
        text = out.force_encoding(Encoding::UTF_8).scrub
        line = text.lines.map(&:strip).find { |l| l.match?(/\A\.?cpython-\d+[\w.-]*\z/) }
        unless st.exitstatus&.zero? && line
          raise TebakoPythonBuilder::Error.new(
            "the built interpreter did not report its EXT_SUFFIX (#{st}): #{text}", 106
          )
        end
        line.sub(/\A\./, "")
      end
    end

    private

    # The generated Makefile's BUILDEXE — the one authority on how
    # BUILDPYTHON spells the exe on THIS build dir (the exe_path comment).
    def build_exe_ext
      makefile = File.join(src_dir, "Makefile")
      match = File.read(makefile).match(/^BUILDEXE=\s*(\S*)\s*$/)
      return match[1] if match

      raise TebakoPythonBuilder::Error.new(
        "no BUILDEXE in #{makefile} — configure's output is missing (the build did not run?)", 104
      )
    end

    def mlibs
      @mlibs ||= TebakoPythonBuilder::Mlibs.new(platform: @platform, link_unit: @link_unit,
                                                link_unit_dir: @link_unit_dir)
    end

    def ncores
      @jobs || @platform.ncores
    end

    def src_parent
      File.join(@prefix, "src")
    end

    def extract
      @src_dir = File.join(src_parent, "tfs-python-#{@python_version}-src")
      marker = File.join(src_parent, ".#{@python_version}.src-sha256")
      if File.directory?(@src_dir) && File.file?(marker) && File.read(marker).strip == @src_sha256
        puts "-- CPython source #{@python_version} already extracted (sha256 #{@src_sha256})"
        return
      end

      FileUtils.rm_rf(@src_dir, secure: true)
      FileUtils.mkdir_p(src_parent)
      TebakoPythonBuilder::BuildHelpers.run_with_capture(["tar", "-xzf", @tarball, "-C", src_parent])
      unless File.directory?(@src_dir)
        raise TebakoPythonBuilder::Error.new(
          "#{@tarball} did not extract to tfs-python-#{@python_version}-src under #{src_parent}", 103
        )
      end
      File.write(marker, "#{@src_sha256}\n")
    end

    # Modules/Setup.local: makesetup reads it FIRST and a first definition
    # wins, so the *static* entries here override Setup.stdlib's shared
    # ones; the *disabled* section suppresses its modules wherever listed.
    def write_setup_local
      lines = [
        "# Written by tebako-runtime-python (PythonBuild) — the deterministic",
        "# static/disabled extension contract of the v1 hermetic core.",
        "*static*",
        *STATIC_MODULES,
        "*disabled*",
        *DISABLED_MODULES,
        ""
      ]
      File.write(File.join(src_dir, "Modules", "Setup.local"), lines.join("\n"))
    end

    # The relocatable configure: the compiled-in prefix IS the mount root
    # (sysconfig data and the .pyc source paths then spell the runtime VFS
    # path; PYTHONHOME — set by the fs TU from the driver's effective root
    # — is what actually drives getpath at boot, TODO.python/01's probe).
    def configure
      args = ["./configure",
              "--prefix=#{@platform.mount_root}",
              "--disable-shared",
              "--with-openssl=#{openssl_prefix}",
              "--with-openssl-rpath=no"]
      puts "-- Configuring CPython #{@python_version} (#{@platform.host_id})"
      TebakoPythonBuilder::BuildHelpers.run_with_capture(args, env: configure_env, chdir: src_dir)
    rescue TebakoPythonBuilder::Error => e
      raise TebakoPythonBuilder::Error.new("'build_runtime' configure step failed: #{e.message}", 103)
    end

    # macOS: brew's openssl@3 and zlib are keg-only (pkg-config never
    # sees them), so the detection inputs are named explicitly — ZLIB_*
    # are honored env overrides (configure.ac), openssl rides
    # --with-openssl.
    # linux-gnu: the tpkg-builder images export CFLAGS=-pthread, so
    # configure's run-probe reports pthreads "available without options"
    # and no link-side thread flag ever lands in LIBS/LDFLAGS — while the
    # Makefile's link rules use only $(PY_CORE_LDFLAGS) $(LIBS) $(MODLIBS)
    # $(SYSLIBS), and glibc < 2.34 keeps pthread_create/sem_init in
    # libpthread (the _freeze_module link dies there, undefined refs).
    # LDFLAGS=-pthread flows through PY_LDFLAGS into PY_CORE_LDFLAGS, the
    # link side of every rule; the compile side already carries the
    # image's -pthread.
    # Everywhere else the system openssl/zlib are found by the default
    # detection (the containers ship libssl-dev/zlib1g-dev,
    # openssl-dev/zlib-static, pacman openssl).
    def configure_env
      if @platform.macos?
        zlib = @platform.brew_prefix("zlib")
        {
          "ZLIB_CFLAGS" => "-I#{File.join(zlib, "include")}",
          "ZLIB_LIBS" => mlibs.static_lib("z")
        }
      elsif @platform.linux_gnu?
        { "LDFLAGS" => "-pthread" }
      else
        {}
      end
    end

    def openssl_prefix
      if @platform.macos?
        @platform.brew_prefix("openssl@3")
      elsif @platform.msys?
        "/ucrt64"
      else
        "/usr"
      end
    end

    # The build-time substitutions on the generated build files. Every
    # anchor must match Makefile.pre exactly once — a CPython line whose
    # Makefile.pre.in drifted is a named error, never a half-applied edit.
    def substitute_makefiles # rubocop:disable Metrics/MethodLength
      targets = %w[Makefile.pre Makefile].map { |f| File.join(src_dir, f) }.select { |f| File.file?(f) }
      durable = File.join(src_dir, "Makefile.pre")
      if File.read(durable).include?(MARKER)
        puts "   ... Makefile substitutions already applied"
        return
      end

      rewrites = mlibs.modlib_rewrites
      substitutions = [
        [%r{^(\$\(BUILDPYTHON\):\s*)Programs/python\.o( \$\(LINK_PYTHON_DEPS\).*)$},
         "\\1Programs/tebako_python.o\\2"],
        [/^(\t\$\(LINKCC\) \$\(PY_CORE_LDFLAGS\) \$\(LINKFORSHARED\) -o \$@ )Programs\/python\.o( \$\(LINK_PYTHON_OBJS\) \$\(LIBS\) \$\(MODLIBS\) \$\(SYSLIBS\))$/,
         "\\1Programs/tebako_python.o\\2 $(TEBAKO_LIBS)"],
        # libainstall ships the interpreter's main object for embedding:
        # the fs TU rides under the shipped name python.o (the object
        # consumers of LIBPL expect; its content is the driver-linked TU).
        [%r{^(\s*\$\(INSTALL_DATA\) )Programs/python\.o( \$\(DESTDIR\)\$\(LIBPL\)/python\.o;.*)$},
         "\\1Programs/tebako_python.o\\2"]
      ] + rewrites.map { |key, value| [/^#{key}=.*$/, "#{key}=#{value}"] }

      targets.each do |path|
        content = File.read(path)
        substitutions.each { |(pattern, replacement)| content = content.gsub(pattern, replacement) }
        content += "\n#{MARKER}\nTEBAKO_LIBS=\t#{mlibs.tebako_libs}\n" \
                   "Programs/tebako_python.o: Programs/tebako_python.c $(PYTHON_HEADERS)\n" \
                   "\t$(CC) -c $(PY_CORE_CFLAGS) -o $@ $<\n"
        File.write(path, content)
      end

      verify_substitutions(durable)
      puts "   ... Makefile substitutions applied (#{targets.map { |t| File.basename(t) }.join(", ")})"
    end

    def verify_substitutions(durable)
      content = File.read(durable)
      missing = []
      missing << "the $(BUILDPYTHON) rule" unless content.include?("$(BUILDPYTHON):\tPrograms/tebako_python.o")
      missing << "the libainstall python.o line" unless content.include?("$(INSTALL_DATA) Programs/tebako_python.o")
      mlibs.modlib_rewrites.each_key do |key|
        missing << key unless content =~ /^#{key}=\S/
      end
      return if missing.empty?

      raise TebakoPythonBuilder::Error.new(
        "Makefile.pre substitution incomplete (#{missing.join(", ")}) — this CPython's " \
        "Makefile.pre.in/MODULE_BLOCK grammar drifted from the factory's anchors", 103
      )
    end

    # The generated fs TU: the exe's real main() — boots the driver with
    # the baked mount root, exports the contract version, sets PYTHONHOME
    # from the effective root, and re-execs under the preload-shim
    # injection when the image is mounted (README's LINKED-driver section).
    def write_fs_tu
      template = File.read(File.join(@repo_root, "build", "resources", "tebako_python_main.c"))
      rendered = template.gsub("@MOUNT_ROOT@", @platform.mount_root)
      File.write(File.join(src_dir, "Programs", "tebako_python.c"), rendered)
      puts "   ... fs TU: Programs/tebako_python.c (mount root #{@platform.mount_root})"
    end

    def make
      TebakoPythonBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], chdir: src_dir)
    rescue TebakoPythonBuilder::Error => e
      raise TebakoPythonBuilder::Error.new("'build_runtime' build step failed: #{e.message}", 104)
    end

    # Staged install: `make install DESTDIR=<stage>` lands the prefix tree
    # at <stage>/<mount root spelling>. ensurepip rides the install (pip
    # in site-packages — the image's one selected site-package); the
    # compileall pass writes the stdlib .pyc set the read-only image then
    # serves (no .pyc writes at run time).
    def install
      @stage_dir = File.join(@prefix, "stage")
      FileUtils.rm_rf(@stage_dir, secure: true)
      FileUtils.mkdir_p(@stage_dir)
      TebakoPythonBuilder::BuildHelpers.run_with_capture(["make", "install", "DESTDIR=#{stage_dir}"],
                                                         chdir: src_dir)
    rescue TebakoPythonBuilder::Error => e
      raise TebakoPythonBuilder::Error.new("'build_runtime' install step failed: #{e.message}", 105)
    end

    public

    # The staged prefix tree (the image root's content): stage/<root>
    # with the root spelling normalized ("/__tfs__" -> "__tfs__", the
    # windows "A:/t" -> "A/t" — a literal drive-qualified directory name
    # is unportable even as a staging artifact).
    def staged_prefix_tree
      spelling = @platform.mount_root.sub(%r{\A/+}, "").sub(/\A([A-Za-z]):\//, '\1/')
      File.join(stage_dir, spelling).tap do |tree|
        next if File.directory?(tree)

        raise TebakoPythonBuilder::Error.new(
          "the staged install carries no #{spelling} tree under #{stage_dir} " \
          "(prefix #{@platform.mount_root} did not install as expected)", 105
        )
      end
    end
  end
end
