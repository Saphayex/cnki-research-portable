# =====================================================================================
# setup.ps1 - CNKI Research Portable unified entry point (unified RC3 candidate)
#
# 统一入口 / unified entry:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action check   [-InstallRoot <dir>]
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action plan    [-InstallRoot <dir>]
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action install [-InstallRoot <dir>] -Yes
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action upgrade -InstallRoot <rc2>                (read-only PLAN, prints planId)
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action upgrade -InstallRoot <rc2> -PlanId <id> -Yes   (transactional APPLY)
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action verify  [-InstallRoot <dir>]
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action status  [-InstallRoot <dir>]
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action rollback [-InstallRoot <dir>] [-RollbackTarget auto|upgrade|install] -Yes
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup.ps1 -Action uninstall [-InstallRoot <dir>] -Yes
#
# Actions: check | plan | install | upgrade | verify | status | rollback | uninstall
# Exit codes: 0 = success / no FAIL; 2 = refused / FAIL / conflict / unknown / incomplete;
#             1 = tool or internal error.
# Read-only actions: check, plan, status, verify (write nothing except an explicit -OutFile).
#
# Routing (charter D8):
#   check / plan / verify / status / upgrade / rollback(upgrade)  -> embedded engine
#       tools\lib\UpgradeCommon.ps1   (Invoke-UpgraderAction -Options ... -> {doc, exitCode})
#   install / uninstall / rollback(install)                       -> child process
#       powershell.exe -NoProfile -ExecutionPolicy Bypass -File <PackageRoot>\tools\portable.ps1
#       with explicitly mapped arguments (byte-unchanged frozen installer).
#
#   IMPORTANT / 重要: tools\portable.ps1 -Action upgrade is LEGACY behaviour
#   (reinstall-over-existing: it runs check + install again). It is NOT a safe
#   incremental upgrade. The only safe incremental path is
#   tools\setup.ps1 -Action upgrade (CHECK -> PLAN -> transactional APPLY, rollback-able).
#
# Windows PowerShell 5.1 only. Offline. No network. No profile edits. Never kills DSH.
# This file contains Chinese text and MUST be saved as UTF-8 WITH BOM.
# =====================================================================================

# NOTE: deliberately not [CmdletBinding()] - the script exposes an explicit -Verbose
# switch (V1 CLI style), which would collide with the common parameter.
param(
    # Unified action. Validated below (not via ValidateSet) so invalid input still
    # produces a machine-readable document and exit code 2.
    [string]$Action,

    # Package root: the extracted unified distribution tree. Defaults to the
    # directory above tools\ (i.e. this script's parent's parent).
    [string]$PackageRoot,

    # Installation root. Defaults to PackageRoot for install/check/plan/status/verify.
    # REQUIRED for upgrade (an existing installation must be named explicitly).
    [string]$InstallRoot,

    # DSH home. Defaults to the environment the child/engine resolves themselves.
    [string]$DshHome,

    # DSH profile to install into / inspect. `desktop` is the interactive profile.
    [string]$DshProfile = 'desktop',

    # planId returned by `-Action plan` / a read-only `-Action upgrade` run. Required
    # together with -Yes to execute a transactional upgrade APPLY.
    [string]$PlanId,

    # Upgrade transaction id for `-Action rollback` (newest when omitted).
    [string]$Transaction,

    # Rollback route: auto (newest upgrade transaction first, else installer backup),
    # upgrade (transaction engine only), install (installer backup only).
    [string]$RollbackTarget = 'auto',

    # Explicit authorisation to mutate the real user DSH home when the delegated
    # installer asks for it (forwarded to portable.ps1 only).
    [switch]$AllowProductionProfile,

    # Explicit consent for mutating actions. Without it setup prompts once on an
    # interactive console and refuses (exit 2) in -Json / -OutFile mode.
    [switch]$Yes,

    # Read-only preview: no mutation is executed by setup or by any child process.
    [switch]$DryRun,

    # install only: reinstall over an existing/unknown installation (LEGACY
    # reinstall-over-existing behaviour; forwarded to portable.ps1).
    [switch]$Force,

    # uninstall only: also delete the venv / copied upstream tree (forwarded).
    [switch]$PurgeRuntime,

    # Emit a single JSON document instead of the human report.
    [switch]$Json,

    # Write the JSON document to this file (additionally to stdout when -Json).
    [string]$OutFile,

    # Test-only fault plan (JSON file with a "faults" array). Honoured only when
    # $env:CNKI_UPGRADE_TEST_MODE=1; forwarded to the engine for engine routes.
    [string]$FaultPlan,

    # Forwarded to portable.ps1 (offline uv mode; skip installing missing tooling).
    [switch]$Offline,
    [switch]$NoToolInstall,

    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# =====================================================================================
# Script state / constants
# =====================================================================================

$script:SetupToolName = 'cnki-research-portable-setup'
$script:SetupToolVersion = '1.0.0'
$script:EnvelopeSchema = 1
$script:SetupActions = @('check', 'plan', 'install', 'upgrade', 'verify', 'status', 'rollback', 'uninstall')
$script:RollbackTargets = @('auto', 'upgrade', 'install')
$script:TargetVersionFallback = '1.0.0-rc.3'
$script:LegacyNotice = 'LEGACY: tools\portable.ps1 -Action upgrade is reinstall-over-existing (check+install), NOT a safe incremental upgrade. The only safe incremental upgrade path is tools\setup.ps1 -Action upgrade (CHECK -> PLAN -> transactional APPLY with backup/rollback).'
$script:RuntimeActivationNotTested = 'NOT TESTED'

$script:FinalDocument = $null
$script:ExitCode = 1
$script:EngineReady = $false
$script:EngineLoadError = $null
$script:EnginePath = Join-Path -Path $PSScriptRoot -ChildPath 'lib\UpgradeCommon.ps1'
$script:ScriptDirectory = $PSScriptRoot
$script:ScriptPackageRoot = $null
$script:PackageRootValue = $null
$script:InstallRootValue = $null
$script:InstallRootExplicit = $false
$script:PortableScriptPath = $null
$script:ActionName = ''
$script:MachineMode = $false
$script:Opt = @{}
$script:PackageInfo = $null
$script:TargetInfo = $null

# =====================================================================================
# Small generic helpers (no engine dependency)
# =====================================================================================

function Join-SetupPath {
    param([string]$Parent, [string]$Child)
    if ([string]::IsNullOrEmpty($Child)) { return $Parent }
    if ([string]::IsNullOrEmpty($Parent)) { return $Child }
    return ($Parent.TrimEnd('\', '/') + '\' + $Child.TrimStart('\', '/'))
}

function Get-SetupNormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $p = $Path.Trim()
    if ($p.Length -eq 0) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($p)
    } catch {
        return $null
    }
    if ($full.Length -gt 3 -and ($full.EndsWith('\') -or $full.EndsWith('/'))) {
        $full = $full.TrimEnd('\', '/')
    }
    return $full
}

function Test-SetupFileExists {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try { return [System.IO.File]::Exists($Path) } catch { return $false }
}

function Test-SetupDirExists {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try { return [System.IO.Directory]::Exists($Path) } catch { return $false }
}

function Get-SetupDirectoryEntryPaths {
    param([string]$Path)
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-SetupDirExists $Path)) { return $out.ToArray() }
    try {
        foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($Path)) { [void]$out.Add([string]$entry) }
    } catch {
        return $out.ToArray()
    }
    return $out.ToArray()
}

function Test-SetupPathEqual {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    $na = Get-SetupNormalizedPath $A
    $nb = Get-SetupNormalizedPath $B
    if ($null -eq $na -or $null -eq $nb) { return $false }
    return [string]::Equals($na, $nb, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SetupPathUnder {
    param([string]$Child, [string]$Parent)
    if ([string]::IsNullOrEmpty($Child) -or [string]::IsNullOrEmpty($Parent)) { return $false }
    $nc = Get-SetupNormalizedPath $Child
    $np = Get-SetupNormalizedPath $Parent
    if ($null -eq $nc -or $null -eq $np) { return $false }
    return ($nc.StartsWith(($np.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase))
}

function Read-SetupTextFile {
    param([string]$Path)
    if (-not (Test-SetupFileExists $Path)) { return $null }
    try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return $null }
}

function Read-SetupJsonFile {
    param([string]$Path)
    $text = Read-SetupTextFile $Path
    if ($null -eq $text -or $text.Trim().Length -eq 0) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Get-DocValue {
    # Safe property reader for ordered dictionaries AND ConvertFrom-Json objects.
    param($Doc, [string]$Name)
    if ($null -eq $Doc -or [string]::IsNullOrEmpty($Name)) { return $null }
    if ($Doc -is [System.Collections.IDictionary]) {
        if ($Doc.Contains($Name)) { return , $Doc[$Name] }
        return $null
    }
    try {
        $prop = $Doc.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $null }
        return , $prop.Value
    } catch {
        return $null
    }
}

function Test-DocHas {
    param($Doc, [string]$Name)
    if ($null -eq $Doc -or [string]::IsNullOrEmpty($Name)) { return $false }
    if ($Doc -is [System.Collections.IDictionary]) { return $Doc.Contains($Name) }
    try { return ($null -ne $Doc.PSObject.Properties[$Name]) } catch { return $false }
}

function Set-DocValue {
    param($Doc, [string]$Name, $Value)
    if ($Doc -is [System.Collections.IDictionary]) { $Doc[$Name] = $Value }
    else {
        if ($null -ne $Doc.PSObject.Properties[$Name]) { $Doc.PSObject.Properties[$Name].Value = $Value }
        else { Add-Member -InputObject $Doc -NotePropertyName $Name -NotePropertyValue $Value -Force }
    }
}

function Get-SetupArrayValue {
    # Array-typed document value for DIRECT assignment (PS 5.1-safe: the unary comma
    # prevents a single-element array from collapsing into a scalar).
    param($Object, [string]$Name)
    $value = Get-DocValue $Object $Name
    if ($null -eq $value) { return , @() }
    return , @($value)
}

function ConvertTo-SetupJsonText {
    param($Document)
    if ($null -eq $Document) { return 'null' }
    $json = $Document | ConvertTo-Json -Depth 30
    if ($null -eq $json) { return 'null' }
    return ($json -replace "`r`n", "`n")
}

function Write-SetupJsonFile {
    param([string]$Path, [string]$JsonText)
    $full = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if (-not [string]::IsNullOrEmpty($dir) -and -not [System.IO.Directory]::Exists($dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($JsonText)
    [System.IO.File]::WriteAllBytes($full, $bytes)
}

function ConvertTo-SetupExitCode {
    param($Code)
    $c = 0
    try { $c = [int]$Code } catch { return 2 }
    if ($c -eq 0) { return 0 }
    if ($c -eq 1) { return 1 }
    return 2
}

# =====================================================================================
# Check list / summary / outcome helpers
# =====================================================================================

function New-SetupCheck {
    param([string]$Id, [string]$Status, [string]$Detail)
    return [ordered]@{ id = $Id; status = $Status; detail = $Detail }
}

function New-SetupCheckList {
    return , (New-Object System.Collections.ArrayList)
}

function Add-SetupCheck {
    param($Checks, [string]$Id, [string]$Status, [string]$Detail)
    if ($null -eq $Checks) { return }
    [void]$Checks.Add((New-SetupCheck -Id $Id -Status $Status -Detail $Detail))
}

function Merge-SetupCheckLists {
    param($BaseChecks, $ExtraChecks)
    $merged = New-Object System.Collections.ArrayList
    foreach ($c in @($BaseChecks)) { if ($null -ne $c) { [void]$merged.Add($c) } }
    foreach ($c in @($ExtraChecks)) { if ($null -ne $c) { [void]$merged.Add($c) } }
    return , $merged
}

function ConvertTo-SetupCheckArray {
    # Plain array return (function output unrolls one level). Call sites that store
    # the result must wrap it as @(ConvertTo-SetupCheckArray ...) so a single-element
    # result still serializes as a JSON array instead of an object.
    param($Checks)
    if ($null -eq $Checks) { return @() }
    if ($Checks -is [System.Collections.ArrayList]) { return [object[]]$Checks.ToArray() }
    if ($Checks -is [System.Array]) { return [object[]]$Checks }
    return [object[]]@($Checks)
}

function Get-SetupCheckSummary {
    param($Checks)
    $pass = 0; $warn = 0; $fail = 0; $nt = 0
    foreach ($c in @(ConvertTo-SetupCheckArray $Checks)) {
        $st = [string](Get-DocValue $c 'status')
        if ($st -eq 'PASS') { $pass++ }
        elseif ($st -eq 'WARN') { $warn++ }
        elseif ($st -eq 'FAIL') { $fail++ }
        elseif ($st -eq 'NOT TESTED') { $nt++ }
    }
    return [ordered]@{ pass = $pass; warn = $warn; fail = $fail; notTested = $nt; refused = $false; outcome = '' }
}

function Get-SetupFailedCheckLines {
    param($Checks, $Warnings)
    $errors = New-Object System.Collections.ArrayList
    $warnList = New-Object System.Collections.ArrayList
    foreach ($c in @(ConvertTo-SetupCheckArray $Checks)) {
        $st = [string](Get-DocValue $c 'status')
        $id = [string](Get-DocValue $c 'id')
        $detail = [string](Get-DocValue $c 'detail')
        if ($st -eq 'FAIL') { [void]$errors.Add('CHECK_FAILED: ' + $id + ' - ' + $detail) }
        elseif ($st -eq 'WARN') { [void]$warnList.Add('CHECK_WARN: ' + $id + ' - ' + $detail) }
    }
    foreach ($w in @($Warnings)) { if (-not [string]::IsNullOrEmpty([string]$w)) { [void]$warnList.Add([string]$w) } }
    return [pscustomobject]@{ errors = $errors.ToArray(); warnings = $warnList.ToArray() }
}

# =====================================================================================
# Document envelope
# =====================================================================================

function New-SetupDocument {
    param([string]$ActionName)
    return New-Object System.Collections.Specialized.OrderedDictionary
}

function Initialize-SetupDocument {
    param($Doc, [string]$ActionName)
    $Doc['schemaVersion'] = $script:EnvelopeSchema
    $Doc['tool'] = $script:SetupToolName
    $Doc['toolVersion'] = $script:SetupToolVersion
    $Doc['action'] = $ActionName
    $Doc['generatedAt'] = (Get-Date).ToString('o')
    $Doc['ok'] = $false
    $Doc['exitCode'] = 1
    $Doc['summary'] = $null
    $Doc['checks'] = @()
    $Doc['route'] = 'setup'
    $Doc['sourceState'] = $null
    $Doc['state'] = $null
    $Doc['sourceVersion'] = $null
    $Doc['variant'] = $null
    $Doc['targetVersion'] = $script:TargetVersionFallback
    $Doc['installRoot'] = $null
    $Doc['packageRoot'] = $null
    $Doc['dshHome'] = $null
    $Doc['dshProfile'] = $null
    $Doc['planId'] = $null
    $Doc['plan'] = $null
    $Doc['transaction'] = $null
    $Doc['rollback'] = $null
    $Doc['verify'] = $null
    $Doc['status'] = $null
    $Doc['FILE_UPGRADE_COMPLETE'] = $null
    $Doc['DSH_RUNTIME_ACTIVATION_VERIFIED'] = $script:RuntimeActivationNotTested
    $Doc['runtimeActivation'] = $script:RuntimeActivationNotTested
    $Doc['legacyNotice'] = $script:LegacyNotice
    $Doc['outcome'] = $null
    $Doc['portable'] = $null
    $Doc['portableCheck'] = $null
    $Doc['engine'] = $null
    $Doc['source'] = $null
    $Doc['conflicts'] = $null
    $Doc['nextCommand'] = $null
    $Doc['errors'] = @()
    $Doc['warnings'] = @()
    return $Doc
}

function New-SetupActionDocument {
    param([string]$ActionName)
    $doc = New-SetupDocument -ActionName $ActionName
    return (Initialize-SetupDocument -Doc $doc -ActionName $ActionName)
}

function Complete-SetupDocument {
    param($Doc, [string]$ActionName)
    if ($null -eq $Doc) { $Doc = New-SetupActionDocument -ActionName $ActionName }
    if ($null -eq (Get-DocValue $Doc 'summary')) {
        $checks = @(ConvertTo-SetupCheckArray (Get-DocValue $Doc 'checks'))
        $summary = Get-SetupCheckSummary $checks
        $lines = Get-SetupFailedCheckLines $checks @()
        if ($summary.fail -gt 0) {
            $summary.outcome = 'FAIL'
            if ([int](Get-DocValue $Doc 'exitCode') -eq 0) { Set-DocValue $Doc 'exitCode' 2 }
            Set-DocValue $Doc 'ok' $false
        }
        Set-DocValue $Doc 'summary' $summary
        $docErrors = Get-SetupArrayValue $Doc 'errors'
        $docWarnings = Get-SetupArrayValue $Doc 'warnings'
        if ($docErrors.Count -eq 0) { Set-DocValue $Doc 'errors' $lines.errors }
        if ($docWarnings.Count -eq 0) { Set-DocValue $Doc 'warnings' $lines.warnings }
    }
    if ($null -eq (Get-DocValue $Doc 'state')) { Set-DocValue $Doc 'state' (Get-DocValue $Doc 'sourceState') }
    if ($null -eq (Get-DocValue $Doc 'dshHome')) { Set-DocValue $Doc 'dshHome' $script:Opt['DshHome'] }
    if ($null -eq (Get-DocValue $Doc 'dshProfile')) { Set-DocValue $Doc 'dshProfile' $script:Opt['DshProfile'] }
    if ($null -eq (Get-DocValue $Doc 'packageRoot') -and $null -ne $script:PackageRootValue) { Set-DocValue $Doc 'packageRoot' $script:PackageRootValue }
    if ($null -eq (Get-DocValue $Doc 'installRoot') -and $null -ne $script:InstallRootValue) { Set-DocValue $Doc 'installRoot' $script:InstallRootValue }
    if ($null -eq (Get-DocValue $Doc 'targetVersion')) { Set-DocValue $Doc 'targetVersion' $script:TargetVersionFallback }
    Set-DocValue $Doc 'DSH_RUNTIME_ACTIVATION_VERIFIED' $script:RuntimeActivationNotTested
    Set-DocValue $Doc 'runtimeActivation' $script:RuntimeActivationNotTested
    Set-DocValue $Doc 'legacyNotice' $script:LegacyNotice
    $finalSummary = Get-DocValue $Doc 'summary'
    if ($null -ne $finalSummary) {
        Set-DocValue $Doc 'outcome' ([string](Get-DocValue $finalSummary 'outcome'))
        Set-DocValue $Doc 'ok' ([int](Get-DocValue $Doc 'exitCode') -eq 0)
    }
    $verify = Get-DocValue $Doc 'verify'
    if ($null -ne $verify) { Set-DocValue $Doc 'FILE_UPGRADE_COMPLETE' (Get-DocValue $verify 'FILE_UPGRADE_COMPLETE') }
    return $Doc
}

function Set-SetupOutcome {
    param($Doc, $Checks, [int]$ExitCode, [string]$Outcome, [bool]$Refused = $false, $Errors = @(), $Warnings = @())
    $checksArray = @(ConvertTo-SetupCheckArray $Checks)
    Set-DocValue $Doc 'checks' $checksArray
    $summary = Get-SetupCheckSummary $checksArray
    $summary.refused = $Refused
    $summary.outcome = $Outcome
    Set-DocValue $Doc 'summary' $summary
    Set-DocValue $Doc 'exitCode' $ExitCode
    Set-DocValue $Doc 'ok' ($ExitCode -eq 0)
    Set-DocValue $Doc 'outcome' $Outcome
    $lines = Get-SetupFailedCheckLines $checksArray $Warnings
    $errList = New-Object System.Collections.ArrayList
    foreach ($e in @($Errors)) { if (-not [string]::IsNullOrEmpty([string]$e)) { [void]$errList.Add([string]$e) } }
    foreach ($e in @($lines.errors)) { [void]$errList.Add([string]$e) }
    Set-DocValue $Doc 'errors' $errList.ToArray()
    Set-DocValue $Doc 'warnings' $lines.warnings
    return $Doc
}

function Set-SetupRefused {
    param($Doc, [string]$Outcome, $Errors = @(), $ExtraChecks = @())
    $checks = Merge-SetupCheckLists (Get-DocValue $Doc 'checks') $ExtraChecks
    $existingErrors = Get-SetupArrayValue $Doc 'errors'
    $errList = New-Object System.Collections.ArrayList
    foreach ($e in @($Errors)) { if (-not [string]::IsNullOrEmpty([string]$e)) { [void]$errList.Add([string]$e) } }
    foreach ($e in $existingErrors) { if (-not [string]::IsNullOrEmpty([string]$e)) { [void]$errList.Add([string]$e) } }
    return (Set-SetupOutcome -Doc $Doc -Checks $checks -ExitCode 2 -Outcome $Outcome -Refused $true -Errors $errList.ToArray())
}

function Add-SetupExtraChecks {
    # Append checks to an engine-produced document without losing its outcome when
    # the appended checks are non-failing. If any appended check FAILs, the document
    # becomes a refusal (exit 2) with the supplied outcome/errors.
    param($Doc, $ExtraChecks, [string]$FailOutcome = 'REFUSED', $FailErrors = @())
    $existing = @(ConvertTo-SetupCheckArray (Get-DocValue $Doc 'checks'))
    $extra = @(ConvertTo-SetupCheckArray $ExtraChecks)
    if ($extra.Count -eq 0) { return $Doc }
    $merged = Merge-SetupCheckLists $existing $extra
    $anyNewFail = $false
    foreach ($c in $extra) { if ([string](Get-DocValue $c 'status') -eq 'FAIL') { $anyNewFail = $true } }
    if (-not $anyNewFail) {
        $docSummary = Get-DocValue $Doc 'summary'
        $outcome = ''
        if ($null -ne $docSummary) { $outcome = [string](Get-DocValue $docSummary 'outcome') }
        $summary = Get-SetupCheckSummary $merged
        $summary.outcome = $outcome
        $summary.refused = [bool](Get-DocValue $docSummary 'refused')
        Set-DocValue $Doc 'checks' (@(ConvertTo-SetupCheckArray $merged))
        Set-DocValue $Doc 'summary' $summary
        $warn = New-Object System.Collections.ArrayList
        foreach ($w in (Get-SetupArrayValue $Doc 'warnings')) { [void]$warn.Add($w) }
        foreach ($c in $extra) {
            if ([string](Get-DocValue $c 'status') -eq 'WARN') {
                [void]$warn.Add('CHECK_WARN: ' + [string](Get-DocValue $c 'id') + ' - ' + [string](Get-DocValue $c 'detail'))
            }
        }
        Set-DocValue $Doc 'warnings' ($warn.ToArray())
        return $Doc
    }
    $existingErrors = Get-SetupArrayValue $Doc 'errors'
    $errList = New-Object System.Collections.ArrayList
    foreach ($e in @($FailErrors)) { if (-not [string]::IsNullOrEmpty([string]$e)) { [void]$errList.Add([string]$e) } }
    foreach ($e in $existingErrors) { if (-not [string]::IsNullOrEmpty([string]$e)) { [void]$errList.Add([string]$e) } }
    return (Set-SetupOutcome -Doc $Doc -Checks $merged -ExitCode 2 -Outcome $FailOutcome -Refused $true -Errors $errList.ToArray())
}

function ConvertTo-SetupEngineDocument {
    # Wrap an engine document in the setup envelope while keeping every V1-style
    # field available at the SAME top-level location (charter D8 machine doc).
    param($EngineDoc, [string]$ActionName, [string]$Route = 'engine')
    $doc = New-SetupActionDocument -ActionName $ActionName
    $order = @('schemaVersion', 'generatedAt', 'ok', 'exitCode', 'summary', 'checks', 'sourceState', 'sourceVersion',
        'targetVersion', 'installRoot', 'packageRoot', 'planId', 'plan', 'transaction', 'verify', 'status', 'rollback',
        'source', 'conflicts', 'preservedFingerprints', 'faultInjection', 'errors', 'warnings', 'runtimeActivation')
    foreach ($k in $order) {
        if (Test-DocHas $EngineDoc $k) { Set-DocValue $doc $k (Get-DocValue $EngineDoc $k) }
    }
    # Any extra engine keys are preserved too.
    if ($EngineDoc -is [System.Collections.IDictionary]) {
        foreach ($k in @($EngineDoc.Keys)) {
            if (-not (Test-DocHas $doc $k)) { Set-DocValue $doc ([string]$k) (Get-DocValue $EngineDoc $k) }
        }
    } else {
        foreach ($p in @($EngineDoc.PSObject.Properties)) {
            if (-not (Test-DocHas $doc $p.Name)) { Set-DocValue $doc $p.Name $p.Value }
        }
    }
    Set-DocValue $doc 'route' $Route
    Set-DocValue $doc 'engine' ([ordered]@{
            tool        = [string](Get-DocValue $EngineDoc 'tool')
            toolVersion = [string](Get-DocValue $EngineDoc 'toolVersion')
            action      = [string](Get-DocValue $EngineDoc 'action')
        })
    $source = Get-DocValue $EngineDoc 'source'
    if ($null -ne $source) {
        $variant = Get-DocValue $source 'variant'
        if ($null -ne $variant) { Set-DocValue $doc 'variant' ([string]$variant) }
    }
    $engineSummary = Get-DocValue $EngineDoc 'summary'
    if ($null -ne $engineSummary) {
        Set-DocValue $doc 'outcome' ([string](Get-DocValue $engineSummary 'outcome'))
        Set-DocValue $doc 'ok' ([bool](Get-DocValue $EngineDoc 'ok'))
    }
    Set-DocValue $doc 'runtimeActivation' $script:RuntimeActivationNotTested
    return $doc
}

# =====================================================================================
# Engine loading (top-level dot-source; the engine is a package payload file)
# =====================================================================================

try {
    if (-not (Test-SetupFileExists $script:EnginePath)) {
        throw "engine library not found: $script:EnginePath"
    }
    $null = . $script:EnginePath
    foreach ($requiredFunction in @('Invoke-UpgraderAction', 'Get-PackageIntegrity')) {
        if (-not (Get-Command -Name $requiredFunction -ErrorAction SilentlyContinue)) {
            throw "engine library is missing required function: $requiredFunction"
        }
    }
    $script:EngineReady = $true
} catch {
    $script:EngineLoadError = $_.Exception.Message
    $script:EngineReady = $false
}

# =====================================================================================
# Engine invocation helpers
# =====================================================================================

function Get-SetupTargetVersion {
    if (-not [string]::IsNullOrEmpty($script:TargetVersion)) { return [string]$script:TargetVersion }
    return $script:TargetVersionFallback
}

function Test-SetupEngineReady {
    return [bool]$script:EngineReady
}

function New-SetupEngineOptions {
    param([string]$EngineAction, [string]$PlanIdValue, [string]$TransactionValue, [bool]$YesValue)
    return @{
        Action        = $EngineAction
        InstallRoot   = $script:InstallRootValue
        PackageRoot   = $script:PackageRootValue
        DshHome       = $script:Opt['DshHome']
        DshProfile    = $script:Opt['DshProfile']
        PlanId        = $PlanIdValue
        Transaction   = $TransactionValue
        BackupRoot    = ''
        Yes           = $YesValue
        Json          = $false
        OutFile       = ''
        FaultPlan     = $script:Opt['FaultPlan']
        TargetVersion = ''
        UpgradeId     = ''
        Verbose       = [bool]$script:Opt['Verbose']
    }
}

function Invoke-SetupEngineAction {
    param([string]$EngineAction, [string]$PlanIdValue = '', [string]$TransactionValue = '', [bool]$YesValue = $false)
    if (-not (Test-SetupEngineReady)) { throw "engine library is not available: $script:EngineLoadError" }
    $options = New-SetupEngineOptions -EngineAction $EngineAction -PlanIdValue $PlanIdValue -TransactionValue $TransactionValue -YesValue $YesValue
    $result = Invoke-UpgraderAction -Options $options
    if ($null -eq $result) { throw "engine returned no result for action '$EngineAction'" }
    $doc = Get-DocValue $result 'doc'
    $exitCode = Get-DocValue $result 'exitCode'
    if ($null -eq $doc) { throw "engine returned no document for action '$EngineAction'" }
    return [pscustomobject]@{ doc = $doc; exitCode = (ConvertTo-SetupExitCode $exitCode) }
}

function Get-SetupEngineSourceState {
    param($EngineDoc)
    return [string](Get-DocValue $EngineDoc 'sourceState')
}

# =====================================================================================
# Package / target inspection (read-only)
# =====================================================================================

function Get-SetupPackageInfo {
    param([string]$Root)
    $info = [ordered]@{
        packageRoot      = $Root
        exists           = (Test-SetupDirExists $Root)
        hasManifest      = $false
        hasSums          = $false
        hasUpgradeData   = $false
        hasPortable      = $false
        hasPortableCommon = $false
        hasEngine        = $false
        manifestDistribution = $null
    }
    if (-not $info.exists) { return $info }
    $info.hasManifest = (Test-SetupFileExists (Join-SetupPath $Root 'manifest.json'))
    $info.hasSums = (Test-SetupFileExists (Join-SetupPath $Root 'SHA256SUMS.txt'))
    $info.hasUpgradeData = (Test-SetupFileExists (Join-SetupPath $Root 'upgrade-data\rc2-to-rc3.json'))
    $info.hasPortable = (Test-SetupFileExists (Join-SetupPath $Root 'tools\portable.ps1'))
    $info.hasPortableCommon = (Test-SetupFileExists (Join-SetupPath $Root 'tools\lib\PortableCommon.ps1'))
    $info.hasEngine = (Test-SetupFileExists (Join-SetupPath $Root 'tools\lib\UpgradeCommon.ps1'))
    $manifest = Read-SetupJsonFile (Join-SetupPath $Root 'manifest.json')
    if ($null -ne $manifest) {
        $distribution = Get-DocValue $manifest 'distribution'
        $version = [string](Get-DocValue $distribution 'version')
        if ($version.Length -gt 0) { $info.manifestDistribution = $version }
    }
    return $info
}

function Get-SetupVersionMarkerReport {
    # Read-only cross-check of the four version markers. A mixed set means the tree
    # is in an UNKNOWN/mixed state and must not be silently upgraded/overwritten.
    param([string]$Root)
    $entries = New-Object System.Collections.ArrayList
    $versionText = Read-SetupTextFile (Join-SetupPath $Root 'VERSION')
    if ($null -ne $versionText -and $versionText.Trim().Length -gt 0) {
        [void]$entries.Add([ordered]@{ source = 'VERSION'; version = $versionText.Trim() })
    }
    $manifest = Read-SetupJsonFile (Join-SetupPath $Root 'manifest.json')
    if ($null -ne $manifest) {
        $version = [string](Get-DocValue (Get-DocValue $manifest 'distribution') 'version')
        if ($version.Length -gt 0) { [void]$entries.Add([ordered]@{ source = 'manifest.json'; version = $version }) }
    }
    $installState = Read-SetupJsonFile (Join-SetupPath $Root '_portable\install-state.json')
    if ($null -ne $installState) {
        $version = [string](Get-DocValue $installState 'distribution')
        if ($version.Length -gt 0) { [void]$entries.Add([ordered]@{ source = '_portable\install-state.json'; version = $version }) }
    }
    $runtime = Read-SetupJsonFile (Join-SetupPath $Root 'bundle\cnki-research\portable.runtime.json')
    if ($null -ne $runtime) {
        $version = [string](Get-DocValue $runtime 'distribution')
        if ($version.Length -gt 0) { [void]$entries.Add([ordered]@{ source = 'portable.runtime.json'; version = $version }) }
    }
    $distinct = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        $v = [string]$e['version']
        $seen = $false
        foreach ($d in $distinct) { if ([string]::Equals([string]$d, $v, [System.StringComparison]::OrdinalIgnoreCase)) { $seen = $true } }
        if (-not $seen) { [void]$distinct.Add($v) }
    }
    # "New ZIP extracted over old install": payload markers already claim the target
    # release while the installer's env metadata still describes the source release.
    # Both engines' blind spot; setup CHECK refuses it fail-closed (audit Q7/I15).
    $targetVersion = $script:TargetVersionFallback
    if (-not [string]::IsNullOrEmpty([string]$script:TargetVersion)) { $targetVersion = [string]$script:TargetVersion }
    $sourceVersion = '1.0.0-rc.2'
    if (-not [string]::IsNullOrEmpty([string]$script:SourceVersion)) { $sourceVersion = [string]$script:SourceVersion }
    $versionFileValue = ''
    $manifestValue = ''
    $installStateValue = ''
    $runtimeValue = ''
    foreach ($e in $entries) {
        $src = [string]$e['source']
        if ($src -eq 'VERSION') { $versionFileValue = [string]$e['version'] }
        elseif ($src -eq 'manifest.json') { $manifestValue = [string]$e['version'] }
        elseif ($src -eq '_portable\install-state.json') { $installStateValue = [string]$e['version'] }
        elseif ($src -eq 'portable.runtime.json') { $runtimeValue = [string]$e['version'] }
    }
    $payloadLooksTarget = ($versionFileValue -ieq $targetVersion) -or ($manifestValue -ieq $targetVersion)
    $envLooksSource = ($installStateValue -ieq $sourceVersion) -or ($runtimeValue -ieq $sourceVersion)
    $extractedOverExisting = ($payloadLooksTarget -and $envLooksSource)
    $mismatch = ($distinct.Count -gt 1)
    return [ordered]@{
        entries              = [object[]]$entries.ToArray()
        distinct             = [object[]]$distinct.ToArray()
        mismatch             = $mismatch
        extractedOverExisting = $extractedOverExisting
        versionFile          = $versionFileValue
        manifestDistribution = $manifestValue
        installStateDistribution = $installStateValue
        runtimeDistribution  = $runtimeValue
    }
}

function Get-SetupTargetInfo {
    param([string]$TargetRoot, [string]$PackageRootPath)
    $info = [ordered]@{
        installRoot       = $TargetRoot
        exists            = (Test-SetupDirExists $TargetRoot)
        kind              = 'ABSENT'
        entryCount        = 0
        installed         = $false
        hasInstallState   = $false
        hasPortableDir    = $false
        hasVenv           = $false
        hasRuntimeFile    = $false
        hasManifest       = $false
        hasVersion        = $false
        hasBundle         = $false
        hasUpstream       = $false
        sameAsPackageRoot = $false
        installState      = $null
        versionMarkers    = $null
    }
    if (-not $info.exists) {
        $info.kind = 'ABSENT'
        return $info
    }
    $entries = @(Get-SetupDirectoryEntryPaths $TargetRoot)
    $info.entryCount = $entries.Count
    $info.hasInstallState = (Test-SetupFileExists (Join-SetupPath $TargetRoot '_portable\install-state.json'))
    $info.hasPortableDir = (Test-SetupDirExists (Join-SetupPath $TargetRoot '_portable'))
    $info.hasVenv = (Test-SetupDirExists (Join-SetupPath $TargetRoot '.venv'))
    $info.hasRuntimeFile = (Test-SetupFileExists (Join-SetupPath $TargetRoot 'bundle\cnki-research\portable.runtime.json'))
    $info.hasManifest = (Test-SetupFileExists (Join-SetupPath $TargetRoot 'manifest.json'))
    $info.hasVersion = (Test-SetupFileExists (Join-SetupPath $TargetRoot 'VERSION'))
    $info.hasBundle = (Test-SetupDirExists (Join-SetupPath $TargetRoot 'bundle\cnki-research'))
    $info.hasUpstream = (Test-SetupDirExists (Join-SetupPath $TargetRoot 'upstream\cnki-mcp'))
    $info.sameAsPackageRoot = (Test-SetupPathEqual $TargetRoot $PackageRootPath)
    # "Installed" = the installer wrote environment markers. A merely extracted
    # package tree (payload copied, no env dirs) is NOT an installation.
    $info.installed = ($info.hasInstallState -or $info.hasPortableDir -or $info.hasVenv -or $info.hasRuntimeFile)
    if ($info.installed) {
        $info.kind = 'INSTALLED'
        $info.installState = Read-SetupJsonFile (Join-SetupPath $TargetRoot '_portable\install-state.json')
        $info.versionMarkers = Get-SetupVersionMarkerReport -Root $TargetRoot
    } elseif ($info.entryCount -eq 0) {
        $info.kind = 'EMPTY'
    } elseif ($info.sameAsPackageRoot) {
        $info.kind = 'EXTRACTED_PACKAGE'
    } else {
        $info.kind = 'UNKNOWN_DIR'
    }
    return $info
}

function Invoke-SetupPackageIntegrity {
    # Engine package self-integrity (read-only). v2 accepts an optional -InstallRoot
    # for "self mode" (PackageRoot == InstallRoot); older engine libraries do not, so
    # the parameter is passed only when the loaded engine actually declares it.
    param($Checks, [string]$InstallRootHint = '')
    $pkgArgs = @{ PackageRoot = $script:PackageRootValue; Checks = $Checks }
    if (-not [string]::IsNullOrEmpty($InstallRootHint)) {
        $command = Get-Command -Name 'Get-PackageIntegrity' -ErrorAction SilentlyContinue
        if ($null -ne $command -and $command.Parameters.ContainsKey('InstallRoot')) {
            $pkgArgs['InstallRoot'] = $InstallRootHint
        }
    }
    return (Get-PackageIntegrity @pkgArgs)
}

function Get-SetupLatestInstallerBackup {
    # Read-only scan of <InstallRoot>\_portable\backups (newest first; ordinal).
    param([string]$TargetRoot)
    $result = [ordered]@{ found = $false; path = $null; backup = $null }
    $backupsRoot = Join-SetupPath $TargetRoot '_portable\backups'
    if (-not (Test-SetupDirExists $backupsRoot)) { return $result }
    $names = New-Object System.Collections.ArrayList
    try {
        foreach ($dir in [System.IO.Directory]::GetDirectories($backupsRoot)) {
            [void]$names.Add([System.IO.Path]::GetFileName($dir))
        }
    } catch { return $result }
    if ($names.Count -eq 0) { return $result }
    $arr = [object[]]$names.ToArray()
    if ($arr.Length -gt 1) { [System.Array]::Sort($arr, [System.StringComparer]::Ordinal) }
    for ($i = $arr.Length - 1; $i -ge 0; $i--) {
        $candidate = Join-SetupPath $backupsRoot ([string]$arr[$i])
        $backupJson = Join-SetupPath $candidate 'backup.json'
        if (-not (Test-SetupFileExists $backupJson)) { continue }
        $backup = Read-SetupJsonFile $backupJson
        if ($null -eq $backup) { continue }
        $result.found = $true
        $result.path = $candidate
        $result.backup = $backup
        return $result
    }
    return $result
}

# =====================================================================================
# Child process delegation to the frozen installer (portable.ps1)
# =====================================================================================

function Get-SetupPowerShellExe {
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($PSHOME)) { [void]$candidates.Add((Join-SetupPath $PSHOME 'powershell.exe')) }
    if (-not [string]::IsNullOrEmpty($env:SystemRoot)) {
        [void]$candidates.Add((Join-SetupPath $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    }
    foreach ($c in $candidates) { if (Test-SetupFileExists $c) { return [string]$c } }
    return 'powershell.exe'
}

function ConvertFrom-SetupChildJsonText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $start = $Text.IndexOf('{')
    if ($start -lt 0) { return $null }
    $end = $Text.LastIndexOf('}')
    if ($end -le $start) { return $null }
    $jsonText = $Text.Substring($start, ($end - $start + 1))
    try { return ($jsonText | ConvertFrom-Json) } catch { return $null }
}

function Invoke-SetupPortableChild {
    # Delegates one action to <PackageRoot>\tools\portable.ps1 as a child process.
    # -CaptureJson: run the child with -Json and capture its machine document
    #   (used for all read-only delegation and for -Json/-OutFile setup runs).
    # Without -CaptureJson the child inherits the console and its human report is
    #   streamed live (interactive install/uninstall/rollback).
    param([string]$PortableAction, [switch]$CaptureJson, [switch]$MutatingYes)
    $result = [ordered]@{
        action    = $PortableAction
        exitCode  = 1
        captured  = [bool]$CaptureJson
        rawText   = ''
        doc       = $null
        jsonParsed = $false
    }
    $exe = Get-SetupPowerShellExe
    $argList = New-Object System.Collections.ArrayList
    [void]$argList.Add('-NoProfile')
    [void]$argList.Add('-ExecutionPolicy')
    [void]$argList.Add('Bypass')
    [void]$argList.Add('-File')
    [void]$argList.Add($script:PortableScriptPath)
    [void]$argList.Add('-Action')
    [void]$argList.Add($PortableAction)
    [void]$argList.Add('-PackageRoot')
    [void]$argList.Add($script:PackageRootValue)
    [void]$argList.Add('-InstallRoot')
    [void]$argList.Add($script:InstallRootValue)
    if (-not [string]::IsNullOrEmpty([string]$script:Opt['DshHome'])) {
        [void]$argList.Add('-DshHome')
        [void]$argList.Add([string]$script:Opt['DshHome'])
    }
    [void]$argList.Add('-DshProfile')
    [void]$argList.Add([string]$script:Opt['DshProfile'])
    # Consent was already obtained by setup's own gate: always pass -Yes for mutating
    # delegations so the installer never re-prompts nor silently skips steps in -Json
    # mode (audit F-3). Read-only delegations never receive -Yes.
    if ($script:Opt['Yes'] -or $MutatingYes) { [void]$argList.Add('-Yes') }
    if ($script:Opt['Force'] -and $PortableAction -eq 'install') { [void]$argList.Add('-Force') }
    if ($script:Opt['AllowProductionProfile']) { [void]$argList.Add('-AllowProductionProfile') }
    if ($script:Opt['Offline']) { [void]$argList.Add('-Offline') }
    if ($script:Opt['NoToolInstall']) { [void]$argList.Add('-NoToolInstall') }
    if ($script:Opt['PurgeRuntime'] -and $PortableAction -eq 'uninstall') { [void]$argList.Add('-PurgeRuntime') }
    if ($CaptureJson) { [void]$argList.Add('-Json') }
    $argArray = [string[]]$argList.ToArray()
    # PS 5.1 turns native stderr into terminating errors when ErrorActionPreference is
    # Stop; the child may write progress to stderr. Relax it only around the call and
    # keep $LASTEXITCODE authoritative (audit R-01).
    $preferenceBefore = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($CaptureJson) {
            $lineList = New-Object System.Collections.ArrayList
            & $exe @argArray 2>&1 | ForEach-Object { [void]$lineList.Add([string]$_) }
            $result.exitCode = ConvertTo-SetupExitCode $LASTEXITCODE
            $result.rawText = ($lineList -join "`n")
            $childDoc = ConvertFrom-SetupChildJsonText $result.rawText
            if ($null -ne $childDoc) { $result.doc = $childDoc; $result.jsonParsed = $true }
        } else {
            & $exe @argArray
            $result.exitCode = ConvertTo-SetupExitCode $LASTEXITCODE
        }
    } catch {
        $result.rawText = 'child process invocation failed: ' + $_.Exception.Message
        $result.exitCode = 1
    } finally {
        $ErrorActionPreference = $preferenceBefore
    }
    return [pscustomobject]$result
}

function Get-SetupPortableChildChecks {
    param($ChildResult)
    if ($null -eq $ChildResult -or $null -eq $ChildResult.doc) { return @() }
    return @(Get-DocValue $ChildResult.doc 'checks')
}

function Get-SetupPortableChildOutcome {
    param($ChildResult, [string]$Fallback)
    if ($null -eq $ChildResult -or $null -eq $ChildResult.doc) { return $Fallback }
    $outcome = [string](Get-DocValue $ChildResult.doc 'outcome')
    if ([string]::IsNullOrEmpty($outcome)) { return $Fallback }
    return $outcome
}

function Get-SetupPortableChildSummary {
    param($ChildResult)
    if ($null -eq $ChildResult -or $null -eq $ChildResult.doc) { return $null }
    return (Get-DocValue $ChildResult.doc 'summary')
}

function New-SetupPortableEvidence {
    param($ChildResult)
    if ($null -eq $ChildResult) { return $null }
    if ($null -ne $ChildResult.doc) {
        return [ordered]@{
            action     = [string](Get-DocValue $ChildResult.doc 'action')
            outcome    = [string](Get-DocValue $ChildResult.doc 'outcome')
            exitCode   = [int]$ChildResult.exitCode
            jsonParsed = $true
            doc        = $ChildResult.doc
        }
    }
    return [ordered]@{
        action     = [string]$ChildResult.action
        outcome    = $null
        exitCode   = [int]$ChildResult.exitCode
        jsonParsed = $false
        rawOutput  = [string]$ChildResult.rawText
    }
}

# =====================================================================================
# Install-plan self-computation (read-only; charter + audit F-1)
# =====================================================================================

function New-SetupInstallPlanData {
    param($TargetInfo, $ChildCheckResult)
    $layoutMode = 'A_IN_PLACE'
    if (-not [string]::IsNullOrEmpty($script:InstallRootValue) -and -not (Test-SetupPathEqual $script:InstallRootValue $script:PackageRootValue)) {
        $layoutMode = 'B_SEPARATE_ROOT'
    }
    $steps = New-Object System.Collections.ArrayList
    [void]$steps.Add('1. 只读校验安装包完整性（manifest.json；存在时含 SHA256SUMS.txt 闭包），不写任何文件。')
    [void]$steps.Add('2. 只读检查宿主机环境：DSH 安装/版本、Python、uv、Playwright Chromium、profile 状态（由 tools\portable.ps1 -Action check 提供）。')
    if ($layoutMode -eq 'A_IN_PLACE') {
        [void]$steps.Add('3. Layout A（解压即安装）：向 <InstallRoot> 部署发行载荷（InstallRoot = PackageRoot）。')
    } else {
        [void]$steps.Add('3. Layout B（独立安装根）：把发行载荷复制到 <InstallRoot>，包根保持不变。')
    }
    [void]$steps.Add('4. 创建/复用 .venv 并安装 cnki-mcp 运行时依赖（uv；断网时使用缓存，或显式加 -Offline）。')
    [void]$steps.Add('5. 初始化/校验 DSH profile 并注册插件（link 模式创建 node_modules junction）。')
    [void]$steps.Add('6. 写入 _portable\install-state.json 与 bundle\cnki-research\portable.runtime.json（环境元数据）。')
    [void]$steps.Add('7. 用 -Action status / -Action verify 验收；DSH 运行期激活需用户真实会话，标注 NOT TESTED。')
    $envNotes = New-Object System.Collections.ArrayList
    $childChecks = @(Get-SetupPortableChildChecks $ChildCheckResult)
    foreach ($c in $childChecks) {
        $id = [string](Get-DocValue $c 'id')
        $status = [string](Get-DocValue $c 'status')
        $detail = [string](Get-DocValue $c 'detail')
        if ($status -eq 'WARN') { [void]$envNotes.Add(('[' + $id + '] ' + $detail)) }
    }
    $actionable = $true
    if ($null -eq $ChildCheckResult) { $actionable = $false }
    elseif ([int]$ChildCheckResult.exitCode -ne 0) { $actionable = $false }
    return [ordered]@{
        actionable    = $actionable
        noOp          = $false
        installPlan   = $true
        layoutMode    = $layoutMode
        targetVersion = Get-SetupTargetVersion
        packageRoot   = $script:PackageRootValue
        installRoot   = $script:InstallRootValue
        steps         = [object[]]$steps.ToArray()
        environmentNotes = [object[]]$envNotes.ToArray()
    }
}

function New-SetupInstallPreviewDocument {
    param([string]$ActionName, [string]$OutcomePrefix, $GateChecks)
    $checks = New-SetupCheckList
    foreach ($c in @($GateChecks)) { if ($null -ne $c) { [void]$checks.Add($c) } }
    $childCheck = Invoke-SetupPortableChild -PortableAction 'check' -CaptureJson
    $planData = New-SetupInstallPlanData -TargetInfo $script:TargetInfo -ChildCheckResult $childCheck
    $doc = New-SetupActionDocument -ActionName $ActionName
    Set-DocValue $doc 'route' 'setup'
    Set-DocValue $doc 'sourceState' ([string]$script:TargetInfo.kind)
    Set-DocValue $doc 'dryRun' $true
    Set-DocValue $doc 'plan' $planData
    Set-DocValue $doc 'portableCheck' (New-SetupPortableEvidence $childCheck)
    Add-SetupCheck $checks 'setup.planMode' 'PASS' 'install plan is self-computed by setup.ps1 (read-only); the legacy portable plan path is not invoked'
    foreach ($c in @(Get-SetupPortableChildChecks $childCheck)) { [void]$checks.Add($c) }
    $exitCode = ConvertTo-SetupExitCode $childCheck.exitCode
    $outcome = $OutcomePrefix + '_PLAN_READY'
    $refused = $false
    if ($exitCode -ne 0) {
        $outcome = $OutcomePrefix + '_PLAN_BLOCKED'
        $refused = $true
        if ($exitCode -eq 1) { $exitCode = 2 }
    }
    $errors = @()
    if ($refused) { $errors = @('INSTALL_PRECHECK_FAILED') }
    [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode $exitCode -Outcome $outcome -Refused $refused -Errors $errors)
    return $doc
}

# =====================================================================================
# Environment gates for delegated mutating actions (production home / DSH in use /
# install-root path safety), and read-only postconditions (audit O-4/O-5, R-13/R-14,
# §11.7). None of these write anything.
# =====================================================================================

function Get-SetupProductionDshHome {
    $command = Get-Command -Name 'Get-ProductionDshHome' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        try { return (Get-ProductionDshHome) } catch { }
    }
    if (-not [string]::IsNullOrEmpty($env:DSH_HOME)) { return (Get-SetupNormalizedPath $env:DSH_HOME) }
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) { return (Get-SetupNormalizedPath (Join-SetupPath $env:USERPROFILE '.dsh')) }
    return $null
}

function Get-SetupMutationDshHome {
    $explicit = [string]$script:Opt['DshHome']
    if (-not [string]::IsNullOrEmpty($explicit)) {
        $normalized = Get-SetupNormalizedPath $explicit
        if ($null -ne $normalized) { return $normalized }
    }
    return (Get-SetupProductionDshHome)
}

function Get-SetupDshProcesses {
    $command = Get-Command -Name 'Get-DshProcessTable' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        try { return @(Get-DshProcessTable) } catch { return @() }
    }
    $result = New-Object System.Collections.ArrayList
    try { $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { return @() }
    foreach ($p in $procs) {
        $name = [string]$p.Name
        $isHost = $false
        if ($name -match '(?i)^(DeepSeek[ _-]?Harness|deepseek-harness|dsh|dsh-host)(\.exe|\.cmd)?$') { $isHost = $true }
        elseif ($name -match '(?i)^(node|nodejs)\.exe$') {
            if ([string]$p.CommandLine -match '(?i)deepseek|dsh') { $isHost = $true }
        }
        if ($isHost) { [void]$result.Add([ordered]@{ pid = [int]$p.ProcessId; name = $name }) }
    }
    return $result.ToArray()
}

function Test-SetupProductionTarget {
    param([string]$DshHome)
    # NOTE: PowerShell variables are case-insensitive and $HOME is read-only
    # automatic; never name a local $home.
    $homePath = $DshHome
    if ([string]::IsNullOrEmpty($homePath)) { $homePath = Get-SetupMutationDshHome }
    if ([string]::IsNullOrEmpty($homePath)) { return $false }
    $production = Get-SetupProductionDshHome
    if (-not [string]::IsNullOrEmpty($production) -and (Test-SetupPathEqual $homePath $production)) { return $true }
    foreach ($sub in @('sessions', 'storages')) {
        $p = Join-SetupPath $homePath $sub
        if (-not (Test-SetupDirExists $p)) { continue }
        $entries = @(Get-SetupDirectoryEntryPaths $p)
        if ($entries.Count -gt 0) { return $true }
    }
    return $false
}

function Get-SetupProfileDirPath {
    param([string]$DshHome, [string]$DshProfile)
    if ([string]::IsNullOrEmpty($DshHome)) { return $null }
    $profile = $DshProfile
    if ([string]::IsNullOrEmpty($profile)) { $profile = 'desktop' }
    return (Join-SetupPath $DshHome ('profiles\' + $profile))
}

function Get-SetupProfileBundleDependency {
    param([string]$ProfileDir)
    if ([string]::IsNullOrEmpty($ProfileDir)) { return '' }
    $packageJson = Read-SetupJsonFile (Join-SetupPath $ProfileDir 'package.json')
    if ($null -eq $packageJson) { return '' }
    $dependencies = Get-DocValue $packageJson 'dependencies'
    if ($null -eq $dependencies) { return '' }
    return [string](Get-DocValue $dependencies '@local/dsh-cnki-research')
}

function Get-SetupInstallRootSafetyReasons {
    param([string]$InstallRoot, [string]$PackageRoot)
    $reasons = New-Object System.Collections.ArrayList
    $command = Get-Command -Name 'Test-InstallRootPathSafety' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        try {
            foreach ($r in @(Test-InstallRootPathSafety -InstallRoot $InstallRoot -PackageRoot $PackageRoot)) {
                if (-not [string]::IsNullOrEmpty([string]$r)) { [void]$reasons.Add([string]$r) }
            }
            return $reasons.ToArray()
        } catch {
            return $reasons.ToArray()
        }
    }
    $root = Get-SetupNormalizedPath $InstallRoot
    if ($null -eq $root) { [void]$reasons.Add('INSTALL_ROOT_INVALID'); return $reasons.ToArray() }
    if ($root -match '^[A-Za-z]:\\$') { [void]$reasons.Add('INSTALL_ROOT_IS_DRIVE_ROOT') }
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE) -and (Test-SetupPathEqual $root $env:USERPROFILE)) {
        [void]$reasons.Add('INSTALL_ROOT_IS_USERPROFILE')
    }
    $production = Get-SetupProductionDshHome
    if (-not [string]::IsNullOrEmpty($production) -and ((Test-SetupPathEqual $root $production) -or (Test-SetupPathUnder $root $production))) {
        [void]$reasons.Add('INSTALL_ROOT_INSIDE_PRODUCTION_DSH_HOME')
    }
    foreach ($name in @('WINDIR', 'SystemRoot', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432')) {
        $v = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($v) -and (Test-SetupPathEqual $root $v)) { [void]$reasons.Add('INSTALL_ROOT_FORBIDDEN_LOCATION') }
    }
    return $reasons.ToArray()
}

function Add-SetupMutationEnvironmentGates {
    param($Checks, [string]$ActionLabel)
    $gates = [ordered]@{ blocked = $false; errors = @() }
    $errorList = New-Object System.Collections.ArrayList
    $safety = @(Get-SetupInstallRootSafetyReasons -InstallRoot $script:InstallRootValue -PackageRoot '')
    if ($safety.Count -gt 0) {
        Add-SetupCheck $Checks 'setup.gate.installRoot' 'FAIL' ('INSTALL_ROOT_UNSAFE: ' + ($safety -join '; '))
        $gates.blocked = $true
        [void]$errorList.Add('INSTALL_ROOT_UNSAFE')
    } else {
        Add-SetupCheck $Checks 'setup.gate.installRoot' 'PASS' ('install root is not a system/user/production location: ' + $script:InstallRootValue)
    }
    $dshHome = Get-SetupMutationDshHome
    $isProduction = Test-SetupProductionTarget -DshHome $dshHome
    if ($isProduction -and -not $script:Opt['AllowProductionProfile']) {
        Add-SetupCheck $Checks 'setup.gate.production' 'FAIL' ('PRODUCTION_GATE: ' + $ActionLabel + ' targets a live-production DSH home (' + [string]$dshHome + '). Re-run with -AllowProductionProfile if this is intended; user data is never modified silently.')
        $gates.blocked = $true
        [void]$errorList.Add('PRODUCTION_GATE')
    } elseif ($isProduction) {
        Add-SetupCheck $Checks 'setup.gate.production' 'WARN' 'PRODUCTION_GATE: -AllowProductionProfile supplied; the action will modify the live DSH home'
    } else {
        Add-SetupCheck $Checks 'setup.gate.production' 'PASS' ('target DSH home is not the live production home: ' + [string]$dshHome)
    }
    $dshProcesses = @(Get-SetupDshProcesses)
    $dshRunning = ($dshProcesses.Count -gt 0)
    if ($dshRunning -and $isProduction) {
        Add-SetupCheck $Checks 'setup.gate.dshRunning' 'FAIL' 'DSH_IN_USE: a DSH host process is running while the target is the live production home. Close DSH normally (do not force-kill), then re-run from a separate PowerShell window.'
        $gates.blocked = $true
        [void]$errorList.Add('DSH_IN_USE')
    } elseif ($dshRunning) {
        Add-SetupCheck $Checks 'setup.gate.dshRunning' 'WARN' ('DSH is running, but the target DSH home is isolated (' + [string]$dshHome + '); continuing without touching the production profile.')
    } else {
        Add-SetupCheck $Checks 'setup.gate.dshRunning' 'PASS' 'no DSH host process detected (read-only CIM probe)'
    }
    $gates.errors = $errorList.ToArray()
    return [pscustomobject]$gates
}

function ConvertTo-SetupDelegatedExit {
    # The frozen installer uses child exit 1 for both internal errors and its own
    # REFUSED gate throws; map refusal-like messages to setup exit 2 (audit §6.5).
    param($ChildResult, [string]$FallbackError)
    if ($null -eq $ChildResult) { return 1 }
    $code = ConvertTo-SetupExitCode $ChildResult.exitCode
    if ($code -ne 1) { return $code }
    $text = [string]$ChildResult.rawText
    if ($null -ne $ChildResult.doc) {
        $docError = Get-DocValue $ChildResult.doc 'error'
        if (-not [string]::IsNullOrEmpty([string]$docError)) { $text = $text + ' ' + [string]$docError }
    }
    if (-not [string]::IsNullOrEmpty($FallbackError)) { $text = $text + ' ' + $FallbackError }
    if ($text -match '(?i)REFUSED|PRODUCTION|拒绝|permission|ACCESS_DENIED') { return 2 }
    return 1
}

function Get-SetupBundleDirPath {
    return (Join-SetupPath $script:InstallRootValue 'bundle\cnki-research')
}

function Add-SetupInstallPostChecks {
    # Read-only postconditions after a delegated install (audit §11.7, F-3 guard).
    param($Checks)
    $failed = $false
    $stateFile = Join-SetupPath $script:InstallRootValue '_portable\install-state.json'
    $state = Read-SetupJsonFile $stateFile
    if ($null -eq $state) {
        Add-SetupCheck $Checks 'setup.post.installState' 'FAIL' ('install-state.json missing or unparseable after install: ' + $stateFile)
        return $true
    }
    Add-SetupCheck $Checks 'setup.post.installState' 'PASS' ('install-state.json written: ' + $stateFile)
    $expectedDistribution = [string]$script:PackageInfo.manifestDistribution
    $actualDistribution = [string](Get-DocValue $state 'distribution')
    if (-not [string]::IsNullOrEmpty($expectedDistribution) -and $actualDistribution -ieq $expectedDistribution) {
        Add-SetupCheck $Checks 'setup.post.installDistribution' 'PASS' ('installed distribution equals package distribution (' + $actualDistribution + ')')
    } else {
        Add-SetupCheck $Checks 'setup.post.installDistribution' 'FAIL' ('installed distribution ''' + $actualDistribution + ''' != package distribution ''' + $expectedDistribution + '''')
        $failed = $true
    }
    $verified = Get-DocValue $state 'verified'
    $profileDependency = $false
    if ($null -ne $verified) { $profileDependency = [bool](Get-DocValue $verified 'profileDependency') }
    if ($profileDependency) {
        Add-SetupCheck $Checks 'setup.post.profileDependency' 'PASS' 'installer verified that the DSH profile resolves the bundle'
    } else {
        Add-SetupCheck $Checks 'setup.post.profileDependency' 'FAIL' 'the DSH profile does not resolve the bundle after install (profile registration did not complete)'
        $failed = $true
    }
    $runtimeFile = Join-SetupPath $script:InstallRootValue 'bundle\cnki-research\portable.runtime.json'
    $runtime = Read-SetupJsonFile $runtimeFile
    if ($null -ne $runtime) {
        $runtimeDistribution = [string](Get-DocValue $runtime 'distribution')
        if ([string]::IsNullOrEmpty($expectedDistribution) -or $runtimeDistribution -ieq $expectedDistribution) {
            Add-SetupCheck $Checks 'setup.post.runtimeDescriptor' 'PASS' ('portable.runtime.json distribution = ' + $runtimeDistribution)
        } else {
            Add-SetupCheck $Checks 'setup.post.runtimeDescriptor' 'FAIL' ('portable.runtime.json distribution ''' + $runtimeDistribution + ''' != package distribution ''' + $expectedDistribution + '''')
            $failed = $true
        }
    } else {
        Add-SetupCheck $Checks 'setup.post.runtimeDescriptor' 'FAIL' ('portable.runtime.json missing after install: ' + $runtimeFile)
        $failed = $true
    }
    $dshHome = Get-SetupMutationDshHome
    $profileDir = Get-SetupProfileDirPath -DshHome $dshHome -DshProfile ([string]$script:Opt['DshProfile'])
    $dependency = Get-SetupProfileBundleDependency -ProfileDir $profileDir
    $expectedLink = 'link:' + (Get-SetupBundleDirPath)
    $expectedFile = 'file:' + (Get-SetupBundleDirPath)
    if ($dependency -ieq $expectedLink -or $dependency -ieq $expectedFile) {
        Add-SetupCheck $Checks 'setup.post.profileDependencyValue' 'PASS' ('profile dependency restored: ' + $dependency)
    } else {
        Add-SetupCheck $Checks 'setup.post.profileDependencyValue' 'FAIL' ('profile dependency is ''' + $dependency + ''', expected ''' + $expectedLink + '''')
        $failed = $true
    }
    return $failed
}

function Add-SetupUninstallPostChecks {
    param($Checks)
    $failed = $false
    $stateFile = Join-SetupPath $script:InstallRootValue '_portable\install-state.json'
    if (Test-SetupFileExists $stateFile) {
        Add-SetupCheck $Checks 'setup.post.installStateRemoved' 'FAIL' ('install-state.json still exists after uninstall: ' + $stateFile)
        $failed = $true
    } else {
        Add-SetupCheck $Checks 'setup.post.installStateRemoved' 'PASS' 'install-state.json removed'
    }
    $runtimeFile = Join-SetupPath $script:InstallRootValue 'bundle\cnki-research\portable.runtime.json'
    if (Test-SetupFileExists $runtimeFile) {
        Add-SetupCheck $Checks 'setup.post.runtimeRemoved' 'FAIL' ('portable.runtime.json still exists after uninstall: ' + $runtimeFile)
        $failed = $true
    } else {
        Add-SetupCheck $Checks 'setup.post.runtimeRemoved' 'PASS' 'portable.runtime.json removed'
    }
    $dshHome = Get-SetupMutationDshHome
    $profileDir = Get-SetupProfileDirPath -DshHome $dshHome -DshProfile ([string]$script:Opt['DshProfile'])
    $dependency = Get-SetupProfileBundleDependency -ProfileDir $profileDir
    if ([string]::IsNullOrEmpty($dependency)) {
        Add-SetupCheck $Checks 'setup.post.profileDependencyRemoved' 'PASS' 'the DSH profile no longer declares the bundle'
    } else {
        Add-SetupCheck $Checks 'setup.post.profileDependencyRemoved' 'WARN' ('profile still declares dependency ''' + $dependency + ''' (foreign link target may be left in place by design)')
    }
    return $failed
}

function Add-SetupRollbackPostChecks {
    param($Checks)
    $dshHome = Get-SetupMutationDshHome
    $profileDir = Get-SetupProfileDirPath -DshHome $dshHome -DshProfile ([string]$script:Opt['DshProfile'])
    $dependency = Get-SetupProfileBundleDependency -ProfileDir $profileDir
    $expectedLink = 'link:' + (Get-SetupBundleDirPath)
    $expectedFile = 'file:' + (Get-SetupBundleDirPath)
    if ($dependency -ieq $expectedLink -or $dependency -ieq $expectedFile) {
        Add-SetupCheck $Checks 'setup.post.profileDependencyRestored' 'PASS' ('profile dependency restored: ' + $dependency)
        return $false
    }
    Add-SetupCheck $Checks 'setup.post.profileDependencyRestored' 'FAIL' ('profile dependency is ''' + $dependency + ''', expected ''' + $expectedLink + '''')
    return $true
}

# =====================================================================================
# Consent gate (setup's own, never relies on the child's consent logic)
# =====================================================================================

function Test-SetupConsent {
    # Returns $true when the mutation may proceed. Refusal is recorded by the caller.
    param([string]$What)
    if ($script:Opt['Yes']) { return $true }
    if ($script:Opt['DryRun']) { return $true }
    if ($script:MachineMode) { return $false }
    try {
        $answer = Read-Host ('确认执行 ' + $What + '（输入 y 继续，其他取消） / type y to continue')
        return ($answer -match '^(?i)y(es)?$')
    } catch {
        return $false
    }
}

# =====================================================================================
# Action: check (read-only)
# =====================================================================================

function Get-SetupMarkerProblemDetail {
    # Turns the read-only version-marker report into a failure id/token/detail.
    param($Markers)
    $parts = New-Object System.Collections.ArrayList
    foreach ($e in @($Markers.entries)) { [void]$parts.Add(([string]$e['source'] + '=' + [string]$e['version'])) }
    $text = ($parts -join '; ')
    if ([bool]$Markers.extractedOverExisting) {
        return [ordered]@{
            id     = 'setup.extractedOverExisting'
            token  = 'EXTRACTED_OVER_INSTALL'
            detail = ('EXTRACTED_OVER_EXISTING: payload markers already claim 1.0.0-rc.3 while the installer metadata still says 1.0.0-rc.2 (' + $text + '). A new ZIP was extracted over an existing installation; this is refused fail-closed. Re-extract the package into an EMPTY directory and upgrade with -Action upgrade -InstallRoot <old install>.')
        }
    }
    return [ordered]@{
        id     = 'setup.versionMarkers'
        token  = 'MIXED_VERSION_MARKERS'
        detail = ('MIXED_VERSION_MARKERS: version markers disagree (' + $text + '); the tree is in an UNKNOWN/mixed state and was refused fail-closed.')
    }
}

function Invoke-SetupActionCheck {
    $checks = New-SetupCheckList
    Add-SetupCheck $checks 'setup.packageRoot' 'PASS' ('package root: ' + $script:PackageRootValue)
    if (-not $script:PackageInfo.hasManifest) {
        Add-SetupCheck $checks 'package.manifest' 'FAIL' ('manifest.json not found at package root: ' + $script:PackageRootValue)
    } else {
        Add-SetupCheck $checks 'package.manifest' 'PASS' ('manifest.json found (distribution ' + [string]$script:PackageInfo.manifestDistribution + ')')
    }
    if (-not $script:PackageInfo.hasSums) {
        Add-SetupCheck $checks 'package.sumsFile' 'FAIL' ('SHA256SUMS.txt not found at package root: ' + $script:PackageRootValue)
        $doc = New-SetupActionDocument -ActionName 'check'
        Set-DocValue $doc 'route' 'setup'
        Set-DocValue $doc 'sourceState' 'PACKAGE_INVALID'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'PACKAGE_INVALID' -Refused $true -Errors @('PACKAGE_INTEGRITY_FILES_MISSING'))
        return $doc
    }
    $target = $script:TargetInfo
    if ($target.kind -eq 'ABSENT' -or $target.kind -eq 'EMPTY' -or $target.kind -eq 'EXTRACTED_PACKAGE') {
        $detail = 'not installed (' + [string]$target.kind + '): no installation markers at ' + $script:InstallRootValue
        Add-SetupCheck $checks 'setup.targetState' 'PASS' ('NOT_INSTALLED: ' + $detail)
        $pkgResult = $null
        $integrityHint = ''
        if ($target.sameAsPackageRoot) { $integrityHint = $script:InstallRootValue }
        try { $pkgResult = Invoke-SetupPackageIntegrity -Checks $checks -InstallRootHint $integrityHint } catch {
            Add-SetupCheck $checks 'setup.packageIntegrity' 'FAIL' ('package integrity inspection failed: ' + $_.Exception.Message)
        }
        $packageValid = $false
        if ($null -ne $pkgResult) { $packageValid = [bool](Get-DocValue $pkgResult 'valid') }
        if ($packageValid) {
            Add-SetupCheck $checks 'setup.recommendation' 'PASS' ('RUN_INSTALL: run -Action install -InstallRoot "' + $script:InstallRootValue + '" -Yes')
        } else {
            Add-SetupCheck $checks 'setup.recommendation' 'FAIL' 'package self-integrity failed; repair/re-download the package before installing'
        }
        $doc = New-SetupActionDocument -ActionName 'check'
        Set-DocValue $doc 'route' 'setup'
        Set-DocValue $doc 'sourceState' 'NOT_INSTALLED'
        Set-DocValue $doc 'variant' $null
        $exitCode = 0
        $errors = @()
        if (-not $packageValid) { $exitCode = 2; $errors = @('PACKAGE_INTEGRITY_FAILED') }
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode $exitCode -Outcome 'NOT_INSTALLED' -Refused (-not $packageValid) -Errors $errors)
        return $doc
    }
    if ($target.kind -eq 'UNKNOWN_DIR') {
        Add-SetupCheck $checks 'setup.targetState' 'FAIL' ('TARGET_NOT_AN_INSTALLATION: ' + $script:InstallRootValue + ' is not empty but has no installer markers and is not the package root; refusing to treat it as an installation')
        Add-SetupCheck $checks 'setup.recommendation' 'FAIL' 're-extract the package into an empty directory, or point -InstallRoot at the existing installation root'
        $doc = New-SetupActionDocument -ActionName 'check'
        Set-DocValue $doc 'route' 'setup'
        Set-DocValue $doc 'sourceState' 'UNKNOWN_OR_MODIFIED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'UNKNOWN_OR_MODIFIED' -Refused $true -Errors @('TARGET_NOT_AN_INSTALLATION'))
        return $doc
    }
    # Installed target: engine CHECK (package integrity + full target-state detection).
    $result = Invoke-SetupEngineAction -EngineAction 'check'
    $doc = ConvertTo-SetupEngineDocument -EngineDoc $result.doc -ActionName 'check'
    Set-DocValue $doc 'route' 'engine'
    $extra = New-SetupCheckList
    Add-SetupCheck $extra 'setup.packageRoot' 'PASS' ('package root: ' + $script:PackageRootValue)
    $markerToken = ''
    if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
        $markerProblem = Get-SetupMarkerProblemDetail $target.versionMarkers
        Add-SetupCheck $extra ([string]$markerProblem.id) 'FAIL' ([string]$markerProblem.detail)
        $markerToken = [string]$markerProblem.token
    } elseif ($target.sameAsPackageRoot) {
        # Legitimate in-place installation (extracted + installed in the same folder):
        # read-only self-mode is allowed; package sealing is relaxed by the engine and
        # this check is advisory only.
        Add-SetupCheck $extra 'setup.selfModeInPlace' 'WARN' 'SELF_MODE_IN_PLACE_PACKAGE_ROOT: PackageRoot == InstallRoot with consistent version markers (legitimate in-place installation). Read-only self-mode is allowed; -Action install/upgrade from an in-place tree is still refused (no separate package/target).'
    }
    $doc = Add-SetupExtraChecks -Doc $doc -ExtraChecks $extra -FailOutcome 'UNKNOWN_OR_MODIFIED' -FailErrors @($markerToken)
    return $doc
}

# =====================================================================================
# Action: plan (read-only)
# =====================================================================================

function Invoke-SetupActionPlan {
    $target = $script:TargetInfo
    if ($target.kind -eq 'ABSENT' -or $target.kind -eq 'EMPTY' -or $target.kind -eq 'EXTRACTED_PACKAGE') {
        return (New-SetupFreshInstallPlanDocument -ActionName 'plan')
    }
    if ($target.kind -eq 'UNKNOWN_DIR') {
        $checks = New-SetupCheckList
        Add-SetupCheck $checks 'setup.targetState' 'FAIL' ('TARGET_NOT_AN_INSTALLATION: ' + $script:InstallRootValue)
        Add-SetupCheck $checks 'setup.recommendation' 'FAIL' 're-extract the package into an empty directory, or point -InstallRoot at the existing installation root'
        $doc = New-SetupActionDocument -ActionName 'plan'
        Set-DocValue $doc 'route' 'setup'
        Set-DocValue $doc 'sourceState' 'UNKNOWN_OR_MODIFIED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'UNKNOWN_OR_MODIFIED' -Refused $true -Errors @('TARGET_NOT_AN_INSTALLATION'))
        return $doc
    }
    $result = Invoke-SetupEngineAction -EngineAction 'plan'
    $doc = ConvertTo-SetupEngineDocument -EngineDoc $result.doc -ActionName 'plan'
    Set-DocValue $doc 'route' 'engine'
    $extra = New-SetupCheckList
    $markerToken = ''
    if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
        $markerProblem = Get-SetupMarkerProblemDetail $target.versionMarkers
        Add-SetupCheck $extra ([string]$markerProblem.id) 'FAIL' ([string]$markerProblem.detail)
        $markerToken = [string]$markerProblem.token
    } elseif ($target.sameAsPackageRoot) {
        Add-SetupCheck $extra 'setup.selfModeInPlace' 'WARN' 'SELF_MODE_IN_PLACE_PACKAGE_ROOT: legitimate in-place installation (consistent version markers); planning is read-only. -Action install/upgrade from this in-place tree is still refused.'
    }
    if ([int]$result.exitCode -eq 0) {
        $state = [string](Get-DocValue $doc 'sourceState')
        if ($state -eq 'RC2_CLEAN' -or $state -eq 'RC2_HOTFIXED') {
            Add-SetupCheck $extra 'setup.planReady' 'PASS' ('planId=' + [string](Get-DocValue $doc 'planId') + '; approve with -Action upgrade -InstallRoot "' + $script:InstallRootValue + '" -PlanId <planId> -Yes')
        } elseif ($state -eq 'RC3_ALREADY_INSTALLED') {
            Add-SetupCheck $extra 'setup.noop' 'PASS' 'already at target (1.0.0-rc.3): no upgrade plan is needed'
        }
    }
    $doc = Add-SetupExtraChecks -Doc $doc -ExtraChecks $extra -FailOutcome 'UNKNOWN_OR_MODIFIED' -FailErrors @($markerToken)
    return $doc
}

# =====================================================================================
# Fresh-install plan (self-computed; read-only portable CHECK for environment data)
# =====================================================================================

function New-SetupFreshInstallPlanDocument {
    param([string]$ActionName)
    $checks = New-SetupCheckList
    if (-not $script:PackageInfo.hasManifest) {
        Add-SetupCheck $checks 'package.manifest' 'FAIL' ('manifest.json not found at package root: ' + $script:PackageRootValue)
        $doc = New-SetupActionDocument -ActionName $ActionName
        Set-DocValue $doc 'route' 'setup'
        Set-DocValue $doc 'sourceState' 'PACKAGE_INVALID'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'PACKAGE_INVALID' -Refused $true -Errors @('PACKAGE_INTEGRITY_FILES_MISSING'))
        return $doc
    }
    Add-SetupCheck $checks 'setup.targetState' 'PASS' ('NOT_INSTALLED (' + [string]$script:TargetInfo.kind + '): fresh install plan')
    Add-SetupCheck $checks 'setup.planMode' 'PASS' 'fresh-install plan is self-computed by setup.ps1 (read-only); no installer backup/write is created'
    $childCheck = Invoke-SetupPortableChild -PortableAction 'check' -CaptureJson
    $planData = New-SetupInstallPlanData -TargetInfo $script:TargetInfo -ChildCheckResult $childCheck
    $doc = New-SetupActionDocument -ActionName $ActionName
    Set-DocValue $doc 'route' 'setup'
    Set-DocValue $doc 'sourceState' 'NOT_INSTALLED'
    Set-DocValue $doc 'plan' $planData
    Set-DocValue $doc 'portableCheck' (New-SetupPortableEvidence $childCheck)
    foreach ($c in @(Get-SetupPortableChildChecks $childCheck)) { [void]$checks.Add($c) }
    $exitCode = ConvertTo-SetupExitCode $childCheck.exitCode
    $outcome = 'INSTALL_PLAN_READY'
    $refused = $false
    $errors = @()
    if ($exitCode -ne 0) {
        $outcome = 'INSTALL_PLAN_BLOCKED'
        $refused = $true
        if ($exitCode -eq 1) { $exitCode = 2 }
        $errors = @('INSTALL_PRECHECK_FAILED')
    }
    [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode $exitCode -Outcome $outcome -Refused $refused -Errors $errors)
    return $doc
}

# =====================================================================================
# Action: install (delegates to portable.ps1; setup gates on its own CHECK)
# =====================================================================================

function Invoke-SetupActionInstall {
    $target = $script:TargetInfo
    $gates = New-SetupCheckList
    $fatal = $false
    $fatalOutcome = 'REFUSED'
    $fatalErrors = @()
    if (-not $script:PackageInfo.hasManifest) {
        Add-SetupCheck $gates 'package.manifest' 'FAIL' ('manifest.json not found at package root: ' + $script:PackageRootValue)
        $fatal = $true; $fatalOutcome = 'PACKAGE_INVALID'; $fatalErrors = @('PACKAGE_INTEGRITY_FILES_MISSING')
    }
    if (-not $script:PackageInfo.hasPortable) {
        Add-SetupCheck $gates 'package.portableInstaller' 'FAIL' ('tools\portable.ps1 not found under package root: ' + $script:PackageRootValue)
        $fatal = $true; $fatalOutcome = 'PACKAGE_INVALID'; $fatalErrors = @('PACKAGE_CORRUPT: portable installer missing')
    }
    if ($target.sameAsPackageRoot -and $target.installed) {
        Add-SetupCheck $gates 'setup.extractionOverInstall' 'FAIL' 'PACKAGE_ROOT_EQUALS_INSTALL_ROOT: never unzip a new release over an existing installation; re-extract to an empty directory'
        $fatal = $true; $fatalOutcome = 'REFUSED'; $fatalErrors = @('PACKAGE_ROOT_EQUALS_INSTALL_ROOT')
    }
    if ($target.kind -eq 'INSTALLED' -and -not $script:Opt['Force']) {
        Add-SetupCheck $gates 'setup.alreadyInstalled' 'FAIL' ('ALREADY_INSTALLED: ' + $script:InstallRootValue + ' already contains an installation. Use -Action upgrade for a safe incremental upgrade of RC2, or -Force to reinstall (LEGACY reinstall-over-existing behaviour).')
        $fatal = $true; $fatalOutcome = 'REFUSED'; $fatalErrors = @('ALREADY_INSTALLED')
    } elseif ($target.kind -eq 'INSTALLED') {
        Add-SetupCheck $gates 'setup.forceReinstall' 'WARN' 'FORCE_REINSTALL: existing installation will be reinstalled over (LEGACY reinstall-over-existing); a backup is still taken by the installer'
    }
    if ($target.kind -eq 'UNKNOWN_DIR' -and -not $script:Opt['Force']) {
        Add-SetupCheck $gates 'setup.targetState' 'FAIL' ('TARGET_NOT_INSTALLABLE: ' + $script:InstallRootValue + ' is not empty but has no installer markers; refusing without -Force')
        $fatal = $true; $fatalOutcome = 'REFUSED'; $fatalErrors = @('TARGET_NOT_INSTALLABLE')
    } elseif ($target.kind -eq 'UNKNOWN_DIR') {
        Add-SetupCheck $gates 'setup.forceReinstall' 'WARN' 'FORCE: installing into a non-empty non-installation directory (LEGACY force behaviour)'
    }
    if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
        $extractedOver = [bool]$target.versionMarkers.extractedOverExisting
        if ($script:Opt['Force']) {
            Add-SetupCheck $gates 'setup.versionMarkers' 'WARN' 'MIXED_VERSION_MARKERS: version markers disagree; installing with -Force (documented recovery path)'
        } elseif ($extractedOver) {
            Add-SetupCheck $gates 'setup.extractedOverExisting' 'FAIL' 'EXTRACTED_OVER_EXISTING: the payload is already at 1.0.0-rc.3 but the installer metadata still describes 1.0.0-rc.2 (a new ZIP was unzipped over the old installation). Refusing to install over it; re-extract the package into an empty directory and use the safe -Action upgrade path, or reinstall explicitly with -Force.'
            $fatal = $true; $fatalOutcome = 'EXTRACTED_OVER_EXISTING'; $fatalErrors = @('EXTRACTED_OVER_EXISTING')
        } else {
            Add-SetupCheck $gates 'setup.versionMarkers' 'FAIL' 'MIXED_VERSION_MARKERS: version markers disagree (VERSION / manifest.distribution / install-state / runtime). Resolve manually, or reinstall with -Force explicitly.'
            $fatal = $true; $fatalOutcome = 'UNKNOWN_OR_MODIFIED'; $fatalErrors = @('MIXED_VERSION_MARKERS')
        }
    }
    if ($fatal) {
        $doc = New-SetupActionDocument -ActionName 'install'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' ([string]$target.kind)
        [void](Set-SetupOutcome -Doc $doc -Checks $gates -ExitCode 2 -Outcome $fatalOutcome -Refused $true -Errors $fatalErrors)
        return $doc
    }
    # --- setup's own package self-integrity gate (read-only; fail-closed) -----------
    $integrityChecks = New-SetupCheckList
    $integrityHint = ''
    if ($target.sameAsPackageRoot) { $integrityHint = $script:InstallRootValue }
    $pkgResult = $null
    try {
        $pkgResult = Invoke-SetupPackageIntegrity -Checks $integrityChecks -InstallRootHint $integrityHint
    } catch {
        Add-SetupCheck $integrityChecks 'setup.packageIntegrity' 'FAIL' ('package integrity inspection failed: ' + $_.Exception.Message)
    }
    $packageValid = $false
    if ($null -ne $pkgResult) { $packageValid = [bool](Get-DocValue $pkgResult 'valid') }
    $integrityFail = $false
    foreach ($c in @(ConvertTo-SetupCheckArray $integrityChecks)) {
        [void]$gates.Add($c)
        if ([string](Get-DocValue $c 'status') -eq 'FAIL') { $integrityFail = $true }
    }
    if (-not $packageValid -or $integrityFail) {
        Add-SetupCheck $gates 'setup.packageIntegrityGate' 'FAIL' 'package self-integrity failed; the installer is NOT invoked (fail-closed)'
        $doc = New-SetupActionDocument -ActionName 'install'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' ([string]$target.kind)
        [void](Set-SetupOutcome -Doc $doc -Checks $gates -ExitCode 2 -Outcome 'PACKAGE_INVALID' -Refused $true -Errors @('PACKAGE_INTEGRITY_FAILED'))
        return $doc
    }
    if (-not [string]::IsNullOrEmpty([string]$script:Opt['FaultPlan'])) {
        $doc = New-SetupActionDocument -ActionName 'install'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' ([string]$target.kind)
        Add-SetupCheck $gates 'setup.faultPlan' 'FAIL' '-FaultPlan is supported only for engine-routed upgrade actions; the delegated installer does not implement fault injection'
        [void](Set-SetupOutcome -Doc $doc -Checks $gates -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('FAULT_PLAN_UNSUPPORTED_ACTION'))
        return $doc
    }
    # Environment gates owned by setup (production home, DSH in use, install-root safety).
    $envGates = Add-SetupMutationEnvironmentGates -Checks $gates -ActionLabel 'install'
    if ($envGates.blocked) {
        $doc = New-SetupActionDocument -ActionName 'install'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' ([string]$target.kind)
        [void](Set-SetupOutcome -Doc $doc -Checks $gates -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors $envGates.errors)
        return $doc
    }
    if ($script:Opt['DryRun']) { return (New-SetupInstallPreviewDocument -ActionName 'install' -OutcomePrefix 'DRYRUN_INSTALL' -GateChecks $gates) }
    if (-not (Test-SetupConsent -What '全新安装（会写入安装根和 DSH profile）')) {
        $doc = New-SetupActionDocument -ActionName 'install'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' ([string]$target.kind)
        Add-SetupCheck $gates 'setup.confirmation' 'FAIL' 'CONFIRMATION_REQUIRED: pass -Yes for non-interactive use (or -DryRun for a read-only preview)'
        [void](Set-SetupOutcome -Doc $doc -Checks $gates -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('CONFIRMATION_REQUIRED'))
        return $doc
    }
    # Setup gates the mutation on its own read-only CHECK: if that check FAILs we do
    # NOT invoke the installer (portable.ps1 would install even after its own check FAIL).
    $machineChild = $script:MachineMode
    $childCheck = Invoke-SetupPortableChild -PortableAction 'check' -CaptureJson:$machineChild
    if ($childCheck.exitCode -ne 0) {
        $doc = New-SetupActionDocument -ActionName 'install'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' ([string]$target.kind)
        Set-DocValue $doc 'portableCheck' (New-SetupPortableEvidence $childCheck)
        $checks = New-SetupCheckList
        foreach ($c in @($gates)) { [void]$checks.Add($c) }
        foreach ($c in @(Get-SetupPortableChildChecks $childCheck)) { [void]$checks.Add($c) }
        Add-SetupCheck $checks 'setup.precheck' 'FAIL' 'INSTALL_PRECHECK_FAILED: setup''s own read-only check failed; the installer is NOT invoked (its internal check is not trusted as a gate)'
        $exit = ConvertTo-SetupExitCode $childCheck.exitCode
        if ($exit -eq 1) { $exit = 2 }
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode $exit -Outcome 'INSTALL_BLOCKED' -Refused $true -Errors @('INSTALL_PRECHECK_FAILED'))
        return $doc
    }
    $child = Invoke-SetupPortableChild -PortableAction 'install' -CaptureJson:$machineChild -MutatingYes
    $checks = New-SetupCheckList
    foreach ($c in @($gates)) { [void]$checks.Add($c) }
    Add-SetupCheck $checks 'setup.precheck' 'PASS' 'setup read-only precheck passed; installer invoked with -Yes'
    foreach ($c in @(Get-SetupPortableChildChecks $child)) { [void]$checks.Add($c) }
    $exit = ConvertTo-SetupDelegatedExit -ChildResult $child -FallbackError ''
    $outcome = Get-SetupPortableChildOutcome $child 'INSTALL_FINISHED'
    $errors = @()
    if ($child.exitCode -eq 0) {
        $outcome = 'INSTALLED'
        $postFailed = Add-SetupInstallPostChecks -Checks $checks
        if ($postFailed) {
            Add-SetupCheck $checks 'setup.postconditions' 'FAIL' 'POSTCONDITION_FAILED: the installer reported success but the setup postconditions do not hold (see setup.post.* checks)'
            $exit = 2
            $outcome = 'INSTALL_INCOMPLETE'
            $errors = @('POSTCONDITION_FAILED')
        }
    } elseif ($exit -eq 2) {
        $errors = @('PORTABLE_INSTALL_REFUSED_OR_FAILED')
    } else {
        $errors = @('PORTABLE_INSTALL_FAILED')
    }
    $doc = New-SetupActionDocument -ActionName 'install'
    Set-DocValue $doc 'route' 'portable'
    Set-DocValue $doc 'sourceState' ([string]$target.kind)
    Set-DocValue $doc 'portable' (New-SetupPortableEvidence $child)
    if ($machineChild) { Set-DocValue $doc 'portableCheck' (New-SetupPortableEvidence $childCheck) }
    [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode $exit -Outcome $outcome -Refused ($exit -ne 0) -Errors $errors)
    return $doc
}

# =====================================================================================
# Action: uninstall (delegates to portable.ps1)
# =====================================================================================

function Invoke-SetupActionUninstall {
    $target = $script:TargetInfo
    $checks = New-SetupCheckList
    if ($target.kind -ne 'INSTALLED') {
        $detail = 'NOT_INSTALLED: no installation markers at ' + $script:InstallRootValue
        if ($target.kind -eq 'UNKNOWN_DIR') { $detail = 'TARGET_NOT_AN_INSTALLATION: ' + $script:InstallRootValue }
        Add-SetupCheck $checks 'setup.targetState' 'FAIL' $detail
        $doc = New-SetupActionDocument -ActionName 'uninstall'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' ([string]$target.kind)
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('NOT_INSTALLED'))
        return $doc
    }
    if ($target.sameAsPackageRoot) {
        if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
            $markerProblem = Get-SetupMarkerProblemDetail $target.versionMarkers
            Add-SetupCheck $checks ([string]$markerProblem.id) 'FAIL' ([string]$markerProblem.detail)
            $doc = New-SetupActionDocument -ActionName 'uninstall'
            Set-DocValue $doc 'route' 'portable'
            Set-DocValue $doc 'sourceState' 'UNKNOWN_OR_MODIFIED'
            [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'EXTRACTED_OVER_EXISTING' -Refused $true -Errors @([string]$markerProblem.token))
            return $doc
        }
        Add-SetupCheck $checks 'setup.selfModeInPlace' 'WARN' 'SELF_MODE_IN_PLACE_PACKAGE_ROOT: legitimate in-place installation; the in-place tree is the uninstall target (package sealing is relaxed by the installer)'
    }
    if (-not $script:PackageInfo.hasManifest) {
        Add-SetupCheck $checks 'package.manifest' 'FAIL' ('manifest.json not found at package root: ' + $script:PackageRootValue)
        $doc = New-SetupActionDocument -ActionName 'uninstall'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' 'INSTALLED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'PACKAGE_INVALID' -Refused $true -Errors @('PACKAGE_INTEGRITY_FILES_MISSING'))
        return $doc
    }
    $pending = Get-SetupPendingTransaction
    if ($null -ne $pending) {
        $pid = [string](Get-DocValue $pending 'transactionId')
        Add-SetupCheck $checks 'setup.pendingTransaction' 'FAIL' ('PENDING_TRANSACTION: ' + $pid + ' — roll it back (or resolve it) before uninstalling')
        $doc = New-SetupActionDocument -ActionName 'uninstall'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' 'INSTALLED'
        Set-DocValue $doc 'transaction' $pending
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('PENDING_TRANSACTION'))
        return $doc
    }
    if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
        Add-SetupCheck $checks 'setup.versionMarkers' 'WARN' 'MIXED_VERSION_MARKERS: version markers disagree; uninstall is a removal action, proceeding'
    }
    # Environment gates owned by setup (production home, DSH in use, install-root safety).
    $envGates = Add-SetupMutationEnvironmentGates -Checks $checks -ActionLabel 'uninstall'
    if ($envGates.blocked) {
        $doc = New-SetupActionDocument -ActionName 'uninstall'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' 'INSTALLED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors $envGates.errors)
        return $doc
    }
    if ($script:Opt['DryRun']) {
        $doc = New-SetupActionDocument -ActionName 'uninstall'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' 'INSTALLED'
        Set-DocValue $doc 'dryRun' $true
        Set-DocValue $doc 'portableCheck' (New-SetupPortableEvidence (Invoke-SetupPortableChild -PortableAction 'check' -CaptureJson))
        Add-SetupCheck $checks 'setup.dryRun' 'PASS' 'read-only preview only: the delegated uninstall (-DryRun) is NOT invoked because the installer dry-run is not a proven no-write path; no files were changed'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 0 -Outcome 'DRYRUN_UNINSTALL_PREVIEW' -Refused $false)
        return $doc
    }
    if (-not (Test-SetupConsent -What '卸载（会修改 DSH profile 并可能删除运行时）')) {
        Add-SetupCheck $checks 'setup.confirmation' 'FAIL' 'CONFIRMATION_REQUIRED: pass -Yes for non-interactive use'
        $doc = New-SetupActionDocument -ActionName 'uninstall'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' 'INSTALLED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('CONFIRMATION_REQUIRED'))
        return $doc
    }
    if (-not [string]::IsNullOrEmpty([string]$script:Opt['FaultPlan'])) {
        Add-SetupCheck $checks 'setup.faultPlan' 'FAIL' '-FaultPlan is supported only for engine-routed upgrade actions'
        $doc = New-SetupActionDocument -ActionName 'uninstall'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' 'INSTALLED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('FAULT_PLAN_UNSUPPORTED_ACTION'))
        return $doc
    }
    $machineChild = $script:MachineMode
    $child = Invoke-SetupPortableChild -PortableAction 'uninstall' -CaptureJson:$machineChild -MutatingYes
    foreach ($c in @(Get-SetupPortableChildChecks $child)) { [void]$checks.Add($c) }
    $exit = ConvertTo-SetupDelegatedExit -ChildResult $child -FallbackError ''
    $outcome = Get-SetupPortableChildOutcome $child 'UNINSTALL_FINISHED'
    $errors = @()
    if ($child.exitCode -eq 0) {
        $outcome = 'UNINSTALLED'
        $postFailed = Add-SetupUninstallPostChecks -Checks $checks
        if ($postFailed) {
            Add-SetupCheck $checks 'setup.postconditions' 'FAIL' 'POSTCONDITION_FAILED: the installer reported success but the setup postconditions do not hold (see setup.post.* checks)'
            $exit = 2
            $outcome = 'UNINSTALL_INCOMPLETE'
            $errors = @('POSTCONDITION_FAILED')
        }
    } elseif ($exit -eq 2) {
        $errors = @('PORTABLE_UNINSTALL_REFUSED_OR_FAILED')
    } else {
        $errors = @('PORTABLE_UNINSTALL_FAILED')
    }
    $doc = New-SetupActionDocument -ActionName 'uninstall'
    Set-DocValue $doc 'route' 'portable'
    Set-DocValue $doc 'sourceState' 'INSTALLED'
    Set-DocValue $doc 'portable' (New-SetupPortableEvidence $child)
    [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode $exit -Outcome $outcome -Refused ($exit -ne 0) -Errors $errors)
    return $doc
}

# =====================================================================================
# Action: upgrade (engine CHECK -> PLAN -> APPLY with planId + -Yes)
# =====================================================================================

function Invoke-SetupActionUpgrade {
    $target = $script:TargetInfo
    $checks = New-SetupCheckList
    if (-not $script:InstallRootExplicit) {
        Add-SetupCheck $checks 'setup.installRoot' 'FAIL' 'INSTALL_ROOT_REQUIRED: -InstallRoot must point at the existing installation for -Action upgrade'
        $doc = New-SetupActionDocument -ActionName 'upgrade'
        Set-DocValue $doc 'route' 'engine'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('INSTALL_ROOT_REQUIRED'))
        return $doc
    }
    if ($target.kind -eq 'ABSENT' -or $target.kind -eq 'EMPTY' -or $target.kind -eq 'EXTRACTED_PACKAGE') {
        Add-SetupCheck $checks 'setup.targetState' 'FAIL' ('NOT_INSTALLED: no installation markers at ' + $script:InstallRootValue)
        Add-SetupCheck $checks 'setup.recommendation' 'FAIL' ('this target is not installed (or is just an extracted package); use -Action install -InstallRoot "' + $script:InstallRootValue + '" -Yes for a fresh install')
        $doc = New-SetupActionDocument -ActionName 'upgrade'
        Set-DocValue $doc 'route' 'engine'
        Set-DocValue $doc 'sourceState' 'NOT_INSTALLED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('NOT_INSTALLED_USE_INSTALL'))
        return $doc
    }
    if ($target.kind -ne 'INSTALLED') {
        Add-SetupCheck $checks 'setup.targetState' 'FAIL' ('TARGET_STATE_UNKNOWN: ' + $script:InstallRootValue + ' does not look like a supported Layout-A installation')
        $doc = New-SetupActionDocument -ActionName 'upgrade'
        Set-DocValue $doc 'route' 'engine'
        Set-DocValue $doc 'sourceState' 'UNKNOWN_OR_MODIFIED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'UNKNOWN_OR_MODIFIED' -Refused $true -Errors @('TARGET_STATE_UNKNOWN'))
        return $doc
    }
    if ($target.sameAsPackageRoot) {
        $doc = New-SetupActionDocument -ActionName 'upgrade'
        Set-DocValue $doc 'route' 'engine'
        Set-DocValue $doc 'sourceState' 'UNKNOWN_OR_MODIFIED'
        if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
            $markerProblem = Get-SetupMarkerProblemDetail $target.versionMarkers
            Add-SetupCheck $checks ([string]$markerProblem.id) 'FAIL' ([string]$markerProblem.detail)
            [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'EXTRACTED_OVER_EXISTING' -Refused $true -Errors @([string]$markerProblem.token))
        } else {
            Add-SetupCheck $checks 'setup.extractionOverInstall' 'FAIL' 'PACKAGE_ROOT_EQUALS_INSTALL_ROOT: -Action upgrade needs a separate package root (the unified package extracted into a NEW directory) and an explicit -InstallRoot pointing at the existing installation. Read-only check/plan/status/verify are allowed from an in-place tree; install/upgrade are refused.'
            [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('PACKAGE_ROOT_EQUALS_INSTALL_ROOT'))
        }
        return $doc
    }
    if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
        $markerProblem = Get-SetupMarkerProblemDetail $target.versionMarkers
        Add-SetupCheck $checks ([string]$markerProblem.id) 'FAIL' ([string]$markerProblem.detail)
        $doc = New-SetupActionDocument -ActionName 'upgrade'
        Set-DocValue $doc 'route' 'engine'
        $outcome = 'UNKNOWN_OR_MODIFIED'
        if ([bool]$target.versionMarkers.extractedOverExisting) { $outcome = 'EXTRACTED_OVER_EXISTING' }
        Set-DocValue $doc 'sourceState' $outcome
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome $outcome -Refused $true -Errors @([string]$markerProblem.token))
        return $doc
    }
    if (-not [string]::IsNullOrEmpty([string]$script:Opt['FaultPlan']) -and $env:CNKI_UPGRADE_TEST_MODE -ne '1') {
        # Already refused globally in argument validation; kept as defence in depth.
        Add-SetupCheck $checks 'setup.faultPlan' 'FAIL' 'FAULT_INJECTION_DISALLOWED: -FaultPlan requires $env:CNKI_UPGRADE_TEST_MODE=1'
        $doc = New-SetupActionDocument -ActionName 'upgrade'
        Set-DocValue $doc 'route' 'engine'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('FAULT_INJECTION_DISALLOWED'))
        return $doc
    }
    # 1) engine CHECK (read-only)
    $checkResult = Invoke-SetupEngineAction -EngineAction 'check'
    $checkDoc = ConvertTo-SetupEngineDocument -EngineDoc $checkResult.doc -ActionName 'upgrade'
    Set-DocValue $checkDoc 'route' 'engine'
    if ($checkResult.exitCode -ne 0) {
        $state = [string](Get-DocValue $checkDoc 'sourceState')
        $outcome = 'UPGRADE_PRECHECK_BLOCKED'
        if ($state -eq 'UNKNOWN_OR_MODIFIED') { $outcome = 'UNKNOWN_OR_MODIFIED' }
        $existing = Get-SetupArrayValue $checkDoc 'errors'
        $all = New-Object System.Collections.ArrayList
        [void]$all.Add('UPGRADE_PRECHECK_FAILED')
        foreach ($e in $existing) { [void]$all.Add([string]$e) }
        [void](Set-SetupOutcome -Doc $checkDoc -Checks (Get-DocValue $checkDoc 'checks') -ExitCode 2 -Outcome $outcome -Refused $true -Errors $all.ToArray())
        return $checkDoc
    }
    $state = [string](Get-DocValue $checkDoc 'sourceState')
    if ($state -eq 'RC3_ALREADY_INSTALLED') {
        # Charter D5/Q9 + Lead ruling: APPLY on the target state is a safe no-op, and
        # setup reports it as a SUCCESS with zero writes (no transaction, no backup).
        $noopChecks = New-SetupCheckList
        Add-SetupCheck $noopChecks 'setup.noop' 'PASS' 'already at target (1.0.0-rc.3): no transaction, no backup, nothing written; no action needed'
        $variant = Get-DocValue $checkDoc 'variant'
        if ($null -ne $variant) { Set-DocValue $checkDoc 'variant' ([string]$variant) }
        $merged = Merge-SetupCheckLists (Get-DocValue $checkDoc 'checks') $noopChecks
        [void](Set-SetupOutcome -Doc $checkDoc -Checks $merged -ExitCode 0 -Outcome 'NOOP_ALREADY_TARGET' -Refused $false)
        return $checkDoc
    }
    if ($state -ne 'RC2_CLEAN' -and $state -ne 'RC2_HOTFIXED') {
        $extra = New-SetupCheckList
        Add-SetupCheck $extra 'setup.route' 'FAIL' ('UNSUPPORTED_SOURCE_STATE: ' + $state + ' — upgrade supports only RC2_CLEAN/RC2_HOTFIXED source states')
        $doc = Add-SetupExtraChecks -Doc $checkDoc -ExtraChecks $extra -FailOutcome 'UNKNOWN_OR_MODIFIED' -FailErrors @('UNSUPPORTED_SOURCE_STATE')
        return $doc
    }
    # 2) engine PLAN (read-only)
    $planResult = Invoke-SetupEngineAction -EngineAction 'plan'
    $planDoc = ConvertTo-SetupEngineDocument -EngineDoc $planResult.doc -ActionName 'upgrade'
    Set-DocValue $planDoc 'route' 'engine'
    if ($planResult.exitCode -ne 0) {
        $existing = Get-SetupArrayValue $planDoc 'errors'
        $all = New-Object System.Collections.ArrayList
        [void]$all.Add('UPGRADE_PLAN_BLOCKED')
        foreach ($e in $existing) { [void]$all.Add([string]$e) }
        [void](Set-SetupOutcome -Doc $planDoc -Checks (Get-DocValue $planDoc 'checks') -ExitCode 2 -Outcome 'PLAN_BLOCKED' -Refused $true -Errors $all.ToArray())
        return $planDoc
    }
    $plan = Get-DocValue $planDoc 'plan'
    $actionable = $false
    if ($null -ne $plan) { $actionable = [bool](Get-DocValue $plan 'actionable') }
    if (-not $actionable) {
        $extra = New-SetupCheckList
        Add-SetupCheck $extra 'setup.planGate' 'FAIL' 'PLAN_NOT_ACTIONABLE: the engine plan is not actionable (see checks/errors above)'
        $doc = Add-SetupExtraChecks -Doc $planDoc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @('PLAN_NOT_ACTIONABLE')
        return $doc
    }
    $currentPlanId = [string](Get-DocValue $planDoc 'planId')
    Set-DocValue $planDoc 'nextCommand' (Get-SetupNextCommand -PlanIdValue $currentPlanId)
    if ($script:Opt['DryRun']) {
        $extra = New-SetupCheckList
        Add-SetupCheck $extra 'setup.dryRun' 'PASS' ('DRY RUN: read-only CHECK+PLAN completed; no APPLY was executed. planId=' + $currentPlanId)
        $doc = Add-SetupExtraChecks -Doc $planDoc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @('DRY_RUN_NO_APPLY')
        $docSummary = Get-DocValue $doc 'summary'
        if ($null -ne $docSummary) { Set-DocValue $docSummary 'outcome' 'PLAN_READY' }
        Set-DocValue $doc 'dryRun' $true
        return $doc
    }
    if ([string]::IsNullOrEmpty([string]$script:Opt['PlanId'])) {
        $extra = New-SetupCheckList
        Add-SetupCheck $extra 'setup.planReady' 'PASS' ('PLAN_READY (read-only): planId=' + $currentPlanId + '; re-run with -PlanId <planId> -Yes to apply the transactional upgrade')
        $doc = Add-SetupExtraChecks -Doc $planDoc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @('PLAN_ID_REQUIRED')
        $docSummary = Get-DocValue $doc 'summary'
        if ($null -ne $docSummary) { Set-DocValue $docSummary 'outcome' 'PLAN_READY' }
        return $doc
    }
    if (-not [string]::Equals([string]$script:Opt['PlanId'], $currentPlanId, [System.StringComparison]::OrdinalIgnoreCase)) {
        $extra = New-SetupCheckList
        Add-SetupCheck $extra 'setup.planGate' 'FAIL' ('PLAN_STALE: provided -PlanId ''' + [string]$script:Opt['PlanId'] + ''' does not match the current state planId ''' + $currentPlanId + '''; re-run -Action plan. No file was written.')
        $doc = Add-SetupExtraChecks -Doc $planDoc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @('PLAN_STALE')
        return $doc
    }
    if (-not $script:Opt['Yes']) {
        $extra = New-SetupCheckList
        Add-SetupCheck $extra 'setup.confirmation' 'FAIL' 'CONFIRMATION_REQUIRED: APPLY requires -Yes together with -PlanId (no file was written)'
        $doc = Add-SetupExtraChecks -Doc $planDoc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @('CONFIRMATION_REQUIRED')
        return $doc
    }
    # 3) engine APPLY (planId gate + -Yes already satisfied)
    $applyResult = Invoke-SetupEngineAction -EngineAction 'apply' -PlanIdValue ([string]$script:Opt['PlanId']) -YesValue $true
    $applyDoc = ConvertTo-SetupEngineDocument -EngineDoc $applyResult.doc -ActionName 'upgrade'
    Set-DocValue $applyDoc 'route' 'engine'
    $applySummary = Get-DocValue $applyDoc 'summary'
    $applyOutcome = ''
    if ($null -ne $applySummary) { $applyOutcome = [string](Get-DocValue $applySummary 'outcome') }
    if ($applyResult.exitCode -eq 0) {
        if ($applyOutcome -eq 'ALREADY_AT_TARGET') {
            $extra = New-SetupCheckList
            Add-SetupCheck $extra 'setup.noop' 'PASS' 'already at target: APPLY was a safe no-op (zero writes, no transaction)'
            $doc = Add-SetupExtraChecks -Doc $applyDoc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @()
            $docSummary = Get-DocValue $doc 'summary'
            if ($null -ne $docSummary) { Set-DocValue $docSummary 'outcome' 'NOOP_ALREADY_TARGET' }
            return $doc
        }
        $extra = New-SetupCheckList
        Add-SetupCheck $extra 'setup.upgradeApplied' 'PASS' ('transactional APPLY committed; transaction=' + [string](Get-DocValue (Get-DocValue $applyDoc 'transaction') 'transactionId'))
        $doc = Add-SetupExtraChecks -Doc $applyDoc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @()
        return $doc
    }
    return $applyDoc
}

function Get-SetupNextCommand {
    param([string]$PlanIdValue)
    $setupPath = Join-SetupPath $script:ScriptDirectory 'setup.ps1'
    $profileArg = ''
    if (-not [string]::IsNullOrEmpty([string]$script:Opt['DshHome'])) { $profileArg = ' -DshHome "' + [string]$script:Opt['DshHome'] + '"' }
    return ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $setupPath + '" -Action upgrade -InstallRoot "' +
        $script:InstallRootValue + '" -PlanId ' + $PlanIdValue + ' -Yes' + $profileArg)
}

# =====================================================================================
# Action: verify (read-only)
# =====================================================================================

function Invoke-SetupActionVerify {
    $target = $script:TargetInfo
    if ($target.kind -ne 'INSTALLED') {
        $checks = New-SetupCheckList
        Add-SetupCheck $checks 'setup.targetState' 'FAIL' ('NOT_INSTALLED: nothing to verify at ' + $script:InstallRootValue)
        $doc = New-SetupActionDocument -ActionName 'verify'
        Set-DocValue $doc 'route' 'engine'
        Set-DocValue $doc 'sourceState' 'NOT_INSTALLED'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'FILE_UPGRADE_INCOMPLETE' -Refused $true -Errors @('NOT_INSTALLED'))
        Set-DocValue $doc 'verify' ([ordered]@{
                fileUpgradeComplete              = $false
                FILE_UPGRADE_COMPLETE            = 'FAIL'
                runtimeActivation                = $script:RuntimeActivationNotTested
                DSH_RUNTIME_ACTIVATION_VERIFIED  = $script:RuntimeActivationNotTested
                sourceState                      = 'NOT_INSTALLED'
                summary                          = (Get-SetupCheckSummary $checks)
            })
        Set-DocValue $doc 'FILE_UPGRADE_COMPLETE' 'FAIL'
        return $doc
    }
    $result = Invoke-SetupEngineAction -EngineAction 'verify'
    $doc = ConvertTo-SetupEngineDocument -EngineDoc $result.doc -ActionName 'verify'
    Set-DocValue $doc 'route' 'engine'
    $extra = New-SetupCheckList
    $markerToken = ''
    if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
        $markerProblem = Get-SetupMarkerProblemDetail $target.versionMarkers
        Add-SetupCheck $extra ([string]$markerProblem.id) 'FAIL' ([string]$markerProblem.detail)
        $markerToken = [string]$markerProblem.token
    }
    $doc = Add-SetupExtraChecks -Doc $doc -ExtraChecks $extra -FailOutcome 'FILE_UPGRADE_INCOMPLETE' -FailErrors @($markerToken)
    $verify = Get-DocValue $doc 'verify'
    if ($null -ne $verify) {
        $fileComplete = [string](Get-DocValue $verify 'FILE_UPGRADE_COMPLETE')
        if (-not [string]::IsNullOrEmpty($markerToken)) { $fileComplete = 'FAIL'; Set-DocValue $verify 'FILE_UPGRADE_COMPLETE' 'FAIL'; Set-DocValue $verify 'fileUpgradeComplete' $false }
        Set-DocValue $doc 'FILE_UPGRADE_COMPLETE' $fileComplete
        Set-DocValue $doc 'variant' (Get-DocValue $verify 'variant')
    }
    $docSummary = Get-DocValue $doc 'summary'
    if ($null -ne $docSummary) {
        $outcome = [string](Get-DocValue $docSummary 'outcome')
        if ($outcome -ne 'FILE_UPGRADE_COMPLETE') { $outcome = 'FILE_UPGRADE_INCOMPLETE' }
        Set-DocValue $docSummary 'outcome' $outcome
    }
    return $doc
}

# =====================================================================================
# Action: status (read-only)
# =====================================================================================

function Get-SetupResolvedDshHome {
    $homePath = [string]$script:Opt['DshHome']
    if (-not [string]::IsNullOrEmpty($homePath)) { return (Get-SetupNormalizedPath $homePath) }
    if (-not [string]::IsNullOrEmpty($env:DSH_HOME)) { return (Get-SetupNormalizedPath $env:DSH_HOME) }
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) { return (Get-SetupNormalizedPath (Join-SetupPath $env:USERPROFILE '.dsh')) }
    return $null
}

function Invoke-SetupActionStatus {
    $target = $script:TargetInfo
    if ($target.kind -ne 'INSTALLED') {
        $checks = New-SetupCheckList
        Add-SetupCheck $checks 'setup.targetState' 'PASS' ('NOT_INSTALLED (' + [string]$target.kind + '): no installation at ' + $script:InstallRootValue)
        Add-SetupCheck $checks 'setup.recommendation' 'PASS' 'run -Action install for a fresh install, or -Action check for the integrity/state report'
        $dshHome = Get-SetupResolvedDshHome
        $production = $null
        if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) { $production = Get-SetupNormalizedPath (Join-SetupPath $env:USERPROFILE '.dsh') }
        $doc = New-SetupActionDocument -ActionName 'status'
        Set-DocValue $doc 'route' 'engine'
        Set-DocValue $doc 'sourceState' 'NOT_INSTALLED'
        Set-DocValue $doc 'status' ([ordered]@{
                installed          = [ordered]@{ version = $null; manifestSha256 = $null; manifestParses = $false; distributionVersion = $null; bundleVersion = $null; fileCount = 0 }
                payload            = [ordered]@{ state = 'NOT_INSTALLED'; sourceMatches = 0; targetMatches = 0; conflicts = @(); reasons = @('NOT_INSTALLED') }
                environmentFiles   = @()
                dsh                = [ordered]@{ home = $dshHome; productionHome = $production; profile = [string]$script:Opt['DshProfile']; referenceOutcome = 'NOT_FOUND'; junctionTarget = $null; dshRunning = $null; isLiveTarget = $null }
                transactions       = @()
                transactionRoot    = $null
                pendingTransaction = $null
                lastUpgrade        = $null
                installState       = $null
            })
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 0 -Outcome 'NOT_INSTALLED' -Refused $false)
        return $doc
    }
    $result = Invoke-SetupEngineAction -EngineAction 'status'
    $doc = ConvertTo-SetupEngineDocument -EngineDoc $result.doc -ActionName 'status'
    Set-DocValue $doc 'route' 'engine'
    $status = Get-DocValue $doc 'status'
    if ($null -ne $status) {
        $installState = Read-SetupJsonFile (Join-SetupPath $script:InstallRootValue '_portable\install-state.json')
        Set-DocValue $status 'installState' $installState
        $runtime = Read-SetupJsonFile (Join-SetupPath $script:InstallRootValue 'bundle\cnki-research\portable.runtime.json')
        Set-DocValue $status 'runtime' $runtime
    }
    $extra = New-SetupCheckList
    if ($null -ne $target.versionMarkers) {
        $markerText = New-Object System.Collections.ArrayList
        foreach ($e in @($target.versionMarkers.entries)) { [void]$markerText.Add(([string]$e['source'] + '=' + [string]$e['version'])) }
        if ([bool]$target.versionMarkers.mismatch) {
            Add-SetupCheck $extra 'setup.versionMarkers' 'WARN' ('MIXED_VERSION_MARKERS (informational status): ' + ($markerText -join '; '))
        } elseif ($markerText.Count -gt 0) {
            Add-SetupCheck $extra 'setup.versionMarkers' 'PASS' ('consistent version markers: ' + ($markerText -join '; '))
        }
    }
    if ($target.sameAsPackageRoot) {
        Add-SetupCheck $extra 'setup.selfModeInPlace' 'WARN' 'SELF_MODE_IN_PLACE_PACKAGE_ROOT: this tree is both package root and installation root (legitimate in-place installation; informational status)'
    }
    $doc = Add-SetupExtraChecks -Doc $doc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @()
    # STATUS is informational and always exits 0 (engine V1 semantics).
    Set-DocValue $doc 'exitCode' 0
    Set-DocValue $doc 'ok' $true
    return $doc
}

# =====================================================================================
# Action: rollback
# =====================================================================================

function Get-SetupPendingTransaction {
    # Read-only: engine STATUS is used to detect a pending/corrupt upgrade transaction.
    if (-not (Test-SetupEngineReady)) { return $null }
    try {
        $result = Invoke-SetupEngineAction -EngineAction 'status'
        $status = Get-DocValue $result.doc 'status'
        if ($null -eq $status) { return $null }
        $pending = Get-DocValue $status 'pendingTransaction'
        if ($null -eq $pending) { return $null }
        return $pending
    } catch {
        return $null
    }
}

function Get-SetupEngineStatusDocument {
    if (-not (Test-SetupEngineReady)) { return $null }
    try {
        $result = Invoke-SetupEngineAction -EngineAction 'status'
        return $result.doc
    } catch {
        return $null
    }
}

function Invoke-SetupActionRollback {
    $target = $script:TargetInfo
    $checks = New-SetupCheckList
    if ($target.kind -ne 'INSTALLED') {
        Add-SetupCheck $checks 'setup.targetState' 'FAIL' ('NOT_INSTALLED: nothing to roll back at ' + $script:InstallRootValue)
        $doc = New-SetupActionDocument -ActionName 'rollback'
        Set-DocValue $doc 'route' 'engine'
        Set-DocValue $doc 'sourceState' ([string]$target.kind)
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('NOT_INSTALLED'))
        return $doc
    }
    if ($target.sameAsPackageRoot) {
        if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
            $markerProblem = Get-SetupMarkerProblemDetail $target.versionMarkers
            Add-SetupCheck $checks ([string]$markerProblem.id) 'FAIL' ([string]$markerProblem.detail)
            $doc = New-SetupActionDocument -ActionName 'rollback'
            Set-DocValue $doc 'route' 'engine'
            Set-DocValue $doc 'sourceState' 'UNKNOWN_OR_MODIFIED'
            [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'EXTRACTED_OVER_EXISTING' -Refused $true -Errors @([string]$markerProblem.token))
            return $doc
        }
        Add-SetupCheck $checks 'setup.selfModeInPlace' 'WARN' 'SELF_MODE_IN_PLACE_PACKAGE_ROOT: legitimate in-place installation; rollback runs against the in-place tree (package sealing is relaxed by the engine)'
    }
    $statusDoc = Get-SetupEngineStatusDocument
    $pending = $null
    $lastUpgrade = $null
    if ($null -ne $statusDoc) {
        $status = Get-DocValue $statusDoc 'status'
        if ($null -ne $status) {
            $pending = Get-DocValue $status 'pendingTransaction'
            $lastUpgrade = Get-DocValue $status 'lastUpgrade'
        }
    }
    $route = ''
    $transactionId = [string]$script:Opt['Transaction']
    $rollbackTarget = [string]$script:Opt['RollbackTarget']
    if ([string]::IsNullOrEmpty($rollbackTarget)) { $rollbackTarget = 'auto' }
    if ([string]::IsNullOrEmpty($transactionId)) {
        if ($rollbackTarget -eq 'upgrade') { $route = 'engine' }
        elseif ($rollbackTarget -eq 'install') { $route = 'portable' }
        else {
            if ($null -ne $lastUpgrade) { $route = 'engine' } else { $route = 'portable' }
        }
    } else {
        # Explicit transaction id always means an upgrade transaction.
        $route = 'engine'
    }
    if ($null -ne $pending -and $route -eq 'portable') {
        # A pending upgrade transaction must be resolved with the transaction engine.
        $route = 'engine'
    }
    $routeCheckDetail = 'ROLLBACK_ROUTE=' + $route
    if ($route -eq 'engine') { $routeCheckDetail = $routeCheckDetail + ' (transaction engine' + $(if ($rollbackTarget -eq 'auto') { ', newest upgrade transaction' } else { '' }) + ')' }
    else { $routeCheckDetail = $routeCheckDetail + ' (installer backup via portable.ps1)' }
    Add-SetupCheck $checks 'setup.route' 'PASS' $routeCheckDetail
    if ($null -ne $target.versionMarkers -and [bool]$target.versionMarkers.mismatch) {
        Add-SetupCheck $checks 'setup.versionMarkers' 'WARN' 'MIXED_VERSION_MARKERS: rollback is a recovery route; conflict detection is delegated to the engine/installer'
    }
    if ($route -eq 'portable') {
        # Installer-backed rollback mutates the DSH profile: apply setup's own
        # production-home / DSH-in-use / install-root gates before delegating.
        $envGates = Add-SetupMutationEnvironmentGates -Checks $checks -ActionLabel 'rollback (installer backup)'
        if ($envGates.blocked) {
            $doc = New-SetupActionDocument -ActionName 'rollback'
            Set-DocValue $doc 'route' 'portable'
            Set-DocValue $doc 'sourceState' 'INSTALLED'
            Set-DocValue $doc 'rollbackTarget' 'install'
            [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors $envGates.errors)
            return $doc
        }
    }
    if (-not $script:Opt['Yes'] -and -not $script:Opt['DryRun']) {
        $consent = Test-SetupConsent -What ('回滚（' + $route + '）')
        if (-not $consent) {
            Add-SetupCheck $checks 'setup.confirmation' 'FAIL' 'CONFIRMATION_REQUIRED: rollback requires -Yes (no file was written)'
            $doc = New-SetupActionDocument -ActionName 'rollback'
            Set-DocValue $doc 'route' $route
            Set-DocValue $doc 'sourceState' 'INSTALLED'
            Set-DocValue $doc 'rollbackTarget' $route
            [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('CONFIRMATION_REQUIRED'))
            return $doc
        }
    }
    if ($script:Opt['DryRun']) {
        $doc = New-SetupActionDocument -ActionName 'rollback'
        Set-DocValue $doc 'route' $route
        Set-DocValue $doc 'sourceState' 'INSTALLED'
        Set-DocValue $doc 'rollbackTarget' $route
        Set-DocValue $doc 'dryRun' $true
        if ($route -eq 'engine') {
            Set-DocValue $doc 'transaction' $lastUpgrade
            if ($null -ne $lastUpgrade) {
                Add-SetupCheck $checks 'setup.dryRun' 'PASS' ('DRY RUN: would restore the newest committed upgrade transaction ' + [string](Get-DocValue $lastUpgrade 'transactionId') + '; nothing was written')
            } else {
                Add-SetupCheck $checks 'setup.dryRun' 'WARN' 'DRY RUN: no committed upgrade transaction found; nothing was written'
            }
        } else {
            $backup = Get-SetupLatestInstallerBackup -TargetRoot $script:InstallRootValue
            if ($backup.found) {
                Add-SetupCheck $checks 'setup.dryRun' 'PASS' ('DRY RUN: would restore installer backup ' + [string]$backup.path + '; nothing was written')
                Set-DocValue $doc 'rollback' ([ordered]@{ route = 'install'; backupPath = $backup.path; backup = $backup.backup })
            } else {
                Add-SetupCheck $checks 'setup.dryRun' 'FAIL' 'DRY RUN: no installer backup found under _portable\backups; nothing was written'
            }
        }
        $exit = 0
        $outcome = 'DRYRUN_ROLLBACK'
        $refused = $false
        foreach ($c in @(ConvertTo-SetupCheckArray $checks)) {
            if ([string](Get-DocValue $c 'status') -eq 'FAIL') { $exit = 2; $refused = $true; $outcome = 'DRYRUN_ROLLBACK_BLOCKED' }
        }
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode $exit -Outcome $outcome -Refused $refused)
        return $doc
    }
    if (-not [string]::IsNullOrEmpty([string]$script:Opt['FaultPlan'])) {
        Add-SetupCheck $checks 'setup.faultPlan' 'WARN' '-FaultPlan is forwarded to the transaction engine for rollback routes; installer-backed rollback does not implement fault injection'
    }
    if ($route -eq 'engine') {
        $txnArg = $transactionId
        $result = Invoke-SetupEngineAction -EngineAction 'rollback' -TransactionValue $txnArg -YesValue $true
        $doc = ConvertTo-SetupEngineDocument -EngineDoc $result.doc -ActionName 'rollback'
        Set-DocValue $doc 'route' 'engine'
        Set-DocValue $doc 'rollbackTarget' 'upgrade'
        $extra = New-SetupCheckList
        Add-SetupCheck $extra 'setup.route' 'PASS' 'ROLLBACK_ROUTE=engine (transaction engine)'
        $doc = Add-SetupExtraChecks -Doc $doc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @()
        if ($result.exitCode -eq 2) {
            $errText = ((Get-SetupArrayValue $doc 'errors') -join '; ')
            if ($errText -like '*ROLLBACK_TRANSACTION_NOT_FOUND*') {
                Add-SetupCheck $extra 'setup.rollbackRoute' 'WARN' 'no upgrade transaction available: use -RollbackTarget install to restore the installer backup instead'
                $doc = Add-SetupExtraChecks -Doc $doc -ExtraChecks $extra -FailOutcome 'REFUSED' -FailErrors @()
            }
        }
        return $doc
    }
    $backup = Get-SetupLatestInstallerBackup -TargetRoot $script:InstallRootValue
    if (-not $backup.found) {
        Add-SetupCheck $checks 'setup.installerBackup' 'FAIL' 'NO_INSTALLER_BACKUP: no restorable installer backup under _portable\backups; nothing was written'
        $doc = New-SetupActionDocument -ActionName 'rollback'
        Set-DocValue $doc 'route' 'portable'
        Set-DocValue $doc 'sourceState' 'INSTALLED'
        Set-DocValue $doc 'rollbackTarget' 'install'
        [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('NO_INSTALLER_BACKUP'))
        return $doc
    }
    Add-SetupCheck $checks 'setup.installerBackup' 'PASS' ('restoring installer backup: ' + [string]$backup.path)
    $machineChild = $script:MachineMode
    $child = Invoke-SetupPortableChild -PortableAction 'rollback' -CaptureJson:$machineChild -MutatingYes
    foreach ($c in @(Get-SetupPortableChildChecks $child)) { [void]$checks.Add($c) }
    $exit = ConvertTo-SetupDelegatedExit -ChildResult $child -FallbackError ''
    $outcome = Get-SetupPortableChildOutcome $child 'ROLLBACK_FINISHED'
    $errors = @()
    if ($child.exitCode -eq 0) {
        $outcome = 'ROLLED_BACK'
        $postFailed = Add-SetupRollbackPostChecks -Checks $checks
        if ($postFailed) {
            Add-SetupCheck $checks 'setup.postconditions' 'FAIL' 'POSTCONDITION_FAILED: the installer reported success but the profile dependency was not restored (see setup.post.* checks)'
            $exit = 2
            $outcome = 'ROLLBACK_INCOMPLETE'
            $errors = @('POSTCONDITION_FAILED')
        }
    } elseif ($exit -eq 2) {
        $errors = @('PORTABLE_ROLLBACK_REFUSED_OR_FAILED')
    } else {
        $errors = @('PORTABLE_ROLLBACK_FAILED')
    }
    $doc = New-SetupActionDocument -ActionName 'rollback'
    Set-DocValue $doc 'route' 'portable'
    Set-DocValue $doc 'sourceState' 'INSTALLED'
    Set-DocValue $doc 'rollbackTarget' 'install'
    Set-DocValue $doc 'rollback' ([ordered]@{ route = 'install'; backupPath = $backup.path; backup = $backup.backup })
    Set-DocValue $doc 'portable' (New-SetupPortableEvidence $child)
    [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode $exit -Outcome $outcome -Refused ($exit -ne 0) -Errors $errors)
    return $doc
}

# =====================================================================================
# Argument validation / main dispatch
# =====================================================================================

function Get-SetupArgumentErrors {
    # NOTE: variable names are case-insensitive in PowerShell: do NOT name a local
    # `$action` here because the script parameter `$Action` would be shadowed.
    $errors = New-Object System.Collections.ArrayList
    $actionValue = ''
    if (-not [string]::IsNullOrEmpty($Action)) { $actionValue = $Action.Trim().ToLowerInvariant() }
    if ([string]::IsNullOrEmpty($actionValue)) {
        [void]$errors.Add('INVALID_ACTION: -Action is mandatory (check|plan|install|upgrade|verify|status|rollback|uninstall)')
    } elseif ($script:SetupActions -notcontains $actionValue) {
        [void]$errors.Add("INVALID_ACTION: -Action must be one of check/plan/install/upgrade/verify/status/rollback/uninstall (got '$actionValue')")
    }
    $rollbackTargetValue = [string]$RollbackTarget
    if ([string]::IsNullOrEmpty($rollbackTargetValue)) { $rollbackTargetValue = 'auto' }
    if ($script:RollbackTargets -notcontains $rollbackTargetValue.Trim().ToLowerInvariant()) {
        [void]$errors.Add("INVALID_ARGUMENT: -RollbackTarget must be auto/upgrade/install (got '$rollbackTargetValue')")
    }
    if (-not [string]::IsNullOrEmpty($FaultPlan) -and $env:CNKI_UPGRADE_TEST_MODE -ne '1') {
        [void]$errors.Add('FAULT_INJECTION_DISALLOWED: -FaultPlan is test-only and is refused unless $env:CNKI_UPGRADE_TEST_MODE=1')
    }
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        try { $null = [System.IO.Path]::GetFullPath($OutFile) } catch {
            [void]$errors.Add("INVALID_ARGUMENT: -OutFile is not a valid path: $($_.Exception.Message)")
        }
    }
    return $errors.ToArray()
}

function Resolve-SetupPaths {
    $errors = New-Object System.Collections.ArrayList
    $script:ScriptPackageRoot = Get-SetupNormalizedPath (Split-Path -Path $script:ScriptDirectory -Parent)
    if ([string]::IsNullOrEmpty($script:PackageRoot)) {
        $script:PackageRootValue = $script:ScriptPackageRoot
    } else {
        $script:PackageRootValue = Get-SetupNormalizedPath $script:PackageRoot
        if ($null -eq $script:PackageRootValue) { [void]$errors.Add('INVALID_ARGUMENT: -PackageRoot is not a valid path') }
    }
    $script:InstallRootExplicit = -not [string]::IsNullOrEmpty($script:InstallRoot)
    if ($script:InstallRootExplicit) {
        $script:InstallRootValue = Get-SetupNormalizedPath $script:InstallRoot
        if ($null -eq $script:InstallRootValue) { [void]$errors.Add('INVALID_ARGUMENT: -InstallRoot is not a valid path') }
    } else {
        $script:InstallRootValue = $script:PackageRootValue
    }
    if ($script:ActionName -eq 'upgrade' -and -not $script:InstallRootExplicit) {
        [void]$errors.Add('INSTALL_ROOT_REQUIRED: -InstallRoot must point at the existing installation for -Action upgrade')
    }
    $dshProfile = [string]$DshProfile
    if ([string]::IsNullOrWhiteSpace($dshProfile)) { $dshProfile = 'desktop' }
    $script:Opt = @{
        Yes                    = [bool]$Yes
        DryRun                 = [bool]$DryRun
        Force                  = [bool]$Force
        AllowProductionProfile = [bool]$AllowProductionProfile
        PurgeRuntime           = [bool]$PurgeRuntime
        Offline                = [bool]$Offline
        NoToolInstall          = [bool]$NoToolInstall
        Verbose                = [bool]$Verbose
        DshHome                = [string]$DshHome
        DshProfile             = $dshProfile.Trim()
        PlanId                 = [string]$PlanId
        Transaction            = [string]$Transaction
        RollbackTarget         = ([string]$RollbackTarget).Trim().ToLowerInvariant()
        FaultPlan              = [string]$FaultPlan
    }
    if ($script:ActionName -eq 'rollback') {
        if ([string]::IsNullOrEmpty($script:Opt['RollbackTarget'])) { $script:Opt['RollbackTarget'] = 'auto' }
    }
    if (-not [string]::IsNullOrEmpty($script:PackageRootValue)) {
        $script:PortableScriptPath = Join-SetupPath $script:PackageRootValue 'tools\portable.ps1'
    }
    $script:PackageInfo = Get-SetupPackageInfo -Root $script:PackageRootValue
    $script:TargetInfo = Get-SetupTargetInfo -TargetRoot $script:InstallRootValue -PackageRootPath $script:PackageRootValue
    return $errors.ToArray()
}

function New-SetupInternalErrorDocument {
    param([string]$ActionName, [string]$Message, [string]$Detail)
    $doc = New-SetupActionDocument -ActionName $ActionName
    $checks = New-SetupCheckList
    if ([string]::IsNullOrEmpty($ActionName)) { Add-SetupCheck $checks 'tool.internal' 'FAIL' $Message }
    else { Add-SetupCheck $checks 'tool.internal' 'FAIL' $Message }
    [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 1 -Outcome 'INTERNAL_ERROR' -Refused $false -Errors @($Message))
    if (-not [string]::IsNullOrEmpty($Detail)) { Set-DocValue $doc 'internalDetail' $Detail }
    return $doc
}

# =====================================================================================
# Human report (Chinese) - printed when -Json is not used
# =====================================================================================

function Write-SetupHumanReport {
    param($Document)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('CNKI Research Portable 统一入口 setup.ps1（统一候选版 / unified candidate）')
    [void]$lines.Add('')
    [void]$lines.Add('重要说明（LEGACY 语义）:')
    [void]$lines.Add('  - tools\portable.ps1 -Action upgrade 是 LEGACY（重装/覆盖已有安装），不是安全增量升级。')
    [void]$lines.Add('  - 安全增量升级只有一条路径：tools\setup.ps1 -Action upgrade（CHECK -> PLAN -> 事务化 APPLY，可回滚）。')
    [void]$lines.Add('  - tools\portable.ps1 的 check/plan/install/uninstall/rollback 由本入口按 D8 路由复用。')
    [void]$lines.Add('')
    if ($null -eq $Document) {
        [void]$lines.Add('[FAIL] 内部错误：没有生成结果文档。')
        foreach ($l in $lines) { Write-Host $l }
        return
    }
    $action = [string](Get-DocValue $Document 'action')
    $route = [string](Get-DocValue $Document 'route')
    $installRoot = [string](Get-DocValue $Document 'installRoot')
    $packageRoot = [string](Get-DocValue $Document 'packageRoot')
    [void]$lines.Add('动作: ' + $action + '    路由: ' + $route + '    退出码: ' + [int](Get-DocValue $Document 'exitCode'))
    [void]$lines.Add('安装根: ' + $installRoot)
    [void]$lines.Add('包根  : ' + $packageRoot)
    $dshHome = [string](Get-DocValue $Document 'dshHome')
    if (-not [string]::IsNullOrEmpty($dshHome)) { [void]$lines.Add('DSH home: ' + $dshHome + '    profile: ' + [string](Get-DocValue $Document 'dshProfile')) }
    $state = [string](Get-DocValue $Document 'sourceState')
    if (-not [string]::IsNullOrEmpty($state)) {
        $line = '安装状态: ' + $state
        if (-not [string]::IsNullOrEmpty([string](Get-DocValue $Document 'sourceVersion'))) { $line = $line + '    源版本: ' + [string](Get-DocValue $Document 'sourceVersion') }
        $variant = [string](Get-DocValue $Document 'variant')
        if (-not [string]::IsNullOrEmpty($variant)) { $line = $line + '    变体: ' + $variant }
        [void]$lines.Add($line)
    }
    [void]$lines.Add('')
    $checks = @(ConvertTo-SetupCheckArray (Get-DocValue $Document 'checks'))
    if ($checks.Count -gt 0) {
        $shown = 0
        foreach ($c in $checks) {
            if ($shown -ge 80) { [void]$lines.Add('... 其余检查项略'); break }
            [void]$lines.Add('[' + [string](Get-DocValue $c 'status') + '] ' + [string](Get-DocValue $c 'id') + '  ' + [string](Get-DocValue $c 'detail'))
            $shown++
        }
        [void]$lines.Add('')
    }
    $summary = Get-DocValue $Document 'summary'
    if ($null -ne $summary) {
        [void]$lines.Add('检查汇总: PASS=' + [int](Get-DocValue $summary 'pass') + '  WARN=' + [int](Get-DocValue $summary 'warn') +
            '  FAIL=' + [int](Get-DocValue $summary 'fail') + '  NOT TESTED=' + [int](Get-DocValue $summary 'notTested') +
            '    结果: ' + [string](Get-DocValue $summary 'outcome'))
    }
    $planId = [string](Get-DocValue $Document 'planId')
    if (-not [string]::IsNullOrEmpty($planId)) { [void]$lines.Add('planId: ' + $planId) }
    if ($action -eq 'check') {
        if ($state -eq 'NOT_INSTALLED') {
            [void]$lines.Add('检测结果: NOT_INSTALLED —— 未检测到安装。下一步:')
            [void]$lines.Add('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-SetupPath $script:ScriptDirectory 'setup.ps1') + '" -Action install -InstallRoot "' + $installRoot + '" -Yes')
        } elseif ($state -eq 'RC2_CLEAN' -or $state -eq 'RC2_HOTFIXED') {
            [void]$lines.Add('检测结果: ' + $state + ' —— 标准 rc.2 安装，可以安全升级。下一步（只读）:')
            [void]$lines.Add('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-SetupPath $script:ScriptDirectory 'setup.ps1') + '" -Action plan -InstallRoot "' + $installRoot + '"')
        } elseif ($state -eq 'RC3_ALREADY_INSTALLED') {
            [void]$lines.Add('检测结果: RC3_ALREADY_INSTALLED —— 已经是 1.0.0-rc.3，无需操作（no-op）。')
        } elseif ($state -eq 'PACKAGE_INVALID') {
            [void]$lines.Add('检测结果: 安装包自身完整性失败，请重新下载/解压统一包。')
        } else {
            [void]$lines.Add('检测结果: ' + $state + ' —— 状态未知/被修改，工具拒绝自动修复或覆盖。请人工核对后重新解压到空目录（不要覆盖既有安装）。')
        }
    } elseif ($action -eq 'plan') {
        $plan = Get-DocValue $Document 'plan'
        if ($null -ne $plan) {
            $isInstallPlan = [bool](Get-DocValue $plan 'installPlan')
            if ($isInstallPlan) {
                [void]$lines.Add('全新安装计划（setup.ps1 只读自算，未委托 portable plan）:')
                foreach ($s in (Get-SetupArrayValue $plan 'steps')) { [void]$lines.Add('  ' + [string]$s) }
                $mode = [string](Get-DocValue $plan 'layoutMode')
                [void]$lines.Add('布局模式: ' + $mode)
                [void]$lines.Add('确认后执行: -Action install -InstallRoot "' + $installRoot + '" -Yes')
            } else {
                $planChangedFiles = Get-SetupArrayValue $plan 'changedFiles'
                $planEnvFiles = Get-SetupArrayValue $plan 'environmentUpdates'
                [void]$lines.Add('可执行: ' + [bool](Get-DocValue $plan 'actionable') + '    无需操作: ' + [bool](Get-DocValue $plan 'noOp') + '    变更文件: ' + $planChangedFiles.Count + '    环境文件: ' + $planEnvFiles.Count)
                $backupLocation = [string](Get-DocValue $plan 'backupLocation')
                if (-not [string]::IsNullOrEmpty($backupLocation)) { [void]$lines.Add('计划备份目录: ' + $backupLocation) }
                if ($state -eq 'RC3_ALREADY_INSTALLED' -or [bool](Get-DocValue $plan 'noOp')) {
                    [void]$lines.Add('结论: 已经是 1.0.0-rc.3，无需升级（NOOP）。')
                } else {
                    [void]$lines.Add('下一步（确认无误后）:')
                    [void]$lines.Add('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-SetupPath $script:ScriptDirectory 'setup.ps1') + '" -Action upgrade -InstallRoot "' + $installRoot + '" -PlanId ' + $planId + ' -Yes')
                }
            }
        }
    } elseif ($action -eq 'upgrade') {
        $summaryOutcome = ''
        if ($null -ne $summary) { $summaryOutcome = [string](Get-DocValue $summary 'outcome') }
        if ($summaryOutcome -eq 'NOOP_ALREADY_TARGET' -or $summaryOutcome -eq 'ALREADY_AT_TARGET') {
            [void]$lines.Add('结论: 已是目标版本 1.0.0-rc.3 —— 无操作（no-op），未写任何文件、未建事务/备份。')
        } elseif ($summaryOutcome -eq 'PLAN_READY') {
            [void]$lines.Add('结论: 只读 CHECK+PLAN 完成，尚未执行升级（未写任何文件）。')
            $nextCommand = [string](Get-DocValue $Document 'nextCommand')
            if ([string]::IsNullOrEmpty($nextCommand)) { $nextCommand = Get-SetupNextCommand -PlanIdValue $planId }
            [void]$lines.Add('下一步（确认无误后）:')
            [void]$lines.Add('  ' + $nextCommand)
        } elseif ([int](Get-DocValue $Document 'exitCode') -eq 0) {
            $txn = Get-DocValue $Document 'transaction'
            if ($null -ne $txn) {
                [void]$lines.Add('事务: ' + [string](Get-DocValue $txn 'transactionId') + '    阶段: ' + [string](Get-DocValue $txn 'phase'))
                $txnDir = [string](Get-DocValue $txn 'transactionDir')
                if (-not [string]::IsNullOrEmpty($txnDir)) { [void]$lines.Add('事务目录: ' + $txnDir) }
            }
            [void]$lines.Add('结论: 文件升级完成（事务 COMMITTED）。FILE_UPGRADE_COMPLETE=PASS；DSH_RUNTIME_ACTIVATION_VERIFIED=NOT TESTED。')
            [void]$lines.Add('下一步: 正常重新打开 DSH（不要强制结束进程，不要编辑 profile），新建会话并选择 "CNKI Research" 预设，按验收清单确认。')
        } else {
            [void]$lines.Add('结论: 升级未执行或被拒绝/失败；未覆盖用户修改的文件。请按上方检查项与错误处理。')
        }
    } elseif ($action -eq 'verify') {
        $verify = Get-DocValue $Document 'verify'
        if ($null -ne $verify) {
            [void]$lines.Add('FILE_UPGRADE_COMPLETE = ' + [string](Get-DocValue $verify 'FILE_UPGRADE_COMPLETE'))
        } else {
            [void]$lines.Add('FILE_UPGRADE_COMPLETE = ' + [string](Get-DocValue $Document 'FILE_UPGRADE_COMPLETE'))
        }
        [void]$lines.Add('DSH_RUNTIME_ACTIVATION_VERIFIED = NOT TESTED（本工具不声称运行时激活已验证）')
    } elseif ($action -eq 'status') {
        $status = Get-DocValue $Document 'status'
        if ($null -ne $status) {
            $installed = Get-DocValue $status 'installed'
            if ($null -ne $installed) {
                [void]$lines.Add('已安装版本: ' + [string](Get-DocValue $installed 'version') + '    manifest distribution: ' + [string](Get-DocValue $installed 'distributionVersion'))
            }
            $dsh = Get-DocValue $status 'dsh'
            if ($null -ne $dsh) {
                [void]$lines.Add('DSH home: ' + [string](Get-DocValue $dsh 'home') + '    profile: ' + [string](Get-DocValue $dsh 'profile') + '    引用: ' + [string](Get-DocValue $dsh 'referenceOutcome'))
                $junction = [string](Get-DocValue $dsh 'junctionTarget')
                if (-not [string]::IsNullOrEmpty($junction)) { [void]$lines.Add('junction 目标: ' + $junction) }
            }
            $txns = Get-SetupArrayValue $status 'transactions'
            if ($txns.Count -gt 0) {
                [void]$lines.Add('事务历史（新到旧）:')
                foreach ($t in $txns) { [void]$lines.Add('  ' + [string](Get-DocValue $t 'transactionId') + '  phase=' + [string](Get-DocValue $t 'phase') + '  committedAt=' + [string](Get-DocValue $t 'committedAt')) }
            } else {
                [void]$lines.Add('事务历史: 无')
            }
            $pending = Get-DocValue $status 'pendingTransaction'
            if ($null -ne $pending) { [void]$lines.Add('待处理事务: ' + [string](Get-DocValue $pending 'transactionId') + ' —— ' + [string](Get-DocValue $pending 'guidance')) }
            $lastUpgrade = Get-DocValue $status 'lastUpgrade'
            if ($null -ne $lastUpgrade) { [void]$lines.Add('最近一次升级: ' + [string](Get-DocValue $lastUpgrade 'transactionId') + '（' + [string](Get-DocValue $lastUpgrade 'committedAt') + '）') }
            $installState = Get-DocValue $status 'installState'
            if ($null -ne $installState) {
                [void]$lines.Add('安装器记录: distribution=' + [string](Get-DocValue $installState 'distribution') + '    linkMode=' + [string](Get-DocValue $installState 'linkMode') + '    installedAt=' + [string](Get-DocValue $installState 'installedAt'))
            }
        }
    } elseif ($action -eq 'rollback') {
        $rb = Get-DocValue $Document 'rollback'
        if ($null -ne $rb) {
            $before = [string](Get-DocValue $rb 'phaseBefore')
            $after = [string](Get-DocValue $rb 'phaseAfter')
            if (-not [string]::IsNullOrEmpty($before)) { [void]$lines.Add('回滚: ' + $before + ' -> ' + $after + '    恢复文件数: ' + [int](Get-DocValue $rb 'restoredCount')) }
            $backupPath = [string](Get-DocValue $rb 'backupPath')
            if (-not [string]::IsNullOrEmpty($backupPath)) { [void]$lines.Add('恢复的安装器备份: ' + $backupPath) }
        }
        $rollbackTarget = [string](Get-DocValue $Document 'rollbackTarget')
        [void]$lines.Add('回滚路由: ' + $rollbackTarget)
        if ([int](Get-DocValue $Document 'exitCode') -eq 0) {
            [void]$lines.Add('结论: 已恢复到升级前状态；备份/事务目录保留（不会删除）。')
        } else {
            [void]$lines.Add('结论: 回滚被拒绝或失败；没有覆盖用户修改过的文件。请按上方错误处理，切勿删除备份。')
        }
    } elseif ($action -eq 'install' -or $action -eq 'uninstall') {
        $portable = Get-DocValue $Document 'portable'
        if ($null -ne $portable) {
            $childOutcome = [string](Get-DocValue $portable 'outcome')
            if (-not [string]::IsNullOrEmpty($childOutcome)) { [void]$lines.Add('安装器结果: ' + $childOutcome) }
        }
        if ($action -eq 'install') {
            if ([int](Get-DocValue $Document 'exitCode') -eq 0) {
                [void]$lines.Add('结论: 安装完成。下一步: 刷新 DSH 页面、新建会话并选择 "CNKI Research" 预设；DSH_RUNTIME_ACTIVATION_VERIFIED=NOT TESTED。')
            } else {
                [void]$lines.Add('结论: 安装未完成或被拒绝；没有被静默覆盖的安装。请按上方检查项与错误处理。')
            }
        } else {
            if ([int](Get-DocValue $Document 'exitCode') -eq 0) { [void]$lines.Add('结论: 卸载完成。') }
            else { [void]$lines.Add('结论: 卸载未完成或被拒绝；请按上方检查项与错误处理。') }
        }
    }
    $nextCommand = [string](Get-DocValue $Document 'nextCommand')
    if (-not [string]::IsNullOrEmpty($nextCommand) -and $action -ne 'upgrade') { [void]$lines.Add('下一步命令: ' + $nextCommand) }
    $errors = Get-SetupArrayValue $Document 'errors'
    if ($errors.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('错误/拒绝原因:')
        $n = 0
        foreach ($e in $errors) { if ($n -ge 20) { [void]$lines.Add('  ...'); break }; [void]$lines.Add('  - ' + [string]$e); $n++ }
    }
    $warnings = Get-SetupArrayValue $Document 'warnings'
    if ($warnings.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('警告:')
        $n = 0
        foreach ($w in $warnings) { if ($n -ge 20) { [void]$lines.Add('  ...'); break }; [void]$lines.Add('  - ' + [string]$w); $n++ }
    }
    [void]$lines.Add('')
    $exitCode = [int](Get-DocValue $Document 'exitCode')
    if ($exitCode -eq 0) { [void]$lines.Add('EXIT 0: 成功（无 FAIL）。') }
    elseif ($exitCode -eq 2) { [void]$lines.Add('EXIT 2: 被拒绝 / 存在 FAIL / 冲突 / 状态未知 / 未完成。详见上方输出。') }
    else { [void]$lines.Add('EXIT 1: 工具内部错误。') }
    foreach ($l in $lines) { Write-Host $l }
}

# =====================================================================================
# main
# =====================================================================================

$script:MachineMode = ([bool]$Json) -or (-not [string]::IsNullOrWhiteSpace($OutFile))
$argumentErrors = Get-SetupArgumentErrors
if (@($argumentErrors).Count -gt 0) {
    $actionForError = ''
    if (-not [string]::IsNullOrEmpty($Action)) { $actionForError = $Action.Trim().ToLowerInvariant() }
    $doc = New-SetupActionDocument -ActionName $actionForError
    $checks = New-SetupCheckList
    foreach ($e in @($argumentErrors)) { Add-SetupCheck $checks 'cli.arguments' 'FAIL' ([string]$e) }
    [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors $argumentErrors)
    $script:FinalDocument = $doc
    $script:ExitCode = 2
} else {
    $script:ActionName = $Action.Trim().ToLowerInvariant()
    try {
        if (-not (Test-SetupEngineReady)) {
            $msg = 'ENGINE_UNAVAILABLE: ' + [string]$script:EngineLoadError
            $script:FinalDocument = New-SetupInternalErrorDocument -ActionName $script:ActionName -Message $msg -Detail ''
            $script:ExitCode = 1
        } else {
            $pathErrors = Resolve-SetupPaths
            if (@($pathErrors).Count -gt 0) {
                $doc = New-SetupActionDocument -ActionName $script:ActionName
                $checks = New-SetupCheckList
                foreach ($e in @($pathErrors)) { Add-SetupCheck $checks 'cli.arguments' 'FAIL' ([string]$e) }
                [void](Set-SetupOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors $pathErrors)
                $script:FinalDocument = $doc
                $script:ExitCode = 2
            } else {
                $doc = $null
                switch ($script:ActionName) {
                    'check' { $doc = Invoke-SetupActionCheck }
                    'plan' { $doc = Invoke-SetupActionPlan }
                    'install' { $doc = Invoke-SetupActionInstall }
                    'upgrade' { $doc = Invoke-SetupActionUpgrade }
                    'verify' { $doc = Invoke-SetupActionVerify }
                    'status' { $doc = Invoke-SetupActionStatus }
                    'rollback' { $doc = Invoke-SetupActionRollback }
                    'uninstall' { $doc = Invoke-SetupActionUninstall }
                    default { throw "unsupported action '$($script:ActionName)'" }
                }
                $doc = Complete-SetupDocument -Doc $doc -ActionName $script:ActionName
                $script:FinalDocument = $doc
                $script:ExitCode = ConvertTo-SetupExitCode (Get-DocValue $doc 'exitCode')
            }
        }
    } catch {
        $message = 'INTERNAL_ERROR: ' + $_.Exception.Message
        $detail = ''
        try { $detail = [string]$_.ScriptStackTrace } catch { $detail = '' }
        $script:FinalDocument = New-SetupInternalErrorDocument -ActionName $script:ActionName -Message $message -Detail $detail
        $script:ExitCode = 1
    }
}

# -------------------------------------------------------------------------------------
# output
# -------------------------------------------------------------------------------------
try {
    $jsonText = ConvertTo-SetupJsonText $script:FinalDocument
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        try { Write-SetupJsonFile -Path $OutFile -JsonText $jsonText } catch {
            [Console]::Error.WriteLine('failed to write -OutFile: ' + $_.Exception.Message)
            $script:ExitCode = 1
        }
    }
    if ($Json) {
        [Console]::Out.WriteLine($jsonText)
    } else {
        Write-SetupHumanReport $script:FinalDocument
    }
} catch {
    [Console]::Error.WriteLine('output failure: ' + $_.Exception.Message)
    $script:ExitCode = 1
}
exit $script:ExitCode
