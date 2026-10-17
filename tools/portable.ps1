# CNKI Research Portable -- environment check, install, uninstall, rollback, diagnose.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\portable.ps1 -Action check
#
# Every action except `check`, `status` and `diagnose` mutates state, and every
# mutating action takes a backup first. Nothing here writes to the bundle that is
# currently servicing a running DSH until the very last step, and no step ever
# removes a Windows directory junction with a recursive delete.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('check', 'install', 'uninstall', 'rollback', 'upgrade', 'status', 'diagnose', 'plan')]
    [string]$Action,

    # Where the extracted distribution lives. Defaults to the directory above tools\.
    [string]$PackageRoot,

    # Where the runtime lives (<InstallRoot>\.venv, <InstallRoot>\bundle\...).
    # Defaults to PackageRoot, so extracting and installing in place needs no options.
    [string]$InstallRoot,

    # Harness home. Defaults to $env:DSH_HOME, then $env:USERPROFILE\.dsh.
    [string]$DshHome,

    # DSH profile to install into. `desktop` is the interactive Desktop profile.
    [string]$DshProfile = 'desktop',

    # Shipped template used to initialize the profile when it does not exist yet.
    # Only consulted for a non-`desktop` profile; the Desktop profile is owned by
    # the Desktop application and must already exist.
    [ValidateSet('web', 'headless', 'acp', 'sdk', 'sdk-minimal')]
    [string]$ProfileTemplate = 'web',

    # Path to resources\runtime\cli\bin\dsh.cmd. Discovered when omitted.
    [string]$DshCli,

    # Optional: make this CNKI profile the cnki-mcp default (created on demand).
    [string]$CnkiProfile,

    # Explicit interpreter. Discovered when omitted.
    [string]$Python,

    # Explicit uv executable. Discovered (and installed if missing) when omitted.
    [string]$Uv,

    # How the cnki-mcp dependency is obtained.
    [ValidateSet('vendor', 'pypi', 'git')]
    [string]$Upstream = 'vendor',

    # Version/commit/service used by the non-vendor strategies.
    [string]$UpstreamVersion,
    [string]$UpstreamCommit,
    [string]$UpstreamRepository = 'https://github.com/sepinetam/cnki-mcp',

    # `link` keeps a junction to the bundle directory; `copy` installs a private copy.
    [ValidateSet('link', 'copy')]
    [string]$LinkMode = 'link',

    # Backup to restore for -Action rollback. Defaults to the newest one.
    [string]$Backup,

    # Reinstall over an existing or unknown installation.
    [switch]$Force,

    # Print the plan and change nothing (check/status/diagnose never change anything).
    [switch]$DryRun,

    # Also delete the venv and copied upstream tree.
    [switch]$PurgeRuntime,

    # Do not attempt to install missing tooling (uv).
    [switch]$NoToolInstall,

    # Never prompt; assume "yes" for the questions the caller already approved.
    [switch]$Yes,

    # Explicit authorisation to mutate the live user DSH home. Without it, every
    # mutating action against $env:USERPROFILE\.dsh is refused (see
    # Assert-MutationAllowed). `check`, `plan`, `status` and `diagnose` need it
    # never, because they do not mutate anything.
    [switch]$AllowProductionProfile,

    # Emit a single JSON document instead of the human report.
    [switch]$Json,

    # Pass --offline to uv (all wheels must already be in the uv cache).
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\PortableCommon.ps1')

# ===========================================================================
# Helpers
# ===========================================================================

$script:Checks = New-Object System.Collections.ArrayList
$script:Transcript = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Id, [string]$Status, [string]$Detail)
    [void]$script:Checks.Add((New-CheckResult -Id $Id -Status $Status -Detail $Detail))
}

function Add-Step {
    param([string]$Text)
    [void]$script:Transcript.Add($Text)
    if (-not $Json) { Write-Host "  -> $Text" }
}

function Confirm-Action {
    param([string]$Question)
    # In a dry run nothing is executed, so the honest answer is "this is what
    # would happen": report the action rather than the refusal.
    if ($DryRun) { return $true }
    # -Yes is the single explicit authorisation. -Json must NOT imply consent:
    # it only selects the output format, and treating it as "yes" would let a
    # purely diagnostic invocation mutate the machine.
    if ($Yes) { return $true }
    if ($Json) { return $false }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -eq 'y' -or $answer -eq 'Y' -or $answer -eq 'yes')
}

function Get-Manifest {
    param([string]$Path)
    $manifest = Read-JsonFile -Path $Path
    if (-not $manifest) { throw "manifest.json is missing or unreadable at $Path" }
    return $manifest
}

function Invoke-Native {
    <#
      Run an external command, echoing it. Output is captured unless -PassThruOutput
      is set (used when a tool prompts or streams progress).

      Native tooling writes progress to stderr by design (uv prints the interpreter
      it selected and a "Checked N packages" line there on a fully successful run).
      Under $ErrorActionPreference = 'Stop', Windows PowerShell 5.1 promotes each
      such NativeCommandError record to a *terminating* error, which would abort the
      install on success. The preference is therefore relaxed to 'Continue' for the
      duration of the call only: the process exit code is the single source of
      truth for success, and stderr is still captured into Output for reporting.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Environment,
        [string]$WorkingDirectory,
        [switch]$PassThruOutput
    )
    $display = "$File " + (($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    Add-Step $display
    if ($DryRun) { return [pscustomobject]@{ ExitCode = 0; Output = ''; Skipped = $true } }

    $saved = @{}
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
        }
    }
    $push = $null
    $preferenceBefore = $ErrorActionPreference
    try {
        if ($WorkingDirectory) { $push = (Get-Location).Path; Set-Location -LiteralPath $WorkingDirectory }
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        if ($PassThruOutput) {
            & $File @Arguments
            $code = $LASTEXITCODE
            if ($null -eq $code) { $code = 0 }
            return [pscustomobject]@{ ExitCode = $code; Output = ''; Skipped = $false }
        }
        $all = & $File @Arguments 2>&1
        $text = ($all | Out-String)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        return [pscustomobject]@{ ExitCode = $code; Output = $text; Skipped = $false }
    } finally {
        $ErrorActionPreference = $preferenceBefore
        if ($push) { Set-Location -LiteralPath $push }
        if ($Environment) {
            foreach ($key in $Environment.Keys) {
                [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
            }
        }
    }
}

# Test-VenvHealthy / Get-VenvPython / Get-VenvPackageVersions are provided by
# lib\PortableCommon.ps1, which is dot-sourced above.


# ===========================================================================
# Environment discovery
# ===========================================================================

function Get-Environment {
    param([string]$PackageRoot, [string]$InstallRoot, [string]$DshHome, [string]$DshProfile, [string]$DshCli, [string]$Python, [string]$Uv)

    $layout = Get-PortableLayout -PackageRoot $PackageRoot -InstallRoot $InstallRoot
    $resolvedHome = Get-DshHome -DshHome $DshHome

    $cli = Find-DshCli -Explicit $DshCli -DshHome $resolvedHome
    $appRoot = $null
    if ($cli) { $appRoot = Get-DshCliAppRoot -DshCli $cli }
    $desktopVersion = Get-DshDesktopVersion -DshHome $resolvedHome -AppRoot $appRoot
    $profileDir = Get-DshProfileDir -DshHome $resolvedHome -Profile $DshProfile

    $pythonInfo = $null
    try { $pythonInfo = Find-Python -Explicit $Python -AppRoot $appRoot -DshHome $resolvedHome } catch { $pythonInfo = $null }

    $uvInfo = $null
    try { $uvInfo = Find-Uv -Explicit $Uv } catch { $uvInfo = $null }

    $env = [pscustomobject]@{
        Layout          = $layout
        DshHome         = $resolvedHome
        DshProfile      = $DshProfile
        DshProfileDir   = $profileDir
        DshCli          = $cli
        DshAppRoot      = $appRoot
        DshDesktopVersion = $desktopVersion
        Python          = $pythonInfo
        Uv              = $uvInfo
        VenvPython      = $null
        Cnki            = $null
        Playwright      = (Get-PlaywrightBrowserInfo)
        Profile         = (Get-ProfileManifestInfo -ProfileDir $profileDir)
        Installed       = (Get-InstalledBundleInfo -ProfileDir $profileDir)
        OtherProfiles   = @(Get-AllProfilesWithPackage -DshHome $resolvedHome)
    }
    $env.VenvPython = Get-VenvPython -VenvDir $layout.VenvDir
    if ($env.VenvPython) {
        $env.Cnki = Get-CnkiProfileInfo -Python $env.VenvPython
    } elseif ($pythonInfo) {
        $env.Cnki = Get-CnkiProfileInfo -Python $pythonInfo.Path
    }
    return $env
}

function Test-DshVersionSupported {
    param([string]$Version, $Manifest)
    if (-not $Version) { return 'UNKNOWN' }
    $verified = @()
    if ($Manifest.compatibility -and $Manifest.compatibility.dshDesktopVerified) {
        $verified = @($Manifest.compatibility.dshDesktopVerified)
    }
    foreach ($v in $verified) { if ($v -eq $Version) { return 'VERIFIED' } }
    $range = $null
    if ($Manifest.compatibility) { $range = [string]$Manifest.compatibility.dshDesktopRange }
    return 'UNTESTED'
}

# ===========================================================================
# Reporting
# ===========================================================================

function Write-CheckReport {
    param($Environment, $Manifest, [string]$Action)

    if ($Json) { return }

    Write-Section "CNKI Research Portable -- $Action"

    $layout = $Environment.Layout
    Write-Host "  package root : $($layout.PackageRoot)"
    Write-Host "  install root : $($layout.InstallRoot)"
    Write-Host "  dsh home     : $($Environment.DshHome)"
    Write-Host "  dsh profile  : $($Environment.DshProfile)  ($($Environment.DshProfileDir))"
    Write-Host ''

    Write-Section 'Checks'
    foreach ($check in $script:Checks) {
        Write-Item -Status $check.status -Text ("{0}: {1}" -f $check.id, $check.detail)
    }
}

function Get-CheckSummary {
    $fail = 0; $warn = 0; $pass = 0; $nt = 0
    foreach ($check in $script:Checks) {
        if ($check.status -eq 'FAIL') { $fail++ }
        elseif ($check.status -eq 'WARN') { $warn++ }
        elseif ($check.status -eq 'PASS') { $pass++ }
        else { $nt++ }
    }
    return [pscustomobject]@{ pass = $pass; warn = $warn; fail = $fail; notTested = $nt }
}

# ===========================================================================
# check
# ===========================================================================

function Invoke-Check {
    param($Environment, $Manifest)
    $layout = $Environment.Layout

    # --- platform -----------------------------------------------------------
    $os = [System.Environment]::OSVersion
    $isWindows = ($env:OS -eq 'Windows_NT')
    if ($isWindows) {
        Add-Check 'platform' 'PASS' "Windows $($os.Version) on $env:PROCESSOR_ARCHITECTURE"
        if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { Add-Check 'architecture' 'PASS' 'x86_64 (the verified architecture)' }
        else { Add-Check 'architecture' 'WARN' "$env:PROCESSOR_ARCHITECTURE is outside the verified x86_64 target" }
    } else {
        Add-Check 'platform' 'NOT TESTED' "only Windows 11 / x86_64 is verified; this host reports $($os.Platform)"
    }

    # --- DSH ----------------------------------------------------------------
    if ($Environment.DshCli) {
        Add-Check 'dsh.cli' 'PASS' $Environment.DshCli
        if ($Environment.DshAppRoot) { Add-Check 'dsh.appRoot' 'PASS' $Environment.DshAppRoot }
    } else {
        Add-Check 'dsh.cli' 'FAIL' 'dsh.cmd not found; pass -DshCli <path to resources\runtime\cli\bin\dsh.cmd>'
    }
    if ($Environment.DshDesktopVersion) {
        $verdict = Test-DshVersionSupported -Version $Environment.DshDesktopVersion -Manifest $Manifest
        Add-Check 'dsh.version' $verdict "DSH Desktop $($Environment.DshDesktopVersion)"
    } else {
        Add-Check 'dsh.version' 'WARN' 'could not determine the DSH Desktop version'
    }
    if ($Environment.Profile.Exists) {
        $count = @($Environment.Profile.Bundles).Count
        Add-Check 'dsh.profile' 'PASS' "profile '$($Environment.DshProfile)' exists with $count bundle layer(s)"
    } elseif ($Environment.DshProfile -eq 'desktop') {
        Add-Check 'dsh.profile' 'FAIL' "the Desktop profile has no package.json; start DSH Desktop once so it initializes its profile"
    } else {
        Add-Check 'dsh.profile' 'WARN' "profile '$($Environment.DshProfile)' does not exist yet; -Action install initializes it from the shipped '$ProfileTemplate' template"
    }
    if ($Environment.DshProfile -eq 'desktop') {
        Add-Check 'dsh.profileKind' 'PASS' "the reserved Desktop profile; installing here changes the running Desktop's plugin set"
    } else {
        Add-Check 'dsh.profileKind' 'PASS' "custom profile '$($Environment.DshProfile)' (isolated from the Desktop profile)"
    }

    # --- python / uv --------------------------------------------------------
    if ($Environment.Python) {
        $src = 'system'
        if ($Environment.Python.Bundled) { $src = 'DSH-bundled runtime' }
        Add-Check 'python' 'PASS' "Python $($Environment.Python.Version) ($src) at $($Environment.Python.Path)"
    } else {
        Add-Check 'python' 'FAIL' 'no Python >= 3.11 found; install Python 3.11+ or pass -Python <path>'
    }
    if ($Environment.Uv) {
        Add-Check 'uv' 'PASS' "$($Environment.Uv.Version) at $($Environment.Uv.Path)"
    } else {
        $status = 'WARN'
        if ($NoToolInstall) { $status = 'FAIL' }
        Add-Check 'uv' $status 'uv not found; it can be installed automatically from the pinned version'
    }

    # --- runtime ------------------------------------------------------------
    if ($Environment.VenvPython) {
        if (Test-VenvHealthy -VenvDir $layout.VenvDir) {
            Add-Check 'runtime.venv' 'PASS' "usable environment at $($layout.VenvDir)"
        } else {
            Add-Check 'runtime.venv' 'FAIL' "venv exists at $($layout.VenvDir) but cnki_mcp/mcp/playwright are not importable"
        }
    } else {
        Add-Check 'runtime.venv' 'WARN' "no environment yet at $($layout.VenvDir); -Action install creates it"
    }

    $upstreamDir = $layout.UpstreamSource
    if (Test-Path -LiteralPath (Join-Path $upstreamDir 'pyproject.toml')) {
        Add-Check 'upstream.source' 'PASS' "vendored cnki-mcp source present at $upstreamDir"
    } else {
        Add-Check 'upstream.source' 'WARN' "no vendored source at $upstreamDir; -Upstream pypi|git needs the network"
    }
    if ($layout.SameRoot) {
        Add-Check 'upstream.location' 'PASS' 'the install root is the package root, so the shipped source is used in place'
    } elseif (Test-Path -LiteralPath (Join-Path $layout.UpstreamDir 'pyproject.toml')) {
        Add-Check 'upstream.location' 'PASS' "runtime source already materialized at $($layout.UpstreamDir)"
    } else {
        Add-Check 'upstream.location' 'WARN' "-Action install copies the source to $($layout.UpstreamDir)"
    }
    if (Test-Path -LiteralPath (Join-Path $upstreamDir 'uv.lock')) {
        Add-Check 'upstream.lock' 'PASS' 'uv.lock present: dependency resolution is frozen and reproducible'
    } else {
        Add-Check 'upstream.lock' 'WARN' 'uv.lock missing: dependency versions are not pinned'
    }

    # --- playwright browsers -------------------------------------------------
    $pw = $Environment.Playwright
    if ($pw.Exists -and @($pw.Chromium).Count -gt 0) {
        Add-Check 'playwright.browser' 'PASS' "chromium present: $(@($pw.Chromium) -join ', ')"
    } else {
        Add-Check 'playwright.browser' 'WARN' "no Chromium under $($pw.Root); -Action install downloads it"
    }

    # --- CNKI profile --------------------------------------------------------
    if ($Environment.Cnki -and $Environment.Cnki.ok) {
        $profiles = @($Environment.Cnki.profiles)
        if ($profiles.Count -gt 0) {
            Add-Check 'cnki.profile' 'PASS' "profiles: $($profiles -join ', '); default: $($Environment.Cnki.default)"
        } else {
            Add-Check 'cnki.profile' 'WARN' "no CNKI profile yet under $($Environment.Cnki.base); the login tool creates one on first use"
        }
    } else {
        Add-Check 'cnki.profile' 'WARN' 'cnki-mcp is not installed yet, so its profile store cannot be read'
    }

    # --- bundle structure ----------------------------------------------------
    $bundleDir = $layout.BundleSource
    foreach ($rel in @('package.json', 'cordis.patch.yml', 'launcher\cnki_research_launcher.py', 'skills\cnki-literature-search\SKILL.md')) {
        $full = Join-Path $bundleDir $rel
        if (Test-Path -LiteralPath $full -PathType Leaf) { Add-Check "bundle.$rel" 'PASS' "$rel present" }
        else { Add-Check "bundle.$rel" 'FAIL' "missing $rel in $bundleDir" }
    }
    $bundleManifest = Read-JsonFile -Path (Join-Path $bundleDir 'package.json')
    if ($bundleManifest) {
        if ($Manifest.bundle -and $bundleManifest.version -eq $Manifest.bundle.version -and $bundleManifest.name -eq $Manifest.bundle.name) {
            Add-Check 'bundle.identity' 'PASS' "$($bundleManifest.name)@$($bundleManifest.version) matches manifest.json"
        } else {
            Add-Check 'bundle.identity' 'FAIL' "bundle package.json ($($bundleManifest.name)@$($bundleManifest.version)) disagrees with manifest.json"
        }
    } else {
        Add-Check 'bundle.identity' 'FAIL' "cannot read $bundleDir\package.json"
    }

    # --- integrity -----------------------------------------------------------
    if ($Manifest.files) {
        $problems = @(Test-PackageIntegrity -PackageRoot $layout.PackageRoot -Manifest $Manifest)
        if ($problems.Count -eq 0) {
            Add-Check 'package.integrity' 'PASS' "$(@($Manifest.files).Count) file(s) match manifest.json SHA-256"
        } else {
            $preview = ($problems | Select-Object -First 3) -join '; '
            Add-Check 'package.integrity' 'FAIL' "$($problems.Count) integrity problem(s): $preview"
        }
    } else {
        Add-Check 'package.integrity' 'NOT TESTED' 'manifest.json has no files list'
    }

    # --- existing installation ----------------------------------------------
    $installed = $Environment.Installed
    if ($installed.LinkExists) {
        $version = $installed.Version
        $target = $installed.Target
        if ($installed.IsLink) {
            Add-Check 'existing.bundle' 'WARN' "'$($installed.PackageName)' is already installed as a link to $target (version $version)"
        } else {
            Add-Check 'existing.bundle' 'WARN' "'$($installed.PackageName)' is already installed as a real directory at $($installed.LinkPath) (version $version)"
        }
        if ($version -and $Manifest.bundle -and $version -eq $Manifest.bundle.version) {
            Add-Check 'existing.version' 'PASS' "installed version $version equals this package's $($Manifest.bundle.version)"
        } else {
            Add-Check 'existing.version' 'WARN' "installed version '$version' differs from this package's '$($Manifest.bundle.version)'"
        }
    } else {
        Add-Check 'existing.bundle' 'PASS' "no '$($installed.PackageName)' in profile '$($Environment.DshProfile)'"
    }
    $others = @($Environment.OtherProfiles | Where-Object { $_.Profile -ne $Environment.DshProfile })
    if ($others.Count -gt 0) {
        $names = ($others | ForEach-Object { $_.Profile }) -join ', '
        Add-Check 'existing.otherProfiles' 'WARN' "same-named plugin also present in profile(s): $names; installing here does not change them"
    } else {
        Add-Check 'existing.otherProfiles' 'PASS' 'no other profile declares this plugin'
    }

    # --- credentials ---------------------------------------------------------
    $credentialHits = @(Get-ChildItem -Path $bundleDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(cookies|storage_state)\.json$' -or $_.Name -match '\.(pem|key|pfx|p12)$' })
    if ($credentialHits.Count -eq 0) { Add-Check 'package.credentials' 'PASS' 'no cookies, storage state, keys or certificates inside the bundle' }
    else { Add-Check 'package.credentials' 'FAIL' "$($credentialHits.Count) credential-like file(s) found in the bundle" }

    # --- not verified here ---------------------------------------------------
    Add-Check 'mcp.protocol' 'NOT TESTED' 'run tests\run_all.ps1 to exercise the stdio MCP handshake'
    Add-Check 'dsh.guiPreset' 'NOT TESTED' 'verify the CNKI Research preset in a real DSH session after installing'
    Add-Check 'realSearch' 'NOT TESTED' 'requires a legally authorised institution login'
    return
}

# ===========================================================================
# install
# ===========================================================================

function Invoke-Install {
    param($Environment, $Manifest)
    $layout = $Environment.Layout

    if (-not $Environment.DshCli) { throw 'dsh.cmd not found; pass -DshCli <path> or install DSH Desktop first.' }
    Assert-MutationAllowed -DshHome $Environment.DshHome -Action 'install' -AllowProductionProfile:$AllowProductionProfile -WhatIfOnly:$DryRun
    if (-not $Environment.Profile.Exists) {
        if ($Environment.DshProfile -eq 'desktop') {
            throw "the Desktop profile does not exist; start DSH Desktop once so it initializes its profile, then re-run."
        }
        # `--from-default-profile` is the supported way to create a custom profile:
        # dsh-app-boot's prepareProfile() -> initializeProfileFromDefault().
        Add-Step "initialize profile '$($Environment.DshProfile)' from the shipped '$ProfileTemplate' template"
        $init = Invoke-Native -File $Environment.DshCli `
            -Arguments @('--profile', $Environment.DshProfile, '--from-default-profile', $ProfileTemplate, '--dump-config')
        if ($init.ExitCode -ne 0 -and -not $DryRun) {
            throw "could not initialize profile '$($Environment.DshProfile)'. Output:`n$($init.Output)"
        }
        $Environment.Profile = Get-ProfileManifestInfo -ProfileDir $Environment.DshProfileDir
        $Environment.Installed = Get-InstalledBundleInfo -ProfileDir $Environment.DshProfileDir
        if (-not $DryRun -and -not $Environment.Profile.Exists) {
            throw "profile '$($Environment.DshProfile)' was not created at $($Environment.DshProfileDir)"
        }
    }

    # 1. Toolchain -----------------------------------------------------------
    $pythonInfo = $Environment.Python
    if (-not $pythonInfo) { throw 'no Python >= 3.11 found; install one or pass -Python <path>.' }

    $uvInfo = $Environment.Uv
    if (-not $uvInfo) {
        if ($NoToolInstall) { throw 'uv not found and -NoToolInstall was given.' }
        $pinnedUv = $null
        if ($Manifest.dependencies -and $Manifest.dependencies.uv) { $pinnedUv = [string]$Manifest.dependencies.uv.version }
        $spec = 'uv'
        if ($pinnedUv) { $spec = "uv==$pinnedUv" }
        if (-not (Confirm-Action "Install the pinned uv ($spec) with pip into $($pythonInfo.Path)?")) {
            throw 'uv is required and was not installed.'
        }
        $pip = Invoke-Native -File $pythonInfo.Path -Arguments @('-m', 'pip', 'install', '--user', '--disable-pip-version-check', $spec) -PassThruOutput
        if ($pip.ExitCode -ne 0) {
            $pip = Invoke-Native -File $pythonInfo.Path -Arguments @('-m', 'pip', 'install', '--disable-pip-version-check', $spec) -PassThruOutput
        }
        if ($pip.ExitCode -ne 0 -and -not $DryRun) { throw "could not install uv ($spec)." }
        $uvInfo = Find-Uv
        if (-not $uvInfo -and -not $DryRun) {
            $candidate = Join-Path (Split-Path -Parent $pythonInfo.Path) 'Scripts\uv.exe'
            if (Test-Path -LiteralPath $candidate) { $uvInfo = [pscustomobject]@{ Path = $candidate; Version = 'unknown' } }
        }
        if (-not $uvInfo -and -not $DryRun) { throw 'uv was installed but is still not discoverable; pass -Uv <path>.' }
    }

    # 2. Existing installation ------------------------------------------------
    $installed = $Environment.Installed
    if ($installed.LinkExists -and -not $Force) {
        $sameTarget = ($installed.Target -and ((Get-NormalizedPath -Path $installed.Target) -eq (Get-NormalizedPath -Path $layout.BundleDir)))
        if ($sameTarget) {
            Add-Step "already installed from this directory (version $($installed.Version)); use -Force to reinstall"
            return 'already-installed'
        }
        throw ("'$($installed.PackageName)' is already installed in profile '$($Environment.DshProfile)' from " +
               "'$($installed.Target)' (version $($installed.Version)). Refusing to overwrite an unknown or foreign " +
               "installation. Re-run with -Force to replace it after a backup, or uninstall it first.")
    }

    # 3. Materialize the install root ----------------------------------------
    if (-not $layout.SameRoot) {
        if (-not (Test-Path -LiteralPath $layout.InstallRoot)) {
            Add-Step "create install root $($layout.InstallRoot)"
            if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $layout.InstallRoot | Out-Null }
        }
        $bundleParent = Split-Path -Parent $layout.BundleDir
        Add-Step "copy bundle to $($layout.BundleDir)"
        if (-not $DryRun) {
            New-Item -ItemType Directory -Force -Path $bundleParent | Out-Null
            Copy-Item -LiteralPath $layout.BundleSource -Destination $bundleParent -Recurse -Force
        }
        $upstreamParent = Split-Path -Parent $layout.UpstreamDir
        Add-Step "copy upstream source to $($layout.UpstreamDir)"
        if (-not $DryRun) {
            New-Item -ItemType Directory -Force -Path $upstreamParent | Out-Null
            Copy-Item -LiteralPath $layout.UpstreamSource -Destination $upstreamParent -Recurse -Force
        }
    } else {
        Add-Step "install in place at $($layout.InstallRoot)"
    }

    # 4. Python environment ---------------------------------------------------
    if ((Test-VenvHealthy -VenvDir $layout.VenvDir) -and -not $Force) {
        Add-Step "reuse the existing usable environment at $($layout.VenvDir)"
    } else {
        # An interrupted earlier install can leave a .venv without an interpreter
        # (uv writes .gitignore/CACHEDIR.TAG first). `uv sync` and `uv venv` both
        # refuse to work against it, which would make this install fail forever on
        # an artefact the user cannot see, so clear it before building.
        if (-not $DryRun) {
            $reset = Reset-BrokenVenv -VenvDir $layout.VenvDir
            if ($reset -eq 'removed' -or $reset -eq 'unlinked') {
                Add-Step "cleared an unusable environment at $($layout.VenvDir) ($reset); rebuilding it"
            } elseif ($reset -eq 'locked') {
                throw "$($layout.VenvDir) is locked by another uv process; close it and retry."
            }
        }
        switch ($Upstream) {
            'vendor' {
                $sourceDir = $layout.UpstreamDir
                if (-not (Test-Path -LiteralPath (Join-Path $sourceDir 'pyproject.toml'))) {
                    throw "vendored cnki-mcp source is missing at $sourceDir"
                }
                $uvArgs = @('sync', '--frozen', '--no-dev', '--no-editable', '--directory', $sourceDir, '--python', $pythonInfo.Path)
                if ($Offline) { $uvArgs += '--offline' }
                $env2 = @{ UV_PROJECT_ENVIRONMENT = $layout.VenvDir; UV_NO_PROGRESS = '1' }
                $result = Invoke-Native -File $uvInfo.Path -Arguments $uvArgs -Environment $env2
                if ($result.ExitCode -ne 0) { throw "uv sync failed:`n$($result.Output)" }
            }
            'pypi' {
                $version = $UpstreamVersion
                if (-not $version -and $Manifest.dependencies -and $Manifest.dependencies.cnkiMcp) { $version = [string]$Manifest.dependencies.cnkiMcp.version }
                if (-not $version) { throw '-Upstream pypi needs -UpstreamVersion.' }
                $venv = Invoke-Native -File $uvInfo.Path -Arguments @('venv', '--python', $pythonInfo.Path, $layout.VenvDir)
                if ($venv.ExitCode -ne 0) { throw "uv venv failed:`n$($venv.Output)" }
                $venvPython = Get-VenvPython -VenvDir $layout.VenvDir
                $install = Invoke-Native -File $uvInfo.Path -Arguments @('pip', 'install', '--python', $venvPython, "cnki-mcp==$version")
                if ($install.ExitCode -ne 0) { throw "uv pip install failed:`n$($install.Output)" }
            }
            'git' {
                if (-not $UpstreamCommit) { throw '-Upstream git needs -UpstreamCommit <sha>.' }
                $venv = Invoke-Native -File $uvInfo.Path -Arguments @('venv', '--python', $pythonInfo.Path, $layout.VenvDir)
                if ($venv.ExitCode -ne 0) { throw "uv venv failed:`n$($venv.Output)" }
                $venvPython = Get-VenvPython -VenvDir $layout.VenvDir
                $spec = "git+$UpstreamRepository@$UpstreamCommit"
                $install = Invoke-Native -File $uvInfo.Path -Arguments @('pip', 'install', '--python', $venvPython, $spec)
                if ($install.ExitCode -ne 0) { throw "uv pip install failed:`n$($install.Output)" }
            }
        }
        if (-not $DryRun -and -not (Test-VenvHealthy -VenvDir $layout.VenvDir)) {
            throw "the environment at $($layout.VenvDir) cannot import cnki_mcp/mcp/playwright"
        }
    }

    # 5. Playwright Chromium --------------------------------------------------
    $pw = Get-PlaywrightBrowserInfo
    if ((@($pw.Chromium).Count -eq 0) -or $Force) {
        $venvPython = Get-VenvPython -VenvDir $layout.VenvDir
        if ($venvPython) {
            if (Confirm-Action 'Download the Playwright Chromium build now?') {
                $install = Invoke-Native -File $venvPython -Arguments @('-m', 'playwright', 'install', 'chromium') -Environment @{ UV_NO_PROGRESS = '1' } -PassThruOutput
                if ($install.ExitCode -ne 0) { Add-Step "WARNING: playwright install chromium exited $($install.ExitCode); retry later with '$venvPython -m playwright install chromium'" }
            }
        }
    } else {
        Add-Step "reuse the installed Chromium build: $(@($pw.Chromium) -join ', ')"
    }

    # 6. Runtime descriptor ---------------------------------------------------
    $venvPython = Get-VenvPython -VenvDir $layout.VenvDir
    $cnkiInfo = $null
    if ($venvPython) { $cnkiInfo = Get-CnkiProfileInfo -Python $venvPython }
    $runtime = [pscustomobject]@{
        schemaVersion  = 1
        distribution   = [string]$Manifest.distribution.version
        bundle         = "$($Manifest.bundle.name)@$($Manifest.bundle.version)"
        installRoot    = $layout.InstallRoot
        python         = $venvPython
        launcher       = (Join-Path $layout.BundleDir 'launcher\cnki_research_launcher.py')
        upstream       = $Upstream
        upstreamDir    = $layout.UpstreamDir
        cnkiProfile    = $(if ($cnkiInfo -and $cnkiInfo.ok) { $cnkiInfo.default } else { $null })
        # Serve the provider-safe schemas by default: upstream's Pydantic
        # `anyOf: [X, {"type": "null"}]` shape is a known INVALID_REQUEST trigger.
        # Set this to $false to serve the verbatim upstream schemas instead.
        sanitizeSchema = $true
        installedAt    = (Get-Date).ToString('o')
        installedBy    = 'tools/portable.ps1'
    }
    Add-Step "write $($layout.RuntimeFile)"
    if (-not $DryRun) { Write-JsonFile -Path $layout.RuntimeFile -Value $runtime }

    # 7. Optional CNKI default profile ---------------------------------------
    # Setting the default profile rewrites %USERPROFILE%\.cnki-mcp\profiles\config.json,
    # which holds the user's real institution profiles. That is user data outside
    # $DshHome, so it is gated separately and never implied by -Yes alone.
    if ($CnkiProfile) {
        $cnkiHome = Get-CnkiStateHome
        $cnkiIsProduction = $false
        if ($cnkiHome -and (Test-Path -LiteralPath $cnkiHome)) { $cnkiIsProduction = $true }
        if ($cnkiIsProduction -and -not $AllowProductionProfile) {
            if ($DryRun) {
                Add-Step "NOTE: -CnkiProfile $CnkiProfile would rewrite $cnkiHome; executing it will require -AllowProductionProfile."
            } else {
                throw ("REFUSED: -CnkiProfile would change the default profile in the real CNKI state directory " +
                       "'$cnkiHome', which holds your institution login state. Re-run with -AllowProductionProfile " +
                       "if that is what you want, or omit -CnkiProfile and pick the profile inside the CNKI Research session.")
            }
        }
    }
    if ($CnkiProfile -and $venvPython -and (-not $cnkiIsProduction -or $AllowProductionProfile)) {
        if (Confirm-Action "Make '$CnkiProfile' the default CNKI profile? It is created if it does not exist.") {
            Add-Step "set the cnki-mcp default profile to '$CnkiProfile'"
            if (-not $DryRun) {
                try { $set = Set-CnkiDefaultProfile -Python $venvPython -Name $CnkiProfile; Add-Step "cnki-mcp default profile is now $($set.default)" }
                catch { Add-Step "WARNING: could not set the default CNKI profile: $_" }
            }
        } else {
            Add-Step 'skipped setting the default CNKI profile'
        }
    }

    # 8. Install the bundle through the official plugin manager ---------------
    $spec = $layout.BundleDir
    if ($LinkMode -eq 'link') { $spec = "link:$($layout.BundleDir)" }
    else { $spec = "file:$($layout.BundleDir)" }

    $backupDir = $null
    if (Confirm-Action "Install '$($Manifest.bundle.name)' into DSH profile '$($Environment.DshProfile)' now?") {
        $backupDir = New-ProfileBackup -ProfileDir $Environment.DshProfileDir -BackupDir $layout.BackupDir -Reason 'install'
        Add-Step "backed up profile manifest and lockfile to $backupDir"

        $add = Invoke-Native -File $Environment.DshCli -Arguments @('plugin', '--profile', $Environment.DshProfile, 'add', $spec)
        $ok = ($add.ExitCode -eq 0)
        if (-not $ok -and -not $DryRun) {
            Add-Step "plugin install failed (exit $($add.ExitCode)); restoring the profile backup"
            Restore-ProfileBackup -BackupDir $backupDir -ProfileDir $Environment.DshProfileDir
            throw "could not install the bundle. pnpm output:`n$($add.Output)"
        }
    } else {
        Add-Step 'skipped the profile install; the runtime is prepared but the preset is not registered'
    }

    # 9. Verify + record ------------------------------------------------------
    $after = Get-InstalledBundleInfo -ProfileDir $Environment.DshProfileDir
    $state = [pscustomobject]@{
        schemaVersion   = 1
        distribution    = [string]$Manifest.distribution.version
        bundle          = "$($Manifest.bundle.name)@$($Manifest.bundle.version)"
        installedAt     = (Get-Date).ToString('o')
        installRoot     = $layout.InstallRoot
        packageRoot     = $layout.PackageRoot
        dshHome         = $Environment.DshHome
        dshProfile      = $Environment.DshProfile
        dshProfileDir   = $Environment.DshProfileDir
        dshCli          = $Environment.DshCli
        dshVersion      = $Environment.DshDesktopVersion
        linkMode        = $LinkMode
        bundleDir       = $layout.BundleDir
        venvDir         = $layout.VenvDir
        python          = $venvPython
        backupDir       = $backupDir
        upstream        = $Upstream
        packages        = (Get-VenvPackageVersions -VenvPython $venvPython)
        verified        = [pscustomobject]@{
            profileDependency = ($after.LinkExists)
            linkTarget        = $after.Target
        }
        restartRequired = $false
    }
    Add-Step "write $($layout.StateFile)"
    if (-not $DryRun) { Write-JsonFile -Path $layout.StateFile -Value $state }

    if ($after.LinkExists) {
        Add-Step "verified: profile '$($Environment.DshProfile)' now resolves '$($Manifest.bundle.name)'"
    } elseif (-not $DryRun) {
        Add-Step 'WARNING: the profile does not resolve the bundle after the install; run -Action diagnose'
    }
    if (-not $Json) {
        Write-Host ''
        Write-Host '  restart-required: false' -ForegroundColor Green
        Write-Host '  Next: refresh the DSH page, start a new session, and pick the "CNKI Research" agent preset.'
    }
    return 'installed'
}

function Restore-ProfileBackup {
    param([Parameter(Mandatory = $true)][string]$BackupDir, [Parameter(Mandatory = $true)][string]$ProfileDir)
    $record = Read-JsonFile -Path (Join-Path $BackupDir 'backup.json')
    if (-not $record) { throw "no backup.json in $BackupDir" }
    foreach ($file in @($record.files)) {
        $source = Join-Path $BackupDir ($file -replace '[\\/]', '__')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $dest = Join-Path $ProfileDir $file
        $destDir = Split-Path -Parent $dest
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Copy-Item -LiteralPath $source -Destination $dest -Force
        Add-Step "restored $file"
    }
}

# ===========================================================================
# uninstall
# ===========================================================================

function Invoke-Uninstall {
    param($Environment, $Manifest)
    $layout = $Environment.Layout
    if (-not $Environment.DshCli) { throw 'dsh.cmd not found; pass -DshCli <path>.' }
    Assert-MutationAllowed -DshHome $Environment.DshHome -Action 'uninstall' -AllowProductionProfile:$AllowProductionProfile -WhatIfOnly:$DryRun
    if ($PurgeRuntime) {
        Assert-MutationAllowed -DshHome $Environment.DshHome -Action 'uninstall -PurgeRuntime' -AllowProductionProfile:$AllowProductionProfile -WhatIfOnly:$DryRun
    }

    $installed = $Environment.Installed
    # Guard: only ever uninstall the copy this distribution installed. A foreign
    # link (a hand-built plugin, another checkout, the frozen production bundle)
    # is reported and left alone.
    if ($installed.LinkExists -and $installed.IsLink -and $installed.Target) {
        $targetResolved = Get-NormalizedPath -Path $installed.Target
        $expected = Get-NormalizedPath -Path $layout.BundleDir
        if ($targetResolved -ne $expected) {
            if (-not $Force) {
                throw ("REFUSED: profile '$($Environment.DshProfile)' resolves '$($installed.PackageName)' from " +
                       "'$targetResolved', which is not this installation's bundle ('$expected'). " +
                       "This distribution only removes what it installed; re-run with -Force if you are sure.")
            }
            Add-Step "WARNING: removing a foreign installation from $targetResolved (-Force was given)"
        }
    }

    if (-not $installed.LinkExists) {
        $listed = @($Environment.Profile.Bundles) -contains $Manifest.bundle.name
        if (-not $listed) {
            Add-Step "'$($Manifest.bundle.name)' is not installed in profile '$($Environment.DshProfile)'"
        } else {
            Add-Step "the profile lists the bundle but its files are gone; use -Action diagnose"
        }
    }

    if (-not (Confirm-Action "Remove '$($Manifest.bundle.name)' from DSH profile '$($Environment.DshProfile)'?")) {
        Add-Step 'aborted by the operator'
        return 'aborted'
    }

    $backupDir = New-ProfileBackup -ProfileDir $Environment.DshProfileDir -BackupDir $layout.BackupDir -Reason 'uninstall'
    Add-Step "backed up profile manifest and lockfile to $backupDir"

    if ($installed.LinkExists) {
        $targetBefore = $installed.Target
        if ($installed.IsLink) {
            Add-Step "installed entry is a junction to $targetBefore; pnpm removes only the link"
        }
        $remove = Invoke-Native -File $Environment.DshCli -Arguments @('plugin', '--profile', $Environment.DshProfile, 'remove', $Manifest.bundle.name)
        if ($remove.ExitCode -ne 0 -and -not $DryRun) {
            Add-Step "pnpm remove failed (exit $($remove.ExitCode)); not touching the profile any further"
            throw "could not uninstall '$($Manifest.bundle.name)'. pnpm output:`n$($remove.Output)"
        }
        # Belt and braces: if pnpm left the link, unlink it without recursing.
        if (-not $DryRun -and (Test-Path -LiteralPath $installed.LinkPath)) {
            if (Test-IsReparsePoint -Path $installed.LinkPath) {
                $outcome = Remove-LinkSafely -Path $installed.LinkPath
                Add-Step "leftover junction $outcome"
            } else {
                Add-Step "WARNING: '$($installed.LinkPath)' is not a link and was left untouched; remove it manually if it is this plugin's copy"
            }
        }
        if ($targetBefore -and -not $DryRun) {
            if (Test-Path -LiteralPath $targetBefore) {
                Add-Step "verified: the link target still exists ($targetBefore) -- nothing was deleted through the junction"
            } else {
                Add-Step "WARNING: the link target $targetBefore no longer exists"
            }
        }
    } else {
        Add-Step 'nothing to unlink; only the bundle list is reconciled'
    }

    if ($PurgeRuntime) {
        if (Confirm-Action "Also delete the Python environment at $($layout.VenvDir)?") {
            if (-not $DryRun -and (Test-Path -LiteralPath $layout.VenvDir)) {
                if (Test-IsReparsePoint -Path $layout.VenvDir) {
                    Remove-LinkSafely -Path $layout.VenvDir | Out-Null
                } elseif (Test-TreeContainsReparsePoint -Path $layout.VenvDir -Depth 1) {
                    # Delete through nested links would follow them into their
                    # targets; refuse instead of risking unrelated data.
                    throw ("REFUSED: '$($layout.VenvDir)' contains a link/reparse point. " +
                           "Remove-Item -Recurse would follow it, so nothing was deleted. " +
                           "Inspect it manually before purging.")
                } else {
                    Remove-Item -LiteralPath $layout.VenvDir -Recurse -Force
                }
                Add-Step "removed $($layout.VenvDir)"
            }
        } else {
            Add-Step 'kept the Python environment (purge was not confirmed)'
        }
    } else {
        Add-Step "kept the Python environment at $($layout.VenvDir) (use -PurgeRuntime to remove it)"
    }

    if (-not $DryRun) {
        $after = Get-InstalledBundleInfo -ProfileDir $Environment.DshProfileDir
        if ($after.LinkExists) { Add-Step 'WARNING: the bundle is still present after uninstall' }
        else { Add-Step 'verified: the profile no longer resolves the bundle' }
        if (Test-Path -LiteralPath $layout.RuntimeFile) { Remove-Item -LiteralPath $layout.RuntimeFile -Force }
        if (Test-Path -LiteralPath $layout.StateFile) { Remove-Item -LiteralPath $layout.StateFile -Force }
    }
    return 'uninstalled'
}

# ===========================================================================
# rollback
# ===========================================================================

function Invoke-Rollback {
    param($Environment, $Manifest)
    $layout = $Environment.Layout
    if (-not $Environment.DshCli) { throw 'dsh.cmd not found; pass -DshCli <path>.' }
    Assert-MutationAllowed -DshHome $Environment.DshHome -Action 'rollback' -AllowProductionProfile:$AllowProductionProfile -WhatIfOnly:$DryRun

    $backupDir = $Backup
    if (-not $backupDir) {
        # Not simply "the newest": after an uninstall the newest snapshot is the
        # post-removal state, which would restore the very thing being escaped.
        # Pick the newest backup that still declares the bundle.
        $backupDir = Get-RestorableBackup -BackupDir $layout.BackupDir -PackageName $Manifest.bundle.name
        if (-not $backupDir) {
            $newest = Get-LatestBackup -BackupDir $layout.BackupDir
            if ($newest) {
                throw ("no backup under $($layout.BackupDir) restores '$($Manifest.bundle.name)': the newest " +
                       "($newest) is a post-uninstall snapshot that no longer declares it. Pass -Backup <dir> to " +
                       "choose one explicitly.")
            }
        }
    }
    if (-not $backupDir) { throw "no backup found under $($layout.BackupDir)" }
    $backupDir = Get-NormalizedPath -Path $backupDir
    if (-not (Test-Path -LiteralPath (Join-Path $backupDir 'backup.json'))) { throw "$backupDir is not a portable backup directory" }

    Add-Step "restoring profile files from $backupDir"
    if (-not (Confirm-Action 'Restore this backup and reinstall the profile dependencies?')) {
        Add-Step 'aborted by the operator'
        return 'aborted'
    }

    # Keep a copy of the current state so a rollback is itself reversible.
    $safety = New-ProfileBackup -ProfileDir $Environment.DshProfileDir -BackupDir $layout.BackupDir -Reason 'pre-rollback'
    Add-Step "saved the current state to $safety"

    Restore-ProfileBackup -BackupDir $backupDir -ProfileDir $Environment.DshProfileDir

    # Repairing node_modules after a rollback needs `plugin add`, not `plugin install`.
    # dsh's reconcile pass (dsh-plugin-manager operations.js) resolves every bundle
    # listed in the profile BEFORE pnpm runs, so with the link missing it aborts with
    # "cannot resolve profile bundle ... run 'dsh plugin install'" -- the very command
    # it is telling you to run. `plugin add` creates the node_modules entry and then
    # finds the lockfile already up to date.
    $afterRestore = Get-InstalledBundleInfo -ProfileDir $Environment.DshProfileDir
    if ($afterRestore.LinkExists) {
        Add-Step 'the profile already resolves the bundle; no dependency repair needed'
    } else {
        $spec = if ($LinkMode -eq 'link') { "link:$($layout.BundleDir)" } else { "file:$($layout.BundleDir)" }
        $repair = Invoke-Native -File $Environment.DshCli `
            -Arguments @('plugin', '--profile', $Environment.DshProfile, 'add', $spec)
        if ($repair.ExitCode -ne 0 -and -not $DryRun) {
            throw ("the restored manifest was written but the profile still does not resolve the bundle " +
                   "(plugin add exited $($repair.ExitCode)). Re-run: dsh plugin --profile $($Environment.DshProfile) " +
                   "add `"$spec`"`nOutput:`n$($repair.Output)")
        }
    }

    if (-not $DryRun) {
        $after = Get-InstalledBundleInfo -ProfileDir $Environment.DshProfileDir
        if ($after.LinkExists) {
            Add-Step "verified: profile '$($Environment.DshProfile)' resolves '$($Manifest.bundle.name)' again"
        } else {
            throw ("rollback restored the profile files but '$($Manifest.bundle.name)' is still not resolvable " +
                   "from $($Environment.DshProfileDir); run -Action diagnose")
        }
    }
    Add-Step 'rollback complete'
    return 'rolled-back'
}

# ===========================================================================
# status / diagnose
# ===========================================================================

function Invoke-Status {
    param($Environment, $Manifest)
    $layout = $Environment.Layout
    $state = Read-JsonFile -Path $layout.StateFile
    if (-not $state) {
        Add-Check 'status.state' 'NOT TESTED' "no install state at $($layout.StateFile)"
    } else {
        Add-Check 'status.state' 'PASS' "installed $($state.installedAt) as $($state.distribution) into profile '$($state.dshProfile)'"
    }
    $installed = $Environment.Installed
    if ($installed.LinkExists) {
        if ($installed.IsLink) { Add-Check 'status.link' 'PASS' "junction -> $($installed.Target)" }
        else { Add-Check 'status.link' 'PASS' "real directory at $($installed.LinkPath)" }
        Add-Check 'status.version' 'PASS' "resolved version $($installed.Version)"
    } else {
        Add-Check 'status.link' 'FAIL' 'the profile does not resolve the bundle'
    }
    if ($Environment.VenvPython -and (Test-VenvHealthy -VenvDir $layout.VenvDir)) {
        Add-Check 'status.runtime' 'PASS' (Get-VenvPackageVersions -VenvPython $Environment.VenvPython)
    } else {
        Add-Check 'status.runtime' 'FAIL' "no usable environment at $($layout.VenvDir)"
    }
    return
}

function Invoke-Diagnose {
    param($Environment, $Manifest)
    Invoke-Check -Environment $Environment -Manifest $Manifest
    Invoke-Status -Environment $Environment -Manifest $Manifest
    $layout = $Environment.Layout

    $venvPython = $Environment.VenvPython
    $launcher = Join-Path $layout.BundleDir 'launcher\cnki_research_launcher.py'
    if ($venvPython -and (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        $check = Invoke-Native -File $venvPython -Arguments @($launcher, '--check') -PassThruOutput:$false
        if ($check.ExitCode -eq 0) { Add-Check 'launcher.check' 'PASS' 'the launcher reports a healthy import environment' }
        else { Add-Check 'launcher.check' 'FAIL' "launcher --check exited $($check.ExitCode): $($check.Output)" }

        $self = Invoke-Native -File $venvPython -Arguments @($launcher, '--selfcheck')
        if ($self.Output -match 'still broken') { Add-Check 'launcher.selfcheck' 'PASS' 'the upstream stdio transport is still broken, so this launcher is still required' }
        elseif ($self.Output -match 'may be fixed') { Add-Check 'launcher.selfcheck' 'WARN' 'upstream may be fixed; the launcher can be retired after re-verification' }
        else { Add-Check 'launcher.selfcheck' 'WARN' 'selfcheck produced no verdict' }
    } else {
        Add-Check 'launcher.check' 'NOT TESTED' 'no environment or launcher to probe'
    }

    $probe = Join-Path $layout.PackageRoot 'tools\probe_mcp_stdio.py'
    if ($venvPython -and (Test-Path -LiteralPath $probe -PathType Leaf)) {
        $result = Invoke-Native -File $venvPython -Arguments @($probe, '--launcher', $launcher, '--json')
        if ($result.ExitCode -eq 0) { Add-Check 'launcher.mcpProbe' 'PASS' 'stdio initialize + tools/list succeeded' }
        else { Add-Check 'launcher.mcpProbe' 'FAIL' "MCP probe exited $($result.ExitCode): $($result.Output)" }
    } else {
        Add-Check 'launcher.mcpProbe' 'NOT TESTED' 'no environment, or tools\probe_mcp_stdio.py is missing'
    }

    # Orphaned launcher processes are a common cause of "the browser will not start".
    $orphans = @(Get-CimInstance Win32_Process -Filter "Name like '%python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*cnki_research_launcher.py*' })
    if ($orphans.Count -eq 0) { Add-Check 'launcher.orphans' 'PASS' 'no launcher process is running' }
    else { Add-Check 'launcher.orphans' 'WARN' "$($orphans.Count) launcher process(es) already running (PID $((($orphans | ForEach-Object { $_.ProcessId }) -join ', ')))" }
    return
}

# ===========================================================================
# main
# ===========================================================================

try {
    $manifest = Get-Manifest -Path (Join-Path (Get-PortableLayout -PackageRoot $PackageRoot -InstallRoot $InstallRoot).PackageRoot 'manifest.json')
    $environment = Get-Environment -PackageRoot $PackageRoot -InstallRoot $InstallRoot -DshHome $DshHome `
        -DshProfile $DshProfile -DshCli $DshCli -Python $Python -Uv $Uv

    $outcome = 'ok'
    switch ($Action) {
        'check'     { Invoke-Check -Environment $environment -Manifest $manifest }
        'plan'      {
            # A plan is a real dry run of the install: the same code path, with
            # every side effect suppressed, so the step list is exactly what
            # INSTALL would do. No write, no profile change, no process started.
            $script:DryRun = $true
            $outcome = Invoke-Install -Environment $environment -Manifest $manifest
        }
        'install'   { Invoke-Check -Environment $environment -Manifest $manifest; $outcome = Invoke-Install -Environment $environment -Manifest $manifest }
        'uninstall' { $outcome = Invoke-Uninstall -Environment $environment -Manifest $manifest }
        'rollback'  { $outcome = Invoke-Rollback -Environment $environment -Manifest $manifest }
        'upgrade'   { Invoke-Check -Environment $environment -Manifest $manifest; $outcome = Invoke-Install -Environment $environment -Manifest $manifest }
        'status'    { Invoke-Status -Environment $environment -Manifest $manifest }
        'diagnose'  { Invoke-Diagnose -Environment $environment -Manifest $manifest }
    }

    $summary = Get-CheckSummary
    if ($Json) {
        $payload = [pscustomobject]@{
            action = $Action
            outcome = $outcome
            dryRun = [bool]$DryRun
            distribution = [string]$manifest.distribution.version
            installRoot = $environment.Layout.InstallRoot
            dshHome = $environment.DshHome
            dshProfile = $environment.DshProfile
            dshVersion = $environment.DshDesktopVersion
            summary = $summary
            checks = @($script:Checks)
            steps = @($script:Transcript)
        }
        Write-Output ($payload | ConvertTo-Json -Depth 8)
    } else {
        Write-CheckReport -Environment $environment -Manifest $manifest -Action $Action
        Write-Section 'Summary'
        Write-Item -Status 'PASS' -Text "$($summary.pass) passed"
        if ($summary.warn -gt 0) { Write-Item -Status 'WARN' -Text "$($summary.warn) warning(s)" }
        if ($summary.fail -gt 0) { Write-Item -Status 'FAIL' -Text "$($summary.fail) failure(s)" }
        if ($summary.notTested -gt 0) { Write-Item -Status 'NOT TESTED' -Text "$($summary.notTested) not testable in this environment" }
        Write-Host ''
        Write-Host "  outcome: $outcome"
    }

    # `plan` is included because it is a dry run of install: a plan that reports a
    # FAIL must not look like success to a script. status/diagnose report on an
    # arbitrary existing state and stay exit 0.
    if ($summary.fail -gt 0 -and $Action -in @('check', 'plan', 'install', 'upgrade')) { exit 2 }
    exit 0
} catch {
    $message = $_.Exception.Message
    if ($Json) {
        $summary = Get-CheckSummary
        $payload = [pscustomobject]@{
            action = $Action; outcome = 'error'; error = $message
            summary = $summary; checks = @($script:Checks); steps = @($script:Transcript)
        }
        Write-Output ($payload | ConvertTo-Json -Depth 8)
    } else {
        Write-Host ''
        Write-Host "ERROR: $message" -ForegroundColor Red
        if ($script:Transcript.Count -gt 0) {
            Write-Host ''
            Write-Host 'Steps before the failure:'
            foreach ($step in $script:Transcript) { Write-Host "  - $step" }
        }
    }
    exit 1
}
