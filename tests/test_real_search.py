#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""CNKI Research Portable - real CNKI retrieval acceptance (opt-in, attended).

Runs the acceptance sequence from Phase P4-D against a real, legally authorised
CNKI session:

    1. start the bundled stdio MCP server;
    2. call `login` (opens a *visible* Chromium window; if the saved session is
       still valid upstream reports "already logged in" with no interaction);
    3. call `easy-search` with a deliberately small `limit`;
    4. verify that real, non-empty records came back and report their fields
       verbatim (nothing is invented, nothing is rewritten);
    5. close the session and prove the browser processes are gone.

DELIBERATE OMISSION: this script never calls `logout`. Upstream
`cnki_mcp.core.auth.logout()` deletes the profile's `cookies.json` and
`storage_state.json`, and the distribution must not touch a user's saved
institutional login. Closing the MCP session terminates the child process and
its Playwright browser, which is what this test measures instead.

Usage:
    python test_real_search.py --launcher <path> [--python <exe>]
                               [--keywords "生态文明 案例"] [--limit 3]
                               [--login-timeout 180] [--out report.json]

Exit codes: 0 verified, 1 failure, 2 setup error, 3 authentication required
           (manual acceptance needed - reported as NOT TESTED, never as PASS).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import time

BROWSER_PROCESS_HINTS = ("chrome.exe", "chromium", "headless_shell")


def browser_processes() -> list[dict]:
    """Playwright browser processes currently running (Windows)."""
    if os.name != "nt":
        return []
    script = (
        "$ErrorActionPreference='SilentlyContinue';"
        "Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'chrome|chromium|headless_shell' "
        "} | Select-Object ProcessId,Name | ConvertTo-Json -Compress"
    )
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                             capture_output=True, text=True, timeout=40)
        text = (out.stdout or "").strip()
        if not text:
            return []
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            parsed = [parsed]
        return [{"pid": int(p.get("ProcessId")), "name": p.get("Name")} for p in parsed]
    except Exception:
        return []


def extract_text(result) -> str:
    parts = []
    for item in getattr(result, "content", None) or []:
        text = getattr(item, "text", None)
        if text:
            parts.append(text)
    return "\n".join(parts)


def parse_records(text: str):
    """Best-effort extraction of the record list from a tool result."""
    if not text:
        return None
    try:
        value = json.loads(text)
    except Exception:
        match = re.search(r"[\[{].*[\]}]", text, re.S)
        if not match:
            return None
        try:
            value = json.loads(match.group(0))
        except Exception:
            return None
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("results", "records", "data", "items", "papers"):
            if isinstance(value.get(key), list):
                return value[key]
    return None


async def run(args: argparse.Namespace) -> dict:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    report: dict = {
        "launcher": args.launcher,
        "python": args.python,
        "keywords": args.keywords,
        "limit": args.limit,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "logoutCalled": False,
        "note": "logout is deliberately not called: it would delete the user's saved CNKI login state",
    }

    baseline = browser_processes()
    report["browserProcessesBefore"] = len(baseline)

    fields = set(getattr(StdioServerParameters, "model_fields", {}) or {})
    kwargs: dict = {"command": args.python, "args": [args.launcher]}
    env = dict(os.environ)
    env.setdefault("PYTHONIOENCODING", "utf-8")
    kwargs["env"] = env
    if "cwd" in fields:
        kwargs["cwd"] = os.path.dirname(os.path.dirname(os.path.abspath(args.launcher)))
    params = StdioServerParameters(**kwargs)

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listing = await session.list_tools()
            report["toolCount"] = len(listing.tools)

            login_started = time.time()
            try:
                login = await asyncio.wait_for(
                    session.call_tool("login", {}), timeout=args.login_timeout)
            except asyncio.TimeoutError:
                report["login"] = {"ok": False, "reason": f"login did not settle within {args.login_timeout}s"}
                report["error"] = "login timed out"
                report["authRequired"] = True
                return report
            report["loginSeconds"] = round(time.time() - login_started, 1)
            login_text = extract_text(login)
            report["login"] = {"isError": bool(getattr(login, "isError", False)), "text": login_text[:2000]}
            if getattr(login, "isError", False):
                report["error"] = f"login failed: {login_text[:300]}"
                report["authRequired"] = True
                return report
            try:
                login_value = json.loads(login_text)
            except Exception:
                login_value = {}
            report["loginProfile"] = login_value.get("profile")
            if login_value.get("success") is not True:
                report["error"] = f"login did not report success: {login_text[:300]}"
                report["authRequired"] = True
                return report

            report["browserProcessesDuringLogin"] = len(browser_processes())

            search_started = time.time()
            search = await asyncio.wait_for(
                session.call_tool("easy-search", {"keywords": args.keywords, "limit": args.limit}),
                timeout=args.search_timeout)
            report["searchSeconds"] = round(time.time() - search_started, 1)
            search_text = extract_text(search)
            report["searchIsError"] = bool(getattr(search, "isError", False))
            report["searchRawHead"] = search_text[:4000]
            if report["searchIsError"]:
                report["error"] = f"easy-search failed: {search_text[:300]}"
                return report
            records = parse_records(search_text)
            report["resultCount"] = len(records) if records is not None else None
            if records:
                report["records"] = [
                    {k: r.get(k) for k in ("title", "authors", "journal", "date", "url") if isinstance(r, dict) and k in r}
                    for r in records[: args.limit]
                ]
            report["ok"] = bool(records) and len(records) > 0
            if not report["ok"]:
                report["error"] = "easy-search returned no parsable record"
    # session closed: the stdio child is terminated here

    waited = 0.0
    while waited < args.release_timeout:
        remaining = browser_processes()
        if len(remaining) <= len(baseline):
            break
        await asyncio.sleep(1.0)
        waited += 1.0
    remaining = browser_processes()
    report["browserProcessesAfter"] = len(remaining)
    report["browserReleaseSeconds"] = round(waited, 1)
    report["browserReleased"] = len(remaining) <= len(baseline)
    if not report["browserReleased"]:
        report["ok"] = False
        report["error"] = (f"{len(remaining)} browser process(es) still running "
                           f"{args.release_timeout}s after the MCP session closed")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Real CNKI retrieval acceptance test.")
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--keywords", default="生态文明 案例")
    parser.add_argument("--limit", type=int, default=3)
    parser.add_argument("--login-timeout", type=float, default=180.0)
    parser.add_argument("--search-timeout", type=float, default=180.0)
    parser.add_argument("--release-timeout", type=float, default=40.0)
    parser.add_argument("--out", default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if not os.path.isfile(args.launcher):
        print(f"launcher not found: {args.launcher}", file=sys.stderr)
        return 2

    try:
        report = asyncio.run(run(args))
    except Exception as exc:
        report = {"ok": False, "error": f"{exc!r}"}

    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    if args.json:
        print(text)
    else:
        if report.get("ok"):
            print(f"login profile : {report.get('loginProfile')}")
            print(f"records       : {report.get('resultCount')}")
            for record in report.get("records", []) or []:
                print(f"  - {record.get('title')} | {record.get('journal')} | {record.get('date')}")
                print(f"    {record.get('url')}")
            print(f"browser       : {report.get('browserProcessesBefore')} -> "
                  f"{report.get('browserProcessesAfter')} in {report.get('browserReleaseSeconds')}s")
            print("VERDICT: a real CNKI search returned usable records.")
        else:
            print(f"real search not verified: {report.get('error')}")
            if report.get("authRequired"):
                print("This needs a human to complete institutional authentication in the "
                      "browser window; report it as NOT TESTED rather than PASS.")
    if report.get("ok"):
        return 0
    if report.get("authRequired"):
        return 3
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
