# tebako-runtime-python

Builds and publishes the prebuilt tebako CPython runtime packages
(`tebako-runtime-<tebako-version>-<python-version>-<triplet>[.exe]`) that
the tebako bootstrap/shim resolves at press/run time. Modeled on
[tebako-runtime-ruby](https://github.com/tamatebako/tebako-runtime-ruby)
(TODO.python/02).

**Status: SKELETON.** This repo is bootstrapping: structure, recorded
decisions, pins, and a CI shape that lints/parses. Real CPython builds,
the env-image packer, and the publish machinery land in the
TODO.python/02 follow-up PRs — every build/publish entry point fails
closed (exit 64) at a named TODO boundary until then. Nothing here has
published an artifact.

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
  patches**. The driver's job at boot is to set those from the baked
  mount root; nothing about the interpreter needs to change.
- Contract 2 from day one: this factory has no contract-1 era (no merged
  env+app images, no embedded incbin image). The env image is always the
  standalone `.tfs` the driver mounts from `TEBAKO_RUNTIME_IMAGE`.

## The artifacts (per version × triplet)

The publish layout mirrors tebako-runtime-ruby's current shape (its
issue-139 layout from day one — **no legacy monolith-only mode**):

- `tebako-runtime-<tebako>-<python>-<triplet>[.exe]` — the interpreter:
  `python3` with the spec-17 driver linked in.
- `tebako-runtime-<tebako>-<python>-<triplet>.tfs` — the env image:
  stdlib + selected site-packages, packed at build time by `tfs mkimage`
  (the limnifs writer — the current default format; a build-time factory
  tool, never a runtime dependency of the shipped package).
- `<package>.manifest.json` — the package shard: the manifest entry
  (`python_version` / `platform` / `filename` / `sha256` / `size_bytes` /
  `mount_root` / `image_layout` / `built_from` / `contract_version`),
  plus the additive `image` key and the interpreter paths (entrypoints
  decided explicitly with the first build — TODO).
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
        assemble env layout (stdlib + selected site-packages)
        pack <package>.tfs  (tfs mkimage — limnifs writer)
                        |
                        v
        boot smoke (TEBAKO_RUNTIME_IMAGE, PYTHONHOME/PYTHONPATH,
        TEBAKO_MOUNT_ROOT 65/78 parity)  →  publish
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
design). The version catalog lives in `contract.yml` (the SSOT), the env
vocabulary in `.github/matrix.json` — versions, tags, and SHAs never
appear in workflow YAML.

## contract.yml — the pins

- `contract_version: 2` — the bootstrap ↔ runtime contract (spec 17
  grammar). Floored at 2 by the schema: no contract-1 era exists here.
  Bump rules mirror the ruby factory's (+1 in lockstep with the
  compiled-in `TEBAKO_CONTRACT_VERSION`, same commit; the driver-source
  parity check lands with the first build).
- `container_version: "v1"` — the tpkg-builder tag line. The first real
  build PR pins per-leg digests.
- `link_unit_release: "v2.1.5"` — the tamatebako/tebako release whose
  prebuilt link unit the legs consume (the current line; verified
  2026-09-02 against the fully published release — all seven legs ship a
  unit, `linux-gnu-arm64` included; a miss would never be an error).
- `source_release: ""` — the tamatebako/python source release pin.
  **Empty placeholder**: the source factory has published no release yet;
  build legs fail closed until its first tag lands and this is set.
- `python:` — the version catalog (`catalog` / `full` / `tidy` sets),
  mirroring tamatebako/python's `versions.yml` at scaffold time.

## Layout

- `VERSION` — the package version: package names and the release tag
  follow it (`v$(cat VERSION)`). `0.0.0` is the never-published
  placeholder; the first publish PR opens the real line.
- `contract.yml` + `schema/` — the pins and the version catalog, and
  their JSON Schema; `scripts/check_contract.rb` validates (CI).
- `scripts/versions` — emits the catalog / resolves the dispatch filter
  grammar / reads the pins (contract.yml is the SSOT).
- `scripts/compute_matrix.rb` — the publish.yml plan job: catalog × env
  vocabulary under the dispatch filters → the leg matrix.
- `tools/build_runtime` — the build entry point (fetch → verify → build
  → link → pack → package → smoke). **Skeleton**: the option contract is
  fixed; every phase is a named TODO and the driver fails closed.
- `.github/workflows/lint.yml` — the skeleton gate: schema validation,
  catalog/matrix resolution, YAML/JSON parse checks.
- `.github/workflows/publish.yml` — the release coordinator skeleton
  (workflow_dispatch only; build legs and release step fail closed at
  their TODO boundaries).
- `Brewfile` — macOS host build dependencies (CI).

## Follow-ups (explicitly NOT this PR)

1. `tools/build_runtime` phases 1–7 — the real CPython build logic
   (port tebako-runtime-ruby's `build/lib` model deliberately, one PR at
   a time): source fetch/verify, link-unit download, configure/make,
   driver link, env-image pack, packaging, boot smoke.
2. `scripts/upload_release.rb` port — sidecars, shards, the finalize
   pass.
3. The boot-contract parity suite (`spec/`) — exit-code parity with the
   ruby driver's contract suite where the cases overlap; the
   `TEBAKO_MOUNT_ROOT` 65/78 cases; a stdlib import off the mounted
   image; the local macos-arm64 dogfood (TODO.python/02 acceptance).
4. The site-packages selection list (a declarative YAML config) and the
   manifest's interpreter-paths/entrypoint decisions.
5. The windows shared-library question (the ucrt64 libpython analog of
   the ruby factory's issue-40 DLL) — decided with the first windows
   leg.
6. Container digest pinning, the `source_release` pin (after
   tamatebako/python's first tag), the VERSION opening line, and the
   per-platform reusable workflow split (`_build-platform.yml`) when the
   real legs justify it.

Artifacts stay unpublished until the xml2rfc payload (TODO.python/03)
proves the chain.
