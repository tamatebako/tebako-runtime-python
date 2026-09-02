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

## Repo status: SKELETON

`tools/build_runtime` and the publish.yml build/release steps are TODO
boundaries that **fail closed (exit 64)**. Real CPython build logic
lands only via the TODO.python/02 follow-up PRs — do not flesh phases
out piecemeal; port tebako-runtime-ruby's `build/lib` model
deliberately. The linked-driver decision and its rationale are recorded
in README.md — do not reopen it here; the wrapper pattern (spec 29) is
the java stream's.

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
