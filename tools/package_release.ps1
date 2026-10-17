# Package the CNKI Research Portable distribution into a distributable zip.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\package_release.ps1 [-OutputDir <dir>] [-SkipVerify]
#
# The payload list comes from manifest.json, so _scratch\, dist\, .venv\,
# node_modules\, _portable\ and __pycache__ are excluded by construction. Every
# file is re-hashed before staging; a mismatch aborts the packaging.

[CmdletBinding()]
param(
    [string]$OutputDir,
    [switch]$SkipVerify,
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\PortableCommon.ps1')

$packageRoot = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..')).FullName
$manifest = Read-JsonFile -Path (Join-Path $packageRoot 'manifest.json')
if (-not $manifest) { throw 'manifest.json is missing; run: node tools/build_manifest.mjs' }
$version = [string]$manifest.distribution.version
if (-not $OutputDir) { $OutputDir = Join-Path $packageRoot 'dist' }
$OutputDir = Get-NormalizedPath -Path $OutputDir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Section "Packaging CNKI Research Portable $version"

if (-not $SkipVerify) {
    Write-Item -Status 'INFO' -Text "verifying $(@($manifest.files).Count) payload file(s) against manifest.json"
    $problems = @(Test-PackageIntegrity -PackageRoot $packageRoot -Manifest $manifest)
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems | Select-Object -First 10) { Write-Item -Status 'FAIL' -Text $problem }
        throw "payload integrity check failed with $($problems.Count) problem(s); run: node tools/build_manifest.mjs"
    }
    Write-Item -Status 'PASS' -Text 'every payload file matches its recorded SHA-256'
}

# Release artefact name required by the distribution spec.
$zipName = "CNKI-Research-Portable-$version"
$staging = Join-Path $OutputDir ("_staging\$zipName")
if (Test-Path -LiteralPath (Split-Path -Parent $staging)) {
    Remove-Item -LiteralPath (Split-Path -Parent $staging) -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$copied = 0
foreach ($entry in $manifest.files) {
    $source = Join-Path $packageRoot ([string]$entry.path)
    $destination = Join-Path $staging ([string]$entry.path)
    $destinationDir = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDir)) { New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null }
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $copied++
}
# manifest.json excludes itself from its own file list (it cannot record its own
# hash), so it must be staged explicitly -- the installer and the extracted-copy
# checks both read it from the package root.
Copy-Item -LiteralPath (Join-Path $packageRoot 'manifest.json') -Destination (Join-Path $staging 'manifest.json') -Force
$copied++
Write-Item -Status 'PASS' -Text "staged $copied file(s) (payload + manifest.json)"

# Refuse to ship development leftovers even if the manifest ever listed them.
$leaks = @(Get-ChildItem -LiteralPath $staging -Recurse -Force -Directory |
    Where-Object { $_.Name -in @('_scratch', '.venv', 'node_modules', '__pycache__', '_portable') })
$leaks += @(Get-ChildItem -LiteralPath $staging -Recurse -Force -File -Filter '*.pyc')
$leaks += @(Get-ChildItem -LiteralPath $staging -Recurse -Force -File -Filter '*.log')
if ($leaks.Count -gt 0) {
    foreach ($leak in $leaks | Select-Object -First 10) { Write-Item -Status 'FAIL' -Text $leak.FullName }
    throw 'the staged payload contains runtime artefacts that must not ship'
}
Write-Item -Status 'PASS' -Text 'no .venv, node_modules, __pycache__, .pyc or test log in the staged payload'

$zipPath = Join-Path $OutputDir "$zipName.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Item -Status 'PASS' -Text "created $zipPath"

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$hashPath = "$zipPath.sha256"
Write-TextFile -Path $hashPath -Text "$hash *$(Split-Path -Leaf $zipPath)`n"
Write-Item -Status 'PASS' -Text "sha256 $hash"

if (-not $KeepStaging) {
    Remove-Item -LiteralPath (Split-Path -Parent $staging) -Recurse -Force
}

$sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
Write-Section 'Release artefact'
Write-Host "  zip     : $zipPath"
Write-Host "  sha256  : $hashPath"
Write-Host "  size    : $sizeMb MB"
Write-Host "  files   : $copied"
