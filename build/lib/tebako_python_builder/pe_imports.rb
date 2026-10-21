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

module TebakoPythonBuilder
  # The PE import table, read in-process (no objdump/dumpbin shell-out):
  # the windows runtime pair's dependency evidence. The OS loader binds
  # EVERY name in a module's static import table at process start (a
  # missing one is the loader's own "The code execution cannot proceed"
  # + exit 127 — the issue-55 symptom: libpython3.14.dll importing
  # libintl-8.dll, which no release asset and no bare windows machine
  # carries), and delay-loaded names bind on first use. Both tables are
  # walked, because the audience rule cares about ANY host library a
  # boot could need — a delay import is a dependency too.
  #
  # SYSTEM_DLLS is the host-provided vocabulary: the DLLs every Windows
  # installation carries in System32, plus the API-set/extension
  # namespaces (`api-ms-win-*`, `ext-ms-win-*`) the loader resolves
  # through the host's schema. A name outside it is a LIBRARY THE
  # PACKAGE MUST SHIP — the closure walk's whole point. The list is
  # deliberately an allowlist, never a "does it look like a system
  # name" heuristic: an unlisted system DLL fails the build loudly and
  # is one line away from being admitted.
  #
  # The closure walk (`self.closure`) is shared by the image builder
  # (staging the members into the env image's bin/, fail-closed when a
  # member is unresolvable) and by tools/boot_smoke (the read-back from
  # the PACKED image + the shipped pair). Both sides walk the same
  # grammar; neither trusts the other's idea of what was staged.
  #
  # A malformed image is a named error (131 — the image assemble/pack
  # class), never a silent empty import list: a parser that cannot read
  # the pair must fail the build, not certify it.
  class PeImports
    # The Windows-provided DLL basenames (lower case). Sourced from the
    # imports the python pair actually binds (kernel32/user32/advapi32/
    # shell32/ws2_32/psapi/userenv/version/bcrypt/bcryptprimitives/
    # ncrypt/secur32/crypt32/ntdll + the api-ms-win-crt set) plus the
    # classic System32 surface a mingw/CPython link may name.
    SYSTEM_DLLS = %w[
      advapi32.dll bcrypt.dll bcryptprimitives.dll cabinet.dll cfgmgr32.dll
      comctl32.dll comdlg32.dll crypt32.dll dbghelp.dll dnsapi.dll dwmapi.dll
      gdi32.dll gdiplus.dll imagehlp.dll imm32.dll iphlpapi.dll kernel32.dll
      kernelbase.dll mpr.dll msvcrt.dll ncrypt.dll netapi32.dll normaliz.dll
      ntdll.dll ole32.dll oleacc.dll oleaut32.dll powrprof.dll psapi.dll
      rpcrt4.dll secur32.dll setupapi.dll shcore.dll shell32.dll shlwapi.dll
      sspicli.dll ucrtbase.dll urlmon.dll user32.dll userenv.dll uxtheme.dll
      uuid.dll version.dll winhttp.dll wininet.dll winmm.dll winspool.drv
      wintrust.dll ws2_32.dll wsock32.dll
    ].freeze

    # The API-set / extension namespaces the host's loader schema owns.
    API_SET_PREFIXES = %w[api-ms-win- ext-ms-win-].freeze

    def self.imports(path)
      new(path).imports
    end

    # True when Windows itself provides `name` (a bare DLL name; the
    # match is case-insensitive like the loader's own).
    def self.system?(name)
      base = File.basename(name.to_s).downcase
      return true if API_SET_PREFIXES.any? { |prefix| base.start_with?(prefix) }

      SYSTEM_DLLS.include?(base)
    end

    # The recursive non-system import closure of `roots`: every name a
    # root (or a member resolved along the way) imports that neither the
    # host nor `provided` supplies, resolved against `search_dirs` in
    # order. Returns
    #   { resolved: [{ "name" =>, "source" => }], missing: [{ "importer" =>, "name" => }] }
    # with resolved entries in first-import order (name-spelling from
    # the import table, deduped case-insensitively). `provided` names
    # the already-satisfied members — the co-located libpython pair on
    # the staging side, the pair on the read-back side.
    def self.closure(roots, search_dirs: [], provided: [])
      provided_keys = provided.map { |name| File.basename(name.to_s).downcase }
      resolved = {}
      missing = []
      queue = roots.dup
      visited = {}
      until queue.empty?
        path = queue.shift
        key = File.expand_path(path)
        next if visited[key]

        visited[key] = true
        imports(path).each do |name|
          base = File.basename(name)
          lname = base.downcase
          next if system?(base) || provided_keys.include?(lname) || resolved.key?(lname)

          source = search_dirs.map { |dir| File.join(dir, base) }.find { |candidate| File.file?(candidate) }
          unless source
            missing << { "importer" => path, "name" => base }
            next
          end
          resolved[lname] = { "name" => base, "source" => source }
          queue << source
        end
      end
      { resolved: resolved.values, missing: missing }
    end

    def initialize(path)
      @path = path
    end

    def imports
      @imports ||= parse
    end

    private

    def data
      @data ||= File.binread(@path)
    end

    def parse
      if data.bytesize < 0x40 || data.byteslice(0, 2) != "MZ"
        raise malformed("no DOS 'MZ' header")
      end

      pe = u32(0x3c)
      raise malformed("no PE signature at 0x#{pe.to_s(16)}") unless bytes(pe, 4) == "PE\0\0"

      coff = pe + 4
      sections = u16(coff + 2)
      optional_size = u16(coff + 16)
      optional = coff + 20
      magic = u16(optional)
      pe32_plus = case magic
                  when 0x10b then false
                  when 0x20b then true
                  else raise malformed("optional-header magic 0x#{magic.to_s(16)} is neither PE32 nor PE32+")
                  end
      @image_base = pe32_plus ? u64(optional + 24) : u32(optional + 28)
      @sections = (0...sections).map do |index|
        base = optional + optional_size + (index * 40)
        { va: u32(base + 12), vsize: u32(base + 8), raw: u32(base + 20), rawsize: u32(base + 16) }
      end
      @headers_end = optional + optional_size + (sections * 40)
      dir_count = u32(optional + (pe32_plus ? 108 : 92))
      dirs = optional + (pe32_plus ? 112 : 96)

      names = import_names(dirs, dir_count)
      names.concat(delay_import_names(dirs, dir_count))
      names.uniq { |name| name.downcase }
    end

    def import_names(dirs, dir_count)
      rva = directory(dirs, dir_count, 1)
      return [] if rva.zero?

      names = []
      offset = offset_for_rva(rva)
      loop do
        descriptor = bytes(offset, 20)
        break if descriptor == ("\0" * 20)

        name_rva = descriptor.byteslice(12, 4).unpack1("V")
        names << cstring(name_rva) unless name_rva.zero?
        offset += 20
      end
      names
    end

    def delay_import_names(dirs, dir_count)
      rva = directory(dirs, dir_count, 13)
      return [] if rva.zero?

      names = []
      offset = offset_for_rva(rva)
      loop do
        descriptor = bytes(offset, 32)
        break if descriptor == ("\0" * 32)

        attributes = descriptor.byteslice(0, 4).unpack1("V")
        name_field = descriptor.byteslice(4, 4).unpack1("V")
        unless name_field.zero?
          # Attributes bit 0: 1 = the descriptor's fields are RVAs,
          # 0 = virtual addresses (the pre-x64 spelling); normalize.
          names << cstring(attributes & 1 == 1 ? name_field : name_field - @image_base)
        end
        offset += 32
      end
      names
    end

    def directory(dirs, dir_count, index)
      return 0 if index >= dir_count

      u32(dirs + (index * 8))
    end

    def offset_for_rva(rva)
      section = @sections.find do |entry|
        rva >= entry[:va] && rva < entry[:va] + [entry[:vsize], entry[:rawsize]].max
      end
      return section[:raw] + (rva - section[:va]) if section
      return rva if rva < @headers_end

      raise malformed("RVA 0x#{rva.to_s(16)} falls outside every section")
    end

    def cstring(rva)
      offset = offset_for_rva(rva)
      chunk = data.byteslice(offset, 4096)
      raise malformed("truncated import-name string at RVA 0x#{rva.to_s(16)}") if chunk.nil?

      stop = chunk.index("\0")
      raise malformed("unterminated import-name string at RVA 0x#{rva.to_s(16)}") if stop.nil?

      chunk.byteslice(0, stop).force_encoding(Encoding::UTF_8).scrub
    end

    def u16(offset)
      bytes(offset, 2).unpack1("v")
    end

    def u32(offset)
      bytes(offset, 4).unpack1("V")
    end

    def u64(offset)
      bytes(offset, 8).unpack1("Q<")
    end

    def bytes(offset, length)
      chunk = data.byteslice(offset, length)
      unless chunk && chunk.bytesize == length
        raise malformed("truncated image (read #{length} bytes at 0x#{offset.to_s(16)})")
      end

      chunk
    end

    def malformed(detail)
      TebakoPythonBuilder::Error.new("#{@path} is not a readable PE image: #{detail}", 131)
    end
  end
end
