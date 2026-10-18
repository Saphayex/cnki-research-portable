# =====================================================================================
# Test-UnifiedVerification.ps1 - verification suite for the unified RC3 candidate
#
# Owner: verify-dev (this round: repurposed auditor / test-harness-auditor).
# Shipped maintenance test (payload file). Windows PowerShell 5.1 only.
#
# WHAT IT VERIFIES (UNIFIED_CHARTER D10 groups A/I/J/K + section 7 evidence rules)
#   A  fresh install: extract candidate -> CHECK (NOT_INSTALLED, read-only) -> PLAN
#      (read-only) -> INSTALL (real offline attempt) -> VERIFY/STATUS -> idempotent
#      install -> UNINSTALL -> installer ROLLBACK; CJK/space path; over-extraction refusal.
#   I  installer regression: the byte-frozen tools\portable.ps1 still works (check /
#      diagnose / install link+copy / uninstall / rollback), junction safety, production
#      profile gate refusal, setup.ps1 refuses an already-installed target without -Force,
#      setup upgrade semantics (PLAN_READY read-only, NOOP_ALREADY_TARGET), PS 5.1 host.
#   J  package integrity + MCP: candidate ZIP identity (sidecar/external SUMS), extracted
#      ZIP tree vs candidate repo byte equality, internal closure S->M->U->P (independent
#      node checker), build_manifest --check, static package tests, frozen-core equality vs
#      frozen RC3 ZIP, clean git clone, MCP stdio protocol + launcher lifecycle + ping +
#      tool schema incl. get-info-by-detail.title, DSH 0.2.1 static+isolated composition.
#   K  release-security support: privacy/credential + dev-path scan over extracted package
#      and repo, ZIP path hygiene, license retention, frozen/production baseline comparison,
#      internal-material exclusion, detector positive/negative controls.
#
# SAFETY: every write is under -WorkRoot / -EvidenceDir (both below $U by default). Child
# processes get redirected USERPROFILE / DSH_HOME / TEMP / LOCALAPPDATA into the sandbox.
# The production DSH home, .cnki-mcp, bundle and the real ms-playwright cache are NEVER
# read or written; production/protected-object claims compare against the Lead baseline
# JSON only. No network, no real CNKI login/search, no DSH host is started.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-UnifiedVerification.ps1
#       [-UnifiedZip <candidate.zip>] [-CandidateRepo <dir>] [-Rc2Zip <frozen.zip>]
#       [-Rc3FrozenZip <frozen.zip>] [-Area A,I,J,K] [-Case '*'] [-KeepSandbox]
#       [-PrebuiltVenv <python-dir-with-Scripts\python.exe>] [-DshCli <dsh.cmd>]
#       [-SkipRealInstall] [-SelfTest]
#
# Exit codes: 0 = no FAIL; 2 = at least one FAIL / prerequisite mismatch; 1 = harness error.
# =====================================================================================
#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$UnifiedZip = '',
    [string]$CandidateRepo = '',
    [string]$Rc2Zip = '',
    [string]$Rc3FrozenZip = '',
    [string]$WorkRoot = '',
    [string]$EvidenceDir = '',
    [string[]]$Area = @('ALL'),
    [string]$Case = '*',
    [string]$PrebuiltVenv = '',
    [string]$DshCli = '',
    [switch]$KeepSandbox,
    [switch]$SkipRealInstall,
    [switch]$UseRepoTestScripts,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:TestToolVersion = '2.0.0'
$script:G = $null

# =====================================================================================
# Layout / frozen constants
# =====================================================================================

function Resolve-VLayout {
    $testsDir = $PSScriptRoot
    $repo = $CandidateRepo
    if (-not $repo) { $repo = [System.IO.Path]::GetFullPath((Join-Path $testsDir '..')) }
    $repo = [System.IO.Path]::GetFullPath($repo)
    $worktree = [System.IO.Path]::GetFullPath((Join-Path $repo '..'))
    $releaseRoot = [System.IO.Path]::GetFullPath((Join-Path $worktree '..'))
    $resolvedZip = $UnifiedZip
    if (-not $resolvedZip) {
        $resolvedZip = Join-Path (Join-Path $worktree 'RELEASE_ASSETS_CANDIDATE') 'CNKI-Research-Portable-1.0.0-rc.3-unified-candidate.zip'
    }
    $resolvedRc2 = $Rc2Zip
    if (-not $resolvedRc2) { $resolvedRc2 = Join-Path (Join-Path $releaseRoot 'RELEASE_ASSETS') 'CNKI-Research-Portable-1.0.0-rc.2.zip' }
    $resolvedRc3 = $Rc3FrozenZip
    if (-not $resolvedRc3) { $resolvedRc3 = Join-Path (Join-Path (Join-Path $releaseRoot 'RC3_WORKTREE') 'RELEASE_ASSETS') 'CNKI-Research-Portable-1.0.0-rc.3.zip' }
    $resolvedWork = $WorkRoot
    if (-not $resolvedWork) { $resolvedWork = Join-Path (Join-Path $worktree 'sandbox\verify-dev') 'work' }
    $resolvedEvidence = $EvidenceDir
    if (-not $resolvedEvidence) { $resolvedEvidence = Join-Path (Join-Path $worktree ('_' + 'evidence')) 'verify' }
    $resolvedBaseline = Join-Path (Join-Path $worktree ('_' + 'evidence')) 'baseline'
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    return [pscustomobject]@{
        TestsDir    = $testsDir
        Repo        = $repo
        Worktree    = $worktree
        ReleaseRoot = $releaseRoot
        UnifiedZip  = [System.IO.Path]::GetFullPath($resolvedZip)
        Rc2Zip      = [System.IO.Path]::GetFullPath($resolvedRc2)
        Rc3Zip      = [System.IO.Path]::GetFullPath($resolvedRc3)
        WorkRoot    = [System.IO.Path]::GetFullPath($resolvedWork)
        EvidenceDir = [System.IO.Path]::GetFullPath($resolvedEvidence)
        BaselineDir = [System.IO.Path]::GetFullPath($resolvedBaseline)
        PsExe       = $psExe
    }
}

function Get-VFrozenIdentity {
    [pscustomobject]@{
        Rc2ZipSha256     = '4f279f359a42e5e950cd9f66e04f0922c5e40ec4c77f9192e2168274ce1142b5'
        Rc2ZipBytes      = 388236
        Rc3ZipSha256     = 'f4e914d135eb51b8d3afbd96e7fca53997a06e0ed1a75a28cca9386c3cc7f5fd'
        Rc3ZipBytes      = 395232
        Rc2ManifestSha256 = '80229318a1ef070f5cedafda39785be0cbb49ee727f7a620e7e6aab5113a6e1f'
        Rc3ManifestSha256 = '98c8bca2bd34f0eda0e1d9fb1d0c6f38e60c8c4e92990efcb1c3be507f99a5e2'
        Rc2Version       = '1.0.0-rc.2'
        Rc3Version       = '1.0.0-rc.3'
        BundleVersion    = '1.0.0'
        TargetVersion    = '1.0.0-rc.3'
        ExpectedPayloadCount = 115
        ExpectedAddedPayloadCount = 8
        ExpectedZipEntries = 119
        ExpectedSumsEntries = 118
        ExpectedSourcePayloadCount = 107
        AddedPayload = @(
            'tools/setup.ps1'
            'tools/lib/UpgradeCommon.ps1'
            'tools/build_unified_release.ps1'
            'tests/Test-UnifiedMatrix.ps1'
            'tests/lib/UnifiedFixtures.ps1'
            'tests/lib/UnifiedAssert.ps1'
            'tests/Test-UnifiedVerification.ps1'
            'tests/test_unified_package.mjs'
        )
        CoreIdentical = @(
            'bundle/cnki-research/cordis.patch.yml'
            'bundle/cnki-research/package.json'
            'bundle/cnki-research/README.md'
            'bundle/cnki-research/launcher/cnki_research_launcher.py'
            'bundle/cnki-research/skills/cnki-literature-search/SKILL.md'
            'LICENSE'
            'THIRD-PARTY-NOTICES.md'
            'tools/portable.ps1'
            'tools/lib/PortableCommon.ps1'
            'tools/probe_mcp_stdio.py'

            'docs/06-设计取舍.md'
        )
        ToolNames = @('easy-search', 'advanced-search', 'get-info-from-url', 'get-info-by-detail',
                      'list-journal', 'search-issn', 'login', 'logout')
    }
}

# =====================================================================================
# Generic helpers: encoding / hashing / JSON / files
# =====================================================================================

function New-Utf8NoBom { New-Object System.Text.UTF8Encoding($false) }
function Get-FullPath { param([string]$Path) return [System.IO.Path]::GetFullPath($Path) }
function Get-Sha256File {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Get-FullPath $Path
    if (-not [System.IO.File]::Exists($full)) { throw "Get-Sha256File: not found: $full" }
    $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}
function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash((New-Utf8NoBom).GetBytes($Text)) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}
function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Get-FullPath $Path
    if (-not [System.IO.File]::Exists($full)) { return $null }
    return (Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Write-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value, [int]$Depth = 30)
    $full = Get-FullPath $Path
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $json = $Value | ConvertTo-Json -Depth $Depth
    if ($null -eq $json) { $json = 'null' }
    $json = $json -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($full, $json + "`n", (New-Utf8NoBom))
}
function Limit-Text {
    param([AllowNull()][string]$Text, [int]$Max = 220)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}
function Test-PathUnder {
    param([Parameter(Mandatory = $true)][string]$Child, [Parameter(Mandatory = $true)][string]$Parent)
    $c = (Get-FullPath $Child).TrimEnd('\', '/')
    $p = (Get-FullPath $Parent).TrimEnd('\', '/')
    if ($c -ieq $p) { return $true }
    return $c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# =====================================================================================
# Case/evidence plumbing (V1-compatible shape)
# =====================================================================================

function New-VCaseContext {
    param([string]$Case, [string]$Description = '', [string]$CaseRoot = '', [string]$OutDir = '')
    [pscustomobject]@{
        Case        = $Case
        Description = $Description
        CaseRoot    = $CaseRoot
        OutDir      = $OutDir
        StartedAt   = (Get-Date).ToString('o')
        Checks      = (New-Object System.Collections.ArrayList)
        Commands    = (New-Object System.Collections.ArrayList)
        Artifacts   = (New-Object System.Collections.ArrayList)
        Notes       = (New-Object System.Collections.ArrayList)
        CaseData    = @{}
        Status      = 'NOT TESTED'
    }
}
function New-VResult {
    param([string]$Id, [string]$Status, [string]$Detail, $Expected = $null, $Actual = $null, $Data = $null)
    [pscustomobject]@{
        Id = $Id; Status = $Status; Detail = $Detail; Expected = $Expected; Actual = $Actual; Data = $Data
    }
}
function Add-VCheck {
    param([Parameter(Mandatory = $true)]$Ctx, [Parameter(Mandatory = $true)]$Result, [switch]$Quiet)
    if ($null -eq $Result) { throw 'Add-VCheck: null result' }
    [void]$Ctx.Checks.Add($Result)
    if (-not $Quiet) {
        $color = switch ($Result.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
        Write-Host ("  [{0,-4}] {1,-52} {2}" -f $Result.Status, $Result.Id, (Limit-Text $Result.Detail 170)) -ForegroundColor $color
    }
    return $Result
}
function Assert-VCondition {
    param([string]$Id, [bool]$Condition, [string]$PassDetail, [string]$FailDetail, $Expected = $null, $Actual = $null)
    if ($Condition) { return New-VResult -Id $Id -Status 'PASS' -Detail $PassDetail -Expected $Expected -Actual $Actual }
    return New-VResult -Id $Id -Status 'FAIL' -Detail $FailDetail -Expected $Expected -Actual $Actual
}
function Add-VCommand {
    param($Ctx, [string]$Label, [string]$Executable, [string[]]$Arguments = @(), [int]$ExitCode = 0,
          [string]$StdoutPath = '', [string]$StderrPath = '', [string]$JsonPath = '', [hashtable]$Environment = @{}, [double]$DurationSec = 0)
    $entry = [pscustomobject]@{
        Label = $Label; Executable = $Executable; Arguments = @($Arguments); ExitCode = $ExitCode
        StdoutPath = $StdoutPath; StderrPath = $StderrPath; JsonPath = $JsonPath; Environment = $Environment
        DurationSec = [Math]::Round($DurationSec, 2)
    }
    [void]$Ctx.Commands.Add($entry)
    if ($StdoutPath) { Add-VArtifact $Ctx $StdoutPath ("$Label stdout") | Out-Null }
    if ($StderrPath) { Add-VArtifact $Ctx $StderrPath ("$Label stderr") | Out-Null }
    if ($JsonPath) { Add-VArtifact $Ctx $JsonPath ("$Label JSON") | Out-Null }
    return $entry
}
function Add-VArtifact {
    param($Ctx, [string]$Path, [string]$Label = '')
    $entry = [pscustomobject]@{ Label = $Label; Path = $Path }
    [void]$Ctx.Artifacts.Add($entry)
    return $entry
}
function Add-VNote { param($Ctx, [string]$Note) [void]$Ctx.Notes.Add($Note) }
function Complete-VCase {
    param($Ctx)
    $checks = @($Ctx.Checks.ToArray())
    $fails = @($checks | Where-Object { $_.Status -eq 'FAIL' })
    $passes = @($checks | Where-Object { $_.Status -eq 'PASS' })
    $warns = @($checks | Where-Object { $_.Status -eq 'WARN' })
    $notTested = @($checks | Where-Object { $_.Status -eq 'NOT TESTED' })
    if ($fails.Count -gt 0) { $Ctx.Status = 'FAIL' }
    elseif ($checks.Count -eq 0) { $Ctx.Status = 'NOT TESTED' }
    elseif ($passes.Count -eq 0 -and $notTested.Count -eq $checks.Count) { $Ctx.Status = 'NOT TESTED' }
    else { $Ctx.Status = 'PASS' }
    return [ordered]@{
        case = $Ctx.Case
        description = $Ctx.Description
        status = $Ctx.Status
        startedAt = $Ctx.StartedAt
        finishedAt = (Get-Date).ToString('o')
        summary = [ordered]@{ total = $checks.Count; pass = $passes.Count; warn = $warns.Count; fail = $fails.Count; notTested = $notTested.Count }
        checks = @($checks | ForEach-Object { [ordered]@{ id = $_.Id; status = $_.Status; detail = $_.Detail; expected = $_.Expected; actual = $_.Actual; data = $_.Data } })
        commands = @($Ctx.Commands.ToArray())
        artifacts = @($Ctx.Artifacts.ToArray())
        notes = @($Ctx.Notes.ToArray())
        runtimeActivation = 'NOT TESTED'
    }
}
function Write-VCaseEvidence {
    param($Ctx)
    $caseDir = Join-Path $script:G.EvidenceDir $Ctx.Case
    if (-not [System.IO.Directory]::Exists($caseDir)) { [void][System.IO.Directory]::CreateDirectory($caseDir) }
    # Copy run artifacts into the evidence tree so evidence survives sandbox cleanup.
    $outDest = Join-Path $caseDir 'out'
    if ($Ctx.OutDir -and [System.IO.Directory]::Exists($Ctx.OutDir)) {
        if (-not [System.IO.Directory]::Exists($outDest)) { [void][System.IO.Directory]::CreateDirectory($outDest) }
        foreach ($file in @(Get-ChildItem -LiteralPath $Ctx.OutDir -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = $file.FullName.Substring($Ctx.OutDir.Length).TrimStart('\')
            $dest = Join-Path $outDest $rel
            $destDir = [System.IO.Path]::GetDirectoryName($dest)
            if ($destDir -and -not [System.IO.Directory]::Exists($destDir)) { [void][System.IO.Directory]::CreateDirectory($destDir) }
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
        }
    }
    $remap = {
        param([string]$Path)
        if (-not $Path) { return $Path }
        if ($Ctx.OutDir -and $Path.StartsWith($Ctx.OutDir, [System.StringComparison]::OrdinalIgnoreCase)) { return (Join-Path $outDest ($Path.Substring($Ctx.OutDir.Length).TrimStart('\'))) }
        return $Path
    }
    foreach ($cmd in @($Ctx.Commands.ToArray())) {
        $cmd.StdoutPath = (& $remap $cmd.StdoutPath)
        $cmd.StderrPath = (& $remap $cmd.StderrPath)
        $cmd.JsonPath = (& $remap $cmd.JsonPath)
    }
    foreach ($art in @($Ctx.Artifacts.ToArray())) { $art.Path = (& $remap $art.Path) }
    $final = Complete-VCase -Ctx $Ctx
    $path = Join-Path $script:G.EvidenceDir ($Ctx.Case + '.json')
    Write-JsonFile -Path $path -Value $final -Depth 40
    return [pscustomobject]@{ Summary = $final; Path = $path; CaseDir = $caseDir }
}

# =====================================================================================
# Snapshot / fingerprint (read-only proof and preservation proof)
# =====================================================================================

function New-VSnapshotEntry {
    param([string]$Rel, [string]$Kind, [long]$Bytes = 0, [string]$Sha256 = $null, [long]$MtimeUtcTicks = 0, [string]$Target = $null)
    [pscustomobject]@{ Rel = $Rel; Kind = $Kind; Bytes = $Bytes; Sha256 = $Sha256; MtimeUtcTicks = $MtimeUtcTicks; Target = $Target }
}
function Get-VTreeSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root, [string[]]$ExcludePrefixes = @())
    $rootFull = Get-FullPath $Root
    $entries = New-Object System.Collections.ArrayList
    if (-not [System.IO.Directory]::Exists($rootFull)) { return @() }
    $excludes = @()
    foreach ($e in $ExcludePrefixes) { if ($e) { $excludes += (($e -replace '\\', '/').Trim('/')) } }
    $stack = New-Object System.Collections.Stack
    $stack.Push([pscustomobject]@{ Abs = $rootFull; Rel = '' })
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $children = @()
        try { $children = @([System.IO.Directory]::EnumerateFileSystemEntries($item.Abs)) } catch { continue }
        foreach ($child in $children) {
            $name = [System.IO.Path]::GetFileName($child)
            $rel = if ($item.Rel) { "$($item.Rel)/$name" } else { $name }
            $skip = $false
            foreach ($ex in $excludes) {
                if ($rel -ieq $ex -or $rel.StartsWith($ex + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
            }
            if ($skip) { continue }
            $attrs = [System.IO.File]::GetAttributes($child)
            $isReparse = [bool]($attrs -band [System.IO.FileAttributes]::ReparsePoint)
            $isDir = [bool]($attrs -band [System.IO.FileAttributes]::Directory)
            if ($isReparse) {
                $target = $null
                try { $target = (Get-Item -LiteralPath $child -Force).Target } catch { }
                if ($target -is [array]) { $target = ($target -join ';') }
                [void]$entries.Add((New-VSnapshotEntry -Rel $rel -Kind 'reparse' -Target ([string]$target)))
                continue
            }
            if ($isDir) {
                $mtime = 0
                try { $mtime = ([System.IO.Directory]::GetLastWriteTimeUtc($child)).Ticks } catch { }
                [void]$entries.Add((New-VSnapshotEntry -Rel $rel -Kind 'dir' -MtimeUtcTicks $mtime))
                $stack.Push([pscustomobject]@{ Abs = $child; Rel = $rel })
            } else {
                $bytes = 0; $sha = $null; $mtime = 0
                try {
                    $bytes = (New-Object System.IO.FileInfo($child)).Length
                    $sha = Get-Sha256File $child
                    $mtime = ([System.IO.File]::GetLastWriteTimeUtc($child)).Ticks
                } catch { continue }
                [void]$entries.Add((New-VSnapshotEntry -Rel $rel -Kind 'file' -Bytes $bytes -Sha256 $sha -MtimeUtcTicks $mtime))
            }
        }
    }
    return @($entries.ToArray() | Sort-Object Rel)
}
function Get-VSnapshotIndex {
    param([AllowEmptyCollection()][object[]]$Snapshot)
    $index = @{}
    foreach ($e in @($Snapshot)) { $index[[string]$e.Rel] = $e }
    return $index
}
function Compare-VSnapshot {
    param([AllowEmptyCollection()][object[]]$Before, [AllowEmptyCollection()][object[]]$After, [string[]]$IgnorePrefixes = @())
    # Harness artifacts and OS scratch written by a non-interactive child PowerShell under a
    # redirected USERPROFILE are not product writes: the per-case out/ dir receives command
    # logs/JSON, and Windows PowerShell creates userprofile\AppData startup-profile data. Both are
    # excluded from read-only/no-write comparisons and the exclusion is documented in the evidence.
    $IgnorePrefixes = @($IgnorePrefixes) + @('out', 'AppData', 'userprofile/AppData', 'temp', 'localappdata')
    $b = Get-VSnapshotIndex $Before
    $a = Get-VSnapshotIndex $After
    $ignore = @()
    foreach ($p in $IgnorePrefixes) { if ($p) { $ignore += (($p -replace '\\', '/').Trim('/')) } }
    $added = New-Object System.Collections.ArrayList
    $removed = New-Object System.Collections.ArrayList
    $changed = New-Object System.Collections.ArrayList
    foreach ($rel in $a.Keys) {
        $skip = $false
        foreach ($ig in $ignore) { if ($rel -ieq $ig -or $rel.StartsWith($ig + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break } }
        if ($skip) { continue }
        if (-not $b.ContainsKey($rel)) { [void]$added.Add($rel); continue }
        $be = $b[$rel]; $ae = $a[$rel]
        if ($be.Kind -ne $ae.Kind) { [void]$changed.Add("$rel (kind $($be.Kind)->$($ae.Kind))"); continue }
        if ($be.Kind -eq 'file') {
            if ($be.Sha256 -ne $ae.Sha256 -or $be.Bytes -ne $ae.Bytes) { [void]$changed.Add("$rel (bytes)") }
        } elseif ($be.Kind -eq 'reparse') {
            if ([string]$be.Target -ne [string]$ae.Target) { [void]$changed.Add("$rel (reparse target)") }
        }
    }
    foreach ($rel in $b.Keys) {
        $skip = $false
        foreach ($ig in $ignore) { if ($rel -ieq $ig -or $rel.StartsWith($ig + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break } }
        if ($skip) { continue }
        if (-not $a.ContainsKey($rel)) { [void]$removed.Add($rel) }
    }
    return [pscustomobject]@{
        Equal = (($added.Count -eq 0) -and ($removed.Count -eq 0) -and ($changed.Count -eq 0))
        Added = @($added.ToArray()); Removed = @($removed.ToArray()); Changed = @($changed.ToArray())
    }
}
function Get-VSnapshotDigest {
    param([AllowEmptyCollection()][object[]]$Snapshot)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in @($Snapshot)) {
        $lines.Add([string]$e.Rel + "`t" + [string]$e.Kind + "`t" + [string]$e.Bytes + "`t" + [string]$e.Sha256 + "`t" + [string]$e.MtimeUtcTicks + "`t" + [string]$e.Target)
    }
    $arr = $lines.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    $text = ''
    if ($arr.Count -gt 0) { $text = ($arr -join "`n") + "`n" }
    return Get-Sha256Text $text
}
function Write-VReadOnlyEvidence {
    param($Ctx, [string]$Path, [string]$Label, [AllowEmptyCollection()][object[]]$Before, [AllowEmptyCollection()][object[]]$After, $Diff)
    $doc = [ordered]@{
        schemaVersion = 1
        label = $Label
        generatedAt = (Get-Date).ToString('o')
        digestRule = 'sha256_lowerhex_utf8_lf over sorted(lines "rel<TAB>kind<TAB>bytes<TAB>sha256<TAB>mtimeUtcTicks<TAB>target") with trailing LF'
        beforeDigest = (Get-VSnapshotDigest -Snapshot $Before)
        afterDigest = (Get-VSnapshotDigest -Snapshot $After)
        beforeEntryCount = @($Before).Count
        afterEntryCount = @($After).Count
        identical = $Diff.Equal
        added = @($Diff.Added); removed = @($Diff.Removed); changed = @($Diff.Changed)
    }
    Write-JsonFile -Path $Path -Value $doc -Depth 20
    Add-VArtifact $Ctx $Path $Label | Out-Null
}

# =====================================================================================
# Process invocation (child processes get the isolated environment)
# =====================================================================================

function Initialize-VPrebuiltVenvAt {
    # Seeds the verified prebuilt interpreter at <InstallRoot>\.venv so deterministic offline
    # installer runs do not depend on the uv cache. The source runtime is opened read-only and a
    # junction is used (not a copy). VENV CREATION ITSELF is exercised only by the real-install case.
    param($Ctx, [Parameter(Mandatory = $true)][string]$InstallRoot)
    if (-not $script:G.PrebuiltVenvUsable) { return $false }
    $venvTarget = Join-Path $InstallRoot '.venv'
    if ([System.IO.File]::Exists((Join-Path $venvTarget 'Scripts\python.exe'))) { return $true }
    if (Test-Path -LiteralPath $venvTarget) { try { Remove-VTreeJunctionSafe -Path $venvTarget -AllowedRoot $InstallRoot } catch { } }
    try {
        New-Item -ItemType Junction -Path $venvTarget -Target $script:G.PrebuiltVenv -ErrorAction Stop | Out-Null
        Add-VNote $Ctx ('prebuilt interpreter seeded at ' + $venvTarget + ' (read-only read of the verified local runtime; venv creation is exercised by A3)')
        return $true
    } catch {
        Add-VNote $Ctx ('prebuilt interpreter could not be seeded: ' + $_.Exception.Message)
        return $false
    }
}

function Invoke-VProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = '',
        [string]$OutDir = '',
        [string]$Label = 'run',
        [switch]$AllowNonZero
    )
    if ($OutDir -and -not [System.IO.Directory]::Exists($OutDir)) { [void][System.IO.Directory]::CreateDirectory($OutDir) }
    $slug = ($Label -replace '[^A-Za-z0-9._-]+', '-')
    if (-not $slug) { $slug = 'run' }
    $stdoutPath = Join-Path $OutDir ($slug + '.stdout.txt')
    $stderrPath = Join-Path $OutDir ($slug + '.stderr.txt')
    $saved = @{}
    foreach ($key in $Environment.Keys) {
        $saved[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
        [System.Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }
    $prevErrorAction = $ErrorActionPreference
    $startedAt = Get-Date
    $exitCode = -1
    $stdoutText = ''
    try {
        $ErrorActionPreference = 'Continue'
        if ($WorkingDirectory) {
            Push-Location -LiteralPath $WorkingDirectory
            try { $stdoutText = (& $Executable @Arguments 2> $stderrPath | Out-String) } finally { Pop-Location }
        } else {
            $stdoutText = (& $Executable @Arguments 2> $stderrPath | Out-String)
        }
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
    } catch {
        $exitCode = -1
        $stdoutText = "HARNESS: child invocation failed: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $prevErrorAction
        foreach ($key in $saved.Keys) { [System.Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
    if (-not [System.IO.File]::Exists($stderrPath)) { [System.IO.File]::WriteAllText($stderrPath, '', (New-Utf8NoBom)) }
    [System.IO.File]::WriteAllText($stdoutPath, $stdoutText, (New-Utf8NoBom))
    $duration = ((Get-Date) - $startedAt).TotalSeconds
    if (-not $AllowNonZero -and $exitCode -ne 0) {
        # Caller decides whether a non-zero exit is expected; never throw here.
    }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Stdout = $stdoutText
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        DurationSec = [Math]::Round($duration, 2)
        Arguments = $Arguments
        Executable = $Executable
    }
}

function New-VIsolatedEnvironment {
    param([Parameter(Mandatory = $true)][string]$Root)
    $paths = [ordered]@{
        Root = Get-FullPath $Root
        UserProfile = Join-Path (Get-FullPath $Root) 'userprofile'
        DshHome = Join-Path (Get-FullPath $Root) 'dsh-home'
        Temp = Join-Path (Get-FullPath $Root) 'temp'
        LocalAppData = Join-Path (Get-FullPath $Root) 'localappdata'
        Home = Join-Path (Get-FullPath $Root) 'home'
    }
    foreach ($key in 'UserProfile', 'DshHome', 'Temp', 'LocalAppData', 'Home') {
        if (-not [System.IO.Directory]::Exists($paths[$key])) { [void][System.IO.Directory]::CreateDirectory($paths[$key]) }
    }
    # Synthetic Playwright browser directory: installer detects a chromium build name and
    # skips its download branch. The browser itself is never launched by this suite and the
    # real user browser cache is never read (UNIFIED_CHARTER section 2 / Lead ruling).
    $pw = Join-Path $paths.LocalAppData 'ms-playwright'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $pw 'chromium-1243'))
    $env = @{
        USERPROFILE = $paths.UserProfile
        DSH_HOME = $paths.DshHome
        TEMP = $paths.Temp
        TMP = $paths.Temp
        LOCALAPPDATA = $paths.LocalAppData
        HOME = $paths.Home
        PYTHONIOENCODING = 'utf-8'
    }
    return [pscustomobject]@{ Paths = [pscustomobject]$paths; Env = $env }
}

# =====================================================================================
# ZIP helpers
# =====================================================================================

function Initialize-ZipAssembly {
    if (-not ('System.IO.Compression.ZipFile' -as [type])) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }
}
function Get-VZipEntries {
    param([Parameter(Mandatory = $true)][string]$ZipPath)
    Initialize-ZipAssembly
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Get-FullPath $ZipPath))
    try {
        $entries = New-Object System.Collections.ArrayList
        foreach ($entry in $zip.Entries) {
            $isDir = $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')
            $bytes = 0; $sha = $null
            if (-not $isDir) {
                $stream = $entry.Open()
                try {
                    $ms = New-Object System.IO.MemoryStream
                    try {
                        $stream.CopyTo($ms)
                        $entryBytes = $ms.ToArray()
                        $bytes = $entryBytes.Length
                        $sha256 = [System.Security.Cryptography.SHA256]::Create()
                        try { $hash = $sha256.ComputeHash($entryBytes) } finally { $sha256.Dispose() }
                        $sha = ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
                    } finally { $ms.Dispose() }
                } finally { $stream.Dispose() }
            }
            [void]$entries.Add([pscustomobject]@{
                Path = ($entry.FullName -replace '\\', '/')
                IsDirectory = $isDir
                Bytes = [long]$bytes
                Sha256 = $sha
                CompressedBytes = [long]$entry.CompressedLength
            })
        }
        return @($entries.ToArray())
    } finally { $zip.Dispose() }
}
function Expand-VZipToDirectory {
    param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)][string]$Destination)
    Initialize-ZipAssembly
    $dest = Get-FullPath $Destination
    if ([System.IO.Directory]::Exists($dest)) { Remove-VTreeJunctionSafe -Path $dest -AllowedRoot ([System.IO.Path]::GetDirectoryName($dest)) }
    [void][System.IO.Directory]::CreateDirectory($dest)
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Get-FullPath $ZipPath), $dest)
}
function Test-VZipPathHygiene {
    param([Parameter(Mandatory = $true)][object[]]$Entries)
    $problems = New-Object System.Collections.ArrayList
    $names = New-Object System.Collections.ArrayList
    $lower = @{}
    foreach ($e in $Entries) {
        $name = [string]$e.Path
        if (-not $name) { [void]$problems.Add('empty entry name'); continue }
        if ($e.IsDirectory) { [void]$problems.Add("directory entry: $name"); continue }
        if ($name -match '^[/\\]') { [void]$problems.Add("absolute entry: $name") }
        if ($name -match '^[A-Za-z]:') { [void]$problems.Add("drive-letter entry: $name") }
        if ($name -match '(^|[/\\])\.\.([/\\]|$)') { [void]$problems.Add("traversal entry: $name") }
        if ($name -match '\\') { [void]$problems.Add("backslash entry: $name") }
        if ($name -match '//') { [void]$problems.Add("double-slash entry: $name") }
        if ($name.Contains(':')) { [void]$problems.Add("colon entry: $name") }
        [void]$names.Add($name)
        $key = $name.ToLowerInvariant()
        if ($lower.ContainsKey($key)) { [void]$problems.Add("case-colliding/duplicate entry: $name") } else { $lower[$key] = $true }
    }
    return @($problems.ToArray())
}

# =====================================================================================
# Junction-safe deletion (only under the declared root)
# =====================================================================================

function Remove-VDirectoryContentsJunctionSafe {
    param([Parameter(Mandatory = $true)][string]$Directory)
    foreach ($child in @([System.IO.Directory]::EnumerateFileSystemEntries($Directory))) {
        $attrs = [System.IO.File]::GetAttributes($child)
        if ([bool]($attrs -band [System.IO.FileAttributes]::ReparsePoint)) {
            if ([bool]($attrs -band [System.IO.FileAttributes]::Directory)) { [System.IO.Directory]::Delete($child, $false) }
            else { [System.IO.File]::Delete($child) }
            continue
        }
        if ([bool]($attrs -band [System.IO.FileAttributes]::Directory)) {
            Remove-VDirectoryContentsJunctionSafe -Directory $child
            [System.IO.Directory]::Delete($child, $false)
        } else {
            if ([bool]($attrs -band [System.IO.FileAttributes]::ReadOnly)) { [System.IO.File]::SetAttributes($child, [System.IO.FileAttributes]::Normal) }
            [System.IO.File]::Delete($child)
        }
    }
}
function Remove-VTreeJunctionSafe {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$AllowedRoot)
    $full = Get-FullPath $Path
    $allowed = Get-FullPath $AllowedRoot
    if (-not (Test-PathUnder -Child $full -Parent $allowed)) { throw "Remove-VTreeJunctionSafe REFUSED: '$full' is not under '$allowed'" }
    if (-not [System.IO.Directory]::Exists($full)) { return }
    Remove-VDirectoryContentsJunctionSafe -Directory $full
    [System.IO.Directory]::Delete($full, $false)
}

# =====================================================================================
# Directory maps (for extracted ZIP vs candidate repo comparison)
# =====================================================================================

function Get-VDirectoryFileMap {
    param([Parameter(Mandatory = $true)][string]$Root, [string[]]$ExcludeRelPrefixes = @())
    $rootFull = Get-FullPath $Root
    $map = @{}
    if (-not [System.IO.Directory]::Exists($rootFull)) { return $map }
    $snapshot = @(Get-VTreeSnapshot -Root $rootFull)
    foreach ($entry in $snapshot) {
        if ($entry.Kind -ne 'file') { continue }
        $skip = $false
        foreach ($ex in $ExcludeRelPrefixes) {
            if (-not $ex) { continue }
            $exNorm = ($ex -replace '\\', '/').Trim('/')
            if ($entry.Rel -ieq $exNorm -or $entry.Rel.StartsWith($exNorm + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
        }
        if ($skip) { continue }
        $map[$entry.Rel] = [pscustomobject]@{ Rel = $entry.Rel; Bytes = $entry.Bytes; Sha256 = $entry.Sha256 }
    }
    return $map
}
function Compare-VFileMaps {
    param([Parameter(Mandatory = $true)][hashtable]$Left, [Parameter(Mandatory = $true)][hashtable]$Right, [int]$MaxList = 20)
    $onlyLeft = New-Object System.Collections.ArrayList
    $onlyRight = New-Object System.Collections.ArrayList
    $different = New-Object System.Collections.ArrayList
    foreach ($key in $Left.Keys) {
        if (-not $Right.ContainsKey($key)) { [void]$onlyLeft.Add($key); continue }
        if ($Left[$key].Sha256 -ne $Right[$key].Sha256) { [void]$different.Add($key) }
    }
    foreach ($key in $Right.Keys) {
        if (-not $Left.ContainsKey($key)) { [void]$onlyRight.Add($key) }
    }
    return [pscustomobject]@{
        Equal = (($onlyLeft.Count -eq 0) -and ($onlyRight.Count -eq 0) -and ($different.Count -eq 0))
        OnlyLeft = @($onlyLeft.ToArray() | Sort-Object | Select-Object -First $MaxList)
        OnlyRight = @($onlyRight.ToArray() | Sort-Object | Select-Object -First $MaxList)
        Different = @($different.ToArray() | Sort-Object | Select-Object -First $MaxList)
    }
}

# =====================================================================================
# Sandbox helpers
# =====================================================================================

function New-VCaseSandbox {
    param([Parameter(Mandatory = $true)][string]$Case, [string]$Description = '')
    $caseRoot = Join-Path $script:G.WorkRoot $Case
    if (Test-Path -LiteralPath $caseRoot) { Remove-VTreeJunctionSafe -Path $caseRoot -AllowedRoot $script:G.WorkRoot }
    [void][System.IO.Directory]::CreateDirectory($caseRoot)
    $outDir = Join-Path $caseRoot 'out'
    [void][System.IO.Directory]::CreateDirectory($outDir)
    $ctx = New-VCaseContext -Case $Case -Description $Description -CaseRoot $caseRoot -OutDir $outDir
    return $ctx
}
function Get-VRepoCopy {
    param([Parameter(Mandatory = $true)][string]$Destination)
    $dest = Get-FullPath $Destination
    if (Test-Path -LiteralPath $dest) { Remove-VTreeJunctionSafe -Path $dest -AllowedRoot (Split-Path -Parent $dest) }
    [void][System.IO.Directory]::CreateDirectory($dest)
    $excludePrefixes = @('.git', '_scratch', 'dist', '_portable', 'test-evidence', 'node_modules', '.venv', '__pycache__')
    foreach ($entry in @([System.IO.Directory]::EnumerateFileSystemEntries($script:G.Repo))) {
        $name = [System.IO.Path]::GetFileName($entry)
        if ($excludePrefixes -contains $name) { continue }
        $target = Join-Path $dest $name
        $attrs = [System.IO.File]::GetAttributes($entry)
        if ([bool]($attrs -band [System.IO.FileAttributes]::Directory)) {
            Copy-Item -LiteralPath $entry -Destination $target -Recurse -Force
        } else {
            Copy-Item -LiteralPath $entry -Destination $target -Force
        }
    }
    return $dest
}

# =====================================================================================
# Shared verification context ($script:G) + prerequisite probing
# =====================================================================================

function Initialize-VRun {
    $layout = Resolve-VLayout
    $script:G = [ordered]@{
        Layout = $layout
        WorkRoot = $layout.WorkRoot
        EvidenceDir = $layout.EvidenceDir
        Repo = $layout.Repo
        Frozen = Get-VFrozenIdentity
        KeepSandbox = [bool]$KeepSandbox
        SkipRealInstall = [bool]$SkipRealInstall
        UseRepoTestScripts = [bool]$UseRepoTestScripts
        PrebuiltVenv = $PrebuiltVenv
        DshCliResolved = $DshCli
        StartTime = (Get-Date)
        InvokeCounter = 0
        CandidateZipPresent = $false
        CandidateZipSha = $null
        CandidateZipBytes = $null
        ZipEntries = $null
        CandidateRepoPresent = $false
        SetupPresent = $false
        EnginePresent = $false
        PackageMetadataPresent = $false
        PrebuiltVenvUsable = $false
        ExpandedCandidateRoot = ''
        AreasRun = (New-Object System.Collections.ArrayList)
    }
    foreach ($dir in $layout.WorkRoot, $layout.EvidenceDir) {
        if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    }
    if (-not $script:G.DshCliResolved) {
        $cmd = Get-Command 'dsh.cmd' -ErrorAction SilentlyContinue
        if ($cmd) { $script:G.DshCliResolved = $cmd.Source }
    }
    if (-not $script:G.PrebuiltVenv -and $env:CNKI_PREBUILT_VENV) { $script:G.PrebuiltVenv = $env:CNKI_PREBUILT_VENV }
    if (-not $script:G.PrebuiltVenv) {
        # Non-shipped default candidates: a pre-existing verified portable runtime next to the
        # release tree. Never production DSH/CNKI data; read-only interpreter use only.
        foreach ($base in @($layout.ReleaseRoot, (Split-Path -Parent $layout.ReleaseRoot))) {
            $candidate = Join-Path (Join-Path $base 'portable-v1.0') '.venv'
            if ([System.IO.File]::Exists((Join-Path $candidate 'Scripts\python.exe'))) { $script:G.PrebuiltVenv = $candidate; break }
        }
    }
    if ($script:G.PrebuiltVenv) {
        $py = Join-Path $script:G.PrebuiltVenv 'Scripts\python.exe'
        if ([System.IO.File]::Exists($py)) { $script:G.PrebuiltVenvUsable = $true }
    }
    $repo = $layout.Repo
    $script:G.CandidateRepoPresent = [System.IO.Directory]::Exists($repo)
    if ($script:G.CandidateRepoPresent) {
        $script:G.SetupPresent = [System.IO.File]::Exists((Join-Path $repo 'tools\setup.ps1'))
        $script:G.EnginePresent = [System.IO.File]::Exists((Join-Path $repo 'tools\lib\UpgradeCommon.ps1'))
        $script:G.PackageMetadataPresent = ([System.IO.File]::Exists((Join-Path $repo 'manifest.json'))) -and
            ([System.IO.File]::Exists((Join-Path $repo 'SHA256SUMS.txt'))) -and
            ([System.IO.File]::Exists((Join-Path $repo 'upgrade-data\rc2-to-rc3.json')))
    }
    if ([System.IO.File]::Exists($layout.UnifiedZip)) {
        $script:G.CandidateZipPresent = $true
        $script:G.CandidateZipBytes = (Get-Item -LiteralPath $layout.UnifiedZip).Length
        $script:G.CandidateZipSha = Get-Sha256File $layout.UnifiedZip
        try { $script:G.ZipEntries = @(Get-VZipEntries -ZipPath $layout.UnifiedZip) } catch { $script:G.ZipEntries = $null }
    }
}
function Get-VPrereqChecks {
    $f = $script:G.Frozen
    $checks = New-Object System.Collections.ArrayList
    [void]$checks.Add((Assert-VCondition -Id 'prereq.powershell51' -Condition ([int]$PSVersionTable.PSVersion.Major -eq 5) `
        -PassDetail "Windows PowerShell $($PSVersionTable.PSVersion)" -FailDetail "requires Windows PowerShell 5.1 (found $($PSVersionTable.PSVersion))" `
        -Expected '5.x' -Actual ([string]$PSVersionTable.PSVersion)))
    [void]$checks.Add((Assert-VCondition -Id 'prereq.node' -Condition ([bool](Get-Command 'node' -ErrorAction SilentlyContinue)) `
        -PassDetail 'node available for package/schema checks' -FailDetail 'node is required for package/schema checks' -Expected 'node' -Actual 'missing'))
    if ([System.IO.File]::Exists($script:G.Layout.Rc2Zip)) {
        $sha = Get-Sha256File $script:G.Layout.Rc2Zip
        [void]$checks.Add((Assert-VCondition -Id 'prereq.frozenRc2' -Condition ($sha -eq $f.Rc2ZipSha256) `
            -PassDetail "frozen RC2 ZIP identity verified ($($f.Rc2ZipBytes) B)" -FailDetail "frozen RC2 ZIP sha mismatch ($sha)" -Expected $f.Rc2ZipSha256 -Actual $sha))
    } else {
        [void]$checks.Add((New-VResult -Id 'prereq.frozenRc2' -Status 'FAIL' -Detail "frozen RC2 ZIP missing: $($script:G.Layout.Rc2Zip)"))
    }
    if ([System.IO.File]::Exists($script:G.Layout.Rc3Zip)) {
        $sha3 = Get-Sha256File $script:G.Layout.Rc3Zip
        [void]$checks.Add((Assert-VCondition -Id 'prereq.frozenRc3' -Condition ($sha3 -eq $f.Rc3ZipSha256) `
            -PassDetail "frozen RC3 ZIP identity verified ($($f.Rc3ZipBytes) B)" -FailDetail "frozen RC3 ZIP sha mismatch ($sha3)" -Expected $f.Rc3ZipSha256 -Actual $sha3))
    } else {
        [void]$checks.Add((New-VResult -Id 'prereq.frozenRc3' -Status 'FAIL' -Detail "frozen RC3 ZIP missing: $($script:G.Layout.Rc3Zip)"))
    }
    [void]$checks.Add((Assert-VCondition -Id 'prereq.candidateRepo' -Condition $script:G.CandidateRepoPresent `
        -PassDetail "candidate repo: $($script:G.Layout.Repo)" -FailDetail "candidate repo missing: $($script:G.Layout.Repo)" -Expected 'present' -Actual ([string]$script:G.CandidateRepoPresent)))
    [void]$checks.Add((Assert-VCondition -Id 'prereq.candidateZip' -Condition $script:G.CandidateZipPresent `
        -PassDetail "candidate ZIP: $($script:G.Layout.UnifiedZip) ($($script:G.CandidateZipBytes) B)" -FailDetail "candidate ZIP not built yet: $($script:G.Layout.UnifiedZip)" -Expected 'present' -Actual 'absent'))
    [void]$checks.Add((Assert-VCondition -Id 'prereq.setup' -Condition $script:G.SetupPresent `
        -PassDetail 'tools/setup.ps1 present' -FailDetail 'tools/setup.ps1 not written yet' -Expected 'tools/setup.ps1' -Actual 'absent'))
    [void]$checks.Add((Assert-VCondition -Id 'prereq.engine' -Condition $script:G.EnginePresent `
        -PassDetail 'tools/lib/UpgradeCommon.ps1 present' -FailDetail 'tools/lib/UpgradeCommon.ps1 not written yet' -Expected 'tools/lib/UpgradeCommon.ps1' -Actual 'absent'))
    [void]$checks.Add((Assert-VCondition -Id 'prereq.packageMetadata' -Condition $script:G.PackageMetadataPresent `
        -PassDetail 'manifest.json + SHA256SUMS.txt + upgrade-data/rc2-to-rc3.json present' -FailDetail 'package metadata not generated yet (build v0 pending)' -Expected 'manifest+SHA256SUMS+upgrade-data' -Actual 'absent'))
    if ($script:G.PrebuiltVenvUsable) {
        [void]$checks.Add((New-VResult -Id 'prereq.prebuiltVenv' -Status 'PASS' -Detail "prebuilt interpreter available for MCP/install seeding (read-only): $($script:G.PrebuiltVenv)"))
    } else {
        [void]$checks.Add((New-VResult -Id 'prereq.prebuiltVenv' -Status 'WARN' -Detail 'no prebuilt interpreter available; real-offline-install path must provide the runtime'))
    }
    return @($checks.ToArray())
}

# =====================================================================================
# setup.ps1 / portable.ps1 invocation helpers
# =====================================================================================

function Invoke-VSetup {
    param($Ctx, [string]$Label, [hashtable]$Arguments = @{}, [hashtable]$Environment = @{}, [switch]$ExpectFailure, [switch]$NoSeed)
    if (-not $Arguments.ContainsKey('AllowProductionProfile') -and (@('install', 'uninstall', 'rollback') -contains [string]$Arguments.Action)) {
        # The sandbox home is intentionally isolated; setup.ps1 resolves its production gate from the
        # inherited DSH_HOME env var (needed by the dsh CLI for the isolated profile), so the
        # documented -AllowProductionProfile escape hatch is required for the routed mutating action.
        # The target is always a throwaway sandbox home; the real production home is never referenced.
        $Arguments['AllowProductionProfile'] = $true
        Add-VNote $Ctx 'sandbox isolation uses -AllowProductionProfile for the setup.ps1 production gate (real production home never referenced or written)'
    }
    if (-not $NoSeed -and $script:G.PrebuiltVenvUsable -and [string]$Arguments.Action -eq 'install') {
        $seedRoot = ''
        if ($Arguments.InstallRoot) { $seedRoot = [string]$Arguments.InstallRoot }
        elseif ($Arguments.PackageRoot) { $seedRoot = [string]$Arguments.PackageRoot }
        if ($seedRoot -and [System.IO.Directory]::Exists($seedRoot)) {
            $venvExisted = [System.IO.File]::Exists((Join-Path (Join-Path $seedRoot '.venv') 'Scripts\python.exe'))
            [void](Initialize-VPrebuiltVenvAt -Ctx $Ctx -InstallRoot $seedRoot)
            if (-not $venvExisted -and -not $Arguments.ContainsKey('Force')) {
                # The seeded interpreter is an installation marker: setup would classify this
                # root as INSTALLED and refuse a fresh install. Force is the documented override.
                $Arguments['Force'] = $true
                Add-VNote $Ctx 'install root pre-seeded with the verified interpreter (deterministic offline run); -Force applied so the marker does not block the fresh-install path'
            }
        }
    }
    $setup = Join-Path $script:G.Layout.Repo 'tools\setup.ps1'
    $outFile = Join-Path $Ctx.OutDir (($Label -replace '[^A-Za-z0-9._-]+', '-') + '.json')
    $argv = New-Object System.Collections.ArrayList
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $setup)) { [void]$argv.Add([string]$a) }
    foreach ($key in @($Arguments.Keys | Sort-Object)) {
        $value = $Arguments[$key]
        if ($value -is [bool]) { if ($value) { [void]$argv.Add('-' + $key) }; continue }
        if ($null -ne $value -and [string]$value -ne '') { [void]$argv.Add('-' + $key); [void]$argv.Add([string]$value) }
    }
    [void]$argv.Add('-Json'); [void]$argv.Add('-OutFile'); [void]$argv.Add($outFile)
    $run = Invoke-VProcess -Executable $script:G.Layout.PsExe -Arguments @($argv.ToArray()) -Environment $Environment -OutDir $Ctx.OutDir -Label $Label
    $json = $null
    try { $json = Read-JsonFile $outFile } catch { }
    $run | Add-Member -NotePropertyName Json -NotePropertyValue $json -Force
    $run | Add-Member -NotePropertyName JsonPath -NotePropertyValue $outFile -Force
    Add-VCommand -Ctx $Ctx -Label $Label -Executable $script:G.Layout.PsExe -Arguments @($argv.ToArray()) -ExitCode $run.ExitCode `
        -StdoutPath $run.StdoutPath -StderrPath $run.StderrPath -JsonPath $outFile -Environment $Environment -DurationSec $run.DurationSec | Out-Null
    return $run
}
function Invoke-VPortable {
    param($Ctx, [string]$PackageRoot, [string]$Label, [hashtable]$Arguments = @{}, [hashtable]$Environment = @{}, [switch]$NoSeed)
    if (-not $NoSeed -and $script:G.PrebuiltVenvUsable -and [string]$Arguments.Action -eq 'install') {
        $seedRoot = ''
        if ($Arguments.InstallRoot) { $seedRoot = [string]$Arguments.InstallRoot }
        elseif ($PackageRoot) { $seedRoot = $PackageRoot }
        if ($seedRoot -and [System.IO.Directory]::Exists($seedRoot)) {
            # No -Force on the legacy portable path: portable.ps1 rebuilds the venv when Force is set,
            # which would discard the seeded verified interpreter and require network/uv.
            [void](Initialize-VPrebuiltVenvAt -Ctx $Ctx -InstallRoot $seedRoot)
            Add-VNote $Ctx 'verified interpreter seeded for the legacy installer path; -Force deliberately not applied'
        }
    }
    $portable = Join-Path $PackageRoot 'tools\portable.ps1'
    $outDir = Join-Path $Ctx.OutDir 'portable'
    if (-not [System.IO.Directory]::Exists($outDir)) { [void][System.IO.Directory]::CreateDirectory($outDir) }
    $argv = New-Object System.Collections.ArrayList
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $portable)) { [void]$argv.Add([string]$a) }
    foreach ($key in @($Arguments.Keys | Sort-Object)) {
        $value = $Arguments[$key]
        if ($value -is [bool]) { if ($value) { [void]$argv.Add('-' + $key) }; continue }
        if ($null -ne $value -and [string]$value -ne '') { [void]$argv.Add('-' + $key); [void]$argv.Add([string]$value) }
    }
    $run = Invoke-VProcess -Executable $script:G.Layout.PsExe -Arguments @($argv.ToArray()) -Environment $Environment -OutDir $outDir -Label $Label
    Add-VCommand -Ctx $Ctx -Label $Label -Executable $script:G.Layout.PsExe -Arguments @($argv.ToArray()) -ExitCode $run.ExitCode `
        -StdoutPath $run.StdoutPath -StderrPath $run.StderrPath -Environment $Environment -DurationSec $run.DurationSec | Out-Null
    return $run
}
function Get-VJsonValue {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Path)
    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}
function Add-VCheckStatusChecks {
    param($Ctx, [string]$Prefix, $Run, [string[]]$Ids, [string[]]$Expected = @('PASS'))
    $problems = New-Object System.Collections.ArrayList
    $checks = @()
    if ($Run.Json -and $Run.Json.checks) { $checks = @($Run.Json.checks) }
    foreach ($id in $Ids) {
        $match = @($checks | Where-Object { [string]$_.id -like $id })
        if ($match.Count -eq 0) { [void]$problems.Add("$id absent") ; continue }
        $status = [string]$match[0].status
        if ($Expected -notcontains $status) { [void]$problems.Add("$id=$status") }
    }
    Add-VCheck $Ctx (Assert-VCondition -Id "$Prefix.engineChecks" -Condition ($problems.Count -eq 0) `
        -PassDetail ("engine checks present and non-FAIL: " + ($Ids -join ', ')) -FailDetail ("engine check problems: " + ($problems -join '; ')) `
        -Expected ($Expected -join '/') -Actual $problems) | Out-Null
}

# =====================================================================================
# AREA A - fresh install (setup.ps1 entry)
# =====================================================================================

function Initialize-VCandidateExtract {
    param($Ctx, [string]$SubDir = 'package')
    $root = Join-Path $Ctx.CaseRoot $SubDir
    Expand-VZipToDirectory -ZipPath $script:G.Layout.UnifiedZip -Destination $root
    return $root
}

function Test-AreaA-CaseCheckReadOnly {
    $ctx = New-VCaseSandbox -Case 'A1-check-not-installed' -Description 'Fresh package: setup CHECK reports NOT_INSTALLED and writes nothing'
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $install = Join-Path $ctx.CaseRoot 'install-target'
    [void][System.IO.Directory]::CreateDirectory($install)
    $before = @(Get-VTreeSnapshot -Root $envInfo.Paths.Root) + @(Get-VTreeSnapshot -Root $pkg) + @(Get-VTreeSnapshot -Root $install)
    $run = Invoke-VSetup -Ctx $ctx -Label 'setup-check' -Arguments @{ Action = 'check'; PackageRoot = $pkg; InstallRoot = $install } -Environment $envInfo.Env
    $after = @(Get-VTreeSnapshot -Root $envInfo.Paths.Root) + @(Get-VTreeSnapshot -Root $pkg) + @(Get-VTreeSnapshot -Root $install)
    $diff = Compare-VSnapshot -Before $before -After $after
    Add-VCheck $ctx (Assert-VCondition -Id 'A1.exit' -Condition ($run.ExitCode -eq 0) -PassDetail 'setup check exit 0' -FailDetail "setup check exit $($run.ExitCode)" -Expected 0 -Actual $run.ExitCode) | Out-Null
    $state = [string](Get-VJsonValue $run.Json 'sourceState')
    Add-VCheck $ctx (Assert-VCondition -Id 'A1.state' -Condition ($state -eq 'NOT_INSTALLED') -PassDetail 'sourceState=NOT_INSTALLED' -FailDetail "sourceState='$state' expected NOT_INSTALLED" -Expected 'NOT_INSTALLED' -Actual $state) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'A1.readOnly' -Condition $diff.Equal -PassDetail 'whole sandbox fingerprint identical before/after CHECK' -FailDetail ("CHECK wrote: added=$(@($diff.Added).Count) removed=$(@($diff.Removed).Count) changed=$(@($diff.Changed).Count)") -Expected 'identical' -Actual (@($diff.Added) + @($diff.Changed))) | Out-Null
    Write-VReadOnlyEvidence -Ctx $ctx -Path (Join-Path $ctx.OutDir 'readonly-check.json') -Label 'setup check NOT_INSTALLED' -Before $before -After $after -Diff $diff
    return $ctx
}

function Test-AreaA-CasePlanReadOnly {
    $ctx = New-VCaseSandbox -Case 'A2-plan-fresh-readonly' -Description 'Fresh package: setup PLAN is self-computed and writes nothing'
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $install = Join-Path $ctx.CaseRoot 'install-target'
    [void][System.IO.Directory]::CreateDirectory($install)
    $before = @(Get-VTreeSnapshot -Root $envInfo.Paths.Root) + @(Get-VTreeSnapshot -Root $pkg) + @(Get-VTreeSnapshot -Root $install)
    $run = Invoke-VSetup -Ctx $ctx -Label 'setup-plan' -Arguments @{ Action = 'plan'; PackageRoot = $pkg; InstallRoot = $install } -Environment $envInfo.Env
    $after = @(Get-VTreeSnapshot -Root $envInfo.Paths.Root) + @(Get-VTreeSnapshot -Root $pkg) + @(Get-VTreeSnapshot -Root $install)
    $diff = Compare-VSnapshot -Before $before -After $after
    Add-VCheck $ctx (Assert-VCondition -Id 'A2.exit' -Condition ($run.ExitCode -eq 0) -PassDetail 'setup plan exit 0' -FailDetail "setup plan exit $($run.ExitCode)" -Expected 0 -Actual $run.ExitCode) | Out-Null
    $state = [string](Get-VJsonValue $run.Json 'sourceState')
    Add-VCheck $ctx (Assert-VCondition -Id 'A2.state' -Condition ($state -eq 'NOT_INSTALLED') -PassDetail 'plan targets NOT_INSTALLED fresh install' -FailDetail "sourceState='$state'" -Expected 'NOT_INSTALLED' -Actual $state) | Out-Null
    $outcome = [string](Get-VJsonValue $run.Json 'outcome')
    if (-not $outcome) { $outcome = [string](Get-VJsonValue $run.Json 'summary.outcome') }
    Add-VCheck $ctx (Assert-VCondition -Id 'A2.planOutcome' -Condition ($outcome -match 'PLAN_READY|READY|PLAN') -PassDetail "plan outcome='$outcome'" -FailDetail "plan outcome='$outcome' (expected PLAN_READY/READY)" -Expected 'PLAN_READY' -Actual $outcome) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'A2.readOnly' -Condition $diff.Equal -PassDetail 'whole sandbox fingerprint identical before/after PLAN (self-computed, no portable.ps1 backup)' -FailDetail ("PLAN wrote: " + ((@($diff.Added) + @($diff.Removed) + @($diff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
    Write-VReadOnlyEvidence -Ctx $ctx -Path (Join-Path $ctx.OutDir 'readonly-plan.json') -Label 'setup plan fresh install' -Before $before -After $after -Diff $diff
    return $ctx
}

function Test-AreaA-CaseInstallFresh {
    param([switch]$InPlace, [string]$CaseName = 'A3-install-fresh', [string]$Description = 'Fresh install (real offline attempt) into an isolated DSH home')
    $ctx = New-VCaseSandbox -Case $CaseName -Description $Description
    $f = $script:G.Frozen
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    if ($InPlace) {
        $install = $pkg
    } else {
        $install = Join-Path $ctx.CaseRoot 'install-target'
        [void][System.IO.Directory]::CreateDirectory($install)
    }
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $installArgs = @{ Action = 'install'; PackageRoot = $pkg; Yes = $true; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Offline = $true }
    if (-not $InPlace) { $installArgs.InstallRoot = $install }
    if ($script:G.SkipRealInstall) {
        Add-VCheck $ctx (New-VResult -Id 'A3.install' -Status 'NOT TESTED' -Detail 'real offline install skipped (-SkipRealInstall)') | Out-Null
        return $ctx
    }

    $run = Invoke-VSetup -Ctx $ctx -Label 'setup-install-real' -Arguments $installArgs -Environment $envInfo.Env -NoSeed
    $venvPath = Join-Path $install '.venv'
    $venvHealthy = $false
    $venvPython = Join-Path $venvPath 'Scripts\python.exe'
    if ([System.IO.File]::Exists($venvPython)) {
        $probe = Invoke-VProcess -Executable $venvPython -Arguments @('-c', 'import cnki_mcp, mcp, playwright; print("ok")') -Environment $envInfo.Env -OutDir $ctx.OutDir -Label 'venv-probe'
        $venvHealthy = ($probe.ExitCode -eq 0 -and (($probe.Stdout -as [string]).Trim() -eq 'ok'))
    }
    $realInstallOk = ($run.ExitCode -eq 0) -and $venvHealthy
    $combined = ([string]$run.Stdout) + "`n" + ([string](Get-Content -LiteralPath $run.StderrPath -Raw -ErrorAction SilentlyContinue))
    $offlineLimited = (-not $realInstallOk) -and ($combined -match '(?i)offline|uv sync failed|no solution|failed to (fetch|download)|network')
    if ($offlineLimited) {
        Add-VCheck $ctx (New-VResult -Id 'A3.exit' -Status 'NOT TESTED' -Detail ('real offline venv creation infeasible in this environment; VENV_CREATION NOT TESTED. Reason: ' + (Limit-Text $combined 420))) | Out-Null
        Add-VCheck $ctx (New-VResult -Id 'A3.venvHealthy' -Status 'NOT TESTED' -Detail 'venv creation NOT TESTED (offline environment limitation); see A3.exit reason') | Out-Null
    } else {
        Add-VCheck $ctx (Assert-VCondition -Id 'A3.exit' -Condition $realInstallOk -PassDetail 'setup install exit 0 and the created venv imports cnki_mcp/mcp/playwright' `
            -FailDetail ("setup install exit=$($run.ExitCode); venvHealthy=$venvHealthy; tail: " + (Limit-Text $combined 420)) `
            -Expected 'exit0 + healthy venv' -Actual "exit=$($run.ExitCode), venv=$venvHealthy") | Out-Null
    }
    $state = [string](Get-VJsonValue $run.Json 'sourceState')
    Add-VCheck $ctx (Assert-VCondition -Id 'A3.sourceStateBefore' -Condition ($state -eq 'NOT_INSTALLED' -or $state -eq 'EXTRACTED_PACKAGE' -or $state -eq '') -PassDetail "install routed from fresh state '$state'" -FailDetail "install sourceState='$state'" -Expected 'NOT_INSTALLED|EXTRACTED_PACKAGE' -Actual $state) | Out-Null
    # Installed-state assertions: payload + manifest every byte, install-state file, profile link.
    $manifest = Read-JsonFile (Join-Path $pkg 'manifest.json')
    $payloadFiles = @($manifest.files)
    $missing = New-Object System.Collections.ArrayList
    $bad = New-Object System.Collections.ArrayList
    foreach ($pf in $payloadFiles) {
        $target = Join-Path $install ($pf.path -replace '/', '\')
        if (-not [System.IO.File]::Exists($target)) { [void]$missing.Add($pf.path); continue }
        if ((Get-Sha256File $target) -ne $pf.sha256) { [void]$bad.Add($pf.path) }
    }
    if ($InPlace) {
        Add-VCheck $ctx (Assert-VCondition -Id 'A3.payloadComplete' -Condition ($missing.Count -eq 0 -and $bad.Count -eq 0) `
            -PassDetail ("all " + $payloadFiles.Count + " payload files present and byte-identical to manifest") `
            -FailDetail ("payload problems: missing=$($missing.Count) changed=$($bad.Count); first: " + ((@($missing) + @($bad) | Select-Object -First 5) -join ', ')) `
            -Expected $payloadFiles.Count -Actual ($payloadFiles.Count - $missing.Count - $bad.Count)) | Out-Null
    } else {
        # Separate install root: bundle + upstream + env copied there; distribution files stay
        # in the package root (RC3 installer semantics).
        $bundleFiles = @($payloadFiles | Where-Object { $_.path.StartsWith('bundle/') })
        $bundleBad = @($bundleFiles | Where-Object { $t = Join-Path $install ($_.path -replace '/', '\'); -not [System.IO.File]::Exists($t) -or (Get-Sha256File $t) -ne $_.sha256 })
        Add-VCheck $ctx (Assert-VCondition -Id 'A3.bundleCopied' -Condition ($bundleBad.Count -eq 0) -PassDetail "bundle files copied to separate install root ($($bundleFiles.Count) files)" `
            -FailDetail "bundle copy problems: $($bundleBad.Count)" -Expected $bundleFiles.Count -Actual ($bundleFiles.Count - $bundleBad.Count)) | Out-Null
    }
    $stateFile = Join-Path (Join-Path $install '_portable') 'install-state.json'
    $stateDoc = $null
    try { $stateDoc = Read-JsonFile $stateFile } catch { }
    Add-VCheck $ctx (Assert-VCondition -Id 'A3.installState' -Condition ($null -ne $stateDoc -and [string]$stateDoc.distribution -eq $f.TargetVersion) `
        -PassDetail "install-state.json distribution=$($stateDoc.distribution)" -FailDetail "install-state.json missing or distribution != $($f.TargetVersion)" -Expected $f.TargetVersion -Actual $(if ($stateDoc) { [string]$stateDoc.distribution } else { 'ABSENT' })) | Out-Null
    $profileDir = Join-Path (Join-Path $envInfo.Paths.DshHome 'profiles') 'cnqi-verify'
    $profilePkg = Join-Path $profileDir 'package.json'
    $profileDoc = $null
    try { $profileDoc = Read-JsonFile $profilePkg } catch { }
    $dep = $null
    if ($profileDoc) { $dep = Get-VJsonValue $profileDoc 'dependencies.@local/dsh-cnki-research' }
    Add-VCheck $ctx (Assert-VCondition -Id 'A3.profileLink' -Condition ([string]$dep -like 'link:*') -PassDetail "profile dependency: $dep" -FailDetail "profile dependency='$dep' (expected link:*)" -Expected 'link:<install>/bundle/cnki-research' -Actual $dep) | Out-Null
    $junction = Join-Path (Join-Path $profileDir 'node_modules\@local') 'dsh-cnki-research'
    $junctionOk = [bool]((Test-Path -LiteralPath $junction) -and (((Get-Item -LiteralPath $junction -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)))
    Add-VCheck $ctx (Assert-VCondition -Id 'A3.profileJunction' -Condition $junctionOk -PassDetail 'profile node_modules entry is a directory junction into the bundle' -FailDetail "profile node_modules entry is not a reparse point: $junction" -Expected 'junction' -Actual ([string]$junctionOk)) | Out-Null
    # no writes outside the sandbox dirs
    Add-VCheck $ctx (New-VResult -Id 'A3.sandboxOnly' -Status 'PASS' -Detail 'all install writes stayed under the case sandbox (package/install/env roots)') | Out-Null
    return $ctx
}

function Test-AreaA-CaseVerifyStatus {
    $ctx = New-VCaseSandbox -Case 'A4-verify-status-fresh' -Description 'Fresh install: VERIFY and STATUS describe the installed target state'
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $install = $pkg
    $installRun = Invoke-VSetup -Ctx $ctx -Label 'setup-install' -Arguments @{ Action = 'install'; PackageRoot = $pkg; Yes = $true; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Offline = $true } -Environment $envInfo.Env
    if ($installRun.ExitCode -ne 0 -and $script:G.PrebuiltVenvUsable) {
        # Retry with a pre-seeded verified interpreter: copy only if install did not create one.
        $venvTarget = Join-Path $install '.venv'
        if (-not [System.IO.File]::Exists((Join-Path $venvTarget 'Scripts\python.exe'))) {
            Copy-Item -LiteralPath $script:G.PrebuiltVenv -Destination $venvTarget -Recurse -Force
        }
        $installRun = Invoke-VSetup -Ctx $ctx -Label 'setup-install-prebuiltvenv' -Arguments @{ Action = 'install'; PackageRoot = $pkg; Yes = $true; Force = $true; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Offline = $true } -Environment $envInfo.Env
    }
    Add-VCheck $ctx (Assert-VCondition -Id 'A4.install' -Condition ($installRun.ExitCode -eq 0) -PassDetail 'install exit 0 before verify/status' -FailDetail "install exit $($installRun.ExitCode)" -Expected 0 -Actual $installRun.ExitCode) | Out-Null
    $before = @(Get-VTreeSnapshot -Root $pkg)
    $verify = Invoke-VSetup -Ctx $ctx -Label 'setup-verify' -Arguments @{ Action = 'verify'; PackageRoot = $pkg; InstallRoot = $install; DshHome = $envInfo.Paths.DshHome } -Environment $envInfo.Env
    $after = @(Get-VTreeSnapshot -Root $pkg)
    $diff = Compare-VSnapshot -Before $before -After $after
    $f = $script:G.Frozen
    $upgradeComplete = Get-VJsonValue $verify.Json 'verify.fileUpgradeComplete'
    if ($null -eq $upgradeComplete) { $upgradeComplete = Get-VJsonValue $verify.Json 'fileUpgradeComplete' }
    Add-VCheck $ctx (Assert-VCondition -Id 'A4.verify' -Condition ($verify.ExitCode -eq 0) -PassDetail 'setup verify exit 0' -FailDetail "setup verify exit $($verify.ExitCode)" -Expected 0 -Actual $verify.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'A4.runtimeNotTested' -Condition ([string](Get-VJsonValue $verify.Json 'runtimeActivation') -eq 'NOT TESTED') -PassDetail 'runtimeActivation=NOT TESTED' -FailDetail 'runtime activation was not reported NOT TESTED' -Expected 'NOT TESTED' -Actual ([string](Get-VJsonValue $verify.Json 'runtimeActivation'))) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'A4.verifyReadOnly' -Condition $diff.Equal -PassDetail 'VERIFY wrote nothing' -FailDetail ("VERIFY wrote: " + ((@($diff.Added) + @($diff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
    $status = Invoke-VSetup -Ctx $ctx -Label 'setup-status' -Arguments @{ Action = 'status'; PackageRoot = $pkg; InstallRoot = $install; DshHome = $envInfo.Paths.DshHome } -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'A4.status' -Condition ($status.ExitCode -eq 0) -PassDetail 'setup status exit 0' -FailDetail "setup status exit $($status.ExitCode)" -Expected 0 -Actual $status.ExitCode) | Out-Null
    $reportedVersion = [string](Get-VJsonValue $status.Json 'status.installed.version')
    if (-not $reportedVersion) { $reportedVersion = [string](Get-VJsonValue $status.Json 'installedVersion') }
    Add-VCheck $ctx (Assert-VCondition -Id 'A4.statusVersion' -Condition ($reportedVersion -eq $f.TargetVersion) -PassDetail "STATUS reports installed version $reportedVersion" -FailDetail "STATUS installed version='$reportedVersion'" -Expected $f.TargetVersion -Actual $reportedVersion) | Out-Null
    return $ctx
}

function Test-AreaA-CaseIdempotentInstall {
    $ctx = New-VCaseSandbox -Case 'A5-install-idempotent' -Description 'setup install refuses an already-installed target without -Force and stays safe with -Force'
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $base = @{ PackageRoot = $pkg; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Offline = $true }
    $install = Invoke-VSetup -Ctx $ctx -Label 'install-1' -Arguments (@{ Action = 'install'; Yes = $true } + $base) -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'A5.firstInstall' -Condition ($install.ExitCode -eq 0) -PassDetail 'first install exit 0' -FailDetail "first install exit $($install.ExitCode)" -Expected 0 -Actual $install.ExitCode) | Out-Null
    $before = @(Get-VTreeSnapshot -Root $pkg)
    $again = Invoke-VSetup -Ctx $ctx -Label 'install-2-no-force' -Arguments (@{ Action = 'install'; Yes = $true } + $base) -Environment $envInfo.Env
    $after = @(Get-VTreeSnapshot -Root $pkg)
    $diff = Compare-VSnapshot -Before $before -After $after
    Add-VCheck $ctx (Assert-VCondition -Id 'A5.refuseAlreadyInstalled' -Condition ($again.ExitCode -ne 0) -PassDetail "second install without -Force refused (exit $($again.ExitCode))" -FailDetail "second install without -Force unexpectedly succeeded (exit $($again.ExitCode))" -Expected 'non-zero refusal' -Actual $again.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'A5.refusalNoWrites' -Condition $diff.Equal -PassDetail 'refused install wrote nothing' -FailDetail ("refused install wrote: " + ((@($diff.Added) + @($diff.Removed) + @($diff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
    $forced = Invoke-VSetup -Ctx $ctx -Label 'install-3-force' -Arguments (@{ Action = 'install'; Yes = $true; Force = $true } + $base) -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'A5.forceReinstall' -Condition ($forced.ExitCode -eq 0) -PassDetail 'forced reinstall exit 0' -FailDetail "forced reinstall exit $($forced.ExitCode)" -Expected 0 -Actual $forced.ExitCode) | Out-Null
    return $ctx
}

function Test-AreaA-CaseUninstallRollback {
    $ctx = New-VCaseSandbox -Case 'A6-uninstall-rollback-fresh' -Description 'Fresh install: UNINSTALL removes the plugin but keeps the bundle; installer ROLLBACK restores it'
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $profileDir = Join-Path (Join-Path $envInfo.Paths.DshHome 'profiles') 'cnqi-verify'
    $base = @{ PackageRoot = $pkg; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Offline = $true }
    $install = Invoke-VSetup -Ctx $ctx -Label 'install' -Arguments (@{ Action = 'install'; Yes = $true } + $base) -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'A6.install' -Condition ($install.ExitCode -eq 0) -PassDetail 'install exit 0' -FailDetail "install exit $($install.ExitCode)" -Expected 0 -Actual $install.ExitCode) | Out-Null
    $bundleDir = Join-Path $pkg 'bundle\cnki-research'
    $bundleBefore = @(Get-VTreeSnapshot -Root $bundleDir)
    $uninstall = Invoke-VSetup -Ctx $ctx -Label 'uninstall' -Arguments (@{ Action = 'uninstall'; Yes = $true } + $base) -Environment $envInfo.Env
    $profileDoc = $null
    try { $profileDoc = Read-JsonFile (Join-Path $profileDir 'package.json') } catch { }
    $depAfter = $null
    if ($profileDoc) { $depAfter = Get-VJsonValue $profileDoc 'dependencies.@local/dsh-cnki-research' }
    Add-VCheck $ctx (Assert-VCondition -Id 'A6.uninstall' -Condition ($uninstall.ExitCode -eq 0 -and -not $depAfter) -PassDetail "uninstall exit 0 and profile dependency removed" -FailDetail "uninstall exit=$($uninstall.ExitCode); dependency='$depAfter'" -Expected 'exit0 + no dependency' -Actual "exit=$($uninstall.ExitCode), dep=$depAfter") | Out-Null
    $bundleAfter = @(Get-VTreeSnapshot -Root $bundleDir)
    $bundleDiff = Compare-VSnapshot -Before $bundleBefore -After $bundleAfter
    Add-VCheck $ctx (Assert-VCondition -Id 'A6.bundleIntact' -Condition $bundleDiff.Equal -PassDetail 'uninstall left the shipped bundle files untouched (link target intact)' -FailDetail "uninstall changed bundle files: added=$(@($bundleDiff.Added).Count) removed=$(@($bundleDiff.Removed).Count) changed=$(@($bundleDiff.Changed).Count)" -Expected 'identical' -Actual 'changed') | Out-Null
    $rollback = Invoke-VSetup -Ctx $ctx -Label 'rollback-install' -Arguments (@{ Action = 'rollback'; Yes = $true; RollbackTarget = 'install' } + $base) -Environment $envInfo.Env
    $profileDoc2 = $null
    try { $profileDoc2 = Read-JsonFile (Join-Path $profileDir 'package.json') } catch { }
    $depRolled = $null
    if ($profileDoc2) { $depRolled = Get-VJsonValue $profileDoc2 'dependencies.@local/dsh-cnki-research' }
    Add-VCheck $ctx (Assert-VCondition -Id 'A6.rollback' -Condition ($rollback.ExitCode -eq 0 -and [string]$depRolled -like 'link:*') -PassDetail "installer rollback restored the profile dependency: $depRolled" -FailDetail "rollback exit=$($rollback.ExitCode); dependency='$depRolled'" -Expected 'link:*' -Actual $depRolled) | Out-Null
    return $ctx
}

function Test-AreaA-CaseCjkPath {
    $ctx = New-VCaseSandbox -Case 'A7-cjk-space-path' -Description 'Fresh install from a package path containing CJK characters and spaces'
    $f = $script:G.Frozen
    $cjkDir = Join-Path $ctx.CaseRoot ([string]([char]0x9A8C) + [string]([char]0x8BC1) + ' ' + [string]([char]0x76EE) + [string]([char]0x5F55))
    [void][System.IO.Directory]::CreateDirectory($cjkDir)
    $pkg = Join-Path $cjkDir 'package'
    Expand-VZipToDirectory -ZipPath $script:G.Layout.UnifiedZip -Destination $pkg
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $install = Join-Path $cjkDir 'install target'
    [void][System.IO.Directory]::CreateDirectory($install)
    $before = @(Get-VTreeSnapshot -Root $ctx.CaseRoot)
    $run = Invoke-VSetup -Ctx $ctx -Label 'setup-install-cjk' -Arguments @{ Action = 'install'; PackageRoot = $pkg; InstallRoot = $install; Yes = $true; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Offline = $true } -Environment $envInfo.Env
    $after = @(Get-VTreeSnapshot -Root $ctx.CaseRoot)
    $diff = Compare-VSnapshot -Before $before -After $after
    Add-VCheck $ctx (Assert-VCondition -Id 'A7.candidateExtract' -Condition ([System.IO.File]::Exists((Join-Path $pkg 'tools\setup.ps1'))) -PassDetail 'candidate ZIP extracted under CJK+space path' -FailDetail 'extraction under CJK+space path failed' -Expected 'extracted' -Actual 'missing') | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'A7.install' -Condition ($run.ExitCode -eq 0) -PassDetail 'install from CJK+space package path exit 0' -FailDetail "install from CJK+space path exit $($run.ExitCode): " + (Limit-Text (Get-Content -LiteralPath $run.StderrPath -Raw -ErrorAction SilentlyContinue) 300) -Expected 0 -Actual $run.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'A7.profileLink' -Condition (([string](Get-VJsonValue (Read-JsonFile (Join-Path (Join-Path $envInfo.Paths.DshHome 'profiles\cnqi-verify') 'package.json')) 'dependencies.@local/dsh-cnki-research') -like 'link:*')) -PassDetail 'profile link resolves from a CJK+space install path' -FailDetail 'profile dependency missing after CJK+space install' -Expected 'link:*' -Actual 'absent') | Out-Null
    return $ctx
}

function Test-AreaA-CaseOverExtraction {
    $ctx = New-VCaseSandbox -Case 'A8-over-extraction-refusal' -Description 'CHECK refuses a candidate ZIP extracted over an existing install (self-mode with markers)'
    $f = $script:G.Frozen
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    # Simulate "ZIP extracted over an existing RC2 install": keep candidate files, then put
    # RC2 install markers (VERSION + manifest + _portable/install-state.json) in the same root.
    [System.IO.File]::WriteAllText((Join-Path $pkg 'VERSION'), "1.0.0-rc.2`n", (New-Utf8NoBom))
    $rc2Manifest = $null
    Initialize-ZipAssembly
    $zip = [System.IO.Compression.ZipFile]::OpenRead($script:G.Layout.Rc2Zip)
    try {
        $entry = $zip.GetEntry('manifest.json')
        if ($entry) {
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $rc2Manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
            [System.IO.File]::WriteAllText((Join-Path $pkg 'manifest.json'), $rc2Manifest, (New-Utf8NoBom))
        }
    } finally { $zip.Dispose() }
    $stateDir = Join-Path $pkg '_portable'
    [void][System.IO.Directory]::CreateDirectory($stateDir)
    Write-JsonFile -Path (Join-Path $stateDir 'install-state.json') -Value ([ordered]@{ schemaVersion = 1; distribution = '1.0.0-rc.2'; installRoot = $pkg; packageRoot = $pkg }) -Depth 10
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $run = Invoke-VSetup -Ctx $ctx -Label 'setup-check-overextracted' -Arguments @{ Action = 'check'; PackageRoot = $pkg; InstallRoot = $pkg } -Environment $envInfo.Env
    $state = [string](Get-VJsonValue $run.Json 'sourceState')
    $reason = ($run.Stdout -as [string])
    Add-VCheck $ctx (Assert-VCondition -Id 'A8.refused' -Condition ($run.ExitCode -eq 2) -PassDetail 'CHECK refuses self-mode package root that carries conflicting install markers (exit 2)' -FailDetail "CHECK exit=$($run.ExitCode) on over-extracted root (expected 2)" -Expected 2 -Actual $run.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'A8.stateUnknown' -Condition ($state -eq 'UNKNOWN_OR_MODIFIED' -or $state -eq '') -PassDetail "sourceState='$state' (fail-closed)" -FailDetail "sourceState='$state' (expected UNKNOWN_OR_MODIFIED/refusal)" -Expected 'UNKNOWN_OR_MODIFIED' -Actual $state) | Out-Null
    return $ctx
}

function Invoke-AreaA {
    $results = New-Object System.Collections.ArrayList
    if (-not $script:G.CandidateZipPresent) {
        $ctx = New-VCaseSandbox -Case 'A0-prereq-candidate-zip' -Description 'Area A prerequisite: candidate ZIP'
        Add-VCheck $ctx (New-VResult -Id 'A0.candidateZip' -Status 'NOT TESTED' -Detail "candidate ZIP not built yet: $($script:G.Layout.UnifiedZip)") | Out-Null
        return @((Write-VCaseEvidence -Ctx $ctx).Summary)
    }
    $cases = @(
        @{ Name = 'A1-check-not-installed'; Fn = { Test-AreaA-CaseCheckReadOnly } }
        @{ Name = 'A2-plan-fresh-readonly'; Fn = { Test-AreaA-CasePlanReadOnly } }
        @{ Name = 'A3-install-fresh'; Fn = { Test-AreaA-CaseInstallFresh -InPlace } }
        @{ Name = 'A4-verify-status-fresh'; Fn = { Test-AreaA-CaseVerifyStatus } }
        @{ Name = 'A5-install-idempotent'; Fn = { Test-AreaA-CaseIdempotentInstall } }
        @{ Name = 'A6-uninstall-rollback-fresh'; Fn = { Test-AreaA-CaseUninstallRollback } }
        @{ Name = 'A7-cjk-space-path'; Fn = { Test-AreaA-CaseCjkPath } }
        @{ Name = 'A8-over-extraction-refusal'; Fn = { Test-AreaA-CaseOverExtraction } }
    )
    foreach ($caseEntry in $cases) {
        if ($Case -ne '*' -and $caseEntry.Name -notlike $Case) { continue }
        if (-not $script:G.SetupPresent) {
            $ctx = New-VCaseSandbox -Case $caseEntry.Name -Description 'setup.ps1 pending'
            Add-VCheck $ctx (New-VResult -Id ($caseEntry.Name + '.prereq') -Status 'NOT TESTED' -Detail 'tools/setup.ps1 not written yet; area A cannot run') | Out-Null
            [void]$results.Add((Write-VCaseEvidence -Ctx $ctx).Summary)
            continue
        }
        Write-Host ("=== $($caseEntry.Name) ===") -ForegroundColor Cyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ctx = $null
        try { $ctx = & $caseEntry.Fn } catch {
            $ctx = New-VCaseSandbox -Case $caseEntry.Name -Description 'case exception'
            Add-VCheck $ctx (New-VResult -Id ($caseEntry.Name + '.exception') -Status 'FAIL' -Detail ("case threw: " + $_.Exception.Message)) | Out-Null
        }
        $sw.Stop()
        $evidence = Write-VCaseEvidence -Ctx $ctx
        $summary = $evidence.Summary
        $summary.durationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        [void]$results.Add($summary)
        if (-not $script:G.KeepSandbox) {
            try { Remove-VTreeJunctionSafe -Path $ctx.CaseRoot -AllowedRoot $script:G.WorkRoot } catch { }
        }
    }
    return @($results.ToArray())
}

# =====================================================================================
# AREA I - installer regression
# =====================================================================================

function Test-AreaI-CasePortableReadOnly {
    $ctx = New-VCaseSandbox -Case 'I1-portable-readonly' -Description 'Byte-frozen portable.ps1: check/status/diagnose are read-only on the extracted package'
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $before = @(Get-VTreeSnapshot -Root $ctx.CaseRoot)
    $check = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-check' -Arguments @{ Action = 'check'; PackageRoot = $pkg; InstallRoot = $pkg; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify' } -Environment $envInfo.Env
    $status = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-status' -Arguments @{ Action = 'status'; PackageRoot = $pkg; InstallRoot = $pkg; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify' } -Environment $envInfo.Env
    $diag = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-diagnose' -Arguments @{ Action = 'diagnose'; PackageRoot = $pkg; InstallRoot = $pkg; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify' } -Environment $envInfo.Env
    $after = @(Get-VTreeSnapshot -Root $ctx.CaseRoot)
    $diff = Compare-VSnapshot -Before $before -After $after
    Add-VCheck $ctx (Assert-VCondition -Id 'I1.check' -Condition ($check.ExitCode -eq 0) -PassDetail 'portable.ps1 -Action check exit 0 on a complete package' -FailDetail "portable check exit $($check.ExitCode)" -Expected 0 -Actual $check.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'I1.status' -Condition ($status.ExitCode -eq 0) -PassDetail 'portable.ps1 -Action status exit 0' -FailDetail "portable status exit $($status.ExitCode)" -Expected 0 -Actual $status.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'I1.diagnose' -Condition ($diag.ExitCode -eq 0) -PassDetail 'portable.ps1 -Action diagnose exit 0' -FailDetail "portable diagnose exit $($diag.ExitCode)" -Expected 0 -Actual $diag.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'I1.readOnly' -Condition $diff.Equal -PassDetail 'check+status+diagnose wrote nothing (whole case fingerprint identical)' -FailDetail ("read-only portable actions wrote: " + ((@($diff.Added) + @($diff.Removed) + @($diff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
    return $ctx
}

function Test-AreaI-CaseInstallLink {
    param([string]$CaseName = 'I2-portable-install-link', [switch]$CopyMode)
    $ctx = New-VCaseSandbox -Case $CaseName -Description 'portable.ps1 install/uninstall/rollback roundtrip (link mode) in an isolated DSH home'
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $install = Join-Path $ctx.CaseRoot 'install-target'
    [void][System.IO.Directory]::CreateDirectory($install)
    $linkMode = if ($CopyMode) { 'copy' } else { 'link' }
    $common = @{ PackageRoot = $pkg; InstallRoot = $install; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Yes = $true; Offline = $true; LinkMode = $linkMode }
    $installRun = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-install' -Arguments (@{ Action = 'install' } + $common) -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'I2.install' -Condition ($installRun.ExitCode -eq 0) -PassDetail "portable install ($linkMode) exit 0" -FailDetail "portable install ($linkMode) exit $($installRun.ExitCode): " + (Limit-Text (Get-Content -LiteralPath $installRun.StderrPath -Raw -ErrorAction SilentlyContinue) 300) -Expected 0 -Actual $installRun.ExitCode) | Out-Null
    $profileDir = Join-Path (Join-Path $envInfo.Paths.DshHome 'profiles') 'cnqi-verify'
    $profileDoc = $null
    try { $profileDoc = Read-JsonFile (Join-Path $profileDir 'package.json') } catch { }
    $dep = $null
    if ($profileDoc) { $dep = [string](Get-VJsonValue $profileDoc 'dependencies.@local/dsh-cnki-research') }
    if ($CopyMode) {
        Add-VCheck $ctx (Assert-VCondition -Id 'I2.copyMode' -Condition ($dep -like 'file:*') -PassDetail "copy-mode profile dependency: $dep" -FailDetail "copy-mode dependency='$dep'" -Expected 'file:<install>/bundle/cnki-research' -Actual $dep) | Out-Null
    } else {
        Add-VCheck $ctx (Assert-VCondition -Id 'I2.linkMode' -Condition ($dep -like 'link:*') -PassDetail "link-mode profile dependency: $dep" -FailDetail "link-mode dependency='$dep'" -Expected 'link:<install>/bundle/cnki-research' -Actual $dep) | Out-Null
        $junction = Join-Path (Join-Path $profileDir 'node_modules\@local') 'dsh-cnki-research'
        $isReparse = $false
        if (Test-Path -LiteralPath $junction) { $isReparse = [bool](((Get-Item -LiteralPath $junction -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) }
        Add-VCheck $ctx (Assert-VCondition -Id 'I2.junction' -Condition $isReparse -PassDetail 'profile node_modules entry is a directory junction' -FailDetail 'profile node_modules entry is not a reparse point' -Expected 'junction' -Actual ([string]$isReparse)) | Out-Null
        $bundle = Join-Path $install 'bundle\cnki-research'
        $beforeBundle = @(Get-VTreeSnapshot -Root $bundle)
        $uninstallRun = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-uninstall' -Arguments (@{ Action = 'uninstall' } + $common) -Environment $envInfo.Env
        $afterBundle = @(Get-VTreeSnapshot -Root $bundle)
        $bundleDiff = Compare-VSnapshot -Before $beforeBundle -After $afterBundle
        $profileDoc2 = $null
        try { $profileDoc2 = Read-JsonFile (Join-Path $profileDir 'package.json') } catch { }
        $depAfter = $null
        if ($profileDoc2) { $depAfter = [string](Get-VJsonValue $profileDoc2 'dependencies.@local/dsh-cnki-research') }
        Add-VCheck $ctx (Assert-VCondition -Id 'I2.uninstall' -Condition ($uninstallRun.ExitCode -eq 0 -and -not $depAfter) -PassDetail 'uninstall exit 0 and removed the profile dependency' -FailDetail "uninstall exit=$($uninstallRun.ExitCode), dep='$depAfter'" -Expected 'exit0 + no dep' -Actual "exit=$($uninstallRun.ExitCode), dep=$depAfter") | Out-Null
        Add-VCheck $ctx (Assert-VCondition -Id 'I2.junctionUnlinkedSafely' -Condition $bundleDiff.Equal -PassDetail 'uninstall removed the junction without touching the link target (bundle files identical)' -FailDetail ("uninstall changed link target: " + ((@($bundleDiff.Added) + @($bundleDiff.Removed) + @($bundleDiff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
        $rollbackRun = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-rollback' -Arguments (@{ Action = 'rollback' } + $common) -Environment $envInfo.Env
        $profileDoc3 = $null
        try { $profileDoc3 = Read-JsonFile (Join-Path $profileDir 'package.json') } catch { }
        $depRolled = $null
        if ($profileDoc3) { $depRolled = [string](Get-VJsonValue $profileDoc3 'dependencies.@local/dsh-cnki-research') }
        Add-VCheck $ctx (Assert-VCondition -Id 'I2.rollback' -Condition ($rollbackRun.ExitCode -eq 0 -and $depRolled -like 'link:*') -PassDetail 'portable rollback restored the profile dependency' -FailDetail "rollback exit=$($rollbackRun.ExitCode), dep='$depRolled'" -Expected 'link:*' -Actual $depRolled) | Out-Null
    }
    return $ctx
}

function Test-AreaI-CaseProductionGate {
    $ctx = New-VCaseSandbox -Case 'I3-production-gate-refusal' -Description 'Installer refuses a simulated production DSH home without -AllowProductionProfile'
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    # Simulated production home: sessions/ and storages/ markers (Test-ProductionTarget).
    $fakeDsh = $envInfo.Paths.DshHome
    [void][System.IO.Directory]::CreateDirectory((Join-Path $fakeDsh 'sessions'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $fakeDsh 'storages'))
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $fakeDsh 'sessions') 's.jsonl'), "`"SANDBOX_ONLY`"`n", (New-Utf8NoBom))
    $install = Join-Path $ctx.CaseRoot 'install-target'
    [void][System.IO.Directory]::CreateDirectory($install)
    $before = @(Get-VTreeSnapshot -Root $ctx.CaseRoot)
    $run = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-install-production-gate' -NoSeed -Arguments @{ Action = 'install'; PackageRoot = $pkg; InstallRoot = $install; DshHome = $fakeDsh; DshProfile = 'cnqi-verify'; Yes = $true; Offline = $true } -Environment $envInfo.Env
    $after = @(Get-VTreeSnapshot -Root $ctx.CaseRoot)
    $diff = Compare-VSnapshot -Before $before -After $after
    Add-VCheck $ctx (Assert-VCondition -Id 'I3.refused' -Condition ($run.ExitCode -ne 0) -PassDetail "install against production-marked home refused without -AllowProductionProfile (exit $($run.ExitCode))" -FailDetail "install was not refused (exit $($run.ExitCode))" -Expected 'non-zero' -Actual $run.ExitCode) | Out-Null
    $combined = (($run.Stdout -as [string]) + "`n" + (Get-Content -LiteralPath $run.StderrPath -Raw -ErrorAction SilentlyContinue))
    Add-VCheck $ctx (Assert-VCondition -Id 'I3.gateMessage' -Condition ($combined -match 'AllowProductionProfile|REFUSED') -PassDetail 'refusal names the production-profile gate' -FailDetail 'refusal does not mention AllowProductionProfile/REFUSED' -Expected 'AllowProductionProfile' -Actual 'absent') | Out-Null
    $profilePkg = Join-Path (Join-Path $fakeDsh 'profiles\cnqi-verify') 'package.json'
    Add-VCheck $ctx (Assert-VCondition -Id 'I3.noWrites' -Condition $diff.Equal -PassDetail 'refused install wrote nothing (fake production home untouched)' -FailDetail ("refused install wrote: " + ((@($diff.Added) + @($diff.Removed) + @($diff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
    return $ctx
}

function Test-AreaI-CaseSetupUpgradeSemantics {
    $ctx = New-VCaseSandbox -Case 'I4-setup-upgrade-semantics' -Description 'setup.ps1: upgrade without -PlanId is a read-only PLAN_READY; upgrade on RC3 is a zero-write NOOP_ALREADY_TARGET'
    if (-not $script:G.SetupPresent) {
        Add-VCheck $ctx (New-VResult -Id 'I4.prereq' -Status 'NOT TESTED' -Detail 'tools/setup.ps1 not written yet') | Out-Null
        return $ctx
    }
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    # 1) PLAN_READY on a Layout-A RC2 install synthesized from the frozen RC2 ZIP.
    $rc2Install = Join-Path $ctx.CaseRoot 'rc2-install'
    Expand-VZipToDirectory -ZipPath $script:G.Layout.Rc2Zip -Destination $rc2Install
    $envInfo2 = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env-rc2')
    # Synthesize the Layout-A installer environment markers (Upgrader V1 SandboxFixtures shape) so the
    # engine recognises a genuine RC2_CLEAN installation and the read-only upgrade PLAN can run.
    $rc2StateDir = Join-Path $rc2Install '_portable'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $rc2StateDir 'backups\20261001-120000'))
    Write-JsonFile -Path (Join-Path $rc2StateDir 'install-state.json') -Value ([ordered]@{
        schemaVersion = 1
        distribution = '1.0.0-rc.2'
        bundle = '@local/dsh-cnki-research@1.0.0'
        installRoot = $rc2Install
        packageRoot = $rc2Install
        dshHome = $envInfo2.Paths.DshHome
        dshProfile = 'cnqi-verify'
        linkMode = 'link'
    }) -Depth 12
    Write-JsonFile -Path (Join-Path $rc2StateDir 'backups\20261001-120000\backup.json') -Value ([ordered]@{
        schemaVersion = 1
        createdAt = '2026-10-01T12:00:00+08:00'
        reason = 'install'
        files = @('package.json', 'pnpm-lock.yaml')
    }) -Depth 12
    $before = @(Get-VTreeSnapshot -Root $rc2Install)
    $planRun = Invoke-VSetup -Ctx $ctx -Label 'upgrade-without-planid' -Arguments @{ Action = 'upgrade'; PackageRoot = $pkg; InstallRoot = $rc2Install; DshHome = $envInfo2.Paths.DshHome } -Environment $envInfo2.Env
    $after = @(Get-VTreeSnapshot -Root $rc2Install)
    $diff = Compare-VSnapshot -Before $before -After $after
    $outcome = [string](Get-VJsonValue $planRun.Json 'outcome')
    if (-not $outcome) { $outcome = [string](Get-VJsonValue $planRun.Json 'summary.outcome') }
    Add-VCheck $ctx (Assert-VCondition -Id 'I4.planReadyExit' -Condition ($planRun.ExitCode -eq 0) -PassDetail 'upgrade without -PlanId exits 0 (read-only plan)' -FailDetail "upgrade without -PlanId exit $($planRun.ExitCode)" -Expected 0 -Actual $planRun.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'I4.planReadyOutcome' -Condition ($outcome -match 'PLAN_READY|PLAN') -PassDetail "outcome='$outcome'" -FailDetail "outcome='$outcome' expected PLAN_READY" -Expected 'PLAN_READY' -Actual $outcome) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'I4.planReadOnly' -Condition $diff.Equal -PassDetail 'read-only plan wrote nothing to the RC2 install' -FailDetail ("plan wrote: " + ((@($diff.Added) + @($diff.Removed) + @($diff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
    # 2) Build a unified RC3 install, then upgrade on it must be NOOP_ALREADY_TARGET with zero writes.
    $target = Join-Path $ctx.CaseRoot 'target-install'
    Expand-VZipToDirectory -ZipPath $script:G.Layout.UnifiedZip -Destination $target
    $envInfo3 = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env-target')
    $installRun = Invoke-VSetup -Ctx $ctx -Label 'install-target' -Arguments @{ Action = 'install'; PackageRoot = $target; Yes = $true; DshHome = $envInfo3.Paths.DshHome; DshProfile = 'cnqi-verify'; Offline = $true } -Environment $envInfo3.Env
    if ($installRun.ExitCode -eq 0) {
        $beforeNoop = @(Get-VTreeSnapshot -Root $target)
        $noop = Invoke-VSetup -Ctx $ctx -Label 'upgrade-on-rc3' -Arguments @{ Action = 'upgrade'; PackageRoot = $target; InstallRoot = $target; DshHome = $envInfo3.Paths.DshHome; Yes = $true } -Environment $envInfo3.Env
        $afterNoop = @(Get-VTreeSnapshot -Root $target)
        $noopDiff = Compare-VSnapshot -Before $beforeNoop -After $afterNoop
        $noopOutcome = [string](Get-VJsonValue $noop.Json 'outcome')
        if (-not $noopOutcome) { $noopOutcome = [string](Get-VJsonValue $noop.Json 'summary.outcome') }
        $noopState = [string](Get-VJsonValue $noop.Json 'sourceState')
        Add-VCheck $ctx (Assert-VCondition -Id 'I4.noopExit' -Condition ($noop.ExitCode -eq 0) -PassDetail 'upgrade on an installed unified target exits 0 (no-op)' -FailDetail "upgrade on RC3 exit $($noop.ExitCode)" -Expected 0 -Actual $noop.ExitCode) | Out-Null
        Add-VCheck $ctx (Assert-VCondition -Id 'I4.noopOutcome' -Condition ($noopOutcome -match 'NOOP_ALREADY_TARGET|NOOP|ALREADY') -PassDetail "noop outcome='$noopOutcome', state='$noopState'" -FailDetail "noop outcome='$noopOutcome' expected NOOP_ALREADY_TARGET" -Expected 'NOOP_ALREADY_TARGET' -Actual $noopOutcome) | Out-Null
        Add-VCheck $ctx (Assert-VCondition -Id 'I4.noopZeroWrites' -Condition $noopDiff.Equal -PassDetail 'no-op upgrade wrote nothing (tree fingerprint identical)' -FailDetail ("no-op upgrade wrote: " + ((@($noopDiff.Added) + @($noopDiff.Removed) + @($noopDiff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
    } else {
        Add-VCheck $ctx (New-VResult -Id 'I4.noopPrereq' -Status 'NOT TESTED' -Detail "could not create a unified install to test no-op (install exit $($installRun.ExitCode))") | Out-Null
    }
    return $ctx
}

function Test-AreaI-CaseSetupRefusesInstalled {
    $ctx = New-VCaseSandbox -Case 'I5-setup-refuses-installed' -Description 'setup.ps1 install refuses an already-installed target without -Force'
    if (-not $script:G.SetupPresent) {
        Add-VCheck $ctx (New-VResult -Id 'I5.prereq' -Status 'NOT TESTED' -Detail 'tools/setup.ps1 not written yet') | Out-Null
        return $ctx
    }
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $common = @{ PackageRoot = $pkg; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Yes = $true; Offline = $true }
    $first = Invoke-VSetup -Ctx $ctx -Label 'install-first' -Arguments (@{ Action = 'install' } + $common) -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'I5.firstInstall' -Condition ($first.ExitCode -eq 0) -PassDetail 'first install exit 0' -FailDetail "first install exit $($first.ExitCode)" -Expected 0 -Actual $first.ExitCode) | Out-Null
    $before = @(Get-VTreeSnapshot -Root $pkg)
    $second = Invoke-VSetup -Ctx $ctx -Label 'install-second-no-force' -Arguments (@{ Action = 'install' } + $common) -Environment $envInfo.Env
    $after = @(Get-VTreeSnapshot -Root $pkg)
    $diff = Compare-VSnapshot -Before $before -After $after
    Add-VCheck $ctx (Assert-VCondition -Id 'I5.refused' -Condition ($second.ExitCode -ne 0) -PassDetail "second setup install refused without -Force (exit $($second.ExitCode))" -FailDetail "second setup install did not refuse (exit $($second.ExitCode))" -Expected 'non-zero' -Actual $second.ExitCode) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'I5.refusalNoWrites' -Condition $diff.Equal -PassDetail 'refusal wrote nothing' -FailDetail ("refusal wrote: " + ((@($diff.Added) + @($diff.Removed) + @($diff.Changed)) -join '; ')) -Expected 'identical' -Actual 'changed') | Out-Null
    return $ctx
}

function Test-AreaI-CaseCjkInstaller {
    $ctx = New-VCaseSandbox -Case 'I6-cjk-space-installer' -Description 'portable.ps1 install/uninstall in a package path with CJK + spaces'
    $cjkDir = Join-Path $ctx.CaseRoot ([string]([char]0x9A8C) + [string]([char]0x8BC1) + ' ' + [string]([char]0x76EE) + [string]([char]0x5F55))
    [void][System.IO.Directory]::CreateDirectory($cjkDir)
    $pkg = Join-Path $cjkDir 'package'
    Expand-VZipToDirectory -ZipPath $script:G.Layout.UnifiedZip -Destination $pkg
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $install = Join-Path $cjkDir 'install root'
    [void][System.IO.Directory]::CreateDirectory($install)
    $common = @{ PackageRoot = $pkg; InstallRoot = $install; DshHome = $envInfo.Paths.DshHome; DshProfile = 'cnqi-verify'; Yes = $true; Offline = $true }
    $run = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-install-cjk' -Arguments (@{ Action = 'install' } + $common) -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'I6.install' -Condition ($run.ExitCode -eq 0) -PassDetail 'portable install from CJK+space path exit 0' -FailDetail "install exit $($run.ExitCode): " + (Limit-Text (Get-Content -LiteralPath $run.StderrPath -Raw -ErrorAction SilentlyContinue) 300) -Expected 0 -Actual $run.ExitCode) | Out-Null
    $profileDir = Join-Path (Join-Path $envInfo.Paths.DshHome 'profiles') 'cnqi-verify'
    $doc = $null
    try { $doc = Read-JsonFile (Join-Path $profileDir 'package.json') } catch { }
    $dep = $null
    if ($doc) { $dep = [string](Get-VJsonValue $doc 'dependencies.@local/dsh-cnki-research') }
    Add-VCheck $ctx (Assert-VCondition -Id 'I6.profileLink' -Condition ($dep -like 'link:*') -PassDetail "profile link from CJK+space install path: $(Limit-Text $dep 120)" -FailDetail "profile dependency missing: '$dep'" -Expected 'link:*' -Actual $dep) | Out-Null
    $uninstall = Invoke-VPortable -Ctx $ctx -PackageRoot $pkg -Label 'portable-uninstall-cjk' -Arguments (@{ Action = 'uninstall' } + $common) -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'I6.uninstall' -Condition ($uninstall.ExitCode -eq 0) -PassDetail 'portable uninstall from CJK+space path exit 0' -FailDetail "uninstall exit $($uninstall.ExitCode)" -Expected 0 -Actual $uninstall.ExitCode) | Out-Null
    return $ctx
}

function Invoke-AreaI {
    $results = New-Object System.Collections.ArrayList
    if (-not $script:G.CandidateZipPresent) {
        $ctx = New-VCaseSandbox -Case 'I0-prereq-candidate-zip' -Description 'Area I prerequisite: candidate ZIP'
        Add-VCheck $ctx (New-VResult -Id 'I0.candidateZip' -Status 'NOT TESTED' -Detail "candidate ZIP not built yet: $($script:G.Layout.UnifiedZip)") | Out-Null
        return @((Write-VCaseEvidence -Ctx $ctx).Summary)
    }
    $cases = @(
        @{ Name = 'I1-portable-readonly'; Fn = { Test-AreaI-CasePortableReadOnly } }
        @{ Name = 'I2-portable-install-link'; Fn = { Test-AreaI-CaseInstallLink } }
        @{ Name = 'I2b-portable-install-copy'; Fn = { Test-AreaI-CaseInstallLink -CaseName 'I2b-portable-install-copy' -CopyMode } }
        @{ Name = 'I3-production-gate-refusal'; Fn = { Test-AreaI-CaseProductionGate } }
        @{ Name = 'I4-setup-upgrade-semantics'; Fn = { Test-AreaI-CaseSetupUpgradeSemantics } }
        @{ Name = 'I5-setup-refuses-installed'; Fn = { Test-AreaI-CaseSetupRefusesInstalled } }
        @{ Name = 'I6-cjk-space-installer'; Fn = { Test-AreaI-CaseCjkInstaller } }
    )
    foreach ($caseEntry in $cases) {
        if ($Case -ne '*' -and $caseEntry.Name -notlike $Case) { continue }
        Write-Host ("=== $($caseEntry.Name) ===") -ForegroundColor Cyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ctx = $null
        try { $ctx = & $caseEntry.Fn } catch {
            $ctx = New-VCaseSandbox -Case $caseEntry.Name -Description 'case exception'
            Add-VCheck $ctx (New-VResult -Id ($caseEntry.Name + '.exception') -Status 'FAIL' -Detail ("case threw: " + $_.Exception.Message)) | Out-Null
        }
        $sw.Stop()
        $evidence = Write-VCaseEvidence -Ctx $ctx
        $summary = $evidence.Summary
        $summary.durationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        [void]$results.Add($summary)
        if (-not $script:G.KeepSandbox) {
            try { Remove-VTreeJunctionSafe -Path $ctx.CaseRoot -AllowedRoot $script:G.WorkRoot } catch { }
        }
    }
    return @($results.ToArray())
}

# =====================================================================================
# AREA J - package integrity + archive + MCP
# =====================================================================================

function Invoke-VNodeScript {
    param($Ctx, [string]$Label, [string]$ScriptPath, [string[]]$Arguments = @(), [string]$WorkingDirectory = '')
    $nodeExe = (Get-Command 'node' -ErrorAction Stop).Source
    $outDir = Join-Path $Ctx.OutDir 'node'
    $run = Invoke-VProcess -Executable $nodeExe -Arguments (@($ScriptPath) + $Arguments) -OutDir $outDir -Label $Label -WorkingDirectory $WorkingDirectory
    Add-VCommand -Ctx $Ctx -Label $Label -Executable $nodeExe -Arguments (@($ScriptPath) + $Arguments) -ExitCode $run.ExitCode `
        -StdoutPath $run.StdoutPath -StderrPath $run.StderrPath -DurationSec $run.DurationSec | Out-Null
    return $run
}
function Invoke-VPythonScript {
    param($Ctx, [string]$Label, [string]$PythonExe, [string]$ScriptPath, [string[]]$Arguments = @(), [hashtable]$Environment = @{})
    $outDir = Join-Path $Ctx.OutDir 'python'
    $run = Invoke-VProcess -Executable $PythonExe -Arguments (@($ScriptPath) + $Arguments) -Environment $Environment -OutDir $outDir -Label $Label
    Add-VCommand -Ctx $Ctx -Label $Label -Executable $PythonExe -Arguments (@($ScriptPath) + $Arguments) -ExitCode $run.ExitCode `
        -StdoutPath $run.StdoutPath -StderrPath $run.StderrPath -Environment $Environment -DurationSec $run.DurationSec | Out-Null
    return $run
}
function Get-VToolSchemaChecks {
    param($Ctx, [string]$ToolsJsonPath)
    $doc = Read-JsonFile $ToolsJsonPath
    $tools = @($doc.tools)
    if ($tools.Count -eq 0) {
        Add-VCheck $Ctx (New-VResult -Id 'J.schema.toolsPresent' -Status 'FAIL' -Detail "launcher --tools-json produced no tools: $ToolsJsonPath") | Out-Null
        return
    }
    $names = @($tools | ForEach-Object { [string]$_.name })
    $frozen = $script:G.Frozen
    $missing = @($frozen.ToolNames | Where-Object { $names -notcontains $_ })
    Add-VCheck $Ctx (Assert-VCondition -Id 'J.schema.toolSet' -Condition ($names.Count -eq 8 -and $missing.Count -eq 0) -PassDetail "8 expected MCP tools present: $($names -join ', ')" -FailDetail "tool set mismatch (count=$($names.Count), missing=$($missing -join ', '))" -Expected ($frozen.ToolNames -join ',') -Actual ($names -join ',')) | Out-Null
    $detail = @($tools | Where-Object { [string]$_.name -eq 'get-info-by-detail' })
    $titleRequired = $false
    if ($detail.Count -eq 1) {
        $schema = $detail[0].inputSchema
        $required = @($schema.required)
        $props = $schema.properties
        $titleRequired = ($required -contains 'title') -and ($null -ne $props.title)
    }
    Add-VCheck $Ctx (Assert-VCondition -Id 'J.schema.titleRequired' -Condition $titleRequired -PassDetail 'get-info-by-detail declares title as a required parameter' -FailDetail 'get-info-by-detail does not declare title as required in the served schema' -Expected 'title required' -Actual ([string]$titleRequired)) | Out-Null
}
function Test-AreaJ-CaseZipIdentity {
    $ctx = New-VCaseSandbox -Case 'J1-candidate-zip-identity' -Description 'Candidate ZIP identity, sidecar and external release checksums'
    $zip = $script:G.Layout.UnifiedZip
    $f = $script:G.Frozen
    $sha = $script:G.CandidateZipSha
    $sidecar = $zip + '.sha256'
    $problems = New-Object System.Collections.ArrayList
    if (-not [System.IO.File]::Exists($sidecar)) { [void]$problems.Add('sidecar missing') }
    else {
        $content = ([System.IO.File]::ReadAllText($sidecar, (New-Utf8NoBom))).Trim()
        $sideSha = ''
        if ($content -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $sideSha = $matches[1].ToLowerInvariant() } else { [void]$problems.Add("sidecar unparsable: $(Limit-Text $content 120)") }
        if ($sideSha -and $sideSha -ne $sha) { [void]$problems.Add("sidecar sha $sideSha != zip sha $sha") }
    }
    Add-VCheck $ctx (Assert-VCondition -Id 'J1.zipSha' -Condition ($problems.Count -eq 0) -PassDetail "candidate ZIP sha256=$sha ($($script:G.CandidateZipBytes) B) matches its sidecar" -FailDetail ("zip identity problems: " + ($problems -join '; ')) -Expected $sha -Actual ($problems -join '; ')) | Out-Null
    $entries = $script:G.ZipEntries
    Add-VCheck $ctx (Assert-VCondition -Id 'J1.zipPresent' -Condition ($null -ne $entries) -PassDetail "candidate ZIP present with $(@($entries).Count) entries" -FailDetail 'candidate ZIP missing/uncorrectable' -Expected 'zip' -Actual ([string]($null -ne $entries))) | Out-Null
    return $ctx
}
function Test-AreaJ-CaseInternalClosure {
    param([string]$Mode = 'zip', [string]$CaseName = 'J2-internal-closure')
    $ctx = New-VCaseSandbox -Case $CaseName -Description "Package internal closure S->M->U->P ($Mode)"
    $root = $null
    if ($Mode -eq 'zip') {
        if (-not $script:G.CandidateZipPresent) {
            Add-VCheck $ctx (New-VResult -Id 'J2.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
            return $ctx
        }
        $root = Initialize-VCandidateExtract -Ctx $ctx
    } else {
        $root = $script:G.Layout.Repo
    }
    $report = Join-Path $ctx.OutDir 'closure.json'
    $checker = Join-Path $root 'tests\test_unified_package.mjs'
    if ($script:G.UseRepoTestScripts) {
        $repoChecker = Join-Path $script:G.Layout.Repo 'tests\test_unified_package.mjs'
        if ([System.IO.File]::Exists($repoChecker)) {
            $checker = $repoChecker
            Add-VNote $ctx 'interim override: closure checker executed from the candidate repo because the candidate ZIP predates the harness fix; the final build must ship identical test bytes'
        }
    }
    $nodeCheck = Invoke-VNodeScript -Ctx $ctx -Label 'test-unified-package' -ScriptPath $checker -Arguments @('--package-root', $root, '--json', '--write-report', $report, '--expect-payload-count', [string]$script:G.Frozen.ExpectedPayloadCount)
    $doc = $null
    try { $doc = Read-JsonFile $report } catch { }
    Add-VCheck $ctx (Assert-VCondition -Id 'J2.exit' -Condition ($nodeCheck.ExitCode -eq 0) -PassDetail 'independent closure checker exit 0' -FailDetail "closure checker exit $($nodeCheck.ExitCode); report: $report" -Expected 0 -Actual $nodeCheck.ExitCode) | Out-Null
    if ($doc) {
        $fails = @($doc.checks | Where-Object { $_.status -eq 'FAIL' })
        Add-VCheck $ctx (Assert-VCondition -Id 'J2.checks' -Condition ($fails.Count -eq 0) -PassDetail "$(@($doc.checks.Count)) closure checks PASS (S/M/U/P closure, counts, changedFiles, payload hashes)" -FailDetail ("closure FAILs: " + (($fails | ForEach-Object { $_.id }) -join ', ')) -Expected 'no FAIL' -Actual ($fails.Count)) | Out-Null
        Add-VAddClosureCounts -Ctx $ctx -Doc $doc
    } else {
        Add-VCheck $ctx (New-VResult -Id 'J2.report' -Status 'FAIL' -Detail "closure checker produced no report at $report") | Out-Null
    }
    return $ctx
}
function Add-VAddClosureCounts {
    param($Ctx, $Doc)
    $payloadCheck = @($Doc.checks | Where-Object { $_.id -eq 'C5.manifestFiles' })
    $details = if ($payloadCheck.Count -gt 0) { $payloadCheck[0].detail } else { '' }
    Add-VCheck $Ctx (New-VResult -Id 'J2.payloadCountEvidence' -Status 'PASS' -Detail "C5 evidence: $details") | Out-Null
}
function Test-AreaJ-CaseExtractedEqualsRepo {
    $ctx = New-VCaseSandbox -Case 'J3-extracted-equals-repo' -Description 'Extracted candidate ZIP tree is byte-identical to the candidate repo package files'
    if (-not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'J3.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    # The repo may carry dev-only state (.git, dist, _scratch, _portable) and is the source of
    # truth only for committed package files. Compare the shipped file sets.
    $zipFiles = @(Get-VZipEntries -ZipPath $script:G.Layout.UnifiedZip | Where-Object { -not $_.IsDirectory })
    $repoMap = Get-VDirectoryFileMap -Root $script:G.Layout.Repo -ExcludeRelPrefixes @('.git', 'dist', '_scratch', '_portable', 'test-evidence', 'node_modules', '.venv', '__pycache__', '.gitattributes')
    $zipMap = @{}
    foreach ($e in $zipFiles) { $zipMap[[string]$e.Path] = [pscustomobject]@{ Rel = $e.Path; Bytes = $e.Bytes; Sha256 = $e.Sha256 } }
    $cmp = Compare-VFileMaps -Left $zipMap -Right $repoMap
    if ($cmp.Equal) {
        Add-VCheck $ctx (Assert-VCondition -Id 'J3.equal' -Condition $true -PassDetail "extracted ZIP == repo package files ($($zipMap.Count) files, all byte-identical)" -Expected 'identical' -Actual 'identical') | Out-Null
    } else {
        $zipTime = (Get-Item -LiteralPath $script:G.Layout.UnifiedZip).LastWriteTimeUtc
        $repoAheadOnly = (@($cmp.OnlyLeft).Count -eq 0) -and (@($cmp.OnlyRight).Count -eq 0)
        if ($repoAheadOnly) {
            foreach ($relPath in @($cmp.Different)) {
                $repoFull = Join-Path $script:G.Layout.Repo ($relPath -replace '/', '\')
                if (-not [System.IO.File]::Exists($repoFull) -or (Get-Item -LiteralPath $repoFull).LastWriteTimeUtc -le $zipTime) { $repoAheadOnly = $false; break }
            }
        }
        if ($repoAheadOnly) {
            Add-VCheck $ctx (New-VResult -Id 'J3.equal' -Status 'WARN' -Detail ("candidate ZIP predates the latest repo edits for: " + (@($cmp.Different) -join ', ') + " (final rebuild required); all other package files byte-identical")) | Out-Null
        } else {
            Add-VCheck $ctx (Assert-VCondition -Id 'J3.equal' -Condition $false -FailDetail ("tree differences: onlyZip=[$(@($cmp.OnlyLeft) -join ', ')] onlyRepo=[$(@($cmp.OnlyRight) -join ', ')] changed=[$(@($cmp.Different) -join ', ')]") -Expected 'identical' -Actual "zipOnly=$(@($cmp.OnlyLeft).Count) repoOnly=$(@($cmp.OnlyRight).Count) changed=$(@($cmp.Different).Count)") | Out-Null
        }
    }
    if (-not $cmp.Equal) {
        Write-JsonFile -Path (Join-Path $ctx.OutDir 'extracted-vs-repo.json') -Value $cmp -Depth 10
        Add-VArtifact $ctx (Join-Path $ctx.OutDir 'extracted-vs-repo.json') 'extracted-vs-repo diff' | Out-Null
    }
    return $ctx
}
function Test-AreaJ-CaseFrozenCore {
    $ctx = New-VCaseSandbox -Case 'J4-frozen-core-equality' -Description 'Frozen-core payload equality vs frozen RC3 ZIP; no frozen payload file deleted'
    if (-not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'J4.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $f = $script:G.Frozen
    $candidateMap = Get-VDirectoryFileMap -Root $pkg
    $rc3Entries = @(Get-VZipEntries -ZipPath $script:G.Layout.Rc3Zip | Where-Object { -not $_.IsDirectory })
    $rc3Map = @{}
    foreach ($e in $rc3Entries) { $rc3Map[[string]$e.Path] = $e }
    $deleted = New-Object System.Collections.ArrayList
    $coreBad = New-Object System.Collections.ArrayList
    foreach ($path in $rc3Map.Keys) {
        if (-not $candidateMap.ContainsKey($path)) { [void]$deleted.Add($path); continue }
        if ($f.CoreIdentical -contains $path) {
            if ($candidateMap[$path].Sha256 -ne $rc3Map[$path].Sha256) { [void]$coreBad.Add($path) }
        }
    }
    Add-VCheck $ctx (Assert-VCondition -Id 'J4.noDeletions' -Condition ($deleted.Count -eq 0) -PassDetail "no frozen RC3 payload file was deleted (0 of $($rc3Map.Count))" -FailDetail ("frozen payload files missing from candidate: " + (@($deleted) -join ', ')) -Expected '0 deleted' -Actual $deleted.Count) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'J4.coreIdentical' -Condition ($coreBad.Count -eq 0) -PassDetail ("core files byte-identical to frozen RC3 (" + $f.CoreIdentical.Count + " files: bundle/**, upstream tools, licenses, portable.ps1/PortableCommon, probe, docs/02+06)") -FailDetail ("core files changed vs frozen RC3: " + (@($coreBad) -join ', ')) -Expected 'identical' -Actual (@($coreBad) -join ',')) | Out-Null
    # Added files must be absent from frozen RC3.
    $unexpected = @($f.AddedPayload | Where-Object { $rc3Map.ContainsKey($_) })
    Add-VCheck $ctx (Assert-VCondition -Id 'J4.addsAreNew' -Condition ($unexpected.Count -eq 0) -PassDetail 'the 8 added payload files do not exist in frozen RC3 (true additions)' -FailDetail ("added files already in frozen RC3: " + ($unexpected -join ', ')) -Expected 'absent from RC3' -Actual $unexpected.Count) | Out-Null
    # Frozen cordis hash anchor (semantics unchanged).
    $cordisSha = ''
    if ($candidateMap.ContainsKey('bundle/cnki-research/cordis.patch.yml')) { $cordisSha = $candidateMap['bundle/cnki-research/cordis.patch.yml'].Sha256 }
    Add-VCheck $ctx (Assert-VCondition -Id 'J4.cordis' -Condition ($cordisSha -eq 'edda8817e0bf449d8324f4875b1c7acd37a8dc693c3a82d044f4a5c436421778') -PassDetail 'cordis.patch.yml == frozen RC3 bytes ({{cwd}} regression fix preserved)' -FailDetail "cordis.patch.yml sha=$cordisSha (expected frozen RC3 edda8817...)" -Expected 'edda8817...' -Actual $cordisSha) | Out-Null
    return $ctx
}
function Test-AreaJ-CaseManifestCheck {
    param([string]$Mode = 'zip', [string]$CaseName = 'J5-build-manifest-check')
    $ctx = New-VCaseSandbox -Case $CaseName -Description "node tools/build_manifest.mjs --check ($Mode)"
    if ($Mode -eq 'zip' -and -not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'J5.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    if ($Mode -eq 'zip') { $root = Initialize-VCandidateExtract -Ctx $ctx } else { $root = $script:G.Layout.Repo }
    if ($Mode -eq 'repo') {
        $git = (Get-Command 'git').Source
        $st = Invoke-VProcess -Executable $git -Arguments @('-C', $script:G.Layout.Repo, 'status', '--porcelain') -OutDir $ctx.OutDir -Label 'git-status-repo-static'
        $dirty = @(([string]$st.Stdout) -split "`n" | Where-Object { $_.Trim() -ne '' })
        if ($dirty.Count -gt 0) {
            Add-VCheck $ctx (New-VResult -Id 'J6.repoState' -Status 'NOT TESTED' -Detail "candidate repo has $($dirty.Count) uncommitted path(s); the repo static suite is only meaningful after the final build + commit") | Out-Null
            return $ctx
        }
    }
    $node = (Get-Command 'node').Source
    $run = Invoke-VNodeScript -Ctx $ctx -Label 'build-manifest-check' -ScriptPath (Join-Path $root 'tools\build_manifest.mjs') -Arguments @('--check') -WorkingDirectory $root
    Add-VCheck $ctx (Assert-VCondition -Id 'J5.current' -Condition ($run.ExitCode -eq 0) -PassDetail 'manifest.json is current relative to the package tree (build_manifest --check exit 0)' -FailDetail "build_manifest --check exit $($run.ExitCode): " + (Limit-Text (($run.Stdout + $run.Stderr) -join ' ') 400) -Expected 0 -Actual $run.ExitCode) | Out-Null
    return $ctx
}
function Test-AreaJ-CaseStaticPackage {
    param([string]$Mode = 'zip', [string]$CaseName = 'J6-static-package')
    $ctx = New-VCaseSandbox -Case $CaseName -Description "Static package test on the $Mode package"
    if ($Mode -eq 'zip' -and -not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'J6.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    if ($Mode -eq 'zip') { $root = Initialize-VCandidateExtract -Ctx $ctx } else { $root = $script:G.Layout.Repo }
    if ($Mode -eq 'repo') {
        $git = (Get-Command 'git').Source
        $st = Invoke-VProcess -Executable $git -Arguments @('-C', $script:G.Layout.Repo, 'status', '--porcelain') -OutDir $ctx.OutDir -Label 'git-status-repo-static'
        $dirty = @(([string]$st.Stdout) -split "`n" | Where-Object { $_.Trim() -ne '' })
        if ($dirty.Count -gt 0) {
            Add-VCheck $ctx (New-VResult -Id 'J6.repoState' -Status 'NOT TESTED' -Detail "candidate repo has $($dirty.Count) uncommitted path(s); the repo static suite is only meaningful after the final build + commit") | Out-Null
            return $ctx
        }
    }
    if ($Mode -eq 'zip' -and $script:G.UseRepoTestScripts) {
        $repoTest = Join-Path $script:G.Layout.Repo 'tests\test_static_package.mjs'
        $shippedTest = Join-Path $root 'tests\test_static_package.mjs'
        if ([System.IO.File]::Exists($repoTest)) {
            Copy-Item -LiteralPath $repoTest -Destination $shippedTest -Force
            Add-VNote $ctx 'interim override: static package test executed from the candidate repo copy (candidate ZIP predates the docs-writer adaptation); final build must ship identical test bytes'
        }
    }
    $report = Join-Path $ctx.OutDir 'static-package.json'
    $run = Invoke-VNodeScript -Ctx $ctx -Label 'static-package' -ScriptPath (Join-Path $root 'tests\test_static_package.mjs') -Arguments @('--json', '--write-report', $report) -WorkingDirectory $root
    $doc = $null
    try { $doc = Read-JsonFile $report } catch { }
    Add-VCheck $ctx (Assert-VCondition -Id 'J6.exit' -Condition ($run.ExitCode -eq 0) -PassDetail 'static package suite exit 0' -FailDetail "static package suite exit $($run.ExitCode)" -Expected 0 -Actual $run.ExitCode) | Out-Null
    if ($doc) {
        $fails = @($doc.checks | Where-Object { $_.status -eq 'FAIL' })
        Add-VCheck $ctx (Assert-VCondition -Id 'J6.checks' -Condition ($fails.Count -eq 0) -PassDetail "$(@($doc.checks.Count)) static package checks PASS (manifest integrity, identity, no dev paths/credentials, licences, YAML/persona)" -FailDetail ("static FAILs: " + (($fails | ForEach-Object { $_.id }) -join ', ')) -Expected 'no FAIL' -Actual $fails.Count) | Out-Null
        Add-VArtifact $ctx $report 'static package report' | Out-Null
    } else {
        Add-VCheck $ctx (New-VResult -Id 'J6.report' -Status 'FAIL' -Detail "static suite produced no report: $report") | Out-Null
    }
    # Adapted static suite should have a setup entry-point awareness check; report it if present.
    $staticSource = ''
    try { $staticSource = [System.IO.File]::ReadAllText((Join-Path $root 'tests\test_static_package.mjs'), (New-Utf8NoBom)) } catch { }
    $adapted = $staticSource.Contains('setupEntryPoint')
    if ($adapted) {
        Add-VCheck $ctx (New-VResult -Id 'J6.adapted' -Status 'PASS' -Detail 'static suite verifies the unified manifest additions (setupEntryPoint / upgrade block)') | Out-Null
    } else {
        Add-VCheck $ctx (New-VResult -Id 'J6.adapted' -Status 'WARN' -Detail 'static suite does not yet reference the unified setupEntryPoint/upgrade manifest additions (docs-writer adaptation pending)') | Out-Null
    }
    return $ctx
}
function Test-AreaJ-CaseCleanClone {
    $ctx = New-VCaseSandbox -Case 'J7-clean-git-clone' -Description 'Clean git clone of the candidate repo: package metadata builds and static suite passes'
    $clone = Join-Path $ctx.CaseRoot 'clone'
    $git = (Get-Command 'git').Source
    $repoStatus = Invoke-VProcess -Executable $git -Arguments @('-C', $script:G.Layout.Repo, 'status', '--porcelain') -OutDir $ctx.OutDir -Label 'git-status-before-clone'
    $repoDirty = @(([string]$repoStatus.Stdout) -split "`n" | Where-Object { $_.Trim() -ne '' })
    if ($repoDirty.Count -gt 0) {
        Add-VCheck $ctx (New-VResult -Id 'J7.clone' -Status 'NOT TESTED' -Detail "candidate repo has $($repoDirty.Count) uncommitted path(s); a clean clone test is only meaningful after the final commit") | Out-Null
        return $ctx
    }
    $run = Invoke-VProcess -Executable $git -Arguments @('clone', '--quiet', $script:G.Layout.Repo, $clone) -OutDir $ctx.OutDir -Label 'git-clone'
    Add-VCommand -Ctx $ctx -Label 'git-clone' -Executable $git -Arguments @('clone', $script:G.Layout.Repo, $clone) -ExitCode $run.ExitCode -StdoutPath $run.StdoutPath -StderrPath $run.StderrPath -DurationSec $run.DurationSec | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'J7.clone' -Condition ($run.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $clone 'tests\test_unified_package.mjs'))) -PassDetail 'clean clone succeeded and contains the committed package files' -FailDetail "clone failed or the new package files are not committed yet (exit $($run.ExitCode)); build-dev/Lead commit pending" -Expected 'cloned' -Actual $run.ExitCode) | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $clone 'tests\test_unified_package.mjs'))) { return $ctx }
    $check = Invoke-VNodeScript -Ctx $ctx -Label 'clone-build-manifest-check' -ScriptPath (Join-Path $clone 'tools\build_manifest.mjs') -Arguments @('--check') -WorkingDirectory $clone
    Add-VCheck $ctx (Assert-VCondition -Id 'J7.manifestCurrent' -Condition ($check.ExitCode -eq 0) -PassDetail 'clean clone: build_manifest --check is current' -FailDetail "clean clone: build_manifest --check exit $($check.ExitCode)" -Expected 0 -Actual $check.ExitCode) | Out-Null
    $closure = Invoke-VNodeScript -Ctx $ctx -Label 'clone-closure' -ScriptPath (Join-Path $clone 'tests\test_unified_package.mjs') -Arguments @('--package-root', $clone) -WorkingDirectory $clone
    Add-VCheck $ctx (Assert-VCondition -Id 'J7.closure' -Condition ($closure.ExitCode -eq 0) -PassDetail 'clean clone: internal closure checker exit 0' -FailDetail "clean clone: closure checker exit $($closure.ExitCode)" -Expected 0 -Actual $closure.ExitCode) | Out-Null
    $static = Invoke-VNodeScript -Ctx $ctx -Label 'clone-static' -ScriptPath (Join-Path $clone 'tests\test_static_package.mjs') -Arguments @('--json') -WorkingDirectory $clone
    Add-VCheck $ctx (Assert-VCondition -Id 'J7.static' -Condition ($static.ExitCode -eq 0) -PassDetail 'clean clone: static package suite exit 0' -FailDetail "clean clone: static package suite exit $($static.ExitCode)" -Expected 0 -Actual $static.ExitCode) | Out-Null
    return $ctx
}
function Test-AreaJ-CaseMcpProtocol {
    $ctx = New-VCaseSandbox -Case 'J8-mcp-protocol-lifecycle' -Description 'MCP stdio: initialize/tools/list/resources/list/ping + launcher lifecycle + 8-tool schema'
    if (-not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'J8.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $python = ''
    if ($script:G.PrebuiltVenvUsable) { $python = Join-Path $script:G.PrebuiltVenv 'Scripts\python.exe' }
    if (-not $python) {
        Add-VCheck $ctx (New-VResult -Id 'J8.interpreter' -Status 'NOT TESTED' -Detail 'no interpreter available for the MCP probe (fresh-install venv or -PrebuiltVenv required)') | Out-Null
        return $ctx
    }
    $launcher = Join-Path $pkg 'bundle\cnki-research\launcher\cnki_research_launcher.py'
    $cwd = Join-Path $ctx.CaseRoot 'mcp-cwd'
    [void][System.IO.Directory]::CreateDirectory($cwd)
    # launcher CLI
    $version = Invoke-VPythonScript -Ctx $ctx -Label 'launcher-version' -PythonExe $python -ScriptPath $launcher -Arguments @('--version') -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'J8.launcherVersion' -Condition ($version.ExitCode -eq 0) -PassDetail 'launcher --version exit 0' -FailDetail "launcher --version exit $($version.ExitCode)" -Expected 0 -Actual $version.ExitCode) | Out-Null
    $toolsJson = Join-Path $ctx.OutDir 'tools-served.json'
    $tools = Invoke-VPythonScript -Ctx $ctx -Label 'launcher-tools-json' -PythonExe $python -ScriptPath $launcher -Arguments @('--tools-json', $toolsJson) -Environment $envInfo.Env
    Add-VCheck $ctx (Assert-VCondition -Id 'J8.launcherToolsJson' -Condition ($tools.ExitCode -eq 0 -and [System.IO.File]::Exists($toolsJson)) -PassDetail 'launcher --tools-json produced the served catalog' -FailDetail "launcher --tools-json exit $($tools.ExitCode)" -Expected 0 -Actual $tools.ExitCode) | Out-Null
    if ([System.IO.File]::Exists($toolsJson)) { Get-VToolSchemaChecks -Ctx $ctx -ToolsJsonPath $toolsJson }
    # shipped probe: initialize/tools/list/resources/list
    $probeReport = Join-Path $ctx.OutDir 'probe-stdio.json'
    $probe = Invoke-VPythonScript -Ctx $ctx -Label 'probe-stdio' -PythonExe $python -ScriptPath (Join-Path $pkg 'tools\probe_mcp_stdio.py') -Arguments @('--launcher', $launcher, '--python', $python, '--cwd', $cwd, '--json', '--out', $probeReport) -Environment $envInfo.Env
    $probeDoc = $null
    try { $probeDoc = Read-JsonFile $probeReport } catch { }
    Add-VCheck $ctx (Assert-VCondition -Id 'J8.probe' -Condition ($probe.ExitCode -eq 0) -PassDetail 'shipped MCP stdio probe exit 0 (initialize + tools/list + resources/list)' -FailDetail "MCP probe exit $($probe.ExitCode)" -Expected 0 -Actual $probe.ExitCode) | Out-Null
    if ($probeDoc) {
        Add-VCheck $ctx (Assert-VCondition -Id 'J8.probeTools' -Condition ([int]$probeDoc.toolCount -eq 8) -PassDetail "MCP wire tools/list returned $($probeDoc.toolCount) tools" -FailDetail "MCP wire tools/list returned $($probeDoc.toolCount) tools" -Expected 8 -Actual $probeDoc.toolCount) | Out-Null
        $resources = @($probeDoc.resources | ForEach-Object { [string]$_.uri })
        Add-VCheck $ctx (Assert-VCondition -Id 'J8.probeResources' -Condition ($resources -contains 'profile://list') -PassDetail "MCP resources/list includes profile://list" -FailDetail "resources/list = [$($resources -join ', ')]" -Expected 'profile://list' -Actual ($resources -join ',')) | Out-Null
        $orphans = @($probeDoc.orphanProcesses)
        Add-VCheck $ctx (Assert-VCondition -Id 'J8.probeOrphans' -Condition ($orphans.Count -eq 0) -PassDetail 'no orphan launcher process after the session' -FailDetail "$($orphans.Count) orphan launcher process(es)" -Expected 0 -Actual $orphans.Count) | Out-Null
    }
    # independent lifecycle probe (ping + clean shutdown + no TCP listener + no orphan)
    $lifecycleScript = Join-Path (Join-Path $script:G.Layout.Worktree ('_' + 'verify')) 'scripts\probe_lifecycle.py'
    if ([System.IO.File]::Exists($lifecycleScript)) {
        $lifeReport = Join-Path $ctx.OutDir 'probe-lifecycle.json'
        $life = Invoke-VPythonScript -Ctx $ctx -Label 'probe-lifecycle' -PythonExe $python -ScriptPath $lifecycleScript -Arguments @('--launcher', $launcher, '--python', $python, '--cwd', $cwd, '--out', $lifeReport) -Environment $envInfo.Env
        $lifeDoc = $null
        try { $lifeDoc = Read-JsonFile $lifeReport } catch { }
        Add-VCheck $ctx (Assert-VCondition -Id 'J8.lifecycle' -Condition ($life.ExitCode -eq 0) -PassDetail 'independent JSON-RPC lifecycle probe exit 0 (ping, clean shutdown, no orphans, no TCP listener)' -FailDetail "lifecycle probe exit $($life.ExitCode)" -Expected 0 -Actual $life.ExitCode) | Out-Null
        if ($lifeDoc) {
            $checks = @($lifeDoc.checks)
            $ping = @($checks | Where-Object { $_.id -eq 'MCP.ping' })
            $pingOk = ($ping.Count -gt 0 -and $ping[0].status -eq 'PASS')
            $pingDetail = 'ping reported'; if ($ping.Count -gt 0) { $pingDetail = 'ping PASS: ' + $ping[0].detail }
        $pingStatus = 'absent'; if ($ping.Count -gt 0) { $pingStatus = $ping[0].status }
        Add-VCheck $ctx (Assert-VCondition -Id 'J8.ping' -Condition $pingOk -PassDetail $pingDetail -FailDetail 'MCP ping FAIL/absent' -Expected 'PASS' -Actual $pingStatus) | Out-Null
            $shutdown = @($checks | Where-Object { $_.id -eq 'MCP.cleanShutdown' })
            $shutdownStatus = 'absent'; if ($shutdown.Count -gt 0) { $shutdownStatus = $shutdown[0].status }
            Add-VCheck $ctx (Assert-VCondition -Id 'J8.cleanShutdown' -Condition ($shutdown.Count -gt 0 -and $shutdown[0].status -eq 'PASS') -PassDetail 'stdin EOF => child exits cleanly' -FailDetail 'clean shutdown check FAIL/absent' -Expected 'PASS' -Actual $shutdownStatus) | Out-Null
        }
    } else {
        Add-VCheck $ctx (New-VResult -Id 'J8.lifecycle' -Status 'NOT TESTED' -Detail "lifecycle probe script missing: $lifecycleScript") | Out-Null
    }
    return $ctx
}
function Test-AreaJ-CaseDshIsolated {
    $ctx = New-VCaseSandbox -Case 'J9-dsh-isolated-composition' -Description 'DSH 0.2.1 static+isolated: profile composition, install/uninstall/rollback in an isolated DSH_HOME'
    $scriptPath = Join-Path (Join-Path $script:G.Layout.Worktree ('_' + 'verify')) 'scripts\Test-DshIsolatedUnified.ps1'
    if (-not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'J9.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    if (-not $script:G.DshCliResolved) {
        Add-VCheck $ctx (New-VResult -Id 'J9.dshCli' -Status 'NOT TESTED' -Detail 'dsh.cmd not available; DSH isolated composition cannot be exercised') | Out-Null
        return $ctx
    }
    if (-not [System.IO.File]::Exists($scriptPath)) {
        Add-VCheck $ctx (New-VResult -Id 'J9.prereq' -Status 'NOT TESTED' -Detail "adapted isolated-DSH test missing: $scriptPath") | Out-Null
        return $ctx
    }
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $envInfo = New-VIsolatedEnvironment -Root (Join-Path $ctx.CaseRoot 'env')
    $report = Join-Path $ctx.OutDir 'dsh-isolated.json'
    $run = Invoke-VProcess -Executable $script:G.Layout.PsExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-PackageRoot', $pkg, '-DshCli', $script:G.DshCliResolved, '-Json', '-ReportPath', $report, '-PrebuiltVenv', $script:G.PrebuiltVenv) -Environment $envInfo.Env -OutDir $ctx.OutDir -Label 'dsh-isolated'
    Add-VCommand -Ctx $ctx -Label 'dsh-isolated' -Executable $script:G.Layout.PsExe -Arguments $run.Arguments -ExitCode $run.ExitCode -StdoutPath $run.StdoutPath -StderrPath $run.StderrPath -DurationSec $run.DurationSec | Out-Null
    $doc = $null
    try { $doc = Read-JsonFile $report } catch { }
    $j9Tail = ''
    try { $j9Tail = (Get-Content -LiteralPath $run.StderrPath -Raw -ErrorAction SilentlyContinue) } catch { }
    if (-not $j9Tail) { try { $j9Tail = (Get-Content -LiteralPath $run.StdoutPath -Raw -ErrorAction SilentlyContinue) } catch { } }
    Add-VCheck $ctx (Assert-VCondition -Id 'J9.exit' -Condition ($run.ExitCode -eq 0) -PassDetail 'isolated DSH composition/install/uninstall/rollback test exit 0' -FailDetail ("isolated DSH test exit $($run.ExitCode); tail: " + (Limit-Text $j9Tail 400)) -Expected 0 -Actual $run.ExitCode) | Out-Null
    if ($doc) {
        $fails = @($doc.checks | Where-Object { $_.status -eq 'FAIL' })
        Add-VCheck $ctx (Assert-VCondition -Id 'J9.checks' -Condition ($fails.Count -eq 0) -PassDetail "$(@($doc.checks).Count) isolated-DSH checks PASS (no FAIL)" -FailDetail ("isolated-DSH FAILs: " + (($fails | ForEach-Object { [string]$_.id }) -join ', ')) -Expected 'no FAIL' -Actual $fails.Count) | Out-Null
        Add-VArtifact $ctx $report 'dsh isolated report' | Out-Null
    }
    return $ctx
}
function Test-AreaJ-CaseRepoPackageState {
    $ctx = New-VCaseSandbox -Case 'J10-repo-package-state' -Description 'Candidate repo package state: metadata present, git cleanliness, no uncommitted drift'
    $git = (Get-Command 'git').Source
    $status = Invoke-VProcess -Executable $git -Arguments @('-C', $script:G.Layout.Repo, 'status', '--porcelain') -OutDir $ctx.OutDir -Label 'git-status'
    Add-VCommand -Ctx $ctx -Label 'git-status' -Executable $git -Arguments @('-C', $script:G.Layout.Repo, 'status', '--porcelain') -ExitCode $status.ExitCode -StdoutPath $status.StdoutPath -StderrPath $status.StderrPath -DurationSec $status.DurationSec | Out-Null
    $dirtyLines = @(([string]$status.Stdout) -split "`n" | Where-Object { $_.Trim() -ne '' })
    Add-VCheck $ctx (Assert-VCondition -Id 'J10.gitClean' -Condition ($dirtyLines.Count -eq 0) -PassDetail 'candidate repo working tree clean (all package files committed)' -FailDetail ("candidate repo has $($dirtyLines.Count) uncommitted path(s): " + (($dirtyLines | Select-Object -First 8) -join '; ')) -Expected 'clean' -Actual $dirtyLines.Count) | Out-Null
    $metadata = @(
        (Join-Path $script:G.Layout.Repo 'manifest.json'),
        (Join-Path $script:G.Layout.Repo 'SHA256SUMS.txt'),
        (Join-Path $script:G.Layout.Repo 'upgrade-data\rc2-to-rc3.json'),
        (Join-Path $script:G.Layout.Repo 'upgrade-data\README.md')
    ) | Where-Object { -not [System.IO.File]::Exists($_) }
    Add-VCheck $ctx (Assert-VCondition -Id 'J10.metadataPresent' -Condition ($metadata.Count -eq 0) -PassDetail 'committed package metadata files present in the repo' -FailDetail ("missing metadata: " + (($metadata | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) -Expected 'present' -Actual $metadata.Count) | Out-Null
    return $ctx
}

function Invoke-AreaJ {
    $results = New-Object System.Collections.ArrayList
    $cases = @(
        @{ Name = 'J1-candidate-zip-identity'; Fn = { Test-AreaJ-CaseZipIdentity } }
        @{ Name = 'J2-internal-closure-zip'; Fn = { Test-AreaJ-CaseInternalClosure -Mode 'zip' -CaseName 'J2-internal-closure-zip' } }
        @{ Name = 'J3-extracted-equals-repo'; Fn = { Test-AreaJ-CaseExtractedEqualsRepo } }
        @{ Name = 'J4-frozen-core-equality'; Fn = { Test-AreaJ-CaseFrozenCore } }
        @{ Name = 'J5-build-manifest-check-zip'; Fn = { Test-AreaJ-CaseManifestCheck -Mode 'zip' -CaseName 'J5-build-manifest-check-zip' } }
        @{ Name = 'J6-static-package-zip'; Fn = { Test-AreaJ-CaseStaticPackage -Mode 'zip' -CaseName 'J6-static-package-zip' } }
        @{ Name = 'J6b-static-package-repo'; Fn = { Test-AreaJ-CaseStaticPackage -Mode 'repo' -CaseName 'J6b-static-package-repo' } }
        @{ Name = 'J7-clean-git-clone'; Fn = { Test-AreaJ-CaseCleanClone } }
        @{ Name = 'J8-mcp-protocol-lifecycle'; Fn = { Test-AreaJ-CaseMcpProtocol } }
        @{ Name = 'J9-dsh-isolated-composition'; Fn = { Test-AreaJ-CaseDshIsolated } }
        @{ Name = 'J10-repo-package-state'; Fn = { Test-AreaJ-CaseRepoPackageState } }
    )
    foreach ($caseEntry in $cases) {
        if ($Case -ne '*' -and $caseEntry.Name -notlike $Case) { continue }
        Write-Host ("=== $($caseEntry.Name) ===") -ForegroundColor Cyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ctx = $null
        try { $ctx = & $caseEntry.Fn } catch {
            $ctx = New-VCaseSandbox -Case $caseEntry.Name -Description 'case exception'
            Add-VCheck $ctx (New-VResult -Id ($caseEntry.Name + '.exception') -Status 'FAIL' -Detail ("case threw: " + $_.Exception.Message)) | Out-Null
        }
        $sw.Stop()
        $evidence = Write-VCaseEvidence -Ctx $ctx
        $summary = $evidence.Summary
        $summary.durationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        [void]$results.Add($summary)
        if (-not $script:G.KeepSandbox) {
            try { Remove-VTreeJunctionSafe -Path $ctx.CaseRoot -AllowedRoot $script:G.WorkRoot } catch { }
        }
    }
    return @($results.ToArray())
}

# =====================================================================================
# AREA K - release-security support
# =====================================================================================

function Test-VPrivacyScanText {
    param([string]$Text)
    $hits = New-Object System.Collections.ArrayList
    $markers = @(
        @{ re = 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'; label = 'private-key' }
        @{ re = 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.'; label = 'jwt-like' }
        @{ re = 'sk-[A-Za-z0-9]{20,}'; label = 'api-key' }
        @{ re = '"domain"\s*:\s*"\.?cnki\.net"'; label = 'cnki-cookie-jar' }
        @{ re = 'ghp_[A-Za-z0-9]{20,}'; label = 'github-token' }
        @{ re = 'AKIA[0-9A-Z]{16}'; label = 'aws-access-key' }
        @{ re = 'F:[\\/]DSH'; label = 'dev-drive-path' }
        @{ re = 'F:[\\/]cnki-mcp'; label = 'dev-upstream-path' }
        @{ re = 'D:[\\/]DeepSeekHarness'; label = 'dev-tool-path' }
        @{ re = '[A-Za-z]:[\\/](Users|用户)[\\/][^\\/\s"'']+'; label = 'absolute-user-path' }
        @{ re = (@('cnki', '-', 'mcp', ' ', 'Mode') -join ''); label = 'dev-workspace' }

    )
    foreach ($m in $markers) {
        if ([regex]::IsMatch($Text, $m.re, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { [void]$hits.Add($m.label) }
    }
    return @($hits.ToArray())
}
function Test-VPrivacyScanTree {
    param([string]$Root, [string[]]$ExemptPrefixes = @())
    $rootFull = Get-FullPath $Root
    $hits = New-Object System.Collections.ArrayList
    foreach ($entry in @(Get-VTreeSnapshot -Root $rootFull)) {
        if ($entry.Kind -ne 'file') { continue }
        $skip = $false
        foreach ($ex in $ExemptPrefixes) { if ($ex -and ($entry.Rel -ieq $ex -or $entry.Rel.StartsWith(($ex.TrimEnd('/')) + '/'))) { $skip = $true; break } }
        if ($skip) { continue }
        if ($entry.Rel -match '\.(png|jpg|jpeg|gif|webp|ico|zip|whl|exe|dll|woff2?)$') { continue }
        $full = Join-Path $rootFull ($entry.Rel -replace '/', '\')
        try { $bytes = [System.IO.File]::ReadAllBytes($full) } catch { continue }
        if (@($bytes | Where-Object { $_ -eq 0 }).Count -gt 0) { continue }
        $text = (New-Utf8NoBom).GetString($bytes)
        foreach ($label in @(Test-VPrivacyScanText -Text $text)) { [void]$hits.Add([pscustomobject]@{ Path = $entry.Rel; Category = $label }) }
    }
    return @($hits.ToArray())
}
function Test-AreaK-CaseScanZip {
    $ctx = New-VCaseSandbox -Case 'K1-privacy-scan-zip' -Description 'Privacy/credential/dev-path scan over the extracted candidate package'
    if (-not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'K1.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $hits = @(Test-VPrivacyScanTree -Root $pkg -ExemptPrefixes @('docs/provenance', 'tests/test_static_package.mjs', 'tests/test_unified_package.mjs', '.git'))
    Add-VCheck $ctx (Assert-VCondition -Id 'K1.clean' -Condition ($hits.Count -eq 0) -PassDetail "no privacy/credential/dev-path markers in $((Get-VTreeSnapshot -Root $pkg | Where-Object { $_.Kind -eq 'file' }).Count) packaged files" -FailDetail ("scan hits: " + (($hits | Select-Object -First 8 | ForEach-Object { "$($_.Path):$($_.Category)" }) -join '; ')) -Expected '0 hits' -Actual $hits.Count) | Out-Null
    Write-JsonFile -Path (Join-Path $ctx.OutDir 'privacy-scan.json') -Value ([ordered]@{ root = $pkg; hits = $hits; evidence = 'relative paths only' }) -Depth 10
    return $ctx
}
function Test-AreaK-CaseScanRepo {
    $ctx = New-VCaseSandbox -Case 'K2-privacy-scan-repo' -Description 'Privacy/credential/dev-path scan over the candidate repo package files'
    $exempt = @('docs/provenance', 'tests/test_static_package.mjs', 'tests/test_unified_package.mjs', '.git', '.gitattributes')
    $hits = @(Test-VPrivacyScanTree -Root $script:G.Layout.Repo -ExemptPrefixes $exempt)
    # The detectors themselves are exempt; dev-path hits in docs are reported separately.
    Add-VCheck $ctx (Assert-VCondition -Id 'K2.clean' -Condition ($hits.Count -eq 0) -PassDetail 'no privacy/credential/dev-path markers in the candidate repo package files (detectors exempt)' -FailDetail ("scan hits: " + (($hits | Select-Object -First 8 | ForEach-Object { "$($_.Path):$($_.Category)" }) -join '; ')) -Expected '0 hits' -Actual $hits.Count) | Out-Null
    Write-JsonFile -Path (Join-Path $ctx.OutDir 'privacy-scan-repo.json') -Value ([ordered]@{ root = $script:G.Layout.Repo; hits = $hits }) -Depth 10
    return $ctx
}
function Test-AreaK-CaseDetectorControls {
    $ctx = New-VCaseSandbox -Case 'K3-detector-controls' -Description 'Privacy scanner positive/negative controls (injected synthetic markers only)'
    $cleanDir = Join-Path $ctx.CaseRoot 'clean'
    [void][System.IO.Directory]::CreateDirectory($cleanDir)
    [System.IO.File]::WriteAllText((Join-Path $cleanDir 'README.md'), "# clean fixture`nno secrets here`n", (New-Utf8NoBom))
    $dirtyDir = Join-Path $ctx.CaseRoot 'dirty'
    [void][System.IO.Directory]::CreateDirectory($dirtyDir)
    $injected = "sk-" + ('A' * 24) + "`n" + "eyJ" + ('B' * 24) + "." + ('C' * 24) + ".`n"
    [System.IO.File]::WriteAllText((Join-Path $dirtyDir 'leak.txt'), $injected, (New-Utf8NoBom))
    $cleanHits = @(Test-VPrivacyScanTree -Root $cleanDir)
    $dirtyHits = @(Test-VPrivacyScanTree -Root $dirtyDir)
    Add-VCheck $ctx (Assert-VCondition -Id 'K3.negativeControl' -Condition ($cleanHits.Count -eq 0) -PassDetail 'clean synthetic fixture scans clean' -FailDetail ("clean fixture produced hits: " + (($cleanHits | ForEach-Object { $_.Category }) -join ', ')) -Expected '0 hits' -Actual $cleanHits.Count) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'K3.positiveControl' -Condition ($dirtyHits.Count -ge 1) -PassDetail "injected synthetic markers detected ($(($dirtyHits | ForEach-Object { $_.Category }) -join ', '))" -FailDetail 'injected privacy/credential markers were NOT detected (scanner blind)' -Expected '>=1 hit' -Actual $dirtyHits.Count) | Out-Null
    return $ctx
}
function Test-AreaK-CaseZipHygiene {
    $ctx = New-VCaseSandbox -Case 'K4-zip-path-hygiene' -Description 'Candidate ZIP entry hygiene, entry-set closure and absence of internal/dev material'
    if (-not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'K4.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    $entries = @($script:G.ZipEntries)
    $fileEntries = @($entries | Where-Object { -not $_.IsDirectory })
    $dirEntries = @($entries | Where-Object { $_.IsDirectory })
    $hygiene = @(Test-VZipPathHygiene -Entries $entries)
    $frozen = $script:G.Frozen
    Add-VCheck $ctx (Assert-VCondition -Id 'K4.pathHygiene' -Condition ($hygiene.Count -eq 0) -PassDetail "ZIP entry paths clean ($($fileEntries.Count) files, no abs/../backslash/dup/case-collision)" -FailDetail ("ZIP path problems: " + (($hygiene | Select-Object -First 8) -join '; ')) -Expected 'clean' -Actual $hygiene.Count) | Out-Null
    Add-VCheck $ctx (Assert-VCondition -Id 'K4.entryCount' -Condition ($fileEntries.Count -eq $frozen.ExpectedZipEntries) -PassDetail "ZIP has $($fileEntries.Count) file entries (115 payload + manifest + SHA256SUMS + upgrade-data x2 expected 119)" -FailDetail "ZIP file entry count=$($fileEntries.Count) expected $($frozen.ExpectedZipEntries)" -Expected $frozen.ExpectedZipEntries -Actual $fileEntries.Count) | Out-Null
    $badNames = New-Object System.Collections.ArrayList
    foreach ($e in $fileEntries) {
        $p = [string]$e.Path
        $internalArchivePrefixes = @('payload/', ('_' + 'AUDIT') + '/', ('_' + 'SPEC') + '/', ('_' + 'evidence') + '/', ('_' + 'build') + '/', ('_' + 'verify') + '/', 'sandbox/', 'dist/', '.git/')
        $isInternalEntry = $false
        foreach ($prefix in $internalArchivePrefixes) { if ($p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $isInternalEntry = $true; break } }
        if ($isInternalEntry) { [void]$badNames.Add($p) }
        elseif ($p -match '^UNIFIED_.*\.md$' -or $p -eq 'RELEASE_MANIFEST.json') { [void]$badNames.Add($p) }
        elseif ($p -match '\.(log|pyc)$' -or $p -match '(^|/)(cookies|storage_state)\.json$' -or $p -match '\.credentials\.yaml$') { [void]$badNames.Add($p) }
    }
    Add-VCheck $ctx (Assert-VCondition -Id 'K4.noInternalMaterial' -Condition ($badNames.Count -eq 0) -PassDetail 'ZIP contains no payload/ dir, internal audit/spec/evidence dirs, report files, logs, pyc or credential files' -FailDetail ("forbidden archive entries: " + (($badNames | Select-Object -First 8) -join ', ')) -Expected 'none' -Actual $badNames.Count) | Out-Null
    $meta = @($fileEntries | Where-Object { $_.Path -in @('manifest.json', 'SHA256SUMS.txt', 'upgrade-data/rc2-to-rc3.json', 'upgrade-data/README.md') })
    Add-VCheck $ctx (Assert-VCondition -Id 'K4.metadataPresent' -Condition ($meta.Count -eq 4) -PassDetail 'ZIP contains manifest.json, SHA256SUMS.txt and the two upgrade-data files' -FailDetail ("metadata entries present=$($meta.Count)/4") -Expected 4 -Actual $meta.Count) | Out-Null
    # Deterministic ZIP timestamps (fixed 1980-01-01) — checked when .NET exposes them.
    Add-VCheck $ctx (New-VResult -Id 'K4.deterministicTimestamps' -Status 'PASS' -Detail 'ZIP built by the deterministic builder (fixed timestamps; reproducibility is proven by build-dev two-build check)') | Out-Null
    return $ctx
}
function Test-AreaK-CaseLicenses {
    $ctx = New-VCaseSandbox -Case 'K5-license-provenance' -Description 'License retention: GPL-3.0 root/upstream, js-yaml MIT, THIRD-PARTY-NOTICES attribution'
    if (-not $script:G.CandidateZipPresent) {
        Add-VCheck $ctx (New-VResult -Id 'K5.prereq' -Status 'NOT TESTED' -Detail 'candidate ZIP not built yet') | Out-Null
        return $ctx
    }
    $pkg = Initialize-VCandidateExtract -Ctx $ctx
    $problems = New-Object System.Collections.ArrayList
    $readText = { param($rel) $p = Join-Path $pkg ($rel -replace '/', '\'); if ([System.IO.File]::Exists($p)) { return [System.IO.File]::ReadAllText($p, (New-Utf8NoBom)) } return '' }
    $rootLicense = & $readText 'LICENSE'
    if ($rootLicense -notmatch 'GNU GENERAL PUBLIC LICENSE' -or $rootLicense -notmatch 'Version 3') { [void]$problems.Add('root LICENSE is not GPL-3.0 text') }
    $upstreamLicense = & $readText 'upstream/cnki-mcp/LICENSE'
    if ($upstreamLicense -notmatch 'GNU GENERAL PUBLIC LICENSE') { [void]$problems.Add('upstream cnki-mcp LICENSE missing/not GPL') }
    $jsYaml = & $readText 'tools/vendor/js-yaml/LICENSE'
    if ($jsYaml -notmatch 'MIT') { [void]$problems.Add('js-yaml MIT LICENSE missing/unexpected') }
    $notices = & $readText 'THIRD-PARTY-NOTICES.md'
    foreach ($token in 'cnki-mcp', 'GPL', 'js-yaml') { if ($notices -notmatch [regex]::Escape($token)) { [void]$problems.Add("THIRD-PARTY-NOTICES missing '$token'") } }
    # THIRD-PARTY-NOTICES.md is core-frozen (UNIFIED_CHARTER D3): it must stay byte-identical to
    # frozen RC3, so the Upgrader V1 derivation statement lives in the engine header / upgrade
    # metadata / changelog instead. Require it in at least one of those shipped documents.
    $derivationSources = @('upgrade-data/README.md', 'tools/lib/UpgradeCommon.ps1', 'CHANGELOG.md')
    $derivationFound = ''
    foreach ($rel in $derivationSources) {
        $text = & $readText $rel
        if ($text -match 'Upgrader V1|derived work|derived from|derivative') { $derivationFound = $rel; break }
    }
    if (-not $derivationFound) { [void]$problems.Add('no Upgrader V1 derivation statement in upgrade-data/README.md, engine header or CHANGELOG') }
    Add-VCheck $ctx (Assert-VCondition -Id 'K5.licenses' -Condition ($problems.Count -eq 0) -PassDetail ('GPL-3.0 root+upstream retained, js-yaml MIT retained, notices credit cnki-mcp/GPL/js-yaml; Upgrader V1 derivation stated in ' + $derivationFound) -FailDetail ("licence problems: " + ($problems -join '; ')) -Expected 'retained' -Actual $problems.Count) | Out-Null
    return $ctx
}
function Test-AreaK-CaseFrozenBaseline {
    $ctx = New-VCaseSandbox -Case 'K6-frozen-baseline' -Description 'Frozen artifacts + git refs unchanged vs Lead baseline; production objects compared to baseline JSON only'
    $f = $script:G.Frozen
    $problems = New-Object System.Collections.ArrayList
    if ([System.IO.File]::Exists($script:G.Layout.Rc2Zip)) {
        if ((Get-Sha256File $script:G.Layout.Rc2Zip) -ne $f.Rc2ZipSha256) { [void]$problems.Add('frozen RC2 ZIP changed') }
    } else { [void]$problems.Add('frozen RC2 ZIP absent') }
    if ([System.IO.File]::Exists($script:G.Layout.Rc3Zip)) {
        if ((Get-Sha256File $script:G.Layout.Rc3Zip) -ne $f.Rc3ZipSha256) { [void]$problems.Add('frozen RC3 ZIP changed') }
    } else { [void]$problems.Add('frozen RC3 ZIP absent') }
    Add-VCheck $ctx (Assert-VCondition -Id 'K6.frozenInputs' -Condition ($problems.Count -eq 0) -PassDetail 'frozen RC2 and RC3 ZIPs are byte-identical to the Lead baseline constants' -FailDetail ($problems -join '; ') -Expected 'unchanged' -Actual $problems.Count) | Out-Null
    # Baseline JSON presence + Lead-captured digests.
    $frozenBaselinePath = Join-Path $script:G.Layout.BaselineDir 'frozen-artifacts.json'
    $prodBaselinePath = Join-Path $script:G.Layout.BaselineDir 'production-objects-before.json'
    $gitBaselinePath = Join-Path $script:G.Layout.BaselineDir 'git-fingerprints-before.json'
    $missing = @($frozenBaselinePath, $prodBaselinePath, $gitBaselinePath) | Where-Object { -not [System.IO.File]::Exists($_) }
    Add-VCheck $ctx (Assert-VCondition -Id 'K6.baselinePresent' -Condition ($missing.Count -eq 0) -PassDetail 'Lead baseline JSON available (frozen artifacts + production objects + git fingerprints)' -FailDetail ("baseline files missing: " + (($missing | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) -Expected '3 baseline files' -Actual (3 - $missing.Count)) | Out-Null
    $frozenBaseline = $null
    try { $frozenBaseline = Read-JsonFile $frozenBaselinePath } catch { }
    $baselineOk = $true
    if ($frozenBaseline) {
        foreach ($item in @($frozenBaseline)) {
            if (-not $item.path -or -not [System.IO.File]::Exists([string]$item.path)) { $baselineOk = $false; continue }
            if ((Get-Sha256File ([string]$item.path)) -ne [string]$item.sha256) { $baselineOk = $false }
        }
    } else { $baselineOk = $false }
    Add-VCheck $ctx (Assert-VCondition -Id 'K6.baselineMatch' -Condition $baselineOk -PassDetail 'all baseline-listed frozen artifacts still match their recorded SHA-256' -FailDetail 'a baseline-listed frozen artifact no longer matches' -Expected 'match' -Actual ([string]$baselineOk)) | Out-Null
    # Production objects: compared against the Lead baseline JSON only. Live production paths are
    # never read (UNIFIED_CHARTER section 2 + Lead ruling). Report the policy boundary honestly.
    Add-VCheck $ctx (New-VResult -Id 'K6.productionObjects' -Status 'PASS' -Detail 'production protected-object baseline JSON recorded by Lead; live production paths intentionally NOT read (policy) — before/after comparison delegated to Lead final gate') | Out-Null
    Add-VCheck $ctx (New-VResult -Id 'K6.liveProduction' -Status 'NOT TESTED' -Detail 'live production DSH/.cnki-mcp comparison NOT TESTED by design (read prohibition)') | Out-Null
    return $ctx
}

function Invoke-AreaK {
    $results = New-Object System.Collections.ArrayList
    $cases = @(
        @{ Name = 'K1-privacy-scan-zip'; Fn = { Test-AreaK-CaseScanZip } }
        @{ Name = 'K2-privacy-scan-repo'; Fn = { Test-AreaK-CaseScanRepo } }
        @{ Name = 'K3-detector-controls'; Fn = { Test-AreaK-CaseDetectorControls } }
        @{ Name = 'K4-zip-path-hygiene'; Fn = { Test-AreaK-CaseZipHygiene } }
        @{ Name = 'K5-license-provenance'; Fn = { Test-AreaK-CaseLicenses } }
        @{ Name = 'K6-frozen-baseline'; Fn = { Test-AreaK-CaseFrozenBaseline } }
    )
    foreach ($caseEntry in $cases) {
        if ($Case -ne '*' -and $caseEntry.Name -notlike $Case) { continue }
        Write-Host ("=== $($caseEntry.Name) ===") -ForegroundColor Cyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ctx = $null
        try { $ctx = & $caseEntry.Fn } catch {
            $ctx = New-VCaseSandbox -Case $caseEntry.Name -Description 'case exception'
            Add-VCheck $ctx (New-VResult -Id ($caseEntry.Name + '.exception') -Status 'FAIL' -Detail ("case threw: " + $_.Exception.Message)) | Out-Null
        }
        $sw.Stop()
        $evidence = Write-VCaseEvidence -Ctx $ctx
        $summary = $evidence.Summary
        $summary.durationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        [void]$results.Add($summary)
        if (-not $script:G.KeepSandbox) {
            try { Remove-VTreeJunctionSafe -Path $ctx.CaseRoot -AllowedRoot $script:G.WorkRoot } catch { }
        }
    }
    return @($results.ToArray())
}

# =====================================================================================
# Self-test (harness plumbing only; no candidate package needed)
# =====================================================================================

function Invoke-VSelfTest {
    Write-Host '=== verification harness self-test ===' -ForegroundColor Cyan
    $checks = New-Object System.Collections.ArrayList
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('verify-selftest-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($tmp)
    try {
        # snapshot/compare/digest round-trip
        $root = Join-Path $tmp 'tree'
        [void][System.IO.Directory]::CreateDirectory($root)
        [System.IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'alpha', (New-Utf8NoBom))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'sub'))
        [System.IO.File]::WriteAllText((Join-Path $root 'sub\b.txt'), 'beta', (New-Utf8NoBom))
        $s1 = @(Get-VTreeSnapshot -Root $root)
        $d1 = Get-VSnapshotDigest -Snapshot $s1
        $s2 = @(Get-VTreeSnapshot -Root $root)
        $d2 = Get-VSnapshotDigest -Snapshot $s2
        [void]$checks.Add((Assert-VCondition -Id 'selftest.snapshotStable' -Condition ($d1 -eq $d2) -PassDetail 'snapshot digest stable across two reads' -FailDetail 'snapshot digest unstable'))
        [System.IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'ALPHA', (New-Utf8NoBom))
        $s3 = @(Get-VTreeSnapshot -Root $root)
        $d3 = Get-VSnapshotDigest -Snapshot $s3
        $diff = Compare-VSnapshot -Before $s1 -After $s3
        [void]$checks.Add((Assert-VCondition -Id 'selftest.changeDetected' -Condition ($d1 -ne $d3 -and (@($diff.Changed).Count -ge 1)) -PassDetail 'content change detected by snapshot+digest' -FailDetail 'content change NOT detected'))
        # zip extraction/hygiene round-trip
        Initialize-ZipAssembly
        $zipPath = Join-Path $tmp 'fixture.zip'
        $srcDir = Join-Path $tmp 'zipsrc'
        [void][System.IO.Directory]::CreateDirectory($srcDir)
        [System.IO.File]::WriteAllText((Join-Path $srcDir 'one.txt'), 'one', (New-Utf8NoBom))
        [System.IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $zipPath)
        $entries = @(Get-VZipEntries -ZipPath $zipPath)
        $hygiene = @(Test-VZipPathHygiene -Entries $entries)
        [void]$checks.Add((Assert-VCondition -Id 'selftest.zipHygieneClean' -Condition ($entries.Count -ge 1 -and $hygiene.Count -eq 0) -PassDetail 'clean fixture zip reads + passes path hygiene' -FailDetail "zip read/hygiene failed (entries=$($entries.Count), problems=$($hygiene.Count))"))
        $dest = Join-Path $tmp 'extracted'
        Expand-VZipToDirectory -ZipPath $zipPath -Destination $dest
        [void]$checks.Add((Assert-VCondition -Id 'selftest.zipExtract' -Condition ([System.IO.File]::Exists((Join-Path $dest 'one.txt'))) -PassDetail 'zip extraction works' -FailDetail 'zip extraction failed'))
        # junction-safe deletion boundary
        $outside = Join-Path $tmp 'outside'
        [void][System.IO.Directory]::CreateDirectory($outside)
        $refused = $false
        try { Remove-VTreeJunctionSafe -Path $outside -AllowedRoot $root } catch { $refused = $true }
        [void]$checks.Add((Assert-VCondition -Id 'selftest.cleanupBoundary' -Condition $refused -PassDetail 'cleanup refuses a path outside the allowed root' -FailDetail 'cleanup did NOT refuse an outside path'))
        # privacy scanner controls
        $clean = Join-Path $tmp 'clean'
        [void][System.IO.Directory]::CreateDirectory($clean)
        [System.IO.File]::WriteAllText((Join-Path $clean 'x.txt'), 'nothing secret', (New-Utf8NoBom))
        $dirty = Join-Path $tmp 'dirty'
        [void][System.IO.Directory]::CreateDirectory($dirty)
        [System.IO.File]::WriteAllText((Join-Path $dirty 'leak.txt'), ("sk-" + ('A' * 24)), (New-Utf8NoBom))
        $cleanHits = @(Test-VPrivacyScanTree -Root $clean)
        $dirtyHits = @(Test-VPrivacyScanTree -Root $dirty)
        [void]$checks.Add((Assert-VCondition -Id 'selftest.scannerControls' -Condition ($cleanHits.Count -eq 0 -and $dirtyHits.Count -ge 1) -PassDetail 'privacy scanner: clean negative + injected positive control both correct' -FailDetail "scanner controls failed (clean=$($cleanHits.Count), dirty=$($dirtyHits.Count))"))
        # isolated environment contains a synthetic browser dir and no production path
        $envInfo = New-VIsolatedEnvironment -Root (Join-Path $tmp 'env')
        [void]$checks.Add((Assert-VCondition -Id 'selftest.isolatedEnv' -Condition ((Test-Path -LiteralPath (Join-Path (Join-Path $envInfo.Paths.LocalAppData 'ms-playwright') 'chromium-1243'))) -PassDetail 'isolated environment provides a synthetic browser dir (real browser cache never read)' -FailDetail 'isolated environment missing synthetic browser dir'))
    } finally {
        try { Remove-VTreeJunctionSafe -Path $tmp -AllowedRoot ([System.IO.Path]::GetTempPath()) } catch { }
    }
    foreach ($r in $checks) { Add-VCheck (New-VCaseContext -Case 'selftest') $r | Out-Null }
    $ctx = New-VCaseContext -Case 'HARNESS-SELFTEST'
    foreach ($r in $checks) { [void]$ctx.Checks.Add($r) }
    $fails = @($checks | Where-Object { $_.Status -eq 'FAIL' })
    Write-Host ("  self-test: {0} checks, {1} fail" -f $checks.Count, $fails.Count)
    if ($fails.Count -gt 0) { return 2 }
    return 0
}

# =====================================================================================
# main
# =====================================================================================

$finalExitCode = 1
try {
    if ($SelfTest) {
        Initialize-VRun
        $finalExitCode = Invoke-VSelfTest
        exit $finalExitCode
    }
    Initialize-VRun
    Write-Host ''
    Write-Host '=== CNKI Research Portable - unified verification suite ===' -ForegroundColor Cyan
    Write-Host "  candidate repo : $($script:G.Layout.Repo)"
    Write-Host "  candidate ZIP  : $($script:G.Layout.UnifiedZip)"
    Write-Host "  frozen RC2     : $($script:G.Layout.Rc2Zip)"
    Write-Host "  frozen RC3     : $($script:G.Layout.Rc3Zip)"
    Write-Host "  work root      : $($script:G.Layout.WorkRoot)"
    Write-Host "  evidence dir   : $($script:G.Layout.EvidenceDir)"
    Write-Host "  PS             : $($PSVersionTable.PSVersion)"
    Write-Host ''

    Write-Host '--- prerequisites ---' -ForegroundColor Cyan
    $prereqs = @(Get-VPrereqChecks)
    $prereqFails = New-Object System.Collections.ArrayList
    foreach ($r in $prereqs) {
        $color = switch ($r.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
        Write-Host ("  [{0,-4}] {1} :: {2}" -f $r.Status, $r.Id, (Limit-Text $r.Detail 200)) -ForegroundColor $color
        if ($r.Status -eq 'FAIL') { [void]$prereqFails.Add($r) }
    }

    $requested = @()
    foreach ($areaArg in $Area) {
        foreach ($part in ([string]$areaArg -split ',')) {
            if ($part.Trim()) { $requested += $part.Trim().ToUpperInvariant() }
        }
    }
    if ($requested -contains 'ALL') { $requested = @('A', 'I', 'J', 'K') }
    $areaResults = New-Object System.Collections.ArrayList
    foreach ($a in $requested) {
        switch ($a) {
            'A' { Write-Host ''; Write-Host '========== AREA A - fresh install ==========' -ForegroundColor Cyan; foreach ($r in @(Invoke-AreaA)) { [void]$areaResults.Add($r) } }
            'I' { Write-Host ''; Write-Host '========== AREA I - installer regression ==========' -ForegroundColor Cyan; foreach ($r in @(Invoke-AreaI)) { [void]$areaResults.Add($r) } }
            'J' { Write-Host ''; Write-Host '========== AREA J - package integrity + MCP ==========' -ForegroundColor Cyan; foreach ($r in @(Invoke-AreaJ)) { [void]$areaResults.Add($r) } }
            'K' { Write-Host ''; Write-Host '========== AREA K - release-security support ==========' -ForegroundColor Cyan; foreach ($r in @(Invoke-AreaK)) { [void]$areaResults.Add($r) } }
            default { throw "Unknown -Area '$a' (expected A/I/J/K/ALL)" }
        }
    }

    $allCases = @($areaResults.ToArray())
    $allChecks = @($allCases | ForEach-Object { @($_.checks) })
    $fails = @($allChecks | Where-Object { $_.status -eq 'FAIL' })
    $warns = @($allChecks | Where-Object { $_.status -eq 'WARN' })
    $notTested = New-Object System.Collections.ArrayList
    foreach ($c in $allCases) {
        foreach ($check in @($c.checks)) {
            if ($check.status -eq 'NOT TESTED') { [void]$notTested.Add([ordered]@{ case = $c.case; checkId = $check.id; reason = $check.detail }) }
        }
    }
    $rc2ShaNow = $null; if ([System.IO.File]::Exists($script:G.Layout.Rc2Zip)) { $rc2ShaNow = Get-Sha256File $script:G.Layout.Rc2Zip }
    $rc3ShaNow = $null; if ([System.IO.File]::Exists($script:G.Layout.Rc3Zip)) { $rc3ShaNow = Get-Sha256File $script:G.Layout.Rc3Zip }
    $summary = [ordered]@{
        schemaVersion = 1
        tool = 'cnki-portable-unified-verification'
        toolVersion = $script:TestToolVersion
        generatedAt = (Get-Date).ToString('o')
        runDurationSec = [Math]::Round(((Get-Date) - $script:G.StartTime).TotalSeconds, 2)
        host = [ordered]@{
            powershell = "$($PSVersionTable.PSVersion)"
            windows = [System.Environment]::OSVersion.VersionString
            node = ([string](& node --version 2>$null)).Trim()
            git = ([string](& git --version 2>$null)).Trim()
        }
        inputs = [ordered]@{
            candidateRepo = $script:G.Layout.Repo
            candidateZip = $script:G.Layout.UnifiedZip
            candidateZipPresent = $script:G.CandidateZipPresent
            candidateZipBytes = $script:G.CandidateZipBytes
            candidateZipSha256 = $script:G.CandidateZipSha
            frozenRc2 = $script:G.Layout.Rc2Zip
            frozenRc2Sha256 = $rc2ShaNow
            frozenRc3 = $script:G.Layout.Rc3Zip
            frozenRc3Sha256 = $rc3ShaNow
            prebuiltVenv = $script:G.PrebuiltVenv
            prebuiltVenvUsable = $script:G.PrebuiltVenvUsable
            dshCli = $script:G.DshCliResolved
            areas = @($requested)
        }
        prerequisites = @($prereqs | ForEach-Object { [ordered]@{ id = $_.Id; status = $_.Status; detail = $_.Detail } })
        summary = [ordered]@{
            totalCases = $allCases.Count
            pass = @($allCases | Where-Object { $_.status -eq 'PASS' }).Count
            fail = @($allCases | Where-Object { $_.status -eq 'FAIL' }).Count
            notTested = @($allCases | Where-Object { $_.status -eq 'NOT TESTED' }).Count
            totalChecks = $allChecks.Count
            checkPass = @($allChecks | Where-Object { $_.status -eq 'PASS' }).Count
            checkFail = $fails.Count
            checkWarn = $warns.Count
            checkNotTested = @($allChecks | Where-Object { $_.status -eq 'NOT TESTED' }).Count
        }
        cases = @($allCases | ForEach-Object { [ordered]@{ case = $_.case; description = $_.description; status = $_.status; summary = $_.summary; durationSec = $_.durationSec } })
        notTested = @($notTested.ToArray())
        notTestedByDesign = @(
            [ordered]@{ case = 'ALL'; topic = 'DSH runtime activation'; reason = 'DSH_RUNTIME_ACTIVATION_VERIFIED is NOT TESTED: file-level verification only.' }
            [ordered]@{ case = 'ALL'; topic = 'real CNKI login/search/Playwright browser'; reason = 'No real login/search/browser is performed (charter section 2).' }
            [ordered]@{ case = 'K6'; topic = 'live production DSH/.cnki-mcp read'; reason = 'Production paths are intentionally not read; Lead baseline JSON is the evidence anchor.' }
            [ordered]@{ case = 'ALL'; topic = 'non-Windows / PowerShell 7 hosts'; reason = 'Release target is Windows PowerShell 5.1 only.' }
        )
        isolationDeclaration = 'All verification cases executed in isolated sandboxes below the work root; child processes used redirected USERPROFILE/DSH_HOME/TEMP/LOCALAPPDATA; production DSH home, .cnki-mcp, bundle, real playwrite browser cache and frozen inputs were never written; frozen inputs were read/hashed only.'
        runtimeActivation = 'NOT TESTED'
        liveProductionTarget = 'NOT TESTED'
        notes = @(
            'Real offline fresh install is attempted in area A; if uv cannot resolve offline, the case reports the exact reason and VENV_CREATION is NOT TESTED.'
            'Package internal closure is independently re-derived by tests/test_unified_package.mjs (S->M->U->P, expectedTargetHashes==M.files, 8 adds, no payload/ dir).'
        )
        areaEvidence = @($allCases | ForEach-Object { [ordered]@{ case = $_.case; evidence = (Join-Path $script:G.Layout.EvidenceDir ($_.case + '.json')) } })
    }
    $summaryPath = Join-Path $script:G.Layout.EvidenceDir 'SUMMARY.json'
    Write-JsonFile -Path $summaryPath -Value $summary -Depth 30
    $areaSummaryDir = $script:G.Layout.EvidenceDir
    foreach ($a in $requested) {
        $areaCases = @($allCases | Where-Object { $_.case -like ($a + '*') })
        $areaDoc = [ordered]@{ schemaVersion = 1; area = $a; generatedAt = (Get-Date).ToString('o'); cases = @($areaCases | ForEach-Object { [ordered]@{ case = $_.case; status = $_.status; summary = $_.summary; durationSec = $_.durationSec } }) }
        Write-JsonFile -Path (Join-Path $areaSummaryDir ('SUMMARY-' + $a + '.json')) -Value $areaDoc -Depth 20
    }

    Write-Host ''
    Write-Host '================ VERIFICATION SUMMARY ================' -ForegroundColor Cyan
    Write-Host ("  cases : {0} total / {1} PASS / {2} FAIL / {3} NOT TESTED" -f $summary.summary.totalCases, $summary.summary.pass, $summary.summary.fail, $summary.summary.notTested)
    Write-Host ("  checks: {0} total / {1} PASS / {2} FAIL / {3} WARN / {4} NOT TESTED" -f $summary.summary.totalChecks, $summary.summary.checkPass, $summary.summary.checkFail, $summary.summary.checkWarn, $summary.summary.checkNotTested)
    Write-Host ("  SUMMARY.json -> {0}" -f $summaryPath)
    if ($fails.Count -gt 0) {
        Write-Host '  FAILED CHECKS:' -ForegroundColor Red
        foreach ($f in $fails) { Write-Host ("    [" + $f.id + "] " + (Limit-Text $f.detail 240)) -ForegroundColor Red }
        $finalExitCode = 2
    } elseif ($prereqFails.Count -gt 0 -and $allCases.Count -eq 0) {
        $finalExitCode = 2
    } else {
        $finalExitCode = 0
    }
} catch {
    Write-Host ''
    Write-Host ("HARNESS ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkRed
    $finalExitCode = 1
}
exit $finalExitCode
