# START HERE — CNKI Research Portable 1.0.0

给**中国知网（CNKI）文献检索**用的 DSH Desktop 插件发行版。装好之后，在 DSH 里
新建一个 **CNKI Research** 会话，就能直接查知网、取题录、看期刊目录。

* 不需要命令行基础：跟着 [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md) 走就行。
* 不需要重启 DSH：安装完成后刷新一次页面即可。
* 不影响其他模式：Standard / Creator 会话里**看不到**任何知网工具。
* 不绑定机构：用你自己学校的 CNKI 认证，发行包里没有任何机构预设、账号或 Cookie。

---

## 我该先看哪个文件？

| 你的情况 | 看这个 |
|---|---|
| 我是普通用户，想装 | [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md) —— 里面有可以整段粘贴给 DSH 的提示词 |
| 我想先确认这台电脑能不能装（不改动任何东西） | [`INSTALL_PROMPT.md`](INSTALL_PROMPT.md) 第三节的 `-Action check` |
| 我想知道它到底做了什么、为什么这样设计 | [`docs/01-架构与路径契约.md`](docs/01-架构与路径契约.md) |
| 安装出问题了 | [`docs/02-安装卸载与回滚.md`](docs/02-安装卸载与回滚.md) |
| 我想知道支持哪些系统 / DSH 版本 | [`docs/03-兼容性矩阵.md`](docs/03-兼容性矩阵.md) |
| 我要卸载或回滚 | [`docs/02-安装卸载与回滚.md`](docs/02-安装卸载与回滚.md) |
| 我要升级或自己维护这个发行版 | [`docs/04-升级与版本维护.md`](docs/04-升级与版本维护.md) |
| 我想看验证结果（哪些真的测过） | [`docs/05-测试报告.md`](docs/05-测试报告.md) |
| 许可证与第三方来源 | [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) |

---

## 最短路径

```powershell
# 1) 只检查，不动任何东西
powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action check

# 2) 正式安装（会先备份你的 DSH Profile）
#    安装到日常使用的 desktop Profile 时必须带上 -AllowProductionProfile，
#    否则安装器会以 "REFUSED:" 拒绝执行（这是保护你的会话与凭据的门禁）。
powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action install -Yes -AllowProductionProfile

#    只想先试装、不碰日常 Profile 时改用独立 Profile（无需该开关）：
# powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action install -Yes -DshProfile cnki-trial

# 3) 刷新 DSH 页面 → 新建会话 → Agent 预设选 "CNKI Research" → 让它登录知网
```

把第 1 步的输出留好：它会告诉你缺什么、哪些项目**没测过**。

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

## 目录结构

```
CNKI-Research-Portable-1.0.0/
├── START_HERE.md              <- 你在这里
├── DEPLOYMENT_README.md       <- 用户部署与三步验收指南
├── INSTALL_PROMPT.md          <- 粘贴给 DSH 的提示词
├── README.md                  <- 项目总览与设计取舍
├── manifest.json              <- 版本、依赖、兼容性、逐文件 SHA-256
├── VERSION
├── LICENSE                    <- GNU GPL v3
├── THIRD-PARTY-NOTICES.md
├── CHANGELOG.md
├── bundle/cnki-research/      <- 被安装的 DSH 插件（路径无关）
├── upstream/cnki-mcp/         <- 固定版本的上游源码（GPL-3.0）
├── tools/                     <- 安装 / 检查 / 卸载 / 回滚 / 诊断
├── tests/                     <- 自动测试
└── docs/                      <- 说明、兼容性矩阵、测试报告、来源记录
```

---

## 三条你必须知道的限制

1. **不提供全文下载。** 只做检索与元数据。
2. **机构认证要你本人操作。** 第一次用会弹出 Chromium 窗口，你需要在里面完成学校
   SSO 或验证码；这一步无法自动化，也无法由发行包代做。
3. **只验证过 Windows 11 x64。** 其他系统一律标注为未验证，不声称可用。
   详见 [`docs/03-兼容性矩阵.md`](docs/03-兼容性矩阵.md)。
