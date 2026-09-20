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
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require "spec_helper"

RSpec.describe TebakoPythonBuilder::Platform do
  describe ".host_id_for" do
    it "names the package platform id for every matrix.json row" do
      expectations = {
        %w[linux-gnu x86_64] => "linux-gnu-x86_64",
        %w[linux-gnu arm64] => "linux-gnu-arm64",
        %w[linux-musl x86_64] => "linux-musl-x86_64",
        %w[linux-musl arm64] => "linux-musl-arm64",
        %w[macos x86_64] => "macos-x86_64",
        %w[macos arm64] => "macos-arm64",
        %w[windows x86_64] => "windows-ucrt64",
        %w[windows arm64] => "windows-ucrt-arm64"
      }
      expectations.each do |(os, arch), host_id|
        expect(described_class.host_id_for(os, arch)).to eq(host_id)
      end
    end

    it "fails named (112) outside the vocabulary" do
      expect { described_class.host_id_for("sunos", "sparc") }
        .to raise_error(TebakoPythonBuilder::Error) { |e| expect(e.error_code).to eq(112) }
    end
  end

  describe ".link_unit_pid_for" do
    it "maps the windows legs to the product's link-unit platform ids" do
      expect(described_class.link_unit_pid_for("windows", "x86_64")).to eq("x86_64-windows-gnu")
      expect(described_class.link_unit_pid_for("windows", "arm64")).to eq("aarch64-windows-gnu")
    end
  end

  describe "#tpkg_triplet" do
    it "spells the reserved aarch64-windows-ucrt triplet for the arm64 windows host" do
      arm64_windows = described_class.new("aarch64-w64-mingw32", "aarch64")
      expect(arm64_windows.host_id).to eq("windows-ucrt-arm64")
      expect(arm64_windows.tpkg_triplet).to eq("aarch64-windows-ucrt")
    end
  end

  describe "#msys_env" do
    it "names ucrt64 on the x86_64 mingw host and clangarm64 on the arm64 one" do
      expect(described_class.new("x86_64-w64-mingw32", "x86_64").msys_env).to eq("ucrt64")
      expect(described_class.new("aarch64-w64-mingw32", "aarch64").msys_env).to eq("clangarm64")
    end

    it "follows the declared arch over the emulated tooling's self-report (windows-11-arm)" do
      # The msys tooling ruby on a windows-11-arm runner is the emulated
      # x64 build: RUBY_PLATFORM/host_cpu say x86_64. The leg's declared
      # arch (build_runtime --arch) must still key the arm64 environment,
      # link-unit pid, and package name.
      emulated = described_class.new("x64-mingw-ucrt", "arm64")
      expect(emulated.msys_env).to eq("clangarm64")
      expect(emulated.host_id).to eq("windows-ucrt-arm64")
      expect(emulated.link_unit_pid).to eq("aarch64-windows-gnu")
    end

    it "fails named (112) on a POSIX host" do
      expect { described_class.new("x86_64-pc-linux-gnu", "x86_64").msys_env }
        .to raise_error(TebakoPythonBuilder::Error) { |e| expect(e.error_code).to eq(112) }
    end
  end
end
