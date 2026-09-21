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
  # static extension set's deps (openssl, zlib) — and the msys _ctypes
  # build's libffi — to STATIC archives. The tebako-runtime-ruby Mlibs
  # port, reduced to python's dependency set (the disabled-extension list
  # in PythonBuild is why the ruby factory's readline/ncurses/gdbm/yaml
  # tail has no analog here).
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
    # plus the win32 default set. The C++ runtime heads the tail via
    # msys_cxx_runtime (the set differs per msys2 environment).
    MSYS_SYSTEM_LIBRARIES = [
      "-static-libgcc", "-l:libwinpthread.a",
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
      rewrites = {
        "MODULE__SSL_LDFLAGS" => "#{static_lib("ssl")} #{static_lib("crypto")}",
        "MODULE__HASHLIB_LDFLAGS" => static_lib("crypto"),
        "MODULE_ZLIB_LDFLAGS" => static_lib("z"),
        "MODULE_BINASCII_LDFLAGS" => static_lib("z")
      }
      # _ctypes is msys-only (PythonBuild::MSYS_ENABLED_MODULES); its
      # libffi binds statically for the same audience-rule reason — a
      # shared libffi-*.dll would be a runtime dependency a bare windows
      # machine cannot satisfy. The rewrite is gated so POSIX builds (no
      # _ctypes, no libffi in the containers) never resolve the archive.
      # The ole32/oleaut32/uuid tail is configure's win32 CTYPES_LIBS
      # (ctypes' COM utilities) — ever-present system DLLs, kept verbatim.
      if @platform.msys?
        rewrites["MODULE__CTYPES_LDFLAGS"] = "#{static_lib("ffi")} -lole32 -loleaut32 -luuid"
      end
      rewrites
    end

    # The static archive path for one of the extension deps (ssl/crypto/z,
    # ffi on msys). macOS resolves from the Homebrew keg (the toolchain
    # default search never sees a keg-only formula); every other leg asks
    # the C toolchain's own search path (`cc -print-file-name`), so the
    # archive bound is the one the platform's compiler would have chosen.
    # An unresolved archive is a named build error, never a silent dynamic
    # bind.
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
        "no static lib#{name}.a resolvable on this platform (#{path}) — the runtime must bind " \
        "its extension deps statically (a runtime .so/.dll dependency breaks the audience rule)", 112
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
    # Security.framework: the v2.8.4+ unit's driver embeds the trust
    # bridge's OS-store enumeration (rustls-native-certs →
    # security-framework objects) — its kSec*/_Sec*/_CMS*/
    # _Authorization*/_SSL* references resolve only against the system
    # Security framework (the first v2.8.9 leg's link died on the 288-strong
    # undefined set; tebako-runtime-ruby's mlibs.rb carries the same arm).
    def darwin_libs
      libs = @link_unit.libraries(@link_unit_dir)
      (["-Wl,-ld_classic"] + libs +
       [static_lib("ssl"), static_lib("crypto"), static_lib("z")] +
       %w[-framework Security -lc++ -lc++abi]).join(" ")
    end

    # msys: the group minus the pacman-covered set, the static C++
    # runtime, the platform archives, the windows system tail.
    def msys_libs
      (["-Wl,--start-group"] + uncovered_libraries + ["-Wl,--end-group"] +
       [static_lib("ssl"), static_lib("crypto"), static_lib("z")] +
       msys_cxx_runtime + MSYS_SYSTEM_LIBRARIES).join(" ")
    end

    # The C++ runtime, keyed on the msys2 environment (Platform#msys_env):
    # ucrt64 is a gcc toolchain (libstdc++.a + the -static-libstdc++ driver
    # flag); clangarm64 (windows/arm64) is the llvm toolchain — libc++.a +
    # libc++abi.a + libunwind.a, and no libstdc++.a at all (a hardcoded
    # -l:libstdc++.a there dies at the python.exe link with lld's "unable
    # to find library" — run 35530044014). -static-libgcc stays in the
    # shared tail: clang maps it to the compiler-rt builtins.
    def msys_cxx_runtime
      if @platform.msys_env == "ucrt64"
        ["-l:libstdc++.a", "-static-libstdc++"]
      else
        ["-l:libc++.a", "-l:libc++abi.a", "-l:libunwind.a"]
      end
    end
  end
end
