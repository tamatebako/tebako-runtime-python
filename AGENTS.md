# AGENTS.md — tebako-runtime-python

The binding rules are the ecosystem's: **tamatebako/AGENTS.md** (the
workspace root) — read it first. The short version as applied here:

- **Draft PRs only.** No merges to `main`, no tags, no releases without
  the owner's explicit go-ahead. Nothing publishes from this repo until
  the TODO.python chain is proven (the xml2rfc payload, 03).
- **Prebuilt artifacts flow downward.** This factory CONSUMES published
  releases — CPython source tarballs from tamatebako/python, the link
  unit from tamatebako/tebako — pinned in `contract.yml`. Never a source
  checkout of a sibling repo, in CI or locally.
- **SSOT for versions and pins.** Versions, tags, SHAs live in
  `contract.yml` (catalog + pins) and `.github/matrix.json` (env
  vocabulary) — never hardcoded in workflow YAML or scripts.
- **YAML** for all authored config/manifests; named errors and named
  exit codes, never silent fallbacks.

## Repo status: builds green, unpublished

`tools/build_runtime` is implemented (the tebako-runtime-ruby `build/lib`
port): fetch/verify → configure/make → driver link → env-image pack →
packaging → sidecars, gated by `ci/check_symbol_provenance.sh` and
`tools/boot_smoke`. CI carries the ruby factory's shape:
`_build-platform.yml` + the four `build-*.yml` triggers, and
`publish.yml` drives `scripts/upload_release.rb` per platform. The
macos-arm64 leg is dogfooded locally green (7/7 boot-smoke scenarios).

Nothing has published: releases stay draft-gated until the TODO.python
chain is proven (the xml2rfc payload, 03). The pinned
`link_unit_release: "v2.1.10"` carries all three libtfs-preload boot
fixes — the `fcntl` interpose (tamatebako/tebako#524, the CPython
FileIO boot blocker), the BOOT_LIVE gate + raw early-boot passthrough
(tamatebako/tebako#527, the static-jemalloc boot deadlock that wedged
the gnu legs), and the `fcntl64` export (tamatebako/tebako#529 —
glibc's `_FILE_OFFSET_BITS=64` redirect made the gnu interpreter's
PEP-446 cloexec probe bypass the shim and die EBADF at
init_fs_encoding). The POSIX boot-smoke CI legs were red-by-design on
the old v2.1.5 pin and are expected green on this one. The windows row
is descoped out of the 02 matrix (TODO.python/05 — CPython upstream
has zero mingw support; the port is a tamatebako/python msys2/ucrt64
patch
series), and `tools/boot_smoke` hard-kills a wedged child against a
CLOCK_MONOTONIC deadline instead of wedging with it. The
linked-driver decision and the preload-shim re-exec rationale are
recorded in README.md — do not reopen them here; the wrapper pattern
(spec 29) is the java stream's.

## Repo-local gotchas

- Tooling is **Ruby** (stdlib-first; gems only via `Gemfile`).
  Ecosystem §12 rules apply: autoload only, no `require_relative`, no
  `send`/`instance_variable_get`/`respond_to?` metaprogramming.
- `Gemfile.lock` is gitignored (factory convention — resolutions float).
- `contract.yml` is validated by `scripts/check_contract.rb` against
  `schema/contract.schema.yml` (`bundle exec`). A contract bump edits
  `contract.yml` and the compiled-in `TEBAKO_CONTRACT_VERSION` in the
  same commit (the driver-source parity arm of the check lands with the
  first build).
- CI containers are `ghcr.io/tamatebako/tpkg-builder-*`
  (tebako-ci-containers) only; the archived v1 `tebako-<platform>`
  images are never referenced here. Windows/macOS legs are
  runner-native.
- `gh pr create` bodies: always `--body-file` — inline `--body` with
  backticks executes them (ecosystem §13).
