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

# A minimal synthetic PE writer for the specs: just enough of the DOS
# header, COFF header, optional header, one .idata section, and import/
# delay-import descriptor tables for PeImports to read. Keeping the
# fixtures synthetic (a few hundred bytes) keeps the suite hermetic —
# no downloaded DLLs, no dependency on a windows host.
require "fileutils"

module PeFixture
  DOS_STUB = 0x40
  OPTIONAL_SIZE = 0xF0
  SECTION_RVA = 0x1000
  SECTION_RAW = 0x200
  SECTION_SIZE = 0x600
  IMPORT_TABLE = 0x200
  DELAY_TABLE = 0x2A0
  IMPORT_NAMES = 0x300
  DELAY_NAMES = 0x400

  module_function

  def write_pe(path, imports: [], delay_imports: [], pe32_plus: true)
    image = String.new(capacity: SECTION_RAW + SECTION_SIZE, encoding: Encoding::BINARY)
    image << "MZ".b << ("\0" * (DOS_STUB - 2 - 4)) << [DOS_STUB].pack("V")
    image << "PE\0\0".b
    image << [0x8664, 1, 0, 0, 0, OPTIONAL_SIZE, 0x2022].pack("vvVVVvv")
    image << optional_header(imports, delay_imports, pe32_plus)
    image << section_header
    image << ("\0" * (SECTION_RAW - image.bytesize))
    image << section_data(imports, delay_imports)
    File.binwrite(path, image)
    path
  end

  def optional_header(imports, delay_imports, pe32_plus)
    header = ("\0" * OPTIONAL_SIZE).b
    header[0, 2] = [pe32_plus ? 0x20b : 0x10b].pack("v")
    header[24, 8] = [0x140000000].pack("Q<") if pe32_plus
    header[28, 4] = [0x400000].pack("V") unless pe32_plus
    header[56, 4] = [0x2000].pack("V") # SizeOfImage
    header[60, 4] = [SECTION_RAW].pack("V") # SizeOfHeaders
    dirs = pe32_plus ? 112 : 96
    header[(pe32_plus ? 108 : 92), 4] = [16].pack("V")
    header[dirs + 8, 8] = [SECTION_RVA, 0x200].pack("VV") # import directory
    header[dirs + (13 * 8), 8] = [SECTION_RVA + (DELAY_TABLE - SECTION_RAW), 0x40].pack("VV") unless delay_imports.empty?
    header
  end

  def section_header
    [
      ".idata\0\0", # 8 bytes
      0x800, # VirtualSize
      SECTION_RVA,
      SECTION_SIZE, # SizeOfRawData
      SECTION_RAW # PointerToRawData
    ].pack("a8VVVV") + ("\0" * 16)
  end

  def section_data(imports, delay_imports)
    data = ("\0" * SECTION_SIZE).b
    imports.each_with_index do |name, index|
      data[IMPORT_TABLE - SECTION_RAW + (index * 20), 20] =
        [0, 0, 0, SECTION_RVA + (IMPORT_NAMES - SECTION_RAW) + (index * 0x40), 0].pack("VVVVV")
    end
    delay_imports.each_with_index do |name, index|
      data[DELAY_TABLE - SECTION_RAW + (index * 32), 32] =
        [1, SECTION_RVA + (DELAY_NAMES - SECTION_RAW) + (index * 0x40), 0, 0, 0, 0, 0, 0].pack("VVVVVVVV")
    end
    imports.each_with_index do |name, index|
      data[IMPORT_NAMES - SECTION_RAW + (index * 0x40), name.bytesize] = name
    end
    delay_imports.each_with_index do |name, index|
      data[DELAY_NAMES - SECTION_RAW + (index * 0x40), name.bytesize] = name
    end
    data
  end

  # Write a PE at <dir>/<name> (the basename is the only thing that
  # matters for the fixtures' roles).
  def dll(dir, name, imports: [], delay_imports: [], pe32_plus: true)
    FileUtils.mkdir_p(dir)
    write_pe(File.join(dir, name), imports: imports, delay_imports: delay_imports, pe32_plus: pe32_plus)
  end
end
