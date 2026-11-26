#!/usr/bin/env python3
# frozen_string_literal: true

# The on-system compute reference probe — the denominator of
# tools/boot_smoke's compute-floor ratio gate (the runner-class-relative
# tripwire; tebako#1095's follow-up). The build workflow runs this probe
# as a SIBLING STEP on the leg's own runner, under the on-system
# reference interpreter (actions/setup-python at the leg's base python
# version — the covenant's on-system provisioner), and hands the
# measurement to the boot smoke as COMPUTE_FLOOR_REFERENCE_SECONDS /
# COMPUTE_FLOOR_REFERENCE_N. An absolute seconds ceiling calibrated on
# one fleet cannot survive a runner-class move (the current
# macos-15-intel class runs EVERY x86_64 CPython — tebako's and
# python.org's alike — past the old 4.0 s ceiling; tebako#1095's closing
# verdict); the per-call-rate ratio against a same-leg reference is the
# honest gate.
#
# The workload is the boot smoke's own shape at a smaller N (fib(30),
# timed INSIDE the interpreter — provisioning, interpreter startup, and
# the harness never enter the measurement). The recursive fib's call
# count is an exact constant per N (T(n) = 2*F(n+1) - 1), so the boot
# smoke normalizes the two Ns to per-call rates before comparing — the
# ratio is a property of the built interpreter against the reference on
# the SAME runner class, never of the fleet's absolute rate.
#
# The statistic is the MEDIAN of 25 runs (best printed for the log):
# fib(30) is ~0.1 s on a healthy runner, and at that scale a best-of-3
# MIN samples the runner's instantaneous state instead of measuring its
# sustained rate — the first full-matrix run (45344792366) false-red two
# healthy macos-arm64 legs at ratio 1.87/1.95 on reference windows whose
# own three runs spread 29% (0.090/0.116/0.104), minutes of drift away
# from the tebako arm's tight seconds-scale window. The covenant's cells
# gate on medians for the same reason. The tebako arm keeps its fib(35)
# best-of-3 (tebako#1095's follow-up pins it; at 4.5 s a run
# self-averages). 25 runs cost ~3 s on the fast class, ~7 s on the slow
# one — the probe stays tiny.
#
# The boot smoke also re-runs this file ITSELF as the reference arm of
# its same-window re-probe (tools/boot_smoke's compute-floor header): a
# first-window breach re-times both arms back-to-back, under the
# interpreter the workflow hands down as COMPUTE_FLOOR_REFERENCE_PYTHON
# — run 45834307812's false red is the class that drift between the two
# separately measured windows paints onto a healthy build. The printed
# contract (n:/runs:/median:) is the re-probe's parse surface too.
#
# Usage:
#   python3 tools/compute_reference_probe.py
#
# Exit codes: 0 measured · the interpreter's own on any failure.

import statistics
import sys
import time

# The reference workload. The workflow's sibling step and tools/boot_smoke
# read these back off the printed n:/runs:/median: lines — they are this
# file's to change, in one place.
N = 30
RUNS = 25


def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)


def one():
    t0 = time.perf_counter()
    fib(N)
    return time.perf_counter() - t0


def main():
    import sysconfig

    print("COMPUTE-REFERENCE")
    print("python:", sys.version.split()[0], "at", sys.executable)
    # The build identity, for the apples-to-apples read against the
    # factory build's own opt:/CFLAGS report (tools/boot_smoke's compute
    # probe): a per-call gap that survives a stable window is a BUILD
    # difference (PGO, the tail-calling interpreter, computed gotos),
    # and these lines name it in the leg's log.
    print("configure:", (sysconfig.get_config_var("CONFIGURE_ARGS") or ""))
    print("opt:", (sysconfig.get_config_var("OPT") or ""),
          "|", (sysconfig.get_config_var("CFLAGS") or ""))
    runs = [one() for _ in range(RUNS)]
    print("n:", N)
    print("runs:", " ".join(f"{r:.3f}" for r in runs))
    print("best:", f"{min(runs):.3f}")
    print("median:", f"{statistics.median(runs):.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
