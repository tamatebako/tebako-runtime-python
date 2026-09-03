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

require "yaml"

module TebakoPythonBuilder
  # contract.yml — the factory's pin/catalog SSOT (repo AGENTS.md). The
  # build entry points read their defaults from here; an EMPTY pin fails
  # closed by name (a pin the schema requires but the value has not been
  # opened yet is a config state, never a silent skip).
  class Contract
    PATH = File.expand_path("../../../contract.yml", __dir__).freeze

    def initialize(path = PATH)
      @path = path
      @data = YAML.load_file(path)
      unless @data.is_a?(Hash)
        raise TebakoPythonBuilder::Error.new("#{path} is not a YAML mapping (schema: schema/contract.schema.yml)", 64)
      end
    end

    def contract_version
      pin("contract_version")
    end

    # The tamatebako/python source release pin (tfs-python-<v>-src.tar.gz
    # + SHA256SUMS). Empty = the source factory has published nothing this
    # factory may consume — fail closed.
    def source_release
      nonempty_pin("source_release")
    end

    # The tamatebako/tebako release pin whose prebuilt link unit (and tfs
    # CLI) the legs consume.
    def link_unit_release
      nonempty_pin("link_unit_release")
    end

    def catalog
      sets = @data.fetch("python") do
        raise TebakoPythonBuilder::Error.new("#{@path} carries no python: catalog", 64)
      end
      sets.fetch("catalog") do
        raise TebakoPythonBuilder::Error.new("#{@path} python: carries no catalog key", 64)
      end
    end

    private

    def pin(key)
      @data.fetch(key) do
        raise TebakoPythonBuilder::Error.new("#{@path} carries no #{key} pin", 64)
      end
    end

    def nonempty_pin(key)
      value = pin(key).to_s
      return value unless value.empty?

      raise TebakoPythonBuilder::Error.new(
        "#{@path} pin #{key} is empty — the release it names has not been published/opened yet " \
        "(build legs fail closed on an empty pin)", 64
      )
    end
  end
end
