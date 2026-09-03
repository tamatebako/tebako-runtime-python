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

# ci/check_symbol_provenance.sh — the symbol-provenance assert for a built
# tebako python runtime (the spec 18 C4 analog; tebako-runtime-ruby's
# script is the model). This factory's shadow class is not the ruby
# toolchain stub (there is none — the fs TU compiles straight into the
# exe) but the QUIETLY PLAIN interpreter: a link that dropped
# Programs/tebako_python.o still yields a working python that fails
# nothing until the first image boot. The fingerprints:
#
#   1. nm: the exe defines the driver's C ABI (tebako_driver_boot,
#      tebako_mount_point, tebako_driver_contract_version) as text/data
#      symbols — libtebako_driver.a was pulled in.
#   2. nm: the exe defines `main` — never stripped (Builder#finalize
#      copies, never strips, on every platform: the symbol table IS this
#      evidence on PE too).
#   3. the disassembly of `main` references tebako_driver_boot — the fs
#      TU (build/resources/tebako_python_main.c) is the entry point that
#      forwards to the driver, not CPython's own Programs/python.c main.
#
# Usage: ci/check_symbol_provenance.sh --exe PATH
set -euo pipefail

EXE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --exe) EXE="$2"; shift 2 ;;
    *) echo "check_symbol_provenance: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$EXE" ] || { echo "check_symbol_provenance: --exe PATH is required" >&2; exit 2; }
[ -s "$EXE" ] || { echo "::error::provenance: exe $EXE is missing or empty"; exit 1; }

failures=0
fail() { echo "::error::provenance: $*"; failures=$((failures + 1)); }
note() { echo "provenance: $*"; }

# capture-then-test everywhere (never nm | grep -q under pipefail: grep's
# early exit SIGPIPEs nm into a false negative).
symbols="$(nm "$EXE" 2>/dev/null || true)"

for sym in tebako_driver_boot tebako_mount_point tebako_driver_contract_version main; do
  line="$(printf '%s\n' "$symbols" | grep -E "[TtWwDd] _?${sym}\$" || true)"
  if [ -z "$line" ]; then
    fail "$sym is not a defined symbol in $EXE — the driver stack / fs TU was never linked (the plain-interpreter shadow)"
    echo "nm evidence (all tebako-ish symbols):"
    printf '%s\n' "$symbols" | grep -i tebako || echo "(none — stripped? Builder#finalize never strips)"
  else
    note "$sym defined in the exe: $line"
  fi
done

# --- main forwards to tebako_driver_boot --------------------------------
# Output-driven tool selection (tebako-runtime-ruby's cascade): an
# objdump that cannot honor --disassemble=<sym> yields no body and the
# llvm-objdump spelling is tried next; neither producing the body is a
# failure — never a silently skipped provenance check.
dis=""
if command -v objdump >/dev/null 2>&1; then
  dis="$(objdump -d --disassemble=main "$EXE" 2>/dev/null || true)"
fi
if ! printf '%s\n' "$dis" | grep -q 'main>:' && command -v llvm-objdump >/dev/null 2>&1; then
  dis="$(llvm-objdump -d --disassemble-symbols=main "$EXE" 2>/dev/null || true)"
fi
if ! printf '%s\n' "$dis" | grep -q 'main>:' && command -v otool >/dev/null 2>&1; then
  # darwin last resort: /usr/bin/objdump is a deprecation shim and
  # llvm-objdump sits behind xcrun (off PATH) — otool (cctools) is
  # always there. Mach-O labels are bare `_symbol:` lines; take the body
  # up to the next label (a tail call has no ret).
  dis="$(otool -tV "$EXE" 2>/dev/null | awk '/^_main:/{f=1; next} f && /^[_a-zA-Z].*:$/{exit} f{print}' || true)"
fi
if [ -z "$dis" ]; then
  fail "no objdump could disassemble main in $EXE — the forwarding check cannot run"
elif printf '%s\n' "$dis" | grep -q tebako_driver_boot; then
  note "main forwards to tebako_driver_boot (the fs TU is the entry point)"
else
  fail "main in $EXE does not reference tebako_driver_boot — CPython's own main, not the fs TU (the Makefile substitution never landed)"
  echo "disassembly evidence:"; printf '%s\n' "$dis"
fi

if [ "$failures" -gt 0 ]; then
  echo "::error::provenance: $failures check(s) failed"
  exit 1
fi
note "the driver stack is linked and the fs TU is the entry point — provenance OK ($EXE)"
