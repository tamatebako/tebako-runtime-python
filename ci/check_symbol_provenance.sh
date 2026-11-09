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
# early exit SIGPIPEs nm into a false negative). An empty capture earns
# nm's own diagnostic as evidence — a silent nm failure (a path the
# native tool cannot open, an unreadable file) must not read as
# "stripped".
symbols="$(nm "$EXE" 2>/dev/null || true)"
if [ -z "$symbols" ]; then
  echo "provenance: nm yielded no symbol table for $EXE; nm's own diagnostic:"
  nm "$EXE" 2>&1 | head -5 || true
fi

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
#
# The greps below are capture-then-test for the same reason the nm side
# is: grep -q exits on its first match, the still-writing printf dies of
# SIGPIPE, and pipefail reads the pipeline as 141 — a false "not found".
# A binutils PE objdump's --disassemble=<sym> span runs from the symbol
# to the next data island (thousands of lines — past the pipe buffer),
# so the windows leg hit exactly that (run 34759975017: main's body DOES
# call tebako_driver_boot, printed in the failure's own evidence).
dis=""
if command -v objdump >/dev/null 2>&1; then
  dis="$(objdump -d --disassemble=main "$EXE" 2>/dev/null || true)"
fi
if [ -z "$(printf '%s\n' "$dis" | grep 'main>:' || true)" ] && command -v llvm-objdump >/dev/null 2>&1; then
  dis="$(llvm-objdump -d --disassemble-symbols=main "$EXE" 2>/dev/null || true)"
fi
if [ -z "$(printf '%s\n' "$dis" | grep 'main>:' || true)" ] && command -v otool >/dev/null 2>&1; then
  # darwin last resort: /usr/bin/objdump is a deprecation shim and
  # llvm-objdump sits behind xcrun (off PATH) — otool (cctools) is
  # always there. Mach-O labels are bare `_symbol:` lines; take the body
  # up to the next label (a tail call has no ret).
  dis="$(otool -tV "$EXE" 2>/dev/null | awk '/^_main:/{f=1; next} f && /^[_a-zA-Z].*:$/{exit} f{print}' || true)"
fi
if [ -z "$dis" ]; then
  fail "no objdump could disassemble main in $EXE — the forwarding check cannot run"
elif [ -n "$(printf '%s\n' "$dis" | grep tebako_driver_boot || true)" ]; then
  note "main forwards to tebako_driver_boot (the fs TU is the entry point)"
else
  fail "main in $EXE does not reference tebako_driver_boot — CPython's own main, not the fs TU (the Makefile substitution never landed)"
  echo "disassembly evidence:"; printf '%s\n' "$dis"
fi

# --- the exe's runtime library closure is system-only (ELF legs) -------
# The audience rule in executable form: a runtime must boot on a bare
# target system, so its NEEDED set carries the platform's own libraries
# and nothing else. tebako-runtime-python#76 shipped a musl exe NEEDing
# libintl.so.8 (configure's -lintl bound the shared object where no static
# archive was provisioned) — a bare alpine cannot boot it. readelf's
# NEEDED rows are the evidence; an unreadable/missing table is a failure,
# never a silent pass. The allowlist: musl's libc, glibc's core set, and
# the loaders themselves.
if file_out="$(file "$EXE" 2>/dev/null)" && printf '%s' "$file_out" | grep -q ELF; then
  # The same cascade as the disassembly above: readelf, then the llvm
  # spelling; an ELF leg with neither is a harness gap, named as such.
  needed=""
  if command -v readelf >/dev/null 2>&1; then
    needed="$(readelf -d "$EXE" 2>/dev/null | awk '/NEEDED/ { gsub(/[][]/, ""); print $NF }' || true)"
  elif command -v llvm-readelf >/dev/null 2>&1; then
    needed="$(llvm-readelf -d "$EXE" 2>/dev/null | awk '/NEEDED/ { gsub(/[][]/, ""); print $NF }' || true)"
  else
    fail "an ELF exe and no readelf/llvm-readelf to audit its NEEDED rows — the harness must carry binutils"
  fi
  if [ -z "$needed" ] && { command -v readelf >/dev/null 2>&1 || command -v llvm-readelf >/dev/null 2>&1; }; then
    fail "the dynamic section of $EXE yielded no NEEDED rows (a static exe? the probe cannot run)"
  fi
  needed_failures_before=$failures
  while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    case "$lib" in
      libc.musl-*.so.1 | ld-musl-*.so.1 | \
      libc.so.6 | libm.so.6 | libdl.so.2 | librt.so.2 | libpthread.so.0 | \
      libutil.so.1 | \
      ld-linux-*.so.2 | ld-linux-*.so.1 | libgcc_s.so.1) : ;;
      *) fail "$EXE NEEDs $lib — a runtime .so dependency a bare system cannot satisfy (the audience rule; tebako-runtime-python#76)" ;;
    esac
  done <<< "$needed"
  [ -n "$needed" ] && [ "$failures" -eq "$needed_failures_before" ] && note "the exe's NEEDED set is system-only: $(printf '%s\n' "$needed" | tr '\n' ' ')"
elif printf '%s' "$file_out" | grep -q 'Mach-O'; then
  # The Mach-O spelling of the same gate: the v0.3.3 macos-x86_64 exe
  # loaded /usr/local/opt/gettext/lib/libintl.8.dylib (Homebrew's keg —
  # absent on a bare Mac, so the exe did not boot; otool on the published
  # asset is the evidence). otool -L's dependency rows must be macOS's
  # own dylibs and nothing else; the first output line is the exe's own
  # header and is skipped. The arm64 leg escaped by configure NOT finding
  # /opt/homebrew's keg — an accident of the search path, not a shape to
  # rely on: this arm pins the closure regardless of what configure finds.
  if command -v otool >/dev/null 2>&1; then
    needed="$(otool -L "$EXE" 2>/dev/null | awk 'NR > 1 { print $1 }' || true)"
  else
    fail "a Mach-O exe and no otool to audit its dylib rows — the harness must carry cctools"
  fi
  [ -z "$needed" ] && fail "otool -L on $EXE yielded no dylib rows (the probe cannot run)"
  needed_failures_before=$failures
  while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    case "$lib" in
      /usr/lib/* | /System/Library/*) : ;;
      *) fail "$EXE loads $lib — a runtime dylib a bare macOS cannot satisfy (the audience rule; the v0.3.3 macos-x86_64 libintl.8.dylib defect)" ;;
    esac
  done <<< "$needed"
  [ "$failures" -eq "$needed_failures_before" ] && note "the exe's dylib rows are system-only: $(printf '%s\n' "$needed" | tr '\n' ' ')"
fi

if [ "$failures" -gt 0 ]; then
  echo "::error::provenance: $failures check(s) failed"
  exit 1
fi
note "the driver stack is linked and the fs TU is the entry point — provenance OK ($EXE)"
