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

require "open3"
require "rbconfig"

module TebakoPythonBuilder
  # Packaging host platform (ported from tebako-runtime-ruby's Platform:
  # the (os, arch) -> release id lookups and the host probes). The CMake
  # helpers (b_env / m_files) are not carried -- the CPython build is
  # autoconf/make, configured by PythonBuild directly.
  class Platform
    def initialize(ostype = RUBY_PLATFORM, arch = RbConfig::CONFIG["host_cpu"])
      @ostype = ostype
      @arch = arch
      @linux = @ostype =~ /linux/ ? true : false
      @musl = @ostype =~ /linux-musl/ ? true : false
      @macos = @ostype =~ /darwin/ ? true : false
      @msys  = @ostype =~ /msys|mingw|cygwin/ ? true : false

      @exe_suffix = @msys ? ".exe" : ""
    end

    attr_reader :ostype, :exe_suffix

    # The runtime mount root this factory BAKES into the fs TU (the
    # driver's runtime_root argument) and declares in the env image's
    # layout card. OWNER: this factory (unlike ruby, whose value flows
    # from tamatebako/ruby's patch literals -- tamatebako/python carries
    # zero patches, so nothing upstream owns a value). The spelling
    # follows the ecosystem convention (/__tfs__ POSIX, A:/t windows --
    # tebako-driver's DEFAULT_ROOT, short on windows for MAX_PATH
    # headroom) so every tebako runtime mounts at one well-known point.
    def mount_root
      @msys ? "A:/t" : "/__tfs__"
    end

    def linux?
      @linux
    end

    def linux_gnu?
      @linux && !@musl
    end

    def linux_musl?
      @linux && @musl
    end

    def macos?
      @macos
    end

    def msys?
      @msys
    end

    # The msys2 environment this mingw host builds in: the pacman package
    # namespace (`mingw-w64-<ucrt-x86_64|clang-aarch64>-*`) and the
    # toolchain root spelling (`/ucrt64`, `/clangarm64` — the openssl
    # prefix). x86_64 pairs ucrt64 (the proven gcc shape); arm64 pairs
    # clangarm64 (the llvm toolchain — the only aarch64-w64-mingw32
    # environment, and the one MSYS2 itself builds its aarch64 python
    # in). Non-msys hosts raise: there is no environment to name.
    def msys_env
      unless @msys
        raise TebakoPythonBuilder::Error.new("#{@ostype} is not a mingw host — no msys2 environment", 112)
      end

      host_arch_id == "arm64" ? "clangarm64" : "ucrt64"
    end

    def musl?
      @musl
    end

    def posix?
      !@msys
    end

    def ncores
      if @ncores.nil?
        if @macos
          out, st = Open3.capture2e("sysctl", "-n", "hw.ncpu")
        else
          out, st = Open3.capture2e("nproc", "--all")
        end

        @ncores = !st.signaled? && st.exitstatus.zero? ? out.strip.to_i : 4
      end
      @ncores
    end

    # (os id, arch id) -> release platform id. Owned by tpkg::Platform
    # (tamatebako/tebako, docs/spec/03 §3); NOT derivable by formula
    # ("windows-ucrt64" carries no arch segment). windows/arm64 follows
    # the product's RESERVED release-asset name ("windows-ucrt-arm64" —
    # the aarch64-windows-ucrt triplet, which tpkg parses but rejects in
    # payload manifests until the platform ships); this factory's leg is
    # publish-gated OFF until the product un-reserves it.
    HOST_IDS = {
      %w[windows x86_64] => "windows-ucrt64",
      %w[windows arm64] => "windows-ucrt-arm64",
      %w[macos arm64] => "macos-arm64",
      %w[macos x86_64] => "macos-x86_64",
      %w[linux-gnu x86_64] => "linux-gnu-x86_64",
      %w[linux-gnu arm64] => "linux-gnu-arm64",
      %w[linux-musl x86_64] => "linux-musl-x86_64",
      %w[linux-musl arm64] => "linux-musl-arm64"
    }.freeze

    # The lookup for callers with no detected host (the release pipeline's
    # expected-asset model); same named failure as the instance path.
    def self.host_id_for(os_id, arch_id)
      HOST_IDS.fetch([os_id, arch_id]) { raise TebakoPythonBuilder::Error.new("#{os_id}/#{arch_id}", 112) }
    end

    # (os id, arch id) -> the tamatebako/tebako release's link-unit
    # platform id (Owner: tamatebako/tebako release.yml matrix.platform —
    # differs from HOST_IDS only on windows). The single owner of the
    # mapping for BOTH the CI leg planner (scripts/compute_matrix.rb) and
    # the local build's default (tools/build_runtime --link-unit-pid).
    # windows/arm64 pairs the msys2 clangarm64 environment (triple
    # aarch64-w64-mingw32) with the aarch64-pc-windows-gnullvm Rust
    # target, so its pid follows the x86_64-windows-gnu convention — but
    # NO product release publishes an arm64 windows unit yet (v2.8.12
    # verified: x86_64-windows-gnu is the only windows unit). The
    # planner skips the leg loudly naming the exact missing asset; if the
    # eventual asset spells its pid differently, this table is the
    # one-line fix.
    LINK_UNIT_PIDS = {
      ["linux-gnu", "x86_64"] => "linux-gnu-x86_64",
      ["linux-gnu", "arm64"] => "linux-gnu-arm64",
      ["linux-musl", "x86_64"] => "linux-musl-x86_64",
      ["linux-musl", "arm64"] => "linux-musl-arm64",
      ["macos", "x86_64"] => "macos-x86_64",
      ["macos", "arm64"] => "macos-arm64",
      ["windows", "x86_64"] => "x86_64-windows-gnu",
      ["windows", "arm64"] => "aarch64-windows-gnu"
    }.freeze

    def self.link_unit_pid_for(os_id, arch_id)
      LINK_UNIT_PIDS.fetch([os_id, arch_id]) { raise TebakoPythonBuilder::Error.new("#{os_id}/#{arch_id}", 112) }
    end

    # This host's link-unit pid (the local-build default).
    def link_unit_pid
      self.class.link_unit_pid_for(host_os_id, host_arch_id)
    end

    # host_id -> the spec 03 §3 vcpkg-form triplet (the in-image payload
    # manifest's provides.provides[].platform grammar). The mapping is
    # owned by tpkg::Platform (tamatebako/tebako — the single
    # triplet <-> release-asset-name owner); this mirrors it for the
    # factory's manifest emission, and a drift fails loudly at the boot
    # smoke (the driver refuses an unknown triplet at manifest parse,
    # exit 65). windows-ucrt-arm64's triplet is the product's RESERVED
    # axis entry: tpkg parses it but payload-manifest validate rejects
    # its use until the platform ships — the leg's publish gate keeps a
    # served manifest from reaching consumers before that.
    TPKG_TRIPLETS = {
      "windows-ucrt64" => "x86_64-windows-ucrt",
      "windows-ucrt-arm64" => "aarch64-windows-ucrt",
      "macos-arm64" => "aarch64-macos",
      "macos-x86_64" => "x86_64-macos",
      "linux-gnu-x86_64" => "x86_64-linux-gnu",
      "linux-gnu-arm64" => "aarch64-linux-gnu",
      "linux-musl-x86_64" => "x86_64-linux-musl",
      "linux-musl-arm64" => "aarch64-linux-musl"
    }.freeze

    # This platform's spec 03 §3 triplet (e.g. "x86_64-windows-ucrt").
    def tpkg_triplet
      TPKG_TRIPLETS.fetch(host_id) do
        raise TebakoPythonBuilder::Error.new("no spec 03 §3 triplet for host_id '#{host_id}'", 112)
      end
    end

    # Platform id as used by tebako-runtime-python package names
    # (e.g. "macos-arm64", "windows-ucrt64")
    def host_id
      self.class.host_id_for(host_os_id, host_arch_id)
    end

    def brew_prefix(package)
      out, st = Open3.capture2("brew --prefix #{package}")
      unless st.exitstatus.zero?
        raise TebakoPythonBuilder::Error.new("brew --prefix #{package} failed with code #{st.exitstatus}", 112)
      end

      out.strip
    end

    private

    def host_os_id
      case @ostype
      when /msys|mingw|cygwin/ then "windows"
      when /darwin/ then "macos"
      when /linux-musl/ then "linux-musl"
      when /linux/ then "linux-gnu"
      else
        raise TebakoPythonBuilder::Error.new(@ostype, 112)
      end
    end

    def host_arch_id
      case @arch
      when /^(x86_64|amd64|x64)$/ then "x86_64"
      when /^(aarch64|arm64)$/ then "arm64"
      else
        raise TebakoPythonBuilder::Error.new(@arch, 112)
      end
    end
  end
end
