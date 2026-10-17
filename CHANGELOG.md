# Changelog

## 1.0.0 — CNKI Research Portable（首个通用发行版）

从冻结的 `@local/dsh-cnki-research@1.0.0` 生产插件派生的、可跨电脑重复部署的发行版。

### 1.0.0-rc1 修订（本次会话新增，相对首版草案）

这一节记录在把草案推进到可发行 Release Candidate 过程中发现并修复的真实缺陷。

#### 安全

* **新增生产数据硬门禁** `Assert-MutationAllowed` / `Test-ProductionTarget`：
  任何会改动**真实用户 DSH 数据目录**（`%USERPROFILE%\.dsh`，含 sessions /
  storages / 凭据）的操作，未显式传入 `-AllowProductionProfile` 时**直接拒绝执行**。
  涉及 `install`、`uninstall`、`rollback`（以及 `uninstall -PurgeRuntime`）。
* **`-CnkiProfile` 单独设门禁**：它会改写真实的
  `%USERPROFILE%\.cnki-mcp\profiles\config.json`（机构登录状态），而该目录
  **不在 `$DSH_HOME` 覆盖范围内**，因此同样需要 `-AllowProductionProfile`。
* **`-Json` 不再等于默认同意**：此前 `-Json` 会让 `Confirm-Action` 一律返回 true，
  使一次纯诊断调用也可能改动机器。现在只有 `-Yes` 或 dry-run 才会自动确认。
* **`-PurgeRuntime` 不再跟随嵌套链接**：删除 `.venv` 前用
  `Test-TreeContainsReparsePoint` 检查，发现链接即拒绝删除（Windows PowerShell 5.1
  的 `Remove-Item -Recurse` 会跟随嵌套 junction）。
* **卸载只删自己装的东西**：目标的 junction 指向的不是本次安装的 bundle 时拒绝，
  除非显式 `-Force`。

#### 修复

* `tests\run_all.ps1` 调用了只定义在 `portable.ps1` 里的 `Get-VenvPython`，
  导致整个测试套件**在启动时即崩溃、从未产出证据**。三个 venv 辅助函数已移入
  `tools\lib\PortableCommon.ps1`。
* **`uv sync` 的假失败**：Windows PowerShell 5.1 在
  `$ErrorActionPreference='Stop'` 下会把原生命令写到 **stderr** 的正常输出
  （uv 的 "Checked N packages" / 解释器选择行）升级为**终止性错误**，
  于是安装永远失败。`Invoke-Native` 现在仅在调用期间放宽该首选项，
  并以**退出码**作为唯一判据。
* **`$home` 变量名冲突**：PowerShell 的 `$HOME` 是只读自动变量且大小写不敏感，
  赋值会抛错，使 `-Action plan` 直接返回 error。已改名 `$homePath`。
* **`.venv` 残留导致永久卡死**：被打断的安装会留下没有 `python.exe` 的 `.venv`
  （uv 先写 `.gitignore` / `CACHEDIR.TAG`），此后 `uv sync` 永远拒绝。
  新增 `Reset-BrokenVenv`：只清理这种形态的目录，遇到 `.lock`（另一个 uv 正在用）则拒绝。
* **Schema 清洗器会删掉参数本身**：`_collapse_nullable` 递归时无条件丢弃所有
  `title` 键，于是 `get-info-by-detail` 里**名为 `title` 的必需参数**被删除，
  造成 `required` 指向未声明属性。现在只在“键是 schema 关键字”的层级丢弃注解，
  在 `properties` 层级保留参数名。
* **`portable.runtime.json` 泄漏真实机构名**：它记录安装机的解释器路径与
  CNKI Profile 名（本机为真实机构名），且曾被当作发行文件打包。现已从
  `manifest.json` 与打包流程中排除。
* **`docs/test-evidence/` 污染清单**：跑一次文档里写的测试命令就会让
  `manifest.json` 变脏、进而阻断打包。已加入 `EXCLUDED_DIRS`。
* **孤进程误判**：`orphan_processes()` 用子串匹配命令行，把**探针自己**和
  它调用的 PowerShell 都算成“残留的 launcher”，于是永远报 3 个孤儿。
  现在按 pid 与命令行特征排除探针自身。
* **`listeningPorts` 是硬编码的空数组**：探针声称“stdio 不需要 HTTP 端口”，
  实际从未检查。现在对存活的 launcher 真的查询监听端口，查到即判为问题。
* **测试假通过**：`test_tool_schema.mjs` 的 `C4.verbatim` 拿同一个数组和自己比较，
  永远不可能失败。现在改为与**独立捕获**的 `tools/list`（stdio 探针的原始返回）
  逐字节比对，没有独立捕获时如实报 `NOT TESTED`。
* **`D6.productionUntouched` 无法证明任何事**：它没有改前快照，且在“生产环境本来
  就声明了该插件”时报 PASS。现在比对测试前后生产 Profile 的
  `package.json` / `pnpm-lock.yaml` SHA-256。
* **隔离测试会写真实 CNKI 目录**：`%USERPROFILE%` 未被重定向，而 profile 初始化
  就会组合插件集，于是真实的 `%USERPROFILE%\.cnki-mcp\Cookies` 被写。
  现在测试在**创建 profile 之前**就把 `USERPROFILE` 重定向进沙箱，并断言真实目录未被触碰。
* **`Get-ProfileManifestInfo` 的 `Dependencies` 在 StrictMode 下可能缺失**，
  导致卸载/回滚断言抛错。新增 `Get-ProfileDependency` 统一安全读取。

#### 变更

* **默认提供“provider 安全”的工具 Schema**（此前为可选）。上游 Pydantic 为每个可选
  参数生成 `anyOf: [X, {"type": "null"}]`，DSH 会原样转发给供应商，而这正是
  被放弃的 v1.1 运行期插件触发 `INVALID_REQUEST` 的形状。默认路径现在：
  * 折叠 `anyOf: [X, {"type": "null"}]` → `X`，并去掉随之失去意义的 `"default": null`；
  * 把**纯标量联合**（上游 `list-journal.vol` 的 `int | str`）归一为 `{"type": "string"}`；
  * 去掉冗余的 `title` 注解。
  工具的语义与参数集**完全不变**（FastMCP 仍按原始 Python 签名校验与转换，
  且 `int` 作为字符串传入同样被接受）。需要原样上游 Schema 时用
  `--no-sanitize-schema`，或在 `portable.runtime.json` 里设 `"sanitizeSchema": false`。
  安装器写入的 `portable.runtime.json` 现在显式含 `sanitizeSchema: true`。
* **`plan` 现在是真正的 dry-run**：走与 `install` 相同的代码路径并抑制全部副作用，
  输出“将要做什么”的步骤清单；且它有 FAIL 时退出码为 2（此前只看 check 报告且恒为 0）。
* 测试组 C 的模式改名以反映事实：`served`（默认发行路径，必须全清）与
  `upstream`（`--no-sanitize-schema`，仅用于记录被消除的风险形状，记为 WARN）。
* 发行版文本中不再出现开发机账号名；`docs/provenance/audit-v1.0.md` 与
  `PROJECT_STATE.md` 中的账号名已替换为 `<user>`。
* 新增 `A3.exemptIsClean` 检查：被豁免路径扫描的“来源/状态”文件仍会被扫描
  私钥、Cookie、JWT 与账号名，防止豁免变成藏 PII 的地方。

### 新增

* **通用发行结构**：`bundle/`、`upstream/`、`tools/`、`tests/`、`docs/`、
  `manifest.json`、`START_HERE.md`、`INSTALL_PROMPT.md`。
* **路径无关的 Preset 声明**：`cordis.patch.yml` 中所有位置改为运行期 `!!js` 求值
  （bundle 目录、启动器路径、`cwd`、Python 解释器），任何一项缺失都只降级、不中断。
* **机构无关**：移除预设机构名（开发机上写死的那个具体机构名），并移除开发机上的上游
  `.venv` 绝对路径、Bundle 绝对路径与工作区目录名；
  Skill 与启动器说明改为使用"用户自己配置的 CNKI Profile"。
* **内置上游源码**：`upstream/cnki-mcp/`（`cnki-mcp 0.1.1`，GPL-3.0），含
  `uv.lock`，安装时用 `uv sync --frozen --no-dev --no-editable` 精确复现依赖。
  不复制开发机的 `.venv`。
* **安装器** `tools/portable.ps1`：
  `check`（只读 dry-run）/ `install` / `upgrade` / `uninstall` / `rollback` /
  `status` / `diagnose` / `plan`，含 `-DryRun`、`-Json`、`-InstallRoot`、
  `-DshProfile`、`-CnkiProfile`、`-Upstream vendor|pypi|git`、`-LinkMode link|copy`。
* **安装前备份与失败恢复**：Profile 的 `package.json`/`pnpm-lock.yaml` 等写入
  `_portable\backups\<时间戳>\`；`dsh plugin add` 失败时自动恢复。
* **同名冲突保护**：拒绝静默覆盖未知版本或不兼容的既有安装，除指定 `-Force`。
* **Junction 安全**：唯一删除入口 `Remove-LinkSafely` 只对重解析点执行
  非递归 `Directory.Delete`；卸载时验证链接目标仍然存在。
* **自动测试**：`tests/run_all.ps1`，含静态包测试、stdio MCP 协议探针、
  模型侧工具 Schema 验证、隔离 Profile 的 DSH 安装测试。
* **stdio MCP 探针** `tools/probe_mcp_stdio.py`：真实握手 + 工具目录 + Schema +
  进程清理，且不依赖任何 HTTP 服务。
* **清单与完整性**：`manifest.json` 记录发行版身份、冻结基线哈希、依赖固定版本、
  兼容性矩阵与逐文件 SHA-256；`tools/build_manifest.mjs --check` 校验一致性。
* **可选 Schema 加固**：启动器 `--sanitize-schema`（**当时**默认关闭；`1.0.0-rc1`
  修订后改为默认开启，见本文档开头"变更"一节）把 Pydantic 生成的
  `anyOf: [X, {"type":"null"}]` 折叠为 `X` 并去掉 `title`，用于规避 v1.1 中观察到的
  供应商 `INVALID_REQUEST`。

### 相对 v1.0 生产插件的行为差异

| 项目 | v1.0 | Portable 1.0.0 |
|---|---|---|
| 8 个 MCP 工具与参数 Schema | 原样 | **原样**（默认路径逐字不变） |
| 预设 id / name / order | `cnki-research` / CNKI Research / 5 | 相同 |
| MCP `serverName` / transport | `cnki` / stdio | 相同 |
| 重连策略 | `reconnect` + `failOnStartupError:false` | 相同 |
| `command` / `args` / `cwd` | 写死的开发机绝对路径 | 运行期解析，无任何绝对路径 |
| Skill / Preset 描述中的机构 | 写死具体机构名 | 无机构预设 |
| 无 CNKI Profile 时的启动行为 | `require_profile()` 失败即退出码 2 | 警告后继续启动，由 `login` 按需创建 Profile；`--require-profile` 可恢复旧行为 |
| Skill 位置 | 绝对路径 + 回退 | `createRequire` 解析，无绝对路径回退 |
| 启动器诊断 | `--selfcheck` | 另加 `--check` / `--tools-json` / `--version` / `--sanitize-schema` |
| v1.1 Runtime 工具 | 不存在 | **仍然不存在**（明确不引入） |

### 未包含

* v1.1 Host Runtime Plugin 的任何代码、配置或依赖。
* 任何 `.venv`、浏览器缓存、登录态、Cookie、账号、机构预设或测试日志。
