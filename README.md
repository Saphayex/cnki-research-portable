# CNKI Research Portable

**把中国知网（CNKI）文献检索接入 DSH Desktop 的可移植发行版 —— 解压、交给 DSH、审核、授权，即可使用。**

[简体中文](README.md) | [English](README_EN.md)

> **当前状态：`v1.0.0-rc.3` — Pre-release（Release Candidate，非 Verified Release）：统一安装/升级包（unified installer）。**
> 本包把「全新安装」与「从 `1.0.0-rc.2` 的安全原地升级」合并进 **一个 ZIP**：
> 统一入口是 `tools\setup.ps1`；`tools\portable.ps1` 的旧命令与旧语义**逐字节保留**。
> 允许在单机上安全完成的自动化测试已全部通过；**Portable 发行版自身的真机会话、真实模型请求、
> 真实机构检索、第二台电脑验收与本轮统一升级的实机运行期激活尚未执行**，
> 一律标注为 `NOT TESTED`，不计为通过。请不要把它当作已验证的生产发行版。
> 本版本已重新冻结为 `1.0.0-rc.3` 统一发行包，官方发行包名是 `CNKI-Research-Portable-1.0.0-rc.3.zip`；
> 本轮**尚未发布**（Tag、push、GitHub Release 仍需维护者单独批准）。
>
> **RC3 修复**：DSH Desktop `0.2.1-rc.2` 移除了隐式 `{{cwd}}` 提示词变量（缺陷 `CNKI-021-001`）。
> RC3 删除了 Preset persona 中已失效的 `suffix: Your working directory is {{cwd}}.`，
> 保留 `{{model}}` prefix。本机**生产 Bundle**已在 `0.2.1-rc.2` 上通过真实验收；
> **Portable RC3 本身**尚需独立的安装与实机运行验收，详见第 4 节。

**版本标识**（刻意不强行统一）

| 层次 | 值 | 说明 |
|---|---|---|
| 发行版本 | `1.0.0-rc.3` | 本仓库与发行资产的版本；预发行 |
| 发行包类型 | 统一安装/升级包（unified installer） | 一个官方 ZIP 同时支持全新安装与 RC2 安全原地升级；官方发行包名 `CNKI-Research-Portable-1.0.0-rc.3.zip` |
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
* 一个**统一入口** `tools\setup.ps1`：同一个包既能**全新安装**，也能对已有的标准 RC2 安装做
  **事务化安全原地升级**（逐文件校验、失败自动恢复、逐字节回滚、不重装 venv、不重建 Profile）；
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
* persona 只引用 DSH 已注册的提示词变量（`{{model}}`）。DSH `0.2.1-rc.2` 移除的
  `{{cwd}}` 已在 RC3 中删除，并由静态回归断言 `A7.promptVariables` 守护。
* 没有 CNKI Profile 时**不会**让 Preset 加载失败：启动器会降级启动并在日志中提示，
  由 `login` 引导认证（`--require-profile` 可恢复"无 Profile 即退出"的严格行为）。

### 2.3 统一入口：一个包，两种用法

包内的统一入口是 **`tools\setup.ps1`**，动作为
`check` / `plan` / `install` / `upgrade` / `verify` / `status` / `rollback` / `uninstall`，
退出码统一为 `0`（成功/无需操作）、`2`（拒绝/FAIL/状态未知）、`1`（工具内部错误）。

| 你的情况 | 命令 | 会发生什么 |
|---|---|---|
| 新用户 | `setup.ps1 -Action check` → `-Action plan` → `-Action install -Yes` | 只读检查/计划后，委托原安装器完成全新安装（venv、Chromium、`dsh plugin` 注册） |
| 已有标准 RC2 安装 | `check -InstallRoot <RC2 根>` → `plan -InstallRoot <RC2 根>` → **退出 DSH** → `upgrade -InstallRoot <RC2 根> -PlanId <id> -Yes` | 事务化原地升级：只替换变化的发行文件 + 2 个环境元数据；失败自动恢复；可逐字节回滚 |
| 已是 RC3（统一版或冻结版） | `setup.ps1 -Action check` / `-Action upgrade` | 识别为 `RC3_ALREADY_INSTALLED`，安全 no-op（exit 0，不写任何文件） |
| 内容未知/被修改/混合 | `check` / `plan` / `upgrade` | **拒绝**（exit 2）并列出冲突文件；不会覆盖你的修改 |

要点：

* **安全升级只存在于 `setup.ps1 -Action upgrade`**。`portable.ps1 -Action upgrade` 保持旧语义
  （重装覆盖），明确标注为 **LEGACY**，不是安全增量路径。
* 升级**不修改** `portable.ps1`、**不重跑**插件管理器、**不重建** Profile junction、
  **不重建 venv**、**不需要联网**；升级前必须**正常退出 DSH**（升级器不会替你关闭，也绝不强杀）。
* **DSH 模式原则**：安全升级只做文件级写入，不需要 Plugin Manager，因此在一个**普通 PowerShell
  窗口**里执行即可（DSH Standard 会话里的命令工具也可以）；只有全新安装、卸载、安装器回滚
  这类真正调用 `dsh plugin` 的操作，才需要 Creator/插件管理场景。
* 新 ZIP **必须解压到空目录**；解压覆盖旧安装目录会形成混合状态，`setup.ps1 -Action check`
  会 fail-closed 拒绝，不会尝试修复。

用户操作流程见第 3 节；完整命令与约束见 [`docs/04-升级与版本维护.md`](docs/04-升级与版本维护.md)。

### 2.4 Creator 自动安装（全新安装）

用户不需要手敲 PowerShell。把 `INSTALL_PROMPT.md` 交给 DSH 的 **Creator** 模式，它会：

1. 校验发行包结构与哈希；
2. 跑一次只读的 `setup.ps1 -Action check` / `-Action plan` 并用中文解释每条结果；
3. 就"装 uv / 下载 Chromium / 装到哪个 Profile"逐项征求同意；
4. 执行安装并汇报；
5. 输出结构化安装报告，每个字段只用 `PASS` / `FAIL` / `WARN` / `NOT TESTED`。

> 已有 RC2 安装的**升级**不通过 Creator 自动执行：APPLY 必须在 DSH 正常退出后在独立
> PowerShell 窗口中运行（见第 3.2 节）。

### 2.5 独立依赖部署

* Python 依赖用 `uv sync --frozen` 按**随包的** `uv.lock` 精确复现，全部传递依赖版本被锁定。
* 虚拟环境建在**安装根目录**下的 `.venv`，使用 `--no-editable`，包被真正复制进 `site-packages`，
  因此安装根目录可以整体搬走。
* 上游源码随包内置（`upstream/cnki-mcp/`，含 `LICENSE` 与 `uv.lock`），
  满足 GPL-3.0 的源码可得性要求，且不依赖 GitHub 可达性。
* 目标机不需要 Node，也不需要预装任何 Python 包；`uv` 缺失时由安装器按记录版本安装。

### 2.6 浏览器机构认证

* `login` 工具会打开一个**可见的** Chromium 窗口，由**用户本人**完成学校/机构的 SSO 或验证码。
* 发行包**不含**任何账号、Cookie、`storage_state.json` 或预设机构。
* 登录状态保存在**目标机**的 `%USERPROFILE%\.cnki-mcp\profiles\<名称>\` 下，不随包分发。
* `login` 存在约 120 秒的等待窗口；超时以工具真实返回为准，不会被伪造成成功。

### 2.7 Windows 路径适配

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

### 2.8 安装与升级安全门禁

这是本项目最刻意设计的一块：

* **生产数据门禁**：任何会改动真实 `%USERPROFILE%\.dsh`（会话、存储、凭据、CNKI 登录态）的
  动词，未显式传入 `-AllowProductionProfile` 时**直接拒绝执行**，并打印以 `REFUSED:` 开头的说明。
* **`-CnkiProfile` 单独设门**（**仅原安装器 `tools\portable.ps1` 的 LEGACY 选项**；统一入口 `setup.ps1` 不接受该参数）：
  它会改写真实的 `%USERPROFILE%\.cnki-mcp\profiles\config.json`，该目录不在 `$DSH_HOME` 内，因此同样需要显式授权。
* **`-Json` 不等于同意**：诊断性 JSON 调用不会因为"输出了 JSON"就获得修改权限。
* **Junction 安全**：唯一的删除入口只对重解析点执行**非递归** `Directory.Delete`；
  发现 `.venv` 内存在嵌套链接时拒绝删除。
* **不覆盖未知安装**：目标 Profile 已存在同名插件时默认拒绝，需显式 `-Force`。
* **两棵树必须分开**：升级要求 `PackageRoot`（新解压的发行包）与 `InstallRoot`（旧 RC2 安装根）
  是两个独立目录；相等、互为祖先/后代或重解析点组合一律拒绝——这直接堵住
  "把新 ZIP 解压覆盖旧安装目录" 的误操作。
* **目标状态机 fail-closed**：只有 `RC2_CLEAN` / `RC2_HOTFIXED` 允许 PLAN/APPLY；
  `RC3_ALREADY_INSTALLED` 安全 no-op；其余（`UNKNOWN_OR_MODIFIED` 等）一律拒绝并列出冲突，
  **绝不自动修复或覆盖用户修改**。
* **planId 门**：APPLY 必须带由只读 PLAN 生成的 `-PlanId`；状态变化会使旧 id 失效，
  必须重新 PLAN，防止"看过的计划"与"实际执行"不一致。
* **DSH 运行门**：真实 Profile + DSH 正在运行 ⇒ 拒绝 APPLY/ROLLBACK（`DSH_IN_USE`）；
  绝不强杀进程，也不改 Profile 触发 HMR。
* **升级不联网**：升级引擎只读包内已校验的目标字节 + 两个环境元数据文件；
  Node/Git/Python/uv 都不需要，`-Offline` 只影响全新安装的依赖下载。

### 2.9 卸载与回滚

* `-Action uninstall`：走官方 `dsh plugin` 接口移除，并清理自身留下的 junction 与运行时文件。
* `-Action rollback`：从**安装前**的备份恢复 Profile 的 `package.json` 与锁文件，
  必要时用 `dsh plugin add` 重建 bundle 链接，然后断言 Profile 能够解析该 bundle。
* 安装前会把 Profile 的 `package.json`、`pnpm-lock.yaml` 备份到 `_portable\backups\<时间戳>\`。
* 卸载与回滚**不触碰**你的 DSH 会话、工作区、其他插件与其他 Profile。

### 2.10 跨项目文献检索

CNKI Research 会话检索到的题录是结构化数据，可以直接交给其他 DSH 项目使用。
工具作用域被限制在 `CNKI Research` 预设内，因此 **Standard 与 Creator 会话拿不到这些工具**；
同时，**读一份文档并不会获得任何 MCP 工具权限** —— 权限只由 Preset 的作用域决定。

### 2.11 包结构、安装根与完整性链

**统一发行 ZIP 解压后的 PackageRoot 就是 RC3 发行树**，另外带三类**包内发布元数据**：

| 类别 | 内容 | 是否安装到安装根 |
|---|---|---|
| 发行载荷 P（115 个文件） | 冻结 RC3 的 107 个载荷 + 8 个统一新增载荷（`tools\setup.ps1`、`tools\lib\UpgradeCommon.ps1`、`tools\build_unified_release.ps1`、`tests\Test-UnifiedMatrix.ps1`、`tests\lib\UnifiedFixtures.ps1`、`tests\lib\UnifiedAssert.ps1`、`tests\Test-UnifiedVerification.ps1`、`tests\test_unified_package.mjs`） | **是** |
| 分发清单 | `manifest.json`（`schemaVersion 1`；记录 115 个载荷的逐文件大小与 SHA-256；保留 `install.entryPoint = tools/portable.ps1`，新增 `install.setupEntryPoint = tools/setup.ps1` 与 `upgrade` 元数据块） | **是**（安装根保留一份 `manifest.json`） |
| 发布元数据 | `SHA256SUMS.txt`（包内完整性清单）、`upgrade-data\rc2-to-rc3.json`（RC2→RC3 升级契约：只有哈希与规则，无目标文件副本）、`upgrade-data\README.md` | **否**（永不复制进安装根） |

* ZIP 内**没有** `payload\` 之类的目标文件副本；升级目标字节直接取自包根的同相对路径文件。
* 升级完成后安装根 = 115 个载荷 + `manifest.json` + 安装器自己维护的运行期目录
  （`.venv\`、`_portable\`、`bundle\cnki-research\portable.runtime.json`）。
* **完整性链（无循环）**：外部 `CNKI-Research-Portable-1.0.0-rc.3.zip` 的 SHA-256
  （`.sha256` sidecar + 发布级 `SHA256SUMS.txt`）→ 包内 `SHA256SUMS.txt` → `manifest.json` /
  `upgrade-data\rc2-to-rc3.json` → 全部载荷字节。升级元数据**不内嵌**目标 ZIP 哈希、自身哈希或
  `SHA256SUMS.txt` 哈希（否则循环）；目标 `manifest.json` 的身份由"`SHA256SUMS.txt` 中的
  manifest 条目 + `manifest.files[]` 与目标哈希逐项相等"共同证明。
* **发布身份**：本轮已把 `1.0.0-rc.3` 重新冻结为统一发行包，**官方发行包名固定为**
  `CNKI-Research-Portable-1.0.0-rc.3.zip`（所有下载/校验命令一律使用该名；构建机内部产物的旧候选名
  不对外、也不出现在任何用户命令中）。`v1.0.0-rc.3` Tag、push 与 GitHub Release 发布
  **需要维护者另行批准**，本轮不发布、不推送、不移动 Tag。历史冻结 RC3 ZIP 的哈希（`f4e914d1…`）
  只作为**旧候选身份**审计记录，不复用。发布校验策略：ZIP + 同名 `.sha256` sidecar +
  发布级 `SHA256SUMS.txt`，不提供第二份同名 SHA 文件。

---

## 3. 使用方式

> 统一入口是 `tools\setup.ps1`。它先只读识别当前安装状态，再选择**
> 全新安装 / 安全升级 / 验证 / 回滚**。动作：`check`、`plan`、`install`、`upgrade`、
> `verify`、`status`、`rollback`、`uninstall`；退出码 `0` 成功（含"已是 RC3 无需操作"）、
> `2` 拒绝/FAIL/状态未知、`1` 工具内部错误。

### 3.1 全新安装（解压到空目录）

**前置条件**：Windows 10/11 x64、已安装并可用的 DSH Desktop、能联网（首次安装需下载依赖）、
以及**你自己合法的知网访问权限**。

1. **下载发行包**
   获取 `CNKI-Research-Portable-1.0.0-rc.3.zip` 与
   `CNKI-Research-Portable-1.0.0-rc.3.zip.sha256`
   （发布页另有发布级 `SHA256SUMS.txt`）。
2. **校验哈希**
   ```powershell
   Get-FileHash .\CNKI-Research-Portable-1.0.0-rc.3.zip -Algorithm SHA256
   ```
   与 `.sha256` 文件中的值逐字符比对。不一致就**停止**，不要安装。
3. **解压到空目录**
   例如 `D:\Tools\CNKI-Research-Portable`。路径可以含空格与中文；
   但**不要**解压到稍后会清空的临时目录（虚拟环境会引用安装时的绝对路径），
   **更不要**解压覆盖到已有的旧安装目录（见 3.2 与 3.3）。
4. **只读检查与计划**（不写任何东西）
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan
   ```
   首次应看到 `NOT_INSTALLED`（可以安装）以及 DSH / Python / uv / 浏览器的检查结果。
5. **打开 DSH Creator**（或在你自己的 PowerShell 里安装）
   启动 DSH Desktop → 新建会话 → 选择 **Creator（创造模式）**，
   把**工作目录**设为刚才解压出的目录；把 [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md)
   的整段提示词发给 Creator。
6. **审核计划并授权**
   Creator 会先只做检查与计划。逐项确认无误后再批准；装到日常 `desktop` Profile 时，
   安装命令需要 `-AllowProductionProfile` —— 这个开关应当由**你**授权，而不是由模型自行添加：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action install -Yes -AllowProductionProfile
   # 独立 Profile 试装（不需要该开关）：
   # ... -Action install -Yes -DshProfile cnki-trial
   # 离线安装（uv 缓存已预热）：
   # ... -Action install -Yes -Offline
   ```
7. **选择 CNKI Research 并登录检索**
   刷新 DSH 页面 → 新建会话 → Agent 预设选 **CNKI Research** →
   让它调用 `mcp__cnki__login`，在弹出的 Chromium 窗口里完成机构认证 →
   然后说"帮我检索生态文明，3 条"。

### 3.2 从 RC2 安全原地升级（已有标准安装）

适用于已用 **`1.0.0-rc.2` 原地安装（Layout A：解压目录即安装根）** 的用户。
升级是**事务化**的：逐文件备份与校验、失败自动恢复、可逐字节回滚；
**不重装 venv、不重跑插件管理器、不重建 junction、不需要联网**，
并保留 DSH 会话、凭据、CNKI 登录态与 Profile。

```powershell
# 0) 把统一发行 ZIP 解压到一个全新的空目录（不要覆盖 RC2 安装目录）

# 1) 只读检查（DSH 运行中也可执行）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check -InstallRoot "<RC2 安装根目录>"

# 2) 只读 PLAN（DSH 运行中也可执行）：记下输出里的 planId
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan -InstallRoot "<RC2 安装根目录>"

# 3) 正常退出 DSH（不要强杀进程），然后在独立 PowerShell 窗口执行 APPLY
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action upgrade -InstallRoot "<RC2 安装根目录>" -PlanId "<planId>" -Yes

# 4) 正常重新打开 DSH，验收后查看文件级完成状态
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action verify -InstallRoot "<RC2 安装根目录>"

# 5) 需要退回 RC2（事务逐字节回滚，含删除本次新增的文件）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action rollback -InstallRoot "<RC2 安装根目录>" -Yes
```

约束与边界：

* 只支持 **Layout A**；`-InstallRoot` 指向别处的“独立运行根”（Layout B）会被拒绝并给出人工迁移指引。
* 检测到 `UNKNOWN_OR_MODIFIED`（被修改/混合/损坏）时**拒绝写入**并列出冲突文件；不会自动修复。
* 状态变化会使旧 `planId` 失效；必须重新 `plan`。
* 真实 Profile + DSH 正在运行 ⇒ APPLY 被拒绝（`DSH_IN_USE`）。
* 文件级完成（`FILE_UPGRADE_COMPLETE`）**不等于**运行期验收：`DSH_RUNTIME_ACTIVATION_VERIFIED`
  仍为 `NOT TESTED`。
* **新 ZIP 必须解压到空目录**；解压覆盖旧安装目录会形成混合状态，`setup.ps1 -Action check`
  会 fail-closed 拒绝，**不会尝试修复**。

### 3.3 已经是 RC3 / 状态未知 / 未安装

| 检测状态 | `setup.ps1` 行为 |
|---|---|
| `RC3_ALREADY_INSTALLED`（统一版精确匹配） | CHECK exit 0；UPGRADE 为安全 no-op（`NOOP_ALREADY_TARGET`，零写入、零备份） |
| `RC3_ALREADY_INSTALLED`（冻结 RC3 精确匹配） | 同样安全 no-op；**已知限制**：不会自动补装统一工具链新增文件，核心版本已完整、无需操作即可继续使用 |
| `UNKNOWN_OR_MODIFIED` | CHECK/PLAN exit 2 并输出冲突清单；APPLY/ROLLBACK 拒绝；**不覆盖**用户修改 |
| `NOT_INSTALLED` | 推荐全新安装（`-Action install`） |
| `LAYOUT_SEPARATE_PACKAGE_ROOT`（Layout B） | 增量升级不支持；按 [`docs/04`](docs/04-升级与版本维护.md) 的人工迁移方案处理 |

### 3.4 旧命令兼容（LEGACY）

`tools/portable.ps1` 与 `tools/lib/PortableCommon.ps1` 相对已冻结 RC3 **逐字节未变**，
旧命令、旧文档里的 `-Action check/install/uninstall/rollback/status/diagnose` 继续有效。
但请区分：

| 命令 | 语义 |
|---|---|
| `setup.ps1 -Action upgrade` | **唯一安全增量升级**（事务化原地升级） |
| `portable.ps1 -Action upgrade` | **LEGACY**：等同"用当前包重新安装/覆盖"；不校验源状态、不比较版本、不阻止降级，**不是** RC2→RC3 的安全路径 |
| `portable.ps1 -Action plan` / `-DryRun` | **LEGACY 已知限制**：实现上会创建一份 Profile 备份目录，不是完全只读；只读计划请用 `setup.ps1 -Action plan` |
| `portable.ps1 -Action install` | 全新安装的底层实现；统一入口 `setup.ps1 -Action install` 会先做状态识别与门禁再委托它 |
| `portable.ps1 -Action uninstall` / `rollback` | 卸载与**安装器备份**回滚；`setup.ps1` 的同名动作按状态自动选择升级事务回滚或委托给它们 |

---

## 4. 兼容性

DSH Desktop 的兼容性必须**分三级**陈述，不能混为一谈：

| 级别 | 对象 | DSH 版本 | 结论 |
|---|---|---|---|
| 实机运行（Portable） | 本仓库构建的 Portable 发行包 | `0.2.0-rc.2` | **已验证**（历史实机记录） |
| 静态 + 隔离协议（Portable） | 本仓库构建的 Portable RC3 | `0.2.1-rc.2` | **已验证**（不包含真实会话与模型请求） |
| 实机运行（Portable RC3） | 本仓库构建的 Portable RC3 | `0.2.1-rc.2` | **`NOT TESTED`**（独立安装/会话验收未执行） |

其他已经**实测**过的组合：

| 项目 | 已验证 |
|---|---|
| 操作系统 | Windows 11 x64 |
| Electron | `44.0.0`（DSH 0.2.0-rc.2 / 0.2.1-rc.2） |
| Python | 3.12.0（系统解释器）；DSH 自带 3.12.14 |
| `uv` | 0.12.15（安装器可自动安装） |
| `cnki-mcp` | 0.1.1（随包内置） |
| `mcp` / `playwright` | 1.30.0 / 1.63.0（由 `uv.lock` 锁定） |
| Playwright Chromium | `chromium-1243` |

关于 DSH `0.2.1-rc.2`，必须精确区分两件事：

* **本机生产 Bundle**（`@local/dsh-cnki-research@1.0.0` 的已修复生产副本，**不是**本 Portable 包）
  已在 `0.2.1-rc.2` 上完成真实验收：真实模型请求、Preset Prompt Assembly、
  8 个 MCP 工具注册、Provider 接受原始 Schema、MCP 连接与资源调用、
  `mcp__cnki__login` 复用既有 Profile、`mcp__cnki__easy-search` 返回真实题录，均 PASS。
  这证明**修复逻辑**在 `0.2.1-rc.2` 上有效，但**不构成** Portable RC3 的实机 PASS。
* **Portable RC3 本身**只完成了静态检查与隔离 DSH_HOME 下的协议/组合验证；
  尚未在 `0.2.1-rc.2` 上做独立安装后的真实会话。因此 `0.2.1-rc.2` **不进入**
  Portable 的 verified list，安装器对其报告 `UNTESTED`（不阻止安装）。

声明的 DSH 版本区间为 `>=0.2.0-rc.2 <0.3.0`。旧版 `0.2.0-rc.2` 的回归结论为：
**静态兼容成立**（被删除的 suffix 是可选字段、默认空串，0.2.0 的 persona Schema 与
`{{model}}` 均未变），**实机回归 `LIVE NOT TESTED`** —— 没有为了测试旧版而回退生产 Desktop。

**升级能力的验证边界**（与全新安装分开陈述）：

* 统一升级只做**文件级**替换（15 个变化的发行文件 + 8 个新增文件 + `manifest.json` + 2 个环境
  元数据），不改变 Bundle 代码、上游源码、venv 或 Profile 契约，因此**不会引入新的 DSH 版本要求**。
* 升级路径按 A–K 组测试矩阵在**隔离沙箱**中重新执行（RC2_CLEAN / RC2_HOTFIXED、幂等、拒绝未知
  状态、逐字节回滚、故障注入、用户数据保护、安装器回归、包完整性与 MCP 协议）；
  具体执行结果与证据以构建时实际运行记录为准，**没有执行的项目一律 `NOT TESTED`**。
* **运行期激活**（`DSH_RUNTIME_ACTIVATION_VERIFIED`）始终是 `NOT TESTED`：文件级升级完成
  不等于在真实 DSH 会话中验证了 Preset 激活、工具可见性与模型请求，那需要你在本机验收。

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

* 当前是 **Pre-release（Release Candidate，非 Verified Release）**；本轮已把 `1.0.0-rc.3` 重新冻结为**统一安装/升级包**（官方发行包名 `CNKI-Research-Portable-1.0.0-rc.3.zip`），但**尚未发布**，发布仍需维护者单独批准。
* `PORTABLE_LIVE_DSH_STATUS = NOT TESTED` —— Portable RC3 没有在 DSH `0.2.1-rc.2` 上
  做独立安装后的真实会话。
* `REAL_MODEL_REQUEST_STATUS = NOT TESTED` —— 没有用 Portable 载荷启动 DSH 宿主做真实
  模型请求验证（生产 Bundle 的真实验收属于**另一个对象**，见第 4 节）。
* `REAL_CNKI_SEARCH_STATUS = NOT TESTED` —— 没有用真实机构账号在 Portable 载荷上完成
  真实检索验收。
* `DSH_RUNTIME_ACTIVATION_VERIFIED = NOT TESTED` —— 包括统一升级在内，所有"文件级完成"
  结论都不等于运行期激活已验证。
* **没有在第二台电脑上验收。** 全部安装证据来自同一台 Windows 11 x64 主机，
  且运行在隔离的 `DSH_HOME` + `USERPROFILE` 沙箱中。
* **Standard/Creator 的工具隔离是结构性推断而非界面实测**：已验证"预设内只有一条 MCP 行、
  且该预设只有一份引用"，但尚未在运行中的 DSH 界面里直接观察其他模式的工具目录。

**功能边界**

* 只做**检索与元数据**，不提供全文下载。
* 首次安装需要联网（下载 `uv`、Python 依赖与 Chromium）；**RC2→统一版的安全升级不需要联网**。
* 机构认证必须由本人手动完成，无法自动化。
* 只支持 Windows x64。
* **升级只支持标准原地安装（Layout A）**；独立运行根（Layout B）不支持增量升级，需人工迁移。
* **升级前必须正常退出 DSH**；DSH 运行时 APPLY 会被拒绝，且工具绝不强杀进程。
* **新 ZIP 必须解压到空目录**；解压覆盖旧安装目录会形成混合状态并被拒绝。
* `portable.ps1 -Action upgrade` 是 **LEGACY**（重装覆盖，不比较版本、不阻止降级）；
  它**不是**安全增量升级路径，安全升级只经 `setup.ps1 -Action upgrade`。
* `portable.ps1 -Action plan` / `-DryRun` 是 **LEGACY 已知限制**：实现上会写一份 Profile 备份目录，
  不是完全只读；只读计划请用 `setup.ps1 -Action plan`。
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
| [START_HERE.md](START_HERE.md) | 入口索引：全新安装 / RC2 安全升级 / 已是 RC3 各看哪份 |
| [DEPLOYMENT_README.md](DEPLOYMENT_README.md) | 用户部署与三步验收指南（含 RC2 升级验收路径） |
| [INSTALL_PROMPT.md](INSTALL_PROMPT.md) | 可直接粘贴给 DSH 的安装提示词（含 RC2 升级的独立命令行流程） |
| [docs/01-架构与路径契约.md](docs/01-架构与路径契约.md) | Preset / MCP / 启动器 / Skill 结构与统一包布局、升级引擎的路径契约 |
| [docs/02-安装卸载与回滚.md](docs/02-安装卸载与回滚.md) | **原有安装器**（`portable.ps1`）的安装、卸载、回滚、诊断与故障排查（命令语义保持） |
| [docs/03-兼容性矩阵.md](docs/03-兼容性矩阵.md) | 已验证 / 未验证矩阵（含安装与升级两类的边界） |
| [docs/04-升级与版本维护.md](docs/04-升级与版本维护.md) | 统一安全升级流程、LEGACY 说明与维护者构建/版本约定 |
| [docs/05-测试报告.md](docs/05-测试报告.md) | 测试范围、结果与判定标准（含统一安装/升级矩阵） |
| [docs/06-设计取舍.md](docs/06-设计取舍.md) | 路径无关、机构无关与上游分发策略的取舍 |
| [docs/provenance/](docs/provenance/) | 基线来源与逐文件哈希记录 |
| [bundle/cnki-research/README.md](bundle/cnki-research/README.md) | 被安装的插件本体说明 |
| [CHANGELOG.md](CHANGELOG.md) | 版本历史与已修复缺陷（含统一安装/升级包条目） |

**自己复核（不需要 DSH，也不需要联网）**

```powershell
node tools\build_manifest.mjs --check      # 载荷清单是否与磁盘一致
node tests\test_static_package.mjs         # 静态校验：哈希、路径、凭据、许可证、结构、提示词变量
node tests\test_unified_package.mjs        # 统一包闭包：SHA256SUMS / manifest / upgrade-data / 载荷集合
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify_release_zip.ps1 -Zip <解压目录里的发行 ZIP>
```

以上命令的 PASS/FAIL 必须**以实际输出为准**；本版本新增了统一入口、升级引擎、测试与文档，
历史 RC3 载荷上的静态结果不能直接沿用。完整自动化套件（含真实 stdio MCP 握手与隔离 Profile
安装）用 `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_all.ps1`；
它会改动本机环境、需要真实的 DSH 与网络，请先读文档再运行。统一升级矩阵（需要冻结 RC2 ZIP
与发行 ZIP）由 `tests\Test-UnifiedMatrix.ps1` 执行，安装/归档/包完整性验证由
`tests\Test-UnifiedVerification.ps1` 执行；两者都会把所有写入限制在隔离沙箱中。

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
