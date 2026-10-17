# THIRD-PARTY NOTICES / 第三方来源说明

本文件说明 CNKI Research Portable 发行包中包含、调用或依赖的第三方组件、其许可证
与获取来源。发行包根目录的 `LICENSE` 是 **GNU General Public License v3.0** 全文。

---

## 1. 本发行版的许可证

**CNKI Research Portable 整体以 GPL-3.0-only 发布。**

原因：本发行版的 stdio 启动器
（`bundle/cnki-research/launcher/cnki_research_launcher.py`）在运行时导入并链接
上游项目 `cnki-mcp`（GPL-3.0），二者构成结合作品，因此启动器与本发行包整体采用
与上游一致的 GPL-3.0。`bundle/cnki-research/package.json` 中的 `license` 字段
同样声明为 `GPL-3.0-only`。

GPL-3.0 允许再分发，条件是：

* 保留许可证与版权声明；
* 提供完整的对应源代码；
* 不附加额外限制。

本发行包通过**内置上游完整源码**（`upstream/cnki-mcp/`，含 `LICENSE`、
`pyproject.toml`、`uv.lock`、`src/`、`tests/`）满足源码可得性要求。

---

## 2. 内置（随包分发）的第三方组件

### 2.1 cnki-mcp 0.1.1

| 项目 | 内容 |
|---|---|
| 名称 | `cnki-mcp` |
| 版本 | `0.1.1`（与冻结基线一致，**不升级**） |
| 许可证 | GNU General Public License v3.0 |
| 版权 | Copyright (C) Sepine Tam（谭淞） |
| 上游仓库 | https://github.com/sepinetam/cnki-mcp |
| PyPI | https://pypi.org/project/cnki-mcp/0.1.1/ |
| 内置路径 | `upstream/cnki-mcp/`（完整源码） |
| 完整性 | `docs/provenance/upstream-src.sha256.json` 记录每个源文件的 SHA-256 |
| 依赖解析 | `upstream/cnki-mcp/uv.lock`；安装时使用 `uv sync --frozen` |

已核验的 PyPI 制品哈希（用于 `-Upstream pypi` 策略的离线校验）：

* `cnki_mcp-0.1.1-py3-none-any.whl`
  sha256 `a43399eddb060d521359db90cade56263b55a28b77e05e71ccd27b5007dd20d1`
* `cnki_mcp-0.1.1.tar.gz`
  sha256 `1f6098b238b1eafb051984a90a61ff49612a677fa8035dfc60b0a9281460fa99`

> 上游 0.1.1 的 README 声明该项目为个人学习项目，与 CNKI 无隶属关系，不提供全文
> 下载。使用本发行版时请遵守知网使用条款。

### 2.2 js-yaml 4.3.2（仅测试用）

| 项目 | 内容 |
|---|---|
| 名称 | `js-yaml` |
| 版本 | `4.3.2` |
| 许可证 | MIT |
| 版权 | Copyright (C) 2011-2015 by Vitaly Puzrin |
| 来源 | 提取自本机 DSH Desktop 内置的 `app.asar`（`js-yaml@4.3.2`） |
| 内置路径 | `tools/vendor/js-yaml/js-yaml.mjs` 与 `tools/vendor/js-yaml/LICENSE` |
| 用途 | `tests/test_static_package.mjs` 解析 DSH 的 `!!js` entry-list YAML 方言 |

**只读运行时不需要它**；删除它只会让静态测试无法运行，不影响安装、运行与卸载。

---

## 3. 运行期由包管理器获取、不随包分发的依赖

这些组件在安装时由 `uv sync --frozen` 按 `upstream/cnki-mcp/uv.lock` 精确安装到
目标机自带的 `<安装根目录>\.venv`，**不随发行包分发**。

| 名称 | 固定版本 | 许可证 | 来源 |
|---|---|---|---|
| `mcp`（MCP Python SDK） | 1.30.0 | MIT | https://pypi.org/project/mcp/ |
| `playwright`（Python） | 1.63.0 | Apache-2.0 | https://pypi.org/project/playwright/ |
| `pydantic` | 2.13.5 | MIT | PyPI |
| `starlette` | 1.6.0 | BSD-3-Clause | PyPI |
| `uvicorn` | 0.53.0 | BSD-3-Clause | PyPI |
| `httpx` | 0.28.1 | BSD-3-Clause | PyPI |
| `anyio` | 4.15.1 | MIT | PyPI |
| `typer` / `click` / `rich` / `pygments` | 见 `uv.lock` | MIT / BSD-3-Clause | PyPI |
| `cryptography` | 50.0.1 | Apache-2.0 OR BSD-3-Clause | PyPI |
| `pywin32` | 312 | PSF-2.0 | PyPI |
| 其余传递依赖 | 见 `uv.lock` | 见各项目 | PyPI |

完整的精确版本与哈希记录在 `upstream/cnki-mcp/uv.lock`（`uv sync --frozen` 的
唯一权威来源）。

### 3.1 Playwright 浏览器（Chromium）

安装脚本可执行 `<venv>\Scripts\python.exe -m playwright install chromium`。
下载的 Chromium 存放在 `%LOCALAPPDATA%\ms-playwright`，**不随发行包分发**，
其许可证为 BSD-3-Clause 及若干第三方许可证（见该目录内的
`LICENSE`/`Third Party Notices`）。

---

## 4. 宿主平台（不随包分发）

| 名称 | 说明 |
|---|---|
| DSH Desktop | 本发行版安装到其中的 **插件宿主**，采用其官方 `dsh plugin` / Plugin Manager 接口。发行包不包含、不修改 DSH 的任何文件。 |
| Electron 44.0.0 | DSH Desktop 自身的运行时。 |
| Python 3.12.x | 目标机上的解释器，或 DSH Desktop 自带运行时（`python 3.12.14`）。发行包不分发解释器。 |
| uv | 依赖解析工具（Astral，MIT / Apache-2.0）。未安装时由安装器按 manifest 记录的版本用 `pip` 安装。 |

---

## 5. 明确不包含的内容

发行包**不包含**以下任何内容，也没有任何代码路径会收集它们：

* 任何账号、密码、API Key 或令牌；
* 任何 CNKI 登录 Cookie、`cookies.json`、`storage_state.json`；
* 任何浏览器 Profile、浏览器缓存或 `%LOCALAPPDATA%\ms-playwright` 内容；
* 开发者机器上的 `.venv`、`node_modules` 或开发工作区目录；
* 任何机构（学校）名称、机构认证配置或预设机构；
* 用户私人文件、测试日志或会话记录。

> **精确范围说明。** 上述"不包含机构名称"针对**可执行载荷**：`bundle/**`、
> `tools/**` 与 `upstream/**` 内没有任何机构名、机构预设或认证配置（由静态测试
> `A3.institutionNeutral` 与 `A4.noCredentials` 强制）。本发行版的**开发者文档**
> （`CHANGELOG.md` 等）在描述历史变更时可能提及某个机构，那只是变更记录，不是预设。

CNKI 机构认证只能由使用者在目标机上通过 `login` 工具弹出的浏览器窗口自行完成；
登录状态保存在**目标机**的 `%USERPROFILE%\.cnki-mcp\profiles\<名称>\` 下。

---

## 6. 复核方式

```powershell
# 逐文件核对 SHA-256（与 manifest.json 一致）
node tests\test_static_package.mjs

# 确认包内没有凭据、Cookie 或开发机绝对路径
# 同一测试的 A3 / A4 检查项即为该验证
```

任何不一致都会以 `FAIL` 报出，并以非零退出码结束。
