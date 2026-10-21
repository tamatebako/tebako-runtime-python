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

RSpec.describe TebakoPythonBuilder::SupportDlls do
  let(:platform) { TebakoPythonBuilder::Platform.new("x86_64-w64-mingw32", "x86_64") }

  around do |example|
    Dir.mktmpdir("tebako-support-dlls") do |dir|
      @dir = dir
      example.run
    end
  end

  # The runtime pair as the windows build produces it: the exe imports
  # libpython, and the DLL's own imports are the closure under test.
  def pair(dll_imports: %w[kernel32.dll])
    build = File.join(@dir, "build")
    PeFixture.dll(build, "libpython3.14.dll", imports: dll_imports)
    exe = PeFixture.dll(build, "python.exe", imports: %w[kernel32.dll libpython3.14.dll])
    [exe, File.join(build, "libpython3.14.dll")]
  end

  def stager(runtime_pair, image_roots: [], prefix:)
    described_class.new(platform: platform, runtime_pair: runtime_pair,
                        image_roots: image_roots, prefixes: [prefix])
  end

  it "stages the image's recursive non-system closure and declares exactly it" do
    prefix = File.join(@dir, "ucrt64")
    PeFixture.dll(File.join(prefix, "bin"), "libzstd.dll", imports: %w[kernel32.dll])
    PeFixture.dll(File.join(prefix, "bin"), "libmpdec-4.dll", imports: %w[kernel32.dll libgcc_s_seh-1.dll])
    PeFixture.dll(File.join(prefix, "bin"), "libgcc_s_seh-1.dll", imports: %w[kernel32.dll])
    image = File.join(@dir, "image")
    decimal = PeFixture.dll(image, "_decimal.pyd", imports: %w[libpython3.14.dll libmpdec-4.dll])
    zstd = PeFixture.dll(image, "_zstd.pyd", imports: %w[libpython3.14.dll libzstd.dll])

    support = File.join(image, "lib")
    declarations = stager(pair, image_roots: [decimal, zstd], prefix: prefix).stage(support)

    expect(declarations).to eq(
      [{ "name" => "libgcc_s_seh-1.dll", "path" => "/lib/libgcc_s_seh-1.dll" },
       { "name" => "libmpdec-4.dll", "path" => "/lib/libmpdec-4.dll" },
       { "name" => "libzstd.dll", "path" => "/lib/libzstd.dll" }]
    )
    # The staged members sit in the support directory the caller names
    # (the image's lib/, beside the .pyd files in a real assembly).
    expect(Dir.children(support).sort).to eq(%w[libgcc_s_seh-1.dll libmpdec-4.dll libzstd.dll])
  end

  it "fails by name when the pair still binds a dynamic import (the process-start gate)" do
    runtime_pair = pair(dll_imports: %w[kernel32.dll libintl-8.dll])
    prefix = File.join(@dir, "ucrt64")
    PeFixture.dll(File.join(prefix, "bin"), "libintl-8.dll", imports: %w[kernel32.dll])

    expect { stager(runtime_pair, prefix: prefix).stage(File.join(@dir, "lib")) }
      .to raise_error(TebakoPythonBuilder::Error) do |error|
        expect(error.error_code).to eq(131)
        expect(error.message).to include("libintl-8.dll")
        expect(error.message).to include("PROCESS START")
      end
  end

  it "fails by name when an image member is absent from the toolchain" do
    runtime_pair = pair
    image = File.join(@dir, "image")
    root = PeFixture.dll(image, "_decimal.pyd", imports: %w[libpython3.14.dll libmpdec-4.dll])

    expect { stager(runtime_pair, image_roots: [root], prefix: File.join(@dir, "empty")).stage(File.join(@dir, "lib")) }
      .to raise_error(TebakoPythonBuilder::Error) do |error|
        expect(error.error_code).to eq(131)
        expect(error.message).to include("libmpdec-4.dll")
      end
  end

  it "refuses a non-windows platform (the alias channel is a windows contract)" do
    posix = TebakoPythonBuilder::Platform.new("x86_64-pc-linux-gnu", "x86_64")
    expect do
      described_class.new(platform: posix, runtime_pair: pair).stage(File.join(@dir, "lib"))
    end.to raise_error(TebakoPythonBuilder::Error) do |error|
      expect(error.error_code).to eq(112)
    end
  end
end
