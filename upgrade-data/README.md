# upgrade-data — RC2 → unified RC3 upgrade metadata

This directory contains the **package-only upgrade metadata** for
`CNKI Research Portable 1.0.0-rc.3` (unified installer candidate). It is covered by the
in-package trust root `SHA256SUMS.txt`, but it is **not** distribution payload:

- it is not listed in `manifest.json` (`files[]` describes installed payload only),
- it is never copied into an installation root by the installer or the upgrader,
- it contains hashes and rules only — never file copies or target payload bytes.

| File | Purpose |
|---|---|
| `rc2-to-rc3.json` | Machine-readable upgrade contract consumed by `tools/lib/UpgradeCommon.ps1` (schemaVersion 2). Generated deterministically by `tools/build_unified_release.ps1`. |
| `README.md` | This document. |

## Hash chain (no cycles)

```
external ZIP SHA-256 (published sidecar)
        │ anchors
        ▼
SHA256SUMS.txt ──covers──► payload files + manifest.json + rc2-to-rc3.json + README.md
        │                                        │
        │ covers                                 │ files[] covers the 115 payload files only
        ▼                                        ▼
manifest.json (schemaVersion 1)             installed target bytes
        ▲
        │ sha256(manifest.json) — embedded targetManifestHash
rc2-to-rc3.json ──expectedTargetHashes──► the same 115 payload hashes as manifest.json
```

Rules that keep the chain acyclic:

1. `manifest.json` lists only distribution payload (`files[]`); it never lists
   `upgrade-data/**` or `SHA256SUMS.txt`.
2. `rc2-to-rc3.json` embeds `sha256(manifest.json)` and the target payload hashes, but it
   never contains its own hash, the `SHA256SUMS.txt` hash, or the ZIP hash.
3. `SHA256SUMS.txt` lists every package file except itself — payload, `manifest.json`,
   `rc2-to-rc3.json` and this README. It is the in-package trust root.
4. `upgrade-data/` contains exactly two files: `rc2-to-rc3.json` and `README.md`.

## `rc2-to-rc3.json` schema (schemaVersion 2)

Top-level fields (fixed constants; no wall-clock timestamps):

| Field | Meaning |
|---|---|
| `schemaVersion` | `2` |
| `kind` | `cnki-research-portable-unified-upgrade` |
| `upgradeId` | `cnki-portable-1.0.0-rc.2-to-1.0.0-rc.3-unified` |
| `upgraderVersion` | engine version (`2.0.0`) |
| `distributionId` | `cnki-research-portable-unified-1.0.0-rc.3` |
| `createdUtc` | fixed build constant (not a real timestamp) |
| `payloadRoot` | `.` (target bytes are read directly from the package root) |
| `sourceManifestHash` | frozen RC2 `manifest.json` SHA-256 (trust anchor) |
| `targetManifestHash` | `sha256(<package>/manifest.json)` — embedded by design; allowed because `manifest.json` does not hash `upgrade-data/` |
| `sourcePackageHash` / `sourcePackageBytes` | frozen RC2 ZIP identity |
| `targetPackageHash` | `null` (the unified target archive identity is external only) |
| `sourcePayloadFileCount` | 107 |
| `payloadFileCount` | number of distribution payload files (equals `manifest.json` `files[]` count) |
| `changedFileCount` | entries in `changedFiles` |
| `addedFileCount` / `removedFileCount` | target-only files / deleted source files (removals must stay 0) |
| `distributionManifestSchemaVersion` | `1` |
| `allowedSourceStates` | `["RC2_CLEAN","RC2_HOTFIXED"]` |
| `changedFiles[]` | `{path, operation: replace\|add, classification: payload\|distribution-metadata, sourceSha256, targetSha256, targetBytes}` — all hashes inline |
| `expectedSourceHashes` | 107 frozen RC2 payload hashes |
| `expectedTargetHashes` | the 115 target payload hashes; each value equals the corresponding `manifest.json` `files[]` entry |
| `hotfixedSourceOverrides` | the two Upgrader V1 `cordis.patch.yml` byte-variant hashes (verbatim) |
| `environmentFiles` | the two declarative environment metadata files (same shape as Upgrader V1) |
| `preservedDirectories` | directories the engine must never write (`<placeholder>` list) |
| `rollbackMetadata` | backup layout / transaction file / restore order / added-file deletion rules / `createdDirectoriesCleanup` |
| `minimumRequirements` | OS, PowerShell, free-space formula, offline/no-Node requirements |
| `forbiddenPaths` | closed list of never-managed paths (install-root relative or environment placeholders; never absolute development paths) |
| `validation` | frozen MCP tool names, `profile://list`, persona prefix, forbidden token, required files |
| `payloadSetHash` | SHA-256 over ordinal `"<path>\t<sourceSha256|ADD>\t<targetSha256>\n"` lines of payload-class changed files |
| `sourcePayloadSetHash` | SHA-256 over ordinal `"<path>\t<sha256>\n"` lines of the 107 source hashes |

Encoding: UTF-8 without BOM, LF line endings, 2-space JSON, non-ASCII escaped as
`\uXXXX`, object keys emitted in deterministic order.

## Verification

```
node tools/build_manifest.mjs --check
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify_release_zip.ps1 -Zip <candidate.zip>
powershell -NoProfile -ExecutionPolicy Bypass -File tools/build_unified_release.ps1 -VerifyOnly -Zip <candidate.zip> -Rc2Zip <rc2.zip> -Rc3FrozenZip <rc3.zip>
```

The release ZIP is the only external trust anchor: its SHA-256 sidecar plus the
release-level `SHA256SUMS.txt` anchor `SHA256SUMS.txt` → `manifest.json` /
`rc2-to-rc3.json` → payload bytes. `DSH_RUNTIME_ACTIVATION_VERIFIED` remains
`NOT TESTED`: file-level upgrade completion is proven by the engine, runtime activation
requires a real user DSH session.
