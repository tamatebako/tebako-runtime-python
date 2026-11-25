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
# ``AS IS'' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT
# NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
# FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
# OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
# TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
# USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require "spec_helper"
require "fileutils"
require "tmpdir"

# PythonBuild#dispatch_tail_dup_env / #dispatch_tail_dup_append — the
# gh-158283 workaround's enablement probe and per-line delivery (the
# class comment owns the mechanism): a compiler in the affected window
# (LLVM 19 / Apple clang 1700.x) compiles the identity-macro probe and
# ceval builds with -mllvm -tail-dup-pred-size=1000; any other compiler
# trips the probe's #error and the workaround stays off, so GCC legs
# never see a clang-only option and the workaround self-retires when the
# fleet's toolchain leaves the window. The delivery is per-line: 3.14+
# rides the CFLAGS_CEVAL env (Makefile.pre's ceval-only knob); pre-3.14
# has no such variable, so the env stays empty and substitute_makefiles
# appends a target-specific CFLAGS_NODIST binding for Python/ceval.o.
# The probe text mirrors CPython's merged configure test (gh-158286)
# verbatim.
RSpec.describe TebakoPythonBuilder::PythonBuild do
  def build_for(platform, prefix, python_version: "3.14.7")
    described_class.new(platform: platform, python_version: python_version,
                        prefix: prefix, tarball: "unused.tar.gz", src_sha256: "0" * 64,
                        link_unit: nil, link_unit_dir: nil, repo_root: REPO_ROOT)
  end

  def fake_cc(dir, exit_status)
    path = File.join(dir, "cc")
    File.write(path, "#!/bin/sh\nexit #{exit_status}\n")
    FileUtils.chmod(0o755, path)
    path
  end

  around do |example|
    saved = ENV.fetch("CC", nil)
    example.run
  ensure
    saved.nil? ? ENV.delete("CC") : ENV["CC"] = saved
  end

  it "mirrors gh-158286's compiler windows verbatim in the probe" do
    probe = described_class::DISPATCH_TAIL_DUP_PROBE
    expect(probe).to include("__apple_build_version__ < 17000000 || __apple_build_version__ >= 18000000")
    expect(probe).to include("!defined(__clang__) || __clang_major__ != 19")
  end

  it "arms CFLAGS_CEVAL when the macOS build compiler compiles the probe" do
    Dir.mktmpdir("dispatch-tail-dup-spec") do |dir|
      ENV["CC"] = fake_cc(dir, 0)
      build = build_for(TebakoPythonBuilder::Platform.new("arm64-darwin23"), File.join(dir, "build"))
      expect(build.dispatch_tail_dup_env)
        .to eq({ "CFLAGS_CEVAL" => "-mllvm -tail-dup-pred-size=1000" })
      expect(build.dispatch_tail_dup_append).to be_nil
    end
  end

  it "arms the target-specific Makefile append (never the env) on pre-3.14 lines" do
    Dir.mktmpdir("dispatch-tail-dup-spec") do |dir|
      ENV["CC"] = fake_cc(dir, 0)
      build = build_for(TebakoPythonBuilder::Platform.new("arm64-darwin23"), File.join(dir, "build"),
                        python_version: "3.13.15")
      expect(build.dispatch_tail_dup_env).to eq({})
      expect(build.dispatch_tail_dup_append)
        .to eq("Python/ceval.o: CFLAGS_NODIST += -mllvm -tail-dup-pred-size=1000")
    end
  end

  it "stays empty when the macOS build compiler trips the probe's #error" do
    Dir.mktmpdir("dispatch-tail-dup-spec") do |dir|
      ENV["CC"] = fake_cc(dir, 1)
      build = build_for(TebakoPythonBuilder::Platform.new("arm64-darwin23"), File.join(dir, "build"))
      expect(build.dispatch_tail_dup_env).to eq({})
      expect(build.dispatch_tail_dup_append).to be_nil
      expect(File.exist?(File.join(dir, "build", "dispatch_tail_dup_probe.c"))).to be(false)
    end
  end

  it "never probes off-macOS (a GCC leg must not see the clang-only flag)" do
    Dir.mktmpdir("dispatch-tail-dup-spec") do |dir|
      ENV["CC"] = fake_cc(dir, 0)
      build = build_for(TebakoPythonBuilder::Platform.new("x86_64-pc-linux-gnu"), File.join(dir, "build"))
      expect(build.dispatch_tail_dup_env).to eq({})
      expect(build.dispatch_tail_dup_append).to be_nil
      expect(build.dispatch_tail_dup_probed?).to be(false)
    end
  end
end
