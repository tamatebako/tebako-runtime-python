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

RSpec.describe TebakoPythonBuilder::Mlibs do
  let(:link_unit) do
    instance_double(TebakoPythonBuilder::LinkUnit,
                    libraries: ["/lu/libtebako_driver.a", "/lu/libtfs.a"])
  end

  # static_lib shells out to `cc -print-file-name` on non-macOS platforms;
  # pin it to a fixed archive path so the msys link line is assertable off
  # windows.
  def msys_mlibs(ostype, arch)
    described_class.new(platform: TebakoPythonBuilder::Platform.new(ostype, arch),
                        link_unit: link_unit, link_unit_dir: "/lu").tap do |mlibs|
      allow(mlibs).to receive(:static_lib) { |name| "/deps/lib/lib#{name}.a" }
    end
  end

  context "on windows/ucrt64 (the gcc toolchain)" do
    subject(:mlibs) { msys_mlibs("x86_64-w64-mingw32", "x86_64") }

    it "links the gcc C++ runtime set (libstdc++)" do
      libs = mlibs.tebako_libs
      expect(libs).to include("-l:libstdc++.a")
      expect(libs).to include("-static-libstdc++")
      expect(libs).to include("-static-libgcc")
      expect(libs).not_to include("-l:libc++.a")
    end
  end

  context "on windows/arm64 (clangarm64, the llvm toolchain)" do
    subject(:mlibs) { msys_mlibs("aarch64-w64-mingw32", "aarch64") }

    it "links the llvm C++ runtime set (libc++/libc++abi/libunwind) — clangarm64 has no libstdc++.a" do
      # Run 35530044014: a hardcoded -l:libstdc++.a died at the python.exe
      # link with lld's "unable to find library".
      libs = mlibs.tebako_libs
      expect(libs).to include("-l:libc++.a")
      expect(libs).to include("-l:libc++abi.a")
      expect(libs).to include("-l:libunwind.a")
      expect(libs).to include("-static-libgcc")
      expect(libs).not_to include("-l:libstdc++.a")
      expect(libs).not_to include("-static-libstdc++")
    end
  end
end
