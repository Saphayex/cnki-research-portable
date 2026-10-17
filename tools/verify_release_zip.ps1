# Verify a released ZIP as an end user would receive it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify_release_zip.ps1 [-Zip <path>] [-Json]
#
# Why this exists
# ---------------
# Testing the development tree does not prove the *archive* is good: `Compress-Archive`
# could drop files, the staging step could miss a payload entry, or a path could break
# once the package is no longer at its build location. This script therefore:
#
#   1. extracts the zip into a brand-new temporary directory;
#   2. re-runs the integrity check there against the manifest shipped inside the zip;
#   3. re-runs the full static package suite from the extracted copy;
#   4. checks structure, the absence of development leftovers, and that the extracted
#      tree is byte-identical to the recorded payload;
#   5. exercises the installer's read-only `check` on the extracted copy.
#
# It never installs, never writes to a DSH home and never touches user data.

[CmdletBinding()]
param(
    [string]$Zip,
    [string]$WorkDir,
    [switch]$Json,
    [switch]$KeepExtracted
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\PortableCommon.ps1')

$packageRoot = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..')).FullName
$checks = New-Object System.Collections.ArrayList
function Add-Result { param([string]$Id, [string]$Status, [string]$Detail)
    [void]$checks.Add([pscustomobject]@{ id = $Id; status = $Status; detail = $Detail })
    if (-not $Json) { Write-Item -Status $Status -Text "${Id}: $Detail" }
}

# --- locate the zip ---------------------------------------------------------
if (-not $Zip) {
    $dist = Join-Path $packageRoot 'dist'
    $candidate = @(Get-ChildItem -LiteralPath $dist -Filter '*.zip' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($candidate.Count -eq 0) { throw "no zip found under $dist; run tools\package_release.ps1 first, or pass -Zip" }
    $Zip = $candidate[0].FullName
}
$Zip = Get-NormalizedPath -Path $Zip
if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw "zip not found: $Zip" }

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "cnki-portable-verify-$stamp" }
$WorkDir = Get-NormalizedPath -Path $WorkDir
$extractRoot = Join-Path $WorkDir 'extracted'
if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

if (-not $Json) { Write-Section "Verifying $([System.IO.Path]::GetFileName($Zip))" }

# --- 1. hash of the archive -------------------------------------------------
$zipHash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
$zipBytes = (Get-Item -LiteralPath $Zip).Length
$sidecar = "$Zip.sha256"
if (Test-Path -LiteralPath $sidecar) {
    $recorded = ([string](Get-Content -LiteralPath $sidecar -Raw)).Trim().Split(' ')[0].ToLowerInvariant()
    if ($recorded -eq $zipHash) { Add-Result 'Z1.zipHash' 'PASS' "sha256 $zipHash matches $([System.IO.Path]::GetFileName($sidecar))" }
    else { Add-Result 'Z1.zipHash' 'FAIL' "sha256 $zipHash does not match the sidecar $recorded" }
} else {
    Add-Result 'Z1.zipHash' 'PASS' "sha256 $zipHash ($zipBytes bytes); no sidecar to compare"
}

# --- 2. extract -------------------------------------------------------------
Expand-Archive -LiteralPath $Zip -DestinationPath $extractRoot -Force
$extracted = @(Get-ChildItem -LiteralPath $extractRoot -Force)
if ($extracted.Count -eq 1 -and $extracted[0].PSIsContainer) { $root = $extracted[0].FullName }
else { $root = $extractRoot }
Add-Result 'Z2.extracted' 'PASS' "extracted to $root"

# --- 3. expected entry points ----------------------------------------------
$required = @(
    'START_HERE.md', 'INSTALL_PROMPT.md', 'VERSION', 'manifest.json', 'PROJECT_STATE.md',
    'bundle\cnki-research\package.json',
    'bundle\cnki-research\cordis.patch.yml',
    'bundle\cnki-research\launcher\cnki_research_launcher.py',
    'bundle\cnki-research\skills\cnki-literature-search\SKILL.md',
    'tools\portable.ps1', 'tools\lib\PortableCommon.ps1', 'tools\build_manifest.mjs',
    'tools\package_release.ps1', 'tools\verify_release_zip.ps1', 'tools\probe_mcp_stdio.py',
    'tests\run_all.ps1', 'tests\test_static_package.mjs', 'tests\test_tool_schema.mjs',
    'tests\test_dsh_isolated.ps1',
    'upstream\cnki-mcp\pyproject.toml', 'upstream\cnki-mcp\uv.lock', 'upstream\cnki-mcp\LICENSE',
    'LICENSE', 'THIRD-PARTY-NOTICES.md', 'CHANGELOG.md'
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) })
if ($missing.Count -eq 0) { Add-Result 'Z3.entryPoints' 'PASS' "all $($required.Count) required entry point(s) present after extraction" }
else { Add-Result 'Z3.entryPoints' 'FAIL' "missing after extraction: $($missing -join ', ')" }

# --- 4. no development leftovers -------------------------------------------
$forbiddenNames = @('_scratch', '.venv', 'node_modules', '__pycache__', '_portable')
$leaks = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in $forbiddenNames })
$leaks += @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @('.pyc', '.log') -or $_.Name -eq 'portable.runtime.json' })
$leaks += @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(cookies|storage_state)\.json$' -or $_.Name -eq '.credentials.yaml' })
if ($leaks.Count -eq 0) { Add-Result 'Z4.noLeftovers' 'PASS' 'no runtime artefact, log, credential or generated runtime descriptor in the archive' }
else { Add-Result 'Z4.noLeftovers' 'FAIL' "$($leaks.Count) artefact(s) must not ship: $(($leaks | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')" }

# --- 5. manifest integrity, from the extracted copy -------------------------
$manifestPath = Join-Path $root 'manifest.json'
$manifest = Read-JsonFile -Path $manifestPath
if (-not $manifest) {
    Add-Result 'Z5.integrity' 'FAIL' 'manifest.json is missing or unreadable inside the archive'
} else {
    $problems = @(Test-PackageIntegrity -PackageRoot $root -Manifest $manifest)
    if ($problems.Count -eq 0) { Add-Result 'Z5.integrity' 'PASS' "$(@($manifest.files).Count) payload file(s) match size and SHA-256 after extraction" }
    else { Add-Result 'Z5.integrity' 'FAIL' "$($problems.Count) problem(s): $(($problems | Select-Object -First 5) -join '; ')" }
}

# --- 6. full static suite, run from the extracted copy ---------------------
$staticScript = Join-Path $root 'tests\test_static_package.mjs'
if (Test-Path -LiteralPath $staticScript -PathType Leaf) {
    $staticReport = Join-Path $WorkDir 'static-extracted.json'
    # Native tools write progress to stderr; under $ErrorActionPreference='Stop'
    # Windows PowerShell 5.1 would turn that into a terminating error.
    $before = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $nodeOut = & node $staticScript --json --write-report $staticReport 2>&1 }
    finally { $ErrorActionPreference = $before }
    $staticJson = Read-JsonFile -Path $staticReport
    if ($staticJson) {
        $fails = @($staticJson.checks | Where-Object { $_.status -eq 'FAIL' })
        if ($fails.Count -eq 0) { Add-Result 'Z6.staticSuite' 'PASS' "$(@($staticJson.checks).Count) check(s) pass on the extracted copy" }
        else { Add-Result 'Z6.staticSuite' 'FAIL' "$($fails.Count) check(s) failed: $(($fails | Select-Object -First 3 | ForEach-Object { $_.id }) -join ', ')" }
    } else {
        $tail = (($nodeOut | Out-String).Trim() -split "`n" | Select-Object -Last 1)
        Add-Result 'Z6.staticSuite' 'FAIL' "the static suite produced no report: $tail"
    }
} else {
    Add-Result 'Z6.staticSuite' 'FAIL' 'tests\test_static_package.mjs is not in the archive'
}

# --- 7. the installer's read-only check on the extracted copy ---------------
$installer = Join-Path $root 'tools\portable.ps1'
if (Test-Path -LiteralPath $installer -PathType Leaf) {
    # A throwaway DSH home: this must not read the real one.
    $probeHome = Join-Path $WorkDir 'probe-home'
    New-Item -ItemType Directory -Force -Path $probeHome | Out-Null
    $checkOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $installer `
        -Action check -PackageRoot $root -InstallRoot $root -DshHome $probeHome -DshProfile probe -Json 2>&1
    $checkJson = ($checkOut | Out-String) | ConvertFrom-Json
    if ($checkJson -and $checkJson.summary) {
        $checkFails = @($checkJson.checks | Where-Object { $_.status -eq 'FAIL' })
        # A missing DSH profile/CLI is expected on a clean machine; only report
        # integrity and structure failures as defects of the archive.
        $structural = @($checkFails | Where-Object { $_.id -like 'package.*' -or $_.id -like 'bundle.*' -or $_.id -like 'upstream.*' })
        if ($structural.Count -eq 0) {
            Add-Result 'Z7.installerCheck' 'PASS' "installer check ran on the extracted copy ($($checkJson.summary.pass) pass, $($checkFails.Count) fail all environmental)"
        } else {
            Add-Result 'Z7.installerCheck' 'FAIL' "$($structural.Count) structural failure(s): $(($structural | ForEach-Object { $_.id }) -join ', ')"
        }
    } else {
        Add-Result 'Z7.installerCheck' 'FAIL' "the installer check produced no JSON report"
    }
} else {
    Add-Result 'Z7.installerCheck' 'FAIL' 'tools\portable.ps1 is not in the archive'
}

# --- 8. path portability of the extracted location --------------------------
# Re-extract into a path with a space and non-ASCII characters and re-verify.
$trickyBase = Join-Path ([System.IO.Path]::GetTempPath()) 'cnki portable 验证 目录'
$trickyRoot = Join-Path $trickyBase $stamp
try {
    New-Item -ItemType Directory -Force -Path $trickyRoot | Out-Null
    Expand-Archive -LiteralPath $Zip -DestinationPath $trickyRoot -Force
    $inner = @(Get-ChildItem -LiteralPath $trickyRoot -Force)
    if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $tricky = $inner[0].FullName } else { $tricky = $trickyRoot }
    $trickyProblems = @(Test-PackageIntegrity -PackageRoot $tricky -Manifest (Read-JsonFile -Path (Join-Path $tricky 'manifest.json')))
    if ($trickyProblems.Count -eq 0) { Add-Result 'Z8.trickyPath' 'PASS' "verified intact after extraction under '$tricky'" }
    else { Add-Result 'Z8.trickyPath' 'FAIL' "$($trickyProblems.Count) problem(s) under a space/CJK path: $(($trickyProblems | Select-Object -First 3) -join '; ')" }
} catch {
    Add-Result 'Z8.trickyPath' 'FAIL' "could not verify under a space/CJK path: $($_.Exception.Message)"
} finally {
    if (-not $KeepExtracted) { Remove-Item -LiteralPath $trickyBase -Recurse -Force -ErrorAction SilentlyContinue }
}

$fails = @($checks | Where-Object { $_.status -eq 'FAIL' })
$summary = [pscustomobject]@{
    pass = @($checks | Where-Object { $_.status -eq 'PASS' }).Count
    fail = $fails.Count
}
$report = [pscustomobject]@{
    suite = 'release-zip'
    zip = $Zip
    zipBytes = $zipBytes
    zipSha256 = $zipHash
    extractedRoot = $root
    summary = $summary
    ok = ($fails.Count -eq 0)
    checks = @($checks)
}
Write-JsonFile -Path (Join-Path $WorkDir 'release-zip-verification.json') -Value $report

if (-not $KeepExtracted) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue }

if ($Json) { Write-Output ($report | ConvertTo-Json -Depth 8) }
else {
    Write-Section 'Release zip verification'
    if ($fails.Count -eq 0) { Write-Item -Status 'PASS' -Text "the archive verifies as a distributable release" }
    else { Write-Item -Status 'FAIL' -Text "$($fails.Count) problem(s) found" }
    Write-Host "  zip    : $Zip"
    Write-Host "  sha256 : $zipHash"
    Write-Host "  report : $(Join-Path $WorkDir 'release-zip-verification.json')"
}
if ($fails.Count -gt 0) { exit 1 }
exit 0
