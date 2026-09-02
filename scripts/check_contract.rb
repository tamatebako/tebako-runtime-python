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
# against schema/contract.schema.yml and cross-checks the version sets
# (tidy/full must be subsets of the catalog — a version that builds but
# never publishes is a config bug, not a leg).
#
# TODO (first build PR): port tebako-runtime-ruby's driver-source parity
# arm — contract.yml's contract_version must agree with the compiled-in
# TEBAKO_CONTRACT_VERSION in the consumed driver's source
# (TEBAKO_DRIVER_SRC points the check at it; the ruby factory's
# scripts/check_contract_version.rb matches the Rust form
# `pub const TEBAKO_CONTRACT_VERSION: u32 = N;`). Until the build links
# the driver there is no second representation to lock against.

require "bundler/setup"
require "json_schemer"
require "pathname"
require "yaml"

class ContractCheck
  REPO_ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
  CONTRACT_YML = REPO_ROOT.join("contract.yml").freeze
  SCHEMA_YML = REPO_ROOT.join("schema", "contract.schema.yml").freeze

  def initialize(contract_yml: CONTRACT_YML, schema_yml: SCHEMA_YML)
    @contract_yml = Pathname.new(contract_yml)
    @schema_yml = Pathname.new(schema_yml)
  end

  # Human-readable violations: schema errors against contract.yml, or a
  # version set naming a version the catalog does not carry. Empty when
  # the contract is well-formed.
  def errors
    violations = schema_errors
    violations += set_errors if violations.empty?
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
end

if $PROGRAM_NAME == __FILE__
  begin
    check = ContractCheck.new
    if check.valid?
      puts "contract version #{check.contract_version}: contract.yml validates against schema/contract.schema.yml"
    else
      check.errors.each { |error| puts "::error::#{error}" }
      exit 1
    end
  rescue StandardError => e
    puts "::error::contract check failed: #{e.message}"
    exit 1
  end
end
