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
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

require "fileutils"

module TebakoPythonBuilder
  # The env image's windows support-DLL set: the members of the IMAGE'S
  # PE import closure (its .pyd extension modules) that neither Windows
  # nor the co-located libpython pair supplies — staged BESIDE the .pyd
  # files in the image's lib/ and declared as the manifest's
  # `library_aliases:`. The placement is the load-bearing part: CPython
  # loads an extension module with
  #   LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR
  # (Python/dynload_win.c, the bpo-36085 hardening), which searches the
  # .pyd's OWN directory and the default dirs but NEVER PATH. The v0.3.2
  # CI run proved the distinction: with the DLLs staged under bin/ and
  # the driver's alias pass PATH-leading them, `import _decimal` still
  # failed with "DLL load failed" — PATH is not consulted. Beside the
  # .pyd, the loader's DLL-load-dir rule binds them directly, with no
  # process-global search-path mutation. The manifest still declares the
  # set (spec 03 §2.5) so the driver materializes it and a consumer can
  # read the image's support inventory; the declaration's path is
  # truthful at /lib/<name>.
  #
  # The reported failure class (issue 55) is _decimal's libmpdec-4.dll
  # (itself importing libgcc_s_seh-1.dll / libwinpthread-1.dll) and
  # _zstd's libzstd.dll: the v0.3.1 image shipped the .pyd files but
  # none of their DLLs, so `import decimal` / `compression.zstd` died on
  # a bare windows machine.
  #
  # The RUNTIME PAIR is a different case and is gated separately
  # (verify_pair_self_contained!): the OS loader resolves the exe's and
  # libpython's own imports BEFORE any driver code runs, so neither the
  # alias pass nor this co-location can help them. The pair must bind
  # its whole non-system closure statically (PythonBuild's gettext LIBS
  # rewrite — libintl/libiconv/libcharset into libpython3.14.dll); a
  # stray dynamic import here is a named build error, never a consumer's
  # exit 127.
  #
  # The set is DISCOVERED, not a fixed list: the walk starts at the
  # pair + every PE file the assembled image holds, resolves each
  # non-system name from the msys toolchain's bin/, recurses into the
  # staged copies, and fails by name when a member is nowhere in the
  # toolchain. ImageManifest declares exactly the staged names, so
  # declared == staged == closure by construction; ImageBuilder re-walks
  # the image's own bytes as the read-back gate.
  #
  # Source prefixes: the invoking shell's MSYSTEM_PREFIX (the msys2
  # environment the leg builds under), then the environment's own root
  # (/ucrt64, /clangarm64). The msys-runtime /usr/bin is deliberately
  # NOT searched: its same-named DLLs are the msys-flavoured builds
  # (msys-2.0.dll dependents) and would poison the mingw closure.
  class SupportDlls
    # The in-image home: the nt layout's lib/ is the extension modules'
    # directory (the platstdlib the .pyd files load from), so a staged
    # member sits beside its importer — the DLL-load-dir rule's answer.
    IN_IMAGE_SUPPORT = "lib"

    # The PE files an assembled image can carry (the nt layout flattens
    # lib-dynload into lib/; a payload-independent runtime image has no
    # exe of its own).
    PE_GLOBS = %w[**/*.pyd **/*.dll **/*.exe].freeze

    def self.toolchain_prefixes(platform)
      environment = platform.msys? ? "/#{platform.msys_env}" : nil
      [ENV.fetch("MSYSTEM_PREFIX", nil), environment].compact.uniq
    end

    # Every PE file in an assembled image tree (the closure's image-side
    # roots). Case-insensitive: the host filesystem may fold the
    # extension, and a miss would silently shrink the closure.
    def self.image_pe_files(tree)
      PE_GLOBS.flat_map { |glob| Dir.glob(File.join(tree, glob), File::FNM_CASEFOLD) }.sort
    end

    def initialize(platform:, runtime_pair:, image_roots: [], prefixes: nil)
      @platform = platform
      @runtime_pair = Array(runtime_pair).compact
      @image_roots = Array(image_roots)
      @prefixes = (prefixes || self.class.toolchain_prefixes(platform)).uniq
    end

    attr_reader :prefixes

    # The pair member already co-located with the executable (the store
    # installs libpython<X.Y>.dll beside the exe; it is not image
    # content and never an alias).
    def pair_name
      File.basename(@runtime_pair.last.to_s)
    end

    # Copy the image's PE import closure into `support_dir`; returns the
    # manifest's `library_aliases:` declarations ({name, path}), sorted
    # by name — the declared set is exactly the staged set.
    def stage(support_dir)
      unless @platform.msys?
        raise TebakoPythonBuilder::Error.new(
          "the support-DLL staging is the windows class-L alias channel; #{@platform.host_id} has no such shape", 112
        )
      end
      unless @runtime_pair.length == 2 && @runtime_pair.all? { |path| File.file?(path) }
        raise TebakoPythonBuilder::Error.new(
          "the runtime pair (#{@runtime_pair.join(", ")}) is incomplete — the PE closure cannot be walked", 131
        )
      end

      verify_pair_self_contained!
      roots = @runtime_pair + @image_roots
      closure = PeImports.closure(roots, search_dirs: search_dirs, provided: [pair_name])
      unless closure[:missing].empty?
        raise TebakoPythonBuilder::Error.new(
          "the env image's PE import closure is not resolvable from the msys toolchain: " \
          "#{describe_missing(closure[:missing])} (searched: #{search_dirs.join(", ")}) — a bare " \
          "windows machine provides none of them, so the module importing them would not load", 131
        )
      end

      FileUtils.mkdir_p(support_dir)
      closure[:resolved].each do |entry|
        FileUtils.cp(entry["source"], File.join(support_dir, entry["name"]))
      end
      verify_staged_closure!(support_dir, roots, closure)

      closure[:resolved].map { |entry| entry["name"] }
             .sort_by(&:downcase)
             .map { |name| { "name" => name, "path" => "/#{IN_IMAGE_SUPPORT}/#{name}" } }
    end

    private

    def search_dirs
      @prefixes.map { |prefix| File.join(prefix, "bin") }
    end

    # The process-start gate (never an alias candidate): the exe and the
    # libpython DLL must import only Windows system DLLs (and each
    # other). Anything else binds before the driver's boot pass exists.
    def verify_pair_self_contained!
      closure = PeImports.closure(@runtime_pair, search_dirs: [], provided: [pair_name])
      return if closure[:missing].empty?

      raise TebakoPythonBuilder::Error.new(
        "the runtime pair still binds #{describe_missing(closure[:missing])} dynamically — the OS loader " \
        "resolves these at PROCESS START, before any driver code (and therefore before the " \
        "library_aliases PATH lead) can run, so the alias channel cannot carry them. Bind the member " \
        "statically into the runtime instead (PythonBuild's gettext LIBS rewrite is the model)", 131
      )
    end

    # Re-walk the STAGED bytes (not the toolchain copies): the image the
    # user receives must close over what the manifest declares, and a
    # copy-time mistake must surface here rather than at a consumer's
    # boot.
    def verify_staged_closure!(support_dir, roots, closure)
      staged = closure[:resolved].map { |entry| File.join(support_dir, entry["name"]) }
      verify = PeImports.closure(roots + staged, search_dirs: [support_dir], provided: [pair_name])
      return if verify[:missing].empty?

      raise TebakoPythonBuilder::Error.new(
        "the staged support-DLL set does not close over the image's PE imports: " \
        "#{describe_missing(verify[:missing])} — the env image's lib/ does not hold every member", 131
      )
    end

    def describe_missing(missing)
      missing.map { |entry| "#{entry["name"]} (imported by #{File.basename(entry["importer"])})" }
             .uniq.join(", ")
    end
  end
end
