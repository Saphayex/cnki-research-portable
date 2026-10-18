# INSTALL_PROMPT.md — 交给 DSH 的一键安装提示词（统一安装/升级包）

本文件是**给人看的说明**，也可以直接把它交给 DSH。

> **适用包**：`CNKI-Research-Portable-1.0.0-rc.3.zip`（官方发行名；统一安装/升级包，Pre-release）。
> 同一个包既支持**全新安装**，也支持**已有 `1.0.0-rc.2` 标准安装的安全原地升级**。
> 包内统一入口是 `tools\setup.ps1`；原有 `tools\portable.ps1` 命令保持旧语义（其
> `-Action upgrade` 是 LEGACY 重装覆盖，**不是**安全增量升级）。

---

## 一、普通用户怎么用（全新安装，3 步）

1. **解压**：把 `CNKI-Research-Portable-1.0.0-rc.3.zip` 解压到**一个空目录**
   （或全新目录）。路径可以包含空格和中文，例如 `D:\我的工具\CNKI Research`。
   **绝对不要**把新 ZIP 解压覆盖到已有的旧安装目录上。
   解压后请确认能看到 `START_HERE.md`、`bundle\`、`tools\`、`manifest.json`、`SHA256SUMS.txt`。

2. **打开**：启动 DSH Desktop → 新建会话时选择**创造模式（Creator / 全部工具权限）**，
   把工作目录设为**刚才解压出来的那个目录**。

3. **粘贴**：把下面代码块里的**全部内容**复制粘贴给 DSH，然后按它的提示操作。

> 安装过程会做几件需要你点头的事：下载并安装 `uv`、下载 Chromium 浏览器内核、
> 把 CNKI Research 安装进你的 DSH Profile。DSH 会逐项征求你的同意。

---

## 二、粘贴给 DSH 的提示词（全新安装）

```text
你是 CNKI Research Portable 的安装助手。请严格按下面的步骤，把当前工作目录里的
CNKI Research Portable 1.0.0-rc.3（统一安装/升级包）安装到本机 DSH Desktop，
并在最后输出一份安装报告。

硬性规则：
- 全程使用相对路径与 %USERPROFILE% / %LOCALAPPDATA% 这类环境变量，不要写死任何盘符。
- 不要修改发行包以外的任何项目源码；不要修改 DSH Desktop 自身文件。
- 凡是会改动系统或个人环境（安装 uv、下载 Chromium、写入 DSH Profile）的动作，
  必须先用一句话说明将要做什么，并征求我的同意后再执行。
- 当前目录可能已经被解压并用于安装；不要为了“干净”而删除当前目录里的任何东西。
- 任何一步失败都不要跳过或假装成功；如实报告失败原因，并给出可恢复的建议。
- 无法在本机验证的项目，必须写成 NOT TESTED，不能写成 PASS。

步骤：

1. 确认发行包结构完整：当前目录下应存在 START_HERE.md、manifest.json、SHA256SUMS.txt、
   VERSION、bundle\cnki-research\cordis.patch.yml、tools\setup.ps1、
   tools\portable.ps1、upgrade-data\rc2-to-rc3.json、upstream\cnki-mcp\pyproject.toml。
   若有缺失，停止并报告。

2. 先跑一次“只检查、不改动”的检查与计划，并把结果讲给我听：
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan
   把每条 WARN / FAIL / NOT TESTED 用中文解释一遍，并明确告诉我缺什么。
   如果 DSH Desktop、Python 或 uv 没有找到，先告诉我缺哪个，不要自行安装。

3. 询问我三件事，等我回答后再继续：
   (a) 是否同意安装缺失的 uv（会按 manifest.json 记录的版本用 pip 安装）；
   (b) 是否同意下载 Playwright 的 Chromium（约数百 MB）；
   (c) 要安装到哪个 DSH Profile（默认 desktop；如果我想先试，就用一个自定义名字）。

4. 执行安装（重要：安装到日常使用的 desktop Profile 会被安全门拒绝，见下方说明）：
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action install -Yes -AllowProductionProfile
   如果需要指定 Profile 或安装根目录，追加 -DshProfile <名字> / -InstallRoot <目录>。
   安装器会自己备份 DSH Profile 的 package.json 与 pnpm-lock.yaml，然后通过官方
   dsh plugin 接口安装。若报告 restart-required，请立即停下来告诉我，不要重启 DSH。

   > 为什么需要 -AllowProductionProfile
   > 安装器内置一道硬性保护：任何会改动正在使用的真实 DSH 数据目录
   > （%USERPROFILE%\.dsh，里面是你的 sessions / storages / 凭据 / CNKI 登录态）的
   > 操作，在没有显式授权时会直接拒绝执行，并打印一段以 REFUSED: 开头的说明。
   > 因此安装到日常使用的 desktop Profile 时，必须加上 -AllowProductionProfile；
   > 这是你（用户）授权的标志，不要由安装助手自行添加。
   >
   > 如果我想先在一个独立 Profile 里试装，先执行：
   > powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action install -Yes -DshProfile cnki-trial
   > 这种方式不需要 -AllowProductionProfile，也不会影响我的 desktop Profile。
   >
   > 另外，统一入口 setup.ps1 **不接受** -CnkiProfile（它只属于原安装器
   > tools\portable.ps1 的 LEGACY 专用选项）；如果确实要预设默认 CNKI Profile，
   > 请在装好后于 CNKI Research 会话里自行选择，或由用户本人直接调用原安装器
   > tools\portable.ps1 -Action install -CnkiProfile <名字>（LEGACY；需 -AllowProductionProfile 授权；不确定时不要使用）。

5. 检查安装结果：
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action status
   再把测试跑一遍：
   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_all.ps1
   把每一组结果（静态 / MCP / Schema / DSH 安装）用中文汇报，失败的给出原始输出。

6. 指导我完成机构认证（需要人工操作，请清楚提示我）：
   - 让我刷新 DSH 页面，新建会话时在 Agent 预设里选择 "CNKI Research"。
   - 在该会话里让我调用 mcp__cnki__login（或直接让我说“登录知网”）。
   - 会弹出一个可见的 Chromium 窗口，请让我在该窗口里完成我所在学校/机构的 SSO 或
     验证码认证，最长等待 120 秒。
   - 成功后 login 会返回 {"success": true, "profile": "<机构 Profile 名>"}。
   - 如果我的机构认证方式不是 FSSO，请告诉我你会怎么处理，不要伪造成功。

7. 认证成功后，做一次真实低风险检索验收（数量要小）：
   - 调用 mcp__cnki__easy-search，keywords 用我指定的关键词，limit 设为 3。
   - 把真实返回的 title / authors / journal / date / url 原样贴给我，不要改写、不要编造。
   - 然后说明这只验证了“能检索”，没有验证“结果正确性”。
   - 如果我暂时无法完成机构认证，请把这一步标记为 NOT TESTED，并说明原因。

8. 最后输出安装报告，必须包含下列字段，取值只能是 PASS / FAIL / WARN / NOT TESTED：
   PACKAGE_VALIDATION
   INSTALL_STATUS
   DEPENDENCY_STATUS
   DSH_INSTALLATION_STATUS
   MCP_STATUS
   TOOL_SCHEMA_STATUS
   ISOLATION_STATUS
   REAL_SEARCH_STATUS
   ROLLBACK_STATUS
   DSH_RUNTIME_ACTIVATION_VERIFIED（本包不声称已验证：应为 NOT TESTED）
   RELEASE_READINESS
   报告里还要写明：安装根目录、DSH Profile、Python 解释器路径与版本、
   cnki-mcp 版本、DSH Desktop 版本、备份目录、以及 restart-required 的取值。

如果我在第 3 步选择了先在自定义 Profile 里试装，请把上面所有步骤里的 Profile
换成那个名字，并在报告里注明这还没有影响我的日常 desktop Profile。

现在开始，从第 1 步做起。
```

---

## 三、我已经装过 RC2：安全原地升级（不要用 Creator 跑 APPLY）

升级是**文件级事务**：只替换变化的发行文件、更新 2 个环境元数据文件，
**不重装 venv、不重跑插件管理器、不重建 junction、不需要联网**，并保留会话、凭据与 CNKI 登录态。
因为 **APPLY 必须在 DSH 正常退出后执行**，所以它不是第 2 节那种“交给 DSH 自动执行”的流程；
请让 DSH 退出后，在一个**独立的 PowerShell 窗口**里手动执行下面的命令
（由你自己或由 DSH Standard 会话中的命令工具代跑第 2、3 步也可以；第 4 步必须在 DSH 关闭后）。

```powershell
# 0) 把统一发行 ZIP 解压到一个全新的空目录（不要覆盖旧安装目录）

# 1) 只读检查（可以在 DSH 运行时执行）：识别 RC2 状态并列出将修改/新增的文件
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check -InstallRoot "<RC2 安装根目录>"

# 2) 只读 PLAN（可以在 DSH 运行时执行）：记下输出里的 planId
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan -InstallRoot "<RC2 安装根目录>"

# 3) 正常退出 DSH（等它完全关闭；不要强杀进程）

# 4) 独立 PowerShell 窗口：APPLY（必须带 -PlanId 与 -Yes）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action upgrade -InstallRoot "<RC2 安装根目录>" -PlanId "<planId>" -Yes

# 5) 正常重新打开 DSH，新建 CNKI Research 会话验收；文件级完成状态用：
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action verify -InstallRoot "<RC2 安装根目录>"

# 6) 需要退回 RC2：
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action rollback -InstallRoot "<RC2 安装根目录>" -Yes
```

升级的安全边界：

* 只支持**标准原地安装（Layout A）**；独立运行根（Layout B）会被拒绝并给出人工指引。
* 安装内容未知/被修改/混合时**拒绝写入**并列出冲突文件；绝不覆盖用户修改。
* 计划（planId）与执行之间的状态变化会让旧 planId 失效，必须重新 PLAN。
* 真实 Profile + DSH 正在运行时 APPLY 会被拒绝（`DSH_IN_USE`）；绝不强杀 DSH。
* 文件级完成（`FILE_UPGRADE_COMPLETE`）**不等于**运行期验收；
  `DSH_RUNTIME_ACTIVATION_VERIFIED` 仍为 `NOT TESTED`，需要你重新打开 DSH 后人工确认。

> **不要**用 `tools\portable.ps1 -Action upgrade` 做这件事：它是 LEGACY 的“重装覆盖”，
> 不校验 RC2 状态、不做逐文件事务备份，也不是本包提供的安全升级路径。

---

## 四、无人值守 / 先确认兼容性（dry-run）

只想确认这台电脑能不能装、不改动任何东西：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check -Json
```

* `-Action check` / `-Action plan` 是**只读**的：不装依赖、不改 DSH Profile、不写安装根。
* 退出码：`0` 成功/无 FAIL（含“已经是 RC3，无需操作”）；`2` 被拒绝 / 有 FAIL / 状态未知；
  `1` 工具自身出错。
* 加 `-Json`（或 `-OutFile <路径>`）输出机器可读结果，便于把兼容性结论交给别人复核。

> 旧命令 `tools\portable.ps1 -Action check` 仍可用（字节未变、只读），
> 但它不认识统一安装状态机；统一入口请用 `setup.ps1`。
> 注意：**不要**把 `tools\portable.ps1 -Action plan` / `-DryRun` 当作只读计划——
> 实现上它会创建一份 Profile 备份目录（LEGACY 已知限制）。

---

## 五、常见问题

| 现象 | 处理 |
|---|---|
| `dsh.cmd not found` | DSH Desktop 没装在默认位置，或没把 CLI 加到 PATH。统一入口 `setup.ps1` 不接受 `-DshCli`（它会自动发现 CLI）；需要手工指定时用原安装器 `tools\portable.ps1 -Action install -DshCli "<DSH安装目录>\resources\runtime\cli\bin\dsh.cmd"`（LEGACY）。 |
| `profile 'desktop' does not exist` | 先启动一次 DSH Desktop，让它初始化 Profile，然后再安装。 |
| `no Python >= 3.11 found` | 安装 Python 3.11+，或用原安装器 `tools\portable.ps1 -Action install -Python "<python.exe 绝对路径>"` 指定（LEGACY；统一入口 `setup.ps1` 不接受 `-Python`；DSH 自带运行时里的 Python 也可以）。 |
| 安装时提示 `REFUSED:` | 目标是你正在使用的真实 DSH 数据目录；确认无误后由**你本人**决定是否追加 `-AllowProductionProfile`。 |
| 升级提示 `LAYOUT_SEPARATE_PACKAGE_ROOT` | 该安装根是“独立运行根”（Layout B），增量升级不支持；按 `docs/04` 的人工迁移步骤处理。 |
| 升级提示 `UNKNOWN_OR_MODIFIED` / 冲突清单 | 安装内容被修改或混合，升级器拒绝写入。先恢复干净的 RC2 安装，或改用全新安装；不要手工编辑 Profile。 |
| 升级提示 `DSH_IN_USE` | DSH 仍在运行：正常退出 DSH，在独立 PowerShell 中重试。 |
| 提示已安装同名插件（全新安装时） | 该 Profile 里已有 `@local/dsh-cnki-research`。先 `-Action check -InstallRoot <旧根>` 确认版本；需要覆盖时按 README 的 LEGACY/重装说明处理。 |
| 安装后页面上没有 CNKI Research | 刷新页面；仍没有就运行统一入口 `setup.ps1 -Action status`（或 `-Action verify`）检查；需要更深的启动器/MCP 诊断时用原安装器 `tools\portable.ps1 -Action diagnose`（LEGACY）。不要在运行中的 desktop Profile 上手工改 `package.json`。 |
| 想撤掉 | 全新安装：`setup.ps1 -Action uninstall -Yes`；想回到装之前：`setup.ps1 -Action rollback -Yes`（安装器备份）。升级之后回退：`setup.ps1 -Action rollback -InstallRoot "<RC2 根>" -Yes`（升级事务）。 |
