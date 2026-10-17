# PortableCommon.ps1 -- shared helpers for the CNKI Research Portable installer.
#
# Design rules:
#   * Windows PowerShell 5.1 compatible (no `??`, no ternaries, no -AsHashtable).
#   * No absolute developer path is ever written; every path is either a caller
#     parameter, derived from $PSScriptRoot, or discovered from the environment.
#   * Read-only helpers never mutate; mutating helpers are named Install-/New-/Remove-/Set-.
#   * Removing a Windows directory junction must only ever unlink the link. No
#     helper in this file calls Remove-Item -Recurse on a path that can be a link.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:PortableSchemaVersion = 1

function New-Utf8NoBomEncoding {
    return (New-Object System.Text.UTF8Encoding($false))
}

function Write-TextFile {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Utf8NoBomEncoding))
}

function Read-JsonFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFile {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$Value, [int]$Depth = 12)
    Write-TextFile -Path $Path -Text (($Value | ConvertTo-Json -Depth $Depth) + "`n")
}

function Get-NormalizedPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path (Get-Location).Path $expanded
    }
    return [System.IO.Path]::GetFullPath($expanded)
}

function Test-IsReparsePoint {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
    return $false
}

function Get-LinkTarget {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
    if ($item.PSObject.Properties.Name -contains 'Target' -and $item.Target) {
        if ($item.Target -is [array]) { return [string]$item.Target[0] }
        return [string]$item.Target
    }
    return $null
}

<#
.SYNOPSIS
    Remove only the link itself for a junction/symlink; never recurse into the target.
.DESCRIPTION
    A Windows directory junction is a reparse point. `Remove-Item -Recurse` on it
    can delete the *contents of the target directory*. This function therefore
    refuses to act on anything that is not a reparse point, and then uses
    Directory.Delete(path, recursive: $false), which unlinks only the junction.
#>
function Remove-LinkSafely {
    param([Parameter(Mandatory=$true)][string]$Path, [switch]$WhatIfOnly)
    $full = Get-NormalizedPath -Path $Path
    if (-not (Test-Path -LiteralPath $full)) { return 'absent' }
    if (-not (Test-IsReparsePoint -Path $full)) {
        throw "Remove-LinkSafely refuses to act: '$full' is a real directory, not a link. Refusing to delete user data."
    }
    if ($WhatIfOnly) { return 'would-unlink' }
    [System.IO.Directory]::Delete($full, $false)
    return 'unlinked'
}

function Get-RelativePathFrom {
    param([Parameter(Mandatory=$true)][string]$Base, [Parameter(Mandatory=$true)][string]$Path)
    $baseFull = (Get-NormalizedPath -Path $Base).TrimEnd('\','/')
    $pathFull = Get-NormalizedPath -Path $Path
    if ($pathFull.StartsWith($baseFull + '\') -or $pathFull.StartsWith($baseFull + '/')) {
        return $pathFull.Substring($baseFull.Length + 1)
    }
    return $pathFull
}

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

function Get-PortableLayout {
    param(
        [string]$PackageRoot,
        [string]$InstallRoot
    )
    $root = $PackageRoot
    if (-not $root) {
        # tools/lib/ -> package root
        $root = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\..')).FullName
    }
    $pkg = Get-NormalizedPath -Path $root
    $install = $pkg
    if ($InstallRoot) { $install = Get-NormalizedPath -Path $InstallRoot }
    return [pscustomobject]@{
        PackageRoot   = $pkg
        InstallRoot   = $install
        BundleSource  = (Join-Path $pkg 'bundle\cnki-research')
        BundleDir     = (Join-Path $install 'bundle\cnki-research')
        VenvDir       = (Join-Path $install '.venv')
        StateDir      = (Join-Path $install '_portable')
        BackupDir     = (Join-Path $install '_portable\backups')
        StateFile     = (Join-Path $install '_portable\install-state.json')
        RuntimeFile   = (Join-Path $install 'bundle\cnki-research\portable.runtime.json')
        # `UpstreamSource` is where the shipped source lives; `UpstreamDir` is where
        # the runtime consumes it (the install root). They differ only when
        # -InstallRoot points somewhere other than the extracted package.
        UpstreamSource = (Join-Path $pkg 'upstream\cnki-mcp')
        UpstreamDir   = (Join-Path $install 'upstream\cnki-mcp')
        ManifestFile  = (Join-Path $pkg 'manifest.json')
        SameRoot      = ($pkg -eq $install)
    }
}

# ---------------------------------------------------------------------------
# DSH discovery
# ---------------------------------------------------------------------------

function Get-DshHome {
    param([string]$DshHome)
    if ($DshHome) { return Get-NormalizedPath -Path $DshHome }
    $envHome = $env:DSH_HOME
    if ($envHome -and $envHome.Trim().Length -gt 0) { return (Get-NormalizedPath -Path $envHome) }
    return (Join-Path $env:USERPROFILE '.dsh')
}

function Get-DshProfileDir {
    param([Parameter(Mandatory=$true)][string]$DshHome, [Parameter(Mandatory=$true)][string]$Profile)
    return (Join-Path (Join-Path $DshHome 'profiles') $Profile)
}

function Find-DshCli {
    param([string]$Explicit, [string]$DshHome)
    $candidates = New-Object System.Collections.ArrayList
    if ($Explicit) { [void]$candidates.Add($Explicit) }
    $onPath = Get-Command 'dsh.cmd' -ErrorAction SilentlyContinue
    if ($onPath) { [void]$candidates.Add($onPath.Source) }
    $onPath2 = Get-Command 'dsh' -ErrorAction SilentlyContinue
    if ($onPath2) { [void]$candidates.Add($onPath2.Source) }
    # The Desktop owns this registry key while its managed PATH entry is installed.
    try {
        $owner = Get-ItemProperty -Path 'HKCU:\Software\DeepSeekHarness\Command' -ErrorAction SilentlyContinue
        if ($owner -and $owner.Directory) {
            [void]$candidates.Add((Join-Path ([string]$owner.Directory) 'dsh.cmd'))
        }
    } catch { }
    if ($DshHome) {
        foreach ($rt in @(Get-ChildItem -Path (Join-Path $DshHome 'dsh-runtimes') -Directory -ErrorAction SilentlyContinue)) {
            $probe = Join-Path $rt.FullName 'dependencies\node\bin\node.exe'
            if (Test-Path -LiteralPath $probe) { }
        }
    }
    $roots = New-Object System.Collections.ArrayList
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\', 'D:\', 'E:\')) {
        if (-not $base) { continue }
        foreach ($name in @('DeepSeekHarness', 'DeepSeek Harness', 'DeepSeek\Harness')) {
            [void]$roots.Add((Join-Path $base $name))
        }
    }
    foreach ($root in $roots) {
        [void]$candidates.Add((Join-Path $root 'resources\runtime\cli\bin\dsh.cmd'))
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Get-NormalizedPath -Path $candidate) }
        } catch { }
    }
    return $null
}

function Get-DshCliAppRoot {
    param([Parameter(Mandatory=$true)][string]$DshCli)
    # <appRoot>\resources\runtime\cli\bin\dsh.cmd
    $bin = Split-Path -Parent $DshCli
    $cli = Split-Path -Parent $bin
    $runtime = Split-Path -Parent $cli
    $resources = Split-Path -Parent $runtime
    return (Split-Path -Parent $resources)
}

function Get-DshDesktopVersion {
    param([string]$DshHome, [string]$AppRoot)
    if ($DshHome) {
        $runtimeRoot = Join-Path $DshHome 'dsh-runtimes'
        foreach ($dir in @(Get-ChildItem -Path $runtimeRoot -Directory -ErrorAction SilentlyContinue)) {
            $runtimeJson = Read-JsonFile -Path (Join-Path $dir.FullName 'runtime.json')
            if ($runtimeJson -and $runtimeJson.desktopVersion) { return [string]$runtimeJson.desktopVersion }
        }
    }
    if ($AppRoot) {
        $runtimeJson = Read-JsonFile -Path (Join-Path $AppRoot 'resources\runtime\primary-runtime\runtime.json')
        if ($runtimeJson -and $runtimeJson.desktopVersion) { return [string]$runtimeJson.desktopVersion }
    }
    return $null
}

function Get-DshBundledPython {
    param([string]$AppRoot, [string]$DshHome)
    if ($AppRoot) {
        $candidate = Join-Path $AppRoot 'resources\runtime\primary-runtime\dependencies\python\python.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    if ($DshHome) {
        foreach ($dir in @(Get-ChildItem -Path (Join-Path $DshHome 'dsh-runtimes') -Directory -ErrorAction SilentlyContinue)) {
            $candidate = Join-Path $dir.FullName 'dependencies\python\python.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Interpreter / toolchain
# ---------------------------------------------------------------------------

function Get-PythonVersion {
    param([Parameter(Mandatory=$true)][string]$Python)
    try {
        $out = & $Python -c "import sys;print('%d.%d.%d' % sys.version_info[:3])" 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ([string]$out).Trim() }
    } catch { }
    return $null
}

function Test-PythonAtLeast311 {
    param([Parameter(Mandatory=$true)][string]$Version)
    if (-not $Version) { return $false }
    $parts = $Version.Split('.')
    if ($parts.Length -lt 2) { return $false }
    $major = [int]$parts[0]; $minor = [int]$parts[1]
    if ($major -gt 3) { return $true }
    if ($major -eq 3 -and $minor -ge 11) { return $true }
    return $false
}

function Find-Python {
    param([string]$Explicit, [string]$AppRoot, [string]$DshHome)
    $found = New-Object System.Collections.ArrayList
    if ($Explicit) {
        $p = Get-NormalizedPath -Path $Explicit
        if (Test-Path -LiteralPath $p -PathType Leaf) { [void]$found.Add($p) }
        else { throw "The -Python path does not exist: $p" }
    }
    $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($py) {
        foreach ($selector in @('-3.13', '-3.12', '-3.11')) {
            try {
                $out = & $py.Source $selector -c "import sys;print(sys.executable)" 2>$null
                if ($LASTEXITCODE -eq 0 -and $out) { [void]$found.Add(([string]$out).Trim()) }
            } catch { }
        }
    }
    foreach ($name in @('python.exe', 'python3.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { [void]$found.Add($cmd.Source) }
    }
    $bundled = Get-DshBundledPython -AppRoot $AppRoot -DshHome $DshHome
    if ($bundled) { [void]$found.Add($bundled) }
    foreach ($candidate in $found) {
        $version = Get-PythonVersion -Python $candidate
        if (Test-PythonAtLeast311 -Version $version) {
            return [pscustomobject]@{ Path = $candidate; Version = $version; Bundled = ($bundled -and $candidate -eq $bundled) }
        }
    }
    return $null
}

function Find-Uv {
    param([string]$Explicit)
    $candidates = New-Object System.Collections.ArrayList
    if ($Explicit) { [void]$candidates.Add($Explicit) }
    $cmd = Get-Command 'uv.exe' -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Source) }
    $cmd2 = Get-Command 'uv' -ErrorAction SilentlyContinue
    if ($cmd2) { [void]$candidates.Add($cmd2.Source) }
    if ($env:USERPROFILE) { [void]$candidates.Add((Join-Path $env:USERPROFILE '.local\bin\uv.exe')) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\uv\uv.exe')) }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $version = ([string](& $candidate --version 2>$null)).Trim()
                return [pscustomobject]@{ Path = $candidate; Version = $version }
            }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------------------
# CNKI profiles (upstream cnki-mcp state)
# ---------------------------------------------------------------------------

function Get-CnkiProfileInfo {
    param([Parameter(Mandatory=$true)][string]$Python)
    $script = @'
import json, sys
from pathlib import Path
try:
    from cnki_mcp.core import config
    base = str(config.BASE_DIR)
    profiles = config.list_profiles()
    default = config.get_default_profile()
    cfg = None
    if config.PROFILE_CONFIG_PATH.exists():
        try:
            cfg = json.loads(config.PROFILE_CONFIG_PATH.read_text(encoding="utf-8"))
        except Exception:
            cfg = None
    print(json.dumps({"ok": True, "base": base, "profiles": profiles, "default": default,
                      "configExists": config.PROFILE_CONFIG_PATH.exists(),
                      "configured": (cfg or {}).get("default_profile")}, ensure_ascii=False))
except Exception as exc:
    print(json.dumps({"ok": False, "error": repr(exc), "base": str(Path.home() / ".cnki-mcp")}, ensure_ascii=False))
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cnki-probe-" + [guid]::NewGuid().ToString('N') + '.py')
    try {
        Write-TextFile -Path $tmp -Text $script
        $out = & $Python $tmp 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ($out | ConvertFrom-Json) }
    } catch { } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
    return $null
}

function Set-CnkiDefaultProfile {
    param([Parameter(Mandatory=$true)][string]$Python, [Parameter(Mandatory=$true)][string]$Name)
    $script = @'
import json, sys
from cnki_mcp.core import config
config.set_default_profile(sys.argv[1])
print(json.dumps({"ok": True, "default": config.get_default_profile(),
                  "profiles": config.list_profiles()}, ensure_ascii=False))
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cnki-set-" + [guid]::NewGuid().ToString('N') + '.py')
    try {
        Write-TextFile -Path $tmp -Text $script
        $out = & $Python $tmp $Name 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to set the default CNKI profile: $out" }
        return ($out | ConvertFrom-Json)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

# ---------------------------------------------------------------------------
# Playwright / Chromium
# ---------------------------------------------------------------------------

function Get-PlaywrightBrowserInfo {
    $root = Join-Path $env:LOCALAPPDATA 'ms-playwright'
    $result = [pscustomobject]@{ Root = $root; Exists = (Test-Path -LiteralPath $root); Chromium = @(); ChromiumHeadless = @() }
    if (-not $result.Exists) { return $result }
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $result.Chromium = @($dirs | Where-Object { $_ -like 'chromium-*' })
    $result.ChromiumHeadless = @($dirs | Where-Object { $_ -like 'chromium_headless_shell-*' })
    return $result
}

# ---------------------------------------------------------------------------
# Profile manifest inspection
# ---------------------------------------------------------------------------

function Get-ProfileManifestInfo {
    param([Parameter(Mandatory=$true)][string]$ProfileDir)
    $packageJson = Join-Path $ProfileDir 'package.json'
    $info = [pscustomobject]@{
        Dir = $ProfileDir
        Exists = (Test-Path -LiteralPath $packageJson)
        Bundles = @()
        Dependencies = @{}
        CnkiEntry = $null
    }
    if (-not $info.Exists) { return $info }
    $manifest = Read-JsonFile -Path $packageJson
    # StrictMode makes a missing property access fatal, and a profile that never
    # declared dependencies (or just had them removed) genuinely lacks the key.
    $deps = @{}
    if ($manifest) {
        $dshProp = $manifest.PSObject.Properties['dsh']
        if ($dshProp -and $dshProp.Value) {
            $profileProp = $dshProp.Value.PSObject.Properties['profile']
            if ($profileProp -and $profileProp.Value) {
                $bundlesProp = $profileProp.Value.PSObject.Properties['bundles']
                if ($bundlesProp -and $bundlesProp.Value) { $info.Bundles = @($bundlesProp.Value) }
            }
        }
        $depsProp = $manifest.PSObject.Properties['dependencies']
        if ($depsProp -and $depsProp.Value) {
            foreach ($prop in $depsProp.Value.PSObject.Properties) { $deps[$prop.Name] = [string]$prop.Value }
        }
    }
    $info.Dependencies = $deps
    return $info
}

<#
.SYNOPSIS
    Read a dependency value from a profile manifest without assuming it exists.
.DESCRIPTION
    `Get-ProfileManifestInfo` always populates `Dependencies`, but a caller may hold
    a profile object produced by an older code path (or a raw PSCustomObject from
    ConvertFrom-Json, which omits the key entirely when the profile declares no
    dependencies). Reading `.Dependencies[...]` on such an object raises
    "The property 'dependencies' cannot be found on this object" under StrictMode,
    so every read goes through here.
#>
function Get-ProfileDependency {
    param($ProfileInfo, [Parameter(Mandatory=$true)][string]$Name)
    if (-not $ProfileInfo) { return $null }
    $prop = $ProfileInfo.PSObject.Properties['Dependencies']
    if (-not $prop -or -not $prop.Value) { return $null }
    $deps = $prop.Value
    if ($deps -is [hashtable]) {
        if ($deps.ContainsKey($Name)) { return [string]$deps[$Name] }
        return $null
    }
    $inner = $deps.PSObject.Properties[$Name]
    if ($inner) { return [string]$inner.Value }
    return $null
}

function Get-InstalledBundleInfo {
    param([Parameter(Mandatory=$true)][string]$ProfileDir, [string]$PackageName = '@local/dsh-cnki-research')
    $linkPath = Join-Path (Join-Path $ProfileDir 'node_modules') $PackageName
    $result = [pscustomobject]@{
        PackageName = $PackageName
        LinkPath = $linkPath
        LinkExists = (Test-Path -LiteralPath $linkPath)
        IsLink = (Test-IsReparsePoint -Path $linkPath)
        Target = (Get-LinkTarget -Path $linkPath)
        ResolvedDir = $null
        Version = $null
        Name = $null
    }
    if ($result.LinkExists) {
        $pkgJson = Join-Path $linkPath 'package.json'
        $manifest = Read-JsonFile -Path $pkgJson
        if ($manifest) {
            $result.Version = [string]$manifest.version
            $result.Name = [string]$manifest.name
        }
        try { $result.ResolvedDir = (Get-Item -LiteralPath $linkPath -Force).FullName } catch { }
    }
    return $result
}

function Get-AllProfilesWithPackage {
    param([Parameter(Mandatory=$true)][string]$DshHome, [string]$PackageName = '@local/dsh-cnki-research')
    $profilesRoot = Join-Path $DshHome 'profiles'
    $hits = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $profilesRoot)) { return @() }
    foreach ($dir in @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
        $manifest = Read-JsonFile -Path (Join-Path $dir.FullName 'package.json')
        if (-not $manifest) { continue }
        # Under Set-StrictMode, reading a property that does not exist throws.
        # A profile whose dependencies were just removed has no `dependencies` key
        # at all, so every read below goes through PSObject.Properties.
        $depends = $false
        $depsProp = $manifest.PSObject.Properties['dependencies']
        if ($depsProp -and $depsProp.Value) {
            foreach ($prop in $depsProp.Value.PSObject.Properties) {
                if ($prop.Name -eq $PackageName) { $depends = $true }
            }
        }
        $listed = $false
        $dshProp = $manifest.PSObject.Properties['dsh']
        if ($dshProp -and $dshProp.Value) {
            $profileProp = $dshProp.Value.PSObject.Properties['profile']
            if ($profileProp -and $profileProp.Value) {
                $bundlesProp = $profileProp.Value.PSObject.Properties['bundles']
                if ($bundlesProp -and $bundlesProp.Value) {
                    foreach ($b in @($bundlesProp.Value)) { if ($b -eq $PackageName) { $listed = $true } }
                }
            }
        }
        if ($depends -or $listed) {
            [void]$hits.Add([pscustomobject]@{ Profile = $dir.Name; Dir = $dir.FullName; Dependency = $depends; BundleListed = $listed })
        }
    }
    return @($hits)
}

# ---------------------------------------------------------------------------
# Virtual environment
# ---------------------------------------------------------------------------
# These live in the shared library (not in portable.ps1) because tests\run_all.ps1
# and tests\test_dsh_isolated.ps1 dot-source only this file.

function Test-VenvHealthy {
    param([string]$VenvDir)
    $py = Join-Path $VenvDir 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py -PathType Leaf)) {
        $py = Join-Path $VenvDir 'bin/python'
        if (-not (Test-Path -LiteralPath $py -PathType Leaf)) { return $false }
    }
    $probe = & $py -c "import cnki_mcp, mcp, playwright; print('ok')" 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    return (([string]$probe).Trim() -eq 'ok')
}

function Get-VenvPython {
    param([string]$VenvDir)
    $py = Join-Path $VenvDir 'Scripts\python.exe'
    if (Test-Path -LiteralPath $py -PathType Leaf) { return $py }
    $py = Join-Path $VenvDir 'bin/python'
    if (Test-Path -LiteralPath $py -PathType Leaf) { return $py }
    return $null
}

function Get-VenvPackageVersions {
    param([string]$VenvPython)
    $code = "import importlib.metadata as m; print('|'.join('%s=%s' % (n, m.version(n)) for n in ['cnki-mcp','mcp','playwright'] if True))"
    try {
        $out = & $VenvPython -c $code 2>&1
        if ($LASTEXITCODE -eq 0) { return ([string]$out).Trim() }
    } catch { }
    return $null
}

<#
.SYNOPSIS
    Remove a virtual-environment directory that cannot be used, so it can be rebuilt.
.DESCRIPTION
    A previous interrupted install can leave a `.venv` that exists but has no
    interpreter (uv writes `.gitignore`/`CACHEDIR.TAG`/`.lock` first). `uv sync`
    then refuses to proceed and every later install fails on an artefact the user
    cannot see. This clears exactly that shape of directory.

    Safety:
      * acts only on a path that already exists and is NOT a usable environment;
      * never recurses through a reparse point (Remove-LinkSafely unlinks it);
      * refuses when a `.lock` file is present, which means another uv is using it;
      * touches only the venv directory, never its parent.
#>
function Reset-BrokenVenv {
    param([Parameter(Mandatory=$true)][string]$VenvDir)
    if (-not (Test-Path -LiteralPath $VenvDir)) { return 'absent' }
    if (Get-VenvPython -VenvDir $VenvDir) { return 'usable' }
    if (Test-Path -LiteralPath (Join-Path $VenvDir '.lock')) { return 'locked' }
    if (Test-IsReparsePoint -Path $VenvDir) {
        [void](Remove-LinkSafely -Path $VenvDir)
        return 'unlinked'
    }
    Remove-Item -LiteralPath $VenvDir -Recurse -Force
    return 'removed'
}

<#
.SYNOPSIS
    True when a tree contains a reparse point at or below the given depth.
.DESCRIPTION
    `Remove-Item -Recurse` on Windows PowerShell 5.1 follows nested junctions and
    can delete the *target's* contents. The purge path removes a generated `.venv`,
    which should never contain a link, so a link found there means something is
    wrong and the delete must be refused rather than trusted.
#>
function Test-TreeContainsReparsePoint {
    param([Parameter(Mandatory=$true)][string]$Path, [int]$Depth = 1)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (Test-IsReparsePoint -Path $Path) { return $true }
    if ($Depth -le 0) { return $false }
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -Directory -ErrorAction SilentlyContinue)) {
        if (Test-TreeContainsReparsePoint -Path $child.FullName -Depth ($Depth - 1)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Production-data protection
# ---------------------------------------------------------------------------
# Hard gate required by the distribution spec: no operation that can delete,
# overwrite or reset a real user's DSH data may be reachable by accident.
#
#   * `Test-IsPathUnder`     containment test used by every guard below.
#   * `Get-ProductionDshHome` the *default* home, i.e. the one a real Desktop
#                            install uses: $env:USERPROFILE\.dsh.
#   * `Test-ProductionTarget` true when an operation would act on that home.
#   * `Assert-MutationAllowed` throws unless the caller passed
#                            -AllowProductionProfile.
#
# The real user's data is never deleted by this distribution, so the gate is
# deliberately blunt: it blocks first and explains second. An operator who
# genuinely means to install into the live Desktop profile passes the switch,
# which is also what the Creator workflow in INSTALL_PROMPT.md instructs.

function Test-IsPathUnder {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Root
    )
    $p = (Get-NormalizedPath -Path $Path).TrimEnd('\', '/')
    $r = (Get-NormalizedPath -Path $Root).TrimEnd('\', '/')
    if ($p -eq $r) { return $true }
    return $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ProductionDshHome {
    param([string]$UserProfile)
    $profile = $UserProfile
    if (-not $profile) { $profile = $env:USERPROFILE }
    if (-not $profile) { return $null }
    return (Get-NormalizedPath -Path (Join-Path $profile '.dsh'))
}

<#
.SYNOPSIS
    The real user's cnki-mcp state directory (%USERPROFILE%\.cnki-mcp).
.DESCRIPTION
    Upstream cnki-mcp roots all of its state at `Path.home() / ".cnki-mcp"`, which
    on Windows is `$env:USERPROFILE`. It holds the institution profiles and the
    browser authentication state, so it is user data in exactly the sense the
    production gate protects -- and it is NOT covered by $DshHome.
#>
function Get-CnkiStateHome {
    param([string]$UserProfile)
    $profile = $UserProfile
    if (-not $profile) { $profile = $env:USERPROFILE }
    if (-not $profile) { return $null }
    return (Get-NormalizedPath -Path (Join-Path $profile '.cnki-mcp'))
}

<#
.SYNOPSIS
    True when the target DSH home is the live/Desktop home a real user's data lives in.
.DESCRIPTION
    A home is "production" when it is the default $env:USERPROFILE\.dsh, or when
    it already contains a sessions/ or storages/ directory with real user data
    (which means a real user has used it). A throwaway home created by a test has
    neither, so tests stay unaffected.
#>
function Test-ProductionTarget {
    param([Parameter(Mandatory=$true)][string]$DshHome, [string]$UserProfile)
    # NB: never name a local variable $home -- PowerShell's $HOME is read-only
    # and case-insensitive, so assigning it throws.
    $homePath = Get-NormalizedPath -Path $DshHome
    $default = Get-ProductionDshHome -UserProfile $UserProfile
    if ($default -and ($homePath.TrimEnd('\', '/') -ieq $default.TrimEnd('\', '/'))) { return $true }
    foreach ($marker in @('sessions', 'storages')) {
        $dir = Join-Path $homePath $marker
        if (Test-Path -LiteralPath $dir) {
            $any = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($any.Count -gt 0) { return $true }
        }
    }
    return $false
}

<#
.SYNOPSIS
    Throw unless a mutating action against $DshHome was explicitly authorised.
.DESCRIPTION
    -WhatIfOnly suppresses the throw for a dry run: planning against the live home
    is how an operator finds out what -AllowProductionProfile would do, so the
    plan is allowed to proceed and simply reports the authorisation it would need.
    Nothing is mutated by a dry run, so this does not weaken the gate.
#>
function Assert-MutationAllowed {
    param(
        [Parameter(Mandatory=$true)][string]$DshHome,
        [Parameter(Mandatory=$true)][string]$Action,
        [switch]$AllowProductionProfile,
        [switch]$WhatIfOnly,
        [string]$UserProfile
    )
    if (-not (Test-ProductionTarget -DshHome $DshHome -UserProfile $UserProfile)) { return }
    if ($WhatIfOnly) {
        # `Add-Step` is defined by portable.ps1, which dot-sources this file, so it
        # exists at call time in the installer but not in a standalone unit test.
        if (Get-Command 'Add-Step' -ErrorAction SilentlyContinue) {
            Add-Step "NOTE: $Action targets the live DSH home '$DshHome'; executing it will require -AllowProductionProfile."
        } else {
            Write-Warning "NOTE: $Action targets the live DSH home '$DshHome'; executing it will require -AllowProductionProfile."
        }
        return
    }
    if ($AllowProductionProfile) {
        Write-Warning ("-Action $Action targets the live DSH home '$DshHome' and was authorised with -AllowProductionProfile.")
        return
    }
    throw @"
REFUSED: -Action $Action targets the live DSH home '$DshHome'.

That home holds real user data: sessions, storages, credentials and the CNKI
browser profile. This distribution never deletes or resets any of it, and it
will not modify the live home without an explicit authorisation.

If you really mean to change the live Desktop profile, re-run with:

    -AllowProductionProfile

If you are testing, point the operation at a throwaway home instead:

    -DshHome <empty directory> -DshProfile <test profile>
"@
}

# ---------------------------------------------------------------------------
# Integrity
# ---------------------------------------------------------------------------

function Get-FileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

<#
.SYNOPSIS
    Hash the files that identify a profile's plugin registration.
.DESCRIPTION
    Used to prove a profile was not modified: the manifest and lockfile are the
    only files `dsh plugin add/remove` rewrites.
#>
function Get-ProductionProfileFingerprint {
    param([Parameter(Mandatory=$true)][string]$ProfileDir)
    $packageJson = Join-Path $ProfileDir 'package.json'
    $pnpmLock = Join-Path $ProfileDir 'pnpm-lock.yaml'
    $result = [pscustomobject]@{
        profileDir = $ProfileDir
        exists = (Test-Path -LiteralPath $packageJson -PathType Leaf)
        packageJsonSha256 = $null
        pnpmLockSha256 = $null
    }
    if ($result.exists) { $result.packageJsonSha256 = Get-FileSha256 -Path $packageJson }
    if (Test-Path -LiteralPath $pnpmLock -PathType Leaf) { $result.pnpmLockSha256 = Get-FileSha256 -Path $pnpmLock }
    return $result
}

function Test-PackageIntegrity {
    param([Parameter(Mandatory=$true)][string]$PackageRoot, [Parameter(Mandatory=$true)]$Manifest)
    $problems = New-Object System.Collections.ArrayList
    if (-not $Manifest.files) { return @('manifest.json has no files list') }
    foreach ($entry in $Manifest.files) {
        $full = Join-Path $PackageRoot ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            [void]$problems.Add("missing file: $($entry.path)")
            continue
        }
        $actual = Get-FileSha256 -Path $full
        if ($actual -ne ([string]$entry.sha256).ToLowerInvariant()) {
            [void]$problems.Add("hash mismatch: $($entry.path)")
        }
    }
    return @($problems)
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------

function New-ProfileBackup {
    param([Parameter(Mandatory=$true)][string]$ProfileDir, [Parameter(Mandatory=$true)][string]$BackupDir, [string]$Reason = 'install')
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $target = Join-Path $BackupDir $stamp
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $saved = New-Object System.Collections.ArrayList
    foreach ($name in @('package.json', 'pnpm-lock.yaml', 'cordis.patch.yml', 'pnpm-workspace.yaml', '.plugin-manager\run.json')) {
        $src = Join-Path $ProfileDir $name
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $dest = Join-Path $target ($name -replace '[\\/]', '__')
            Copy-Item -LiteralPath $src -Destination $dest -Force
            [void]$saved.Add($name)
        }
    }
    $record = [pscustomobject]@{
        schemaVersion = $script:PortableSchemaVersion
        createdAt = (Get-Date).ToString('o')
        reason = $Reason
        profileDir = $ProfileDir
        files = @($saved)
    }
    Write-JsonFile -Path (Join-Path $target 'backup.json') -Value $record
    return $target
}

function Get-LatestBackup {
    param([Parameter(Mandatory=$true)][string]$BackupDir)
    if (-not (Test-Path -LiteralPath $BackupDir)) { return $null }
    $dirs = @(Get-ChildItem -LiteralPath $BackupDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($dirs.Count -eq 0) { return $null }
    return $dirs[0].FullName
}

<#
.SYNOPSIS
    The newest backup whose profile manifest actually declares a given package.
.DESCRIPTION
    "The newest backup" is the wrong thing to roll back to. Every mutating action
    snapshots first, so the newest snapshot after an uninstall is the state the
    uninstall left behind -- restoring it would re-create the very situation the
    operator is trying to escape.

    A backup that still declares the package in `dependencies` is by construction a
    pre-removal state, so rolling back to the newest such backup always restores the
    plugin. Returns $null when no backup qualifies.
#>
function Get-RestorableBackup {
    param(
        [Parameter(Mandatory=$true)][string]$BackupDir,
        [Parameter(Mandatory=$true)][string]$PackageName
    )
    if (-not (Test-Path -LiteralPath $BackupDir)) { return $null }
    $dirs = @(Get-ChildItem -LiteralPath $BackupDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($dir in $dirs) {
        $snapshot = Join-Path $dir.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf)) { continue }
        $manifest = Read-JsonFile -Path $snapshot
        if (-not $manifest) { continue }
        $depsProp = $manifest.PSObject.Properties['dependencies']
        if (-not $depsProp -or -not $depsProp.Value) { continue }
        if ($depsProp.Value.PSObject.Properties[$PackageName]) { return $dir.FullName }
    }
    return $null
}

# ---------------------------------------------------------------------------
# dsh CLI
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Run the dsh CLI with inherited or captured output.
.DESCRIPTION
    Uses the call operator so that output can be captured. Argument quoting is
    handled by the caller through an array, which PowerShell passes verbatim to a
    native executable. Start-Process is deliberately avoided: it cannot hand back
    redirected streams on Windows PowerShell 5.1.
#>
function Invoke-DshCommand {
    param(
        [Parameter(Mandatory=$true)][string]$DshCli,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [string]$WorkingDirectory,
        [switch]$Capture
    )
    $push = $null
    if ($WorkingDirectory) { $push = (Get-Location).Path; Set-Location -LiteralPath $WorkingDirectory }
    try {
        if ($Capture) {
            $all = & $DshCli @Arguments 2>&1
            $text = ($all | Out-String)
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
        }
        & $DshCli @Arguments
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = '' }
    } finally {
        if ($push) { Set-Location -LiteralPath $push }
    }
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function New-CheckResult {
    param([string]$Id, [string]$Status, [string]$Detail)
    return [pscustomobject]@{ id = $Id; status = $Status; detail = $Detail }
}

function Write-Section {
    param([Parameter(Mandatory=$true)][string]$Title)
    Write-Host ''
    Write-Host ("=" * 72)
    Write-Host $Title
    Write-Host ("=" * 72)
}

function Write-Item {
    param([Parameter(Mandatory=$true)][string]$Status, [Parameter(Mandatory=$true)][string]$Text)
    $color = 'Gray'
    if ($Status -eq 'PASS') { $color = 'Green' }
    elseif ($Status -eq 'VERIFIED') { $color = 'Green' }
    elseif ($Status -eq 'FAIL') { $color = 'Red' }
    elseif ($Status -eq 'WARN') { $color = 'Yellow' }
    elseif ($Status -eq 'UNTESTED') { $color = 'Yellow' }
    elseif ($Status -eq 'NOT TESTED') { $color = 'DarkYellow' }
    Write-Host ("  [{0,-10}] {1}" -f $Status, $Text) -ForegroundColor $color
}
