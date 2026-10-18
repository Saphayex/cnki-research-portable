# CNKI Research Portable

**A portable Windows distribution that brings CNKI (China National Knowledge Infrastructure) literature search into DSH Desktop — unzip, hand it to DSH, review, authorise, and it runs.**

[简体中文](README.md) | [English](README_EN.md)

> **Status: `v1.0.0-rc.3` — Pre-release (Release Candidate, not a Verified Release): unified installer/upgrade package.**
> One ZIP now covers **fresh installs** and **safe in-place upgrade of an existing `1.0.0-rc.2`
> Layout-A installation**. The unified entry is `tools\setup.ps1`; the old
> `tools\portable.ps1` commands and their semantics are preserved byte-for-byte.
> Every automated test that can be run safely on a single machine passes. **Real sessions of the
> portable distribution itself, real model requests, real institutional searches, second-machine
> acceptance and the runtime activation of this unified upgrade have NOT been performed** and are
> marked `NOT TESTED`; they are not counted as passes. Do not treat this as a verified production
> release. This version is re-frozen as the `1.0.0-rc.3` unified release package with the official
> archive name `CNKI-Research-Portable-1.0.0-rc.3.zip`; it is **not published yet** — tag/push/GitHub
> Release require separate maintainer approval.
>
> **RC3 fix**: DSH Desktop `0.2.1-rc.2` removed the implicit `{{cwd}}` prompt variable
> (defect `CNKI-021-001`). RC3 deletes the now-invalid
> `suffix: Your working directory is {{cwd}}.` from the preset persona and keeps the
> `{{model}}` prefix. The **production bundle** on the build host passed real `0.2.1-rc.2`
> acceptance; the **portable RC3 package itself** still requires an independent live
> installation/session acceptance — see section 4.

**Version identity** (deliberately not forced to be equal)

| Level | Value | Meaning |
|---|---|---|
| Distribution | `1.0.0-rc.3` | Version of this repository and its release assets; pre-release |
| Package kind | Unified installer/upgrade package | one official ZIP does both a fresh install and a safe Layout-A RC2 upgrade; official archive name `CNKI-Research-Portable-1.0.0-rc.3.zip` |
| Core bundle | `@local/dsh-cnki-research@1.0.0` | The installed plugin; **frozen baseline version, code unchanged** |
| Upstream | `cnki-mcp 0.1.1` | Vendored source version, matches the baseline |
| Release grade | Release Candidate | Not a Verified Release |

---

## 1. What this is

CNKI Research Portable is a plugin distribution for **DSH Desktop**. The problem it solves is
concrete: DSH Desktop can attach external data sources over MCP, but doing CNKI literature search
normally means installing Python, creating a virtual environment, provisioning a Playwright
browser, hand-writing an MCP server configuration and then editing the DSH plugin manifest.
Each step can fail, and the usual failure mode is "the plugin is installed but no tools appear".

This project packages all of that into one **self-contained Windows distribution**:

* a **path-independent** DSH agent preset (`CNKI Research`);
* a stdio MCP launcher exposing **8 CNKI search tools**;
* a **pinned, vendored** copy of the upstream `cnki-mcp` source plus its lockfile;
* an installer with a **production-data gate**, backups, uninstall and rollback;
* a **unified entry** `tools\setup.ps1`: the same package can **fresh-install**, or **safely
  upgrade an existing Layout-A RC2 installation in place** (per-file verification, automatic
  failure recovery, byte-exact rollback, no venv rebuild, no profile rebuild);
* a self-check and static test suite that runs offline.

It is **not** a new CNKI client and it provides no way to bypass access controls. The search
capability comes from the upstream project [`cnki-mcp`](#5-upstream-and-credits); this project
contributes the integration, deployment and engineering around it.

---

## 2. Features

### 2.1 The eight CNKI MCP tools

After installation, **only** a `CNKI Research` session can see these 8 tools (`mcp__cnki__*`):

| Tool | Required | Optional | Purpose |
|---|---|---|---|
| `easy-search` | `keywords` | `limit` (default 10), `sort_by` | Keyword search |
| `advanced-search` | — | `title`, `author`, `year_from`, `year_to`, `journal`, `keywords`, `subject`, `abstract`, `institution`, `fund`, `doi`, `document_type`, `source_types`, `sort_by`, `limit` (default 10) | Multi-field search |
| `get-info-from-url` | `url` | — | Record from a CNKI detail-page URL |
| `get-info-by-detail` | `title` | `authors`, `year`, `year_from`, `year_to`, `journal`, `keywords`, `subject`, `abstract`, `institution`, `fund`, `doi`, `document_type`, `source_types`, `sort_by`, `limit` (default 10) | Locate and fetch one record by title/author |
| `list-journal` | `issn`, `year`, `vol` | — | List one issue by ISSN |
| `search-issn` | `journal` | — | Resolve a journal name to its ISSN |
| `login` | — | `profile` | Open a browser for institutional sign-in |
| `logout` | — | — | Clear the sign-in state |

One MCP resource, `profile://list`, lists the CNKI profiles configured on this machine.

> `title` is a **required** parameter of `get-info-by-detail`. An earlier schema-sanitising pass
> deleted it as if it were an annotation, breaking the tool; a regression assertion now guards it.

### 2.2 The CNKI Research agent preset

* Preset id `cnki-research`, display name **CNKI Research**, `order: 5`.
* Inherits the standard capabilities (files, commands, planning, delegation, todos, web) and adds
  an MCP client, the skill filesystem and `tool-skill`.
* The persona references only prompt variables DSH registers (`{{model}}`). The `{{cwd}}`
  variable removed by DSH `0.2.1-rc.2` is gone in RC3 and is guarded by the static regression
  assertion `A7.promptVariables`.
* A missing CNKI profile does **not** break preset loading: the launcher starts in a degraded mode
  and lets `login` drive authentication (`--require-profile` restores the strict "no profile, exit"
  behaviour).

### 2.3 Unified entry: one package, two paths

The unified entry is **`tools\setup.ps1`**, with actions
`check` / `plan` / `install` / `upgrade` / `verify` / `status` / `rollback` / `uninstall`.
Exit codes are `0` (success / nothing to do), `2` (refused / FAIL / unknown state) and `1`
(tool/internal error).

| Your situation | Commands | What happens |
|---|---|---|
| New user | `setup.ps1 -Action check` → `-Action plan` → `-Action install -Yes` | read-only checks/plan, then delegates the original installer for a fresh install (venv, Chromium, `dsh plugin` registration) |
| Existing standard RC2 install | `check -InstallRoot <RC2 root>` → `plan -InstallRoot <RC2 root>` → **quit DSH** → `upgrade -InstallRoot <RC2 root> -PlanId <id> -Yes` | transactional in-place upgrade: only changed distribution files + 2 environment metadata files; auto-restore on failure; byte-exact rollback |
| Already RC3 (unified or frozen) | `setup.ps1 -Action check` / `-Action upgrade` | recognised as `RC3_ALREADY_INSTALLED`, safe no-op (exit 0, zero writes) |
| Unknown / modified / mixed | `check` / `plan` / `upgrade` | **refused** (exit 2) with a conflict list; user modifications are never overwritten |

Key points:

* **The safe upgrade exists only as `setup.ps1 -Action upgrade`.** `portable.ps1 -Action upgrade`
  keeps its old semantics (reinstall-over-existing) and is explicitly documented as **LEGACY**;
  it is not the safe incremental path.
* The upgrade **does not modify** `portable.ps1`, **does not re-run** the plugin manager,
  **does not rebuild** the profile junction or the venv, and **needs no network**. You must
  **quit DSH normally** first (the upgrader never closes or kills DSH for you).
* **DSH mode principle**: the safe upgrade only writes files and needs no Plugin Manager, so an
  ordinary **PowerShell window** is enough (the command tool in a DSH Standard session also works).
  Only fresh install, uninstall and installer-backup rollback — which really call `dsh plugin` —
  need Creator / the plugin-manager scenario.
* The new ZIP **must be extracted into an empty directory**. Extracting it over an old install
  directory creates a mixed tree; `setup.ps1 -Action check` fails closed and does not try to repair it.

### 2.4 Creator-driven installation (fresh install)

You do not type PowerShell commands for a fresh install. Hand `INSTALL_PROMPT.md` to DSH's
**Creator** mode and it will:

1. verify the package structure and hashes;
2. run a read-only `setup.ps1 -Action check` / `-Action plan` and explain every result;
3. ask for consent before installing `uv`, downloading Chromium, or choosing a profile;
4. perform the install and report back;
5. emit a structured report using only `PASS` / `FAIL` / `WARN` / `NOT TESTED`.

> Upgrading an existing RC2 installation is **not** driven by Creator: APPLY must run in a
> standalone PowerShell window after DSH has exited (see section 3.2).

### 2.5 Independent dependency deployment

* Python dependencies are reproduced exactly with `uv sync --frozen` against the **vendored**
  `uv.lock`; every transitive dependency version is pinned.
* The virtual environment lives in `.venv` under the **install root**, uses `--no-editable`, and
  copies packages into `site-packages`, so the install root can be moved afterwards.
* Upstream source ships in `upstream/cnki-mcp/` (with its `LICENSE` and `uv.lock`), satisfying the
  GPL-3.0 source-availability requirement without depending on GitHub reachability.
* The target machine needs neither Node nor any pre-installed Python package; if `uv` is missing the
  installer installs the recorded version.

### 2.6 Browser-based institutional authentication

* `login` opens a **visible** Chromium window and **you** complete your institution's SSO or CAPTCHA.
* The distribution contains **no** account, cookie, `storage_state.json` or preset institution.
* Sign-in state is stored on the **target** machine under
  `%USERPROFILE%\.cnki-mcp\profiles\<name>\` and is never shipped.
* `login` waits about 120 seconds; the real tool response decides success, and nothing is faked.

### 2.7 Windows path adaptation

`bundle/cnki-research/cordis.patch.yml` contains **no drive letter, user name or development
directory**. Every location is resolved at row-activation time with `!!js`:

| Setting | Resolution order |
|---|---|
| Bundle directory | `createRequire(baseUrl)` resolves `@local/dsh-cnki-research/package.json` |
| `customSkillDirs[0]` | `<bundle>/skills` |
| MCP `args[0]` | `<bundle>/launcher/cnki_research_launcher.py` |
| MCP `cwd` | `<bundle>` |
| MCP `command` | `$CNKI_RESEARCH_PYTHON` → `<bundle>/portable.runtime.json` → `<installRoot>/.venv/Scripts/python.exe` → `.../bin/python` → `python` on PATH |

Each expression is wrapped in `try/catch` and **always returns a string**, so a missing optional
file degrades rather than breaking preset activation. Install roots containing **spaces and CJK
characters** are exercised by static test group `A7`.

### 2.8 Installation and upgrade safety gates

This is the most deliberately designed part of the project:

* **Production-data gate** — any verb that would modify the real `%USERPROFILE%\.dsh` (sessions,
  storage, credentials, CNKI sign-in state) is **refused outright** unless
  `-AllowProductionProfile` is passed explicitly, printing a `REFUSED:` explanation.
* **`-CnkiProfile` is gated separately** — this is a **LEGACY `tools\portable.ps1`-only option** (`setup.ps1` does not accept it): it rewrites the real
  `%USERPROFILE%\.cnki-mcp\profiles\config.json`, which lives outside `$DSH_HOME`.
* **`-Json` is not consent** — a diagnostic JSON call gains no mutation authority.
* **Junction safety** — the only removal path performs a **non-recursive** `Directory.Delete` on a
  reparse point, and refuses to delete `.venv` when nested links are present.
* **No silent overwrite** — a pre-existing package with the same name is refused unless `-Force`.
* **Two trees must stay separate** — an upgrade requires `PackageRoot` (the freshly extracted
  release package) and `InstallRoot` (the old RC2 installation) to be distinct directories; equal paths,
  ancestor/descendant relations and reparse-point combinations are refused. This directly closes
  the "extract the new ZIP over the old install" mistake.
* **Fail-closed state machine** — only `RC2_CLEAN` / `RC2_HOTFIXED` may PLAN/APPLY;
  `RC3_ALREADY_INSTALLED` is a safe no-op; everything else (`UNKNOWN_OR_MODIFIED`, …) is refused
  with a conflict list, and user modifications are never auto-repaired or overwritten.
* **planId gate** — APPLY requires the `-PlanId` produced by a read-only PLAN; any state change
  invalidates the old id (re-PLAN), so what was reviewed cannot silently differ from what runs.
* **DSH-running gate** — a live profile with a running DSH refuses APPLY/ROLLBACK (`DSH_IN_USE`);
  processes are never force-killed and profiles are never edited to trigger HMR.
* **The upgrade is offline** — the engine reads only in-package, verified target bytes plus the two
  environment metadata files; Node/Git/Python/uv are not needed. `-Offline` only affects a fresh
  install's dependency downloads.

### 2.9 Uninstall and rollback

* `-Action uninstall` removes the plugin through the official `dsh plugin` interface and cleans up
  its own junction and runtime files.
* `-Action rollback` (installer backup) restores the profile's `package.json` and lockfile from the
  **pre-install** backup, runs `dsh plugin add` when the bundle link must be rebuilt, and then
  asserts the profile resolves the bundle.
* For an **upgrade**, `setup.ps1 -Action rollback` automatically uses the latest upgrade transaction
  and restores the pre-upgrade payload **byte-exactly**, including deleting the files added by the
  upgrade (only if their current bytes equal the applied target hash).
* Before installing, the profile's `package.json` and `pnpm-lock.yaml` are backed up to
  `_portable\backups\<timestamp>\`.
* Uninstall and rollback **do not touch** your DSH sessions, workspaces, other plugins or other
  profiles.

### 2.10 Cross-project literature search

Records retrieved in a CNKI Research session are structured data and can be handed to other DSH
projects. Tool scope is confined to the `CNKI Research` preset, so **Standard and Creator sessions
do not receive these tools**. Reading any document grants **no** MCP tool access — scope is decided
by the preset alone.

### 2.11 Package structure, install root and integrity chain

**The PackageRoot of the unified release ZIP is the RC3 distribution tree itself**, plus three
kinds of **package-only release metadata**:

| Class | Contents | Copied into install root? |
|---|---|---|
| Distribution payload P (115 files) | the 107 frozen-RC3 payload files + 8 unified additions (`tools\setup.ps1`, `tools\lib\UpgradeCommon.ps1`, `tools\build_unified_release.ps1`, `tests\Test-UnifiedMatrix.ps1`, `tests\lib\UnifiedFixtures.ps1`, `tests\lib\UnifiedAssert.ps1`, `tests\Test-UnifiedVerification.ps1`, `tests\test_unified_package.mjs`) | **yes** |
| Distribution manifest | `manifest.json` (`schemaVersion 1`; size + SHA-256 for each of the 115 payload files; keeps `install.entryPoint = tools/portable.ps1` and adds `install.setupEntryPoint = tools/setup.ps1` plus an `upgrade` metadata block) | **yes** (one `manifest.json` in the install root) |
| Release metadata | `SHA256SUMS.txt` (in-package integrity list), `upgrade-data\rc2-to-rc3.json` (RC2→RC3 upgrade contract: hashes and rules only, no file copies), `upgrade-data\README.md` | **no** (never copied into an install root) |

* There is **no** `payload\` copy of the target files inside the ZIP; upgrade target bytes are read
  directly from the same relative paths in the package root.
* After an upgrade the install root equals 115 payload files + `manifest.json` + the runtime
  directories maintained by the installer (`.venv\`, `_portable\`,
  `bundle\cnki-research\portable.runtime.json`).
* **Integrity chain (acyclic)**: the external
  `CNKI-Research-Portable-1.0.0-rc.3.zip` SHA-256 (`.sha256` sidecar + release-level
  `SHA256SUMS.txt`) → in-package `SHA256SUMS.txt` → `manifest.json` /
  `upgrade-data\rc2-to-rc3.json` → every payload byte. The upgrade metadata deliberately embeds no
  target-ZIP hash, no self hash and no `SHA256SUMS.txt` hash (that would be circular); the target
  `manifest.json` identity is proven by "the `manifest.json` entry in `SHA256SUMS.txt` + every
  `manifest.files[]` hash matching the declared target hash".
* **Release identity**: this round re-freezes `1.0.0-rc.3` as the unified release package and the
  **official archive name is fixed** as `CNKI-Research-Portable-1.0.0-rc.3.zip` (all download/verify
  commands use it); the internal build artefact's previous candidate name is not user-facing and
  appears in no user command. The `v1.0.0-rc.3` tag, push and GitHub Release **require separate
  maintainer approval**; this round does not publish, push or move tags. The old frozen RC3 ZIP hash
  (`f4e914d1…`) is recorded as the **old candidate identity** for audit only and is not reused.
  Verification policy: ZIP + same-name `.sha256` sidecar + release-level `SHA256SUMS.txt`; no second
  same-name SHA file.

---

## 3. How to use

> The unified entry is `tools\setup.ps1`. It first detects the current installation state
> read-only, then chooses **fresh install / safe upgrade / verify / rollback**.
> Actions: `check`, `plan`, `install`, `upgrade`, `verify`, `status`, `rollback`, `uninstall`.
> Exit codes: `0` success (including "already RC3, nothing to do"), `2` refused/FAIL/unknown,
> `1` tool/internal error.

### 3.1 Fresh install (extract into an empty directory)

**Prerequisites**: Windows 10/11 x64, a working DSH Desktop installation, internet access for the
first install, and **your own lawful CNKI access**.

1. **Download the package** — take `CNKI-Research-Portable-1.0.0-rc.3.zip` and
   `CNKI-Research-Portable-1.0.0-rc.3.zip.sha256` (the release page also provides
   a release-level `SHA256SUMS.txt`).
2. **Verify the hash**
   ```powershell
   Get-FileHash .\CNKI-Research-Portable-1.0.0-rc.3.zip -Algorithm SHA256
   ```
   Compare character by character with the `.sha256` file. If it differs, **stop**.
3. **Extract into an empty directory** — e.g. `D:\Tools\CNKI-Research-Portable`. Spaces and CJK
   characters are fine, but do **not** use a temporary folder you will later delete (the virtual
   environment references the install-time absolute path), and **never** extract over an existing
   install directory (see 3.2 and 3.3).
4. **Read-only check and plan** (write nothing)
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan
   ```
   A fresh machine should report `NOT_INSTALLED` (installable) plus DSH / Python / uv / browser checks.
5. **Open DSH Creator** (or install from your own PowerShell)
   Start DSH Desktop → create a session in **Creator** mode → set the working directory to the
   extracted folder → send the whole prompt block from [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md).
6. **Review and authorise** — Creator first does checks and a plan only. Approve it once every item
   is clear. Installing into your everyday `desktop` profile requires `-AllowProductionProfile`, and
   that switch must be authorised by **you**, not added by the model:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action install -Yes -AllowProductionProfile
   # isolated trial profile (no switch needed):
   # ... -Action install -Yes -DshProfile cnki-trial
   # offline install (uv cache pre-warmed):
   # ... -Action install -Yes -Offline
   ```
7. **Select CNKI Research and search** — refresh the DSH page, create a new session, pick the
   **CNKI Research** preset, call `mcp__cnki__login`, complete sign-in in the Chromium window, then
   ask for a search.

### 3.2 Safe in-place upgrade from RC2 (existing standard install)

For users who already installed **`1.0.0-rc.2` in place (Layout A: the extracted directory is the
install root)**. The upgrade is **transactional**: per-file backup and verification, automatic
recovery on failure, byte-exact rollback. It **does not rebuild the venv, re-run the plugin
manager, rebuild the junction, or require network**, and it preserves DSH sessions, credentials,
CNKI sign-in state and the profile.

```powershell
# 0) Extract the release ZIP into a NEW empty directory (never over the RC2 install directory)

# 1) Read-only check (safe while DSH is running)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check -InstallRoot "<RC2 install root>"

# 2) Read-only PLAN (safe while DSH is running): note the planId from the output
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan -InstallRoot "<RC2 install root>"

# 3) Quit DSH normally (do not force-kill), then run APPLY in a standalone PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action upgrade -InstallRoot "<RC2 install root>" -PlanId "<planId>" -Yes

# 4) Reopen DSH normally, run the acceptance checks, then inspect file-level completion
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action verify -InstallRoot "<RC2 install root>"

# 5) To go back to RC2 (transaction byte-exact rollback, including deleting files added by the upgrade)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action rollback -InstallRoot "<RC2 install root>" -Yes
```

Boundaries:

* **Layout A only**; a separate runtime root (`-InstallRoot` pointing elsewhere, "Layout B") is
  refused with manual migration guidance.
* `UNKNOWN_OR_MODIFIED` (modified/mixed/damaged) is **refused** with a conflict list; nothing is
  auto-repaired.
* A state change invalidates the old `planId`; re-run `plan`.
* A live profile with a running DSH refuses APPLY (`DSH_IN_USE`).
* File-level completion (`FILE_UPGRADE_COMPLETE`) **is not** runtime acceptance:
  `DSH_RUNTIME_ACTIVATION_VERIFIED` remains `NOT TESTED`.
* **The new ZIP must be extracted into an empty directory**; extracting it over an old install
  directory creates a mixed tree that `setup.ps1 -Action check` fails closed on (it never repairs).

### 3.3 Already RC3 / unknown / not installed

| Detected state | `setup.ps1` behaviour |
|---|---|
| `RC3_ALREADY_INSTALLED` (exact unified match) | CHECK exits 0; UPGRADE is a safe no-op (`NOOP_ALREADY_TARGET`, zero writes/backups) |
| `RC3_ALREADY_INSTALLED` (exact frozen-RC3 match) | same safe no-op; **known limitation**: unified tooling additions are not auto-installed — the core version is complete, no action is needed |
| `UNKNOWN_OR_MODIFIED` | CHECK/PLAN exit 2 with a conflict list; APPLY/ROLLBACK refused; user modifications are never overwritten |
| `NOT_INSTALLED` | fresh install recommended (`-Action install`) |
| `LAYOUT_SEPARATE_PACKAGE_ROOT` (Layout B) | incremental upgrade unsupported; follow the manual migration guidance in [`docs/04`](docs/04-升级与版本维护.md) |

### 3.4 Legacy command compatibility (LEGACY)

`tools/portable.ps1` and `tools/lib/PortableCommon.ps1` are **byte-identical** to the frozen RC3;
all old commands and old documentation (`-Action check/install/uninstall/rollback/status/diagnose`)
remain valid. Please distinguish:

| Command | Semantics |
|---|---|
| `setup.ps1 -Action upgrade` | **the only safe incremental upgrade** (transactional in-place upgrade) |
| `portable.ps1 -Action upgrade` | **LEGACY**: equivalent to "reinstall/overwrite with this package"; it does not verify the source state, compare versions or prevent downgrades — **not** the RC2→RC3 safe path |
| `portable.ps1 -Action plan` / `-DryRun` | **LEGACY known limitation**: it creates a profile backup directory, so it is not fully read-only; use `setup.ps1 -Action plan` for a read-only plan |
| `portable.ps1 -Action install` | the underlying fresh-install implementation; `setup.ps1 -Action install` runs state detection and gates first, then delegates to it |
| `portable.ps1 -Action uninstall` / `rollback` | uninstall and **installer-backup** rollback; `setup.ps1` picks the upgrade-transaction rollback by state or delegates to these |

---

## 4. Compatibility

DSH Desktop compatibility must be stated at **three distinct levels**; they are not interchangeable:

| Level | Object | DSH version | Result |
|---|---|---|---|
| Live run (portable) | Portable package built from this repository | `0.2.0-rc.2` | **Verified** (historical live record) |
| Static + isolated protocol (portable) | Portable RC3 built from this repository | `0.2.1-rc.2` | **Verified** (no real session/model request) |
| Live run (portable RC3) | Portable RC3 built from this repository | `0.2.1-rc.2` | **`NOT TESTED`** (independent install/session acceptance outstanding) |

Other combinations actually exercised:

| Item | Verified |
|---|---|
| OS | Windows 11 x64 |
| Electron | `44.0.0` (DSH 0.2.0-rc.2 / 0.2.1-rc.2) |
| Python | 3.12.0 (system interpreter); DSH bundles 3.12.14 |
| `uv` | 0.12.15 (the installer can install it) |
| `cnki-mcp` | 0.1.1 (vendored) |
| `mcp` / `playwright` | 1.30.0 / 1.63.0 (pinned by `uv.lock`) |
| Playwright Chromium | `chromium-1243` |

Regarding DSH `0.2.1-rc.2`, two things must be kept strictly apart:

* The **production bundle** on the build host (the fixed production copy of
  `@local/dsh-cnki-research@1.0.0`, **not** this portable package) passed real `0.2.1-rc.2`
  acceptance: real model request, preset prompt assembly, 8 MCP tools registered, provider
  accepts the raw MCP schema, MCP connection and resource calls, `mcp__cnki__login` reusing an
  existing profile, and `mcp__cnki__easy-search` returning real records — all PASS. That proves
  the **fix logic** works on `0.2.1-rc.2`, but it is **not** a live PASS for portable RC3.
* **Portable RC3 itself** only completed static checks plus isolated-DSH_HOME protocol/composition
  verification; it has not run a real session after an independent install on `0.2.1-rc.2`.
  Therefore `0.2.1-rc.2` does **not** enter the portable verified list, and the installer reports
  `UNTESTED` for it (non-blocking).

The declared DSH range is `>=0.2.0-rc.2 <0.3.0`. For the historical `0.2.0-rc.2` the regression
verdict is: **static compatibility holds** (the deleted suffix was an optional field defaulting to
an empty string, and the 0.2.0 persona schema and `{{model}}` are unchanged), while the **live
regression is `LIVE NOT TESTED`** — the production Desktop was not downgraded to test the old
version.

**Upgrade verification boundary** (stated separately from fresh install):

* The unified upgrade only replaces **files** (15 changed distribution files + 8 added files +
  `manifest.json` + 2 environment metadata files) and changes no bundle code, upstream source, venv
  or profile contract, so it introduces **no new DSH version requirement**.
* The upgrade path is re-executed in **isolated sandboxes** against the A–K test matrix
  (RC2_CLEAN / RC2_HOTFIXED, idempotence, unknown-state rejection, byte-exact rollback, fault
  injection, user-data protection, installer regression, package integrity and MCP protocol);
  results and evidence are whatever was actually executed at build time — **anything not executed
  is `NOT TESTED`**.
* **Runtime activation** (`DSH_RUNTIME_ACTIVATION_VERIFIED`) is always `NOT TESTED`: file-level
  completion is not proof of preset activation, tool visibility or model requests in a real DSH
  session; that requires your own acceptance on the target machine.

**Explicitly unverified**: Windows 10 x64, Windows ARM64, Linux, macOS; older or newer DSH
versions; UNC paths; read-only install locations; path depths beyond 200 characters.
**No claim is made of compatibility with all DSH versions.**
See [docs/03-兼容性矩阵.md](docs/03-兼容性矩阵.md) (Chinese).

---

## 5. Upstream and credits

This project is **based on the third-party open-source project**
[`cnki-mcp`](https://github.com/SepineTam/cnki-mcp) by **Sepine Tam (谭淞)**, version `0.1.1`,
licensed **GNU GPL-3.0**.

* The upstream source is vendored **byte-for-byte** in
  [`upstream/cnki-mcp/`](upstream/cnki-mcp/), including its original `LICENSE`,
  `pyproject.toml`, `uv.lock`, `src/` and `tests/`.
* The upstream licence text ships with the distribution; the root [`LICENSE`](LICENSE) and
  [`upstream/cnki-mcp/LICENSE`](upstream/cnki-mcp/LICENSE) are identical.
* Per-file hashes are recorded in
  [docs/provenance/upstream-src.sha256.json](docs/provenance/upstream-src.sha256.json).
* One `js-yaml` copy used only by the tests is redistributed under MIT, see
  [tools/vendor/js-yaml/LICENSE](tools/vendor/js-yaml/LICENSE).

**What this project adds** — the preset declaration and launcher in `bundle/cnki-research/`, plus
`tools/`, `tests/`, `docs/` and the release engineering — is primarily **DSH Desktop integration,
portable deployment and related engineering**. The transactional upgrade engine in
`tools/lib/UpgradeCommon.ps1` is a derived work of the project's Upgrader V1 (same GPL-3.0-only
project); its derivation and preserved guarantees are documented in `docs/01` and `docs/04`.

**Disclaimer**

* This project has **no official relationship with CNKI, nor with the upstream author**, and is
  endorsed or authorised by neither.
* Users **must have their own lawful access** (institutional subscription or personal access).
* This project provides **no** institutional accounts, cookies, passwords, or any means of bypassing
  access controls, and it does not download full texts.
* Respect CNKI's terms of use and your institution's rules. The upstream project itself states that
  it is a personal learning project with no affiliation to CNKI.

Third-party components and licences are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

---

## 6. Known limitations

Please read this before deciding whether the project fits.

**Release grade and outstanding acceptance**

* This is a **Pre-release (Release Candidate, not a Verified Release)**. This round re-freezes
  `1.0.0-rc.3` as the **unified installer/upgrade package** (official archive
  `CNKI-Research-Portable-1.0.0-rc.3.zip`); it is **not published yet** and publishing requires
  separate maintainer approval.
* `PORTABLE_LIVE_DSH_STATUS = NOT TESTED` — portable RC3 has not run a real session after an
  independent install on DSH `0.2.1-rc.2`.
* `REAL_MODEL_REQUEST_STATUS = NOT TESTED` — no DSH host was booted with the portable payload to
  make a real model request (the production bundle's live acceptance is a **different object**,
  see section 4).
* `REAL_CNKI_SEARCH_STATUS = NOT TESTED` — no real institutional account performed a real search
  with the portable payload.
* `DSH_RUNTIME_ACTIVATION_VERIFIED = NOT TESTED` — including the unified upgrade: "file-level
  complete" is never the same as "runtime activation verified".
* **No second machine acceptance.** All installation evidence comes from a single Windows 11 x64
  host, inside an isolated `DSH_HOME` + `USERPROFILE` sandbox.
* **Standard/Creator tool isolation is a structural inference, not an observed one**: it is verified
  that the preset declares exactly one MCP row and is referenced exactly once, but the other modes'
  tool catalogues have not been inspected in a running DSH UI.

**Functional limits**

* Search and metadata only; **no full-text download**.
* The first install needs internet access (`uv`, Python dependencies, Chromium); **the RC2→unified
  safe upgrade needs no network**.
* Institutional authentication must be completed manually; it cannot be automated.
* Windows x64 only.
* **Upgrade supports standard in-place Layout A only**; a separate runtime root (Layout B) is not
  supported for incremental upgrade and needs manual migration.
* **DSH must be quit normally before an upgrade**; APPLY is refused while DSH is running, and the
  tool never force-kills processes.
* **The new ZIP must be extracted into an empty directory**; extracting over an old install
  directory creates a mixed tree that is refused.
* `portable.ps1 -Action upgrade` is **LEGACY** (reinstall-over-existing; no version comparison, no
  downgrade prevention) and is **not** the safe incremental path — that is only
  `setup.ps1 -Action upgrade`.
* `portable.ps1 -Action plan` / `-DryRun` is a **LEGACY known limitation**: it writes a profile
  backup directory and is not fully read-only; use `setup.ps1 -Action plan` instead.
* Upstream is pinned by **content hash**, not by git commit (the upstream tree has no `.git`).
* Keep the install root **stable**; the virtual environment references that path.
* `login` does **not** create an institutional profile for you; the first sign-in must be completed
  through the institution's own flow in the browser window the tool opens.

**Safety boundaries**

* The installer/upgrader **never** restarts or shuts down DSH; when a page refresh or a normal
  DSH restart is needed it says so.
* The project does not read, export or log your account name, password or cookies.

---

## 7. Documentation

| Document | Contents |
|---|---|
| [START_HERE.md](START_HERE.md) | Entry index: fresh install / safe RC2 upgrade / already-RC3 (Chinese) |
| [DEPLOYMENT_README.md](DEPLOYMENT_README.md) | User deployment and three-step acceptance guide, including the RC2 upgrade acceptance path (Chinese) |
| [INSTALL_PROMPT.md](INSTALL_PROMPT.md) | Install prompt you can paste into DSH, plus the standalone RC2 upgrade command flow (Chinese) |
| [docs/01-架构与路径契约.md](docs/01-架构与路径契约.md) | Preset / MCP / launcher / skill structure, unified package layout and upgrade-engine path contract |
| [docs/02-安装卸载与回滚.md](docs/02-安装卸载与回滚.md) | **Legacy installer** (`portable.ps1`) install, uninstall, rollback, diagnostics and troubleshooting (semantics preserved) |
| [docs/03-兼容性矩阵.md](docs/03-兼容性矩阵.md) | Verified / unverified matrix, covering install and upgrade boundaries |
| [docs/04-升级与版本维护.md](docs/04-升级与版本维护.md) | Unified safe-upgrade workflow, LEGACY notes, maintainer build and version conventions |
| [docs/05-测试报告.md](docs/05-测试报告.md) | Test scope, results and pass criteria (including the unified matrix) |
| [docs/06-设计取舍.md](docs/06-设计取舍.md) | Trade-offs behind path independence, institution neutrality and vendoring |
| [docs/provenance/](docs/provenance/) | Baseline provenance and per-file hashes |
| [bundle/cnki-research/README.md](bundle/cnki-research/README.md) | The installed plugin itself |
| [CHANGELOG.md](CHANGELOG.md) | Version history and fixed defects (including the unified installer entry) |

**Verify it yourself (no DSH, no network required)**

```powershell
node tools\build_manifest.mjs --check      # is the payload manifest current?
node tests\test_static_package.mjs         # hashes, paths, credentials, licence, structure, prompt variables
node tests\test_unified_package.mjs        # unified closure: SHA256SUMS / manifest / upgrade-data / payload set
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify_release_zip.ps1 -Zip <release zip>
```

Results must be taken from the **actual output**; this release adds the unified entry, upgrade
engine, tests and documentation, so the historical RC3 payload's static result cannot be reused.
The full suite (real stdio MCP handshake and an isolated profile install) is
`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_all.ps1`; it modifies the local
machine and needs a real DSH installation and network access, so read the documentation before
running it. The unified upgrade matrix (needs the frozen RC2 ZIP and the release ZIP) runs via
`tests\Test-UnifiedMatrix.ps1`, and archive/package/fresh-install verification via
`tests\Test-UnifiedVerification.ps1`; both confine all writes to isolated sandboxes.

---

## 8. License

**GNU General Public License v3.0 (`GPL-3.0-only`)** — full text in [LICENSE](LICENSE).

The distribution's stdio launcher imports and links the upstream `cnki-mcp` (GPL-3.0) at runtime,
which makes them a combined work, so the distribution as a whole is released under the same
GPL-3.0 as upstream. Third-party components, their licences and origins are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

```
Copyright (C) 2026  CNKI Research Portable contributors
Upstream cnki-mcp: Copyright (C) Sepine Tam (谭淞), GPL-3.0
```

Distributed under GPL-3.0 **without any warranty**, including no warranty of fitness for a
particular purpose or of the correctness of search results.
