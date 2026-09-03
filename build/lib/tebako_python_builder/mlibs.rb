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

module TebakoPythonBuilder
  # The tebako link line for the CPython exe link (the BUILDPYTHON recipe's
  # appended $(TEBAKO_LIBS)) plus the MODLIBS rewrites that force the
  # static extension set's deps (openssl, zlib) to STATIC archives. The
  # tebako-runtime-ruby Mlibs port, reduced to python's dependency set
  # (the disabled-extension list in PythonBuild is why the ruby factory's
  # readline/ncurses/gdbm/ffi/yaml tail has no analog here).
  #
  # Two mechanisms, one goal (the exe is self-contained past libc/libm):
  #
  #   * tebako_libs — the scoped Rust staticlibs + the native closure.
  #     ELF legs wrap the set in -Wl,--start-group/--end-group (the
  #     dwarfs/codec archives have circular member-level references) and
  #     drop the closure members the platform's own static archives cover
  #     by BASENAME (two copies of one library in one link is a
  #     duplicate-definition failure whenever both get pulled — the ruby
  #     factory's gnu libjemalloc lesson). darwin links the full set by
  #     full path under ld_classic (Apple ld implements neither
  #     -l:<file> nor --start-group; ld_classic resolves the cargo-bundled
  #     vague-linkage duplicates by the ODR rule — the ruby factory's
  #     Xcode 15 lesson).
  #
  #   * modlib_rewrites — the generated Makefile's MODULE_*_LDFLAGS lines
  #     (configure's @MODULE_BLOCK@) rewritten to absolute .a paths, so the
  #     static _ssl/_hashlib/zlib/binascii modules never bind a shared
  #     libssl/libcrypto/libz. The same archives repeat at the END of
  #     tebako_libs: the closure's librnp/dwarfs reference openssl/zlib
  #     symbols too, and a single-pass GNU ld resolves those only from an
  #     archive scanned after the group.
  class Mlibs
    # The windows system library tail (msys): the ruby factory's
    # MSYS_DLL_LIBRARIES — Rust std's windows references the mingw-ld
    # probe proved (RtlNtStatusToDosError -> ntdll,
    # GetUserProfileDirectoryW -> userenv, GetProcessMemoryInfo -> psapi)
    # plus the win32 default set; the C++ runtime statically.
    MSYS_SYSTEM_LIBRARIES = [
      "-l:libstdc++.a", "-static-libgcc", "-static-libstdc++", "-l:libwinpthread.a",
      "-lshell32", "-lws2_32", "-lwsock32", "-liphlpapi",
      "-limagehlp", "-lshlwapi", "-lbcrypt", "-lcrypt32",
      "-ladvapi32", "-luser32", "-lole32", "-loleaut32",
      "-luuid", "-lpsapi", "-lntdll", "-luserenv"
    ].freeze

    def initialize(platform:, link_unit:, link_unit_dir:)
      @platform = platform
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
    end

    # The $(TEBAKO_LIBS) value substituted into Makefile.pre.
    def tebako_libs
      if @platform.msys?
        msys_libs
      elsif @platform.macos?
        darwin_libs
      else
        elf_libs
      end
    end

    # The generated-Makefile variable rewrites forcing the static
    # extensions' deps to absolute archive paths.
    def modlib_rewrites
      {
        "MODULE__SSL_LDFLAGS" => "#{static_lib("ssl")} #{static_lib("crypto")}",
        "MODULE__HASHLIB_LDFLAGS" => static_lib("crypto"),
        "MODULE_ZLIB_LDFLAGS" => static_lib("z"),
        "MODULE_BINASCII_LDFLAGS" => static_lib("z")
      }
    end

    # The static archive path for one of the exe's own extension deps
    # (ssl/crypto/z). macOS resolves from the Homebrew keg (the toolchain
    # default search never sees a keg-only formula); every other leg asks
    # the C toolchain's own search path (`cc -print-file-name`), so the
    # archive the exe binds is the one the platform's compiler would have
    # chosen. An unresolved archive is a named build error, never a silent
    # dynamic bind.
    def static_lib(name)
      if @platform.macos?
        package = name == "z" ? "zlib" : "openssl@3"
        path = File.join(@platform.brew_prefix(package), "lib", "lib#{name}.a")
      else
        out = TebakoPythonBuilder::BuildHelpers.run_with_capture(["cc", "-print-file-name=lib#{name}.a"]).strip
        path = out
      end
      return path if File.file?(path)

      raise TebakoPythonBuilder::Error.new(
        "no static lib#{name}.a resolvable on this platform (#{path}) — the exe must bind " \
        "openssl/zlib statically (a runtime .so dependency breaks the audience rule)", 112
      )
    end

    private

    # The closure archives the platform's own static set already covers,
    # by basename (the mlibs.rb linux_covered/pacman_covered port). The
    # closure's copies are the scoped/arscope set; the platform's are what
    # the extensions' headers matched — one copy per link.
    def covered_basenames
      covered = %w[libssl.a libcrypto.a libz.a]
      covered += %w[libzlib.a liblzma.a] if @platform.msys?
      covered
    end

    def uncovered_libraries
      covered = covered_basenames
      @link_unit.libraries(@link_unit_dir).reject do |path|
        covered.include?(File.basename(path))
      end
    end

    # ELF legs: the group around the tebako set, then the C++ runtime,
    # then the platform static archives AGAIN (the group's librnp/dwarfs
    # references resolve only from an archive scanned after the group),
    # then the libc-family tail statically where ruby proved it safe
    # (rt/util), the rest dynamically (always present on a glibc/musl
    # host).
    def elf_libs
      tail = %w[-static-libgcc -l:libstdc++.a -lgcc_eh]
      tail += [static_lib("ssl"), static_lib("crypto"), static_lib("z")]
      tail += @platform.musl? ? %w[-ldl -lpthread] : %w[-l:librt.a -l:libutil.a -ldl -lpthread]
      (["-Wl,--start-group"] + uncovered_libraries + ["-Wl,--end-group"] + tail).join(" ")
    end

    # darwin: full paths under ld_classic (the class comment); the closure
    # rides complete (no -l: search exists and ld_classic resolves the
    # duplicates first-wins), the brew archives follow.
    def darwin_libs
      libs = @link_unit.libraries(@link_unit_dir)
      (["-Wl,-ld_classic"] + libs +
       [static_lib("ssl"), static_lib("crypto"), static_lib("z")] +
       %w[-lc++ -lc++abi]).join(" ")
    end

    # msys: the group minus the pacman-covered set, the static C++
    # runtime, the platform archives, the windows system tail.
    def msys_libs
      (["-Wl,--start-group"] + uncovered_libraries + ["-Wl,--end-group"] +
       [static_lib("ssl"), static_lib("crypto"), static_lib("z")] +
       MSYS_SYSTEM_LIBRARIES).join(" ")
    end
  end
end
