# FAIL-CLOSED GUARD: this script no longer packages the unified RC3 release.
#
# The unified RC3 candidate has a deterministic, reproducible build pipeline:
#   tools\build_unified_release.ps1
# which generates the deterministic ZIP (sorted entries, forward slashes, fixed
# 1980-01-01 timestamps, no attribute bits), the in-package SHA256SUMS.txt trust root,
# the package-only upgrade metadata (upgrade-data\) and the external release identity
# (sidecar, release-level SHA256SUMS.txt, RELEASE_MANIFEST.json).
#
# Keeping a second packaging implementation here would be a non-deterministic second
# source of truth (the historical implementation used Compress-Archive, which embeds
# per-file mtimes/attributes and directory entries, so two builds never matched), and it
# would silently drop the in-package SHA256SUMS.txt. It is therefore retained as a
# fail-closed guard only.
#
# Build the unified candidate with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_unified_release.ps1 `
#     -Rc2Zip <frozen RC2 ZIP> -Rc3FrozenZip <frozen RC3 ZIP> `
#     -Repo <candidate repo root> -OutDir <RELEASE_ASSETS_CANDIDATE>
#
# Exit code 2 = refused by design (documented, not a crash).

[CmdletBinding()]
param(
    [string]$OutputDir,
    [switch]$SkipVerify,
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'

$packageRoot = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..')).FullName

Write-Host 'REFUSED: tools\package_release.ps1 is a fail-closed guard in the unified RC3 tree.' -ForegroundColor Red
Write-Host ''
Write-Host 'The unified release archive is built ONLY by tools\build_unified_release.ps1, which owns:'
Write-Host '  - the deterministic ZIP (sorted, forward slashes, fixed 1980 timestamps, no attr bits)'
Write-Host '  - the in-package SHA256SUMS.txt trust root (payload + manifest.json + upgrade-data/**)'
Write-Host '  - upgrade-data\rc2-to-rc3.json (schemaVersion 2 upgrade metadata)'
Write-Host '  - the external release identity (sidecar, release SHA256SUMS.txt, RELEASE_MANIFEST.json)'
Write-Host ''
Write-Host 'Reproduction command:'
Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File "<repo>\tools\build_unified_release.ps1" `'
Write-Host '    -Rc2Zip "<frozen RC2 ZIP>" -Rc3FrozenZip "<frozen RC3 ZIP>" `'
Write-Host '    -Repo "<repo>" -OutDir "<RELEASE_ASSETS_CANDIDATE>"'
Write-Host ''
Write-Host "Package root inspected (not modified): $packageRoot"
Write-Host "Requested OutputDir (ignored): $OutputDir"
exit 2
