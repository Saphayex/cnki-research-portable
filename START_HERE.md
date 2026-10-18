# START HERE — CNKI Research Portable 1.0.0-rc.3（统一安装/升级包）

给**中国知网（CNKI）文献检索**用的 DSH Desktop 插件发行版。装好之后，在 DSH 里
新建一个 **CNKI Research** 会话，就能直接查知网、取题录、看期刊目录。

> **本包是「统一安装/升级包」（unified installer）。**
> 同一个 ZIP 同时支持两件事：
> 1. **全新安装**（没有装过的新用户）；
> 2. **从 `1.0.0-rc.2` 安全原地升级**（已有标准 RC2 安装的用户；事务化、逐文件校验、可回滚）。
>
> 发行版本是 `1.0.0-rc.3`，本轮已重新冻结为统一发行包，官方发行包名为
> `CNKI-Research-Portable-1.0.0-rc.3.zip`；**尚未发布到 GitHub**（Tag/push/Release 需维护者单独批准）。
> **Portable 自身的实机会话/真实模型请求/真实机构检索仍为 `NOT TESTED`**，请不要把它当作已验证的生产发行版。

* 不需要命令行基础：全新安装可以跟着 [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md) 交给 DSH 执行。
* 不影响其他模式：Standard / Creator 会话里**看不到**任何知网工具。
* 不绑定机构：用你自己学校的 CNKI 认证，发行包里没有任何机构预设、账号或 Cookie。
* 已有 RC2 安装升级时：**脚本要在一个独立的 PowerShell 窗口里跑**（APPLY 前必须正常退出 DSH）。

---

## 我该先看哪个文件？

| 你的情况 | 看这个 |
|---|---|
| 我是新用户，想装 | [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md) —— 可整段粘贴给 DSH 的安装提示词 |
| 我想先确认这台电脑能不能装（不改动任何东西） | 本文下方「全新安装最短路径」第 1 步 |
| **我已经装过 RC2，想做安全升级** | 本文下方「从 RC2 安全升级」；细节见 [`docs/04-升级与版本维护.md`](docs/04-升级与版本维护.md) |
| 我已经是 RC3（统一版或冻结版），还要做什么？ | **不需要操作**：`setup.ps1 -Action check` 会报 `RC3_ALREADY_INSTALLED` 并 exit 0 |
| 我想知道它到底做了什么、为什么这样设计 | [`docs/01-架构与路径契约.md`](docs/01-架构与路径契约.md) |
| 安装/卸载/回滚/诊断（原有安装器语义） | [`docs/02-安装卸载与回滚.md`](docs/02-安装卸载与回滚.md) |
| 我想知道支持哪些系统 / DSH 版本 | [`docs/03-兼容性矩阵.md`](docs/03-兼容性矩阵.md) |
| 我想看测试范围与验证结果（哪些真的测过） | [`docs/05-测试报告.md`](docs/05-测试报告.md) |
| 我要自己维护、重新构建这个发行版 | [`docs/04-升级与版本维护.md`](docs/04-升级与版本维护.md) |
| 许可证与第三方来源 | [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) |

---

## 全新安装最短路径（解压到**空目录**）

> **先把 ZIP 解压到一个空目录或全新目录。**
> **绝对不要**把新的 ZIP 解压覆盖到旧安装目录上；那样会产生混合状态，
> 统一入口 `tools\setup.ps1 -Action check` 会**拒绝**（exit 2），不会尝试修复。

```powershell
# 1) 只读检查：识别“未安装”，并检查 DSH / Python / uv / 浏览器条件（不写任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check

# 2) 只读计划：显示将要执行的全新安装步骤（不写任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan

# 3) 正式安装（安装器会先备份你的 DSH Profile）
#    装到日常使用的 desktop Profile 时必须由你显式加上 -AllowProductionProfile，
#    否则安装器会以 "REFUSED:" 拒绝执行（这是保护会话与凭据的门禁）。
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action install -Yes -AllowProductionProfile

#    只想先试装、不碰日常 Profile 时改用独立 Profile（无需该开关）：
# powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action install -Yes -DshProfile cnki-trial

#    离线/受限网络：先在可联网机器预热 uv 缓存，再带 -Offline（不会下载依赖）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action install -Yes -Offline

# 4) 刷新 DSH 页面 → 新建会话 → Agent 预设选 "CNKI Research" → 让它登录知网
```

`-Action check` 与 `-Action plan` 是**只读**的；它们不会装依赖、不会改 Profile、不会写安装根。
把输出留好：它会告诉你缺什么、哪些项目**没测过**（`NOT TESTED`）。

`setup.ps1` 直接接受与统一流程相关的选项：`-DshProfile`、`-DshHome`、`-InstallRoot`、`-PlanId`、
`-RollbackTarget`、`-Offline`、`-NoToolInstall`、`-Force`、`-PurgeRuntime`、`-AllowProductionProfile`、`-Json`。

原安装器 `tools\portable.ps1`（**LEGACY，语义不同**）另有下面这些选项（均属原安装器 LEGACY 选项，
**不能**传给统一入口）：
`-DshCli`、`-Python`、`-Uv`、`-ProfileTemplate`、`-LinkMode`、`-Upstream`、`-CnkiProfile`（原安装器专用）。
确实需要时请直接调用原安装器，例如：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action install -Yes -DshCli "C:\Program Files\DSH\resources\runtime\cli\bin\dsh.cmd"
```

---

## 从 RC2 安全升级（已有标准 RC2 安装）

适用于：已有 **`1.0.0-rc.2` 原地安装（Layout A：解压目录即安装根）** 的用户。
统一升级是**事务化、逐文件校验、可回滚**的；**不重装 venv、不重跑插件管理器、不重建 junction、
不需要联网**，并保留你的 DSH 会话、凭据、CNKI 登录态与 Profile。

```powershell
# 1) 把统一发行 ZIP 解压到一个全新的空目录（不要覆盖 RC2 安装目录！）

# 2) 只读检查：识别 RC2 安装状态（RC2_CLEAN / RC2_HOTFIXED），列出将修改/新增的文件
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check -InstallRoot "<RC2 安装根目录>"

# 3) 只读 PLAN：生成 planId、变更清单、备份位置与环境文件更新计划
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan -InstallRoot "<RC2 安装根目录>"
#    记住输出里的 planId；这一步不会写任何文件。

# 4) 正常退出 DSH（不要强杀进程、不要改 Profile 触发 HMR），
#    然后在【独立的 PowerShell 窗口】里执行 APPLY：
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action upgrade -InstallRoot "<RC2 安装根目录>" -PlanId "<planId>" -Yes

# 5) 正常重新打开 DSH → 新建 CNKI Research 会话，按验收清单确认（8 个工具可用）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action verify -InstallRoot "<RC2 安装根目录>"

# 6) 需要退回 RC2 时（升级事务的逐字节回滚，含删除本次新增文件）：
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action rollback -InstallRoot "<RC2 安装根目录>" -Yes
```

升级的关键约束：

* **只支持标准原地安装（Layout A）**：安装根里必须有 `VERSION`、`manifest.json`、
  `bundle\cnki-research\`、`upstream\cnki-mcp\`、`_portable\install-state.json` 等标记。
* 安装根是用 `-InstallRoot` 指向别处的“独立运行根”（Layout B）不被增量升级支持；
  检查会明确拒绝并给出人工迁移指引（见 `docs/04`）。
* 安装内容被修改/混合/损坏（`UNKNOWN_OR_MODIFIED`）时：**拒绝写入**并列出冲突文件；
  不会自动修复，也不会覆盖你的修改。请先恢复为干净的 RC2 安装，或改用全新安装。
* APPLY 需要 `-PlanId`（由第 3 步生成）与 `-Yes`；状态变化后旧 planId 失效，必须重新 PLAN。
* **DSH 正在运行时不能 APPLY**（真实 Profile + 运行中的 DSH 会被拒绝，`DSH_IN_USE`）。
* 文件级升级完成 = `FILE_UPGRADE_COMPLETE`；**运行期激活验收
  （`DSH_RUNTIME_ACTIVATION_VERIFIED`）仍为 `NOT TESTED`**，需要你在真实 DSH 会话里确认。

> **DSH 模式原则：** 安全升级只做**文件级**写入，不调用 `dsh plugin` 插件管理器，
> 因此只需要一个**普通 PowerShell 窗口**（在 DSH Standard 会话里执行 PowerShell 命令也可以）；
> 只有全新安装、卸载、安装器回滚这类真正需要 Plugin Manager 的操作，才需要 Creator/插件管理场景。

---

## 原有 `portable.ps1` 命令是否还能用？

**能。** `tools/portable.ps1` 与 `tools/lib/PortableCommon.ps1` 相对已冻结的 RC3 **逐字节未变**，
所有旧命令保持原语义，已有文档/脚本/提示词里的 `tools\portable.ps1 -Action ...` 继续有效。

但请区分两个 **upgrade**：

| 命令 | 语义 | 是否安全增量 |
|---|---|---|
| `tools\setup.ps1 -Action upgrade` | 事务化原地升级（本版统一入口；校验 + 备份 + 逐文件替换 + 可回滚） | **是，唯一安全路径** |
| `tools\portable.ps1 -Action upgrade` | **LEGACY**：等同于“用当前包重新安装/覆盖”旧版，会重跑 venv/Profile/plugin 逻辑 | **不是**；不比较版本、不阻止降级，不用于 RC2→RC3 升级 |

另外两个 **LEGACY 已知限制**（不要当作只读命令使用）：

* `tools\portable.ps1 -Action plan` 与 `-Action install -DryRun` 在实现上会写一个 Profile 备份目录
  （`<安装根>\_portable\backups\<时间戳>\`），**不是完全只读**；
  统一入口的只读计划是 `tools\setup.ps1 -Action plan`。
* `tools\portable.ps1 -Action rollback -DryRun` / `-Action uninstall -DryRun` 也**可能写入备份**；
  统一入口不会把 `-DryRun` 转发给这两个动作。

---

## 装完之后是什么样

* DSH 的 Agent 预设列表里多出 **CNKI Research**（`order: 5`，排在 Standard 之后）。
* 只有 CNKI Research 会话能看到 8 个 `mcp__cnki__*` 工具：
  `easy-search`、`advanced-search`、`get-info-from-url`、`get-info-by-detail`、
  `list-journal`、`search-issn`、`login`、`logout`。
* 另有一个 MCP 资源 `profile://list`，用于列出本机可用的 CNKI Profile。
* 检索技能 `cnki-literature-search` 只在 CNKI Research 模式下可用。
* 所有知网浏览器操作在**一个**子进程里串行执行（并发上限 1），多个 CNKI Research
  会话共享它。

---

## 这个包里有什么

```
CNKI-Research-Portable-1.0.0-rc.3/
├── START_HERE.md              <- 你在这里
├── DEPLOYMENT_README.md       <- 用户部署与三步验收指南
├── INSTALL_PROMPT.md          <- 粘贴给 DSH 的安装提示词
├── README.md                  <- 项目总览与设计取舍
├── manifest.json              <- 版本、依赖、兼容性、逐文件 SHA-256（只描述已安装载荷）
├── SHA256SUMS.txt             <- 包内完整性清单（覆盖除自身外的全部包内文件）
├── VERSION
├── LICENSE                    <- GNU GPL v3
├── THIRD-PARTY-NOTICES.md
├── CHANGELOG.md
├── bundle/cnki-research/      <- 被安装的 DSH 插件（路径无关）
├── upstream/cnki-mcp/         <- 固定版本的上游源码（GPL-3.0）
├── upgrade-data/              <- 升级元数据（只有哈希与规则；不安装、不含目标文件副本）
├── tools/                     <- setup.ps1（统一入口）/ portable.ps1（原安装器）/ 构建校验工具
├── tests/                     <- 自动测试
└── docs/                      <- 说明、兼容性矩阵、测试报告、来源记录
```

**包内元数据 vs 安装根**：`manifest.json`、`SHA256SUMS.txt`、`upgrade-data/**` 是**包内发布元数据**。
安装/升级操作本身**只把发行载荷**写进安装根；它**不会**把 `SHA256SUMS.txt` 或 `upgrade-data/**`
复制进安装根。所以：

* 升级场景（`-InstallRoot` 指向旧 RC2 安装根）：完成后该安装根里有 115 个发行载荷文件
  （以 `manifest.json` 的 `files` 列表为准）+ `manifest.json`，外加安装器自己维护的
  运行期目录（`.venv/`、`_portable/`、`bundle/cnki-research/portable.runtime.json`）；
* 全新安装的默认“解压即安装”场景：安装根就是你解压出来的包目录，因此
  `manifest.json`、`SHA256SUMS.txt`、`upgrade-data/` 本来就在那里（它们是包的一部分，
  不是安装器复制过去的）。

---

## 几条你必须知道的限制

1. **不提供全文下载。** 只做检索与元数据。
2. **机构认证要你本人操作。** 第一次用会弹出 Chromium 窗口，你需要在里面完成学校
   SSO 或验证码；这一步无法自动化，也无法由发行包代做。
3. **只验证过 Windows 11 x64。** 其他系统一律标注为未验证，不声称可用。
   详见 [`docs/03-兼容性矩阵.md`](docs/03-兼容性矩阵.md)。
4. **DSH 版本要分开看。** Portable 发行版的实机运行记录是 `0.2.0-rc.2`；RC3 针对
   `0.2.1-rc.2` 的兼容性修复已通过静态与隔离协议验证，但 Portable 在 `0.2.1-rc.2` 上的
   独立实机验收仍为 `NOT TESTED`；统一升级路径同样如此。
5. **升级前必须正常退出 DSH。** 安装器/升级器不会替你关闭或重启 DSH，也绝不强杀进程。
6. **不要把新 ZIP 解压覆盖到旧安装目录。** 这是混合状态，统一入口会拒绝；新包必须解压到空目录。
