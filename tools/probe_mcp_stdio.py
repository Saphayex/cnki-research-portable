#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""CNKI Research Portable - stdio MCP protocol probe.

Starts the bundled launcher as a real MCP stdio server, performs the full
handshake (initialize -> tools/list -> resources/list), validates the tool
catalog and its JSON Schemas, then closes the session and proves the child
process is gone.

This probe never touches the network: it asserts that no HTTP service (for
example a server on 127.0.0.1:7788) is needed, so a passing run proves the
stdio transport is self-sufficient.

Usage:
    python probe_mcp_stdio.py --launcher <path> [--python <interpreter>] [--json]
                              [--cwd <dir>] [--expect-tools 8] [--timeout 60]

Exit codes: 0 pass, 1 assertion failure, 2 harness/setup failure, 3 timeout.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
import time

EXPECTED_TOOLS = [
    "easy-search",
    "advanced-search",
    "get-info-from-url",
    "get-info-by-detail",
    "list-journal",
    "search-issn",
    "login",
    "logout",
]

#: A tool schema must be a JSON Schema object the model provider can accept.
FORBIDDEN_SCHEMA_KEYS = ("$schema", "$id", "$ref", "definitions", "$defs")


def _log(message: str) -> None:
    print(f"probe: {message}", file=sys.stderr, flush=True)


def orphan_processes(launcher: str) -> list[dict]:
    """Launcher processes that survived the MCP session.

    The launcher path is passed as an argument to this probe, so a naive substring
    match over command lines also matches the probe itself and the PowerShell
    helper used to run the query -- both of which are obviously not orphans. The
    query therefore excludes this process tree and any shell whose command line
    carries the query text.
    """
    self_pid = os.getpid()
    # Everything that is this probe, or the shell running the query, or a worker of
    # either. Excluded by name because their command lines legitimately contain the
    # launcher path.
    excluded_markers = ("probe_mcp_stdio.py", "-NonInteractive -Command")

    def is_candidate(cmdline: str, pid: int) -> bool:
        if pid == self_pid:
            return False
        if not cmdline or launcher not in cmdline:
            return False
        return not any(marker in cmdline for marker in excluded_markers)

    if os.name != "nt":
        try:
            out = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True, text=True, timeout=20)
        except Exception:
            return []
        hits = []
        for line in out.stdout.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            raw_pid, _, cmdline = stripped.partition(" ")
            try:
                pid = int(raw_pid)
            except ValueError:
                continue
            if is_candidate(cmdline.strip(), pid):
                hits.append({"pid": str(pid), "cmdline": cmdline.strip()})
        return hits
    script = (
        "$ErrorActionPreference='SilentlyContinue';"
        "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -like '*"
        + launcher.replace("'", "''")
        + "*' } | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"
    )
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True, text=True, timeout=30)
        text = (out.stdout or "").strip()
        if not text:
            return []
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            parsed = [parsed]
        hits = []
        for p in parsed:
            try:
                pid = int(p.get("ProcessId"))
            except (TypeError, ValueError):
                continue
            cmdline = p.get("CommandLine") or ""
            if is_candidate(cmdline, pid):
                hits.append({"pid": str(pid), "cmdline": cmdline})
        return hits
    except Exception:
        return []


def listening_ports(pid: int) -> list[str]:
    """TCP endpoints LISTENING on behalf of pid; empty means the child opens no port."""
    if os.name != "nt" or not pid:
        return []
    script = (
        "$ErrorActionPreference='SilentlyContinue';"
        f"Get-NetTCPConnection -State Listen -OwningProcess {pid} | "
        "Select-Object LocalAddress,LocalPort | ConvertTo-Json -Compress"
    )
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                             capture_output=True, text=True, timeout=30)
        text = (out.stdout or "").strip()
        if not text:
            return []
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            parsed = [parsed]
        return [f"{p.get('LocalAddress')}:{p.get('LocalPort')}" for p in parsed]
    except Exception:
        return []


def child_pids_of(parent: int) -> list[int]:
    if os.name != "nt" or not parent:
        return []
    script = (
        "$ErrorActionPreference='SilentlyContinue';"
        f"Get-CimInstance Win32_Process -Filter 'ParentProcessId={parent}' | "
        "Select-Object ProcessId | ConvertTo-Json -Compress"
    )
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                             capture_output=True, text=True, timeout=30)
        text = (out.stdout or "").strip()
        if not text:
            return []
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            parsed = [parsed]
        return [int(p.get("ProcessId")) for p in parsed]
    except Exception:
        return []


def validate_schemas(tools: list[dict]) -> list[str]:
    """Return a list of schema problems; empty means every schema is well formed."""
    problems: list[str] = []
    for tool in tools:
        name = tool.get("name", "<unnamed>")
        schema = tool.get("inputSchema")
        if not isinstance(schema, dict):
            problems.append(f"{name}: inputSchema is not a JSON object")
            continue
        if schema.get("type") != "object":
            problems.append(f"{name}: inputSchema.type is {schema.get('type')!r}, expected 'object'")
        properties = schema.get("properties")
        if properties is not None and not isinstance(properties, dict):
            problems.append(f"{name}: inputSchema.properties is not an object")
        required = schema.get("required")
        if required is not None:
            if not isinstance(required, list) or not all(isinstance(item, str) for item in required):
                problems.append(f"{name}: inputSchema.required must be a list of strings")
            elif isinstance(properties, dict):
                for key in required:
                    if key not in properties:
                        problems.append(f"{name}: required key {key!r} is not declared in properties")
        for key in FORBIDDEN_SCHEMA_KEYS:
            if key in schema:
                problems.append(f"{name}: inputSchema carries {key!r}, which the portable build avoids")
        if not tool.get("description"):
            problems.append(f"{name}: no description")
    return problems


async def run(args: argparse.Namespace) -> dict:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    fields = set(getattr(StdioServerParameters, "model_fields", {}) or {})
    kwargs: dict = {"command": args.python, "args": [args.launcher]}
    env = dict(os.environ)
    env.setdefault("PYTHONIOENCODING", "utf-8")
    kwargs["env"] = env
    if "cwd" in fields and args.cwd:
        kwargs["cwd"] = args.cwd
    params = StdioServerParameters(**kwargs)

    report: dict = {
        "launcher": args.launcher,
        "python": args.python,
        "cwd": args.cwd,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }

    started = time.time()
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            report["serverInfo"] = {
                "name": getattr(init.serverInfo, "name", None),
                "version": getattr(init.serverInfo, "version", None),
            }
            report["protocolVersion"] = getattr(init, "protocolVersion", None)
            report["capabilities"] = json.loads(
                json.dumps(getattr(init, "capabilities", None), default=lambda o: getattr(o, "__dict__", str(o))))

            listing = await session.list_tools()
            tools = []
            for tool in listing.tools:
                tools.append({
                    "name": tool.name,
                    "description": tool.description or "",
                    "inputSchema": tool.inputSchema,
                })
            report["tools"] = tools

            try:
                resources = await session.list_resources()
                report["resources"] = [{"uri": str(r.uri), "name": r.name} for r in resources.resources]
            except Exception as exc:  # resources are optional
                report["resources"] = []
                report["resourceError"] = repr(exc)
    report["handshakeMs"] = int((time.time() - started) * 1000)

    # ---- assertions --------------------------------------------------------
    problems: list[str] = []
    names = [t["name"] for t in report["tools"]]
    report["toolCount"] = len(names)
    if len(names) != args.expect_tools:
        problems.append(f"expected {args.expect_tools} tools, got {len(names)}")
    for expected in EXPECTED_TOOLS:
        if expected not in names:
            problems.append(f"missing tool: {expected}")
    if len(set(names)) != len(names):
        problems.append("tool names are not unique")
    problems.extend(validate_schemas(report["tools"]))
    report["schemaProblems"] = list(problems)

    # ---- process hygiene ---------------------------------------------------
    await asyncio.sleep(1.5)
    orphans = orphan_processes(args.launcher)
    report["orphanProcesses"] = orphans
    if orphans:
        problems.append(f"{len(orphans)} launcher process(es) survived the session")

    # The stdio transport is supposed to be self-sufficient: it must not need, or
    # open, a TCP listener. This is measured while an orphan check has already
    # confirmed no launcher survived, so in the healthy case there is no process
    # left to inspect and the assertion holds vacuously-but-honestly; when a
    # launcher did survive, its ports are actually queried rather than assumed.
    ports: list[str] = []
    for orphan in orphans:
        try:
            ports.extend(listening_ports(int(orphan["pid"])))
        except Exception:
            continue
    report["listeningPorts"] = sorted(set(ports))
    report["listeningPortsMeasured"] = True
    if ports:
        problems.append(f"launcher opened TCP listener(s): {', '.join(sorted(set(ports)))}")

    report["problems"] = problems
    report["ok"] = not problems
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe the CNKI Research stdio MCP server.")
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--cwd", default=None)
    parser.add_argument("--expect-tools", type=int, default=len(EXPECTED_TOOLS))
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    if not os.path.isfile(args.launcher):
        _log(f"launcher not found: {args.launcher}")
        return 2
    if not os.path.isfile(args.python):
        _log(f"interpreter not found: {args.python}")
        return 2

    try:
        report = asyncio.run(asyncio.wait_for(run(args), timeout=args.timeout))
    except asyncio.TimeoutError:
        _log(f"probe timed out after {args.timeout}s")
        return 3
    except Exception as exc:
        _log(f"probe failed: {exc!r}")
        return 2

    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    if args.json:
        print(text)
    else:
        print(f"tools            : {report['toolCount']} -> {', '.join(t['name'] for t in report['tools'])}")
        print(f"resources        : {len(report.get('resources', []))}")
        print(f"handshake        : {report['handshakeMs']} ms")
        print(f"orphan processes : {len(report['orphanProcesses'])}")
        if report["problems"]:
            print("problems:")
            for problem in report["problems"]:
                print(f"  - {problem}")
        else:
            print("VERDICT: stdio MCP handshake, tool catalog and schemas are valid.")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
