# CNKI Research Portable

**把中国知网（CNKI）文献检索接入 DSH Desktop 的可移植发行版 —— 解压、交给 DSH、审核、授权，即可使用。**

[简体中文](README.md) | [English](README_EN.md)

> **当前状态：`v1.0.0-rc.2` — Release Candidate（预发行）。**
> 允许在单机上安全完成的自动化测试已全部通过；**真实模型请求、真实机构检索与第二台电脑验收尚未执行**，
> 一律标注为 `NOT TESTED`，不计为通过。请不要把它当作已验证的生产发行版。

**版本标识**（四个层次，刻意不强行统一）

| 层次 | 值 | 说明 |
|---|---|---|
| 发行版本 | `1.0.0-rc.2` | 本仓库与发行资产的版本；预发行 |
| 核心 Bundle | `@local/dsh-cnki-research@1.0.0` | 被安装的插件本体；**冻结基线版本，代码未改动** |
| 上游 | `cnki-mcp 0.1.1` | 内置源码版本，与基线一致 |
| 发行等级 | Release Candidate | 未达到 Verified Release |

---

## 1. 项目简介

CNKI Research Portable 是一个面向 **DSH Desktop** 的插件发行版，解决的问题很具体：

DSH Desktop 可以通过 MCP 接入外部数据源，但要在中国知网上做文献检索，用户通常得自己装 Python、
建虚拟环境、配 Playwright 浏览器、手写 MCP 服务器配置、再调整 DSH 的插件清单 —— 每一步都可能失败，
而且失败时的表现往往是"插件装了，但一个工具都没有"。

本项目把这一整套东西打包成一个**自包含的 Windows 发行包**：

* 一个**路径无关**的 DSH Agent Preset（`CNKI Research`）；
* 一个 stdio 模式的 MCP 启动器，暴露 **8 个知网检索工具**；
* 一份**固定版本、随包内置**的上游 `cnki-mcp` 源码与锁定文件；
* 一个带**生产数据门禁**、备份、卸载与回滚的安装器；
* 一套可以离线复跑的自检与静态测试。

它**不是**一个新的知网客户端，也不提供任何绕过权限的能力。检索能力来自上游项目
[`cnki-mcp`](#5-上游与致谢)，本项目负责的是集成、部署与工程化。

---

## 2. 功能特性

### 2.1 八个 CNKI MCP 工具

安装后，**只有** `CNKI Research` 会话能看到这 8 个工具（`mcp__cnki__*`）：

| 工具 | 必填参数 | 可选参数 | 用途 |
|---|---|---|---|
| `easy-search` | `keywords` | `limit`（默认 10）、`sort_by` | 关键词快速检索 |
| `advanced-search` | — | `title`、`author`、`year_from`、`year_to`、`journal`、`keywords`、`subject`、`abstract`、`institution`、`fund`、`doi`、`document_type`、`source_types`、`sort_by`、`limit`（默认 10） | 多字段组合检索 |
| `get-info-from-url` | `url` | — | 按知网详情页 URL 取题录 |
| `get-info-by-detail` | `title` | `authors`、`year`、`year_from`、`year_to`、`journal`、`keywords`、`subject`、`abstract`、`institution`、`fund`、`doi`、`document_type`、`source_types`、`sort_by`、`limit`（默认 10） | 按题名/作者等精确定位并取详情 |
| `list-journal` | `issn`、`year`、`vol` | — | 按 ISSN 列出某年期目 |
| `search-issn` | `journal` | — | 按期刊名查 ISSN |
| `login` | — | `profile` | 打开浏览器完成机构认证 |
| `logout` | — | — | 清除登录状态 |

另提供 1 个 MCP 资源 `profile://list`，用于列出本机已配置的 CNKI Profile。

> `get-info-by-detail` 的 `title` 是**必填参数**。历史上一次 Schema 清洗曾把它当作注解删掉，
> 导致该工具不可用；现在有专门的回归断言守着这一点。

### 2.2 CNKI Research Agent Preset

* Preset id `cnki-research`，显示名 **CNKI Research**，`order: 5`。
* 继承 Standard 的标准能力（文件、命令、计划、委派、待办、Web 等），额外挂上：
  MCP 客户端、Skill 文件系统与 `tool-skill`。
* 没有 CNKI Profile 时**不会**让 Preset 加载失败：启动器会降级启动并在日志中提示，
  由 `login` 引导认证（`--require-profile` 可恢复"无 Profile 即退出"的严格行为）。

### 2.3 Creator 自动安装

用户不需要手敲 PowerShell。把 `INSTALL_PROMPT.md` 交给 DSH 的 **Creator** 模式，它会：

1. 校验发行包结构与哈希；
2. 跑一次只读的 `-Action check` 并用中文解释每条结果；
3. 就"装 uv / 下载 Chromium / 装到哪个 Profile"逐项征求同意；
4. 执行安装并汇报；
5. 输出结构化安装报告，每个字段只用 `PASS` / `FAIL` / `WARN` / `NOT TESTED`。

### 2.4 独立依赖部署

* Python 依赖用 `uv sync --frozen` 按**随包的** `uv.lock` 精确复现，全部传递依赖版本被锁定。
* 虚拟环境建在**安装根目录**下的 `.venv`，使用 `--no-editable`，包被真正复制进 `site-packages`，
  因此安装根目录可以整体搬走。
* 上游源码随包内置（`upstream/cnki-mcp/`，含 `LICENSE` 与 `uv.lock`），
  满足 GPL-3.0 的源码可得性要求，且不依赖 GitHub 可达性。
* 目标机不需要 Node，也不需要预装任何 Python 包；`uv` 缺失时由安装器按记录版本安装。

### 2.5 浏览器机构认证

* `login` 工具会打开一个**可见的** Chromium 窗口，由**用户本人**完成学校/机构的 SSO 或验证码。
* 发行包**不含**任何账号、Cookie、`storage_state.json` 或预设机构。
* 登录状态保存在**目标机**的 `%USERPROFILE%\.cnki-mcp\profiles\<名称>\` 下，不随包分发。
* `login` 存在约 120 秒的等待窗口；超时以工具真实返回为准，不会被伪造成成功。

### 2.6 Windows 路径适配

`bundle/cnki-research/cordis.patch.yml` 中**没有任何盘符、用户名或开发目录**。
所有位置都在条目激活时用 `!!js` 求值：

| 配置项 | 解析顺序 |
|---|---|
| Bundle 目录 | `createRequire(baseUrl)` 解析 `@local/dsh-cnki-research/package.json` |
| `customSkillDirs[0]` | `<bundle>/skills` |
| MCP `args[0]` | `<bundle>/launcher/cnki_research_launcher.py` |
| MCP `cwd` | `<bundle>` |
| MCP `command` | `$CNKI_RESEARCH_PYTHON` → `<bundle>/portable.runtime.json` → `<installRoot>/.venv/Scripts/python.exe` → `.../bin/python` → PATH 上的 `python` |

每个表达式整体 `try/catch`，**永远返回字符串**：缺少任何可选文件只会降级，不会让 Preset 激活失败。
安装根目录包含**空格与中文**的情况由静态测试 `A7` 组实证。

### 2.7 安装安全门禁

这是本项目最刻意设计的一块：

* **生产数据门禁**：任何会改动真实 `%USERPROFILE%\.dsh`（会话、存储、凭据、CNKI 登录态）的
  动词，未显式传入 `-AllowProductionProfile` 时**直接拒绝执行**，并打印以 `REFUSED:` 开头的说明。
* **`-CnkiProfile` 单独设门**：它会改写真实的 `%USERPROFILE%\.cnki-mcp\profiles\config.json`，
  该目录不在 `$DSH_HOME` 内，因此同样需要显式授权。
* **`-Json` 不等于同意**：诊断性 JSON 调用不会因为"输出了 JSON"就获得修改权限。
* **Junction 安全**：唯一的删除入口只对重解析点执行**非递归** `Directory.Delete`；
  发现 `.venv` 内存在嵌套链接时拒绝删除。
* **不覆盖未知安装**：目标 Profile 已存在同名插件时默认拒绝，需显式 `-Force`。

### 2.8 卸载与回滚

* `-Action uninstall`：走官方 `dsh plugin` 接口移除，并清理自身留下的 junction 与运行时文件。
* `-Action rollback`：从**安装前**的备份恢复 Profile 的 `package.json` 与锁文件，
  必要时用 `dsh plugin add` 重建 bundle 链接，然后断言 Profile 能够解析该 bundle。
* 安装前会把 Profile 的 `package.json`、`pnpm-lock.yaml` 备份到 `_portable\backups\<时间戳>\`。
* 卸载与回滚**不触碰**你的 DSH 会话、工作区、其他插件与其他 Profile。

### 2.9 跨项目文献检索

CNKI Research 会话检索到的题录是结构化数据，可以直接交给其他 DSH 项目使用。
工具作用域被限制在 `CNKI Research` 预设内，因此 **Standard 与 Creator 会话拿不到这些工具**；
同时，**读一份文档并不会获得任何 MCP 工具权限** —— 权限只由 Preset 的作用域决定。

---

## 3. 快速安装

**前置条件**：Windows 10/11 x64、已安装并可用的 DSH Desktop、能联网（首次安装需下载依赖）、
以及**你自己合法的知网访问权限**。

1. **下载 Release**
   从 Releases 页面获取同一版本的 `CNKI-Research-Portable-1.0.0-rc.2.zip` 与
   `CNKI-Research-Portable-1.0.0-rc.2.zip.sha256`。
2. **校验哈希**
   ```powershell
   Get-FileHash .\CNKI-Research-Portable-1.0.0-rc.2.zip -Algorithm SHA256
   ```
   与 `.sha256` 文件中的值逐字符比对。不一致就**停止**，不要安装。
3. **解压到稳定目录**
   例如 `D:\Tools\CNKI-Research-Portable`。路径可以含空格与中文；
   但**不要**解压到稍后会清空的临时目录（虚拟环境会引用安装时的绝对路径）。
4. **打开 DSH Creator**
   启动 DSH Desktop → 新建会话 → 选择 **Creator（创造模式）**，
   把**工作目录**设为刚才解压出的目录。
5. **读取安装提示词**
   把 [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md) 的整段提示词发给 Creator。
6. **审核计划并授权**
   Creator 会先只做检查与计划。逐项确认无误后再批准；装到日常 `desktop` Profile 时，
   它需要 `-AllowProductionProfile` —— 这个开关应当由**你**授权，而不是由模型自行添加。
7. **选择 CNKI Research 并登录检索**
   刷新 DSH 页面 → 新建会话 → Agent 预设选 **CNKI Research** →
   让它调用 `mcp__cnki__login`，在弹出的 Chromium 窗口里完成机构认证 →
   然后说"帮我检索生态文明，3 条"。

完整的用户操作、逐步验收清单与常见问题见 **[DEPLOYMENT_README.md](DEPLOYMENT_README.md)**。
想先确认这台电脑能不能装（不修改任何东西）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action check
```

---

## 4. 兼容性

已经**实测**过的组合：

| 项目 | 已验证 |
|---|---|
| 操作系统 | Windows 11 x64 |
| DSH Desktop | `0.2.0-rc.2` |
| Electron | `44.0.0` |
| Python | 3.12.0（系统解释器）；DSH 自带 3.12.14 |
| `uv` | 0.12.15（安装器可自动安装） |
| `cnki-mcp` | 0.1.1（随包内置） |
| `mcp` / `playwright` | 1.30.0 / 1.63.0（由 `uv.lock` 锁定） |
| Playwright Chromium | `chromium-1243` |

声明的 DSH 版本区间为 `>=0.2.0-rc.2 <0.3.0`，但**只有 `0.2.0-rc.2` 被实测**。

**明确未验证**：Windows 10 x64、Windows ARM64、Linux、macOS；更早或更新的 DSH 版本；
UNC 路径；只读安装位置；超过 200 字符的深层路径。**不声称兼容所有 DSH 版本。**
细节见 [docs/03-兼容性矩阵.md](docs/03-兼容性矩阵.md)。

---

## 5. 上游与致谢

本项目**基于第三方开源项目** [`cnki-mcp`](https://github.com/SepineTam/cnki-mcp)
（作者 **Sepine Tam / 谭淞**，版本 `0.1.1`，许可证 **GNU GPL-3.0**）。

* 上游源码以**逐字节一致**的方式内置在 [`upstream/cnki-mcp/`](upstream/cnki-mcp/)，
  包含其原始 `LICENSE`、`pyproject.toml`、`uv.lock`、`src/` 与 `tests/`。
* 上游许可证全文随包提供；根目录 [`LICENSE`](LICENSE) 与
  [`upstream/cnki-mcp/LICENSE`](upstream/cnki-mcp/LICENSE) 内容相同。
* 逐文件哈希记录在 [docs/provenance/upstream-src.sha256.json](docs/provenance/upstream-src.sha256.json)。
* 测试用的一处 `js-yaml` 副本以 MIT 许可证分发，见
  [tools/vendor/js-yaml/LICENSE](tools/vendor/js-yaml/LICENSE)。

**本项目新增的部分**（`bundle/cnki-research/` 的 Preset 声明与启动器、`tools/`、`tests/`、
`docs/`、安装器与发行工程）主要提供 **DSH Desktop 集成、Portable 部署与相关工程能力**。

**免责与关系声明**

* 本项目**与中国知网（CNKI）及上游作者均不存在任何未经证实的官方合作关系**，
  也未获得其背书或授权。
* 用户**必须自行具备合法的文献访问权限**（机构订阅或个人合法访问）。
* 本项目**不提供**机构账号、Cookie、密码或任何绕过权限的功能，也不提供论文全文下载。
* 请遵守知网的使用条款与所在机构的规定。上游项目本身即声明为个人学习项目，与知网无隶属关系。

第三方组件与许可证清单见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

---

## 6. 已知限制

请务必读完这一节再判断它是否适合你。

**发行等级与未完成的验收**

* 当前是 **Release Candidate**，不是 Verified Release。
* `REAL_MODEL_REQUEST_STATUS = NOT TESTED` —— 没有启动 DSH 宿主做真实模型请求验证。
* `REAL_CNKI_SEARCH_STATUS = NOT TESTED` —— 没有用真实机构账号完成真实检索验收。
* **没有在第二台电脑上验收。** 全部安装证据来自同一台 Windows 11 x64 主机，
  且运行在隔离的 `DSH_HOME` + `USERPROFILE` 沙箱中。
* **Standard/Creator 的工具隔离是结构性推断而非界面实测**：已验证"预设内只有一条 MCP 行、
  且该预设只有一份引用"，但尚未在运行中的 DSH 界面里直接观察其他模式的工具目录。

**功能边界**

* 只做**检索与元数据**，不提供全文下载。
* 首次安装需要联网（下载 `uv`、Python 依赖与 Chromium）。
* 机构认证必须由本人手动完成，无法自动化。
* 只支持 Windows x64。
* `-Action upgrade` 目前等同于重装，不比较版本、不阻止降级。
* 上游以**内容哈希**固定，而非 git commit（上游树不含 `.git`）。
* 安装根目录应当**保持稳定**：在里面建的虚拟环境会引用该路径。
* `login` **不会**替你创建机构 Profile；首次认证需要在工具弹出的浏览器里完成机构侧流程。

**安全边界**

* 安装器**不会**主动重启或关闭 DSH；需要刷新页面时它会明确告诉你。
* 本项目不读取、不导出、不记录你的账号密码与 Cookie。

---

## 7. 技术文档

| 文档 | 内容 |
|---|---|
| [DEPLOYMENT_README.md](DEPLOYMENT_README.md) | 用户部署与三步验收指南（推荐首选） |
| [INSTALL_PROMPT.md](INSTALL_PROMPT.md) | 可直接粘贴给 DSH 的安装提示词 |
| [START_HERE.md](START_HERE.md) | 入口索引：按你的角色选择该读哪份 |
| [docs/01-架构与路径契约.md](docs/01-架构与路径契约.md) | Preset / MCP / 启动器 / Skill 的结构与路径契约 |
| [docs/02-安装卸载与回滚.md](docs/02-安装卸载与回滚.md) | 安装、卸载、回滚、诊断与故障排查 |
| [docs/03-兼容性矩阵.md](docs/03-兼容性矩阵.md) | 已验证 / 未验证矩阵 |
| [docs/04-升级与版本维护.md](docs/04-升级与版本维护.md) | 升级策略与维护者操作 |
| [docs/05-测试报告.md](docs/05-测试报告.md) | 测试总览与判定标准 |
| [docs/06-设计取舍.md](docs/06-设计取舍.md) | 路径无关、机构无关与上游分发策略的取舍 |
| [docs/provenance/](docs/provenance/) | 基线来源与逐文件哈希记录 |
| [bundle/cnki-research/README.md](bundle/cnki-research/README.md) | 被安装的插件本体说明 |
| [CHANGELOG.md](CHANGELOG.md) | 版本历史与已修复缺陷 |

**自己复核（不需要 DSH，也不需要联网）**

```powershell
node tools\build_manifest.mjs --check      # 载荷清单是否与磁盘一致
node tests\test_static_package.mjs         # 18 项静态校验：哈希、路径、凭据、许可证、结构
```

第二条命令在公开仓库的清理版上实测为 `18 passed, 0 warning(s), 0 failure(s)`。
完整自动化套件（含真实 stdio MCP 握手与隔离 Profile 安装）用
`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_all.ps1`；
它会改动本机环境、需要真实的 DSH 与网络，请先读文档再运行。

---

## 8. License

**GNU General Public License v3.0（`GPL-3.0-only`）** —— 全文见 [LICENSE](LICENSE)。

本发行版的 stdio 启动器在运行时导入并链接上游 `cnki-mcp`（GPL-3.0），二者构成结合作品，
因此整体以与上游一致的 GPL-3.0 发布。第三方组件、各自许可证与来源见
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

```
Copyright (C) 2026  CNKI Research Portable contributors
Upstream cnki-mcp: Copyright (C) Sepine Tam (谭淞), GPL-3.0
```

本项目按 GPL-3.0 分发，**不提供任何担保**，包括不保证适用于特定用途或检索结果的正确性。
