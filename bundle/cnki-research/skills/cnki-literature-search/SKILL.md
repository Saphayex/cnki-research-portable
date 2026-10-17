---
name: cnki-literature-search
description: 在 CNKI Research 模式下使用本机 cnki-mcp 进行中国知网文献检索、期刊目录与题录元数据获取时的工作规范。适用于知网查文献、找综述、按作者/机构/基金/期刊检索、查某一期的全部文章、做文献计量与引用整理，以及遇到登录过期、机构认证或验证码需要人工接管时。
---

# CNKI 文献检索工作规范

本 Skill 只服务于 `cnki-research` 模式。工具由 Preset 专属的 stdio MCP 子进程
（`mcp__cnki__*`）提供，**仅在本模式的会话中可见**。

## 0. 先确认连接

1. 工具清单应包含 8 个 `mcp__cnki__*` 工具。若一个都没有，说明 MCP 子进程尚未连上：
   等待数秒后重试；仍无则告知用户运行发行包自带的诊断工具
   （`tools/portable.ps1 -Action diagnose`），不要自行重启 DSH。
2. **浏览器是按需启动的**。第一次检索前先调用 `mcp__cnki__login`。
   `login` 不带参数时使用本机默认的 CNKI Profile；需要指定别的机构时传
   `profile`（如 `mcp__cnki__login(profile: "MyUni")`）。
   返回 `{"success": true, "profile": "<机构名>"}` 后才可检索。
3. 任何时候收到 `please call login before using browser tools`，都表示浏览器未启动或
   已被 `logout` 关闭：重新调用 `mcp__cnki__login` 即可，不要重复重试检索工具。

## 1. 工具

| 工具 | 用途 |
|---|---|
| `mcp__cnki__easy-search` | 一框式检索。参数 `keywords`（必填）、`limit`（默认 10）、`sort_by` |
| `mcp__cnki__advanced-search` | 结构化专业检索，字段见下 |
| `mcp__cnki__get-info-from-url` | 用检索结果里的 `url` 取单篇题录 |
| `mcp__cnki__get-info-by-detail` | 按篇名等细节定位并批量取题录 |
| `mcp__cnki__list-journal` | 按 ISSN + 年 + 期，取某一期的全部文章 |
| `mcp__cnki__search-issn` | 用期刊名查规范名与 ISSN |
| `mcp__cnki__login` | 启动/切换 Profile 的持久浏览器，是检索前的必要步骤 |
| `mcp__cnki__logout` | 关闭浏览器（保留已保存的登录状态） |

## 2. 检索策略

**普通检索**用 `easy-search`，关键词写自然语言或知网一框式语法。

**需要精确控制时**用 `advanced-search`，它把参数拼成知网专业检索式：

* 字段：`SU` 主题、`TKA` 篇关摘、`KY` 关键词、`TI` 篇名、`FT` 全文、`AU` 作者、
  `FI` 第一作者、`RP` 通讯作者、`AF` 作者单位、`FU` 基金、`AB` 摘要、`CO` 小标题、
  `RF` 参考文献、`CLC` 分类号、`LY` 文献来源、`DOI`、`CF` 被引频次。
* 运算符：`and` / `or` / `not`、`*`（同时包含）、`+`（或）、`-`（排除）、`%`（模糊）。
  例：`SU=('经济发展' + '可持续发展') * '转变' - '泡沫'`。
* `advanced-search` 的入参已按字段拆分，一般不需要自己写检索式；写复杂式时用
  `easy-search` 直接传知网语法更灵活。

**排序 `sort_by`**：`relevance`/`相关度`（默认）、`date`/`发表时间`、
`citation`/`被引`、`comprehensive`/`综合`。
找最新进展用 `date`，找领域奠基文献用 `citation`。

**筛选**：`year_from` / `year_to`；`document_type` 取 `学术期刊`、`学位论文`、`会议`、
`报纸`、`图书`、`年鉴`、`专利`、`标准`、`法律法规`；`source_types` 取 `北大核心`、
`CSSCI`、`CSCD`、`AMI`、`WJCI`、`EI`、`SCI`（可多选）。做中文核心综述时优先
`['北大核心','CSSCI']`。

**期刊整期**：先用 `search-issn` 把刊名换成 ISSN，再用 `list-journal` 取某年某期。
`vol` 传知网页面上的期号（如 `1` 或 `01`），返回里 `volume` 与 `issue` 是分开的。

## 3. 结果处理

* 检索返回 `title` / `authors` / `journal` / `date` / `url`。
* **`url` 只在约 10 分钟内可靠**。需要题录详情时，检索后立刻对目标条目调用
  `get-info-from-url`；过期 URL 仍会尝试，但不保证成功。
* `get-info-by-detail` 会为每个命中条目各取一次详情，`limit` 越大耗时越长，
  建议 ≤ 10。
* **一次检索的 `limit` 不要超过实际需要**。每次检索都是真实浏览器操作，会占用
  共享浏览器；默认 10，精读时用 3–5，扫面时用 20–30 并可配合 `sort_by`。

## 4. 引用与产出

* 引用条目时保留 `title`、`authors`、`journal`、`date` 原值，并给出 CNKI `url`。
* 不得编造题录、作者、期刊、年份、DOI。工具没返回的字段就写“未获取”。
* 需要格式化参考文献时，按用户要求的格式（GB/T 7714、APA 等）排列，但字段来源
  必须是工具返回的真实数据。
* 把检索结论写入工作区文件时，用文件工具写，不要写进 CNKI 的 Profile 目录。

## 5. 失败与人工接管

| 现象 | 处理 |
|---|---|
| `please call login before using browser tools` | 调 `mcp__cnki__login` 后重试 |
| `CNKI requires manual security verification`（验证码/安全验证） | **必须人工接管**：`mcp__cnki__login` 会打开可见的 Chromium 窗口，请用户在该窗口中完成验证，然后重试 |
| 机构 SSO 登录页 / 认证过期 | 同上，提示用户在弹出窗口中完成学校认证；`login` 最长等待 120 秒 |
| 工具调用超时或浏览器无响应 | 先 `mcp__cnki__logout`，再 `mcp__cnki__login`，然后重试一次；仍失败则报告用户 |
| `IssueNotAvailable` | 该年/期尚未发行，换年份或期号 |
| `LoginRequired` 且无可用 Profile | 提示用户调用 `mcp__cnki__login` 并在弹出的浏览器窗口完成机构认证；`login` 会自动创建并保存 Profile。也可运行发行包的 `tools/portable.ps1 -Action check` 查看依赖状态 |

人工接管时要把浏览器窗口标题/当前页面地址转述给用户，并说明需要做什么；不要
反复空转重试。

## 6. 并发与边界

* 浏览器操作在 MCP 子进程内**串行执行，并发上限为 1**。多个 CNKI Research 会话
  共享同一个 MCP 子进程，检索请求会排队；不要并发发起大批检索。
* 单次任务里连续检索是安全的（已实测：连续两次 `easy-search` 均正常）。但请
  **顺序调用**，不要在一个回合里并行发多个 `mcp__cnki__easy-search`。
* 本服务**不提供全文下载**。不要尝试下载 PDF，也不要为了绕过限制而批量抓取。
* 遵守知网使用条款；只做与用户研究任务直接相关的检索。

## 7. 最小可用流程

```
1. mcp__cnki__login                       → {"success": true, "profile": "<你的机构 Profile>"}
2. mcp__cnki__advanced-search
     keywords / title / author / institution / journal
     year_from, year_to
     source_types: ['北大核心','CSSCI']
     sort_by: 'date'  limit: 10
3. 对选中的 2–3 条：mcp__cnki__get-info-from-url(url)
4. 整理为清单/综述，注明来源与 CNKI 链接
```
