#!/usr/bin/env bash
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

# ci/provision_jit_toolchain.sh — per-leg JIT toolchain provisioning for
# the container build legs (the macos legs brew install llvm@N in the
# workflow instead). CPython's copy-and-patch JIT compiles its stencils at
# BUILD time with an exact-major LLVM toolchain (clang + llvm-readobj) and
# a host python >= 3.11 (Tools/jit/README.md); both are build-time ONLY —
# the shipped runtime gains no system dependency. The required major comes
# from the matrix's jit_llvm key (planned from
# PythonVersion::JIT_LLVM_MAJORS); PythonBuild's gate re-reads the
# extracted source's Tools/jit/_llvm.py and fails the leg on drift, so
# this script can never provision the wrong toolchain silently.
#
# Platform dispatch rides the container's baked TPKB_FAMILY:
#   linux-gnu   ubuntu focal: apt.llvm.org's llvm-toolchain-<codename>-N
#               ships clang-N / llvm-readobj-N; the host python >= 3.11
#               comes from a PINNED, sha256-verified
#               python-build-standalone tarball (astral-sh) — focal's own
#               python3 is 3.8 and deadsnakes' focal dist was EMPTIED
#               (focal left standard support 2025-04; its Packages index
#               is a 20-byte empty gzip as of 2026-09 — the InRelease
#               still fetches, so a deadsnakes deb line fails SILENTLY at
#               install time). The standalone python lands as
#               /usr/local/bin/python3.13 — the system python3 is NEVER
#               replaced, and configure's PYTHON_FOR_REGEN search finds
#               the versioned name first.
#   linux-musl  alpine 3.21: apk llvmN (+ clangN — 19's clang is already
#               baked into the tpkg-builder image). The tools live in
#               /usr/lib/llvmN/bin, off PATH; the build gate PATH-augments
#               its configure/make children to them.
#
# Usage: ci/provision_jit_toolchain.sh LLVM_MAJOR
# Exit codes: 0 provisioned · 2 usage/unknown family.
set -euo pipefail

MAJOR="${1:-}"
case "$MAJOR" in
  '' | *[!0-9]*)
    echo "provision_jit_toolchain: usage: ci/provision_jit_toolchain.sh LLVM_MAJOR (numeric)" >&2
    exit 2
    ;;
esac

note() { echo "provision_jit_toolchain: $*"; }

# A host python >= 3.11 resolvable the way configure searches
# (versioned names first, bare python3 last).
have_host_python() {
  local py
  for py in python3.14 python3.13 python3.12 python3.11 python3; do
    if command -v "$py" >/dev/null 2>&1 &&
       "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

case "${TPKB_FAMILY:-}" in
  linux-gnu)
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
    [ -n "$codename" ] || {
      echo "provision_jit_toolchain: /etc/os-release carries no VERSION_CODENAME" >&2
      exit 2
    }

    list="/etc/apt/sources.list.d/llvm${MAJOR}.list"
    if [ ! -f "$list" ]; then
      # Retry connect flakes (a runner transient is a leg failure
      # otherwise — observed: arm64 gnu leg, curl (7) into an empty gpg).
      # NO --retry-all-errors: focal's curl 7.68 predates it (7.71).
      curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused \
        https://apt.llvm.org/llvm-snapshot.gpg.key |
        gpg --yes --dearmor -o /usr/share/keyrings/llvm.gpg
      echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/${codename}/ llvm-toolchain-${codename}-${MAJOR} main" \
        > "$list"
    fi
    apt-get -o Acquire::Retries=3 update
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends "clang-${MAJOR}" "llvm-${MAJOR}"

    if ! have_host_python; then
      # The pinned python-build-standalone host python (see the header):
      # 3.13 satisfies configure's PYTHON_FOR_REGEN search for both jit
      # lines (3.13 and 3.14), and python3.13 lands on PATH ahead of the
      # system python3 without replacing it.
      pbs_tag="20260901"
      pbs_name="cpython-3.13.15+${pbs_tag}-$(uname -m)-unknown-linux-gnu-install_only"
      case "$(uname -m)" in
        x86_64)  pbs_sha="0651dd7157d3debf769e15a52c1de9de7fbcdc36ba72faf79fde3c44f14d9461" ;;
        aarch64) pbs_sha="76ed18125286d7dc96ce24023d1e319dbd55a89a767102411b1ea23846113f69" ;;
        *)
          echo "provision_jit_toolchain: no pinned host python for arch $(uname -m)" >&2
          exit 2
          ;;
      esac
      curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused \
        "https://github.com/astral-sh/python-build-standalone/releases/download/${pbs_tag}/${pbs_name}.tar.gz" \
        -o /tmp/host-python.tar.gz
      echo "${pbs_sha}  /tmp/host-python.tar.gz" | sha256sum -c -
      tar -xzf /tmp/host-python.tar.gz -C /opt
      ln -sf /opt/python/bin/python3.13 /usr/local/bin/python3.13
      have_host_python || {
        echo "provision_jit_toolchain: standalone python installed but no python >= 3.11 resolves" >&2
        exit 2
      }
    fi
    ;;
  linux-musl)
    apk add --no-cache "llvm${MAJOR}"
    # clang19 (with clang19-libclang) is baked into the tpkg-builder-musl
    # image; only other majors need the apk clang.
    if [ "$MAJOR" != "19" ]; then
      apk add --no-cache "clang${MAJOR}"
    fi
    have_host_python || {
      echo "provision_jit_toolchain: no host python >= 3.11 (the musl image bakes python3 3.12 — drifted?)" >&2
      exit 2
    }
    ;;
  *)
    echo "provision_jit_toolchain: unknown TPKB_FAMILY '${TPKB_FAMILY:-<unset>}' — this script runs inside the tpkg-builder containers" >&2
    exit 2
    ;;
esac

# Evidence: what resolves, where (the build gate PATH-augments to the
# versioned lib dirs, so an off-PATH install is a provisioned install).
for tool in "clang-${MAJOR}" "llvm-readobj-${MAJOR}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    note "$tool: $(command -v "$tool")"
  fi
done
for dir in "/usr/lib/llvm-${MAJOR}/bin" "/usr/lib/llvm${MAJOR}/bin"; do
  [ -x "${dir}/clang" ] && note "${dir}/clang + llvm-readobj (off-PATH; the build gate augments PATH)"
done
for py in python3.14 python3.13 python3.12 python3.11 python3; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    note "host python: $py ($("$py" --version 2>&1))"
    break
  fi
done
note "LLVM ${MAJOR} toolchain provisioned (${TPKB_FAMILY})"
