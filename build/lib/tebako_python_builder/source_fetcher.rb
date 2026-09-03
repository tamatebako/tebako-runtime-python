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

require "fileutils"

module TebakoPythonBuilder
  # Download, SHA256-verification and caching of the pristine CPython
  # source published by tamatebako/python: the release carries one
  # tfs-python-<version>-src.tar.gz asset per published version plus a
  # SHA256SUMS manifest (the trust anchor — a checksum mismatch is a hard
  # error, never a refetch). Zero patches (the source factory's contract),
  # so there are no per-platform scenario assets (the ruby factory's
  # scenario_asset_names has no analog here).
  class SourceFetcher
    REPO = "tamatebako/python"

    def initialize(cache_dir:, release:, mirror: nil)
      @release = release
      @base_url = (mirror || "https://github.com/#{REPO}/releases/download/#{release}").sub(%r{/+\z}, "")
      @cache_dir = cache_dir
    end

    def asset_name(python_version)
      "tfs-python-#{python_version}-src.tar.gz"
    end

    # Returns [tarball_path, sha256] for the requested python version
    def fetch(python_version)
      fetch_asset(asset_name(python_version))
    end

    # The published sha256 of a version's tarball, read from the pinned
    # release's SHA256SUMS. This is the per-version cache-key input of the
    # build workflow's .build cache: the key and the download-time
    # verification in #fetch_asset share the same source of truth, so a
    # cache restores only trees built from exactly these bytes.
    def tarball_sha256(python_version)
      expected_sha256(asset_name(python_version))
    end

    # Returns [tarball_path, sha256] for the named release asset
    def fetch_asset(name)
      sha256 = expected_sha256(name)
      tarball = File.join(@cache_dir, @release, name)
      return [tarball, sha256] if File.file?(tarball) && TebakoPythonBuilder::BuildHelpers.sha256_file(tarball) == sha256

      FileUtils.rm_f(tarball)
      TebakoPythonBuilder::BuildHelpers.download("#{@base_url}/#{name}", tarball, code: 122)
      actual = TebakoPythonBuilder::BuildHelpers.sha256_file(tarball)
      return [tarball, sha256] if actual == sha256

      FileUtils.rm_f(tarball)
      raise TebakoPythonBuilder::Error.new(
        "#{name}: expected SHA256 #{sha256}, got #{actual}; download deleted", 121
      )
    end

    # The pinned release's full SHA256SUMS as {asset_name => sha256}
    # (downloaded once into the cache).
    def sha256sums
      sums = File.join(@cache_dir, @release, "SHA256SUMS")
      unless File.file?(sums)
        TebakoPythonBuilder::BuildHelpers.download("#{@base_url}/SHA256SUMS", sums, code: 122)
      end
      File.foreach(sums).each_with_object({}) do |line, acc|
        sha256, file = line.strip.split(/\s+/, 2)
        acc[file.sub(/\A\*/, "")] = sha256.downcase if file && sha256 =~ /\A[0-9a-f]{64}\z/i
      end
    end

    private

    def expected_sha256(name)
      sha256sums[name] ||
        (raise TebakoPythonBuilder::Error.new(
          "#{name} not found in the SHA256SUMS of #{REPO} release #{@release} " \
          "(#{@base_url}/SHA256SUMS)", 122
        ))
    end
  end
end
