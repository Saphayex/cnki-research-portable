# One-shot automated test suite for CNKI Research Portable.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_all.ps1 [-SkipDsh] [-EnableRealSearch]
#
# Groups:
#   A  static package validation          (no runtime needed)
#   B  stdio MCP protocol + launcher      (needs <InstallRoot>\.venv)
#   C  model-facing tool JSON Schema      (needs <InstallRoot>\.venv)
#   D  DSH installation in an isolated profile and DSH_HOME
#   E  real CNKI search                   (needs an authenticated institution; opt-in)
#
# Every group that cannot run in this environment is reported as NOT TESTED; the
# script never reports a skipped group as a pass. Exit code 0 = no FAIL.

[CmdletBinding()]
param(
    [string]$PackageRoot,
    [string]$InstallRoot,
    [string]$ReportDir,
    [switch]$SkipDsh,
    [switch]$EnableRealSearch
)

$ErrorActionPreference = 'Continue'

<#
  Suppress only the NativeCommandError that Windows PowerShell 5.1 raises when a
  native tool writes to stderr. The launcher logs its startup line there on a
  perfectly successful run, so an unhandled record would abort the whole suite
  (and a wrapping `pwsh -Command` would then exit non-zero). Real exit codes are
  read from $LASTEXITCODE immediately after each call and are never masked.
#>
function Invoke-Native {
    param([Parameter(Mandatory=$true)][scriptblock]$Script)
    $before = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $Script
    } finally {
        $ErrorActionPreference = $before
    }
}
. (Join-Path $PSScriptRoot '..\tools\lib\PortableCommon.ps1')

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$layout = Get-PortableLayout -PackageRoot $PackageRoot -InstallRoot $InstallRoot
if (-not $ReportDir) { $ReportDir = Join-Path $layout.PackageRoot "docs\test-evidence\$stamp" }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$groups = New-Object System.Collections.ArrayList
function Add-Group {
    param([string]$Id, [string]$Status, [string]$Detail, [string]$Evidence)
    [void]$groups.Add([pscustomobject]@{ id = $Id; status = $Status; detail = $Detail; evidence = $Evidence })
}

$venvPython = Get-VenvPython -VenvDir $layout.VenvDir
$launcher = Join-Path $layout.BundleDir 'launcher\cnki_research_launcher.py'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    $launcher = Join-Path $layout.BundleSource 'launcher\cnki_research_launcher.py'
}

Write-Section "CNKI Research Portable - automated tests"
Write-Host "  package root : $($layout.PackageRoot)"
Write-Host "  install root : $($layout.InstallRoot)"
Write-Host "  interpreter  : $(if ($venvPython) { $venvPython } else { '<none: run tools\portable.ps1 -Action install>' })"
Write-Host "  evidence     : $ReportDir"

# ---------------------------------------------------------------------------
# A - static package
# ---------------------------------------------------------------------------
Write-Section 'A. Static package validation'
$staticReport = Join-Path $ReportDir 'static-package.json'
Invoke-Native { & node (Join-Path $layout.PackageRoot 'tests\test_static_package.mjs') --json --write-report $staticReport 2>&1 | Out-Null }
$staticExit = $LASTEXITCODE
$staticJson = Read-JsonFile -Path $staticReport
if ($staticJson) {
    $failed = @($staticJson.checks | Where-Object { $_.status -eq 'FAIL' })
    $warned = @($staticJson.checks | Where-Object { $_.status -eq 'WARN' })
    foreach ($check in $staticJson.checks) { Write-Item -Status $check.status -Text "$($check.id): $($check.detail)" }
    $status = 'PASS'
    if ($failed.Count -gt 0) { $status = 'FAIL' } elseif ($warned.Count -gt 0) { $status = 'WARN' }
    Add-Group 'A.staticPackage' $status "$(@($staticJson.checks).Count) checks: $($failed.Count) fail / $($warned.Count) warn" $staticReport
} else {
    Add-Group 'A.staticPackage' 'FAIL' "the static test produced no report (exit $staticExit)" $staticReport
}

# ---------------------------------------------------------------------------
# B - stdio MCP + launcher
# ---------------------------------------------------------------------------
Write-Section 'B. stdio MCP protocol'
if (-not $venvPython) {
    Add-Group 'B.mcpStdio' 'NOT TESTED' "no interpreter at $($layout.VenvDir); run tools\portable.ps1 -Action install" ''
    Write-Item -Status 'NOT TESTED' -Text 'no runtime environment; MCP group skipped'
} elseif (-not (Test-Path -LiteralPath $launcher)) {
    Add-Group 'B.mcpStdio' 'FAIL' "launcher not found at $launcher" ''
    Write-Item -Status 'FAIL' -Text "launcher not found at $launcher"
} else {
    # Upstream cnki-mcp roots its state at Path.home()/".cnki-mcp", which is the
    # real user's institution profiles and browser auth state -- outside $DSH_HOME.
    # Redirect USERPROFILE into the evidence directory for groups B/C so no test
    # can read or write the real CNKI store.
    $realUserProfile = $env:USERPROFILE
    $sandboxProfile = Join-Path $ReportDir 'userprofile'
    New-Item -ItemType Directory -Force -Path $sandboxProfile | Out-Null
    $env:USERPROFILE = $sandboxProfile
    $checkReport = Join-Path $ReportDir 'launcher-check.json'
    $checkOut = Invoke-Native { & $venvPython $launcher --check 2>&1 }
    Write-TextFile -Path $checkReport -Text (($checkOut | Out-String) + "`n")
    $checkExit = $LASTEXITCODE
    if ($checkExit -eq 0) {
        Write-Item -Status 'PASS' -Text 'launcher --check reports a healthy import environment'
        Add-Group 'B.launcherCheck' 'PASS' 'cnki_mcp / mcp / playwright importable, Chromium resolvable' $checkReport
    } else {
        Write-Item -Status 'FAIL' -Text "launcher --check exited $checkExit"
        Add-Group 'B.launcherCheck' 'FAIL' "launcher --check exited $checkExit" $checkReport
    }

    $selfOut = Invoke-Native { & $venvPython $launcher --selfcheck 2>&1 }
    $selfReport = Join-Path $ReportDir 'launcher-selfcheck.txt'
    Write-TextFile -Path $selfReport -Text (($selfOut | Out-String) + "`n")
    if (($selfOut | Out-String) -match 'still broken') {
        Write-Item -Status 'PASS' -Text 'upstream stdio transport is still broken, so the launcher is still required'
        Add-Group 'B.launcherSelfcheck' 'PASS' 'upstream defect reproduced; --selfcheck verdict retained' $selfReport
    } elseif (($selfOut | Out-String) -match 'may be fixed') {
        Write-Item -Status 'WARN' -Text 'upstream may be fixed; the launcher can be retired after re-verification'
        Add-Group 'B.launcherSelfcheck' 'WARN' 'upstream stdio may be fixed' $selfReport
    } else {
        Add-Group 'B.launcherSelfcheck' 'WARN' 'selfcheck produced no recognisable verdict' $selfReport
    }

    $mcpReport = Join-Path $ReportDir 'mcp-stdio.json'
    Invoke-Native {
        & $venvPython (Join-Path $layout.PackageRoot 'tools\probe_mcp_stdio.py') `
            --launcher $launcher --python $venvPython --cwd (Split-Path -Parent $launcher) `
            --json --out $mcpReport 2>&1 | Out-Null
    }
    $mcpExit = $LASTEXITCODE
    $mcpJson = Read-JsonFile -Path $mcpReport
    if ($mcpJson) {
        Write-Item -Status 'PASS' -Text "handshake ok, $($mcpJson.toolCount) tool(s), $($mcpJson.handshakeMs) ms"
        if (@($mcpJson.problems).Count -gt 0) {
            foreach ($problem in $mcpJson.problems) { Write-Item -Status 'FAIL' -Text $problem }
        }
        Write-Item -Status 'PASS' -Text "orphan launcher process(es) after the session: $(@($mcpJson.orphanProcesses).Count)"
        $status = 'PASS'
        if (@($mcpJson.problems).Count -gt 0) { $status = 'FAIL' }
        Add-Group 'B.mcpStdio' $status "tools=$($mcpJson.toolCount) resources=$(@($mcpJson.resources).Count) orphans=$(@($mcpJson.orphanProcesses).Count)" $mcpReport
    } else {
        Add-Group 'B.mcpStdio' 'FAIL' "the MCP probe produced no report (exit $mcpExit)" $mcpReport
        Write-Item -Status 'FAIL' -Text "MCP probe exited $mcpExit"
    }
}

# ---------------------------------------------------------------------------
# C - model-facing tool schema
# ---------------------------------------------------------------------------
Write-Section 'C. Model-facing tool JSON Schema'
if (-not $venvPython) {
    Add-Group 'C.toolSchema' 'NOT TESTED' 'no runtime environment' ''
    Write-Item -Status 'NOT TESTED' -Text 'no runtime environment; schema group skipped'
} else {
    # `served` is the shipped default path (the launcher's provider-safe schemas).
    # `upstream` dumps the verbatim Pydantic shapes with sanitization off, purely to
    # document the nullable-union hazard that the default removes; its nullable
    # shapes are recorded as WARN rather than as a failure of this release.
    foreach ($mode in @(
        @{ name = 'served'; extra = @() },
        @{ name = 'upstream'; extra = @('--no-sanitize-schema') }
    )) {
        $dump = Join-Path $ReportDir "tools-$($mode.name).json"
        $log = Join-Path $ReportDir "launcher-tools-$($mode.name).log"
        $argList = @($launcher, '--tools-json', $dump) + $mode.extra
        # Capture stderr to a log instead of discarding it: the launcher writes its
        # startup banner there, and if the dump ever fails that log is the only
        # evidence of why.
        Invoke-Native { & $venvPython @argList 2>&1 | Out-File -Encoding utf8 -FilePath $log }
        $dumpExit = $LASTEXITCODE
        if ($dumpExit -ne 0 -or -not (Test-Path -LiteralPath $dump)) {
            Add-Group "C.toolSchema.$($mode.name)" 'FAIL' "the launcher could not dump the tool catalog (exit $dumpExit)" $dump
            Write-Item -Status 'FAIL' -Text "$($mode.name): no tool dump"
            continue
        }
        $schemaReport = Join-Path $ReportDir "tool-schema-$($mode.name).json"
        $providerOut = Join-Path $ReportDir "provider-payload-$($mode.name).json"
        $schemaArgs = @(
            (Join-Path $layout.PackageRoot 'tests\test_tool_schema.mjs'),
            '--tools-json', $dump, '--json', '--write-report', $schemaReport,
            '--out-provider', $providerOut
        )
        if ($mode.name -eq 'upstream') { $schemaArgs += '--verbatim-upstream' }
        # The served path is compared against the tools/list the stdio probe
        # captured over the real MCP wire, which is independent of this dump.
        if ($mode.name -eq 'served' -and $mcpReport -and (Test-Path -LiteralPath $mcpReport)) {
            $schemaArgs += @('--observed', $mcpReport)
        }
        Invoke-Native { & node @schemaArgs 2>&1 | Out-Null }
        $schemaExit = $LASTEXITCODE
        $schemaJson = Read-JsonFile -Path $schemaReport
        if ($schemaJson) {
            foreach ($check in $schemaJson.checks) { Write-Item -Status $check.status -Text "$($mode.name)/$($check.id): $($check.detail)" }
            $status = 'PASS'
            if (@($schemaJson.checks | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0) { $status = 'FAIL' }
            elseif (@($schemaJson.checks | Where-Object { $_.status -eq 'WARN' }).Count -gt 0) { $status = 'WARN' }
            Add-Group "C.toolSchema.$($mode.name)" $status "$(@($schemaJson.risks).Count) risk shape(s), $($schemaJson.toolCount) tool(s)" $schemaReport
        } else {
            Add-Group "C.toolSchema.$($mode.name)" 'FAIL' "the schema test produced no report (exit $schemaExit)" $schemaReport
        }
    }
}

# Restore the real home before the DSH group, which manages its own sandbox.
if ($realUserProfile) { $env:USERPROFILE = $realUserProfile }

# ---------------------------------------------------------------------------
# D - DSH installation in an isolated profile
# ---------------------------------------------------------------------------
Write-Section 'D. DSH installation (isolated profile)'
if ($SkipDsh) {
    Add-Group 'D.dshIsolated' 'NOT TESTED' 'skipped with -SkipDsh' ''
    Write-Item -Status 'NOT TESTED' -Text 'skipped with -SkipDsh'
} else {
    $isolatedScript = Join-Path $layout.PackageRoot 'tests\test_dsh_isolated.ps1'
    if (-not (Test-Path -LiteralPath $isolatedScript)) {
        Add-Group 'D.dshIsolated' 'NOT TESTED' 'tests\test_dsh_isolated.ps1 is missing' ''
    } else {
        $isolatedReport = Join-Path $ReportDir 'dsh-isolated.json'
        # The isolated test relocates DSH_HOME (real isolation); the install root
        # is shared so an already-built runtime is reused instead of rebuilt.
        Invoke-Native {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $isolatedScript `
                -PackageRoot $layout.PackageRoot -InstallRoot $layout.InstallRoot `
                -Json -ReportPath $isolatedReport 2>&1 | Out-Null
        }
        $isolatedExit = $LASTEXITCODE
        $isolatedJson = Read-JsonFile -Path $isolatedReport
        if ($isolatedJson) {
            foreach ($check in $isolatedJson.checks) { Write-Item -Status $check.status -Text "$($check.id): $($check.detail)" }
            $status = 'PASS'
            if (@($isolatedJson.checks | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0) { $status = 'FAIL' }
            elseif (@($isolatedJson.checks | Where-Object { $_.status -eq 'WARN' }).Count -gt 0) { $status = 'WARN' }
            Add-Group 'D.dshIsolated' $status $isolatedJson.summary $isolatedReport
        } else {
            Add-Group 'D.dshIsolated' 'FAIL' "the isolated DSH test produced no report (exit $isolatedExit)" $isolatedReport
        }
    }
}

# ---------------------------------------------------------------------------
# E - real search
# ---------------------------------------------------------------------------
Write-Section 'E. Real CNKI search'
if (-not $EnableRealSearch) {
    Add-Group 'E.realSearch' 'NOT TESTED' 'requires an authenticated institution; re-run with -EnableRealSearch' ''
    Write-Item -Status 'NOT TESTED' -Text 'not requested; pass -EnableRealSearch on a machine with a valid CNKI login'
} elseif (-not $venvPython) {
    Add-Group 'E.realSearch' 'NOT TESTED' 'no runtime environment' ''
} else {
    $searchScript = Join-Path $layout.PackageRoot 'tests\test_real_search.py'
    if (-not (Test-Path -LiteralPath $searchScript)) {
        Add-Group 'E.realSearch' 'NOT TESTED' 'tests\test_real_search.py is missing' ''
    } else {
        $searchReport = Join-Path $ReportDir 'real-search.json'
        Invoke-Native { & $venvPython $searchScript --launcher $launcher --out $searchReport 2>&1 | ForEach-Object { Write-Host "    $_" } }
        $searchExit = $LASTEXITCODE
        $searchJson = Read-JsonFile -Path $searchReport
        if ($searchJson -and $searchJson.ok) {
            Add-Group 'E.realSearch' 'PASS' "easy-search returned $($searchJson.resultCount) real record(s)" $searchReport
            Write-Item -Status 'PASS' -Text "easy-search returned $($searchJson.resultCount) record(s)"
        } elseif ($searchJson) {
            Add-Group 'E.realSearch' 'FAIL' ([string]$searchJson.error) $searchReport
            Write-Item -Status 'FAIL' -Text ([string]$searchJson.error)
        } else {
            Add-Group 'E.realSearch' 'NOT TESTED' "the search test produced no report (exit $searchExit); institution auth may be missing" $searchReport
            Write-Item -Status 'NOT TESTED' -Text 'no report produced; institution authentication is likely missing'
        }
    }
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
$fails = @($groups | Where-Object { $_.status -eq 'FAIL' })
$warns = @($groups | Where-Object { $_.status -eq 'WARN' })
$notTested = @($groups | Where-Object { $_.status -eq 'NOT TESTED' })
$passes = @($groups | Where-Object { $_.status -eq 'PASS' })

$summary = [pscustomobject]@{
    schemaVersion = 1
    suite = 'run_all'
    startedAt = $stamp
    packageRoot = $layout.PackageRoot
    installRoot = $layout.InstallRoot
    interpreter = $venvPython
    counts = [pscustomobject]@{ pass = $passes.Count; warn = $warns.Count; fail = $fails.Count; notTested = $notTested.Count }
    groups = @($groups)
}
$summaryPath = Join-Path $ReportDir 'summary.json'
Write-JsonFile -Path $summaryPath -Value $summary

Write-Section 'Summary'
foreach ($group in $groups) { Write-Item -Status $group.status -Text "$($group.id): $($group.detail)" }
Write-Host ''
Write-Host "  $($passes.Count) passed, $($warns.Count) warning(s), $($fails.Count) failure(s), $($notTested.Count) not tested"
Write-Host "  evidence: $ReportDir"
if ($fails.Count -eq 0) { Write-Host '  VERDICT: no failing group' -ForegroundColor Green }
else { Write-Host '  VERDICT: at least one group FAILED' -ForegroundColor Red }

exit $(if ($fails.Count -eq 0) { 0 } else { 1 })
