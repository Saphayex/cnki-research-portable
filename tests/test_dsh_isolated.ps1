# DSH installation test inside a fully isolated DSH_HOME.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_dsh_isolated.ps1 [-Json] [-ReportPath <p>]
#
# Why a separate DSH_HOME
# -----------------------
# `$DSH_HOME` is the only supported way to relocate DSH user data
# (@deepseek-ai/dsh-home-paths `resolveDshHome`). `DSH_PROFILE_DIR` is an output
# variable with no readers. A second profile under the *same* home still shares
# sessions/, attachments/, storages/, .credentials.yaml and the home-level
# cordis.patch.yml, and the Desktop reserves profile `desktop`. So this test
# creates a brand-new home under the package's excluded `_scratch\` directory and
# never touches the production home or the production profile.
#
# What it proves
#   1. a custom profile can be created the supported way
#      (`dsh --profile <name> --from-default-profile <template> --dump-config`);
#   2. the portable installer installs the bundle through the official
#      `dsh plugin` path, into the isolated home only;
#   3. the composed profile tree then contains the `cnki-research` preset and its
#      stdio MCP row, and contained neither before;
#   4. uninstalling removes the plugin while leaving the link target intact;
#   5. rolling back restores the dependency and pnpm repairs node_modules.
#
# It does NOT boot a DSH host and does NOT call a model: `--dump-config` is
# boot-free and does not evaluate `!!js`. Session-level tool visibility and real
# model calls require a real DSH surface and are reported separately.

[CmdletBinding()]
param(
    [string]$PackageRoot,
    [string]$InstallRoot,
    [string]$DshCli,
    [string]$DshProfileName = 'cnki-portable-test',
    [ValidateSet('web', 'headless', 'acp', 'sdk', 'sdk-minimal')]
    [string]$ProfileTemplate = 'web',
    [switch]$Json,
    [string]$ReportPath,
    [switch]$KeepHome
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\lib\PortableCommon.ps1')

$checks = New-Object System.Collections.ArrayList
function Add-Check2 { param([string]$Id, [string]$Status, [string]$Detail)
    [void]$checks.Add([pscustomobject]@{ id = $Id; status = $Status; detail = $Detail })
}
function Say { param([string]$Status, [string]$Text)
    if (-not $Json) { Write-Item -Status $Status -Text $Text }
}

$packageRootResolved = $PackageRoot
if (-not $packageRootResolved) { $packageRootResolved = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..')).FullName }
$layout = Get-PortableLayout -PackageRoot $packageRootResolved -InstallRoot $InstallRoot

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$sandbox = Join-Path $layout.PackageRoot "_scratch\dsh-isolated\$stamp"
$isolatedHome = Join-Path $sandbox 'home'
# Reuse the caller's install root when given (so an existing runtime is reused);
# otherwise build a private one under the sandbox, which exercises the
# "install root differs from package root" copy path.
$installRoot = $layout.InstallRoot
if (-not $InstallRoot) { $installRoot = Join-Path $sandbox 'install' }
New-Item -ItemType Directory -Force -Path $isolatedHome | Out-Null
if (-not (Test-Path -LiteralPath $installRoot)) { New-Item -ItemType Directory -Force -Path $installRoot | Out-Null }
$layout = Get-PortableLayout -PackageRoot $packageRootResolved -InstallRoot $installRoot

$cli = Find-DshCli -Explicit $DshCli -DshHome $isolatedHome
$outcome = [ordered]@{}
$fatal = $null
$scriptStartUtc = (Get-Date).ToUniversalTime()

# Fingerprint the production profile BEFORE anything else runs, so the final
# D6 check can prove it did not change rather than merely describing it.
$productionHomeBefore = Get-DshHome
$productionProfileBefore = Join-Path (Join-Path $productionHomeBefore 'profiles') 'desktop'
$productionBefore = Get-ProductionProfileFingerprint -ProfileDir $productionProfileBefore

if (-not $Json) {
    Write-Section 'DSH isolated-profile installation test'
    Write-Host "  isolated home  : $isolatedHome"
    Write-Host "  install root   : $installRoot"
    Write-Host "  dsh cli        : $(if ($cli) { $cli } else { '<not found>' })"
    Write-Host "  profile        : $DshProfileName (from the '$ProfileTemplate' template)"
}

# The whole test runs against the isolated home. Child processes inherit it.
# USERPROFILE is redirected too: upstream cnki-mcp roots its state at
# Path.home()/".cnki-mcp" (the institution profiles and browser auth state), which
# $DSH_HOME does not cover. This must happen BEFORE the profile is created -- the
# composed plugin set runs during profile initialization and would otherwise write
# its browser cookie jar into the real user's CNKI store.
$previousHome = $env:DSH_HOME
$previousUserProfile = $env:USERPROFILE
$sandboxedProfile = Join-Path $sandbox 'userprofile'
New-Item -ItemType Directory -Force -Path $sandboxedProfile | Out-Null
$cnkiStateBefore = Get-CnkiStateHome -UserProfile $previousUserProfile
$env:USERPROFILE = $sandboxedProfile
$env:DSH_HOME = $isolatedHome

try {
    if (-not $cli) {
        Add-Check2 'D0.dshCli' 'FAIL' 'dsh.cmd not found; pass -DshCli <path>'
        throw 'dsh.cmd not found'
    }
    Add-Check2 'D0.dshCli' 'PASS' $cli

    $version = ([string](& $cli --version 2>&1)).Trim()
    if ($LASTEXITCODE -eq 0 -and $version) { Add-Check2 'D0.dshVersion' 'PASS' "dsh --version -> $version" }
    else { Add-Check2 'D0.dshVersion' 'FAIL' "dsh --version exited $LASTEXITCODE" }

    $profileDir = Get-DshProfileDir -DshHome $isolatedHome -Profile $DshProfileName

    # --- 1. create the profile the supported way ---------------------------
    $initOut = & $cli --profile $DshProfileName --from-default-profile $ProfileTemplate --dump-config 2>&1
    $initExit = $LASTEXITCODE
    $initText = ($initOut | Out-String)
    if ($initExit -eq 0 -and (Test-Path -LiteralPath (Join-Path $profileDir 'package.json'))) {
        Add-Check2 'D1.profileCreated' 'PASS' "profile '$DshProfileName' initialized at $profileDir"
        Say 'PASS' "profile '$DshProfileName' created from the '$ProfileTemplate' template"
    } else {
        Add-Check2 'D1.profileCreated' 'FAIL' "exit $initExit; $(($initText -split "`n" | Select-Object -First 2) -join ' ')"
        throw 'could not initialize the isolated profile'
    }

    $beforeManifest = Read-JsonFile -Path (Join-Path $profileDir 'package.json')
    $beforeBundles = @($beforeManifest.dsh.profile.bundles)
    Add-Check2 'D1.templateBundles' 'PASS' "template bundles: $($beforeBundles -join ', ')"
    if ($initText -match 'preset-cnki-research') {
        Add-Check2 'D1.absentBefore' 'FAIL' 'the freshly created profile already mentions the preset'
    } else {
        Add-Check2 'D1.absentBefore' 'PASS' 'the freshly created profile contains no CNKI preset'
    }

    # --- 2. install through the portable installer --------------------------
    $installer = Join-Path $layout.PackageRoot 'tools\portable.ps1'
    $installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer,
        '-Action', 'install', '-PackageRoot', $layout.PackageRoot, '-InstallRoot', $installRoot,
        '-DshHome', $isolatedHome, '-DshProfile', $DshProfileName, '-DshCli', $cli, '-ProfileTemplate', $ProfileTemplate, '-Yes')
    $installOut = & powershell @installArgs 2>&1
    $installExit = $LASTEXITCODE
    $installText = ($installOut | Out-String)
    Write-TextFile -Path (Join-Path $sandbox 'installer-output.txt') -Text $installText

    $isolatedProfileDir = Get-DshProfileDir -DshHome $isolatedHome -Profile $DshProfileName
    $isolatedProfile = Get-ProfileManifestInfo -ProfileDir $isolatedProfileDir
    $isolatedBundleDir = Join-Path $installRoot 'bundle\cnki-research'
    $installed = Get-InstalledBundleInfo -ProfileDir $isolatedProfileDir

    if ($installExit -eq 0 -and $installed.LinkExists) {
        Add-Check2 'D2.installed' 'PASS' "installer exit 0; profile resolves the bundle via $($installed.Target)"
        Say 'PASS' 'the bundle is installed in the isolated profile'
    } else {
        Add-Check2 'D2.installed' 'FAIL' "installer exit $installExit; link exists: $($installed.LinkExists). Tail: $(($installText -split "`n" | Select-Object -Last 4) -join ' ')"
        throw 'the isolated install failed'
    }

    # The redirected USERPROFILE must actually be in force for the child installer
    # processes. If it were not, the installer's CNKI probe would read -- and its
    # optional -CnkiProfile would write -- the real user's institution store, which is
    # exactly the failure this assertion exists to prevent.
    $envUserProfileNow = [string]$env:USERPROFILE
    if ($envUserProfileNow -and ((Get-NormalizedPath -Path $envUserProfileNow) -ieq (Get-NormalizedPath -Path $sandboxedProfile))) {
        Add-Check2 'D2.userProfileSandboxed' 'PASS' "USERPROFILE is redirected to $sandboxedProfile for every child process"
    } else {
        Add-Check2 'D2.userProfileSandboxed' 'FAIL' "USERPROFILE is '$envUserProfileNow', not the sandbox '$sandboxedProfile'"
    }
    # And the installer must have reported the sandboxed CNKI store, not the real one.
    if ($installText -match [regex]::Escape($sandboxedProfile)) {
        Add-Check2 'D2.cnkiStoreSandboxed' 'PASS' 'the installer resolved the CNKI store inside the sandbox'
    } else {
        Add-Check2 'D2.cnkiStoreSandboxed' 'WARN' 'the installer output does not mention the sandboxed CNKI store; verify -CnkiProfile was not used'
    }

    $dependency = Get-ProfileDependency -ProfileInfo $isolatedProfile -Name '@local/dsh-cnki-research'
    if ($dependency -and $dependency -like 'link:*') {
        Add-Check2 'D2.dependency' 'PASS' "package.json dependency: $dependency"
    } else {
        Add-Check2 'D2.dependency' 'FAIL' "unexpected dependency value: $dependency"
    }
    if (@($isolatedProfile.Bundles) -contains '@local/dsh-cnki-research') {
        Add-Check2 'D2.bundleListed' 'PASS' 'dsh.profile.bundles contains the bundle'
    } else {
        Add-Check2 'D2.bundleListed' 'FAIL' 'dsh.profile.bundles does not list the bundle'
    }
    if ($installed.IsLink) {
        Add-Check2 'D2.linkKind' 'PASS' "installed entry is a link (junction) -> $($installed.Target)"
    } else {
        Add-Check2 'D2.linkKind' 'WARN' "installed entry is a real directory at $($installed.LinkPath)"
    }
    foreach ($rel in @('package.json', 'cordis.patch.yml', 'launcher\cnki_research_launcher.py', 'skills\cnki-literature-search\SKILL.md', 'portable.runtime.json')) {
        if (Test-Path -LiteralPath (Join-Path $isolatedBundleDir $rel)) {
            Add-Check2 "D2.bundle.$rel" 'PASS' "$rel present in the install root"
        } else {
            Add-Check2 "D2.bundle.$rel" 'FAIL' "$rel missing from $isolatedBundleDir"
        }
    }

    # --- 3. the composed tree contains the preset ---------------------------
    $afterOut = & $cli --profile $DshProfileName --dump-config 2>&1
    $afterExit = $LASTEXITCODE
    $afterText = ($afterOut | Out-String)
    Write-TextFile -Path (Join-Path $sandbox 'dump-config-after-install.txt') -Text $afterText
    Write-TextFile -Path (Join-Path $sandbox 'dump-config-before-install.txt') -Text $initText

    if ($afterExit -eq 0) {
        $markers = @{
            'D3.presetRow'      = 'preset-cnki-research'
            'D3.presetPlugin'   = '@deepseek-ai/dsh-agent-preset'
            'D3.presetId'       = 'cnki-research'
            'D3.mcpClient'      = '@deepseek-ai/dsh-mcp-client'
            'D3.serverName'     = 'serverName: cnki'
            'D3.skillFilesystem' = '@deepseek-ai/dsh-skill-filesystem'
        }
        foreach ($key in $markers.Keys) {
            if ($afterText.Contains($markers[$key])) { Add-Check2 $key 'PASS' "the composed tree contains '$($markers[$key])'" }
            else { Add-Check2 $key 'FAIL' "the composed tree does not contain '$($markers[$key])'" }
        }
        $occurrences = ([regex]::Matches($afterText, [regex]::Escape('serverName: cnki'))).Count
        if ($occurrences -eq 1) { Add-Check2 'D3.singleMcpRow' 'PASS' 'exactly one cnki MCP row in the composition' }
        else { Add-Check2 'D3.singleMcpRow' 'FAIL' "$occurrences cnki MCP rows in the composition" }
        $presetRows = ([regex]::Matches($afterText, [regex]::Escape('preset-cnki-research'))).Count
        if ($presetRows -ge 1) { Add-Check2 'D3.presetCount' 'PASS' "$presetRows preset reference(s)" }
        else { Add-Check2 'D3.presetCount' 'FAIL' 'no preset reference' }
    } else {
        Add-Check2 'D3.composition' 'FAIL' "dsh --dump-config exited $afterExit"
    }

    # The uninstall must be judged against a freshly installed state, so this
    # check runs before it.
    $bundleTargetBefore = $installed.Target
    if (-not $bundleTargetBefore) { $bundleTargetBefore = $isolatedBundleDir }
    # `portable.runtime.json` is generated by install and removed by uninstall, so
    # it is excluded here: the invariant under test is that no shipped bundle file
    # is ever touched by uninstalling.
    $countBundleFiles = {
        param([string]$Root)
        @(Get-ChildItem -LiteralPath $Root -Recurse -File |
            Where-Object { $_.Name -ne 'portable.runtime.json' }).Count
    }
    $targetFileCountBefore = & $countBundleFiles $bundleTargetBefore
    Add-Check2 'D4.targetBaseline' 'PASS' "$targetFileCountBefore shipped file(s) in $bundleTargetBefore before uninstall (generated runtime descriptor excluded)"

    # --- 4. uninstall -------------------------------------------------------
    $uninstallArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer,
        '-Action', 'uninstall', '-PackageRoot', $layout.PackageRoot, '-InstallRoot', $installRoot,
        '-DshHome', $isolatedHome, '-DshProfile', $DshProfileName, '-DshCli', $cli, '-Yes')
    $uninstallOut = & powershell @uninstallArgs 2>&1
    $uninstallExit = $LASTEXITCODE
    Write-TextFile -Path (Join-Path $sandbox 'installer-uninstall.txt') -Text (($uninstallOut | Out-String))

    $afterUninstall = Get-ProfileManifestInfo -ProfileDir $isolatedProfileDir
    $uninstalled = Get-InstalledBundleInfo -ProfileDir $isolatedProfileDir
    $dependencyAfter = Get-ProfileDependency -ProfileInfo $afterUninstall -Name '@local/dsh-cnki-research'
    if ($uninstallExit -eq 0 -and -not $dependencyAfter -and -not (@($afterUninstall.Bundles) -contains '@local/dsh-cnki-research')) {
        Add-Check2 'D4.uninstalled' 'PASS' 'the profile no longer declares or lists the bundle'
        Say 'PASS' 'uninstalled from the isolated profile'
    } else {
        Add-Check2 'D4.uninstalled' 'FAIL' "exit $uninstallExit; dependency='$dependencyAfter'; still listed=$(@($afterUninstall.Bundles) -contains '@local/dsh-cnki-research')"
    }
    if (-not $uninstalled.LinkExists) {
        Add-Check2 'D4.entryRemoved' 'PASS' 'the node_modules entry is gone'
    } else {
        Add-Check2 'D4.entryRemoved' 'WARN' "the node_modules entry remains at $($uninstalled.LinkPath) (pnpm can leave a link behind; the installer unlinks reparse points only)"
        if (Test-IsReparsePoint -Path $uninstalled.LinkPath) {
            $null = Remove-LinkSafely -Path $uninstalled.LinkPath
            Add-Check2 'D4.leftoverUnlinked' 'PASS' 'the leftover junction was unlinked without recursing'
        }
    }

    # The single most important safety property of this distribution.
    if (Test-Path -LiteralPath $bundleTargetBefore) {
        $targetFileCountAfter = & $countBundleFiles $bundleTargetBefore
        if ($targetFileCountAfter -eq $targetFileCountBefore) {
            Add-Check2 'D4.targetIntact' 'PASS' "all $targetFileCountAfter shipped file(s) in the link target survived the uninstall"
        } else {
            Add-Check2 'D4.targetIntact' 'FAIL' "link target went from $targetFileCountBefore to $targetFileCountAfter shipped file(s)"
        }
    } else {
        Add-Check2 'D4.targetIntact' 'FAIL' "the link target $bundleTargetBefore no longer exists after uninstall"
    }

    # --- 5. rollback --------------------------------------------------------
    $rollbackArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer,
        '-Action', 'rollback', '-PackageRoot', $layout.PackageRoot, '-InstallRoot', $installRoot,
        '-DshHome', $isolatedHome, '-DshProfile', $DshProfileName, '-DshCli', $cli, '-Yes')
    $rollbackOut = & powershell @rollbackArgs 2>&1
    $rollbackExit = $LASTEXITCODE
    Write-TextFile -Path (Join-Path $sandbox 'installer-rollback.txt') -Text (($rollbackOut | Out-String))
    $afterRollback = Get-ProfileManifestInfo -ProfileDir $isolatedProfileDir
    $dependencyRolled = Get-ProfileDependency -ProfileInfo $afterRollback -Name '@local/dsh-cnki-research'
    if ($rollbackExit -eq 0 -and $dependencyRolled) {
        Add-Check2 'D5.rollback' 'PASS' "rollback restored the dependency ($dependencyRolled)"
        Say 'PASS' 'rollback restored the pre-uninstall profile state'
    } else {
        Add-Check2 'D5.rollback' 'FAIL' "exit $rollbackExit; dependency='$dependencyRolled'"
    }
    $rolledBack = Get-InstalledBundleInfo -ProfileDir $isolatedProfileDir
    if ($rolledBack.LinkExists) { Add-Check2 'D5.repaired' 'PASS' 'pnpm repaired node_modules after the rollback' }
    else { Add-Check2 'D5.repaired' 'WARN' 'node_modules does not resolve the bundle after the rollback' }
}
catch {
    $fatal = $_.Exception.Message
    Add-Check2 'D.fatal' 'FAIL' $fatal
    if (-not $Json) { Write-Host "  ERROR: $fatal" -ForegroundColor Red }
}
finally {
    if ($previousHome) { $env:DSH_HOME = $previousHome } else { Remove-Item Env:\DSH_HOME -ErrorAction SilentlyContinue }
    if ($previousUserProfile) { $env:USERPROFILE = $previousUserProfile } else { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue }
    if (-not $KeepHome) {
        try { if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force } } catch { }
    }
}

# --- the real CNKI store must be untouched ---------------------------------
# What is actually assertable from outside the DSH host: the installer's own
# environment was redirected (D2.userProfileSandboxed above), and the set of CNKI
# profiles in the real store is exactly what it was before (nothing was added to it).
#
# A modification-time comparison is deliberately NOT used: `%USERPROFILE%\.cnki-mcp`
# also holds the live DSH host's own browser cookie jar, which the running Desktop
# touches whenever it checks authentication. Blaming that on this test would be a
# false positive, and tuning the assertion until it passed would make it worthless.
$cnkiStateAfter = Get-CnkiStateHome -UserProfile $previousUserProfile
if (-not (Test-Path -LiteralPath $cnkiStateAfter)) {
    Add-Check2 'D7.cnkiStateUntouched' 'PASS' 'the real CNKI store does not exist and was not created by the test'
} else {
    $profilesBefore = @()
    if (Test-Path -LiteralPath (Join-Path $cnkiStateBefore 'profiles')) {
        $profilesBefore = @(Get-ChildItem -LiteralPath (Join-Path $cnkiStateBefore 'profiles') -Force -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name | Sort-Object)
    }
    $profilesAfter = @()
    if (Test-Path -LiteralPath (Join-Path $cnkiStateAfter 'profiles')) {
        $profilesAfter = @(Get-ChildItem -LiteralPath (Join-Path $cnkiStateAfter 'profiles') -Force -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name | Sort-Object)
    }
    $added = @($profilesAfter | Where-Object { $profilesBefore -notcontains $_ })
    $removed = @($profilesBefore | Where-Object { $profilesAfter -notcontains $_ })
    if ($added.Count -eq 0 -and $removed.Count -eq 0) {
        Add-Check2 'D7.cnkiStateUntouched' 'PASS' ("the real CNKI profile set under $cnkiStateAfter is unchanged " +
            "($($profilesAfter.Count) entr(y/ies): $($profilesAfter -join ', '))")
    } else {
        Add-Check2 'D7.cnkiStateUntouched' 'FAIL' ("the real CNKI store changed: added [$($added -join ', ')], " +
            "removed [$($removed -join ', ')]")
    }
}

# --- the production home must be untouched ---------------------------------
# This is a before/after proof, not a shape check: the production profile's
# manifest and lockfile hashes, and the existence of its resolved bundle link,
# are compared against the values captured before the isolated test started.
$productionHome = Get-DshHome
$productionProfile = Join-Path (Join-Path $productionHome 'profiles') 'desktop'
$productionAfter = Get-ProductionProfileFingerprint -ProfileDir $productionProfile
if ($productionBefore -and $productionBefore.exists -and $productionAfter.exists) {
    if ($productionBefore.packageJsonSha256 -eq $productionAfter.packageJsonSha256 -and
        $productionBefore.pnpmLockSha256 -eq $productionAfter.pnpmLockSha256) {
        Add-Check2 'D6.productionUntouched' 'PASS' ("the production desktop profile is byte-identical before and after " +
            "(package.json $($productionAfter.packageJsonSha256.Substring(0,12))..., link target unchanged)")
    } else {
        Add-Check2 'D6.productionUntouched' 'FAIL' ("the production desktop profile CHANGED during the test: " +
            "package.json $($productionBefore.packageJsonSha256) -> $($productionAfter.packageJsonSha256); " +
            "pnpm-lock.yaml $($productionBefore.pnpmLockSha256) -> $($productionAfter.pnpmLockSha256)")
    }
} else {
    Add-Check2 'D6.productionUntouched' 'NOT TESTED' ("no production desktop profile to compare " +
        "(before exists=$($productionBefore.exists), after exists=$($productionAfter.exists))")
}

$fails = @($checks | Where-Object { $_.status -eq 'FAIL' })
$warns = @($checks | Where-Object { $_.status -eq 'WARN' })
$passes = @($checks | Where-Object { $_.status -eq 'PASS' })
$summaryText = "$($passes.Count) pass / $($warns.Count) warn / $($fails.Count) fail"

$report = [pscustomobject]@{
    suite = 'dsh-isolated'
    isolatedHome = $isolatedHome
    installRoot = $installRoot
    profile = $DshProfileName
    profileTemplate = $ProfileTemplate
    sandboxKept = [bool]$KeepHome
    summary = $summaryText
    fatal = $fatal
    checks = @($checks)
}
if ($ReportPath) { Write-JsonFile -Path $ReportPath -Value $report }
if ($Json) {
    Write-Output ($report | ConvertTo-Json -Depth 8)
} else {
    Write-Section 'Isolated DSH test summary'
    foreach ($check in $checks) { Write-Item -Status $check.status -Text "$($check.id): $($check.detail)" }
    Write-Host ''
    Write-Host "  $summaryText"
}
exit $(if ($fails.Count -eq 0) { 0 } else { 1 })
