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

# This factory's tebako-release declaration (ecosystem invariant 10: the
# release machinery's single owner is tamatebako/tebako-release-tooling —
# the gem the Gemfile pins at contract.yml's release_tooling tag). This
# file declares THIS factory's identity + policy through the gem's
# adapter seam; the machinery itself is never copied here. The
# tebako-release exe loads this file before dispatching (upload|sign).

$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_python_builder"

# The factory's release policy, delegated to the version model that owns
# each grammar (TebakoPythonBuilder::PythonVersion — spec 00 §10's
# single-owner rule; nothing here re-derives a name or a grammar).
class PythonReleaseAdapter < TebakoRelease::Adapter
  # The additive capabilities display line of a manifest entry: jit marks
  # the release line's CPython copy-and-patch JIT build (PEP 744, the
  # x.y.z-jit flavor) — display metadata owned by this factory, never a
  # selector axis.
  def capabilities(version:, platform_id:)
    _ = platform_id
    python = TebakoPythonBuilder::PythonVersion.new(version)
    python.jit? ? [TebakoPythonBuilder::PythonVersion::FLAVOR_JIT] : []
  end

  # The PE name the store materializes next to a windows exe so its
  # imports resolve (libpython<X.Y>.dll — PythonVersion#msys_dll_name is
  # the name's single owner). Only the msys legs stage a DLL beside the
  # package, so the uploader consults this facet only there.
  def dll_install_name(version, host_id)
    _ = host_id
    TebakoPythonBuilder::PythonVersion.new(version).msys_dll_name
  end

  # The package-name grammar's version capture (x.y.z plus the optional
  # -jit flavor suffix) — PythonVersion::LINE_GRAMMAR_SOURCE owns it.
  def version_grammar_source
    TebakoPythonBuilder::PythonVersion::LINE_GRAMMAR_SOURCE
  end
end

TebakoRelease.configure(
  repo: "tamatebako/tebako-runtime-python",
  language: "python",
  title_prefix: "Tebako Python runtime packages",
  contract_yml: File.expand_path("../contract.yml", __dir__),
  adapter: PythonReleaseAdapter.new
)
