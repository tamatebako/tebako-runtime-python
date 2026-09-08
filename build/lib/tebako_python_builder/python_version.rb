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
  #
  # The line grammar is x.y.z with an optional FLAVOR suffix
  # (x.y.z-jit): a build ability rides the RELEASE LINE (the version
  # string), never a new selector axis — spec 28 §8's truffleruby
  # native/jvm precedent. "jit" is CPython 3.13+'s experimental
  # copy-and-patch JIT (--enable-experimental-jit, PEP 744): the same
  # pristine source, a different configure-time ability. The line flows
  # verbatim into the package/image names
  # (tebako-runtime-<tebako>-3.13.15-jit-<triplet>), the release index's
  # python_version identity, and the L1 manifest's provides.version;
  # provides.language_version stays the BASE version (a jit build speaks
  # exactly CPython 3.13.15 — constraints match the language level).
  class PythonVersion
    # The one owner of the line grammar (spec 00 §10): the schema's
    # catalog pattern mirrors it (asserted by the lint gate passing on
    # the same strings), scripts/upload_release.rb's package-filename
    # parse interpolates LINE_GRAMMAR_SOURCE — nothing re-derives it.
    LINE_GRAMMAR_SOURCE = '\d+\.\d+\.\d+(?:-jit)?'
    LINE_PATTERN = /\A(?<base>\d+\.\d+\.\d+)(?:-(?<flavor>jit))?\z/.freeze

    FLAVOR_JIT = "jit"

    # The JIT exists upstream in CPython 3.13+ (PEP 744); a jit line
    # below the floor is a declaration bug — named error at parse, never
    # a configure surprise mid-leg.
    JIT_FLOOR = [3, 13].freeze

    # The LLVM major each line's JIT build requires (clang + llvm-readobj
    # at exactly this major — CPython's Tools/jit/_llvm.py matches
    # `version N.` exactly). The OWNER is the extracted CPython source
    # (Tools/jit/_llvm.py's _LLVM_VERSION); this table exists so the leg
    # planner (scripts/compute_matrix.rb) can provision the toolchain
    # BEFORE any source is fetched. PythonBuild asserts the two agree on
    # every jit build (the parity arm) — a drifted table is a named build
    # error, never a silently wrong toolchain.
    JIT_LLVM_MAJORS = { [3, 13].freeze => 18, [3, 14].freeze => 19 }.freeze

    def initialize(python_version)
      @python_version = python_version
      parse_line
    end

    attr_reader :python_version, :base_version, :flavor

    def jit?
      @flavor == FLAVOR_JIT
    end

    # The LLVM major this jit line's build requires; nil for unflavored
    # lines; a named error for a jit line whose toolchain this factory
    # does not know yet (a new CPython line earns its table entry in the
    # PR that opens it).
    def jit_llvm_major
      return nil unless jit?

      JIT_LLVM_MAJORS.fetch(major_minor) do
        raise TebakoPythonBuilder::Error.new(
          "no known JIT toolchain for the #{major_minor.join(".")} line — " \
          "JIT_LLVM_MAJORS (mirroring the source's Tools/jit/_llvm.py) carries #{JIT_LLVM_MAJORS.keys.map { |k| k.join(".") }.join(", ")}",
          109
        )
      end
    end

    # The version's major.minor line as integers (3.13 for every 3.13.x,
    # flavored or not), so 4.x lines fall out naturally.
    def major_minor
      @major_minor ||= base_version.split(".").first(2).map(&:to_i)
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

    private

    # Parse the line into base + flavor, enforcing the grammar and the
    # JIT floor. Named errors, exit 109 — a malformed line is a config
    # bug, never a silently misparsed name.
    def parse_line
      match = LINE_PATTERN.match(@python_version)
      unless match
        raise TebakoPythonBuilder::Error.new(
          "Invalid python version format '#{@python_version}'. Expected format: x.y.z or x.y.z-jit", 109
        )
      end
      @base_version = match[:base]
      @flavor = match[:flavor]
      return unless jit? && (major_minor <=> JIT_FLOOR) < 0

      raise TebakoPythonBuilder::Error.new(
        "the jit flavor needs CPython >= #{JIT_FLOOR.join(".")} (PEP 744 landed in 3.13); " \
        "'#{@python_version}' is a declaration bug", 109
      )
    end
  end
end
