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

# Compute the build-leg matrix for publish.yml: the python set (resolved
# from contract.yml — the same read scripts/versions performs) x the env
# vocabulary (.github/matrix.json — tebako-runtime-ruby's grammar), sliced
# by the dispatch filters. Emits a GitHub Actions matrix JSON document on
# stdout. Stdlib only.
#
# This is the SKELETON planner (TODO.python/02 bootstrap): it expands the
# full cross product under the filters. The ruby factory's planner also
# walks a build-graph.yaml so a leg runs only when something it READS
# changed — that diff-awareness arrives with the real build logic, when
# there are legs worth skipping.
#
# Filters (env vars, mirroring the ruby factory's dispatch grammar):
#   PYTHON_FILTER    full | tidy | catalog | comma-separated versions (default: full)
#   PLATFORM_FILTER  all | windows | linux-gnu | linux-musl | macos      (default: all)
#   ARCH_FILTER      all | x86_64 | arm64                                (default: all)
#
# Every leg carries:
#   python / os / arch / host   — the matrix coordinates
#   container_json              — the job container as a JSON document
#                                 ("null" for the runner-native legs:
#                                 macos, windows — tebako-ci-containers
#                                 documents the exception), the image ref
#                                 with contract.yml's container_version
#                                 tag applied otherwise
#   link_unit_pid               — the product release's platform id for
#                                 the link-unit asset name. Owner:
#                                 tamatebako/tebako release.yml's
#                                 matrix.platform (the same mapping
#                                 tebako-runtime-ruby's
#                                 ci/link-unit-download.sh hardcodes —
#                                 mirrored here, never re-invented).
#
# Named errors, exit 64: an unknown platform/arch filter or a matrix.json
# row outside the known vocabulary is a config bug, never a skipped leg.

require "json"
require "yaml"

REPO_ROOT = File.expand_path("..", __dir__).freeze
CONTRACT_YML = File.join(REPO_ROOT, "contract.yml").freeze
MATRIX_JSON = File.join(REPO_ROOT, ".github", "matrix.json").freeze

PLATFORMS = %w[windows linux-gnu linux-musl macos].freeze
ARCHES = %w[x86_64 arm64].freeze

# os/arch -> the tamatebako/tebako release's link-unit platform id
# (Owner: tamatebako/tebako release.yml matrix.platform).
LINK_UNIT_PID = {
  ["linux-gnu", "x86_64"] => "linux-gnu-x86_64",
  ["linux-gnu", "arm64"] => "linux-gnu-arm64",
  ["linux-musl", "x86_64"] => "linux-musl-x86_64",
  ["linux-musl", "arm64"] => "linux-musl-arm64",
  ["macos", "x86_64"] => "macos-x86_64",
  ["macos", "arm64"] => "macos-arm64",
  ["windows", "x86_64"] => "x86_64-windows-gnu"
}.freeze

def usage_error(message)
  warn "compute_matrix: #{message}"
  exit 64
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
env.each do |row|
  os = row.fetch("os")
  arch = row.fetch("arch")
  usage_error "matrix.json row #{row.inspect} names an unknown os/arch" unless LINK_UNIT_PID.key?([os, arch])
  next unless platform_filter == "all" || platform_filter == os
  next unless arch_filter == "all" || arch_filter == arch

  container = row["container"] && "#{row['container']}:#{container_version}"
  pythons.each do |python|
    legs << {
      python: python,
      os: os,
      arch: arch,
      host: row.fetch("host"),
      container_json: container ? JSON.generate({ image: container }) : "null",
      link_unit_pid: LINK_UNIT_PID.fetch([os, arch])
    }
  end
end

puts JSON.generate({ include: legs })
