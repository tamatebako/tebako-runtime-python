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
  # The PUBLISHED link unit (a tamatebako/tebako release asset): the
  # spec-17 driver (libtebako_driver.a) + the scoped tfs staticlib
  # (libtfs.a) + the native closure (closure/*.a, symbol-scoped by
  # tebako-arscope) + the POSIX preload shim (libtfs_preload.{so,dylib})
  # + the c_api header. The closure depends on the triplet and the
  # product release only — never on the python version.
  #
  # Trust anchor (tebako-runtime-ruby ci/link-unit-download.sh's shape,
  # in-process instead of the gh CLI): the release API's per-asset
  # `digest` field — the release SHA256SUMS does NOT cover the link-unit
  # assets. A checksum MISMATCH is a hard error (124), never a silent
  # fallback — bytes that disagree with the API are a supply-chain event.
  # A pin MISS (the release ships no unit for this platform) is a named
  # error too (123): v2.1.5 ships all seven legs, and the build-from-
  # source fallback is an explicit follow-up, not a silent path.
  class LinkUnit
    REPO = "tamatebako/tebako"

    # The completeness contract — the same shape the build asserts on.
    REQUIRED_FILES = %w[libtebako_driver.a libtfs.a include/tebako/fs/c_api.h].freeze

    def initialize(cache_dir:, release:, platform:, pid: nil)
      @cache_dir = cache_dir
      @release = release
      @platform = platform
      @pid = pid || platform.link_unit_pid
    end

    def asset_name
      "link-unit-#{@release.sub(/\Av/, "")}-#{@pid}.tar.gz"
    end

    # Download + verify + extract the unit into dest; returns dest.
    # Idempotent: a dest whose marker names this asset's verified sha256
    # is reused as-is.
    def stage(dest)
      expected = expected_digest
      marker = File.join(dest, ".sha256")
      if File.file?(marker) && File.read(marker).strip == expected && complete?(dest)
        puts "-- Link unit #{asset_name} already staged (sha256 #{expected})"
        return dest
      end

      tarball = File.join(@cache_dir, "link-unit", asset_name)
      unless File.file?(tarball) && TebakoPythonBuilder::BuildHelpers.sha256_file(tarball) == expected
        FileUtils.rm_f(tarball)
        url = "https://github.com/#{REPO}/releases/download/#{@release}/#{asset_name}"
        TebakoPythonBuilder::BuildHelpers.download(url, tarball, code: 123)
      end

      actual = TebakoPythonBuilder::BuildHelpers.sha256_file(tarball)
      unless actual == expected
        FileUtils.rm_f(tarball)
        raise TebakoPythonBuilder::Error.new(
          "#{asset_name} sha256 mismatch: the #{REPO} #{@release} release API declares #{expected}, " \
          "the download is #{actual} — refusing the unit (never a silent fallback on a " \
          "supply-chain mismatch)", 124
        )
      end

      FileUtils.rm_rf(dest, secure: true)
      FileUtils.mkdir_p(dest)
      TebakoPythonBuilder::BuildHelpers.run_with_capture(["tar", "-xzf", tarball, "-C", dest, "--strip-components=1"])
      assert_complete!(dest)
      File.write(marker, "#{expected}\n")
      puts "-- Link unit #{asset_name} verified (sha256 #{expected}) and staged at #{dest}"
      dest
    end

    # The exe link inputs: the two scoped Rust staticlibs plus the closure
    # archives (sorted for a stable link line), every one existence-checked.
    def libraries(dir)
      libs = %w[libtebako_driver.a libtfs.a].map { |name| checked(dir, name) }
      libs + Dir.glob(File.join(dir, "closure", "*.a")).sort
    end

    # The preload shim's staged path (POSIX only; nil on windows — the
    # preload tier is roadmap 30 phase 2 there).
    def preload_shim_path(dir)
      name = preload_shim_name
      name && File.join(dir, name)
    end

    def preload_shim_name
      return nil if @platform.msys?

      @platform.macos? ? "libtfs_preload.dylib" : "libtfs_preload.so"
    end

    private

    def checked(dir, name)
      path = File.join(dir, name)
      return path if File.file?(path)

      raise TebakoPythonBuilder::Error.new(
        "missing link-unit input: #{path} — stage the link unit first (LinkUnit#stage)", 112
      )
    end

    def expected_digest
      digests = TebakoPythonBuilder::BuildHelpers.release_asset_digests(REPO, @release, code: 123)
      digests.fetch(asset_name) do
        raise TebakoPythonBuilder::Error.new(
          "no published #{asset_name} on #{REPO} release #{@release} — the pinned link unit does not " \
          "cover #{@pid} (a source-build fallback is the follow-up; never a silent one)", 123
        )
      end
    end

    def complete?(dir)
      REQUIRED_FILES.all? { |f| File.size?(File.join(dir, f)) } &&
        !Dir.glob(File.join(dir, "closure", "*.a")).empty? &&
        (preload_shim_name.nil? || File.size?(File.join(dir, preload_shim_name)))
    end

    def assert_complete!(dir)
      REQUIRED_FILES.each do |f|
        next if File.size?(File.join(dir, f))

        raise TebakoPythonBuilder::Error.new("downloaded link unit #{asset_name} lacks #{f}", 124)
      end
      if Dir.glob(File.join(dir, "closure", "*.a")).empty?
        raise TebakoPythonBuilder::Error.new("downloaded link unit #{asset_name} carries no closure/*.a", 124)
      end
      return if preload_shim_name.nil? || File.size?(File.join(dir, preload_shim_name))

      raise TebakoPythonBuilder::Error.new(
        "downloaded link unit #{asset_name} lacks #{preload_shim_name} — the unpatched CPython " \
        "runtime cannot see its mounted image without the preload shim (the LINKED-driver " \
        "re-exec, README)", 124
      )
    end
  end
end
