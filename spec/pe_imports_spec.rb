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

require "spec_helper"
require "pe_fixture"
require "tmpdir"

RSpec.describe TebakoPythonBuilder::PeImports do
  around do |example|
    Dir.mktmpdir("tebako-pe-imports") do |dir|
      @dir = dir
      example.run
    end
  end

  def fixture(name, **options)
    PeFixture.dll(@dir, name, **options)
  end

  it "reads the static import table of a PE32+ module" do
    path = fixture("libpython3.14.dll", imports: %w[KERNEL32.dll libintl-8.dll ADVAPI32.dll])
    expect(described_class.imports(path)).to eq(%w[KERNEL32.dll libintl-8.dll ADVAPI32.dll])
  end

  it "reads the static import table of a PE32 module" do
    path = fixture("legacy.dll", imports: %w[kernel32.dll libiconv-2.dll], pe32_plus: false)
    expect(described_class.imports(path)).to eq(%w[kernel32.dll libiconv-2.dll])
  end

  it "walks the delay-import table too (a delayed name is still a dependency)" do
    path = fixture("a.dll", imports: %w[kernel32.dll], delay_imports: %w[libzstd.dll])
    expect(described_class.imports(path)).to eq(%w[kernel32.dll libzstd.dll])
  end

  it "classifies the Windows system vocabulary (case-insensitive, API sets included)" do
    expect(described_class.system?("KERNEL32.dll")).to be true
    expect(described_class.system?("PSAPI.DLL")).to be true
    expect(described_class.system?("api-ms-win-crt-heap-l1-1-0.dll")).to be true
    expect(described_class.system?("ext-ms-win-ntuser-window-l1-1-0.dll")).to be true
    expect(described_class.system?("libintl-8.dll")).to be false
    expect(described_class.system?("libpython3.14.dll")).to be false
  end

  it "walks the recursive closure and resolves members in search order" do
    first = File.join(@dir, "one")
    second = File.join(@dir, "two")
    PeFixture.dll(first, "libintl-8.dll", imports: %w[kernel32.dll libiconv-2.dll])
    PeFixture.dll(second, "libiconv-2.dll", imports: %w[kernel32.dll])
    root = fixture("python.dll", imports: %w[kernel32.dll libintl-8.dll])

    closure = described_class.closure([root], search_dirs: [first, second])
    expect(closure[:missing]).to be_empty
    expect(closure[:resolved].map { |entry| entry["name"] }).to eq(%w[libintl-8.dll libiconv-2.dll])
    expect(File.basename(closure[:resolved].last["source"])).to eq("libiconv-2.dll")
  end

  it "treats provided names as satisfied (the co-located runtime pair)" do
    dll = fixture("libpython3.14.dll", imports: %w[kernel32.dll libintl-8.dll])
    exe = fixture("python.exe", imports: %w[kernel32.dll libpython3.14.dll])

    closure = described_class.closure([exe, dll], search_dirs: [], provided: %w[libpython3.14.dll])
    expect(closure[:missing]).to eq([{ "importer" => dll, "name" => "libintl-8.dll" }])
  end

  it "reports an unresolved member with its importer (never a silent skip)" do
    root = fixture("_decimal.pyd", imports: %w[libpython3.14.dll libmpdec-4.dll])
    closure = described_class.closure([root], search_dirs: [@dir], provided: %w[libpython3.14.dll])
    expect(closure[:resolved]).to be_empty
    expect(closure[:missing]).to eq([{ "importer" => root, "name" => "libmpdec-4.dll" }])
  end

  it "refuses a file that is not a readable PE image (a named 131, never an empty import list)" do
    path = File.join(@dir, "not-a-pe.dll")
    File.write(path, "MZ but truncated")
    expect { described_class.imports(path) }.to raise_error(TebakoPythonBuilder::Error) do |error|
      expect(error.error_code).to eq(131)
      expect(error.message).to include("not a readable PE image")
    end
  end
end
