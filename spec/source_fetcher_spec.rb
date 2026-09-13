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

require "spec_helper"
require "digest"
require "fileutils"
require "tmpdir"

RSpec.describe TebakoPythonBuilder::SourceFetcher do
  let(:msys_platform) { TebakoPythonBuilder::Platform.new("x86_64-w64-mingw32") }
  let(:posix_platform) { TebakoPythonBuilder::Platform.new("x86_64-pc-linux-gnu") }

  # A staged release mirror: SHA256SUMS + the asset bytes it names,
  # served over file:// — no spec touches the network.
  def stage_release(dir, assets)
    FileUtils.mkdir_p(dir)
    sums = assets.map do |name, bytes|
      File.binwrite(File.join(dir, name), bytes)
      "#{Digest::SHA256.hexdigest(bytes)}  #{name}"
    end
    File.write(File.join(dir, "SHA256SUMS"), "#{sums.join("\n")}\n")
  end

  def staged_fetcher(dir, assets)
    mirror = File.join(dir, "mirror")
    stage_release(mirror, assets)
    described_class.new(cache_dir: File.join(dir, "cache"), release: "v9.9.9", mirror: "file://#{mirror}")
  end

  describe ".scenario_asset_name" do
    it "names the unsuffixed back-compat asset for a POSIX host" do
      expect(described_class.scenario_asset_name("3.14.7", posix_platform))
        .to eq("tfs-python-3.14.7-src.tar.gz")
    end

    it "names the windows-msys scenario asset for a mingw host" do
      expect(described_class.scenario_asset_name("3.14.7", msys_platform))
        .to eq("tfs-python-3.14.7-src-windows-msys.tar.gz")
    end
  end

  describe "#fetch" do
    it "fetches the platform's scenario asset, verified against SHA256SUMS" do
      Dir.mktmpdir do |dir|
        fetcher = staged_fetcher(dir, "tfs-python-3.14.7-src.tar.gz" => "pristine",
                                      "tfs-python-3.14.7-src-windows-msys.tar.gz" => "patched")

        path, sha = fetcher.fetch("3.14.7", platform: msys_platform)
        expect(File.basename(path)).to eq("tfs-python-3.14.7-src-windows-msys.tar.gz")
        expect(File.binread(path)).to eq("patched")
        expect(sha).to eq(Digest::SHA256.hexdigest("patched"))

        posix_path, = fetcher.fetch("3.14.7", platform: posix_platform)
        default_path, = fetcher.fetch("3.14.7")
        expect([File.basename(posix_path), File.basename(default_path)])
          .to eq(["tfs-python-3.14.7-src.tar.gz", "tfs-python-3.14.7-src.tar.gz"])
      end
    end
  end

  describe "#tarball_sha256" do
    it "reads the platform's scenario asset sum from the pinned SHA256SUMS" do
      Dir.mktmpdir do |dir|
        fetcher = staged_fetcher(dir, "tfs-python-3.14.7-src.tar.gz" => "pristine",
                                      "tfs-python-3.14.7-src-windows-msys.tar.gz" => "patched")

        expect(fetcher.tarball_sha256("3.14.7", platform: msys_platform))
          .to eq(Digest::SHA256.hexdigest("patched"))
        expect(fetcher.tarball_sha256("3.14.7")).to eq(Digest::SHA256.hexdigest("pristine"))
      end
    end

    it "fails named when the line's windows-msys asset is absent from SHA256SUMS" do
      Dir.mktmpdir do |dir|
        fetcher = staged_fetcher(dir, "tfs-python-3.13.15-src.tar.gz" => "pristine")

        expect { fetcher.tarball_sha256("3.13.15", platform: msys_platform) }
          .to raise_error(TebakoPythonBuilder::Error, /tfs-python-3\.13\.15-src-windows-msys\.tar\.gz/)
      end
    end
  end
end
