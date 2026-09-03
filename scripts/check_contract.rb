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

# Contract check (roadmap 45's python analog): validates contract.yml
# against schema/contract.schema.yml, cross-checks the version sets
# (tidy/full must be subsets of the catalog — a version that builds but
# never publishes is a config bug, not a leg), and locks the TWO
# representations of the contract version:
#   - contract.yml at the repo root — the release pipeline's source of
#     truth (scripts/upload_release.rb folds it into every manifest.json
#     entry's contract card)
#   - TEBAKO_CONTRACT_VERSION in the CONSUMED driver's source —
#     crates/tebako-driver/src/lib.rs at contract.yml's link_unit_release
#     pin (this factory links the product's published link unit; there is
#     no in-repo driver source to read). TEBAKO_DRIVER_SRC points the arm
#     at a local file instead (offline runs).
# A contract bump edits both in the same commit; the arm fails closed on
# a fetch/read failure (a parity check that cannot see its second
# representation proves nothing).

require "bundler/setup"
require "json_schemer"
require "pathname"
require "yaml"

REPO_ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
$LOAD_PATH.unshift(REPO_ROOT.join("build", "lib").to_s)

require "tebako_python_builder"

class ContractCheck
  CONTRACT_YML = REPO_ROOT.join("contract.yml").freeze
  SCHEMA_YML = REPO_ROOT.join("schema", "contract.schema.yml").freeze

  # The Rust form the arm regexes (crates/tebako-driver/src/lib.rs in the
  # tebako product repo — the contract-2 driver, consumed as
  # libtebako_driver.a). The same grammar tebako-runtime-ruby's
  # scripts/check_contract_version.rb matches.
  RUST_PATTERN = /pub const TEBAKO_CONTRACT_VERSION: u32 = (\d+)/
  DRIVER_LIB_RS = "crates/tebako-driver/src/lib.rs"
  DRIVER_REPO = "tamatebako/tebako"

  def initialize(contract_yml: CONTRACT_YML, schema_yml: SCHEMA_YML, driver_src: nil)
    @contract_yml = Pathname.new(contract_yml)
    @schema_yml = Pathname.new(schema_yml)
    @driver_src = driver_src || ENV.fetch("TEBAKO_DRIVER_SRC", nil)
  end

  # Human-readable violations: schema errors against contract.yml, a
  # version set naming a version the catalog does not carry, or a
  # yaml/driver contract-version disagreement. Empty when the contract is
  # well-formed and both representations agree.
  def errors
    violations = schema_errors
    violations += set_errors if violations.empty?
    violations += parity_errors if violations.empty?
    violations
  end

  def valid?
    errors.empty?
  end

  def contract_version
    data = YAML.load_file(@contract_yml)
    data.is_a?(Hash) ? data["contract_version"] : nil
  end

  private

  def schema_errors
    schemer = JSONSchemer.schema(YAML.load_file(@schema_yml))
    schemer.validate(YAML.load_file(@contract_yml)).map do |problem|
      "#{@contract_yml}: #{problem.fetch('error', problem.to_s)}"
    end
  end

  def set_errors
    sets = YAML.load_file(@contract_yml).fetch("python")
    catalog = sets.fetch("catalog")
    %w[tidy full].flat_map do |set|
      (sets.fetch(set) - catalog).map do |version|
        "#{@contract_yml}: python.#{set} names #{version}, which the catalog does not carry"
      end
    end
  end

  # The driver-source parity arm: an unreadable driver source (fails
  # closed), a missing compiled-in constant, or a yaml/driver
  # disagreement are all violations.
  def parity_errors
    body, origin = driver_source
    match = body.match(RUST_PATTERN)
    unless match
      return ["#{origin} carries no `pub const TEBAKO_CONTRACT_VERSION: u32 = N;` — " \
              "the driver must compile its contract version in (roadmap 45)"]
    end

    driver_version = match[1].to_i
    return [] if driver_version == contract_version

    ["contract.yml contract_version is #{contract_version} but TEBAKO_CONTRACT_VERSION in #{origin} " \
     "is #{driver_version} — a contract bump edits both in the same commit (roadmap 45)"]
  rescue StandardError => e
    ["the driver-source parity arm could not read its second representation: #{e.message} " \
     "(needs network to raw.githubusercontent.com or TEBAKO_DRIVER_SRC=<local lib.rs>; fails closed)"]
  end

  # [body, origin]: the TEBAKO_DRIVER_SRC local file when set, else the
  # pinned link_unit_release's driver source off raw.githubusercontent.com.
  def driver_source
    return [File.read(@driver_src), @driver_src] if @driver_src

    url = "https://raw.githubusercontent.com/#{DRIVER_REPO}/#{link_unit_release}/#{DRIVER_LIB_RS}"
    [TebakoPythonBuilder::BuildHelpers.read_url(url, code: 1), url]
  end

  def link_unit_release
    release = YAML.load_file(@contract_yml)["link_unit_release"].to_s
    return release unless release.empty?

    raise "#{@contract_yml} carries no link_unit_release pin — the parity arm has no driver tag to read"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    check = ContractCheck.new
    if check.valid?
      puts "contract version #{check.contract_version}: contract.yml validates against schema/contract.schema.yml " \
           "and the consumed driver's compiled-in TEBAKO_CONTRACT_VERSION agrees"
    else
      check.errors.each { |error| puts "::error::#{error}" }
      exit 1
    end
  rescue StandardError => e
    puts "::error::contract check failed: #{e.message}"
    exit 1
  end
end
