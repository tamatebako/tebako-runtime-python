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

module TebakoPythonBuilder
  # CPython version model (the tebako-runtime-ruby RubyVersion analog —
  # version predicates and the derived name grammar; the source tarball
  # carries its own integrity metadata via the release SHA256SUMS, so no
  # sha table lives here).
  class PythonVersion
    def initialize(python_version)
      @python_version = python_version
      version_check_format
    end

    attr_reader :python_version

    # The version's major.minor line as integers (3.13 for every 3.13.x),
    # so 4.x lines fall out naturally.
    def major_minor
      @major_minor ||= @python_version.split(".").first(2).map(&:to_i)
    end

    # The abi_line the image manifest's provides block declares (spec 03
    # §2.2 — what native-extension payloads match their version constraint
    # against): the "3.13"-style line. (The full ABI-line grammar — the
    # EXT_SUFFIX class — is TODO.python/04's; the release shard carries
    # the additive `abi` facet with the exact EXT_SUFFIX stem.)
    def abi_line
      major_minor.join(".")
    end

    # The interpreter API version the layout card declares (the schema's
    # required interpreter_api_version): python's "3.13"-style line. The
    # era-2 driver parses but does not gate on it.
    def api_version
      abi_line
    end

    # The stdlib directory name under the image's lib/ ("python3.13") —
    # CPython's unprefixed `python<X.Y>` install layout (the factory
    # configures --prefix=<mount root> with the default platlibdir).
    def libdir_name
      "python#{major_minor.join(".")}"
    end

    # The shared libpython name of an msys --enable-shared build
    # (libpython3.13.dll) — kept for the day the windows leg answers the
    # issue-40 question with "shared". The v1 windows leg builds
    # --disable-shared (no DLL facet).
    def msys_dll_name
      "libpython#{major_minor.join(".")}.dll"
    end

    def version_check_format
      return if @python_version =~ /^\d+\.\d+\.\d+$/

      raise TebakoPythonBuilder::Error.new(
        "Invalid python version format '#{@python_version}'. Expected format: x.y.z", 109
      )
    end
  end
end
