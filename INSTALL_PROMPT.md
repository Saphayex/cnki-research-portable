# INSTALL_PROMPT.md — 交给 DSH 的一键安装提示词

本文件是**给人看的说明**，也可以直接把它交给 DSH。

---

## 一、普通用户怎么用（3 步）

1. **解压**：把 `CNKI-Research-Portable-1.0.0.zip` 解压到任意目录。
   路径可以包含空格和中文，例如 `D:\我的工具\CNKI Research`。
   解压后请确认能看到 `START_HERE.md`、`bundle\`、`tools\` 这几项。

2. **打开**：启动 DSH Desktop → 新建会话时选择**创造模式（Creator / 全部工具权限）**，
   把工作目录设为**刚才解压出来的那个目录**。

3. **粘贴**：把下面代码块里的**全部内容**复制粘贴给 DSH，然后按它的提示操作。

> 安装过程会做几件需要你点头的事：下载并安装 `uv`、下载 Chromium 浏览器内核、
> 把 CNKI Research 安装进你的 DSH Profile。DSH 会逐项征求你的同意。

---

## 二、粘贴给 DSH 的提示词

```text
你是 CNKI Research Portable 的安装助手。请严格按下面的步骤，把当前工作目录里的
CNKI Research Portable 发行版安装到本机 DSH Desktop，并在最后输出一份安装报告。

硬性规则：
- 全程使用相对路径与 %USERPROFILE% / %LOCALAPPDATA% 这类环境变量，不要写死任何盘符。
- 不要修改发行包以外的任何项目源码；不要修改 DSH Desktop 自身文件。
- 凡是会改动系统或个人环境（安装 uv、下载 Chromium、写入 DSH Profile）的动作，
  必须先用一句话说明将要做什么，并征求我的同意后再执行。
- 任何一步失败都不要跳过或假装成功；如实报告失败原因，并给出可恢复的建议。
- 无法在本机验证的项目，必须写成 NOT TESTED，不能写成 PASS。

步骤：

1. 确认发行包结构完整：当前目录下应存在 START_HERE.md、manifest.json、VERSION、
   bundle\cnki-research\cordis.patch.yml、tools\portable.ps1、
   upstream\cnki-mcp\pyproject.toml。若有缺失，停止并报告。

2. 先跑一次"只检查、不改动"的干跑，并把结果讲给我听：
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action check
   把每条 WARN / FAIL / NOT TESTED 用中文解释一遍，并明确告诉我缺什么。
   如果 DSH Desktop、Python 或 uv 没有找到，先告诉我缺哪个，不要自行安装。

3. 询问我三件事，等我回答后再继续：
   (a) 是否同意安装缺失的 uv（会按 manifest.json 记录的版本用 pip 安装）；
   (b) 是否同意下载 Playwright 的 Chromium（约数百 MB）；
   (c) 要安装到哪个 DSH Profile（默认 desktop；如果我想先试，就用一个自定义名字）。

4. 执行安装（**重要：默认会被安全门拒绝，见下方说明**）：
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action install -Yes -AllowProductionProfile
   如果需要指定 Profile 或安装根目录，追加 -DshProfile <名字> / -InstallRoot <目录>。
   安装器会自己备份 DSH Profile 的 package.json 与 pnpm-lock.yaml，然后通过官方
   dsh plugin 接口安装。若报告 restart-required，请立即停下来告诉我，不要重启 DSH。

   > **为什么需要 -AllowProductionProfile**
   > 安装器内置一道硬性保护：任何会改动**正在使用的真实 DSH 数据目录**
   > （`%USERPROFILE%\.dsh`，里面是你的 sessions / storages / 凭据 / CNKI 登录态）
   > 的操作，在没有显式授权时会**直接拒绝执行**，并打印一段以 `REFUSED:` 开头的说明。
   > 这道保护是为了防止误操作清空你的会话或历史记录。
   > 因此安装到日常使用的 desktop Profile 时，**必须**加上 `-AllowProductionProfile`；
   > 这是你（用户）授权的标志，不要由 Creator 自行添加。
   >
   > 如果我想先在一个独立 Profile 里试装，先执行：
   > powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action install -Yes -DshProfile cnki-trial
   > 这种方式**不需要** `-AllowProductionProfile`，也不会影响我的 desktop Profile。
   >
   > 另外，`-CnkiProfile <名字>` 会改写真实的 `%USERPROFILE%\.cnki-mcp\profiles\config.json`
   > （你的机构登录状态），所以它同样需要 `-AllowProductionProfile`；不确定时**不要**使用它，
   > 让用户在 CNKI Research 会话里自己选择 Profile。

5. 检查安装结果：
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action status
   再把测试跑一遍：
   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_all.ps1
   把每一组结果（静态 / MCP / Schema / DSH 安装）用中文汇报，失败的给出原始输出。

6. 指导我完成机构认证（需要人工操作，请清楚提示我）：
   - 让我刷新 DSH 页面，新建会话时在 Agent 预设里选择 "CNKI Research"。
   - 在该会话里让我调用 mcp__cnki__login（或直接让我说"登录知网"）。
   - 会弹出一个可见的 Chromium 窗口，请让我在该窗口里完成我所在学校/机构的 SSO 或
     验证码认证，最长等待 120 秒。
   - 成功后 login 会返回 {"success": true, "profile": "<机构 Profile 名>"}。
   - 如果我的机构认证方式不是 FSSO，请告诉我你会怎么处理，不要伪造成功。

7. 认证成功后，做一次真实低风险检索验收（数量要小）：
   - 调用 mcp__cnki__easy-search，keywords 用我指定的关键词，limit 设为 3。
   - 把真实返回的 title / authors / journal / date / url 原样贴给我，不要改写、不要编造。
   - 然后说明这只验证了"能检索"，没有验证"结果正确性"。
   - 如果我暂时无法完成机构认证，请把这一步标记为 NOT TESTED，并说明原因。

8. 最后输出安装报告，必须包含下列字段，取值只能是 PASS / FAIL / WARN / NOT TESTED：
   PORTABLE_BUILD_STATUS
   PACKAGE_VALIDATION
   DEPENDENCY_STATUS
   DSH_INSTALLATION_STATUS
   MCP_STATUS
   TOOL_SCHEMA_STATUS
   ISOLATION_STATUS
   REAL_SEARCH_STATUS
   ROLLBACK_STATUS
   RELEASE_READINESS
   报告里还要写明：安装根目录、DSH Profile、Python 解释器路径与版本、
   cnki-mcp 版本、DSH Desktop 版本、备份目录、以及 restart-required 的取值。

如果我在第 3 步选择了先在自定义 Profile 里试装，请把上面所有步骤里的 Profile
换成那个名字，并在报告里注明这还没有影响我的日常 desktop Profile。

现在开始，从第 1 步做起。
```

---

## 三、无人值守 / 先确认兼容性（dry-run）

只想先确认这台电脑能不能装、不改动任何东西：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action check
powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action check -Json > compatibility-report.json
```

* `-Action check` 是**只读**的：不写文件、不装依赖、不动 DSH Profile。
* 加 `-Json` 输出机器可读结果，适合把兼容性结论交给别人复核。
* 退出码：`0` 没有 FAIL；`2` 有 FAIL（缺少必要依赖）；`1` 工具自身出错。

想先看安装器**打算**做什么而不真正执行（连下载都不做）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action install -DryRun
```

`-DryRun` 会打印每一步命令与将要写入的路径，但不会创建环境、不会安装插件。

---

## 四、常见问题

| 现象 | 处理 |
|---|---|
| `dsh.cmd not found` | DSH Desktop 没装在默认位置，或没把 CLI 加到 PATH。用 `-DshCli "<DSH安装目录>\resources\runtime\cli\bin\dsh.cmd"` 指定。 |
| `profile 'desktop' does not exist` | 先启动一次 DSH Desktop，让它初始化 Profile，然后再安装。 |
| `no Python >= 3.11 found` | 安装 Python 3.11+，或用 `-Python "<python.exe 绝对路径>"` 指定（DSH 自带运行时里的 Python 也可以）。 |
| 提示已安装同名插件 | 说明该 Profile 里已有 `@local/dsh-cnki-research`。安装器**不会**直接覆盖。先 `-Action diagnose` 看清楚来源，或 `-Action uninstall` 后再装。 |
| 安装后页面上没有 CNKI Research | 刷新页面；仍没有就运行 `-Action diagnose`。不要在运行中的 desktop Profile 上手工改 `package.json`。 |
| 想撤掉 | `-Action uninstall`；想回到装之前的状态用 `-Action rollback`。详见 `docs/02-安装卸载与回滚.md`。 |
