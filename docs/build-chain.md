# The build chain — architecture and invariants

The staged build (fetch/verify → configure/make → driver link →
env-image pack → sidecars) lives in `tools/build_runtime`; the README's
"The unpatched interpreter: preload shim + re-exec" section owns the
visibility mechanism. This file records the cross-cutting planes that
mechanism depends on, with their evidence. First plane: the macOS
signing profile.

## The macOS signing profile and the dyld stripping plane (tebako#1117)

The audit question (tebako#1117, opened from the tebako-runtime-r#5
incident): does the runtime exe (a) re-exec with
`DYLD_INSERT_LIBRARIES` armed AND (b) need the shim for core IO
visibility? For this factory both answers are YES, by construction:

- **(a) the re-exec exists.** `build/resources/tebako_python_main.c`
  (the fs TU) boots the driver in-process, then re-execs the exe with
  the driver-armed env — `DYLD_INSERT_LIBRARIES` naming the
  materialized in-image `libtfs_preload.dylib` on macOS (README's
  two-incarnation composition).
- **(b) the shim is the only visibility.** CPython is unpatched (the
  tamatebako/python zero-patch contract): every interpreter read of the
  mounted tree — the encodings import, the stdlib, site-packages — is
  plain libc IO that only the shim serves. Ruby's patched-IO exemption
  does not exist here.

So the profile (`ci/runtime.entitlements`) MUST carry
`com.apple.security.cs.allow-dyld-environment-variables`: on a
hardened-runtime exe without the grant, dyld strips the variable at
the re-exec (macOS 14 — silently, by design), the second incarnation
runs shimless, and the boot dies
`ModuleNotFoundError: No module named 'encodings'` — the exact
tebako-runtime-r#5 class ("unable to open the base package"), one
interpreter over.

### Why the omission never fired before this audit (the fragile part)

Every python runtime published to date ships **unsigned**
(`APPLE_SIGNING_ENABLED` has never been armed in this repo — verified
on the published v0.3.5 `macos-arm64` exe: `flags=0x20002
(adhoc,linker-signed)`, no TeamIdentifier). dyld strips
`DYLD_INSERT_LIBRARIES` only for hardened-runtime targets, so an
adhoc exe keeps the insertion on every macOS generation and the boot
works — that, and nothing else, is why the pydata payload's demo ran
green on darwin-23 (native extensions reading in-image data). It is
the "DYLD not stripped for this profile shape" answer tebako#1117
names as fragile: the day the signing gate arms, the same bytes take
the hardened runtime and the R#5 class fires on macOS 14. The grant
therefore lands **while the legs still ship unsigned** — ahead of the
gate, exactly where the shape needs it.

### The evidence (darwin-23 = macOS 14.1.1, 23B81, arm64)

| Probe | Result |
|---|---|
| Published v0.2.7 pair (the store's sha256-verified bytes), `TEBAKO_RUNTIME_IMAGE=… exe -c 'import json,zlib,ssl; open(<in-image path>)'` | green — stdlib imports + 14132-byte libc read of an in-image path (the pydata-demo-era shape: unsigned ⇒ insertion honored) |
| Published v0.3.5 `macos-arm64` exe, `codesign -d` | adhoc linker-signed, no hardened runtime, no entitlements — the signing gate was never armed |
| The same-class exe adhoc-signed `--options runtime` with the OLD two-key profile, same probe | **dies** — `ModuleNotFoundError: No module named 'encodings'` (the stripping, reproduced) |
| The same exe re-signed adding ONLY `allow-dyld-environment-variables` | green — stdlib + the libc in-image read served |

### The policing (why a static assertion, not a runner)

The macos-15 runners' dyld TOLERATES a missing dyld-env grant (their
dyld keeps the variables), so no CI runner can police this class at
exec time — the boot smoke's shim-service scenarios (`boot`'s stdlib
imports off the mount) stay green there either way.
`ci/macos-sign-notarize-runtime.sh` therefore asserts the embedded
profile statically — three `<true/>` values AND each key by name —
in-leg, where the bytes still are. A macOS-14 exec canary (the R
factory's publish-leg shape) is the named follow-up for this repo's
acceptance workflow.
