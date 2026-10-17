#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""CNKI Research Portable — stdio launcher for DSH Desktop.

WHY THIS FILE EXISTS
--------------------
`cnki-mcp 0.1.1` registers *synchronous* callables with
`mcp.server.fastmcp.FastMCP`. The MCP Python SDK invokes such callables inline on
the asyncio event-loop thread:

    # mcp/server/fastmcp/utilities/func_metadata.py
    if fn_is_async:
        return await fn(**arguments_parsed_dict)
    else:
        return fn(**arguments_parsed_dict)      # <-- runs on the loop thread

Playwright's *sync* API refuses to run when an asyncio loop is running on the
same thread, so the stdio-only `login` tool always fails with:

    It looks like you are using Playwright Sync API inside the asyncio loop.

`create_mcp_server("stdio", ...)` deliberately skips
`tool_service.start_network()` in its lifespan (that call is HTTP/SSE only), so
`login` is the *only* way stdio can start the browser. It cannot, therefore no
browser ever starts and every search tool then fails with
`please call login before using browser tools`.

WHAT THIS LAUNCHER DOES
-----------------------
Nothing under the upstream `cnki-mcp` package is modified. The launcher reuses
the package's own `McpToolService`, registers the same tools, resource and
instructions, and only changes *how each call is dispatched*: every tool wrapper
is `async` and delegates to `asyncio.to_thread`, so the service's
blocking/Playwright work runs on a worker thread. That is exactly what the HTTP
transport already does with `asyncio.to_thread(tool_service.start_network)`.

Consequences:
  * `login` works and can open a visible browser for institutional SSO / CAPTCHA
    hand-over (Playwright then runs on the `cnki-browser` worker thread).
  * The asyncio event loop is never blocked by a browser call.
  * The browser is still started lazily, and only by tools that need it.

PORTABLE DISTRIBUTION NOTES
---------------------------
  * This file contains no absolute path, no drive letter, no user name and no
    institution name. The CNKI Profile is whatever the local `cnki-mcp`
    configuration names; `login` defaults to it and accepts an explicit
    `profile` argument.
  * `--check` prints a machine-readable environment report and exits.
  * `--tools-json` prints the exact MCP `tools/list` payload (name, description,
    JSON Schema) without starting a browser, which is what the automated
    tool-schema test consumes.
  * `--selfcheck` reports whether the upstream stdio transport has been fixed.
  * Unlike v1.0, a missing CNKI Profile no longer kills the process: the server
    starts, `login` can create the profile on demand, and `--require-profile`
    restores the strict behaviour on request.

UPGRADE NOTE
------------
If a future `cnki-mcp` release wraps its sync tools in `anyio.to_thread`,
exposes async tools, or starts the browser for the stdio transport, delete this
file and point the DSH MCP client straight at `cnki-mcp serve --transport stdio`.
`--selfcheck` reports whether that is already the case.

License: GPL-3.0-only. This launcher links against `cnki-mcp`, which is
GPL-3.0; see THIRD-PARTY-NOTICES.md in the distribution root.
"""

from __future__ import annotations

import asyncio
import json
import sys

__version__ = "1.0.0"

SERVER_NAME = "cnki-mcp"

INSTRUCTIONS = """\
CNKI（中国知网）文献检索服务。本进程由 DSH 的 `cnki-research` Preset 按需启动，
使用本机 `cnki-mcp` 配置的机构 Profile（由用户自行完成机构认证）。

工作规范：
1. 浏览器按需启动。若检索工具返回 “please call login before using browser tools”，
   先调用 `login`（不带参数时使用本机默认 Profile），成功后再检索。
2. 所有浏览器操作在本进程内串行执行（并发上限 1）。多个 CNKI Research 会话共享
   本进程，请勿并发发起大量检索。
3. `login` 会打开可见的 Chromium 窗口。遇到机构 SSO、验证码或登录过期时，需要
   人工在该窗口中完成认证；该调用最长等待 120 秒，请预留时间并提示用户接管。
4. 检索结果中的 `url` 仅在 10 分钟内可靠；超时后 `get-info-from-url` 仍会尝试，
   但不保证成功。
5. 本服务只提供检索与元数据，不提供全文下载。
6. 引用文献时保留标题、作者、期刊、日期与 URL 原值，不要编造不存在的条目。
7. 检索式与结果解读遵循本 Preset 的 `cnki-literature-search` Skill。
"""

#: Tools `cnki_mcp` registers for the stdio transport (6 search/metadata + 2 session).
EXPECTED_TOOLS = (
    "easy-search",
    "advanced-search",
    "get-info-from-url",
    "get-info-by-detail",
    "list-journal",
    "search-issn",
    "login",
    "logout",
)


def _log(message: str) -> None:
    """Diagnostics go to stderr only; stdout carries JSON-RPC frames."""
    print(f"cnki-research-launcher: {message}", file=sys.stderr, flush=True)


_SCALAR_TYPES = {"string", "integer", "number", "boolean"}


def _collapse_nullable(node, keys_are_names=False):
    """Turn ``{"anyOf": [X, {"type": "null"}]}`` into ``X`` and drop ``title``.

    DSH forwards an MCP ``inputSchema`` to the provider verbatim
    (``dsh-mcp-client`` -> ``createMcpToolDefinition`` -> ``parameters: inputSchema``
    -> ``input_schema`` on the Anthropic Messages API), so a Pydantic-generated
    nullable union reaches the wire unchanged. That is the shape behind the
    ``INVALID_REQUEST`` failures seen in the abandoned v1.1 runtime plugin.

    Two rewrites are applied:

    1. ``anyOf: [X, {"type": "null"}]`` -> ``X`` (the redundant nullable wrapper),
       plus removal of the now-meaningless ``"default": null``.
    2. A union of only scalar types (upstream emits ``int | str`` for
       ``list-journal.vol``) -> ``{"type": "string"}``. Every JSON representation of
       those scalars is valid as a string, and FastMCP validates and coerces against
       the original Python signature, so the tool still accepts an integer or a
       string exactly as before. This removes the last union the provider sees.

    ``keys_are_names`` is True while walking a mapping whose keys are parameter
    names rather than schema keywords (``properties``/``$defs``/``definitions``/
    ``patternProperties``). Only a *keyword* named ``title`` is the redundant
    annotation this drops -- a *parameter* named ``title`` is part of the tool's
    interface and must survive. Dropping it would silently remove a parameter from
    the model-facing schema (and leave ``required`` naming an undeclared key).
    Each property's own schema is then visited with ``keys_are_names=False``, so
    the annotation on the parameter is still stripped.
    """
    if isinstance(node, list):
        return [_collapse_nullable(item) for item in node]
    if not isinstance(node, dict):
        return node
    out = {}
    for key, value in node.items():
        if key == "title" and not keys_are_names:
            continue
        if keys_are_names:
            # `key` is a parameter name: keep it, but recurse into its schema.
            out[key] = _collapse_nullable(value, keys_are_names=False)
        else:
            child_is_names = key in (
                "properties", "$defs", "definitions", "patternProperties", "dependentSchemas"
            )
            out[key] = _collapse_nullable(value, keys_are_names=child_is_names)
    variants = out.get("anyOf")
    if isinstance(variants, list):
        non_null = [v for v in variants if not (isinstance(v, dict) and v.get("type") == "null")]
        if non_null and len(non_null) > 1:
            # A union of only scalar types: widen to "string" (see docstring).
            scalar_only = all(
                isinstance(v, dict) and v.get("type") in _SCALAR_TYPES and len(v) == 1
                for v in non_null
            )
            if scalar_only:
                merged = {"type": "string"}
                for key, value in out.items():
                    if key != "anyOf":
                        merged[key] = value
                if merged.get("default", 1) is None:
                    merged.pop("default", None)
                return merged
        if len(non_null) == 1 and len(non_null) != len(variants):
            merged = dict(non_null[0])
            for key, value in out.items():
                if key != "anyOf" and key not in merged:
                    merged[key] = value
            if merged.get("default", 1) is None:
                merged.pop("default", None)
            return merged
    if isinstance(variants, list) and len(variants) == 1:
        merged = dict(variants[0])
        for key, value in out.items():
            if key != "anyOf" and key not in merged:
                merged[key] = value
        return merged
    return out


def sanitize_tool_schemas(server) -> int:
    """Rewrite every registered tool's parameter schema in place.

    Returns the number of schemas that were rewritten, or -1 when the MCP SDK
    does not expose the tools in a mutable form (in which case the caller keeps
    the verbatim schemas, exactly as v1.0 served them).
    """
    manager = getattr(server, "_tool_manager", None)
    if manager is None:
        return -1
    registry = getattr(manager, "_tools", None)
    if not isinstance(registry, dict):
        return -1
    changed = 0
    for name, tool in list(registry.items()):
        schema = getattr(tool, "parameters", None)
        if not isinstance(schema, dict):
            continue
        rewritten = _collapse_nullable(schema)
        if rewritten != schema:
            try:
                tool.parameters = rewritten
                changed += 1
            except Exception as exc:  # pragma: no cover - defensive
                _log(f"cannot rewrite the schema of {name!r}: {exc!r}")
    return changed


class Launcher:
    """Own one McpToolService and expose it over stdio with safe dispatching."""

    def __init__(self) -> None:
        from cnki_mcp.server.tool_registry import McpToolService

        self.service = McpToolService()

    @staticmethod
    async def _offload(func, *args, **kwargs):
        return await asyncio.to_thread(func, *args, **kwargs)

    def _wrappers(self) -> dict:
        """Async, offloaded equivalents of every upstream stdio tool."""
        s = self.service
        off = self._offload

        async def easy_search(keywords: str, limit: int = 10, sort_by: str | None = None):
            return await off(s.easy_search, keywords, limit=limit, sort_by=sort_by)

        async def advanced_search(
            title: str | None = None,
            author: str | None = None,
            year_from: int | None = None,
            year_to: int | None = None,
            journal: str | None = None,
            keywords: str | None = None,
            subject: str | None = None,
            abstract: str | None = None,
            institution: str | None = None,
            fund: str | None = None,
            doi: str | None = None,
            document_type: str | None = None,
            source_types: list[str] | None = None,
            sort_by: str | None = None,
            limit: int = 10,
        ):
            return await off(
                s.advanced_search,
                title=title, author=author, year_from=year_from, year_to=year_to,
                journal=journal, keywords=keywords, subject=subject, abstract=abstract,
                institution=institution, fund=fund, doi=doi,
                document_type=document_type, source_types=source_types,
                sort_by=sort_by, limit=limit,
            )

        async def get_info_from_url(url: str):
            return await off(s.get_info_from_url, url)

        async def get_info_by_detail(
            title: str,
            authors: list[str] | None = None,
            year: int | None = None,
            year_from: int | None = None,
            year_to: int | None = None,
            journal: str | None = None,
            keywords: str | None = None,
            subject: str | None = None,
            abstract: str | None = None,
            institution: str | None = None,
            fund: str | None = None,
            doi: str | None = None,
            document_type: str | None = None,
            source_types: list[str] | None = None,
            sort_by: str | None = None,
            limit: int = 10,
        ):
            return await off(
                s.get_info_by_detail,
                title=title, authors=authors, year=year, year_from=year_from,
                year_to=year_to, journal=journal, keywords=keywords, subject=subject,
                abstract=abstract, institution=institution, fund=fund, doi=doi,
                document_type=document_type, source_types=source_types,
                sort_by=sort_by, limit=limit,
            )

        async def list_journal(issn: str, year: int, vol: int | str):
            return await off(s.list_journal, issn, year, vol)

        async def search_issn(journal: str):
            return await off(s.search_issn, journal)

        async def login(profile: str | None = None):
            return await off(s.login, profile)

        async def logout():
            return await off(s.logout)

        built = {
            "easy-search": easy_search,
            "advanced-search": advanced_search,
            "get-info-from-url": get_info_from_url,
            "get-info-by-detail": get_info_by_detail,
            "list-journal": list_journal,
            "search-issn": search_issn,
            "login": login,
            "logout": logout,
        }
        for name, wrapper in built.items():
            origin = getattr(s, name.replace("-", "_"), None)
            if origin is not None and origin.__doc__:
                # Reuse the upstream docstring verbatim so tool text never drifts.
                wrapper.__doc__ = origin.__doc__
        return built

    def build(self, sanitize: bool = False):
        """Create the FastMCP server with async wrappers around the sync service."""
        from mcp.server.fastmcp import FastMCP

        self._check_parity()
        server = FastMCP(name=SERVER_NAME, instructions=INSTRUCTIONS)
        for name, wrapper in self._wrappers().items():
            server.tool(name=name)(wrapper)
        server.resource(
            "profile://list",
            name="list-profiles",
            description="List profiles that can be passed to the login tool.",
        )(self.service.list_profiles)
        if sanitize:
            changed = sanitize_tool_schemas(server)
            if changed < 0:
                _log("schema sanitisation requested but the MCP SDK exposes no mutable tool "
                     "registry; keeping the verbatim upstream schemas")
            else:
                _log(f"sanitised {changed} tool schema(s) for provider compatibility")
        _log(f"ready with {len(EXPECTED_TOOLS)} tools: {', '.join(EXPECTED_TOOLS)}")
        return server

    def _check_parity(self) -> None:
        """Warn (never fail) when upstream's stdio tool set has moved on."""
        try:
            from cnki_mcp.server.cnki_mcp_server import create_mcp_server

            upstream = create_mcp_server("stdio", service=self.service)
            names = tuple(t.name for t in upstream._tool_manager.list_tools())
        except Exception as exc:  # pragma: no cover - defensive
            _log(f"parity check skipped: {exc!r}")
            return
        if set(names) != set(EXPECTED_TOOLS):
            _log(f"WARNING upstream stdio tools changed: upstream={sorted(names)} "
                 f"launcher={sorted(EXPECTED_TOOLS)}")


def runtime_config() -> dict:
    """Read `<bundle>/portable.runtime.json`, written by the installer. Optional."""
    try:
        from pathlib import Path

        path = Path(__file__).resolve().parent.parent / "portable.runtime.json"
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def sanitize_requested(argv: list[str]) -> bool:
    """Whether to sanitize the model-facing schemas. Defaults to True.

    Upstream's Pydantic models emit ``anyOf: [X, {"type": "null"}]`` for every
    optional parameter, and DSH forwards that to the provider verbatim. That shape
    is a known ``INVALID_REQUEST`` trigger (it is what broke the abandoned v1.1
    runtime plugin), so the safe form is served by default. The rewrite is
    lossless for tool semantics: FastMCP still validates against the original
    Python signature. Pass ``--no-sanitize-schema``, or set
    ``"sanitizeSchema": false`` in ``portable.runtime.json``, to serve the
    verbatim upstream schemas instead.
    """
    if "--sanitize-schema" in argv:
        return True
    if "--no-sanitize-schema" in argv:
        return False
    configured = runtime_config().get("sanitizeSchema")
    if isinstance(configured, bool):
        return configured
    return True


def tools_payload(sanitize: bool = False) -> list[dict]:
    """Return the MCP tool list exactly as `tools/list` would serve it."""
    launcher = Launcher()
    server = launcher.build(sanitize=sanitize)
    payload = []
    for tool in server._tool_manager.list_tools():
        schema = getattr(tool, "parameters", None)
        if schema is None:
            schema = getattr(tool, "inputSchema", None)
        payload.append({
            "name": tool.name,
            "description": tool.description or "",
            "inputSchema": schema,
        })
    return payload


def cmd_tools_json(argv: list[str]) -> int:
    """`--tools-json [path]`: dump the MCP tool list without starting a browser."""
    payload = tools_payload(sanitize=sanitize_requested(argv))
    text = json.dumps({"tools": payload}, ensure_ascii=False, indent=2)
    target = None
    if "--tools-json" in argv:
        index = argv.index("--tools-json")
        if index + 1 < len(argv) and not argv[index + 1].startswith("-"):
            target = argv[index + 1]
    if target:
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
        _log(f"wrote {len(payload)} tool schemas to {target}")
        return 0
    print(text)
    return 0


def _dist_version(name: str) -> str:
    """Installed distribution version, or 'absent' when it is not importable."""
    try:
        from importlib.metadata import PackageNotFoundError, version

        return version(name)
    except PackageNotFoundError:
        return "absent"
    except Exception as exc:  # pragma: no cover - defensive
        return f"error: {exc!r}"


def cmd_check() -> int:
    """`--check`: print a JSON environment report and exit."""
    report: dict = {"launcherVersion": __version__, "python": sys.version.split()[0],
                    "executable": sys.executable, "prefix": sys.prefix,
                    "ok": True, "problems": []}
    try:
        import mcp  # noqa: F401

        report["mcp"] = _dist_version("mcp")
    except Exception as exc:
        report["ok"] = False
        report["problems"].append(f"cannot import mcp: {exc!r}")
    try:
        import cnki_mcp  # noqa: F401

        report["cnkiMcp"] = _dist_version("cnki-mcp")
        report["cnkiMcpPath"] = getattr(cnki_mcp, "__file__", None)
    except Exception as exc:
        report["ok"] = False
        report["problems"].append(f"cannot import cnki_mcp: {exc!r}")
    try:
        import playwright  # noqa: F401

        report["playwright"] = _dist_version("playwright")
    except Exception as exc:
        report["ok"] = False
        report["problems"].append(f"cannot import playwright: {exc!r}")
    try:
        from cnki_mcp.core import config as cnki_config

        profiles = cnki_config.list_profiles()
        report["cnkiProfileBase"] = str(cnki_config.BASE_DIR)
        report["cnkiProfiles"] = profiles
        report["cnkiDefaultProfile"] = cnki_config.get_default_profile()
        if not profiles:
            report["problems"].append(
                "no CNKI profile exists yet; the login tool will create one on first use")
    except Exception as exc:
        report["ok"] = False
        report["problems"].append(f"cannot read cnki-mcp configuration: {exc!r}")
    try:
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            report["chromium"] = p.chromium.executable_path
    except Exception as exc:
        report["problems"].append(f"chromium not usable: {exc!r}")
        report["ok"] = False
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["ok"] else 1


def selfcheck() -> int:
    """Report whether the upstream stdio transport has been fixed yet."""
    import inspect

    from mcp.server.fastmcp.utilities import func_metadata as fm
    from cnki_mcp.server.tool_registry import McpToolService

    src = inspect.getsource(fm.FuncMetadata.call_fn_with_arg_validation).replace("\r\n", "\n")
    inline_sync = "else:\n            return fn(**arguments_parsed_dict)" in src
    login_is_async = inspect.iscoroutinefunction(McpToolService.login)
    print(f"mcp SDK runs sync tools inline on the loop : {inline_sync}")
    print(f"cnki_mcp.McpToolService.login is async      : {login_is_async}")
    if inline_sync and not login_is_async:
        print("VERDICT: upstream stdio transport is still broken; keep this launcher.")
        return 1
    print("VERDICT: upstream may be fixed; consider dropping this launcher.")
    return 0


def main() -> int:
    argv = sys.argv[1:]
    if "--version" in argv:
        print(__version__)
        return 0
    if "--check" in argv:
        return cmd_check()
    if "--tools-json" in argv:
        return cmd_tools_json(argv)
    if "--selfcheck" in argv:
        try:
            return selfcheck()
        except Exception as exc:
            _log(f"selfcheck failed: {exc!r}")
            return 3
    require_profile = "--require-profile" in argv
    try:
        from cnki_mcp.core import auth

        profile = auth.require_profile()
        _log(f"using CNKI profile {profile!r}")
    except Exception as exc:
        if require_profile:
            _log(f"no usable CNKI profile: {exc}")
            return 2
        # Portable behaviour: keep serving. `login` creates and authenticates a
        # profile on demand, so a fresh machine needs no pre-seeded profile.
        _log(f"no CNKI profile yet ({exc}); starting anyway — call the login tool to create one")
    try:
        Launcher().build(sanitize=sanitize_requested(argv)).run(transport="stdio")
    except Exception as exc:  # pragma: no cover - startup failure
        _log(f"failed to start: {exc!r}")
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
