# CNKI Research Portable

**A portable Windows distribution that brings CNKI (China National Knowledge Infrastructure) literature search into DSH Desktop — unzip, hand it to DSH, review, authorise, and it runs.**

[简体中文](README.md) | [English](README_EN.md)

> **Status: `v1.0.0-rc.2` — Release Candidate (pre-release).**
> Every automated test that can be run safely on a single machine passes. **Real model requests,
> real institutional searches and second-machine acceptance have NOT been performed** and are
> marked `NOT TESTED`; they are not counted as passes. Do not treat this as a verified
> production release.

**Version identity** (four levels, deliberately not forced to be equal)

| Level | Value | Meaning |
|---|---|---|
| Distribution | `1.0.0-rc.2` | Version of this repository and its release assets; pre-release |
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
* A missing CNKI profile does **not** break preset loading: the launcher starts in a degraded mode
  and lets `login` drive authentication (`--require-profile` restores the strict "no profile, exit"
  behaviour).

### 2.3 Creator-driven installation

You do not type PowerShell commands. Hand `INSTALL_PROMPT.md` to DSH's **Creator** mode and it will:

1. verify the package structure and hashes;
2. run a read-only `-Action check` and explain every result;
3. ask for consent before installing `uv`, downloading Chromium, or choosing a profile;
4. perform the install and report back;
5. emit a structured report using only `PASS` / `FAIL` / `WARN` / `NOT TESTED`.

### 2.4 Independent dependency deployment

* Python dependencies are reproduced exactly with `uv sync --frozen` against the **vendored**
  `uv.lock`; every transitive dependency version is pinned.
* The virtual environment lives in `.venv` under the **install root**, uses `--no-editable`, and
  copies packages into `site-packages`, so the install root can be moved afterwards.
* Upstream source ships in `upstream/cnki-mcp/` (with its `LICENSE` and `uv.lock`), satisfying the
  GPL-3.0 source-availability requirement without depending on GitHub reachability.
* The target machine needs neither Node nor any pre-installed Python package; if `uv` is missing the
  installer installs the recorded version.

### 2.5 Browser-based institutional authentication

* `login` opens a **visible** Chromium window and **you** complete your institution's SSO or CAPTCHA.
* The distribution contains **no** account, cookie, `storage_state.json` or preset institution.
* Sign-in state is stored on the **target** machine under
  `%USERPROFILE%\.cnki-mcp\profiles\<name>\` and is never shipped.
* `login` waits about 120 seconds; the real tool response decides success, and nothing is faked.

### 2.6 Windows path adaptation

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

### 2.7 Installation safety gates

This is the most deliberately designed part of the project:

* **Production-data gate** — any verb that would modify the real `%USERPROFILE%\.dsh` (sessions,
  storage, credentials, CNKI sign-in state) is **refused outright** unless
  `-AllowProductionProfile` is passed explicitly, printing a `REFUSED:` explanation.
* **`-CnkiProfile` is gated separately**, because it rewrites the real
  `%USERPROFILE%\.cnki-mcp\profiles\config.json`, which lives outside `$DSH_HOME`.
* **`-Json` is not consent** — a diagnostic JSON call gains no mutation authority.
* **Junction safety** — the only removal path performs a **non-recursive** `Directory.Delete` on a
  reparse point, and refuses to delete `.venv` when nested links are present.
* **No silent overwrite** — a pre-existing package with the same name is refused unless `-Force`.

### 2.8 Uninstall and rollback

* `-Action uninstall` removes the plugin through the official `dsh plugin` interface and cleans up
  its own junction and runtime files.
* `-Action rollback` restores the profile's `package.json` and lockfile from the **pre-install**
  backup, runs `dsh plugin add` when the bundle link must be rebuilt, and then asserts the profile
  resolves the bundle.
* Before installing, the profile's `package.json` and `pnpm-lock.yaml` are backed up to
  `_portable\backups\<timestamp>\`.
* Uninstall and rollback **do not touch** your DSH sessions, workspaces, other plugins or other
  profiles.

### 2.9 Cross-project literature search

Records retrieved in a CNKI Research session are structured data and can be handed to other DSH
projects. Tool scope is confined to the `CNKI Research` preset, so **Standard and Creator sessions
do not receive these tools**. Reading any document grants **no** MCP tool access — scope is decided
by the preset alone.

---

## 3. Quick install

**Prerequisites**: Windows 10/11 x64, a working DSH Desktop installation, internet access for the
first install, and **your own lawful CNKI access**.

1. **Download the release** — from the Releases page, take `CNKI-Research-Portable-1.0.0-rc.2.zip` and
   `CNKI-Research-Portable-1.0.0-rc.2.zip.sha256` from the same version.
2. **Verify the hash**
   ```powershell
   Get-FileHash .\CNKI-Research-Portable-1.0.0-rc.2.zip -Algorithm SHA256
   ```
   Compare character by character with the `.sha256` file. If it differs, **stop**.
3. **Extract to a stable directory** — e.g. `D:\Tools\CNKI-Research-Portable`. Spaces and CJK
   characters are fine, but do **not** use a temporary folder you will later delete (the virtual
   environment references the install-time absolute path).
4. **Open DSH Creator** — start DSH Desktop, create a session in **Creator** mode, and set the
   working directory to the extracted folder.
5. **Read the install prompt** — send the whole prompt block from
   [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md).
6. **Review and authorise** — Creator first does checks and a plan only. Approve it once every item
   is clear. Installing into your everyday `desktop` profile requires `-AllowProductionProfile`,
   and that switch must be authorised by **you**, not added by the model.
7. **Select CNKI Research and search** — refresh the DSH page, create a new session, pick the
   **CNKI Research** preset, call `mcp__cnki__login`, complete sign-in in the Chromium window, then
   ask for a search.

The full user walkthrough, step-by-step acceptance checklist and troubleshooting are in
**[DEPLOYMENT_README.md](DEPLOYMENT_README.md)** (Chinese). To check whether this machine can run it
at all, without modifying anything:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action check
```

---

## 4. Compatibility

Actually verified:

| Item | Verified |
|---|---|
| OS | Windows 11 x64 |
| DSH Desktop | `0.2.0-rc.2` |
| Electron | `44.0.0` |
| Python | 3.12.0 (system interpreter); DSH bundles 3.12.14 |
| `uv` | 0.12.15 (the installer can install it) |
| `cnki-mcp` | 0.1.1 (vendored) |
| `mcp` / `playwright` | 1.30.0 / 1.63.0 (pinned by `uv.lock`) |
| Playwright Chromium | `chromium-1243` |

The declared DSH range is `>=0.2.0-rc.2 <0.3.0`, but **only `0.2.0-rc.2` has been exercised**.

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
portable deployment and related engineering**.

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

* This is a **Release Candidate**, not a Verified Release.
* `REAL_MODEL_REQUEST_STATUS = NOT TESTED` — no DSH host was booted to make a real model request.
* `REAL_CNKI_SEARCH_STATUS = NOT TESTED` — no real institutional account performed a real search.
* **No second machine acceptance.** All installation evidence comes from a single Windows 11 x64
  host, inside an isolated `DSH_HOME` + `USERPROFILE` sandbox.
* **Standard/Creator tool isolation is a structural inference, not an observed one**: it is verified
  that the preset declares exactly one MCP row and is referenced exactly once, but the other modes'
  tool catalogues have not been inspected in a running DSH UI.

**Functional limits**

* Search and metadata only; **no full-text download**.
* The first install needs internet access (`uv`, Python dependencies, Chromium).
* Institutional authentication must be completed manually; it cannot be automated.
* Windows x64 only.
* `-Action upgrade` currently behaves like a reinstall: it neither compares versions nor prevents
  downgrades.
* Upstream is pinned by **content hash**, not by git commit (the upstream tree has no `.git`).
* Keep the install root **stable**; the virtual environment references that path.
* `login` does **not** create an institutional profile for you; the first sign-in must be completed
  through the institution's own flow in the browser window the tool opens.

**Safety boundaries**

* The installer **never** restarts or shuts down DSH; when a page refresh is needed it says so.
* The project does not read, export or log your account name, password or cookies.

---

## 7. Documentation

| Document | Contents |
|---|---|
| [DEPLOYMENT_README.md](DEPLOYMENT_README.md) | User deployment and three-step acceptance guide (Chinese, recommended first) |
| [INSTALL_PROMPT.md](INSTALL_PROMPT.md) | Install prompt you can paste into DSH (Chinese) |
| [START_HERE.md](START_HERE.md) | Entry index: which document to read for your role (Chinese) |
| [docs/01-架构与路径契约.md](docs/01-架构与路径契约.md) | Preset / MCP / launcher / skill structure and path contract |
| [docs/02-安装卸载与回滚.md](docs/02-安装卸载与回滚.md) | Install, uninstall, rollback, diagnostics and troubleshooting |
| [docs/03-兼容性矩阵.md](docs/03-兼容性矩阵.md) | Verified / unverified matrix |
| [docs/04-升级与版本维护.md](docs/04-升级与版本维护.md) | Upgrade strategy and maintainer operations |
| [docs/05-测试报告.md](docs/05-测试报告.md) | Test summary and pass criteria |
| [docs/06-设计取舍.md](docs/06-设计取舍.md) | Trade-offs behind path independence, institution neutrality and vendoring |
| [docs/provenance/](docs/provenance/) | Baseline provenance and per-file hashes |
| [bundle/cnki-research/README.md](bundle/cnki-research/README.md) | The installed plugin itself |
| [CHANGELOG.md](CHANGELOG.md) | Version history and fixed defects |

**Verify it yourself (no DSH, no network required)**

```powershell
node tools\build_manifest.mjs --check      # is the payload manifest current?
node tests\test_static_package.mjs         # 18 static checks: hashes, paths, credentials, licence, structure
```

The second command was actually run on this cleaned public repository and reported
`18 passed, 0 warning(s), 0 failure(s)`. The full suite (real stdio MCP handshake and an isolated
profile install) is `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_all.ps1`;
it modifies the local machine and needs a real DSH installation and network access, so read the
documentation before running it.

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
