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
require "yaml"

module TebakoPythonBuilder
  # The env image's L1 payload manifest (spec 03 §1-2): the
  # /__tpkg__/manifest.yaml the driver reads post-mount. The grammar is
  # owned by docs/spec/schemas/payload-manifest.yaml (tamatebako/tebako,
  # mirrored by tpkg's PayloadManifest): a malformed manifest is a named
  # boot refusal (exit 65) on EVERY leg, so this emitter sticks to the
  # locked capability truth tables and digest shapes exactly (the
  # tebako-runtime-ruby ImageManifest port). identity.digest follows the
  # spec 03 §7 fixed-point rule: blob_sha256 is zeroed inside the image
  # (the real digest lives one tier out — the store sidecar), tree_hash
  # is the zero placeholder until the CAS lands.
  #
  # No entrypoints are declared (the ruby factory's shape): consumers
  # resolve the interpreter by the release manifest's naming convention.
  # `python3 -m pip` is the pip form; a pip3 console script would carry
  # a dead build-prefix shebang (README's pip decision).
  # POSIX ssl rides the host's /etc/ssl; windows resolves the system cert
  # store — no materialize declaration anywhere.
  class ImageManifest
    # In-image location the driver reads (tpkg::PAYLOAD_MANIFEST_PATH).
    PATH = File.join("__tpkg__", "manifest.yaml").freeze

    def initialize(platform:, python_version:, tebako_version:, patch_set:, src_sha256:)
      @platform = platform
      @python_version = python_version
      @tebako_version = tebako_version
      @patch_set = patch_set
      @src_sha256 = src_sha256
    end

    # Write the manifest into the assembled layout tree (before the image
    # is packed); returns the written path.
    def deploy(tree_root)
      path = File.join(tree_root, PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(to_h))
      path
    end

    def to_h
      {
        "schema_version" => 1,
        "identity" => identity,
        "provides" => provides
      }
    end

    private

    def identity # rubocop:disable Metrics/MethodLength -- one declarative block per spec 03 §2.1; splitting it scatters the grammar
      {
        "schema_version" => 1,
        # The spec-18 contract field: this image is an era-2 artifact (the
        # same declaration lib/tebako/layout.yaml carries on the C3 edge).
        "era" => 2,
        "kind" => "runtime",
        "name" => "tebako-runtime-python",
        "version" => @tebako_version,
        "producer" => { "tool" => "tebako-runtime-python", "tool_version" => @tebako_version },
        "created" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source" => { "src_sha256" => @src_sha256 },
        "digest" => {
          "tree_hash" => "sha256:#{"0" * 64}",
          "blob_sha256" => "0" * 64
        },
        "signing" => { "state" => "unsigned" },
        "encryption" => { "state" => "none" }
      }
    end

    # kind=runtime PROVIDES (spec 03 §2.2): the engine line the dispatcher
    # matches runtime_requirements against, the source provenance, and the
    # locked runtime capability triple. abi_line is the python major.minor
    # (the "3.13" line; the EXT-SUFFIX ABI grammar is TODO.python/04's,
    # surfaced meanwhile by the release shard's additive `abi` facet).
    def provides # rubocop:disable Metrics/MethodLength -- one declarative block per spec 03 §2.2; splitting it scatters the grammar
      python = TebakoPythonBuilder::PythonVersion.new(@python_version)
      {
        "provides" => {
          "engine" => "python",
          "version" => @python_version,
          "abi_line" => python.abi_line,
          "platform" => @platform.tpkg_triplet
        },
        "built_from" => { "src_sha256" => @src_sha256, "patch_set" => @patch_set },
        "capabilities" => { "exec" => true, "read" => true, "runtime" => true }
      }
    end
  end
end
