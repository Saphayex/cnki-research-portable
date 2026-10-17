# @local/dsh-cnki-research — CNKI Research Preset（Portable 发行版）

DSH Desktop 的 **CNKI Research** Agent Preset（`cnki-research`）：在保留 Standard
全部能力的基础上，加入一个**仅在预设作用域内可见**的 stdio MCP Client，
连到本机的 `cnki-mcp`（中国知网），并挂载 `cnki-literature-search` 检索技能。

机构认证由**用户自己配置的 CNKI Profile** 完成，本发行版不预设、不包含任何机构、
账号、Cookie 或认证状态。

## 目录

```
bundle/cnki-research/
├── package.json                    # dsh.bundle.patch 清单（配置型 bundle，无 Host/Client 入口）
├── cordis.patch.yml                # 预设声明：id=cnki-research，order=5；全部路径在运行时解析
├── launcher/
│   └── cnki_research_launcher.py   # stdio 兼容启动器（修复上游 Playwright 同步/异步缺陷）
├── skills/
│   └── cnki-literature-search/SKILL.md
└── README.md
```

## 路径无关契约

`cordis.patch.yml` 中**没有任何绝对路径**。每个位置都在条目激活时解析：

| 配置项 | 解析方式 |
|---|---|
| Bundle 目录 | `createRequire(baseUrl).resolve('@local/dsh-cnki-research/package.json')`，回退到 `<baseUrl>node_modules/@local/dsh-cnki-research/` |
| `skills` 目录 | `<bundle>/skills` |
| MCP `args` | `<bundle>/launcher/cnki_research_launcher.py` |
| MCP `cwd` | `<bundle>` |
| MCP `command`（Python） | `$CNKI_RESEARCH_PYTHON` → `<bundle>/portable.runtime.json` 的 `python` → `<bundle>/../../.venv` → `<bundle>/../.venv` → PATH 上的 `python` |

`!!js` 表达式由 Cordis loader 的 `interpolate` 求值（见
`@deepseek-ai/cordis-plugin-loader` 的 `src/config/utils.ts`）。表达式抛异常会导致
预设激活失败，因此**每个表达式都整体 try/catch 并总是返回字符串**，缺失任何可选文件
都只会降级，不会中断预设加载。

`portable.runtime.json` 由 `tools/portable.ps1` 在安装时写入，仅记录解释器与版本信息，
是可选的诊断与显式覆盖手段。

## 安装

推荐使用发行包根目录的安装器（同时负责 Python 环境、上游源码与依赖）：

```powershell
# 只检查，不改动任何东西
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\portable.ps1 -Action check
# 安装到当前用户默认 DSH Profile
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\portable.ps1 -Action install
```

也可以直接用 DSH 官方插件管理器安装本 bundle（需先自行准备解释器与
`portable.runtime.json`）：

```powershell
dsh plugin --profile desktop add "link:<本目录的绝对路径>"
```

`dsh plugin` 会转发给 profile 目录里的 pnpm，并把该包加入
`dsh.profile.bundles`。安装后刷新页面，在新建会话的 Agent 预设里选 **CNKI Research**。

卸载、回滚与诊断见发行包 `docs/02-安装卸载与回滚.md`。

## 隔离模型（为什么它不会污染其他模式）

- 所有插件行都是 `preset-cnki-research` 这个 `@deepseek-ai/dsh-agent-preset`
  声明的**子行**，因此激活在预设自己的 Cordis scope 里
  （`dsh-agent-preset-registry` 的 `createScope(owner, key)`），**从不进入根组合**。
- 工具可见性沿 scope 链合并，所以 `mcp__cnki__*` 只出现在 `agentPreset` 为
  `cnki-research` 的会话里。
- MCP `serverName` 预约按 scope 隔离（`activeServerNames` WeakMap），
  与根作用域的同名实例不会冲突。
- 安装**不修改** profile 的 `cordis.patch.yml`，不动内置 Preset；
  日常切换模式不做任何全局配置变更、不触发全局 HMR。

## 关于启动器

上游 `cnki-mcp 0.1.1` 的 stdio 传输不可用：MCP Python SDK 在事件循环线程上直接调用
同步工具函数（`mcp/server/fastmcp/utilities/func_metadata.py`），而 stdio 唯一的
浏览器入口 `login` 会在该线程执行 `sync_playwright()`
（`cnki_mcp/core/auth.py`），必然抛
`It looks like you are using Playwright Sync API inside the asyncio loop`；
stdio 的 lifespan 又不调用 `start_network`，于是浏览器永远无法启动。

`launcher/cnki_research_launcher.py` 复用上游 `McpToolService`，只把分发方式改成
`async` + `asyncio.to_thread`（HTTP 传输本来就是这么做的），**不修改上游任何文件**。

自检与调试：

```powershell
$py = "<安装根目录>\.venv\Scripts\python.exe"
$launcher = "<本目录>\launcher\cnki_research_launcher.py"
& $py $launcher --selfcheck                 # 上游是否已修复
& $py $launcher --check                     # 环境报告（JSON）
& $py $launcher --tools-json out.json       # 导出 MCP 工具 Schema（不启动浏览器）
& $py $launcher --version
```

上游修复后 `--selfcheck` 会输出 `VERDICT: upstream may be fixed`，那时把
`cordis.patch.yml` 的 `command`/`args` 换回 `cnki-mcp serve --transport stdio`
并删除本启动器即可。

## 工具数量说明

stdio 传输下上游会额外注册 `login` / `logout`，所以会话里是 **8 个**
`mcp__cnki__*` 工具 = 6 个核心检索工具 + 2 个 stdio 专属会话工具，
另有 1 个 MCP 资源 `profile://list`。

## 许可证

本 bundle 的启动器链接上游 `cnki-mcp`（GPL-3.0），因此整体以
**GPL-3.0-only** 发布；完整第三方来源说明见发行包根目录
`THIRD-PARTY-NOTICES.md`。
