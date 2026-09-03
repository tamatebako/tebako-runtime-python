# tebako-runtime-python

Builds and publishes the prebuilt tebako CPython runtime packages
(`tebako-runtime-<tebako-version>-<python-version>-<triplet>[.exe]`) that
the tebako bootstrap/shim resolves at press/run time. Modeled on
[tebako-runtime-ruby](https://github.com/tamatebako/tebako-runtime-ruby)
(TODO.python/02).

**Status: builds green, unpublished.** The full chain — fetch/verify →
configure/make → driver link → env-image pack → packaging → provenance
gate → boot smoke — is implemented in `build/lib/tebako_python_builder/`
and wired into CI (`build-*.yml` × 4 over `_build-platform.yml`, the
ruby factory's coordinator shape; `publish.yml` carries the release
machinery via `scripts/upload_release.rb`). The macos-arm64 leg is
dogfooded locally green: 7/7 boot-smoke scenarios (imports of
json/ssl/zlib off the mounted image, the dlopen extension path, the
`TEBAKO_MOUNT_ROOT` 65/78 parity cases) plus the symbol-provenance gate.

Nothing here has published an artifact: releases stay draft-gated until
the xml2rfc payload (TODO.python/03) proves the chain end-to-end. One
upstream dependency: the POSIX boot smoke in CI needs a tamatebako/tebako
link-unit release carrying the `fcntl` interposition fix
([tamatebako/tebako#524](https://github.com/tamatebako/tebako/pull/524));
the pinned `link_unit_release: "v2.1.5"` predates it, so POSIX CI legs
are expected red until a newer tebako release lands and the pin moves.

## DECISION: the driver is LINKED into the interpreter, not wrapped

Python runtimes ship the spec-17 driver **linked into the `python3`
executable** (the ruby pattern), not the java-style wrapper exe
(spec 29).

Rationale:

- The wrapper pattern exists for runtimes that arrive as third-party
  binaries we cannot relink (openjdk). CPython here is **source-built by
  us** — [tamatebako/python](https://github.com/tamatebako/python)
  publishes the verified source tarballs and this factory compiles them —
  so the link step is ours, and the driver goes inside the exe: one
  process, no wrapper layer, no second argv/env contract.
- The boot/exit-code contract is then *literally* the ruby driver's:
  `TEBAKO_RUNTIME_IMAGE` handoff, `TEBAKO_MOUNT_ROOT` redirect with exit
  65 (malformed) / 78 (ungranted), the same named errors. Parity is
  assertable in tests against the ruby driver's contract suite where the
  cases overlap (TODO.python/02 acceptance).
- CPython is relocatable via `PYTHONHOME`/`PYTHONPATH` — TODO.python/01's
  probe built both pinned lines (3.12.14, 3.13.15) and verified a moved
  tree resolves stdlib + ssl against the relocated prefix with **zero
  patches**. The fs TU sets `PYTHONHOME` from the driver's effective
  mount root at boot; the interpreter itself is never patched.
- Contract 2 from day one: this factory has no contract-1 era (no merged
  env+app images, no embedded incbin image). The env image is always the
  standalone `.tfs` the driver mounts from `TEBAKO_RUNTIME_IMAGE`.

## The unpatched interpreter: preload shim + re-exec

The architectural difference from ruby: tamatebako/python's zero-patch
contract means CPython's own libc file IO **cannot see the driver's
mounts** (ruby carries patch literals that reroute its IO; python does
not). Visibility is spec 22's tier-1 preload interposition, composed by
`build/resources/tebako_python_main.c` (the fs TU, which replaces
`Programs/python.o` in the interpreter link) in two process
incarnations:

1. The **first** incarnation boots the driver in-process
   (`tebako_driver_boot`): mounts the env image from
   `TEBAKO_RUNTIME_IMAGE` and every `--tebako-image` payload triple,
   verifies the image's layout card (`lib/tebako/layout.yaml`), applies
   the jail, rewrites argv to the resolved entry, and arms the
   preload-shim injection env from the layout grant. A preload library
   binds only at exec, so —
2. when the boot mounted anything, `main` **re-execs itself** with the
   rewritten argv and the driver-armed env (`LD_PRELOAD` /
   `DYLD_INSERT_LIBRARIES` + `TEBAKO_PRELOAD_SHIM` +
   `TEBAKO_TFS_MOUNTS`, sentinel `TEBAKO_PYTHON_BOOTED`). The shim's
   constructor re-mounts the serialized mount table in the child; the
   child skips the boot and runs the interpreter, whose libc IO the shim
   now serves from the VFS.

`PYTHONHOME` is set from `tebako_mount_point()` (the driver's effective
root — a `TEBAKO_MOUNT_ROOT` override already applied) whenever an env
image is named; an inherited `PYTHONPATH` rides along (the ruby runtime's
`RUBYLIB` parity). A **bare exe** (no `TEBAKO_RUNTIME_IMAGE`) is dev
mode: `PYTHONHOME` stays untouched and getpath resolves from the exe's
own path — the stdlib is image-resident, so a bare exe is NOT a working
interpreter (the boot smoke asserts this contract honestly: non-zero
exit, the driver's warning on stderr).

Named exits are the driver's, surfaced unmodified: 65
(`TEBAKO_MOUNT_ROOT` malformed), 78 (ungranted override, or an env image
with no `preload_shim` grant — an unpatched CPython would boot blind),
74 (re-exec failure), 69 (windows with any mount — see the windows
boundary below).

## The extension set (v1 hermetic core)

`Modules/Setup.local` pins the deterministic contract
(`PythonBuild::STATIC_MODULES` / `DISABLED_MODULES`):

- **Static, in the exe:** `_ssl`, `_hashlib` (both against static
  openssl), `zlib`, `binascii` (static zlib) — their deps bind via the
  link unit's Mlibs rewrites.
- **Disabled:** `_bz2`, `_lzma`, `_sqlite3`, `_ctypes`, `_ctypes_test`,
  `readline`, `_curses`, `_curses_panel`, `_gdbm`, `_dbm`, `nis`,
  `_tkinter`, `_uuid` — the host-asymmetric extensions. Their python
  sides (`test/`, `idlelib`, `tkinter`/`turtle`) are pruned from the
  image: the runtime answers "no such module" by absence, never by a
  broken import.
- **Everything else** configure detects rides the image as dynamic
  extensions in `lib-dynload`, mounted with the stdlib.

## site-packages and pip

The env image ships the stdlib plus a **declarative site-packages
whitelist** (`build/site-packages.yml`; v1 keeps `pip` only, with its
dist-info — pip's `importlib.metadata` self-check reads it). Everything
else ensurepip installed is pruned at image assembly.

**The pip form is `python3 -m pip`.** The image's `bin/` directory is
pruned wholesale: the ensurepip console scripts' shebangs spell the
build prefix — dead links in any mounted layout — so no `pip3` script
ships. This matches the ruby factory's no-entrypoints shape: the L1
manifest declares no entrypoints and the release shard names the
interpreter by convention.

## The windows boundary

The v1 windows leg (ucrt64, `--disable-shared`) is the **driver-contract
surface only**: the exe boots the driver, answers `--tebako-image`/
`TEBAKO_RUNTIME_IMAGE` with the same named errors, and runs the
interpreter only when nothing was mounted (bare/dev mode). There is no
preload tier on windows — with any mount the fs TU exits **69** with a
named error (roadmap 30 phase 2). The `--disable-shared` choice means no
libpython DLL facet ships; `scripts/upload_release.rb` already models
the dll facet opportunistically if a future `--enable-shared` leg
appears (the ruby factory's issue-40 analog).

## The artifacts (per version × triplet)

The publish layout mirrors tebako-runtime-ruby's current shape (its
issue-139 layout from day one — **no legacy monolith-only mode**):

- `tebako-runtime-<tebako>-<python>-<triplet>[.exe]` — the interpreter:
  `python3` with the spec-17 driver linked in (the fs TU as `main`).
- `tebako-runtime-<tebako>-<python>-<triplet>.tfs` — the env image:
  stdlib + lib-dynload + the whitelisted site-packages + the preload
  shim (POSIX — REQUIRED here: the unpatched interpreter cannot read its
  own mounted image without it, so a missing shim is a hard build error,
  never the ruby factory's degrade) + the layout card
  (`lib/tebako/layout.yaml`: era 2, `mount_root_override` granted,
  `preload_shim` path) + the L1 payload manifest
  (`__tpkg__/manifest.yaml`). Packed by `tfs mkimage` (the limnifs
  writer — the current default format; a build-time factory tool, never
  a runtime dependency of the shipped package).
- `<package>.manifest.json` — the package shard: the manifest entry
  (`tebako_version` / `contract_era` / `contract_version` /
  `python_version` / `platform` / `filename` / `sha256` / `size_bytes` /
  `mount_root` / `image_layout` / `built_from`), plus the additive
  `image` key and, when the sidecars are present, `abi` (the build's own
  EXT-SUFFIX stem — exactly the string native-extension wheels pin) and
  `dll` (windows shared builds only; see the windows boundary).
- `<package>.abi` / `<package>.contract.yaml` — the builder-emitted
  sidecars the shard folds in (the era-2 provenance card:
  `contract_era` / `mount_root` / `image_layout` / `built_from`).
- `<asset>.sha256` — the checksum sidecar next to every payload asset,
  in the tebako store's trust-anchor shape (`"<sha256>  <filename>\n"`).
- Derived conveniences: the monolithic `manifest.json` and `SHA256SUMS`
  are **regenerated from the shards + the asset listing** by one finalize
  pass after every platform lands — never read-modify-written per
  platform.

## The flow

```
tamatebako/python release          tamatebako/tebako release
tfs-python-<v>-src.tar.gz          link-unit-<ver>-<pid>.tar.gz
+ SHA256SUMS (trust anchor)        (spec-17 driver + tfs + closure)
        |                                   |
        v                                   v
   fetch + verify  ────────►  link the driver into python3
        configure && make (relocatable; per-triplet toolchain)
                        |
                        v
        assemble env layout (stdlib + lib-dynload + pip + shim
        + layout card + L1 manifest)
        pack <package>.tfs  (tfs mkimage — limnifs writer)
                        |
                        v
        provenance gate (ci/check_symbol_provenance.sh)
        boot smoke (tools/boot_smoke: imports off the mounted image,
        dlopen ext path, TEBAKO_MOUNT_ROOT 65/78 parity, bare-exe
        contract)  →  publish (scripts/upload_release.rb)
```

Both inputs are **published release artifacts**, consumed by pin from
`contract.yml` — never source checkouts of sibling repos (prebuilt
artifacts flow downward; ecosystem AGENTS.md §0/§4).

## Matrix grammar

Same grammar as the ruby factory. Seven legs: every (python × env) cross
of the catalog under the dispatch filters
(`python_filter=full|tidy|catalog|<list>`, `platform=all|windows|
linux-gnu|linux-musl|macos`, `arch_filter=all|x86_64|arm64`).

| os | arch | host | container (ghcr.io/tamatebako/…) | link-unit pid |
|---|---|---|---|---|
| linux-gnu | x86_64 | ubuntu-22.04 | tpkg-builder-x86_64-linux-gnu | linux-gnu-x86_64 |
| linux-gnu | arm64 | ubuntu-22.04-arm | tpkg-builder-aarch64-linux-gnu | linux-gnu-arm64 |
| linux-musl | x86_64 | ubuntu-22.04 | tpkg-builder-x86_64-linux-musl | linux-musl-x86_64 |
| linux-musl | arm64 | ubuntu-22.04-arm | tpkg-builder-aarch64-linux-musl | linux-musl-arm64 |
| macos | x86_64 | macos-15-intel | — (runner-native) | macos-x86_64 |
| macos | arm64 | macos-14 | — (runner-native) | macos-arm64 |
| windows (ucrt64) | x86_64 | windows-2022 | — (runner-native) | x86_64-windows-gnu |

Containers come from
[tebako-ci-containers](https://github.com/tamatebako/tebako-ci-containers)
(the `tpkg-builder-<triplet>` family; windows/macOS are runner-native by
design). The linux legs **docker-run** the image per step (the
alpine-based musl image cannot host node actions, so no job-level
`container:`). The version catalog lives in `contract.yml` (the SSOT),
the env vocabulary in `.github/matrix.json` — versions, tags, and SHAs
never appear in workflow YAML.

## contract.yml — the pins

- `contract_version: 2` — the bootstrap ↔ runtime contract (spec 17
  grammar). Floored at 2 by the schema: no contract-1 era exists here.
  Bump rules mirror the ruby factory's (+1 in lockstep with the
  compiled-in `TEBAKO_CONTRACT_VERSION`, same commit — enforced by the
  driver-source parity arm of `scripts/check_contract.rb`).
- `container_version: "v1"` — the tpkg-builder tag line. Per-leg digest
  pinning is a follow-up.
- `link_unit_release: "v2.1.5"` — the tamatebako/tebako release whose
  prebuilt link unit the legs consume. **Predates the `fcntl`
  interposition fix** (tamatebako/tebako#524): move this pin to the
  first tebako release that carries it, then the POSIX boot-smoke legs
  go green in CI.
- `source_release: "v0.1.0"` — the tamatebako/python source release pin
  (the source factory's first tag; landed).
- `python:` — the version catalog (`catalog` / `full` / `tidy` sets),
  mirroring tamatebako/python's `versions.yml`.

## Layout

- `VERSION` — the package version: package names and the release tag
  follow it (`v$(cat VERSION)`). `0.0.0` is the never-published
  placeholder; the first publish PR opens the real line.
- `contract.yml` + `schema/` — the pins and the version catalog, and
  their JSON Schema; `scripts/check_contract.rb` validates (CI),
  including the driver-source parity arm (contract.yml ↔ the tebako
  driver's compiled-in contract version).
- `scripts/versions` — emits the catalog / resolves the dispatch filter
  grammar / reads the pins (contract.yml is the SSOT).
- `scripts/compute_matrix.rb` — the matrix engine
  (`--format matrix|env|pythons`): catalog × env vocabulary under the
  dispatch filters → the leg matrix (with `host_id`), the env/python
  expectation rows `publish.yml` later asserts.
- `scripts/upload_release.rb` — the release upload/finalize port:
  sidecars, shards, the idempotent re-upload skip, the FINALIZE_ONLY
  pass. `publish.yml`'s release job drives it per platform with the
  `EXPECTED_ENV_MATRIX`/`EXPECTED_PYTHON_MATRIX` rows.
- `tools/build_runtime` — the build entry point (fetch → verify → build
  → link → pack → package → sidecars).
- `tools/boot_smoke` — the post-build acceptance gate (7 scenarios, 14
  checks): stdlib + ssl + zlib imports off the mounted image, the dlopen
  extension path, the `TEBAKO_MOUNT_ROOT` 65/78 parity cases, the
  bare-exe dev-mode contract. Needs `TEBAKO_TFS` (the tfs CLI, for the
  mount probe) and the runtime-packages tree.
- `build/lib/tebako_python_builder/` — the build model (the
  tebako-runtime-ruby `build/lib` port): Contract, Platform,
  PythonVersion, SourceFetcher, LinkUnit, Mlibs, PythonBuild,
  ImageBuilder, ImageManifest, ImagePackager, TfsTool, Builder.
- `build/resources/tebako_python_main.c` — the fs TU template (the
  interpreter's real `main`; see the re-exec section).
- `build/site-packages.yml` — the declarative site-packages whitelist.
- `ci/check_symbol_provenance.sh` — the symbol-provenance gate: the exe
  defines `tebako_driver_boot` / `tebako_mount_point` /
  `tebako_driver_contract_version` / `main`, and `main` forwards to
  `tebako_driver_boot`.
- `.github/workflows/_build-platform.yml` — the reusable per-platform
  build leg (workflow_call): compute → contract check → matrix build →
  provenance → boot smoke → artifact upload.
- `.github/workflows/build-{linux-gnu,linux-musl,macos,windows}.yml` —
  the four thin triggers (push main/PR/dispatch, `python_filter` /
  `arch_filter`).
- `.github/workflows/publish.yml` — the release coordinator
  (workflow_dispatch only; the ruby factory's shape — outputs flow from
  the four reusable calls, one release job assembles per-platform).
  Deliberate deviations: `publish` defaults to **false**; no
  `repository_dispatch` trigger yet.
- `.github/workflows/lint.yml` — the static gate: schema validation,
  catalog/matrix resolution, YAML/JSON parse checks, actionlint, the
  `ruby -c` sweep.
- `Brewfile` — macOS host build dependencies (CI).

## Follow-ups (explicitly NOT this PR)

1. The boot-contract parity suite (`spec/`) — exit-code parity against
   the ruby driver's contract suite where the cases overlap (the boot
   smoke covers the local acceptance; the cross-runtime `spec/` port is
   its own PR).
2. The windows shared-library question (the ucrt64 libpython analog of
   the ruby factory's issue-40 DLL) — decided with the first windows
   leg; the upload port already models the dll facet.
3. Container digest pinning, the `link_unit_release` bump (once a tebako
   release carries tamatebako/tebako#524), and the VERSION opening line.
4. Build-graph diff-awareness for the four build triggers (they fan out
   21 legs per event today; the ruby factory's plan job computes the
   diff — the headers note the follow-up).

Artifacts stay unpublished until the xml2rfc payload (TODO.python/03)
proves the chain.
