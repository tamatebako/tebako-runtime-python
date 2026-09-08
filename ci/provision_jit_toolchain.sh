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
#               ships clang-N / llvm-readobj-N; the host python comes from
#               deadsnakes (python3.11 — the system python3 is NEVER
#               replaced; configure's PYTHON_FOR_REGEN search finds the
#               versioned name first).
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
      curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key |
        gpg --yes --dearmor -o /usr/share/keyrings/llvm.gpg
      echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/${codename}/ llvm-toolchain-${codename}-${MAJOR} main" \
        > "$list"
    fi
    apt-get update
    apt-get install -y --no-install-recommends "clang-${MAJOR}" "llvm-${MAJOR}"

    if ! have_host_python; then
      # deadsnakes (focal's own python3 is 3.8 — under the JIT floor).
      curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" |
        gpg --yes --dearmor -o /usr/share/keyrings/deadsnakes.gpg
      echo "deb [signed-by=/usr/share/keyrings/deadsnakes.gpg] http://ppa.launchpad.net/deadsnakes/ppa/ubuntu ${codename} main" \
        > /etc/apt/sources.list.d/deadsnakes.list
      apt-get update
      apt-get install -y --no-install-recommends python3.11
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
note "LLVM ${MAJOR} toolchain provisioned (${TPKB_FAMILY})"
