#!/usr/bin/env python3
# frozen_string_literal: true

# Socket-mode probe for the staged tebako windows runtime — the msys pip
# connect pathology (WinError 10035, WSAEWOULDBLOCK surfaced through
# pip's vendored urllib3 non-blocking connect).
#
# The symptom this probe discriminates (tebako-packages/xml2rfc runs
# 35326025152 @ v0.2.2 and 35334306542 @ v0.2.3, x86_64-windows-ucrt):
# `python -m pip download` failed EVERY connection within milliseconds
# with "[WinError 10035] A non-blocking socket operation could not be
# completed immediately" (all five pip retries inside ~2ms), while a
# stdlib BLOCKING-socket urlopen from the SAME runtime reached pypi.org
# seconds later. The signature isolates CPython's socket-timeout wait
# engine: Modules/socketmodule.c sock_call_ex() waits via
# internal_select() before/after every non-blocking call when a socket
# carries a positive timeout (settimeout(15) — exactly what pip's
# urllib3 does; blocking mode never enters the wait). internal_select()
# prefers poll() whenever configure defined HAVE_POLL — on the
# mingw-w64/ucrt64 build the generic AC_CHECK_FUNC(poll) probe passes
# against the CRT's poll emulation, a codepath no mainstream Windows
# CPython exercises (MSVC's pyconfig never defines HAVE_POLL; the
# python.org shape waits with winsock select()). When the emulation
# mis-reports for a WSA SOCKET handle, sock_call_ex reaches its
# errorhandler() with the stale WSAGetLastError()=10035 the just-failed
# connect() left behind — the instant, misleading 10035.
#
# Modes (each prints one verdict line; the overall verdict is the AND of
# the two mechanism modes, timeout-connect and nonblocking-select-wait):
#
#   blocking-urlopen        the known-good control: urllib.request.urlopen
#                           with NO timeout (the task's baseline — worked
#                           in the broken runtime too)
#   timeout-connect         socket.create_connection(timeout=15) — the
#                           exact pip/urllib3 layer. PASS = connects, or
#                           raises TimeoutError/any real socket error no
#                           earlier than the deadline's tail (the wait
#                           engine ran). FAIL = an instant WSAEWOULDBLOCK
#                           (10035) — the pathology.
#   nonblocking-select-wait the engine one layer down: setblocking(False)
#                           + connect_ex (instant 10035 here is CORRECT
#                           non-blocking semantics), then select() for
#                           writability within the deadline, then
#                           SO_ERROR. PASS = writable in time and the
#                           connect completed (or failed with a REAL
#                           error, e.g. refused — the wait worked).
#   diagnostics             select.poll availability (the HAVE_POLL
#                           marker), fresh-socket write-readiness (the
#                           winsock quirk the engine's first iteration
#                           relies on), elapsed times.
#
# Usage:
#   inside a staged runtime:  TEBAKO_RUNTIME_IMAGE=<img> <runtime.exe> <this file>
#   a plain interpreter:      python3 <this file>          (msys2 python
#                             comparison; any CPython >= 3.8)
#
# Exit codes: 0 every mechanism mode passed · 3 at least one failed
# (named on stdout, never silent).

import errno
import select
import socket
import sys
import time
import urllib.request

HOST = "pypi.org"
PORT = 443
DEADLINE = 15.0
WSAEWOULDBLOCK = 10035
WSAEINPROGRESS = 10036

# The in-flight codes connect_ex may legitimately return for a pending
# non-blocking connect (winsock spells them 10035/10036; POSIX via errno).
IN_FLIGHT = {WSAEWOULDBLOCK, WSAEINPROGRESS,
             errno.EWOULDBLOCK, errno.EINPROGRESS, errno.EALREADY}

VERDICTS = {}


def record(mode, verdict, detail):
    VERDICTS[mode] = verdict
    print("MODE {}: {} — {}".format(mode, verdict, detail))


def blocking_urlopen():
    url = "https://{}:{}/simple/".format(HOST, PORT)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=None) as response:
            status = response.status
        record("blocking-urlopen", "PASS",
               "https {} after {:.2f}s (control mode — not part of the verdict)".format(
                   status, time.monotonic() - started))
    except Exception as exc:  # the control must not fail the probe on its own
        record("blocking-urlopen", "NOTE",
               "{}: {} after {:.2f}s (control mode — if this fails alongside the "
               "mechanism modes, the leg has no egress, not a wait-engine defect)".format(
                   type(exc).__name__, exc, time.monotonic() - started))


def timeout_connect():
    # The pip/urllib3 layer: create_connection with a positive timeout
    # (socket.create_connection sets it via settimeout — the non-blocking
    # + select-wait shape). The verdict keys on WHEN and WHAT failed:
    # an instant 10035 is the pathology; a post-deadline TimeoutError or
    # a real post-wait error (refused/unreachable) means the engine ran.
    started = time.monotonic()
    try:
        sock = socket.create_connection((HOST, PORT), timeout=DEADLINE)
        elapsed = time.monotonic() - started
        sock.close()
        record("timeout-connect", "PASS", "connected after {:.2f}s".format(elapsed))
        return
    except socket.timeout as exc:
        elapsed = time.monotonic() - started
        verdict, why = ("PASS", "TimeoutError after {:.2f}s — the wait engine ran".format(elapsed))
        if elapsed < DEADLINE * 0.5:
            verdict, why = ("FAIL", "premature TimeoutError after {:.2f}s: {}".format(elapsed, exc))
    except OSError as exc:
        elapsed = time.monotonic() - started
        winerror = getattr(exc, "winerror", None)
        errno_ = getattr(exc, "errno", None)
        code = winerror if winerror is not None else errno_
        if code in (WSAEWOULDBLOCK, errno.EWOULDBLOCK) and elapsed < DEADLINE * 0.5:
            verdict, why = (
                "FAIL",
                "instant WSAEWOULDBLOCK after {:.3f}s (winerror={}, errno={}) — the wait "
                "engine never engaged: {}".format(elapsed, winerror, errno_, exc),
            )
        else:
            verdict, why = (
                "PASS",
                "real error after {:.2f}s (winerror={}, errno={}) — the wait engine ran and "
                "surfaced a genuine connect failure (host reachability), not 10035: {}".format(
                    elapsed, winerror, errno_, exc),
            )
    except Exception as exc:  # noqa: BLE001 — named, never silent
        elapsed = time.monotonic() - started
        verdict, why = ("FAIL", "{} after {:.2f}s: {}".format(type(exc).__name__, elapsed, exc))
    record("timeout-connect", verdict, why)


def ipv4_target():
    # Deterministic single address for the raw mode (create_connection
    # iterates getaddrinfo itself; here we pin one family).
    infos = socket.getaddrinfo(HOST, PORT, 0, socket.SOCK_STREAM)
    for family, _socktype, _proto, _canonname, sockaddr in infos:
        if family == socket.AF_INET:
            return sockaddr
    return infos[0][4]


def nonblocking_select_wait():
    # The engine one layer below timeout-connect: a raw non-blocking
    # connect (instant 10035 is CORRECT here), then the select-wait for
    # writability, then SO_ERROR — the sequence sock_call_ex performs.
    target = ipv4_target()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    started = time.monotonic()
    try:
        sock.setblocking(False)
        rc = sock.connect_ex(target)
        elapsed = time.monotonic() - started
        if rc == 0:
            record("nonblocking-select-wait", "PASS",
                   "connect_ex completed immediately ({:.3f}s)".format(elapsed))
            return
        if rc not in IN_FLIGHT:
            record("nonblocking-select-wait", "NOTE",
                   "connect_ex refused in-flight ({}, {:.3f}s) — egress problem, "
                   "wait engine untested".format(rc, elapsed))
            return
        # internal_select's shape: writability plus the exception set (a
        # connection failure notifies as an error, socketmodule.c's own
        # comment) — the diagnostic mirrors it, not plain writability.
        _readable, writable, exceptional = select.select([], [sock], [sock], DEADLINE)
        waited = time.monotonic() - started
        if not writable:
            record("nonblocking-select-wait", "FAIL",
                   "select() never reported writability within {:.0f}s (waited {:.2f}s) — "
                   "the wait layer is broken for WSA sockets".format(DEADLINE, waited))
            return
        so_error = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        if so_error == 0:
            record("nonblocking-select-wait", "PASS",
                   "connect_ex {} -> select ready after {:.2f}s -> SO_ERROR=0 "
                   "(the wait layer works)".format(rc, waited))
        else:
            record("nonblocking-select-wait", "PASS",
                   "connect_ex {} -> select ready after {:.2f}s -> SO_ERROR={} "
                   "(real post-wait error; the wait layer works)".format(rc, waited, so_error))
    except Exception as exc:  # noqa: BLE001 — named, never silent
        record("nonblocking-select-wait", "FAIL",
               "{}: {} after {:.2f}s".format(type(exc).__name__, exc, time.monotonic() - started))
    finally:
        sock.close()


def diagnostics():
    has_poll = hasattr(select, "poll")
    # A FRESH unconnected socket as internal_select sees it for connect:
    # writability plus the exception set (the poll-branch comment —
    # "the socket becomes writable on connection success, but a
    # connection failure is notified as an error").
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.setblocking(False)
        _r, writable, exceptional = select.select([], [probe], [probe], 0.25)
        fresh_ready = "writable" if writable else ("exceptional" if exceptional else "not-ready")
    finally:
        probe.close()
    print("DIAG select.poll available: {}".format(has_poll))
    print("DIAG   (poll available => socketmodule compiled with HAVE_POLL — the "
          "mingw CRT poll() emulation backs the socket-timeout wait engine)")
    print("DIAG fresh unconnected socket select-ready: {}".format(fresh_ready))
    print("DIAG resolved target: {}".format(ipv4_target()))


def main():
    print("SOCKET-PROBE target={}:{} deadline={:.0f}s python={}".format(
        HOST, PORT, DEADLINE, sys.version.split()[0]))
    diagnostics()
    blocking_urlopen()
    timeout_connect()
    nonblocking_select_wait()
    overall = "PASS" if VERDICTS.get("timeout-connect") == "PASS" and \
        VERDICTS.get("nonblocking-select-wait") == "PASS" else "FAIL"
    print("SOCKET-PROBE OVERALL: {}".format(overall))
    return 0 if overall == "PASS" else 3


if __name__ == "__main__":
    sys.exit(main())
