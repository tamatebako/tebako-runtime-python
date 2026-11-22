# patches/ — the factory patch inventory (windows-msys only)

One folder per patched line — `patches/<major.minor>/` — holding
`<feature>_msys.patch` files, applied in sorted order by
`TebakoPythonBuilder::FactoryPatches` to the extracted windows-msys
source tree at build time (the grammar's single owner is that class).

## What a factory patch is (and is not)

The CPython patch SERIES is the source factory's domain
(tamatebako/python `patches/<line>/`, shipped pre-applied in the
`tfs-python-<ver>-src-windows-msys.tar.gz` scenario asset — the
ecosystem's SSOT rule). A factory patch here is the **exception of
record**: a fix the runtime build needs while the pinned
`source_release` does not carry it, staged so a defect's consumers are
not blocked on a source-factory release cycle. Every entry must:

- target the windows-msys scenario only (the `_msys` suffix, mirroring
  the source factory's series convention). POSIX builds never carry a
  factory patch — their autoconf path is correct by construction, and
  the selection (`FactoryPatches#paths`) is empty off msys;
- cite its provenance in the header (the upstream patch file and the
  commit it was taken at — the windows port tracks MSYS2's
  `mingw-w64-python` series, so a header names the MSYS2 number and the
  MINGW-packages commit sha) and the wall it answers (the failing run
  and the exact error);
- carry a REMOVAL note. The apply step detects a source release that
  has grown the fix (the reverse check answers "already present") and
  skips loudly, so the bump that picks it up stays green — but the file
  is dropped in the same PR that bumps `source_release` past it.

## Inventory

- `3.14/multiprocessing_sem_unlink_msys.patch` — MSYS2 0038: expose
  `sem_unlink` in `_multiprocessing` on MS_WINDOWS (upstream's win32
  build always does; the mingw configure probe drops it behind
  `POSIX_SEMAPHORES_NOT_ENABLED`, killing `multiprocessing/synchronize.py`
  at import — tebako-runtime-python#105).
