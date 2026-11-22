#!/usr/bin/env python3
# frozen_string_literal: true

# Spawn-multiprocessing probe for the staged tebako windows runtime — the
# tebako-runtime-python#105 regression gate: the shipped
# _multiprocessing must export sem_unlink, because the stdlib imports it
# unconditionally.
#
# The defect this pins (tebako-packages/pydata conformance arm 3, run
# 45007247506, x86_64-windows-ucrt): cpython 3.14's
# Lib/multiprocessing/synchronize.py does
#
#   from _multiprocessing import SemLock, sem_unlink
#
# UNCONDITIONALLY (the try only guards platforms with no functioning
# sem_open). Upstream's win32 build always provides the export — on
# MS_WINDOWS Modules/_multiprocessing/multiprocessing.h defines
# HAVE_MP_SEMAPHORE outright and semaphore.c spells SEM_UNLINK(name) a
# no-op 0 (win32 named semaphores need no unlink). The factory's
# windows-ucrt64 build rides the mingw/autoconf path instead: configure's
# sem_open probe fails, POSIX_SEMAPHORES_NOT_ENABLED is defined, the
# methoddef's guard drops the export, and everything touching
# synchronize.py (Lock, Queue, Pool) dies at import. msys2's
# mingw-w64-python carries the fix as patch 0038; the factory carries it
# as patches/3.14/multiprocessing_sem_unlink_msys.patch.
#
# Arms (each prints one verdict line; the overall verdict is the AND):
#
#   import-surface  synchronize.py's exact import line. PASS = SemLock
#                   and sem_unlink both resolve. FAIL = the #105
#                   signature (ImportError naming sem_unlink).
#   spawn-pool      the end-to-end behavior windows actually runs: a
#                   spawn-context Pool(2).map over a picklable top-level
#                   function must return the mapped results (spawn is
#                   win32's only start method, and every worker re-boots
#                   this runtime through the driver). FAIL = any
#                   exception (the synchronize import dies the same way
#                   here) or a wrong result.
#
# A wedged worker (a Pool child that never boots) is the harness's
# domain, not this probe's: boot_smoke's hard deadline kills and fails
# the scenario, exactly its wedged-runtime discipline.
#
# Usage:
#   inside a staged runtime:  TEBAKO_RUNTIME_IMAGE=<img> <runtime.exe> <this file>
#   a plain interpreter:      python3 <this file>          (comparison —
#                             any CPython >= 3.8; the stock win32 and
#                             POSIX shapes both pass)
#
# Exit codes: 0 both arms passed · 3 at least one failed (named on
# stdout, never silent).

import sys

VERDICTS = {}


def record(arm, verdict, detail):
    VERDICTS[arm] = verdict
    print("MODE {}: {} — {}".format(arm, verdict, detail), flush=True)


def square(x):
    # The Pool payload: top-level so the spawn children resolve it by
    # qualified name after re-importing this script as __main__.
    return x * x


def import_surface():
    # synchronize.py's exact unconditional import (the #105 signature).
    try:
        from _multiprocessing import SemLock, sem_unlink  # noqa: F401
    except ImportError as exc:
        record("import-surface", "FAIL",
               "{} — synchronize.py cannot import on this runtime: every "
               "multiprocessing use (Lock/Queue/Pool) dies here "
               "(tebako-runtime-python#105)".format(exc))
        return
    record("import-surface", "PASS",
           "from _multiprocessing import SemLock, sem_unlink")


def spawn_pool():
    try:
        import multiprocessing as mp
        ctx = mp.get_context("spawn")
        with ctx.Pool(2) as pool:
            result = pool.map(square, range(4))
    except Exception as exc:  # noqa: BLE001 — named, never silent
        record("spawn-pool", "FAIL",
               "{}: {} — a spawn-context Pool(2) cannot run on this "
               "runtime".format(type(exc).__name__, exc))
        return
    if result == [0, 1, 4, 9]:
        record("spawn-pool", "PASS",
               "spawn Pool(2).map(square, range(4)) -> {}".format(result))
    else:
        record("spawn-pool", "FAIL",
               "spawn Pool(2).map returned {} — expected [0, 1, 4, 9]".format(result))


def diagnostics():
    print("DIAG python: {}".format(sys.version.split()[0]), flush=True)
    print("DIAG executable: {}".format(sys.executable), flush=True)
    try:
        import multiprocessing as mp
        print("DIAG start methods: {}".format(mp.get_all_start_methods()), flush=True)
    except Exception as exc:  # noqa: BLE001 — diagnostics never fail the probe
        print("DIAG start methods: unavailable ({}: {})".format(type(exc).__name__, exc),
              flush=True)


def main():
    print("MP-SPAWN-PROBE python={}".format(sys.version.split()[0]), flush=True)
    diagnostics()
    import_surface()
    spawn_pool()
    overall = "PASS" if VERDICTS.get("import-surface") == "PASS" and \
        VERDICTS.get("spawn-pool") == "PASS" else "FAIL"
    print("MP-SPAWN-PROBE OVERALL: {}".format(overall), flush=True)
    return 0 if overall == "PASS" else 3


if __name__ == "__main__":
    sys.exit(main())
