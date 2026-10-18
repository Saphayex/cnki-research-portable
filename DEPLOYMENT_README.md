# CNKI Research Portable 1.0 — 部署与首次验收 README

> **面向对象：** 第一次在另一台 Windows 电脑上安装 CNKI Research Portable 的用户，以及已有
> `1.0.0-rc.2` 标准安装、需要安全原地升级的用户。  
> **发行状态：** Pre-release（Release Candidate，非 Verified Release）；本轮是**统一安装/升级包**
> （unified installer），已重新冻结为 `1.0.0-rc.3` 统一发行包，但**尚未发布**（Tag/push/Release 待维护者单独批准）。  
> **使用方式：** 用户负责准备文件、向 DSH 发送提示词、审阅授权及完成机构登录；环境检查、安装与诊断由 DSH 执行；
> **RC2 安全升级由用户在 DSH 正常退出后、于独立 PowerShell 窗口执行**。  
> **适用包：** `CNKI-Research-Portable-1.0.0-rc.3.zip`（官方发行名）

[简体中文](DEPLOYMENT_README.md) | [English summary](README_EN.md) | [回到项目首页](README.md)

本指南的主线是**全新安装**的三步：

1. **在 DSH 创造模式中安装 Portable**
2. **确认 CNKI Research 已正常集成**
3. **完成知网认证并测试真实检索**

已有 RC2 安装的用户请先完成第 1–3 步中的环境确认，再按本文末尾的
**「升级已有 RC2 安装」**执行；升级的 PLAN/APPLY 不需要 DSH 参与。

**全新安装无需手动执行 PowerShell 命令，也无需自行配置 Python、MCP、YAML 或插件。**

> **RC3 兼容性说明：** 本包修复了 DSH Desktop `0.2.1-rc.2` 移除 `{{cwd}}` 提示词变量导致的
> CNKI Research 会话启动失败（删除 Preset persona 中已失效的 suffix，保留 `{{model}}` prefix）。
> 该修复已通过静态与隔离协议验证；**本 Portable 包在 `0.2.1-rc.2` 上的实机安装与会话运行
> 尚未由本发行版独立验收（`LIVE NOT TESTED`）**，请按下方三步完成实测并如实记录。

---

## 开始之前：准备测试电脑

请确认：

- 测试电脑使用 **Windows 10/11 x64**，已安装并可正常使用 DSH Desktop。
- 本 Portable 发行版的实机测试记录来自 DSH `0.2.0-rc.2`；RC3 针对 `0.2.1-rc.2` 的兼容性
  修复已通过静态与隔离协议验证，但**尚未在 `0.2.1-rc.2` 上完成独立的实机会话验收**。
  使用其他版本时需以实际验收结果为准。
- 电脑可以联网，并且你有合法的知网机构或个人访问权限。
- 最好使用**没有安装过 CNKI Research 的电脑**。如果电脑已有重要 DSH 会话和项目，请先自行备份。
- 从原电脑复制**同一次构建**的两个文件：
  - `CNKI-Research-Portable-1.0.0-rc.3.zip`
  - `CNKI-Research-Portable-1.0.0-rc.3.zip.sha256`

将 ZIP 解压到一个**长期保留、不准备删除的文件夹**，例如：

`D:\Tools\CNKI-Research-Portable`

> 不建议解压到稍后会清空的临时目录。Portable 的 Python 环境可能引用安装时的绝对路径。ZIP 完整性校验由后面的 DSH Creator 执行，你不必手动输入校验命令。如果校验失败，立即停止安装。
>
> **必须解压到空目录/新目录。** **绝对不要**把本 ZIP 解压覆盖到已有的旧安装目录上：
> 那会形成混合状态，统一入口的 `tools\setup.ps1 -Action check` 会拒绝（exit 2），
> 并且本发行版不会尝试自动修复这种目录。

如果你要**升级已有的 RC2 安装**，本 ZIP 只是“升级源”，不要解压进旧安装根；
旧安装根保持原样，升级动作见本文最后一节。

---

# 步骤 1：在 DSH 创造模式中安装 Portable

### 1.1 打开 DSH 并发送安装提示词

1. 打开测试电脑上的 **DSH Desktop**。
2. 新建任务，选择 **创造模式（Creator）**。
3. 将任务**工作目录**设为刚才解压的 Portable 文件夹。
4. 将下面整段提示词发送给 Creator。

**复制给 Creator：**

```text
请对当前工作目录内的 CNKI Research Portable 1.0 Release Candidate
执行首次部署验收。

请先阅读发行包中的 INSTALL_PROMPT.md、START_HERE.md、manifest.json
及安装说明。请核对 ZIP 配套哈希文件与发行信息是否一致。

你负责执行环境检查和安装计划，不需要我手动输入 PowerShell 命令。
请先完成：

1. 核查当前 Windows、DSH、Python 和依赖条件。
2. 检查是否已有同名 CNKI Research 插件，避免覆盖已有安装。
3. 执行发行包提供的 CHECK 和 PLAN。
4. 告诉我将安装到哪里、会修改哪些配置、需要什么授权、
   是否有备份/回滚，以及是否需要刷新或重启 DSH。
5. 检查发行包自身和附带哈希是否一致。

这是已有发行包的安装验收，不是重新开发任务。
不要修改发行包源码，不要清理任何 DSH 会话、存储、
用户凭据、知网登录状态或其他插件。

此时只做检查和计划，不要开始正式安装。
请展示结果，等待我审核与明确批准。
```

### 1.2 阅读 Creator 返回的安装计划

Creator 给出结果后，你只需要检查下面几项：

- [ ] 发行文件完整性校验通过，没有哈希不一致。
- [ ] 安装目标确实是**这台测试电脑的预期 DSH Profile**。
- [ ] 安装位置是稳定目录，而不是准备删除的临时目录。
- [ ] 没有覆盖其他来源的 CNKI Research 或其他插件。
- [ ] 计划没有要求删除会话、工作区、账号数据或知网 Cookie。
- [ ] Creator 已说明将修改哪些配置、保存哪些备份。
- [ ] 没有未经你允许的 DSH 关闭、重启或危险清理操作。

**如有任一项不明确，不要批准安装。** 先让 Creator 解释或修正安装计划。

### 1.3 批准安装

在计划完全符合预期后，回复：

```text
我批准按照刚才展示、并且通过审核的安装计划，
在指定目标 DSH Profile 中安装 CNKI Research Portable 1.0。

如果安装器要求 -AllowProductionProfile，仅授权用于本次
已经明确列出的插件注册和配置变更。

请自动完成正式安装与安装后的状态检查、故障诊断，
并保留安装日志与备份位置。

本次授权不包括删除任何会话、存储、工作区、凭据和知网登录态，
也不包括强制关闭或重启 DSH。
若实际操作计划发生变化，请停止并重新向我申请批准。
```

之后由 Creator 自动安装，无需你复制或执行任何命令。

### 1.4 查看安装结果

Creator 报告安装完成后，确认以下内容：

- [ ] 安装过程正常完成，没有阻塞错误。
- [ ] `CNKI Research` Preset 已注册。
- [ ] MCP 和运行时依赖检查正常。
- [ ] Creator 已说明是否需要刷新 DSH。
- [ ] 安装日志、备份信息已保留。

如果 Creator 报告错误，**先保存错误内容**，不要重复盲目安装、清理配置或重置用户目录。

---

# 步骤 2：确认 CNKI Research 已正常集成

### 2.1 新建 CNKI Research 会话

1. 根据安装报告提示，必要时刷新 DSH 页面（通常可按 **F5**）。
2. 返回**新建任务**界面。
3. 检查模式选择器中是否出现 **CNKI Research**。
4. 选择该模式并创建**新会话**，不要留在刚才的 Creator 会话中。

**如果找不到 CNKI Research**，返回 Creator 会话，把实际情况告诉它，让其先检查注册状态和目标 Profile；不要直接重复安装。

### 2.2 在 CNKI Research 会话发送检查提示词

```text
现在进行 CNKI Research Portable 的真实 DSH 集成验收。

请检查当前会话实际可用的 mcp__cnki__* 工具，
确认是否包含以下八个工具：

easy-search
advanced-search
get-info-from-url
get-info-by-detail
list-journal
search-issn
login
logout

请确认工具是当前会话实际注册的，而不只是文档中写到的名称；
尤其检查 get-info-by-detail 的必需参数 title 是否存在。

然后正常完成一次模型回复，汇报当前模式和工具状态。

此时不要登录知网，不要执行文献检索，也不要修改系统配置。
```

随后你需要观察：

- [ ] 模式确实是 **CNKI Research**。
- [ ] 工具目录或日志中实际出现 **8 个 CNKI MCP 工具**，不只是模型复述。
- [ ] 模型能够正常回答，没有工具 Schema 或 `INVALID_REQUEST` 错误。
- [ ] 工具定义中没有缺少 `get-info-by-detail.title` 等必需参数。

### 2.3 检查工具隔离

分别新建 **Standard（标准模式）**和 **Creator（创造模式）**会话，查看它们实际加载的工具目录。

期望结果：

| 模式 | 是否应有 CNKI MCP 工具 |
|---|---|
| CNKI Research | **应有：8 个** |
| Standard | **不应有** |
| Creator | **不应有** |

不要求尝试越权调用工具，只需查看实际可用工具或 DSH 日志。若界面无法查看工具注册证据，请标记为**待核实**，不要只凭模型回答宣布通过。

**步骤 2 通过标准：** 能选择 CNKI Research、工具 8/8 注册、真实模型请求正常、其他模式未被加入 CNKI 工具。

---

# 步骤 3：完成知网认证并测试真实检索

### 3.1 在 CNKI Research 会话启动登录

回到**步骤 2 创建的 CNKI Research 会话**，发送：

```text
现在进行 CNKI Research Portable 的真实机构登录验收。

请实际调用 mcp__cnki__login，
使用当前测试电脑的 CNKI Profile 打开可见的 Chromium 登录窗口。

由我本人完成合法的机构或个人认证。
不要读取、导出或记录账号密码、Cookie 等认证秘密。

请根据工具实际返回结果报告登录状态。
如果失败或超时，请报告原始错误并停止，
不要清理或重建 Profile，也不要修改 DSH 配置。
```

接着由你亲自在弹出的 Chromium 窗口中完成知网登录或学校统一身份认证（SSO）。

- 可以使用当前测试电脑持有人的合法 CNKI 访问权限。
- 不必与原电脑使用同一所学校。
- 原电脑的 CNKI 登录 Cookie、登录状态不会随 Portable 一起分发。
- 登录工具可能存在约 **120 秒**的等待窗口；实际以工具返回结果为准。

确认登录工具返回真实成功状态，再继续。

### 3.2 在同一会话执行真实文献检索

发送第二段提示词：

```text
现在执行 CNKI Research Portable 的首次真实文献检索验收。

请实际调用 mcp__cnki__easy-search：

keywords = "生态文明"
limit = 3

请根据 MCP 工具的真实返回结果列出：
- 论文标题
- 作者
- 期刊或来源
- 发表日期
- CNKI 链接（如有）

不得自行编造文献，不得补写工具没有返回的字段。
请汇报实际调用是否成功、实际返回多少条记录，
并保留原始工具响应与错误信息以供验收。
```

### 3.3 人工检查检索结果

你只需核对：

- [ ] DSH 记录中确实调用了 `mcp__cnki__login`。
- [ ] 浏览器成功打开，你完成了真实登录。
- [ ] DSH 记录中确实调用了 `mcp__cnki__easy-search`。
- [ ] 返回真实的知网题录，而不是模型直接编出的论文。
- [ ] 标题、作者、来源、日期与工具返回相符。
- [ ] 若返回 CNKI 链接，可以打开相应记录。
- [ ] 没有严重的认证、浏览器或 MCP 运行错误。

`limit=3` 不代表一定返回三条。若返回不足三条，依据工具实际结果判断；**不能为了凑数而补造文献**。

如果成功获取并核实真实题录，步骤 3 即可通过。

---

## 升级已有 RC2 安装（安全原地升级，独立 PowerShell）

**适用**：本机已经用 `1.0.0-rc.2` **原地安装**（解压目录即安装根，Layout A），
并且你想保留现有 DSH 会话、Profile junction、venv、Chromium 与 CNKI 登录态。

**准备**：把本发行 ZIP 解压到一个**新的空目录**（作为“升级源”的 PackageRoot）；
**不要**解压覆盖旧安装目录，也不要把升级源解压进旧安装根。

**DSH 模式原则**：安全升级只做**文件级**写入、不调用插件管理器，因此只需要一个普通
PowerShell 窗口（在 DSH Standard 会话里执行命令也可以）。**只有全新安装、卸载、安装器回滚
才需要 Creator/Plugin Manager 场景**；升级的 APPLY 必须在 DSH **正常退出后**执行，
所以不要把 APPLY 交给正在运行的 Creator 会话。

### 升级步骤

```powershell
# 0) 确认：旧 RC2 安装根保持原样；统一发行 ZIP 解压在一个全新的空目录

# 1) 只读检查（DSH 运行中也可执行；不会写任何文件）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check -InstallRoot "<RC2 安装根目录>"
#    期望：RC2_CLEAN 或 RC2_HOTFIXED；若是 UNKNOWN_OR_MODIFIED 会列出冲突，停止并先恢复干净安装

# 2) 只读 PLAN（DSH 运行中也可执行）：记录输出的 planId
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan -InstallRoot "<RC2 安装根目录>"
#    期望：PLAN_READY；显示将替换的文件、将新增的文件、备份位置与环境文件更新

# 3) 正常退出 DSH（等它完全关闭；不要强杀进程，不要手工改 Profile）

# 4) 在独立 PowerShell 窗口执行 APPLY（必须带 -PlanId 与 -Yes）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action upgrade -InstallRoot "<RC2 安装根目录>" -PlanId "<planId>" -Yes
#    期望 exit 0；输出事务 id 与 COMMITTED 阶段

# 5) 正常重新打开 DSH → 新建 CNKI Research 会话，按步骤 2 的方式确认 8 个工具；
#    文件级完成状态：
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action verify -InstallRoot "<RC2 安装根目录>"
#    期望 FILE_UPGRADE_COMPLETE = PASS；DSH_RUNTIME_ACTIVATION_VERIFIED 恒为 NOT TESTED

# 6) 如需退回 RC2（逐字节回滚，含删除本次新增的文件）：
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action rollback -InstallRoot "<RC2 安装根目录>" -Yes
```

### 升级验收要点

- [ ] 第 1 步状态是 `RC2_CLEAN` 或 `RC2_HOTFIXED`（不是未知/被修改）。
- [ ] 第 2 步 exit 0，且你能读懂变更清单与备份位置；planId 已记录。
- [ ] APPLY 前 DSH 已**正常退出**；APPLY exit 0（`2` 表示被拒绝，需按提示处理）。
- [ ] `verify` 输出 `FILE_UPGRADE_COMPLETE = PASS`。
- [ ] 重新打开 DSH 后 CNKI Research 预设存在，8 个工具可用。
- [ ] 你的 DSH 会话、工作区、其他插件、CNKI 登录态未被清空。
- [ ] 升级前备份/升级事务目录仍在（保留以备回滚，不要手工删除）。
- [ ] 运行期激活（真实会话、模型请求、工具可见性）由你人工确认；
      `DSH_RUNTIME_ACTIVATION_VERIFIED` 保持 `NOT TESTED`，本 README 不预写 PASS。

### 升级边界

* 只支持 **Layout A**；`-InstallRoot` 指向别处的独立运行根（Layout B）会被拒绝，需人工迁移。
* 内容未知/被修改/混合时**拒绝写入**并列出冲突文件；不会自动修复。
* 状态变化会让旧 planId 失效，必须重新 PLAN。
* DSH 运行中 APPLY 会被拒绝（`DSH_IN_USE`）；工具绝不强杀 DSH。
* 升级**不需要联网**、不重装 venv、不重跑插件管理器、不重建 junction。
* **不要**用 `tools\portable.ps1 -Action upgrade` 做升级：它是 LEGACY 重装覆盖，不是安全增量路径。

---

## 遇到问题时，用户应怎么做？

| 遇到的情况 | 你应该做的事 |
|---|---|
| Creator 检查发现哈希不一致 | **停止**，重新确认 ZIP 和 `.sha256` 是否来自同一次构建 |
| Creator 要求修改你不认识的目录 | 暂不批准，让其说明具体影响 |
| 安装报错 | 保存报错，要求 Creator 只做诊断，不要反复重装 |
| 看不到 CNKI Research | 返回 Creator，让其检查安装/加载状态 |
| CNKI Research 里少工具 | 保存工具目录或错误信息，不要直接修改插件源码 |
| 浏览器没打开 | 让当前会话报告真实错误，不要删浏览器 Profile |
| 学校认证失败 | 核对学校登录流程和网络，不要让模型假设成功 |
| 检索没有结果或报错 | 保留真实工具输出，不要让模型编造论文 |
| 升级提示 `LAYOUT_SEPARATE_PACKAGE_ROOT` | 该安装根是独立运行根（Layout B），增量升级不支持；按 `docs/04` 的人工迁移步骤处理，不要反复重试 |
| 升级提示 `UNKNOWN_OR_MODIFIED` / 冲突清单 | 安装内容被修改或混合，升级器拒绝写入；先恢复干净的 RC2 安装，或改用全新安装。不要手工编辑安装根/Profile 试图“修好” |
| 升级提示 `DSH_IN_USE` | DSH 还在运行：正常退出后，在独立 PowerShell 中重新 check/plan/upgrade |
| 升级提示 planId 相关错误（`PLAN_STALE` / `PLAN_ID_REQUIRED`） | 重新执行 `plan` 获取新的 planId，再用新 id 执行 APPLY |
| 升级后 DSH 打不开或工具异常 | `setup.ps1 -Action verify` / `status` 先诊断；不要删备份或事务目录；需要时执行 `rollback` 回到 RC2 |
| DSH 会话、工作区、登录态异常 | **立即停止验收**，不要继续安装、清理或重试 |

---

## 完成后三步验收如何记录？

建议让 Creator 或测试负责人整理一份 `CNKI_PORTABLE_TARGET_ACCEPTANCE.md`。你只需要提供已经看到的结果以及必要日志。

| 核验项目 | 记录结果 |
|---|---|
| 步骤 1：Creator 安装与诊断 | PASS / FAIL / NOT TESTED / BLOCKED |
| 步骤 2：Preset、8 工具、真实模型请求、工具隔离 | PASS / FAIL / NOT TESTED / BLOCKED |
| 步骤 3：机构登录与真实知网检索 | PASS / FAIL / NOT TESTED / BLOCKED |
| （如有升级）RC2 状态检测与 PLAN | `RC2_CLEAN` / `RC2_HOTFIXED` / UNKNOWN；planId；PASS / FAIL |
| （如有升级）APPLY 事务与 VERIFY | 事务 id；`FILE_UPGRADE_COMPLETE`；PASS / FAIL / NOT TESTED |
| （如有升级）升级后运行期验收 | PASS / FAIL / NOT TESTED（本包不预写 PASS） |
| 目标电脑系统与 DSH 版本 | 按实际填写 |
| 发行包 SHA-256 | 按实际文件填写 |
| 安装和运行日志 | 记录保存位置 |
| 实际检索题录 | 至少保留可以核对的返回记录 |
| 有无非预期用户数据变更 | 如实填写 |

**三个步骤全部通过**，意味着在这台测试电脑上，Portable 已经完成**首次安装 → DSH 集成 → 真实知网检索**的核心链路验收；
如果还执行了 RC2 升级，则另需记录升级链路（CHECK → PLAN → APPLY → VERIFY → 重新打开 DSH）的实际结果。

但要将发行等级从 RC 提升为完整的 **Verified Release**，还需要单独进行目标电脑的**卸载、回滚以及会话/登录数据保留验收**。本 README 不指导用户直接开展那些可能修改安装状态的操作。

---

## 安全提醒

- 不要清理 `.dsh` 的会话、存储、凭据或 Profile。
- 不要删除 `.cnki-mcp` 登录数据。
- 不要为解决问题而随意使用 `-Force`、`-PurgeRuntime`。
- **不要**把新 ZIP 解压覆盖到旧安装目录；新包必须解压到空目录。
- 升级必须**正常退出 DSH** 后执行，不要强杀进程；工具不会替你关闭/重启 DSH。
- 升级的备份/事务目录（`_portable\upgrades\`、`_portable\backups\`）是回滚依据，**不要手工删除**。
- 不要允许 DSH 擅自重启、关闭或重置生产环境。
- **用户负责授权，DSH 负责执行技术步骤。**

> 发行包自带的 `INSTALL_PROMPT.md` 是安装/升级操作的正式依据。本 README 只说明**用户如何操作和判断结果**，不替代安装器自身的参数、权限和安全检查。
