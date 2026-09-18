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
  #     host-asymmetric extensions: _bz2 _lzma _sqlite3 readline _curses
  #     _gdbm _dbm nis _tkinter _uuid, plus _ctypes on POSIX — the v1
  #     hermetic core; MSYS_ENABLED_MODULES re-enables _ctypes on
  #     windows-msys, where payloads reach host DLLs through it;
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

    # The windows-msys build re-enables these members of the v1 disabled
    # set: windows payloads reach host DLLs through ctypes, and upstream's
    # unpatched libffi detection builds _ctypes clean against the ucrt64
    # libffi package (the shape msys2's own python ships — no source
    # patch needed). The extension rides the image as a dynamic module
    # with libffi STATICALLY bound (Mlibs' MODULE__CTYPES_LDFLAGS rewrite
    # — a shared libffi-*.dll dependency would break the audience rule).
    # POSIX legs keep the v1 hermetic core.
    MSYS_ENABLED_MODULES = %w[_ctypes].freeze

    MARKER = "# --- tebako: the fs TU + driver link (factory substitution) ---"

    def initialize(platform:, python_version:, prefix:, tarball:, src_sha256:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   link_unit:, link_unit_dir:, repo_root:, jobs: nil)
      @platform = platform
      @python_version = python_version
      @python = TebakoPythonBuilder::PythonVersion.new(python_version)
      @prefix = prefix
      @tarball = tarball
      @src_sha256 = src_sha256
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
      @repo_root = repo_root
      @jobs = jobs
      @jit_env = {}
    end

    attr_reader :src_dir, :stage_dir

    def run
      extract
      gate_msys_socket_selectability if @platform.msys?
      gate_jit_toolchain if @python.jit?
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
    # the build's own EXT_SUFFIX stem (e.g. "cpython-313-x86_64-linux-gnu";
    # the windows-msys shared shape spells it "cp314-mingw_x86_64_ucrt_gnu.pyd"
    # — the source series' 0014 SOABI/EXT_SUFFIX port) — exactly the string
    # native-extension wheels pin. Read off the BUILT exe itself (the host
    # is the target: no cross), run bare — dev mode, no image — so getpath
    # resolves the build tree.
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
        line = text.lines.map(&:strip).find { |l| l.match?(/\A\.?(?:cpython-\d+|cp\d+)[\w.-]*\z/) }
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

    # The build tree spelling: flavored lines build in a FLAVOR-QUALIFIED
    # tree (tfs-python-<base>-src-jit). The tarball's top-level directory
    # is flavor-less (tfs-python-<base>-src — the source factory's naming),
    # and the plain line's tree is this factory's scratch build tree, so a
    # jit extract must never unpack onto it: extraction lands in a staging
    # subdir first and is renamed into place (same filesystem). A fresh
    # extraction — never a copy of a possibly-configured plain tree, whose
    # objects would carry the wrong configure flags (make does not track
    # flag changes).
    def tree_name
      "tfs-python-#{@python.base_version}-src#{@python.jit? ? "-#{@python.flavor}" : ""}"
    end

    def extract
      @src_dir = File.join(src_parent, tree_name)
      marker = File.join(src_parent, ".#{tree_name}.src-sha256")
      if File.directory?(@src_dir) && File.file?(marker) && File.read(marker).strip == @src_sha256
        puts "-- CPython source #{@python_version} already extracted (sha256 #{@src_sha256})"
        return
      end

      FileUtils.rm_rf(@src_dir, secure: true)
      FileUtils.mkdir_p(src_parent)
      # A crashed extract's staging leftover is reclaimed FIRST — tar
      # onto a non-empty dir would keep files the tarball no longer
      # carries (debris, not a pristine tree).
      FileUtils.rm_rf(staging_parent, secure: true)
      TebakoPythonBuilder::BuildHelpers.run_with_capture(
        ["tar", "-xzf", @tarball, "-C", staging_parent]
      )
      staged = File.join(staging_parent, "tfs-python-#{@python.base_version}-src")
      unless File.directory?(staged)
        raise TebakoPythonBuilder::Error.new(
          "#{@tarball} did not extract to tfs-python-#{@python.base_version}-src under #{staging_parent}", 103
        )
      end
      FileUtils.mv(staged, @src_dir)
      FileUtils.rm_rf(staging_parent, secure: true)
      File.write(marker, "#{@src_sha256}\n")
    end

    # The msys socket-selectability gate (windows builds only). Upstream
    # guards the "any socket fd can be select()-ed" definition of
    # _PyIsSelectable_fd (Include/internal/pycore_fileutils.h) with
    # _MSC_VER alone; under the ucrt64 gcc the macro falls to its POSIX
    # branch — (unsigned)fd < FD_SETSIZE — and a Winsock SOCKET handle,
    # an opaque kernel value that lands far past FD_SETSIZE in any real
    # process, fails it. socketmodule.c's internal_connect then never
    # enters its wait engine (IS_SELECTABLE is a conjunct of
    # wait_connect) and every positive-timeout connect — pip's vendored
    # urllib3 connect among them — surfaces the stale WSAEWOULDBLOCK
    # (10035) the in-flight connect left behind, instantly. tamatebako/
    # python widened the guard to MS_WINDOWS (the 0040 port,
    # pycore_fileutils_msys); a windows runtime built from a source
    # release predating it is broken by construction, so a pre-fix pin
    # is a named error HERE — never a leg that reds three layers later
    # at the boot smoke's socket-timeout scenario.
    def gate_msys_socket_selectability
      header = File.join(src_dir, "Include", "internal", "pycore_fileutils.h")
      lines = File.readlines(header)
      anchor = lines.index { |line| line.include?("#define _PyIsSelectable_fd(FD) (1)") }
      guard = anchor && lines[0...anchor].reverse.find { |line| line =~ /^#if/ }
      return if guard&.include?("MS_WINDOWS")

      raise TebakoPythonBuilder::Error.new(
        "the pinned source lacks the mingw _PyIsSelectable_fd carve-out — Include/internal/" \
        "pycore_fileutils.h guards the (1) definition with #{guard&.strip || "no #if"} (upstream's " \
        "_MSC_VER-only shape), so under ucrt64 gcc socket-timeout connects on handles >= FD_SETSIZE " \
        "die instantly (WinError 10035, the msys pip connect pathology). Bump contract.yml's " \
        "source_release to the tamatebako/python release carrying the MS_WINDOWS widening " \
        "(the pycore_fileutils_msys patch)", 107
      )
    end

    # The extraction staging dir (sibling of the build trees; extract
    # reclaims it before every unpack and removes it after the rename).
    def staging_parent
      dir = File.join(src_parent, ".extract-staging")
      FileUtils.mkdir_p(dir)
      dir
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
        *(DISABLED_MODULES - (@platform.msys? ? MSYS_ENABLED_MODULES : [])),
        ""
      ]
      File.write(File.join(src_dir, "Modules", "Setup.local"), lines.join("\n"))
    end

    # The relocatable configure: the compiled-in prefix IS the mount root
    # (sysconfig data and the .pyc source paths then spell the runtime VFS
    # path; PYTHONHOME — set by the fs TU from the driver's effective root
    # — is what actually drives getpath at boot).
    # windows-msys builds --enable-shared: on PE a loadable module cannot
    # carry undefined symbols, so every stdlib extension links
    # libpython3.14.dll (the static shape is impossible by construction —
    # issue 40; the ruby factory ships the same way). POSIX stays static
    # (the shipped single-exe shape).
    # A jit line adds --enable-experimental-jit (bare = "yes": the JIT is
    # compiled in AND on by default; PYTHON_JIT=0/1 override at runtime,
    # CPython whatsnew 3.13 — selecting the jit line IS opting into it).
    def configure
      args = ["./configure",
              "--prefix=#{@platform.mount_root}",
              @platform.msys? ? "--enable-shared" : "--disable-shared",
              "--with-openssl=#{openssl_prefix}",
              "--with-openssl-rpath=no"]
      args << "--enable-experimental-jit" if @python.jit?
      puts "-- Configuring CPython #{@python_version} (#{@platform.host_id}#{@python.jit? ? ", JIT on" : ""})"
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
    # windows-msys: static-link the mingw support set INTO the runtime's
    # PE modules — libpython3.14.dll otherwise imports
    # libgcc_s_seh-1.dll + libwinpthread-1.dll, and nothing on a bare
    # windows machine provides them (the audience rule: a user running a
    # package installs no toolchain). LIBS lands in the link TAIL of the
    # exe/DLL rules (after the objects — LDFLAGS sits before them and a
    # static archive there is discarded as unneeded); configure prepends
    # its own finds, so this pair stays last. The ruby factory's proven
    # recipe (its Mlibs::MSYS_DLL_LIBRARIES).
    # ac_cv_func_poll=no: with HAVE_POLL undefined, socketmodule.c's
    # socket-timeout machinery compiles the winsock-select shape the MSVC
    # platform has always shipped (internal_select waits via select();
    # select.poll absent — also the python.org windows shape; the msys
    # select module links -lws2_32 via the source series' 0074). With
    # HAVE_POLL defined — the mingw default, since the generic
    # AC_CHECK_FUNC(poll) probe passes against the CRT's poll() emulation
    # — the wait engine routed through that emulation, and every
    # positive-timeout socket operation died instantly with WinError
    # 10035 in the driver-linked runtime: pip's vendored urllib3 connect
    # (settimeout(15)) storms retries, while blocking-mode urlopen (which
    # never enters the wait engine) reaches pypi.org from the same
    # runtime (the xml2rfc windows leg's pip storm: runs 35326025152 @
    # v0.2.2 / 35334306542 @ v0.2.3). The override is HALF the fix — the
    # other half is gate_msys_socket_selectability's source requirement
    # (the mingw _PyIsSelectable_fd carve-out); tools/socket_probe.py
    # pins the connect modes per build (the boot smoke's socket-timeout
    # scenario, windows legs) and its windows-leg run drove this backend
    # choice: the winsock select() wait is the one proven working there.
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
      elsif @platform.msys?
        { "LIBS" => "-static-libgcc -l:libwinpthread.a",
          "ac_cv_func_poll" => "no" }
      else
        {}
      end.merge(@jit_env)
    end

    # --- the JIT toolchain gate (jit lines only) -------------------------
    #
    # CPython's copy-and-patch JIT compiles its stencils at BUILD time with
    # an exact-major LLVM toolchain (clang + llvm-readobj; llvm-objdump
    # optional) and a host python >= 3.11 running Tools/jit/build.py
    # (Tools/jit/README.md, PEP 744). Build-time ONLY: the stencils are
    # baked into the exe — the shipped runtime gains no runtime system
    # dependency (the tebako invariant). The gate runs before configure so
    # a missing toolchain is a named error (exit 113), never a mid-make
    # surprise, and it PATH-augments the configure/make child env so
    # CPython's own tool discovery (Tools/jit/_llvm.py: unversioned or
    # -N-suffixed tools on PATH, or the homebrew llvm@N prefix) finds what
    # this gate verified.

    # The authoritative LLVM major for this source: read from the
    # extracted tree (Tools/jit/_llvm.py's _LLVM_VERSION — the owner) and
    # asserted against the model's plan-time table (the parity arm — the
    # matrix legs provisioned from that table).
    def gate_jit_toolchain
      llvm_py = File.join(src_dir, "Tools", "jit", "_llvm.py")
      match = File.read(llvm_py).match(/^_LLVM_VERSION = (\d+)$/)
      unless match
        raise TebakoPythonBuilder::Error.new(
          "#{llvm_py} carries no _LLVM_VERSION pin — the jit build cannot verify its toolchain", 113
        )
      end
      major = match[1].to_i
      planned = @python.jit_llvm_major
      if major != planned
        raise TebakoPythonBuilder::Error.new(
          "JIT toolchain drift: #{@python_version}'s Tools/jit/_llvm.py pins LLVM #{major} but " \
          "PythonVersion::JIT_LLVM_MAJORS planned #{planned} — fix the table (the owner is the source)", 113
        )
      end

      clang_dir = resolve_jit_tool("clang", major)
      readobj_dir = resolve_jit_tool("llvm-readobj", major)
      missing = []
      missing << "clang" unless clang_dir
      missing << "llvm-readobj" unless readobj_dir
      unless missing.empty?
        raise TebakoPythonBuilder::Error.new(
          "no LLVM #{major} #{missing.join("/")} resolvable for the #{@python_version} build — " \
          "the jit toolchain is provisioned per leg (CI: ci/provision_jit_toolchain.sh in the container legs, " \
          "brew install llvm@#{major} on macos); it is a build-time-only dependency", 113
        )
      end
      gate_jit_host_python
      @jit_env = { "PATH" => ([clang_dir, readobj_dir].uniq + [ENV.fetch("PATH", "")]).join(File::PATH_SEPARATOR) }
      puts "-- JIT toolchain: LLVM #{major} (clang: #{clang_dir}/clang, llvm-readobj: #{readobj_dir}/llvm-readobj)"
    end

    # The dir carrying `tool` at exactly the required major (nil when
    # nowhere resolvable). Probes, in order: <tool>-<major> on PATH
    # (the apt.llvm.org layout), unversioned <tool> on PATH at the right
    # major, then the platform's versioned tool dirs (homebrew's keg-only
    # llvm@N prefix on macos; debian's /usr/lib/llvm-N/bin and alpine's
    # /usr/lib/llvmN/bin on linux). Version check mirrors CPython's
    # _llvm.py: `version N.` exactly, Apple clang excluded.
    def resolve_jit_tool(tool, major) # rubocop:disable Metrics/MethodLength
      path_dirs = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      candidates = path_dirs.map { |dir| File.join(dir, "#{tool}-#{major}") } +
                   path_dirs.map { |dir| File.join(dir, tool) } +
                   jit_tool_dirs(major).map { |dir| File.join(dir, tool) }
      candidates.uniq.each do |candidate|
        next unless File.file?(candidate) && File.executable?(candidate)
        return File.dirname(candidate) if jit_tool_version_match?(candidate, major)
      end
      nil
    end

    def jit_tool_dirs(major)
      dirs = []
      if @platform.macos?
        begin
          dirs << File.join(@platform.brew_prefix("llvm@#{major}"), "bin")
        rescue TebakoPythonBuilder::Error
          nil # the keg is absent — the gate reports the miss by name
        end
      else
        dirs << "/usr/lib/llvm-#{major}/bin" << "/usr/lib/llvm#{major}/bin"
      end
      dirs
    end

    def jit_tool_version_match?(tool, major)
      out, st = Open3.capture2e(tool, "--version")
      return false unless st.exitstatus&.zero?

      # CPython's own grammar (Tools/jit/_llvm.py): (LLVM|clang) version
      # N.x.y, Apple clang never (its major lineage is not LLVM's).
      out.match?(/(?<!Apple )(?:LLVM|clang) version\s+#{major}\.\d+\.\d+/)
    end

    # PYTHON_FOR_REGEN runs Tools/jit/build.py during make; the jit README
    # floors the host python at 3.11 (the gnu tpkg-builder image is
    # focal-based — its python3, when present at all, is 3.8). The probe
    # mirrors configure's own PYTHON_FOR_REGEN search (newest versioned
    # name first, bare python3 last — a provisioned standalone python3.13
    # NEVER replaces the system python3).
    def gate_jit_host_python
      found = nil
      probed = %w[python3.14 python3.13 python3.12 python3.11 python3]
      probed.each do |name|
        out, st = Open3.capture2e(name, "--version")
        next unless st.exitstatus&.zero?

        match = out.match(/Python (\d+)\.(\d+)/)
        found ||= "#{name} (#{out.strip})"
        return if match && match[1].to_i == 3 && match[2].to_i >= 11
      rescue Errno::ENOENT
        next
      end

      raise TebakoPythonBuilder::Error.new(
        "the #{@python_version} jit build needs a host python >= 3.11 for the stencil regen " \
        "(Tools/jit/build.py via PYTHON_FOR_REGEN); probed #{probed.join(", ")}: " \
        "#{found || "none on PATH"} — CI provisions one per leg (ci/provision_jit_toolchain.sh)", 113
      )
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
        exe_recipe_substitution,
        # libainstall ships the interpreter's main object for embedding:
        # the fs TU rides under the shipped name python.o (the object
        # consumers of LIBPL expect; its content is the driver-linked TU).
        [%r{^(\s*\$\(INSTALL_DATA\) )Programs/python\.o( \$\(DESTDIR\)\$\(LIBPL\)/python\.o;.*)$},
         "\\1Programs/tebako_python.o\\2"],
        # wasm prelude (CPython 3.12/3.13 — 3.14 dropped the wasm rules,
        # so the gsub is a no-op there): WASM_ASSETS_DIR=.$(prefix) spells
        # ".A:/t" on windows, GNU make expands rule prereqs at parse time,
        # and the drive-letter colon then reads `wasm_stdlib: $(WASM_STDLIB)`
        # as a static-pattern rule whose pattern carries no %
        # ("target pattern contains no '%'" — Makefile:1025 on 3.12.14,
        # 1144 on 3.13.15). Off-emscripten the wasm rules are dead weight;
        # "." keeps every expansion colon-free.
        [%r{^WASM_ASSETS_DIR=\.\$\(prefix\)$}, "WASM_ASSETS_DIR=."]
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

    # The exe link recipe substitution, platform-shaped. POSIX keeps
    # upstream's spelling; the windows-msys source series (0039
    # win_resources_pythonw_msys) rewrites the rule to
    # `$(LINKFORSHARED) -municode -o $@ Programs/python.o ...
    # python_exe.o` — the prereq-side regex above still matches (its .*
    # absorbs python_exe.o), the recipe-side must name the msys spelling
    # or the driver link is silently lost (the prereq rewrite alone makes
    # the fs TU compile without ever linking it — verify_substitutions
    # guards the recipe for exactly this reason). The msys substitution
    # STRIPS -municode: the fs TU (build/resources/tebako_python_main.c)
    # defines a plain main — with -municode the mingw CRT demands wmain
    # and the link dies. python_exe.o (the version/icon resource) stays.
    # (Unicode argv reaches the driver through the CRT's narrow
    # conversion, matching the shipped POSIX shape; wide-argv parity is
    # a recorded follow-up.)
    def exe_recipe_substitution
      if @platform.msys?
        [/^(\t\$\(LINKCC\) \$\(PY_CORE_LDFLAGS\) \$\(LINKFORSHARED\)) -municode( -o \$@ )Programs\/python\.o( \$\(LINK_PYTHON_OBJS\) \$\(LIBS\) \$\(MODLIBS\) \$\(SYSLIBS\)) python_exe\.o$/,
         "\\1\\2Programs/tebako_python.o\\3 python_exe.o $(TEBAKO_LIBS)"]
      else
        [/^(\t\$\(LINKCC\) \$\(PY_CORE_LDFLAGS\) \$\(LINKFORSHARED\) -o \$@ )Programs\/python\.o( \$\(LINK_PYTHON_OBJS\) \$\(LIBS\) \$\(MODLIBS\) \$\(SYSLIBS\))$/,
         "\\1Programs/tebako_python.o\\2 $(TEBAKO_LIBS)"]
      end
    end

    def verify_substitutions(durable)
      content = File.read(durable)
      missing = []
      missing << "the $(BUILDPYTHON) rule" unless content.include?("$(BUILDPYTHON):\tPrograms/tebako_python.o")
      missing << "the $(BUILDPYTHON) link recipe" unless content.include?("-o $@ Programs/tebako_python.o")
      missing << "the libainstall python.o line" unless content.include?("$(INSTALL_DATA) Programs/tebako_python.o")
      # The wasm anchor is version-conditional (absent on 3.14+), so the
      # drift guard is inverted: a SURVIVING un-rewritten binding means the
      # anchor drifted (reindented, respelled) under a version that still
      # carries the rules — a named error here, not a parse mystery in CI.
      missing << "the WASM_ASSETS_DIR prefix binding" if content.match?(/^WASM_ASSETS_DIR=\.\$\(prefix\)$/)
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
      # msys: upstream's DLL rule ($(DLLLIBRARY) libpython$(LDVERSION).dll.a
      # as a two-target rule with -Wl,--out-implib=$@) is parallel-unsafe:
      # under -j the two per-target invocations interleave and the
      # import-library write can clobber the DLL (observed locally: the
      # 39 MB libpython3.14.dll replaced by the 1.2 MB import stub —
      # serial make self-heals only because the .dll.a target's expansion
      # runs last). Pre-building the implib target SERIALLY materializes
      # both files with the correct expansion (the recipe writes both), so
      # the parallel make finds the rule up-to-date and never re-runs it.
      if @platform.msys?
        TebakoPythonBuilder::BuildHelpers.run_with_capture(["make", "#{@python.msys_dll_name}.a"], chdir: src_dir)
      end
      TebakoPythonBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], env: @jit_env, chdir: src_dir)
    rescue TebakoPythonBuilder::Error => e
      raise TebakoPythonBuilder::Error.new("'build_runtime' build step failed: #{e.message}", 104)
    end

    # Staged install: `make install DESTDIR=<stage>` lands the prefix tree
    # at <stage>/<mount root spelling>; the compileall pass writes the
    # stdlib .pyc set the read-only image then serves (no .pyc writes at
    # run time). CPython's install rules spell every destination
    # $(DESTDIR)$(dir) with no separator, which composes only because a
    # POSIX prefix starts with a slash. The msys prefix is drive-qualified
    # ("A:/t") and DESTDIR + "A:/t/..." concatenates into one junk
    # component — the tree never lands (the failing recipes are mostly
    # `-`-prefixed, so make exits green over the wreckage) — so the msys
    # install overrides prefix to the POSIX spelling "/A/t": every install
    # dir var derives unexpanded from $(prefix) (autoconf convention), so
    # the override flows through to every rule; recorded .pyc source paths
    # then spell /A/t/... instead of A:/t/..., a traceback cosmetic.
    # ensurepip cannot ride the msys install (ENSUREPIP=no): pip's --root
    # rebase drive-strips the built python's BUILD-TREE prefix, never the
    # staged one, so pip would land under <stage>/<build-tree path> —
    # place_pip stages it explicitly instead.
    def install
      @stage_dir = File.join(@prefix, "stage")
      FileUtils.rm_rf(@stage_dir, secure: true)
      FileUtils.mkdir_p(@stage_dir)
      argv = ["make", "install", "DESTDIR=#{stage_dir}"]
      # "A:/t" -> "/A/t" (the method comment's prefix override).
      argv += ["prefix=/#{@platform.mount_root.delete(':')}", "ENSUREPIP=no"] if @platform.msys?
      TebakoPythonBuilder::BuildHelpers.run_with_capture(argv, chdir: src_dir)
      place_pip if @platform.msys?
    rescue TebakoPythonBuilder::Error => e
      raise TebakoPythonBuilder::Error.new("'build_runtime' install step failed: #{e.message}", 105)
    end

    # msys only — the ensurepip replacement (the install comment): the
    # bundled wheel's own installer run into the staged site-packages,
    # mirroring ensurepip's -c invocation (the wheel prepended to
    # sys.path, pip run as __main__) but with --target deciding the
    # placement — no scheme math, no --root rebase. The build-tree exe
    # runs bare (dev mode — the abi probe's shape), and the paths ride
    # argv rather than the -c payload: the msys runtime translates
    # whole-argument POSIX paths for the native child exe, but a path
    # embedded in the script text crosses verbatim. --no-compile mirrors
    # ensurepip: .pyc records written here would spell the stage paths —
    # dead links in the mounted image — so pip compiles in memory at
    # run time.
    def place_pip
      bundled = Dir.glob(File.join(src_dir, "Lib", "ensurepip", "_bundled", "pip-*-py3-none-any.whl"))
      unless bundled.one?
        raise TebakoPythonBuilder::Error.new(
          "expected exactly one bundled pip wheel under #{src_dir}/Lib/ensurepip/_bundled " \
          "(found #{bundled.size}) — the wheel is the pip source", 105
        )
      end

      target = File.join(staged_prefix_tree, "lib", @python.libdir_name, "site-packages")
      FileUtils.mkdir_p(target)
      snippet = "import runpy, sys; wheel, links, target = sys.argv[1:4]; " \
                "sys.path = [wheel] + sys.path; " \
                "sys.argv = ['pip', 'install', '--no-cache-dir', '--no-index', " \
                "'--find-links', links, '--target', target, '--upgrade', '--no-compile', " \
                "'--disable-pip-version-check', 'pip']; " \
                "runpy.run_module('pip', run_name='__main__', alter_sys=True)"
      TebakoPythonBuilder::BuildHelpers.run_with_capture(
        [exe_path, "-W", "ignore::DeprecationWarning", "-E", "-c", snippet,
         bundled.first, File.dirname(bundled.first), target],
        env: { "PYTHONHOME" => nil, "PYTHONPATH" => nil }, chdir: src_dir
      )
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
