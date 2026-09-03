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
# This is the SKELETON planner (TODO.python/02 bootstrap): it expands the
# full cross product under the filters. The ruby factory's planner also
# walks a build-graph.yaml so a leg runs only when something it READS
# changed — that diff-awareness arrives with the real build logic, when
# there are legs worth skipping.
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

# os/arch -> the tamatebako/tebako release's link-unit platform id.
# TebakoPythonBuilder::Platform::LINK_UNIT_PIDS is this repo's single
# owner of the mapping (shared with the local build's --link-unit-pid
# default; upstream owner: tamatebako/tebako release.yml matrix.platform).
LINK_UNIT_PID = TebakoPythonBuilder::Platform::LINK_UNIT_PIDS

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

legs = []
selected_env = []
env.each do |row|
  os = row.fetch("os")
  arch = row.fetch("arch")
  usage_error "matrix.json row #{row.inspect} names an unknown os/arch" unless LINK_UNIT_PID.key?([os, arch])
  next unless platform_filter == "all" || platform_filter == os
  next unless arch_filter == "all" || arch_filter == arch

  host_id = TebakoPythonBuilder::Platform.host_id_for(os, arch)
  selected_env << row.merge("host_id" => host_id)
  container = row["container"] && "#{row['container']}:#{container_version}"
  pythons.each do |python|
    legs << {
      python: python,
      os: os,
      arch: arch,
      host: row.fetch("host"),
      host_id: host_id,
      container: container,
      link_unit_pid: LINK_UNIT_PID.fetch([os, arch])
    }
  end
end

case format
when "matrix" then puts JSON.generate({ include: legs })
when "env" then puts JSON.generate(selected_env)
when "pythons" then puts JSON.generate(pythons)
end
