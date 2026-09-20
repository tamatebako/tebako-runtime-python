#!/usr/bin/env ruby
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

# Compute the build-leg matrix for _build-platform.yml / publish.yml: the
# python set (resolved from contract.yml — the same read scripts/versions
# performs) x the env vocabulary (.github/matrix.json — tebako-runtime-ruby's
# grammar), sliced by the dispatch filters. Emits a GitHub Actions matrix
# JSON document on stdout. Stdlib only.
#
# This planner expands the full cross product under the filters. The
# ruby factory's planner also walks a build-graph.yaml so a leg runs
# only when something it READS changed — that diff-awareness is a
# follow-up.
#
# Usage: compute_matrix.rb [--format matrix|env|pythons]
#   matrix  (default) the GHA matrix document {"include": [leg, ...]} —
#           extra top-level keys are impossible (GHA would read them as
#           matrix variables), so the other two forms exist
#   env     the selected matrix.json rows as a JSON array (each + host_id)
#           — the release job's EXPECTED_ENV_MATRIX
#   pythons the selected python versions as a JSON array — the release
#           job's EXPECTED_PYTHON_MATRIX
#
# Filters (env vars, mirroring the ruby factory's dispatch grammar):
#   PYTHON_FILTER    full | tidy | catalog | comma-separated versions (default: full)
#   PLATFORM_FILTER  all | windows | linux-gnu | linux-musl | macos      (default: all)
#   ARCH_FILTER      all | x86_64 | arm64                                (default: all)
#
# Every leg carries:
#   python / os / arch / host   — the matrix coordinates
#   host_id                     — this factory's package-name platform id
#                                 (Platform::HOST_IDS — the exe/image
#                                 grammar tebako-runtime-<ver>-<python>-<host_id>)
#   jit_llvm                    — the LLVM major a jit line's build
#                                 provisions ("" for unflavored lines),
#                                 from PythonVersion::JIT_LLVM_MAJORS;
#                                 the build re-verifies it against the
#                                 extracted source's Tools/jit/_llvm.py
#                                 (the parity arm — PythonBuild's gate)
#   container                   — the tpkg-builder image ref with
#                                 contract.yml's container_version tag
#                                 applied, null for the runner-native legs
#                                 (macos, windows — the documented
#                                 tebako-ci-containers exception). The legs
#                                 docker-run the image on the ubuntu host:
#                                 the musl image is alpine-based and node
#                                 actions cannot run on musl, so the
#                                 job-level container: form is out.
#   link_unit_pid               — the product release's platform id for
#                                 the link-unit asset name, read from
#                                 TebakoPythonBuilder::Platform (this
#                                 repo's single owner of the os/arch ->
#                                 pid mapping; upstream owner:
#                                 tamatebako/tebako release.yml's
#                                 matrix.platform).
#
# The windows/arm64 leg carries two gates, both LOUD (the no-jit /
# no-scenario-asset precedents below — a skipped leg names its unmet
# condition, never silently disappears):
#   1. the artifact gate (every run): the pinned link-unit release must
#      ship the arm64 windows unit (link-unit-<ver>-aarch64-windows-
#     gnu.tar.gz). Today's product releases ship x86_64-windows-gnu only;
#      this factory never builds the driver stack from source
#      (contract.yml's link_unit_release comment), so the leg stays
#      disabled until the product publishes the unit — then build CI
#      (push/PR/dispatch) runs it automatically.
#   2. the publish gate (PUBLISH runs only): a leg can build green and
#      still not serve — publish.yml's plan and release audit exclude
#      windows/arm64 until the owner sets the TEBAKO_SERVE_WINDOWS_ARM64
#      repository variable. The env/pythons outputs derive from the same
#      walk, so a gated leg cannot half-serve: no expectation of its
#      packages ever reaches the audit.
#
# Named errors, exit 64: an unknown platform/arch filter, an unknown
# --format, or a matrix.json row outside the known vocabulary is a config
# bug, never a skipped leg.

require "json"
require "yaml"

REPO_ROOT = File.expand_path("..", __dir__).freeze
$LOAD_PATH.unshift(File.join(REPO_ROOT, "build", "lib"))

require "tebako_python_builder"

CONTRACT_YML = File.join(REPO_ROOT, "contract.yml").freeze
MATRIX_JSON = File.join(REPO_ROOT, ".github", "matrix.json").freeze

PLATFORMS = %w[windows linux-gnu linux-musl macos].freeze
ARCHES = %w[x86_64 arm64].freeze

# The product repo the link unit + tfs CLI are consumed from (LinkUnit/
# TfsTool's REPO — the planner's artifact gate reads the same release).
TEBAKO_RELEASE_REPO = "tamatebako/tebako".freeze

# os/arch -> the tamatebako/tebako release's link-unit platform id.
# TebakoPythonBuilder::Platform::LINK_UNIT_PIDS is this repo's single
# owner of the mapping (shared with the local build's --link-unit-pid
# default; upstream owner: tamatebako/tebako release.yml matrix.platform).
LINK_UNIT_PID = TebakoPythonBuilder::Platform::LINK_UNIT_PIDS

# A stand-in mingw/ucrt host, used only to ask SourceFetcher for the
# windows-msys scenario asset name (its grammar branches on #msys?).
MINGW_PLATFORM = TebakoPythonBuilder::Platform.new("x86_64-w64-mingw32").freeze

def usage_error(message)
  warn "compute_matrix: #{message}"
  exit 64
end

format = "matrix"
if (idx = ARGV.index("--format"))
  format = ARGV[idx + 1].to_s
  usage_error "--format expects matrix | env | pythons" unless %w[matrix env pythons].include?(format)
elsif !ARGV.empty?
  usage_error "unknown argument(s): #{ARGV.join(', ')} (the only option is --format matrix|env|pythons)"
end

contract = YAML.load_file(CONTRACT_YML)
python_sets = contract.fetch("python") { usage_error "#{CONTRACT_YML} carries no python: catalog" }
catalog = python_sets.fetch("catalog") { usage_error "#{CONTRACT_YML} python: carries no catalog key" }
container_version = contract.fetch("container_version") do
  usage_error "#{CONTRACT_YML} carries no container_version pin"
end
source_release = contract.fetch("source_release") do
  usage_error "#{CONTRACT_YML} carries no source_release pin"
end
link_unit_release = contract.fetch("link_unit_release") do
  usage_error "#{CONTRACT_YML} carries no link_unit_release pin"
end

python_filter = ENV.fetch("PYTHON_FILTER", "full")
pythons =
  case python_filter
  when "full", "tidy", "catalog"
    python_sets.fetch(python_filter) { usage_error "#{CONTRACT_YML} python: carries no #{python_filter} set" }
  when ""
    usage_error "PYTHON_FILTER is empty — expected full | tidy | catalog | a comma-separated version list"
  else
    versions = python_filter.split(",").map(&:strip).reject(&:empty?)
    unknown = versions - catalog
    usage_error "unknown python version(s) #{unknown.join(', ')} — catalog knows: #{catalog.join(', ')}" unless unknown.empty?
    versions
  end

platform_filter = ENV.fetch("PLATFORM_FILTER", "all")
unless platform_filter == "all" || PLATFORMS.include?(platform_filter)
  usage_error "unknown platform #{platform_filter.inspect} — expected all | #{PLATFORMS.join(' | ')}"
end

arch_filter = ENV.fetch("ARCH_FILTER", "all")
unless arch_filter == "all" || ARCHES.include?(arch_filter)
  usage_error "unknown arch #{arch_filter.inspect} — expected all | #{ARCHES.join(' | ')}"
end

env = JSON.parse(File.read(MATRIX_JSON)).fetch("env")

# A windows leg builds only from the line's msys2/ucrt64 scenario tree —
# upstream CPython has zero mingw support, so the leg's
# source is tfs-python-<base>-src-windows-msys.tar.gz in the pinned
# source release's SHA256SUMS. Lines whose series has not shipped yet
# skip windows LOUDLY (their POSIX legs are unaffected). The SHA256SUMS
# read is lazy and scoped to a windows env row surviving the filters —
# POSIX-only triggers never fetch.
windows_sums = nil
windows_buildable = lambda do |base_version|
  windows_sums ||= begin
    TebakoPythonBuilder::SourceFetcher.new(
      release: source_release,
      cache_dir: File.join(REPO_ROOT, ".build", "downloads")
    ).sha256sums
  rescue TebakoPythonBuilder::Error => e
    # An unreadable pinned release (a 404 while the pin names a release
    # that does not exist yet) is a config-class failure — the same
    # exit-64 discipline as an unknown filter, never a stack trace.
    usage_error "cannot read the pinned source release's SHA256SUMS: #{e.message}"
  end
  windows_sums.key?(TebakoPythonBuilder::SourceFetcher.scenario_asset_name(base_version, MINGW_PLATFORM))
end

# The arm64 windows leg's artifact gate (lazy, scoped the same way): the
# pinned link-unit release's published asset names, read off the same
# release-API digest anchor LinkUnit stages from. An unreadable pinned
# release is a config-class failure — the windows_sums discipline.
windows_arm64_unit_assets = nil
arm64_link_unit_present = lambda do |pid|
  assets = windows_arm64_unit_assets ||= begin
    TebakoPythonBuilder::BuildHelpers.release_asset_digests(TEBAKO_RELEASE_REPO, link_unit_release, code: 123)
  rescue TebakoPythonBuilder::Error => e
    usage_error "cannot read the pinned link-unit release's assets: #{e.message}"
  end
  asset = "link-unit-#{link_unit_release.sub(/\Av/, "")}-#{pid}.tar.gz"
  assets.key?(asset)
end

# A PUBLISH run (publish.yml's build+publish mode) serves windows/arm64
# only when the owner has armed the variable; build CI never consults it.
publish_run = ENV.fetch("PUBLISH", "") == "true"

legs = []
selected_env = []
env.each do |row|
  os = row.fetch("os")
  arch = row.fetch("arch")
  usage_error "matrix.json row #{row.inspect} names an unknown os/arch" unless LINK_UNIT_PID.key?([os, arch])
  next unless platform_filter == "all" || platform_filter == os
  next unless arch_filter == "all" || arch_filter == arch

  host_id = TebakoPythonBuilder::Platform.host_id_for(os, arch)
  container = row["container"] && "#{row['container']}:#{container_version}"
  env_admitted = false
  pythons.each do |python|
    line = begin
      TebakoPythonBuilder::PythonVersion.new(python)
    rescue TebakoPythonBuilder::Error => e
      # A catalog line the model rejects (a bad grammar, a jit line below
      # the 3.13 floor) is a config bug — the same exit-64 class as an
      # unknown filter, never a stack trace.
      usage_error "catalog line #{python.inspect}: #{e.message}"
    end
    # CPython's JIT target whitelist (Tools/jit/_targets.py's get_target)
    # rejects *-linux-musl — upstream has no musl JIT support (both 3.13
    # and 3.14 fail mid-make: "invalid get_target value:
    # 'x86_64-pc-linux-musl'"). jit lines are linux-gnu + macos only; a
    # musl whitelist patch would belong to the source factory
    # (tamatebako/python), never a per-leg workaround here.
    if line.jit? && os == "linux-musl"
      warn "note: #{python} skipped on linux-musl/#{arch} — CPython's JIT target whitelist rejects *-linux-musl (upstream)"
      next
    end
    # The same whitelist admits only MSVC windows targets
    # (x86_64-pc-windows-msvc): the ucrt64 leg's x86_64-w64-mingw32 triple
    # is rejected upstream, so jit lines do not build on windows either.
    if line.jit? && os == "windows"
      warn "note: #{python} skipped on windows/#{arch} — CPython's JIT target whitelist admits MSVC windows only (upstream)"
      next
    end
    # A windows leg exists only when the pinned source release ships the
    # line's msys2/ucrt64 scenario asset (tamatebako/python's
    # patches/<line>/ series). POSIX legs are unaffected. The scenario
    # axis is arch-agnostic: the arm64 row consumes the same
    # windows-msys tree (the series' aarch64 arms are upstream-ported
    # MSYS2 shapes — pyd_platform_tag/ms_dll_id).
    if os == "windows" && !windows_buildable.call(line.base_version)
      warn "note: #{python} skipped on windows/#{arch} — #{source_release} ships no " \
           "#{TebakoPythonBuilder::SourceFetcher.scenario_asset_name(line.base_version, MINGW_PLATFORM)} " \
           "(the line's msys2/ucrt64 series lands in a later tamatebako/python release)"
      next
    end
    # The windows/arm64 gates (see the header): first the artifact
    # reality — the pinned link-unit release must publish the arm64
    # windows unit, or the leg would die mid-build at the LinkUnit stage
    # (a source-build fallback for the driver stack does not exist) —
    # then the owner's publish enablement on PUBLISH runs. Both notes
    # name their unmet condition exactly.
    if os == "windows" && arch == "arm64"
      pid = LINK_UNIT_PID.fetch([os, arch])
      unless arm64_link_unit_present.call(pid)
        warn "note: #{python} skipped on windows/#{arch} — #{TEBAKO_RELEASE_REPO} #{link_unit_release} ships no " \
             "link-unit-#{link_unit_release.sub(/\Av/, "")}-#{pid}.tar.gz (the arm64 windows link unit; " \
             "the leg stays disabled until the product publishes it)"
        next
      end
      if publish_run && ENV.fetch("TEBAKO_SERVE_WINDOWS_ARM64", "") != "true"
        warn "note: #{python} skipped on windows/#{arch} — the publish gate is OFF " \
             "(arm the TEBAKO_SERVE_WINDOWS_ARM64 repository variable to serve windows/arm64 releases)"
        next
      end
    end
    legs << {
      python: python,
      os: os,
      arch: arch,
      host: row.fetch("host"),
      host_id: host_id,
      # The in-leg sign step's tebako-pkg must EXECUTE on the leg's
      # runner, and musl legs build inside the alpine container on a
      # glibc ubuntu host: a musl-linked tool cannot exec there (its ELF
      # interpreter is absent — execve answers ENOENT). The tool's
      # platform is the runner's, never the artifact's.
      sign_tool_host_id: (os == "linux-musl" ? "linux-gnu-#{arch}" : host_id),
      jit_llvm: line.jit? ? line.jit_llvm_major.to_s : "",
      container: container,
      link_unit_pid: LINK_UNIT_PID.fetch([os, arch])
    }
    # The env row joins the expectations only when the row EMITTED a leg:
    # the audit reads EXPECTED_ENV_MATRIX x EXPECTED_PYTHON_MATRIX, so a
    # gated row must not survive into env (its pythons are leg-derived
    # already — a row without legs would manufacture expectations for
    # packages no leg built). matrix/env/pythons all derive from the
    # same filtered walk.
    unless env_admitted
      selected_env << row.merge("host_id" => host_id)
      env_admitted = true
    end
  end
end

case format
when "matrix" then puts JSON.generate({ include: legs })
when "env" then puts JSON.generate(selected_env)
# The leg-derived python set, in catalog order: a line with no leg under
# the active filters (a jit line on linux-musl — upstream's JIT target
# whitelist rejects *-linux-musl, above) can never land on the release, so
# the publish gate must not EXPECT it (the v0.1.3 musl incompleteness
# failure). matrix/env/pythons all derive from the same filtered walk.
when "pythons" then puts JSON.generate(pythons.select { |python| legs.any? { |leg| leg[:python] == python } })
end
