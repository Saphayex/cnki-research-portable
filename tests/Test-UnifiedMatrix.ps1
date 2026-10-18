# =============================================================================
# Test-UnifiedMatrix.ps1 - master maintainer test matrix for the unified RC3
# candidate package (fresh-install + in-place RC2 upgrade from ONE package).
#
# Owner: test-dev.  Shipped in the candidate repository tests\.
#
# Scope (charter D10 groups B-H; groups A/I/J/K are covered by the verification
# suite / engine self-tests / archive verifier owned by other maintainers):
#   B  RC2_CLEAN -> unified RC3: CHECK/PLAN read-only proofs, planId gate,
#      APPLY -> installed target tree == candidate package (P + manifest.json;
#      package-only metadata NOT installed), env update, preservation, VERIFY,
#      STATUS.
#   C  RC2_HOTFIXED (both byte-level cordis variants) -> unified target.
#   D  idempotence: upgraded-unified and synthetic-unified/frozen-RC3 installs
#      are recognized as RC3_ALREADY_INSTALLED (UNIFIED / FROZEN_RC3), PLAN is a
#      no-op and APPLY (engine level) writes nothing.
#   E  UNKNOWN_OR_MODIFIED rejection (tampered/missing/mixed/VERSION/manifest/
#      layout B/package-root==install-root/reparse/user edits): CHECK/PLAN/
#      APPLY/ROLLBACK refuse, conflicts[] reported, zero writes.
#   F  ROLLBACK byte-exact RC2 restoration incl. deleting exactly the added
#      payload files + transaction-created empty dirs; conflict and corrupt
#      backup refusals; second rollback idempotent.
#   G  failure injection (-FaultPlan + CNKI_UPGRADE_TEST_MODE=1): backup /
#      staging / apply-index (incl. added-file writes) / crash recovery /
#      verify / disk-low / read-only target / corrupt transaction; no mixed
#      install, auto-restore or FAILED_MANUAL guidance, no user-data loss.
#   H  user-data protection through upgrade / failed apply / rollback, plus
#      read-only fingerprints for CHECK/PLAN/STATUS/VERIFY across states.
#
# TARGET IDENTITY IS PARAMETERIZED, NOT HARDCODED: the expected target payload
# set/hashes/counts come from the candidate package itself
# (manifest.json + upgrade-data\rc2-to-rc3.json + SHA256SUMS.txt); the frozen
# RC2 ZIP is the only source of state identity, and the frozen RC3 ZIP is used
# read-only only for FROZEN_RC3 recognition fixtures / core-equality evidence
# (NOT TESTED if unavailable on the test host).
#
# SAFETY: every test write is isolated below -WorkRoot / -EvidenceDir.
#   * never points any action at the real %USERPROFILE%\.dsh, the real
#     .cnki-mcp/profile or a production install;
#   * junctions are only removed with [System.IO.Directory]::Delete($p,$false);
#   * sandbox cleanup is refused outside -WorkRoot.
#
# Usage examples:
#   powershell -NoProfile -ExecutionPolicy Bypass -File Test-UnifiedMatrix.ps1 `
#     -Rc2Zip <frozen rc2 zip> -UnifiedZip <candidate zip>
#   ... -Filter B                  # only group B cases
#   ... -Filter 'B,D,E'            # several groups
#   ... -Case 'B4*' -KeepSandbox   # single case by name
#   ... -PackageDir <extracted candidate>   # already-extracted package
#   ... -FixtureSelfTest           # validate fixtures + oracle (no engine)
#
# Exit code: 0 = every executed case PASS (no FAIL); 2 = FAIL/missing
# prerequisites/frozen-input mismatch; 1 = harness error.
#
# Windows PowerShell 5.1 only.  UTF-8 with BOM (contains non-ASCII literals).
# =============================================================================
#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Rc2Zip,
    [string]$UnifiedZip = '',
    [string]$PackageDir = '',
    [string]$Case = '',
    [string]$Filter = '',
    [switch]$KeepSandbox,
    [string]$WorkRoot = '',
    [string]$EvidenceDir = '',
    [string]$OutDir = '',
    [string]$Rc3FrozenZip = '',
    [ValidateSet('setup', 'engine', 'auto')][string]$EngineEntry = 'setup',
    [switch]$FixtureSelfTest
)

$ErrorActionPreference = 'Stop'
$script:TestToolVersion = '1.0.0-unified'
$script:G = $null

# ===========================================================================
# Path resolution / prerequisites
# ===========================================================================

function Resolve-TestLayout {
    $testsDir = $PSScriptRoot
    $candidateRepo = [System.IO.Path]::GetFullPath((Join-Path $testsDir '..'))
    $worktree = [System.IO.Path]::GetFullPath((Join-Path $candidateRepo '..'))
    $resolvedWorkRoot = $WorkRoot
    if (-not $resolvedWorkRoot) { $resolvedWorkRoot = Join-Path $worktree 'sandbox\unified-matrix' }
    $resolvedEvidenceDir = ''
    if ($OutDir) { $resolvedEvidenceDir = $OutDir }
    elseif ($EvidenceDir) { $resolvedEvidenceDir = $EvidenceDir }
    else { $resolvedEvidenceDir = Join-Path $worktree '_evidence\tests' }
    $resolvedUnifiedZip = $UnifiedZip
    if (-not $resolvedUnifiedZip) {
        $resolvedUnifiedZip = Join-Path $worktree 'RELEASE_ASSETS_CANDIDATE\CNKI-Research-Portable-1.0.0-rc.3-unified-candidate.zip'
    }
    $resolvedRc3Frozen = $Rc3FrozenZip
    if (-not $resolvedRc3Frozen) {
        $resolvedRc3Frozen = Join-Path $worktree 'OLD_RC3_FROZEN\CNKI-Research-Portable-1.0.0-rc.3.zip'
    }
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
    $libDir = Join-Path $testsDir 'lib'
    return [pscustomobject]@{
        TestsDir      = $testsDir
        CandidateRepo = $candidateRepo
        Worktree      = $worktree
        Rc2Zip        = [System.IO.Path]::GetFullPath($Rc2Zip)
        WorkRoot      = [System.IO.Path]::GetFullPath($resolvedWorkRoot)
        EvidenceDir   = [System.IO.Path]::GetFullPath($resolvedEvidenceDir)
        UnifiedZip    = [System.IO.Path]::GetFullPath($resolvedUnifiedZip)
        Rc3FrozenZip  = [System.IO.Path]::GetFullPath($resolvedRc3Frozen)
        PackageDirArg = $PackageDir
        PsExe         = $psExe
        LibDir        = $libDir
        LibAssert     = Join-Path $libDir 'UnifiedAssert.ps1'
        LibFixtures   = Join-Path $libDir 'UnifiedFixtures.ps1'
        SetupEntry    = $null
        EngineLib     = $null
        PackageDir    = $null
    }
}

function Resolve-CandidatePackage {
    # Resolves the candidate package root the matrix runs against.
    #   * -PackageDir <dir>: use the already-extracted package directory as-is;
    #   * else: extract -UnifiedZip once under -WorkRoot\_candidate-package.
    # Read-only with respect to the ZIP; never builds, never modifies inputs.
    param([Parameter(Mandatory = $true)]$Layout)
    if ($Layout.PackageDirArg) {
        $pkg = Get-FullPath $Layout.PackageDirArg
        if (-not [System.IO.Directory]::Exists($pkg)) { throw "candidate package directory not found: $pkg" }
        return [pscustomobject]@{ PackageRoot = $pkg; FromZip = $false; ExtractDir = $pkg }
    }
    if (-not [System.IO.File]::Exists($Layout.UnifiedZip)) {
        throw "candidate ZIP not found: $($Layout.UnifiedZip). Build it first (build-dev announces build v0) or pass -PackageDir <extracted candidate>."
    }
    $extractDir = Join-Path $Layout.WorkRoot '_candidate-package'
    if ([System.IO.Directory]::Exists($extractDir)) {
        Remove-TreeJunctionSafe -Path $extractDir -AllowedRoot $Layout.WorkRoot
    }
    [void][System.IO.Directory]::CreateDirectory($extractDir)
    $written = @(Expand-ZipToDirectory -ZipPath $Layout.UnifiedZip -Destination $extractDir)
    if ($written.Count -eq 0) { throw "extracted candidate ZIP is empty: $($Layout.UnifiedZip)" }
    return [pscustomobject]@{ PackageRoot = (Get-FullPath $extractDir); FromZip = $true; ExtractDir = $extractDir }
}

function Initialize-TestRun {
    param($Layout, [string]$PackageRoot, [switch]$SkipEnginePrereqs)
    $results = New-Object System.Collections.ArrayList
    $isAdmin = $false
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }

    [void]$results.Add((Assert-Condition -Id 'prereq.powershell51' -Condition ([int]$PSVersionTable.PSVersion.Major -eq 5) `
        -PassDetail "Windows PowerShell $($PSVersionTable.PSVersion) host" -FailDetail "requires Windows PowerShell 5.1 (found $($PSVersionTable.PSVersion))" -Expected '5.x' -Actual ([string]$PSVersionTable.PSVersion)))
    [void]$results.Add((Assert-Condition -Id 'prereq.frozenRc2Zip' -Condition ([System.IO.File]::Exists($Layout.Rc2Zip)) `
        -PassDetail "frozen RC2 ZIP present (read-only): $($Layout.Rc2Zip)" -FailDetail "frozen RC2 ZIP missing: $($Layout.Rc2Zip)" -Expected 'frozen RC2 ZIP' -Actual 'ABSENT'))
    if (-not $SkipEnginePrereqs) {
        $manifestPath = Join-Path $PackageRoot 'manifest.json'
        $sumsPath = Join-Path $PackageRoot 'SHA256SUMS.txt'
        $metadataPath = Join-Path $PackageRoot 'upgrade-data\rc2-to-rc3.json'
        $setupPath = Join-Path $PackageRoot 'tools\setup.ps1'
        $enginePath = Join-Path $PackageRoot 'tools\lib\UpgradeCommon.ps1'
        [void]$results.Add((Assert-Condition -Id 'prereq.candidateManifest' -Condition ([System.IO.File]::Exists($manifestPath)) `
            -PassDetail "candidate manifest.json present: $manifestPath" -FailDetail "candidate manifest.json missing (build v0 not published yet?): $manifestPath" -Expected 'manifest.json' -Actual 'ABSENT'))
        [void]$results.Add((Assert-Condition -Id 'prereq.candidateSums' -Condition ([System.IO.File]::Exists($sumsPath)) `
            -PassDetail 'candidate SHA256SUMS.txt present' -FailDetail "candidate SHA256SUMS.txt missing (build v0 not published yet?): $sumsPath" -Expected 'SHA256SUMS.txt' -Actual 'ABSENT'))
        [void]$results.Add((Assert-Condition -Id 'prereq.candidateMetadata' -Condition ([System.IO.File]::Exists($metadataPath)) `
            -PassDetail 'candidate upgrade-data\rc2-to-rc3.json present' -FailDetail "candidate upgrade-data\rc2-to-rc3.json missing: $metadataPath" -Expected 'upgrade-data\rc2-to-rc3.json' -Actual 'ABSENT'))
        [void]$results.Add((Assert-Condition -Id 'prereq.setupEntry' -Condition ([System.IO.File]::Exists($setupPath)) `
            -PassDetail "unified entry present: $setupPath" -FailDetail "tools\setup.ps1 missing (installer-dev not landed yet?): $setupPath" -Expected 'tools\setup.ps1' -Actual 'ABSENT'))
        [void]$results.Add((Assert-Condition -Id 'prereq.engineLib' -Condition ([System.IO.File]::Exists($enginePath)) `
            -PassDetail "unified engine library present: $enginePath" -FailDetail "tools\lib\UpgradeCommon.ps1 missing (engine-dev not landed yet?): $enginePath" -Expected 'tools\lib\UpgradeCommon.ps1' -Actual 'ABSENT'))
    }
    return [pscustomobject]@{ Results = @($results.ToArray()); Admin = $isAdmin }
}

function Get-FileTreeHash {
    # Deterministic tree hash of the files below a root: sha256 over sorted
    # "rel<TAB>sha256" lines (forward-slash rel paths, LF, trailing LF).
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeRelPrefixes = @()
    )
    $rootFull = Get-FullPath $Root
    if (-not [System.IO.Directory]::Exists($rootFull)) {
        return [pscustomobject]@{ Exists = $false; FileCount = 0; Bytes = [long]0; TreeSha256 = $null }
    }
    $snapshot = @(Get-TreeSnapshot -Root $rootFull)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $total = [long]0
    foreach ($e in $snapshot) {
        if ($e.Kind -ne 'file') { continue }
        $skip = $false
        foreach ($ex in $ExcludeRelPrefixes) {
            if (-not $ex) { continue }
            $exNorm = ($ex -replace '\\', '/').Trim('/')
            if ([string]::Equals($e.Rel, $exNorm, [System.StringComparison]::OrdinalIgnoreCase) -or
                $e.Rel.StartsWith($exNorm + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
        }
        if ($skip) { continue }
        $lines.Add([string]$e.Rel + "`t" + [string]$e.Sha256)
        $total += [long]$e.Bytes
    }
    $arr = $lines.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    $text = ''
    if ($arr.Count -gt 0) { $text = ($arr -join "`n") + "`n" }
    return [pscustomobject]@{
        Exists     = $true
        FileCount  = $arr.Count
        Bytes      = $total
        TreeSha256 = (Get-Sha256Text $text)
    }
}

function Get-PackageIdentity {
    # Identity of the CANDIDATE PACKAGE under test at matrix run time, derived
    # read-only from the package bytes themselves.  No target hash/count is
    # hardcoded: every number below is recomputed from manifest.json +
    # upgrade-data\rc2-to-rc3.json + SHA256SUMS.txt.
    param(
        [Parameter(Mandatory = $true)]$Model,
        [string]$CandidateZipPath = '',
        [switch]$ExtractedFromZip
    )
    $tree = Get-FileTreeHash -Root $Model.PackageRoot
    $testsDir = $script:G.Layout.TestsDir
    $setupPath = Join-Path $Model.PackageRoot 'tools\setup.ps1'
    $engineLibPath = Join-Path $Model.PackageRoot 'tools\lib\UpgradeCommon.ps1'
    $rc3FrozenPath = $script:G.Rc3FrozenZip
    $sidecarPath = ''
    $candidateSidecar = [ordered]@{ path = $null; exists = $false; content = $null }
    if ($CandidateZipPath) {
        $sidecarPath = $CandidateZipPath + '.sha256'
        $candidateSidecar.path = $sidecarPath
        if ([System.IO.File]::Exists($sidecarPath)) {
            $candidateSidecar.exists = $true
            $candidateSidecar.content = ([System.IO.File]::ReadAllText($sidecarPath, (New-Utf8NoBom))).Trim()
        }
    }
    return [ordered]@{
        packageRoot             = $Model.PackageRoot
        packageSource           = $(if ($ExtractedFromZip) { 'extracted-from-candidate-zip' } else { 'package-dir' })
        candidateZip            = [ordered]@{
            path   = $CandidateZipPath
            bytes  = $(if ($CandidateZipPath -and [System.IO.File]::Exists($CandidateZipPath)) { (Get-Item -LiteralPath $CandidateZipPath).Length } else { $null })
            sha256 = $(if ($CandidateZipPath -and [System.IO.File]::Exists($CandidateZipPath)) { Get-Sha256File $CandidateZipPath } else { $null })
            sidecar = $candidateSidecar
        }
        packageFileCount        = $tree.FileCount
        packageTreeBytes        = $tree.Bytes
        packageTreeSha256       = $tree.TreeSha256
        manifestPath            = $Model.ManifestPath
        manifestSha256          = $Model.ManifestSha256
        manifestBytes           = $Model.ManifestBytes
        sha256SumsPath          = $Model.SumsPath
        sha256SumsSha256        = $(if ($Model.Sums) { $Model.Sums.Sha256 } else { $null })
        sha256SumsEntryCount    = $(if ($Model.Sums) { $Model.Sums.Entries.Count } else { 0 })
        upgradeDataPath         = $Model.MetadataPath
        upgradeDataSha256       = $Model.MetadataSha256
        upgradeDataBytes        = $(if ([System.IO.File]::Exists($Model.MetadataPath)) { (Get-Item -LiteralPath $Model.MetadataPath).Length } else { $null })
        payloadFileCount        = $Model.PayloadFileCount
        targetFileCount         = $Model.TargetFileCount
        changedFileCount        = $Model.ChangedFileCount
        addedFileCount          = @($Model.AddedPaths).Count
        replacedFileCount       = @($Model.ReplacedPaths).Count
        addedFiles              = @($Model.AddedPaths)
        sourceVersion           = $Model.SourceVersion
        targetVersion           = $Model.TargetVersion
        upgradeId               = $Model.UpgradeId
        upgraderVersion         = $Model.UpgraderVersion
        expectedTargetHashes    = $Model.ExpectedTargetHashes.Count
        expectedSourceHashes    = $Model.ExpectedSourceHashes.Count
        frozenRc3Anchor         = [string](Get-JsonValue $Model.SourceIdentity 'frozenRc3ManifestSha256')
        testsIdentity           = [ordered]@{
            testsDir                 = $testsDir
            testUnifiedMatrixSha256  = $(if ([System.IO.File]::Exists((Join-Path $testsDir 'Test-UnifiedMatrix.ps1'))) { Get-Sha256File (Join-Path $testsDir 'Test-UnifiedMatrix.ps1') } else { $null })
            unifiedAssertSha256      = $(if ([System.IO.File]::Exists((Join-Path $testsDir 'lib\UnifiedAssert.ps1'))) { Get-Sha256File (Join-Path $testsDir 'lib\UnifiedAssert.ps1') } else { $null })
            unifiedFixturesSha256    = $(if ([System.IO.File]::Exists((Join-Path $testsDir 'lib\UnifiedFixtures.ps1'))) { Get-Sha256File (Join-Path $testsDir 'lib\UnifiedFixtures.ps1') } else { $null })
            testsReadmeSha256        = $(if ([System.IO.File]::Exists((Join-Path $testsDir 'README.md'))) { Get-Sha256File (Join-Path $testsDir 'README.md') } else { $null })
        }
        setupEntryPoint         = $setupPath
        setupEntrySha256        = $(if ([System.IO.File]::Exists($setupPath)) { Get-Sha256File $setupPath } else { $null })
        engineLibraryPath       = $engineLibPath
        engineLibrarySha256     = $(if ([System.IO.File]::Exists($engineLibPath)) { Get-Sha256File $engineLibPath } else { $null })
        frozenRc3Zip            = [ordered]@{
            path   = $rc3FrozenPath
            exists = [System.IO.File]::Exists($rc3FrozenPath)
            sha256 = $(if ([System.IO.File]::Exists($rc3FrozenPath)) { Get-Sha256File $rc3FrozenPath } else { $null })
            role   = 'read-only evidence for FROZEN_RC3 recognition fixtures / core-equality; NOT a target-identity anchor'
        }
    }
}

function Get-TestInputsReport {
    param($Layout, $PackageIdentity = $null)
    $rc2Path = $script:G.Rc2Zip
    $rc2File = if ($rc2Path -and [System.IO.File]::Exists($rc2Path)) { Get-Item -LiteralPath $rc2Path } else { $null }
    $rc3File = if ($Layout.Rc3FrozenZip -and [System.IO.File]::Exists($Layout.Rc3FrozenZip)) { Get-Item -LiteralPath $Layout.Rc3FrozenZip } else { $null }
    $frozen = Get-FrozenIdentity
    return [ordered]@{
        rc2Zip            = $rc2Path
        rc2Bytes          = $(if ($rc2File) { $rc2File.Length } else { $null })
        rc2Sha256         = $(if ($rc2File) { Get-Sha256File $rc2Path } else { $null })
        rc2ExpectedBytes  = $frozen.Rc2ZipBytes
        rc2ExpectedSha256 = $frozen.Rc2ZipSha256
        rc3FrozenZip      = $Layout.Rc3FrozenZip
        rc3FrozenBytes    = $(if ($rc3File) { $rc3File.Length } else { $null })
        rc3FrozenSha256   = $(if ($rc3File) { Get-Sha256File $Layout.Rc3FrozenZip } else { $null })
        rc3ExpectedBytes  = $frozen.Rc3ZipBytes
        rc3ExpectedSha256 = $frozen.Rc3ZipSha256
        unifiedZip        = $Layout.UnifiedZip
        unifiedZipExists  = [System.IO.File]::Exists($Layout.UnifiedZip)
        packageDir        = $script:G.PackageRoot
        setupEntry        = $script:G.Layout.SetupEntry
        engineEntryScript = $script:G.EngineEntryScript
        engineEntryMode   = $EngineEntry
        workRoot          = $Layout.WorkRoot
        evidenceDir       = $Layout.EvidenceDir
        powershell        = "$($PSVersionTable.PSVersion)"
        windows           = [System.Environment]::OSVersion.VersionString
        isAdmin           = $script:G.Admin
        keepSandbox       = [bool]$script:G.KeepSandbox
        targetIdentity    = $PackageIdentity
    }
}

function Write-SummaryJson {
    param(
        [Parameter(Mandatory = $true)]$SummaryObject,
        [Parameter(Mandatory = $true)][string]$Directory
    )
    if (-not [System.IO.Directory]::Exists($Directory)) { [void][System.IO.Directory]::CreateDirectory($Directory) }
    $path = Join-Path $Directory 'SUMMARY.json'
    Write-JsonFile -Path $path -Value $SummaryObject -Depth 30 | Out-Null
    return $path
}

function New-NotTestedReason {
    param([string]$Case, [string]$CheckId, [string]$Reason)
    [pscustomobject]@{ Case = $Case; CheckId = $CheckId; Reason = $Reason }
}

# ===========================================================================
# Safe sandbox plumbing
# ===========================================================================

function Remove-CaseRootSafe {
    param([string]$CaseRoot)
    $allowed = $script:G.WorkRoot
    if (-not (Test-PathUnder -Child $CaseRoot -Parent $allowed)) {
        throw "refusing to delete case root outside -WorkRoot: $CaseRoot"
    }
    if ([System.IO.Directory]::Exists($CaseRoot)) {
        Remove-TreeJunctionSafe -Path $CaseRoot -AllowedRoot $allowed
    }
}

function Remove-EvidenceCaseDirSafe {
    param([string]$Dir)
    $allowed = $script:G.EvidenceDir
    if (-not (Test-PathUnder -Child $Dir -Parent $allowed)) {
        throw "refusing to delete evidence dir outside -EvidenceDir: $Dir"
    }
    if ([System.IO.Directory]::Exists($Dir)) {
        Remove-TreeJunctionSafe -Path $Dir -AllowedRoot $allowed
    }
}

# ===========================================================================
# Engine child-process invocation
# ===========================================================================

function Get-EngineEntryScriptText {
    # Test-side engine entry: dot-sources the shipped engine library (charter §6
    # public contract) and calls Invoke-UpgraderAction -Options.  This wrapper is
    # generated INTO THE SANDBOX at run time (never shipped) and exists so the
    # matrix can exercise engine-level APPLY/ROLLBACK semantics (no-op APPLY on
    # RC3_ALREADY_INSTALLED, -FaultPlan injection) that the user-facing setup.ps1
    # intentionally routes/refuses.
    @'
param(
    [Parameter(Mandatory = $true)][string]$CommonPath,
    [Parameter(Mandatory = $true)][string]$OptionsPath,
    [Parameter(Mandatory = $true)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
try {
    . $CommonPath
    $jsonOpts = [System.IO.File]::ReadAllText($OptionsPath, (New-Object System.Text.UTF8Encoding($false)))
    $obj = $jsonOpts | ConvertFrom-Json
    $options = @{}
    foreach ($p in @($obj.PSObject.Properties)) { $options[$p.Name] = $p.Value }
    $options['OutFile'] = $OutFile
    $options['Json'] = $true
    $result = Invoke-UpgraderAction -Options $options
    $doc = $null
    $exitCode = 1
    if ($result) {
        foreach ($prop in @($result.PSObject.Properties)) {
            if ($prop.Name -eq 'doc') { $doc = $prop.Value }
            if ($prop.Name -eq 'exitCode') { $exitCode = [int]$prop.Value }
        }
    }
    if ($null -eq $doc -and $result -and -not ($result.PSObject.Properties['doc'])) { $doc = $result; $exitCode = 0 }
    if ($null -ne $doc) {
        $text = ($doc | ConvertTo-Json -Depth 40)
        [System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
    }
    exit $exitCode
} catch {
    [Console]::Error.WriteLine('ENGINE_ENTRY_ERROR: ' + $_.Exception.Message)
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
'@
}

function Initialize-EngineEntryScript {
    $path = Join-Path $script:G.WorkRoot '_engine-entry.ps1'
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($path, (Get-EngineEntryScriptText), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function ConvertTo-EngineOptionsJson {
    param([hashtable]$Options, [Parameter(Mandatory = $true)][string]$OutPath)
    $ordered = [ordered]@{}
    foreach ($key in @($Options.Keys | Sort-Object)) { $ordered[[string]$key] = $Options[$key] }
    Write-JsonFile -Path $OutPath -Value $ordered -Depth 10 | Out-Null
    return $OutPath
}

function New-ChildProcessInvocation {
    # Runs one child powershell.exe with captured stdout/stderr into the case
    # out dir, and returns a structured Run object (exit code, JSON doc, paths).
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$Splat,
        [string]$OutFile = '',
        [switch]$TestMode,
        [hashtable]$ChildEnv = @{}
    )
    $script:G.InvokeCounter++
    $slug = ($Label -replace '[^A-Za-z0-9]+', '-')
    $baseName = ('{0:d3}-{1}' -f $script:G.InvokeCounter, $slug)
    $stdoutFile = Join-Path $Ctx.OutDir ($baseName + '.stdout.txt')
    $stderrFile = Join-Path $Ctx.OutDir ($baseName + '.stderr.txt')
    $prevTestMode = [System.Environment]::GetEnvironmentVariable('CNKI_UPGRADE_TEST_MODE', 'Process')
    $prevEnv = @{}
    $stdoutText = ''
    $exitCode = -1
    $startedAt = Get-Date
    try {
        foreach ($k in $ChildEnv.Keys) {
            $prevEnv[$k] = [System.Environment]::GetEnvironmentVariable($k, 'Process')
            [System.Environment]::SetEnvironmentVariable($k, [string]$ChildEnv[$k], 'Process')
        }
        if ($TestMode) { $env:CNKI_UPGRADE_TEST_MODE = '1' }
        else { Remove-Item Env:CNKI_UPGRADE_TEST_MODE -ErrorAction SilentlyContinue }
        $stdoutText = (& $script:G.PsExe @Splat 2> $stderrFile | Out-String)
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = -1 }
    } catch {
        $exitCode = -1
        $stdoutText = "HARNESS: child invocation failed: $($_.Exception.Message)"
    } finally {
        if ($null -ne $prevTestMode) { $env:CNKI_UPGRADE_TEST_MODE = $prevTestMode }
        else { Remove-Item Env:CNKI_UPGRADE_TEST_MODE -ErrorAction SilentlyContinue }
        foreach ($k in $ChildEnv.Keys) {
            if ($null -ne $prevEnv[$k]) { [System.Environment]::SetEnvironmentVariable($k, $prevEnv[$k], 'Process') }
            else { [System.Environment]::SetEnvironmentVariable($k, $null, 'Process') }
        }
    }
    $duration = ((Get-Date) - $startedAt).TotalSeconds
    [System.IO.File]::WriteAllText($stdoutFile, $stdoutText, (New-Utf8NoBom))
    if (-not (Test-Path -LiteralPath $stderrFile)) { [System.IO.File]::WriteAllText($stderrFile, '', (New-Utf8NoBom)) }
    $json = $null
    $jsonError = $null
    if ($OutFile -and (Test-Path -LiteralPath $OutFile)) {
        try { $json = Read-JsonFile $OutFile } catch { $jsonError = $_.Exception.Message }
    }
    $envRecord = @{}
    foreach ($k in $ChildEnv.Keys) { $envRecord[$k] = [string]$ChildEnv[$k] }
    if ($TestMode) { $envRecord['CNKI_UPGRADE_TEST_MODE'] = '1' }
    Add-CaseCommand -Context $Ctx -Label $Label -Executable $script:G.PsExe -Arguments $Splat -ExitCode ([int]$exitCode) `
        -StdoutPath $stdoutFile -StderrPath $stderrFile -JsonPath $(if ($OutFile -and (Test-Path -LiteralPath $OutFile)) { $OutFile } else { '' }) `
        -Environment $envRecord | Out-Null
    $stderrText = ''
    try { $stderrText = [System.IO.File]::ReadAllText($stderrFile, (New-Utf8NoBom)) } catch { }
    return [pscustomobject]@{
        Label         = $Label
        ExitCode      = [int]$exitCode
        Stdout        = $stdoutText
        Stderr        = $stderrText
        StdoutPath    = $stdoutFile
        StderrPath    = $stderrFile
        OutFile       = $OutFile
        OutFileExists = ($OutFile -and (Test-Path -LiteralPath $OutFile))
        Json          = $json
        JsonError     = $jsonError
        Arguments     = $Splat
        DurationSec   = [Math]::Round($duration, 2)
        TestMode      = [bool]$TestMode
        ChildEnv      = $ChildEnv
        Entry         = ''
    }
}

function Invoke-Engine {
    # Invokes the system under test as an isolated child powershell.exe.
    #   Harness action -> shipped entry point (installer-dev contract, 2026-10-18):
    #     check|plan|verify|status     -> setup.ps1 -Action <same> (read-only user path)
    #     apply                        -> setup.ps1 -Action upgrade -PlanId <id> -Yes
    #     apply-noop                   -> setup.ps1 -Action upgrade -Yes  (RC3 => exit 0 NOOP_ALREADY_TARGET, zero writes)
    #     rollback                     -> setup.ps1 -Action rollback -Transaction <id> -RollbackTarget upgrade -Yes
    #     apply-engine / rollback-engine -> test-side engine entry (dot-sources
    #        tools\lib\UpgradeCommon.ps1 and calls Invoke-UpgraderAction), used for
    #        engine-unit-level APPLY/ROLLBACK evidence only.
    #   -EngineEntry engine forces the engine entry for every action (diagnostic
    #   mode); the default 'setup' exercises the shipped user-facing CLI.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][ValidateSet('check', 'plan', 'verify', 'status', 'apply', 'apply-noop', 'rollback', 'apply-engine', 'rollback-engine', 'check-engine', 'plan-engine', 'verify-engine', 'status-engine')][string]$Action,
        [hashtable]$Params = @{},
        [switch]$TestMode,
        [switch]$OmitYes,
        [string]$Label = '',
        [string]$InstallRoot = '',
        [string]$DshHome = '',
        [string]$PackageRoot = '',
        [hashtable]$ChildEnv = @{}
    )
    $fixture = $Ctx.Fixture
    $entry = 'setup'
    $setupAction = $Action
    if ($Action -like '*-engine') { $entry = 'engine' }
    if ($EngineEntry -eq 'engine') { $entry = 'engine' }
    if ($entry -eq 'setup') {
        if (-not $script:G.Layout.SetupEntry -or -not [System.IO.File]::Exists($script:G.Layout.SetupEntry)) { throw "Invoke-Engine: setup.ps1 not found: $($script:G.Layout.SetupEntry)" }
        switch ($Action) {
            'apply' { $setupAction = 'upgrade' }
            'apply-noop' { $setupAction = 'upgrade' }
            'rollback' { $setupAction = 'rollback' }
        }
    } else {
        if (-not $script:G.Layout.EngineLib -or -not [System.IO.File]::Exists($script:G.Layout.EngineLib)) { throw "Invoke-Engine: engine library not found: $($script:G.Layout.EngineLib)" }
    }
    $installToUse = if ($InstallRoot) { $InstallRoot } elseif ($fixture) { $fixture.InstallRoot } else { throw 'Invoke-Engine: no install root' }
    $dshToUse = if ($DshHome) { $DshHome } elseif ($fixture) { $fixture.DshHome } else { throw 'Invoke-Engine: no DSH home' }
    $packageToUse = if ($PackageRoot) { $PackageRoot } elseif ($script:G.PackageRoot) { $script:G.PackageRoot } else { throw 'Invoke-Engine: no package root' }
    if (-not $Label) { $Label = $Action }
    $script:G.InvokeCounter++
    $slug = ($Label -replace '[^A-Za-z0-9]+', '-')
    $baseName = ('{0:d3}-{1}-{2}' -f $script:G.InvokeCounter, ($Action -replace '[^A-Za-z0-9]+', ''), $slug)
    $outFile = Join-Path $Ctx.OutDir ($baseName + '.json')
    $paramBag = @{}
    foreach ($k in $Params.Keys) { $paramBag[$k] = $Params[$k] }
    if ($Action -eq 'apply-noop') { $paramBag['Yes'] = $true }
    elseif (-not $OmitYes) {
        if ($Action -eq 'apply' -or $Action -eq 'rollback' -or $Action -eq 'apply-engine' -or $Action -eq 'rollback-engine') { $paramBag['Yes'] = $true }
    }
    if ($Action -eq 'rollback') { if (-not $paramBag.ContainsKey('RollbackTarget')) { $paramBag['RollbackTarget'] = 'upgrade' } }

    $argv = New-Object System.Collections.ArrayList
    if ($entry -eq 'setup') {
        foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:G.Layout.SetupEntry,
                         '-Action', $setupAction, '-PackageRoot', $packageToUse,
                         '-InstallRoot', $installToUse, '-DshHome', $dshToUse,
                         '-DshProfile', $(if ($fixture) { $fixture.Profile } else { 'desktop' }),
                         '-Json', '-OutFile', $outFile)) {
            [void]$argv.Add([string]$a)
        }
        $allowed = @('PlanId', 'Yes', 'Transaction', 'RollbackTarget', 'FaultPlan', 'DryRun', 'Force', 'AllowProductionProfile', 'Offline', 'NoToolInstall')
        foreach ($key in @($paramBag.Keys | Sort-Object)) {
            if ($allowed -notcontains $key) { continue }
            $value = $paramBag[$key]
            if ($value -is [bool]) { if ($value) { [void]$argv.Add('-' + [string]$key) }; continue }
            if ($null -ne $value -and [string]$value -ne '') { [void]$argv.Add('-' + [string]$key); [void]$argv.Add([string]$value) }
        }
    } else {
        $wrapper = $script:G.EngineEntryScript
        $optionsPath = Join-Path $Ctx.OutDir ($baseName + '.options.json')
        $engineAction = $Action
        if ($Action -like '*-engine') { $engineAction = $Action.Substring(0, $Action.Length - 7) }
        $engineOptions = @{
            Action      = $engineAction
            InstallRoot = $installToUse
            PackageRoot = $packageToUse
            DshHome     = $dshToUse
            DshProfile  = $(if ($fixture) { $fixture.Profile } else { 'desktop' })
            Json        = $true
            OutFile     = $outFile
        }
        foreach ($k in $paramBag.Keys) { $engineOptions[$k] = $paramBag[$k] }
        [void](ConvertTo-EngineOptionsJson -Options $engineOptions -OutPath $optionsPath)
        Add-CaseArtifact -Context $Ctx -Path $optionsPath -Label "$Label engine options" | Out-Null
        foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
                         '-CommonPath', $script:G.Layout.EngineLib, '-OptionsPath', $optionsPath, '-OutFile', $outFile)) {
            [void]$argv.Add([string]$a)
        }
    }
    $run = New-ChildProcessInvocation -Ctx $Ctx -Label ('{0}-{1}' -f $entry, $Label) -Splat @($argv.ToArray()) -OutFile $outFile -TestMode:$TestMode -ChildEnv $ChildEnv
    $run | Add-Member -NotePropertyName Entry -NotePropertyValue $entry -Force
    $run | Add-Member -NotePropertyName Action -NotePropertyValue $Action -Force
    return $run
}

function Invoke-EngineAction {
    # Convenience wrapper: default params per action + default entry point.
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Action,
        [hashtable]$Extra = @{},
        [switch]$TestMode,
        [string]$Label = ''
    )
    $params = @{}
    foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
    return Invoke-Engine -Ctx $Ctx -Action $Action -Params $params -TestMode:$TestMode -Label $Label
}

# ===========================================================================
# Case fixtures / assertion convenience wrappers
# ===========================================================================

function New-CaseFixture {
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [string]$Variant = 'clean',
        [string]$FixtureRoot = ''
    )
    $root = if ($FixtureRoot) { $FixtureRoot } else { $Ctx.SandboxRoot }
    $Ctx.SandboxRoot = $root
    $fixture = New-UnifiedSandbox -Root $root -Rc2Zip $script:G.Rc2Zip -PackageDir $script:G.PackageRoot `
        -Rc3FrozenZip $script:G.Rc3FrozenZip -Variant $Variant -CaseName $Ctx.Case -Force
    $Ctx.Fixture = $fixture
    Add-CaseArtifact -Context $Ctx -Path $fixture.FingerprintFile -Label 'fixture fingerprint' | Out-Null
    return $fixture
}

function Get-SandboxSnapshot {
    param([Parameter(Mandatory = $true)]$Fixture)
    return @(Get-TreeSnapshot -Root $Fixture.Root)
}

function Get-InstallSnapshot {
    param([Parameter(Mandatory = $true)]$Fixture)
    return @(Get-TreeSnapshot -Root $Fixture.InstallRoot)
}

function Assert-JsonContains {
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Token,
        [switch]$MustContain,
        [string]$Label = ''
    )
    $jsonText = ''
    if ($null -ne $Run.Json) { $jsonText = ($Run.Json | ConvertTo-Json -Depth 30) }
    $inJson = $jsonText.Contains($Token)
    $inStdout = ($Run.Stdout -as [string]) -and $Run.Stdout.Contains($Token)
    $found = $inJson -or $inStdout
    if (-not $MustContain) { $MustContain = $true }
    $detail = if ($found) { "engine output mentions '$Token' ($Label)" }
              else { "engine output does NOT mention '$Token' ($Label); JSON: $(Limit-Text $jsonText 600); stdout: $(Limit-Text $Run.Stdout 400)" }
    return Assert-Condition -Id $Id -Condition $found -PassDetail $detail -FailDetail $detail -Expected $Token -Actual ''
}

function Get-RunTransactionId {
    param([Parameter(Mandatory = $true)]$Ctx, [Parameter(Mandatory = $true)]$Run, [switch]$AllowDiscovery)
    $id = Get-JsonValue $Run.Json 'transaction.transactionId'
    if ($id) { return [string]$id }
    if ($AllowDiscovery) {
        $txns = @(Get-TransactionIds -InstallRoot $Ctx.Fixture.InstallRoot)
        if ($txns.Count -eq 1) { return [string]$txns[0] }
        if ($txns.Count -gt 1) { return [string]$txns[$txns.Count - 1] }
    }
    return $null
}

function Assert-InstallRestoredToPre {
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$PreInstallSnapshot
    )
    return Assert-TreeMatchesSnapshot -Id $Id -Root $Fixture.InstallRoot -ExpectedSnapshot $PreInstallSnapshot -Label 'install tree vs pre-upgrade snapshot'
}

function Assert-NoTargetClaim {
    # Asserts the install does NOT claim the unified target state: VERSION and
    # the installed manifest.json must still be the frozen RC2 identity.
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Fixture,
        [string]$ExpectedVersion = ''
    )
    if (-not $ExpectedVersion) { $ExpectedVersion = $script:G.SourceVersion }
    $frozenIdentity = Get-FrozenIdentity
    $problems = New-Object System.Collections.ArrayList
    $versionFile = Join-Path $Fixture.InstallRoot 'VERSION'
    if (-not [System.IO.File]::Exists($versionFile)) { [void]$problems.Add('VERSION missing') }
    else {
        $trimmed = ([System.IO.File]::ReadAllText($versionFile, (New-Utf8NoBom))).Trim()
        if ($trimmed -ne $ExpectedVersion) { [void]$problems.Add("VERSION='$trimmed' expected '$ExpectedVersion'") }
    }
    $manifestFile = Join-Path $Fixture.InstallRoot 'manifest.json'
    if (-not [System.IO.File]::Exists($manifestFile)) { [void]$problems.Add('manifest.json missing') }
    else {
        $sha = Get-Sha256File $manifestFile
        $expectedManifest = if ($ExpectedVersion -eq $frozenIdentity.Rc2Version) { $frozenIdentity.Rc2ManifestSha256 } else { $script:G.PackageModel.ManifestSha256 }
        if ($sha -ne $expectedManifest) { [void]$problems.Add("manifest.json sha=$sha expected=$expectedManifest") }
    }
    $envStateFile = Join-Path $Fixture.InstallRoot '_portable\install-state.json'
    if ([System.IO.File]::Exists($envStateFile)) {
        try {
            $stateDoc = Read-JsonFile $envStateFile
            $dist = [string](Get-JsonValue $stateDoc 'distribution')
            if ($dist -ne $ExpectedVersion) { [void]$problems.Add("install-state.json distribution='$dist' expected '$ExpectedVersion'") }
        } catch { [void]$problems.Add('install-state.json unparsable') }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "install does not claim the unified target: VERSION=$ExpectedVersion + manifest hash match + env distribution match" } else { 'install claims/mixes version state: ' + ($problems -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected "VERSION=$ExpectedVersion" -Actual $problems
}

function Assert-TransactionCommitted {
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)]$Fixture
    )
    return Assert-TransactionPhase -Id $Id -InstallRoot $Fixture.InstallRoot -TransactionId $TransactionId -ExpectedPhase @('COMMITTED')
}

function Assert-EnginePlanFields {
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Fixture
    )
    $model = $script:G.PackageModel
    $results = New-Object System.Collections.ArrayList
    [void]$results.Add((Assert-Condition -Id "$Prefix.planIdFormat" -Condition ((Get-JsonValue $Run.Json 'planId') -match '^[0-9a-f]{64}$') `
        -PassDetail 'planId is lowercase 64-hex' -FailDetail "planId invalid: '$(Get-JsonValue $Run.Json 'planId')'" -Expected '64 lowercase hex' -Actual (Get-JsonValue $Run.Json 'planId')))
    [void]$results.Add((Assert-EngineJsonValue -Id "$Prefix.actionable" -Run $Run -Path 'plan.actionable' -Expected $true))
    $changedFiles = @(Get-JsonValue $Run.Json 'plan.changedFiles')
    [void]$results.Add((Assert-Condition -Id "$Prefix.changedFileCount" -Condition ($changedFiles.Count -eq $model.ChangedFileCount) `
        -PassDetail "plan lists $($model.ChangedFileCount) changed files (metadata-derived: 15+m replaces + 8 adds + manifest.json)" `
        -FailDetail "plan.changedFiles count=$($changedFiles.Count) expected $($model.ChangedFileCount) (candidate metadata)" -Expected $model.ChangedFileCount -Actual $changedFiles.Count))
    $planPaths = @($changedFiles | ForEach-Object { ConvertTo-NormalizedRelPath ([string]$_.path) } | Sort-Object)
    $expectedPaths = @($model.ChangedPaths | Sort-Object)
    [void]$results.Add((Assert-Condition -Id "$Prefix.changedFileSet" -Condition (Test-StringSetEqual -Left $planPaths -Right $expectedPaths) `
        -PassDetail "plan.changedFiles set == candidate metadata changedFiles set" -FailDetail "plan.changedFiles set differs from metadata (plan=$($planPaths.Count) metadata=$($expectedPaths.Count); missing=$( (@(Get-SetDifference -Left $expectedPaths -Right $planPaths) | Select-Object -First 10) -join ',' ); extra=$( (@(Get-SetDifference -Left $planPaths -Right $expectedPaths) | Select-Object -First 10) -join ',' ))" `
        -Expected "metadata set ($($expectedPaths.Count))" -Actual $planPaths.Count))
    $addedPlanned = @($changedFiles | Where-Object { [string]$_.operation -eq 'add' } | ForEach-Object { ConvertTo-NormalizedRelPath ([string]$_.path) } | Sort-Object)
    $expectedAdded = @($model.AddedPaths | Sort-Object)
    [void]$results.Add((Assert-Condition -Id "$Prefix.addedFiles" -Condition (Test-StringSetEqual -Left $addedPlanned -Right $expectedAdded) `
        -PassDetail "plan lists exactly the $($expectedAdded.Count) operation:add (new) payload files" `
        -FailDetail "plan added-file set differs: plan=[$($addedPlanned -join ', ')] expected=[$($expectedAdded -join ', ')]" -Expected $expectedAdded -Actual $addedPlanned))
    $addedCount = Get-JsonValue $Run.Json 'plan.addedFileCount'
    if ($null -ne $addedCount) {
        [void]$results.Add((Assert-Condition -Id "$Prefix.addedFileCount" -Condition ([int]$addedCount -eq $expectedAdded.Count) `
            -PassDetail "plan.addedFileCount=$addedCount matches the candidate metadata added set" -FailDetail "plan.addedFileCount=$addedCount expected $($expectedAdded.Count)" -Expected $expectedAdded.Count -Actual $addedCount))
    }
    $backupLocation = [string](Get-JsonValue $Run.Json 'plan.backupLocation')
    if (-not $backupLocation) { $backupLocation = [string](Get-JsonValue $Run.Json 'plan.backup.plannedPath') }
    $backupOk = $backupLocation -and ($backupLocation.Contains('_portable\upgrades') -or $backupLocation.Contains('_portable/upgrades'))
    [void]$results.Add((Assert-Condition -Id "$Prefix.backupLocation" -Condition $backupOk `
        -PassDetail "plan plans backup under _portable\upgrades: $backupLocation" -FailDetail "plan backup location missing/incorrect: '$backupLocation'" -Expected '<install>\_portable\upgrades\<id>\backup' -Actual $backupLocation))
    $conflicts = @(Get-JsonValue $Run.Json 'plan.conflicts')
    $conflictsOk = ($null -eq (Get-JsonValue $Run.Json 'plan.conflicts')) -or ($conflicts.Count -eq 0)
    [void]$results.Add((Assert-Condition -Id "$Prefix.noConflicts" -Condition $conflictsOk -PassDetail 'plan reports no conflicts for a clean/hotfixed RC2 state' -FailDetail "plan reports conflicts: $($conflicts.Count)" -Expected 'none' -Actual $conflicts.Count))
    # Every planned changed path must carry the candidate package target hash
    # (independent oracle cross-check; hashSource entries are resolved at runtime
    # by the engine, so the plan must expose the resolved targetSha256).
    $problems = New-Object System.Collections.ArrayList
    foreach ($item in $changedFiles) {
        $path = ConvertTo-NormalizedRelPath ([string]$item.path)
        if (-not $model.TargetMap.ContainsKey($path)) { [void]$problems.Add("planned path is not a candidate target file: $path"); continue }
        $expectedSha = $model.TargetMap[$path].Sha256
        $actualSha = ([string]$item.targetSha256).ToLowerInvariant()
        if ($actualSha -ne $expectedSha) { [void]$problems.Add("targetSha256 mismatch for $path (plan=$actualSha package=$expectedSha)") }
    }
    [void]$results.Add((Assert-Condition -Id "$Prefix.targetHashes" -Condition ($problems.Count -eq 0) `
        -PassDetail "all $($changedFiles.Count) planned targetSha256 values match the candidate package target bytes" `
        -FailDetail ('plan target hash problems: ' + (($problems | Select-Object -First 15) -join '; ')) -Expected 'candidate package target hashes' -Actual $problems))
    if ($null -ne (Get-JsonValue $Run.Json 'plan.requiresDshExit')) {
        [void]$results.Add((Assert-EngineJsonValue -Id "$Prefix.requiresDshExit" -Run $Run -Path 'plan.requiresDshExit' -Expected $false))
    }
    return @($results.ToArray())
}

# ===========================================================================
# Case helpers: setup.ps1 / engine document adapters
# ===========================================================================

function Get-DocSourceState {
    # setup.ps1 exposes both `state` and the engine's `sourceState`; accept either.
    param([AllowNull()]$Json)
    $state = [string](Get-JsonValue $Json 'sourceState')
    if (-not $state) { $state = [string](Get-JsonValue $Json 'state') }
    return $state
}

function Assert-EngineState {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $actual = Get-DocSourceState -Json $Run.Json
    $ok = ($actual -eq $Expected)
    $detail = if ($ok) { "sourceState=$actual" } else { "sourceState='$actual' expected '$Expected'" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected $Expected -Actual $actual
}

function Assert-EngineOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string[]]$Expected
    )
    $actual = [string](Get-JsonValue $Run.Json 'summary.outcome')
    if (-not $actual) { $actual = [string](Get-JsonValue $Run.Json 'outcome') }
    $ok = ($Expected -contains $actual)
    $detail = if ($ok) { "summary.outcome=$actual" } else { "summary.outcome='$actual' expected one of [$($Expected -join ', ')]" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected $Expected -Actual $actual
}

function Assert-EngineRoute {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $actual = [string](Get-JsonValue $Run.Json 'route')
    if (-not $actual) {
        return New-AssertResult -Id $Id -Status 'NOT TESTED' -Detail "engine/setup document has no route field (old build); route='$Expected' not asserted"
    }
    $ok = ($actual -eq $Expected)
    $detail = if ($ok) { "route=$actual" } else { "route='$actual' expected '$Expected'" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected $Expected -Actual $actual
}

function Assert-FileUpgradeComplete {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $actual = [string](Get-JsonValue $Run.Json 'verify.FILE_UPGRADE_COMPLETE')
    if (-not $actual) { $actual = [string](Get-JsonValue $Run.Json 'fileUpgradeComplete') }
    if (-not $actual) {
        $outcome = Get-FileUpgradeOutcome -Json $Run.Json
        $actual = $outcome.Outcome
    }
    $ok = ([string]::Equals($actual, $Expected, [System.StringComparison]::OrdinalIgnoreCase))
    $detail = if ($ok) { "FILE_UPGRADE_COMPLETE=$actual" } else { "FILE_UPGRADE_COMPLETE='$actual' expected '$Expected'" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected $Expected -Actual $actual
}

function Assert-RuntimeActivationNotTested {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run
    )
    $token = [string](Get-JsonValue $Run.Json 'verify.DSH_RUNTIME_ACTIVATION_VERIFIED')
    if (-not $token) { $token = [string](Get-JsonValue $Run.Json 'DSH_RUNTIME_ACTIVATION_VERIFIED') }
    if (-not $token) { $token = [string](Get-JsonValue $Run.Json 'runtimeActivation') }
    $ok = ($token -eq 'NOT TESTED')
    $detail = if ($ok) { 'DSH_RUNTIME_ACTIVATION_VERIFIED=NOT TESTED (file-level matrix only)' } else { "runtime activation token='$token' (must be NOT TESTED)" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'NOT TESTED' -Actual $token
}

function Assert-NoWritesAndNoTransaction {
    # Combined read-only proof: whole-sandbox fingerprint identical + no new txn.
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Before,
        [Parameter(Mandatory = $true)]$Fixture,
        [string[]]$BeforeTxnIds = @()
    )
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id "$Prefix.noWrites" -Before $Before -After (Get-SandboxSnapshot $Fixture) -Label 'whole-sandbox fingerprint') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id "$Prefix.noTxn" -InstallRoot $Fixture.InstallRoot -BeforeIds $BeforeTxnIds) | Out-Null
}


# ===========================================================================
# Case runner + summary aggregation
# ===========================================================================

function Copy-CaseArtifactsToEvidence {
    param([Parameter(Mandatory = $true)]$Ctx)
    $caseEvidenceDir = Join-Path $script:G.EvidenceDir $Ctx.Case
    Remove-EvidenceCaseDirSafe -Dir $caseEvidenceDir
    [void][System.IO.Directory]::CreateDirectory($caseEvidenceDir)
    $outDest = Join-Path $caseEvidenceDir 'out'
    if ([System.IO.Directory]::Exists($Ctx.OutDir)) {
        Copy-DirectoryFilesPlain -Source $Ctx.OutDir -Destination $outDest | Out-Null
    }
    # transaction.json evidence (small, useful even after sandbox cleanup)
    if ($Ctx.Fixture -and $Ctx.Fixture.StateDir -and [System.IO.Directory]::Exists($Ctx.Fixture.StateDir)) {
        foreach ($txn in @(Get-TransactionDirs -InstallRoot $Ctx.Fixture.InstallRoot)) {
            $dest = Join-Path $caseEvidenceDir ("txn\" + $txn.Name)
            [void][System.IO.Directory]::CreateDirectory($dest)
            $txnFile = Join-Path $txn.FullName 'transaction.json'
            if ([System.IO.File]::Exists($txnFile)) { [System.IO.File]::Copy($txnFile, (Join-Path $dest 'transaction.json'), $true) }
        }
    }
    if ($Ctx.Fixture -and $Ctx.Fixture.FingerprintFile -and [System.IO.File]::Exists($Ctx.Fixture.FingerprintFile)) {
        $dest = Join-Path $caseEvidenceDir 'fixture-fingerprint.json'
        [System.IO.File]::Copy($Ctx.Fixture.FingerprintFile, $dest, $true)
    }
    # remap artifact paths from sandbox/work to the copied evidence location
    $remap = {
        param([string]$Path)
        if (-not $Path) { return $Path }
        if ($Ctx.OutDir -and $Path.StartsWith($Ctx.OutDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $Path.Substring($Ctx.OutDir.Length).TrimStart('\', '/')
            return (Join-Path $outDest $rel)
        }
        if ($Path -match '\\_portable\\upgrades\\([^\\]+)\\transaction\.json$') {
            return (Join-Path (Join-Path $caseEvidenceDir 'txn') ($matches[1] + '\transaction.json'))
        }
        if ($Ctx.Fixture -and $Ctx.Fixture.FingerprintFile -and [string]::Equals($Path, $Ctx.Fixture.FingerprintFile, [System.StringComparison]::OrdinalIgnoreCase)) {
            return (Join-Path $caseEvidenceDir 'fixture-fingerprint.json')
        }
        return $Path
    }
    foreach ($artifact in @($Ctx.Artifacts.ToArray())) { $artifact.Path = (& $remap $artifact.Path) }
    foreach ($command in @($Ctx.Commands.ToArray())) {
        $command.StdoutPath = (& $remap $command.StdoutPath)
        $command.StderrPath = (& $remap $command.StderrPath)
        $command.JsonPath = (& $remap $command.JsonPath)
    }
    return $caseEvidenceDir
}

function Invoke-MatrixCase {
    param([Parameter(Mandatory = $true)]$Entry)
    $caseRoot = Join-Path $script:G.WorkRoot $Entry.Name
    Remove-CaseRootSafe -CaseRoot $caseRoot
    [void][System.IO.Directory]::CreateDirectory($caseRoot)
    $ctx = New-CaseContext -Case $Entry.Name -Description $Entry.Description -CaseRoot $caseRoot `
        -SandboxRoot (Join-Path $caseRoot 'sandbox') -OutDir (Join-Path $caseRoot 'out')
    [void][System.IO.Directory]::CreateDirectory($ctx.OutDir)
    Write-Host ''
    Write-Host "=== $($Entry.Name) === " -ForegroundColor Cyan
    Write-Host "    $($Entry.Description)"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Entry.Fn -Ctx $ctx
    } catch {
        $message = $_.Exception.Message
        if ($message -like 'LONG_PATH_UNSUPPORTED*') {
            Add-CaseCheck $ctx (New-AssertResult -Id "$($Entry.Name).longPathSupport" -Status 'NOT TESTED' -Detail $message) | Out-Null
        } else {
            $stack = ($_.ScriptStackTrace -as [string])
            Add-CaseCheck $ctx (New-AssertResult -Id "$($Entry.Name).caseException" -Status FAIL `
                -Detail ("case threw: $message" + $(if ($stack) { "`n$stack" } else { '' }))) | Out-Null
        }
    }
    $stopwatch.Stop()
    # ensure every case has at least one executed assertion
    if ($ctx.Checks.Count -eq 0) {
        Add-CaseCheck $ctx (New-AssertResult -Id "$($Entry.Name).executed" -Status FAIL -Detail 'case produced no assertions (harness defect)') | Out-Null
    }
    Copy-CaseArtifactsToEvidence -Ctx $ctx | Out-Null
    $evidence = Write-CaseEvidence -Context $ctx -EvidenceDir $script:G.EvidenceDir
    $summary = $evidence.Summary
    $summary.DurationSec = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    $summary | Add-Member -NotePropertyName EvidencePath -NotePropertyValue $evidence.Path -Force
    $summary | Add-Member -NotePropertyName SandboxKept -NotePropertyValue ([bool]$script:G.KeepSandbox) -Force
    $summary | Add-Member -NotePropertyName Group -NotePropertyValue ([string]$Entry.Group) -Force
    if (-not $script:G.KeepSandbox) {
        try { Remove-CaseRootSafe -CaseRoot $caseRoot } catch { Write-Host "  WARN cleanup failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    $color = switch ($summary.Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        default { 'Yellow' }
    }
    Write-Host ("  -> {0} ({1} checks: {2} pass / {3} fail / {4} warn / {5} n/t) in {6}s" -f $summary.Status, $summary.Summary.total, $summary.Summary.pass, $summary.Summary.fail, $summary.Summary.warn, $summary.Summary.notTested, $summary.DurationSec) -ForegroundColor $color
    return $summary
}

function Get-EffectiveCaseSelection {
    $selection = ''
    if ($Case) { $selection = $Case }
    elseif ($Filter) { $selection = $Filter }
    else { $selection = '*' }
    if ($selection -match '^[A-H]([ ,;+]*[A-H])*$') {
        $letters = New-Object System.Collections.ArrayList
        foreach ($m in [regex]::Matches($selection, '[A-H]')) { if (-not $letters.Contains($m.Value)) { [void]$letters.Add($m.Value) } }
        return [pscustomobject]@{ Mode = 'group'; Letters = @($letters.ToArray()); Text = $selection }
    }
    return [pscustomobject]@{ Mode = 'wildcard'; Letters = @(); Pattern = $selection; Text = $selection }
}

function Select-MatrixCases {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Registry)
    $selection = Get-EffectiveCaseSelection
    if ($selection.Mode -eq 'group') {
        $picked = New-Object System.Collections.ArrayList
        foreach ($entry in $Registry) {
            if ($selection.Letters -contains [string]$entry.Group) { [void]$picked.Add($entry) }
        }
        return @($picked.ToArray())
    }
    return @($Registry | Where-Object { $_.Name -like $selection.Pattern })
}

function Invoke-MatrixRun {
    param([Parameter(Mandatory = $true)][string]$CaseFilter)
    $registry = @(Get-CaseRegistry)
    $selected = @(Select-MatrixCases -Registry $registry)
    if ($selected.Count -eq 0) {
        Write-Host "No test cases match -Case/-Filter '$CaseFilter'. Known cases:" -ForegroundColor Red
        $registry | ForEach-Object { Write-Host "  [$($_.Group)] $($_.Name)" }
        return 2
    }
    Write-Host ''
    Write-Host 'CNKI Research Portable unified RC3 candidate - upgrade/rollback/fault matrix (groups B-H)' -ForegroundColor Cyan
    Write-Host "  package   : $($script:G.PackageRoot)"
    Write-Host "  source    : frozen RC2 ZIP $($script:G.Rc2Zip)"
    Write-Host "  work      : $($script:G.WorkRoot)"
    Write-Host "  evidence  : $($script:G.EvidenceDir)"
    Write-Host "  cases     : $($selected.Count) (filter '$CaseFilter'; engine entry '$EngineEntry')"
    Write-Host "  PS        : $($PSVersionTable.PSVersion)"

    $caseSummaries = New-Object System.Collections.ArrayList
    $failCount = 0
    foreach ($entry in $selected) {
        $summary = Invoke-MatrixCase -Entry $entry
        [void]$caseSummaries.Add($summary)
        if ($summary.Status -eq 'FAIL') { $failCount++ }
    }
    $allCases = @($caseSummaries.ToArray())
    $checks = @($allCases | ForEach-Object { $_.Checks })
    $notTested = New-Object System.Collections.ArrayList
    foreach ($c in $allCases) {
        foreach ($check in @($c.Checks)) {
            if ($check.Status -eq 'NOT TESTED') {
                [void]$notTested.Add((New-NotTestedReason -Case $c.Case -CheckId $check.Id -Reason $check.Detail))
            }
        }
    }
    $groupLetters = @($selected | ForEach-Object { [string]$_.Group } | Sort-Object -Unique)
    $groups = [ordered]@{}
    foreach ($letter in $groupLetters) {
        $gCases = @($allCases | Where-Object { [string]$_.Group -eq $letter })
        $gChecks = @($gCases | ForEach-Object { $_.Checks })
        $groups[$letter] = [ordered]@{
            cases         = $gCases.Count
            casePass      = @($gCases | Where-Object { $_.Status -eq 'PASS' }).Count
            caseFail      = @($gCases | Where-Object { $_.Status -eq 'FAIL' }).Count
            caseNotTested = @($gCases | Where-Object { $_.Status -eq 'NOT TESTED' }).Count
            checks        = $gChecks.Count
            checkPass     = @($gChecks | Where-Object { $_.Status -eq 'PASS' }).Count
            checkFail     = @($gChecks | Where-Object { $_.Status -eq 'FAIL' }).Count
            checkWarn     = @($gChecks | Where-Object { $_.Status -eq 'WARN' }).Count
            checkNotTested = @($gChecks | Where-Object { $_.Status -eq 'NOT TESTED' }).Count
        }
    }
    $matrix = [ordered]@{
        totalCases = $allCases.Count
        pass = @($allCases | Where-Object { $_.Status -eq 'PASS' }).Count
        fail = @($allCases | Where-Object { $_.Status -eq 'FAIL' }).Count
        notTested = @($allCases | Where-Object { $_.Status -eq 'NOT TESTED' }).Count
        totalChecks = $checks.Count
        checkPass = @($checks | Where-Object { $_.Status -eq 'PASS' }).Count
        checkFail = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
        checkWarn = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
        checkNotTested = @($checks | Where-Object { $_.Status -eq 'NOT TESTED' }).Count
        groups = $groups
    }
    $summaryObject = [ordered]@{
        schemaVersion  = 2
        tool           = 'cnki-research-portable-unified-tests'
        toolVersion    = $script:TestToolVersion
        generatedAt    = (Get-Date).ToString('o')
        runDurationSec = [Math]::Round(((Get-Date) - $script:G.StartTime).TotalSeconds, 2)
        host           = [ordered]@{
            powershell = "$($PSVersionTable.PSVersion)"
            windows    = [System.Environment]::OSVersion.VersionString
            isAdmin    = $script:G.Admin
        }
        inputs             = Get-TestInputsReport -Layout $script:G.Layout -PackageIdentity $script:G.PackageIdentity
        packageIntegrity   = [ordered]@{
            checks = @($script:G.PackageIntegrityChecks)
            pass   = @($script:G.PackageIntegrityChecks | Where-Object { $_.Status -eq 'PASS' }).Count
            fail   = @($script:G.PackageIntegrityChecks | Where-Object { $_.Status -eq 'FAIL' }).Count
            notTested = @($script:G.PackageIntegrityChecks | Where-Object { $_.Status -eq 'NOT TESTED' }).Count
        }
        frozenInputsVerified = ($script:G.PrereqFailures.Count -eq 0)
        prereqFailures     = @($script:G.PrereqFailures)
        frozenCoreEquality = [ordered]@{
            checks   = @($script:G.FrozenCoreChecks)
            pass     = @($script:G.FrozenCoreChecks | Where-Object { $_.Status -eq 'PASS' }).Count
            fail     = @($script:G.FrozenCoreChecks | Where-Object { $_.Status -eq 'FAIL' }).Count
            notTested = @($script:G.FrozenCoreChecks | Where-Object { $_.Status -eq 'NOT TESTED' }).Count
        }
        matrix             = $matrix
        cases              = @($allCases | ForEach-Object {
            [ordered]@{
                case        = $_.Case
                group       = $_.Group
                description = $_.Description
                status      = $_.Status
                summary     = $_.Summary
                durationSec = $_.DurationSec
                evidence    = $_.EvidencePath
                sandboxKept = $_.SandboxKept
            }
        })
        notTested          = @($notTested.ToArray())
        notTestedByDesign  = @(
            [ordered]@{ case = 'ALL'; topic = 'DSH runtime activation'; reason = 'DSH_RUNTIME_ACTIVATION_VERIFIED is always NOT TESTED: this matrix proves file-level upgrade/rollback only; no real DSH session, MCP tool serving or CNKI search evidence is collected.' }
            [ordered]@{ case = 'ALL'; topic = 'live production target'; reason = 'The real %USERPROFILE%\.dsh / production install is never pointed at or written; tests use isolated sandboxes only.' }
            [ordered]@{ case = 'ALL'; topic = 'operating systems other than Windows 10/11'; reason = 'The portable distribution and sealed engine target Windows only; executed on the Windows host recorded in host.windows.' }
            [ordered]@{ case = 'ALL'; topic = 'PowerShell versions other than Windows PowerShell 5.1'; reason = 'Only Windows PowerShell 5.1 is a supported/tested host; PowerShell 7 was not exercised.' }
            [ordered]@{ case = 'ALL'; topic = 'real CNKI search / MCP tool serving / Playwright browser activation'; reason = 'Runtime behaviour after the user reopens DSH is outside this file-upgrade matrix.' }
        )
        isolationDeclaration = ('All matrix cases executed in isolated sandboxes below ' + $script:G.WorkRoot + '; the production DSH home, .cnki-mcp, Playwright browser profiles and production install were never pointed at or written by this matrix. Cases H persist whole-sandbox before/after fingerprint digests (paths+bytes+sizes+mtimes) as evidence.')
        runtimeActivation = 'NOT TESTED'
        dshRuntimeActivationVerified = 'NOT TESTED'
        liveProductionTarget = 'NOT TESTED'
        notes = @(
            'Target identity is derived from the candidate package itself (manifest.json + upgrade-data/rc2-to-rc3.json + SHA256SUMS.txt); target hashes/counts are never hardcoded.'
            'Post-upgrade install target = payload set P + manifest.json. upgrade-data/** and SHA256SUMS.txt are package-only metadata and must NOT be installed.'
            'DSH_RUNTIME_ACTIVATION_VERIFIED is always NOT TESTED: no real DSH session evidence is collected by this matrix.'
            'Engine-level APPLY/ROLLBACK semantics are exercised through the shipped engine library (test-side wrapper generated into the sandbox); user-facing actions go through tools/setup.ps1.'
        )
    }
    $path = Write-SummaryJson -SummaryObject $summaryObject -Directory $script:G.EvidenceDir
    Write-Host ''
    Write-Host '================ MATRIX SUMMARY ================' -ForegroundColor Cyan
    Write-Host ("  cases: {0} total / {1} PASS / {2} FAIL / {3} NOT TESTED" -f $matrix.totalCases, $matrix.pass, $matrix.fail, $matrix.notTested)
    Write-Host ("  checks: {0} total / {1} PASS / {2} FAIL / {3} WARN / {4} NOT TESTED" -f $matrix.totalChecks, $matrix.checkPass, $matrix.checkFail, $matrix.checkWarn, $matrix.checkNotTested)
    foreach ($letter in $groupLetters) {
        $g = $groups[$letter]
        Write-Host ("  group {0}: {1} cases ({2} PASS/{3} FAIL) / {4} checks ({5} PASS/{6} FAIL/{7} WARN/{8} NOT TESTED)" -f $letter, $g.cases, $g.casePass, $g.caseFail, $g.checks, $g.checkPass, $g.checkFail, $g.checkWarn, $g.checkNotTested)
    }
    Write-Host ("  SUMMARY.json -> {0}" -f $path)
    if ($notTested.Count -gt 0) {
        Write-Host '  NOT TESTED:' -ForegroundColor Yellow
        foreach ($nt in $notTested) { Write-Host "    [$($nt.Case)] $($nt.CheckId): $(Limit-Text $nt.Reason 200)" -ForegroundColor Yellow }
    }
    if ($failCount -gt 0) {
        Write-Host '  FAILED CASES:' -ForegroundColor Red
        foreach ($c in @($allCases | Where-Object { $_.Status -eq 'FAIL' })) {
            Write-Host "    [$($c.Case)]" -ForegroundColor Red
            foreach ($check in @($c.Checks | Where-Object { $_.Status -eq 'FAIL' })) {
                Write-Host "      $($check.Id): $(Limit-Text $check.Detail 300)" -ForegroundColor Red
            }
        }
        return 2
    }
    $frozenCoreFails = @($script:G.FrozenCoreChecks | Where-Object { $_.Status -eq 'FAIL' })
    if ($frozenCoreFails.Count -gt 0) {
        Write-Host '  PACKAGE DEFECTS (frozen-core equality, release-readiness FAIL):' -ForegroundColor Red
        foreach ($r in $frozenCoreFails) { Write-Host "    $($r.Id): $(Limit-Text $r.Detail 400)" -ForegroundColor Red }
        return 2
    }
    return 0
}

function Invoke-FixtureSelfTestMode {
    # Validates the unified fixture builder + independent package oracle WITHOUT
    # invoking the engine.  Useful while the candidate package is still being
    # built; also proves fixture determinism / junction safety / cleanup
    # boundary before running the real matrix.
    $modeRoot = Join-Path $script:G.WorkRoot '_fixture-selftest'
    Remove-CaseRootSafe -CaseRoot $modeRoot
    [void][System.IO.Directory]::CreateDirectory($modeRoot)
    $validationDir = Join-Path $script:G.EvidenceDir 'fixture-validation'
    Remove-EvidenceCaseDirSafe -Dir $validationDir
    [void][System.IO.Directory]::CreateDirectory($validationDir)

    $results = New-Object System.Collections.ArrayList
    function Add-SelfTest {
        param($r)
        [void]$results.Add($r)
        $color = if ($r.Status -eq 'PASS') { 'Green' } elseif ($r.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
        Write-Host ("  [{0}] {1} :: {2}" -f $r.Status, $r.Id, (Limit-Text $r.Detail 220)) -ForegroundColor $color
    }

    Write-Host '=== unified fixture/oracle self-test ===' -ForegroundColor Cyan
    foreach ($r in @($script:G.PackageIntegrityChecks)) { Add-SelfTest $r }
    foreach ($r in @($script:G.FrozenRc2Checks)) { Add-SelfTest $r }

    $rc2Map = $script:G.Rc2Map
    $model = $script:G.PackageModel
    $variants = @('clean', 'hotfixed-line', 'hotfixed-text', 'extra-user-files', 'no-venv', 'no-profile', 'separate-package-root',
                  'rc3-unified', 'mixed', 'target-files-present', 'zip-over-install')
    $frozenRc3Available = $false
    if ($script:G.Rc3FrozenZip -and [System.IO.File]::Exists($script:G.Rc3FrozenZip)) {
        $frozen = Get-FrozenIdentity
        if ((Get-Sha256File $script:G.Rc3FrozenZip) -eq $frozen.Rc3ZipSha256) { $frozenRc3Available = $true }
    }
    if ($frozenRc3Available) { $variants += 'rc3-frozen' }
    else { Add-SelfTest (New-AssertResult -Id 'fixture.rc3-frozen.availability' -Status 'NOT TESTED' -Detail "frozen RC3 ZIP unavailable/unverified at '$($script:G.Rc3FrozenZip)'; rc3-frozen fixture and frozen-RC3 recognition cases will be NOT TESTED") }
    if (Test-LongPathSupport -BaseDir $modeRoot) { $variants += 'long-path' }
    else { Add-SelfTest (New-AssertResult -Id 'fixture.longPath.capability' -Status 'NOT TESTED' -Detail 'host/filesystem cannot create >MAX_PATH paths; the long-path case will be NOT TESTED') }

    foreach ($variant in $variants) {
        Write-Host "--- variant: $variant" -ForegroundColor DarkGray
        $fixtureRoot = Join-Path $modeRoot ($variant -replace '[:\\]', '-')
        $fixture = $null
        $fixtureOk = $false
        try {
            $fixture = New-UnifiedSandbox -Root $fixtureRoot -Rc2Zip $script:G.Rc2Zip -PackageDir $script:G.PackageRoot `
                -Rc3FrozenZip $script:G.Rc3FrozenZip -Variant $variant -CaseName ('selftest-' + $variant) -Force
            $fixtureOk = $true
        } catch {
            Add-SelfTest (New-AssertResult -Id "fixture.$variant.build" -Status FAIL -Detail ("fixture build threw: " + $_.Exception.Message))
        }
        if (-not $fixtureOk) { continue }
        Add-SelfTest (New-AssertResult -Id "fixture.$variant.build" -Status PASS -Detail "fixture built at $($fixture.InstallRoot) (install root length $($fixture.InstallRoot.Length))")

        # expected base tree (independent oracle)
        if ($variant -eq 'rc3-unified') {
            Add-SelfTest (Assert-InstallEqualsUnifiedTarget -Id "fixture.$variant.installEqualsTarget" -InstallRoot $fixture.InstallRoot -Model $model -Label 'synthetic unified install vs candidate target')
            Add-SelfTest (Assert-PackageOnlyFilesNotInstalled -Id "fixture.$variant.noPackageOnlyFiles" -InstallRoot $fixture.InstallRoot -Model $model)
        } elseif ($variant -eq 'rc3-frozen') {
            Add-SelfTest (Assert-TreeEquals -Id "fixture.$variant.installEqualsFrozenRc3" -ActualRoot $fixture.InstallRoot -ExpectedFileMap (Get-ZipMap $script:G.Rc3FrozenZip).Map -Label 'install vs frozen RC3 ZIP')
        } elseif ($variant -notin @('hotfixed-line', 'hotfixed-text', 'mixed', 'target-files-present', 'zip-over-install', 'separate-package-root')) {
            Add-SelfTest (Assert-TreeEquals -Id "fixture.$variant.installEqualsRc2" -ActualRoot $fixture.InstallRoot -ExpectedFileMap $rc2Map.Map -Label 'install vs frozen RC2 ZIP')
        }
        if ($variant -in @('hotfixed-line', 'hotfixed-text')) {
            $cordisRel = (Get-FrozenIdentity).CordisPath
            $cordisPath = Join-Path $fixture.InstallRoot ($cordisRel -replace '/', '\')
            $expectedSha = if ($variant -eq 'hotfixed-line') { (Get-FrozenIdentity).HotfixLineRemovedSha256 } else { (Get-FrozenIdentity).HotfixTextRemovedSha256 }
            $actualSha = Get-Sha256File $cordisPath
            Add-SelfTest (Assert-Condition -Id "fixture.$variant.hotfixHash" -Condition ($actualSha -eq $expectedSha) `
                -PassDetail "cordis hash $actualSha equals the allowed $variant hash" -FailDetail "hotfix hash mismatch: $actualSha expected $expectedSha" -Expected $expectedSha -Actual $actualSha)
        }
        if ($variant -eq 'target-files-present') {
            $presentPath = Join-Path $fixture.InstallRoot ($fixture.PresentTargetOnlyPath -replace '/', '\')
            Add-SelfTest (Assert-Condition -Id 'fixture.target-files-present.present' -Condition ([System.IO.File]::Exists($presentPath)) `
                -PassDetail "operation:add file '$($fixture.PresentTargetOnlyPath)' present in an otherwise RC2 install" -FailDetail 'target-only fixture did not place the added file' -Expected 'present' -Actual 'ABSENT')
        }
        if ($variant -eq 'mixed') {
            Add-SelfTest (Assert-Condition -Id 'fixture.mixed.paths' -Condition (@($fixture.MixedPaths).Count -ge 1) `
                -PassDetail "mixed fixture carries unified target bytes for: $($fixture.MixedPaths -join ', ')" -FailDetail 'mixed fixture has no target payload files' -Expected '>=1' -Actual @($fixture.MixedPaths).Count)
        }
        if ($variant -eq 'separate-package-root') {
            $hasVersion = Test-Path -LiteralPath (Join-Path $fixture.InstallRoot 'VERSION')
            $hasManifest = Test-Path -LiteralPath (Join-Path $fixture.InstallRoot 'manifest.json')
            $hasCordis = Test-Path -LiteralPath (Join-Path $fixture.InstallRoot 'bundle\cnki-research\cordis.patch.yml')
            $hasState = Test-Path -LiteralPath (Join-Path $fixture.InstallRoot '_portable\install-state.json')
            Add-SelfTest (Assert-Condition -Id 'fixture.separate.layout' -Condition ((-not $hasVersion) -and (-not $hasManifest) -and $hasCordis -and $hasState) `
                -PassDetail 'separate-package-root layout: no root VERSION/manifest, bundle+_portable present' `
                -FailDetail "separate layout wrong: VERSION=$hasVersion manifest=$hasManifest cordis=$hasCordis state=$hasState" -Expected 'no VERSION/manifest + cordis/state' -Actual "VERSION=$hasVersion manifest=$hasManifest")
        }
        # env schema
        $stateDoc = Read-JsonFile $fixture.InstallStateFile
        $runtimeDoc = Read-JsonFile $fixture.RuntimeFile
        $envOk = $stateDoc -and $runtimeDoc -and ($stateDoc.distribution -eq $fixture.BaseDistribution) -and ($runtimeDoc.distribution -eq $fixture.BaseDistribution) -and
                 ($stateDoc.schemaVersion -eq 1) -and ($stateDoc.installRoot) -and ($stateDoc.dshHome) -and ($stateDoc.python) -and ($runtimeDoc.python) -and ($runtimeDoc.launcher)
        Add-SelfTest (Assert-Condition -Id "fixture.$variant.envSchema" -Condition $envOk -PassDetail "installer env files present with realistic schema (distribution=$($fixture.BaseDistribution))" -FailDetail 'env fixture schema incomplete' -Expected 'realistic env JSON' -Actual "$($stateDoc.distribution)/$($runtimeDoc.distribution)")
        # junction
        if ($variant -eq 'no-profile') {
            Add-SelfTest (Assert-Condition -Id "fixture.$variant.noProfile" -Condition (-not (Test-Path -LiteralPath $fixture.ProfileDir)) -PassDetail 'no-profile fixture has no DSH profile (engine must WARN)' -FailDetail 'no-profile fixture unexpectedly has a profile' -Expected 'no profile' -Actual 'profile present')
        } else {
            $junctionOk = $fixture.JunctionCreated -and (Test-IsReparsePoint $fixture.JunctionPath)
            $targetOk = $junctionOk -and [string]::Equals((Get-ReparseTarget $fixture.JunctionPath), (Get-FullPath $fixture.BundleDir), [System.StringComparison]::OrdinalIgnoreCase)
            Add-SelfTest (Assert-Condition -Id "fixture.$variant.junction" -Condition ($junctionOk -and $targetOk) `
                -PassDetail ("real directory junction -> bundle dir: " + (Get-ReparseTarget $fixture.JunctionPath)) `
                -FailDetail "junction missing or wrong target (created=$($fixture.JunctionCreated) target=$(Get-ReparseTarget $fixture.JunctionPath) expected=$(Get-FullPath $fixture.BundleDir))" -Expected (Get-FullPath $fixture.BundleDir) -Actual (Get-ReparseTarget $fixture.JunctionPath))
        }
        # venv presence / absence
        $venvExists = [System.IO.Directory]::Exists($fixture.VenvDir)
        $venvExpected = ($variant -ne 'no-venv')
        Add-SelfTest (Assert-Condition -Id "fixture.$variant.venv" -Condition ($venvExists -eq $venvExpected) `
            -PassDetail ("fake venv present=$venvExists (expected=$venvExpected), python.exe is a non-executable sentinel") -FailDetail "venv presence $venvExists expected $venvExpected" -Expected $venvExpected -Actual $venvExists)
        # fingerprint matches live tree
        $fp = Read-JsonFile $fixture.FingerprintFile
        Add-SelfTest (Assert-Condition -Id "fixture.$variant.fingerprintJson" -Condition ($null -ne $fp) -PassDetail 'fixture-fingerprint.json parses' -FailDetail 'fixture-fingerprint.json missing/unparsable' -Expected 'JSON' -Actual 'ABSENT')
        if ($fp) {
            Add-SelfTest (Assert-SnapshotMatchesFingerprint -Id "fixture.$variant.fpInstall" -Root $fixture.InstallRoot -FingerprintEntries @($fp.entries.install) -Label 'install fingerprint')
            Add-SelfTest (Assert-SnapshotMatchesFingerprint -Id "fixture.$variant.fpDshHome" -Root $fixture.DshHome -FingerprintEntries @($fp.entries.dshHome) -Label 'DSH home fingerprint')
            Add-SelfTest (Assert-SnapshotMatchesFingerprint -Id "fixture.$variant.fpUserHome" -Root $fixture.UserHome -FingerprintEntries @($fp.entries.userHome) -Label 'user home fingerprint')
        }
        # snapshot repeatability + junction unlink safety
        $s1 = Get-TreeSnapshot -Root $fixture.Root
        $s2 = Get-TreeSnapshot -Root $fixture.Root
        Add-SelfTest (Assert-SnapshotEqual -Id "fixture.$variant.snapshotRepeatable" -Before $s1 -After $s2 -Label 'repeat-snapshot')
        if ($fixture.JunctionCreated) {
            $targetSnapshotBefore = Get-TreeSnapshot -Root $fixture.JunctionTarget
            [System.IO.Directory]::Delete($fixture.JunctionPath, $false)
            $targetSnapshotAfter = Get-TreeSnapshot -Root $fixture.JunctionTarget
            $unlinkSafe = (-not (Test-Path -LiteralPath $fixture.JunctionPath)) -and (Compare-Snapshots -Before $targetSnapshotBefore -After $targetSnapshotAfter).Equal
            Add-SelfTest (Assert-Condition -Id "fixture.$variant.junctionUnlinkSafe" -Condition $unlinkSafe `
                -PassDetail 'junction unlink (Directory.Delete(path,$false)) removed only the link; target tree unchanged' -FailDetail 'junction unlink changed the target or left the link' -Expected 'link removed, target unchanged' -Actual ('link removed=' + (-not (Test-Path -LiteralPath $fixture.JunctionPath))))
        }
        if ($variant -eq 'long-path') {
            Add-SelfTest (Assert-Condition -Id 'fixture.longPath.length' -Condition (($fixture.InstallRootPathLength -ge 160) -and ($fixture.LongestInstallFilePath -ge 220)) `
                -PassDetail "long-path fixture: install root length=$($fixture.InstallRootPathLength), longest managed file path=$($fixture.LongestInstallFilePath)" `
                -FailDetail "long path not long enough: root=$($fixture.InstallRootPathLength) longest=$($fixture.LongestInstallFilePath)" -Expected 'root>=160, file>=220' -Actual "$($fixture.InstallRootPathLength)/$($fixture.LongestInstallFilePath)")
        }
        Remove-TreeJunctionSafe -Path $fixture.Root -AllowedRoot $modeRoot
        Add-SelfTest (Assert-Condition -Id "fixture.$variant.cleanup" -Condition (-not (Test-Path -LiteralPath $fixture.Root)) -PassDetail 'junction-safe cleanup removed the whole fixture' -FailDetail 'cleanup left bytes behind' -Expected 'absent' -Actual (Test-Path -LiteralPath $fixture.Root))
    }

    # modifier helpers used by the matrix must work on a throw-away fixture
    Write-Host '--- fixture modifiers' -ForegroundColor DarkGray
    $modRoot = Join-Path $modeRoot 'modifiers'
    $modFixture = $null
    try {
        $modFixture = New-UnifiedSandbox -Root $modRoot -Rc2Zip $script:G.Rc2Zip -PackageDir $script:G.PackageRoot `
            -Rc3FrozenZip $script:G.Rc3FrozenZip -Variant 'clean' -CaseName 'selftest-modifiers' -Force
        $originalReadmeSha = Get-Sha256File (Join-Path $modFixture.InstallRoot 'README.md')
        Add-FixturePayloadTamper -Fixture $modFixture -RelPath 'README.md' -Marker 'sandbox-tamper'
        $tamperedSha = Get-Sha256File (Join-Path $modFixture.InstallRoot 'README.md')
        Add-SelfTest (Assert-Condition -Id 'fixture.modifier.tamper' -Condition ($tamperedSha -ne $originalReadmeSha) -PassDetail 'Add-FixturePayloadTamper changed bytes' -FailDetail 'tamper helper did not change bytes' -Expected 'different sha' -Actual $tamperedSha)
        Remove-FixturePayloadFile -Fixture $modFixture -RelPath 'CHANGELOG.md'
        Add-SelfTest (Assert-Condition -Id 'fixture.modifier.missing' -Condition (-not (Test-Path -LiteralPath (Join-Path $modFixture.InstallRoot 'CHANGELOG.md'))) -PassDetail 'Remove-FixturePayloadFile removed the file' -FailDetail 'remove helper failed' -Expected 'absent' -Actual 'present')
        Set-FixtureVersionText -Fixture $modFixture -Text "9.9.9`n"
        $versionText = ([System.IO.File]::ReadAllText((Join-Path $modFixture.InstallRoot 'VERSION'))).Trim()
        Add-SelfTest (Assert-Condition -Id 'fixture.modifier.version' -Condition ($versionText -eq '9.9.9') -PassDetail 'Set-FixtureVersionText wrote tampered version' -FailDetail 'version helper failed' -Expected '9.9.9' -Actual $versionText)
        Set-FixtureInstallStateDistribution -Fixture $modFixture -Distribution '9.9.9-rc.x'
        $stateDoc = Read-JsonFile $modFixture.InstallStateFile
        Add-SelfTest (Assert-Condition -Id 'fixture.modifier.envDist' -Condition ($stateDoc.distribution -eq '9.9.9-rc.x') -PassDetail 'Set-FixtureInstallStateDistribution updated env JSON' -FailDetail 'env distribution helper failed' -Expected '9.9.9-rc.x' -Actual $stateDoc.distribution)
        if ($model -and @($model.AddedPaths).Count -gt 0) {
            $addPath = [string](@($model.AddedPaths | Sort-Object)[0])
            Copy-FixtureTargetFile -Fixture $modFixture -RelPath $addPath | Out-Null
            Add-SelfTest (Assert-Condition -Id 'fixture.modifier.copyTargetFile' -Condition ([System.IO.File]::Exists((Join-Path $modFixture.InstallRoot ($addPath -replace '/', '\')))) -PassDetail "Copy-FixtureTargetFile copied target '$addPath'" -FailDetail 'target-file copy helper failed' -Expected 'present' -Actual 'ABSENT')
            $editSha = Add-FixturePostUpgradeUserEdit -Fixture $modFixture -RelPath $addPath
            Add-SelfTest (Assert-Condition -Id 'fixture.modifier.userEdit' -Condition ($editSha -ne $model.TargetMap[$addPath].Sha256) -PassDetail 'Add-FixturePostUpgradeUserEdit changed an added file byte-exactly' -FailDetail 'user-edit helper did not change bytes' -Expected 'different sha' -Actual $editSha)
        }
    } catch {
        Add-SelfTest (New-AssertResult -Id 'fixture.modifiers' -Status FAIL -Detail ("modifier helper threw: " + $_.Exception.Message))
    }

    # junction injection helpers (payload-parent junction and install-root junction)
    if ($modFixture) {
        try {
            $junctionTarget = Replace-FixturePayloadDirectoryWithJunction -Fixture $modFixture -RelPath 'docs'
            $isReparse = Test-IsReparsePoint (Join-Path $modFixture.InstallRoot 'docs')
            Add-SelfTest (Assert-Condition -Id 'fixture.modifier.payloadJunction' -Condition $isReparse -PassDetail "payload dir 'docs' replaced with a reparse point -> $junctionTarget" -FailDetail 'payload junction helper failed' -Expected 'reparse' -Actual $isReparse)
            $rootJunction = New-FixtureJunctionInstallRoot -Fixture $modFixture -LinkName 'install-junction'
            Add-SelfTest (Assert-Condition -Id 'fixture.modifier.installRootJunction' -Condition (Test-IsReparsePoint $rootJunction) -PassDetail "install-root junction created -> $($modFixture.InstallRoot)" -FailDetail 'install-root junction helper failed' -Expected 'reparse' -Actual (Test-IsReparsePoint $rootJunction))
            $pendingTxn = Add-FixturePendingTransaction -Fixture $modFixture -TransactionId '20261018T000000Z-deadbeef' -Phase 'APPLYING'
            $pendingOk = [System.IO.File]::Exists((Join-Path $pendingTxn 'transaction.json'))
            Add-SelfTest (Assert-Condition -Id 'fixture.modifier.pendingTxn' -Condition $pendingOk -PassDetail 'pending transaction fixture written (phase APPLYING)' -FailDetail 'pending transaction fixture failed' -Expected 'transaction.json' -Actual $pendingOk)
            Set-FixtureReadOnlyAttribute -Fixture $modFixture -RelPath 'README.md'
            $readOnlySet = [bool](([System.IO.File]::GetAttributes((Join-Path $modFixture.InstallRoot 'README.md'))) -band [System.IO.FileAttributes]::ReadOnly)
            Set-FixtureReadOnlyAttribute -Fixture $modFixture -RelPath 'README.md' -Clear
            $readOnlyCleared = -not [bool](([System.IO.File]::GetAttributes((Join-Path $modFixture.InstallRoot 'README.md'))) -band [System.IO.FileAttributes]::ReadOnly)
            Add-SelfTest (Assert-Condition -Id 'fixture.modifier.readonly' -Condition ($readOnlySet -and $readOnlyCleared) -PassDetail 'read-only attribute helper sets and clears' -FailDetail "read-only helper failed (set=$readOnlySet cleared=$readOnlyCleared)" -Expected 'set+clear' -Actual "set=$readOnlySet clear=$readOnlyCleared")
        } catch {
            Add-SelfTest (New-AssertResult -Id 'fixture.modifier.junctions' -Status FAIL -Detail ("junction/modifier helper threw: " + $_.Exception.Message))
        }
        Remove-TreeJunctionSafe -Path $modRoot -AllowedRoot $modeRoot
    }

    # cleanup safety boundary: refuse to delete outside -WorkRoot
    $boundaryRefused = $false
    try { Remove-TreeJunctionSafe -Path $script:G.EvidenceDir -AllowedRoot $script:G.WorkRoot } catch { $boundaryRefused = $true }
    Add-SelfTest (Assert-Condition -Id 'fixture.cleanup.boundary' -Condition $boundaryRefused -PassDetail 'cleanup refuses paths outside -WorkRoot' -FailDetail 'cleanup did NOT refuse a path outside -WorkRoot' -Expected 'refused' -Actual $boundaryRefused)

    # a user-modified plan state must stay out of the shipped package: the
    # package integrity gate is recomputed here too (idempotence of the oracle).
    $recheck = @(Assert-UnifiedPackageIntegrity -Model $model -Rc2Zip $script:G.Rc2Zip -Rc2ZipMap $script:G.Rc2Map)
    Add-SelfTest (New-AssertResult -Id 'oracle.packageIntegrityRepeatable' -Status $(if (@($recheck | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) { 'PASS' } else { 'FAIL' }) `
        -Detail "package-integrity oracle re-executed: $(@($recheck).Count) checks, $(@($recheck | Where-Object { $_.Status -eq 'FAIL' }).Count) FAIL")

    $all = @($results.ToArray())
    $summary = [ordered]@{
        schemaVersion = 2
        tool = 'cnki-research-portable-unified-tests'
        toolVersion = $script:TestToolVersion
        mode = 'fixture-self-test'
        generatedAt = (Get-Date).ToString('o')
        inputs = Get-TestInputsReport -Layout $script:G.Layout -PackageIdentity $script:G.PackageIdentity
        total = $all.Count
        pass = @($all | Where-Object { $_.Status -eq 'PASS' }).Count
        fail = @($all | Where-Object { $_.Status -eq 'FAIL' }).Count
        notTested = @($all | Where-Object { $_.Status -eq 'NOT TESTED' }).Count
        checks = $all
    }
    $path = Join-Path $validationDir 'FIXTURE_VALIDATION.json'
    Write-JsonFile -Path $path -Value $summary -Depth 30 | Out-Null
    Write-Host ''
    Write-Host ("FIXTURE SELF-TEST: {0} checks / {1} PASS / {2} FAIL / {3} NOT TESTED" -f $summary.total, $summary.pass, $summary.fail, $summary.notTested) -ForegroundColor $(if ($summary.fail -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  -> $path"
    if (-not $script:G.KeepSandbox) { try { Remove-CaseRootSafe -CaseRoot $modeRoot } catch { } }
    if ($summary.fail -gt 0) { return 2 }
    return 0
}

# ===========================================================================
# Shared case helpers
# ===========================================================================

function Add-EngineCheckStatuses {
    param($Ctx, [string]$Prefix, $Run, [string[]]$Patterns, [string[]]$ExpectedStatus)
    foreach ($pattern in $Patterns) {
        $id = "$Prefix." + ($pattern -replace '[^A-Za-z0-9]+', '_')
        Add-CaseCheck $Ctx (Assert-EngineCheckStatus -Id $id -Run $Run -CheckIdPattern $pattern -ExpectedStatus $ExpectedStatus -MustExist) | Out-Null
    }
}

function Save-FingerprintEvidence {
    # Writes a whole-sandbox fingerprint JSON document (paths+bytes+sizes+mtimes,
    # junctions recorded not descended) as a per-case evidence artifact, and
    # returns its digest.  Required for H (user-data) and I (read-only) proof.
    param(
        [Parameter(Mandatory = $true)]$Ctx,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot,
        [string]$Description = ''
    )
    $doc = New-SnapshotEvidence -Snapshot $Snapshot -Label $Label -Description $Description
    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    $path = Join-Path $Ctx.OutDir ('whole-sandbox-fingerprint-' + $safeLabel + '.json')
    Write-JsonFile -Path $path -Value $doc -Depth 30 | Out-Null
    Add-CaseArtifact -Context $Ctx -Path $path -Label "whole-sandbox fingerprint $Label" | Out-Null
    return [pscustomobject]@{ Path = $path; Digest = $doc.digest; EntryCount = $doc.entryCount }
}

function Attach-FingerprintData {
    # Adds before/after whole-sandbox fingerprint digests to an assertion result's
    # Data so the per-case evidence JSON carries the proof inline as well.
    param($Result, $BeforeInfo, $AfterInfo, [string]$Rule = 'see whole-sandbox-fingerprint-*.json')
    if ($null -ne $Result) {
        $Result.Data = [pscustomobject]@{
            wholeSandboxBeforeDigest     = if ($BeforeInfo) { $BeforeInfo.Digest } else { $null }
            wholeSandboxBeforeEntryCount = if ($BeforeInfo) { $BeforeInfo.EntryCount } else { $null }
            wholeSandboxAfterDigest      = if ($AfterInfo) { $AfterInfo.Digest } else { $null }
            wholeSandboxAfterEntryCount  = if ($AfterInfo) { $AfterInfo.EntryCount } else { $null }
            digestRule                   = $Rule
        }
    }
    return $Result
}

function Get-SnapshotEntrySha {
    param([AllowEmptyCollection()][object[]]$Snapshot, [string]$Rel)
    $idx = Get-SnapshotIndex $Snapshot
    if ($idx.ContainsKey($Rel)) { return [string]$idx[$Rel].Sha256 }
    return $null
}

function Assert-SubtreeEqual {
    param([string]$Id, [AllowEmptyCollection()][object[]]$Before, [AllowEmptyCollection()][object[]]$After, [string[]]$Prefixes, [string]$Label)
    $b = Select-SnapshotSubtree -Snapshot $Before -Prefixes $Prefixes
    $a = Select-SnapshotSubtree -Snapshot $After -Prefixes $Prefixes
    return Assert-SnapshotEqual -Id $Id -Before $b -After $a -Label $Label
}

function Start-FixtureUpgradePlan {
    param($Ctx, [string]$Prefix = 'plan', [switch]$SkipAssert)
    $plan = Invoke-EngineAction $Ctx 'plan' -Label 'plan-for-apply'
    if (-not $SkipAssert) {
        Add-CaseCheck $Ctx (Assert-EngineExit -Id "$Prefix.exit" -Run $plan -ExpectedExit 0 -RequireJson) | Out-Null
    }
    return [string](Get-JsonValue $plan.Json 'planId')
}

function Write-FaultPlanFile {
    param($Ctx, [string]$Name, [string[]]$Faults)
    $path = Join-Path $Ctx.OutDir ("fault-$Name.json")
    Write-JsonFile -Path $path -Value ([ordered]@{ faults = @($Faults) }) -Depth 5 | Out-Null
    Add-CaseArtifact -Context $Ctx -Path $path -Label "fault plan $Name" | Out-Null
    return $path
}

function Get-InstallTxnPath {
    param($Fixture, [string]$TransactionId)
    return (Join-Path $Fixture.InstallRoot ("_portable\upgrades\" + $TransactionId))
}

function Invoke-UnknownStateRefusal {
    param(
        $Ctx,
        [string]$Prefix,
        [string]$Variant,
        [string]$ExpectPath,
        [string[]]$ExpectCategories,
        [string]$ExpectJsonToken = '',
        [scriptblock]$Prepare = $null
    )
    $fixture = New-CaseFixture $Ctx $Variant
    if ($Prepare) { & $Prepare $fixture }
    $preInstall = Get-InstallSnapshot $fixture
    $preRoot = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $check = Invoke-EngineAction $Ctx 'check' -Label 'check-unknown'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id "$Prefix.check.exit" -Run $check -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id "$Prefix.check.state" -Run $check -Expected 'UNKNOWN_OR_MODIFIED') | Out-Null
    $conflicts = @(Get-JsonValue $check.Json 'conflicts')
    $match = @($conflicts | Where-Object { [string]::Equals([string]$_.path, $ExpectPath, [System.StringComparison]::OrdinalIgnoreCase) })
    Add-CaseCheck $Ctx (Assert-Condition -Id "$Prefix.check.conflictListed" -Condition ($match.Count -ge 1) `
        -PassDetail "conflict list contains '$ExpectPath'" -FailDetail "conflict list does not contain '$ExpectPath' (conflicts: $(@($conflicts | ForEach-Object { $_.path }) -join ', '))" `
        -Expected $ExpectPath -Actual @($conflicts | ForEach-Object { $_.path })) | Out-Null
    if ($match.Count -ge 1) {
        $category = [string]$match[0].category
        $categoryOk = $false
        foreach ($want in $ExpectCategories) {
            if ($category -eq $want -or $category -like ($want + '*')) { $categoryOk = $true; break }
        }
        Add-CaseCheck $Ctx (Assert-Condition -Id "$Prefix.check.conflictCategory" -Condition $categoryOk `
            -PassDetail "conflict '$ExpectPath' category='$category'" -FailDetail "conflict '$ExpectPath' category='$category' expected one of [$($ExpectCategories -join ', ')]" `
            -Expected $ExpectCategories -Actual $category) | Out-Null
    }
    if ($ExpectJsonToken) {
        Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id "$Prefix.check.reasonToken" -Run $check -Token $ExpectJsonToken -MustContain -Label 'unknown-state reason') | Out-Null
    }
    $plan = Invoke-EngineAction $Ctx 'plan' -Label 'plan-unknown'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id "$Prefix.plan.exit" -Run $plan -ExpectedExit 2 -RequireJson) | Out-Null
    $apply = Invoke-EngineAction $Ctx 'apply' -Label 'apply-unknown'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id "$Prefix.apply.exit" -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    $postInstall = Get-InstallSnapshot $fixture
    $postRoot = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id "$Prefix.untouched" -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id "$Prefix.noWrites" -Before $preRoot -After $postRoot -Label 'whole-sandbox') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id "$Prefix.noTxn" -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

# ===========================================================================
# CASES A - normal upgrade path (clean RC2)
# ===========================================================================

function Test-CaseB1 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $before = Get-SandboxSnapshot $fixture
    $run = Invoke-EngineAction $Ctx 'check' -Label 'clean'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B1.exit' -Run $run -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'B1.action' -Run $run -Path 'action' -Expected 'check') | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'B1.sourceState' -Run $run -Expected 'RC2_CLEAN') | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'B1.sourceVersion' -Run $run -Path 'sourceVersion' -Expected '1.0.0-rc.2') | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'B1.targetVersion' -Run $run -Path 'targetVersion' -Expected '1.0.0-rc.3') | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'B1.runtimeActivation' -Run $run -Path 'runtimeActivation' -Expected 'NOT TESTED') | Out-Null
    $failCount = Get-JsonValue $run.Json 'summary.fail'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B1.summaryFail0' -Condition ($failCount -eq 0) -PassDetail 'summary.fail=0' -FailDetail "summary.fail=$failCount" -Expected 0 -Actual $failCount) | Out-Null
    Add-EngineCheckStatuses -Ctx $Ctx -Prefix 'B1.checks' -Run $run -Patterns @('patch.sumsFile', 'patch.hashes', 'source.payloadHashes', 'source.state', 'path.installRootSafe', 'env.pendingTransaction', 'env.userDataUntouched') -ExpectedStatus @('PASS')
    Add-CaseCheck $Ctx (Assert-EngineCheckStatus -Id 'B1.check.dshProcessTable' -Run $run -CheckIdPattern 'dsh.processTable' -ExpectedStatus @('PASS', 'WARN') -MustExist) | Out-Null
    $hotfixedVariant = [string](Get-JsonValue $run.Json 'source.hotfixedVariant')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B1.notHotfixed' -Condition ([string]::IsNullOrEmpty($hotfixedVariant)) `
        -PassDetail 'clean RC2 is not reported as hotfixed' -FailDetail "clean RC2 reported hotfixedVariant='$hotfixedVariant'" -Expected 'none' -Actual $hotfixedVariant) | Out-Null
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B1.humanOutput' -Condition ($run.Stdout -and $run.Stdout.Length -gt 0) -PassDetail 'human-readable stdout present' -FailDetail 'no stdout produced' -Expected 'non-empty' -Actual $run.Stdout.Length) | Out-Null
    $after = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-ReadOnlyAction -Id 'B1.readOnly' -Before $before -After $after -ActionLabel 'CHECK on clean RC2') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoBackupCreated -Id 'B1.noBackup' -InstallRoot $fixture.InstallRoot) | Out-Null
}

function Test-CaseB2 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $before = Get-SandboxSnapshot $fixture
    $run = Invoke-EngineAction $Ctx 'plan' -Label 'clean'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B2.exit' -Run $run -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'B2.action' -Run $run -Path 'action' -Expected 'plan') | Out-Null
    foreach ($r in @(Assert-EnginePlanFields -Ctx $Ctx -Prefix 'B2' -Run $run -Fixture $fixture)) { Add-CaseCheck $Ctx $r | Out-Null }
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'B2.requiresDshExit' -Run $run -Path 'plan.requiresDshExit' -Expected $false) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'B2.targetVersion' -Run $run -Path 'targetVersion' -Expected '1.0.0-rc.3') | Out-Null
    $after = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-PlanNoWrites -Id 'B2.planReadOnly' -InstallRoot $fixture.InstallRoot -Before $before -After $after) | Out-Null
}

function Test-CaseB3 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $before = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)

    # (a) upgrade without -PlanId => CHECK+PLAN only, exit 0, read-only, PLAN_READY
    $planOnly = Invoke-Engine -Ctx $Ctx -Action 'apply' -OmitYes -Params @{} -Label 'upgrade-without-planid'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B3.noPlanId.exit' -Run $planOnly -ExpectedExit 0) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineOutcome -Id 'B3.noPlanId.outcome' -Run $planOnly -Expected @('PLAN_READY')) | Out-Null
    $planIdA = [string](Get-JsonValue $planOnly.Json 'planId')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B3.noPlanId.planId' -Condition ($planIdA -match '^[0-9a-f]{64}$') `
        -PassDetail "PLAN_READY emitted planId=$planIdA" -FailDetail "PLAN_READY planId invalid: '$planIdA'" -Expected '64 hex' -Actual $planIdA) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'B3.noPlanId.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'upgrade without planId (plan phase)') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'B3.noPlanId.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null

    # (b) correct PlanId but no -Yes => CONFIRMATION_REQUIRED, zero writes
    $noConfirm = Invoke-Engine -Ctx $Ctx -Action 'apply' -OmitYes -Params @{ PlanId = $planIdA } -Label 'upgrade-planid-no-yes'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B3.noConfirm.exit' -Run $noConfirm -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'B3.noConfirm.token' -Run $noConfirm -Token 'CONFIRMATION_REQUIRED' -MustContain -Label 'confirmation gate') | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'B3.noConfirm.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'upgrade with planId but no -Yes') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'B3.noConfirm.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null

    # (c) wrong/foreign planId => refused (PLAN_STALE / planId mismatch), zero writes
    $wrongId = 'deadbeef' * 8
    $wrong = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $wrongId } -Label 'wrong-planid'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B3.wrongPlanId.exit' -Run $wrong -ExpectedExit 2 -RequireJson) | Out-Null
    $wrongText = if ($wrong.Json) { $wrong.Json | ConvertTo-Json -Depth 30 } else { '' }
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B3.wrongPlanId.token' -Condition (($wrongText -match 'PLAN_STALE') -or ($wrongText -match 'PLAN_ID') -or ($wrongText -match 'planId')) `
        -PassDetail 'wrong planId refused with an explicit plan/planId error token' -FailDetail "wrong planId refusal does not mention plan/planId: $(Limit-Text $wrongText 400)" -Expected 'PLAN_STALE/planId' -Actual '') | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'B3.wrongPlanId.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'refused upgrade (wrong planId)') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'B3.wrongPlanId.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null

    # (d) planId expired by a state change: plan on a clean install, then tamper a
    # planned file, then present the old planId => refused, zero writes.
    $planFresh = Invoke-EngineAction $Ctx 'plan' -Label 'plan-before-state-change'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B3.expired.planExit' -Run $planFresh -ExpectedExit 0 -RequireJson) | Out-Null
    $planIdB = [string](Get-JsonValue $planFresh.Json 'planId')
    Add-FixturePayloadTamper -Fixture $fixture -RelPath 'README.md' -Marker "`nSTATE_CHANGED_AFTER_PLAN`n" | Out-Null
    $beforeExpired = Get-SandboxSnapshot $fixture
    $expired = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planIdB } -Label 'expired-planid'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B3.expired.exit' -Run $expired -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'B3.expired.readOnly' -Before $beforeExpired -After (Get-SandboxSnapshot $fixture) -Label 'refused upgrade (stale planId after state change)') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'B3.expired.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

# ===========================================================================
# CASES B4/B8 - full APPLY to the unified target and exact installed-target proof
# ===========================================================================

function Test-CaseB4 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $model = $script:G.PackageModel
    $preInstall = Get-InstallSnapshot $fixture
    $preRoot = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    # preserve pre-upgrade env files for the non-migration-field proof
    $preStateCopy = Join-Path $Ctx.OutDir 'pre-install-state.json'
    $preRuntimeCopy = Join-Path $Ctx.OutDir 'pre-portable-runtime.json'
    [System.IO.File]::Copy($fixture.InstallStateFile, $preStateCopy, $true)
    [System.IO.File]::Copy($fixture.RuntimeFile, $preRuntimeCopy, $true)

    $run = Invoke-UpgradeToUnifiedTarget -Ctx $Ctx -Fixture $fixture -Prefix 'B4'
    $txnId = $run.TxnId

    # independent oracle: installed tree == candidate package target (P + manifest.json)
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id 'B4.installedTargetTree' -InstallRoot $fixture.InstallRoot -Model $model -Label 'installed tree vs candidate unified target') | Out-Null
    Add-CaseCheck $Ctx (Assert-PackageOnlyFilesNotInstalled -Id 'B4.noPackageOnlyFiles' -InstallRoot $fixture.InstallRoot -Model $model) | Out-Null
    Add-CaseCheck $Ctx (Assert-AddedPayloadFilesPresent -Id 'B4.addedPayloadFiles' -InstallRoot $fixture.InstallRoot -Model $model) | Out-Null
    Add-CaseCheck $Ctx (Assert-Rc3Semantics -Id 'B4.targetSemantics' -InstallRoot $fixture.InstallRoot -Model $model) | Out-Null
    $expectedRel = @($script:G.TargetFileList)
    Add-CaseCheck $Ctx (Assert-NoUnexpectedInstallFiles -Id 'B4.noUnexpectedFiles' -InstallRoot $fixture.InstallRoot `
        -AllowedRelPrefixes @('.venv', '_portable') -AllowedRelPaths @('bundle/cnki-research/portable.runtime.json', 'user-notes.txt') -ExpectedRelPaths $expectedRel) | Out-Null
    Add-CaseCheck $Ctx (Assert-EnvMetadata -Id 'B4.envMetadata' -InstallRoot $fixture.InstallRoot -ExpectedDistribution $script:G.TargetVersion -ExpectUpgradeRecord) | Out-Null
    Add-CaseCheck $Ctx (Assert-EnvNonMigrationPreserved -Id 'B4.envNonMigrationFields' -PreInstallStateFile $preStateCopy -PreRuntimeFile $preRuntimeCopy -InstallRoot $fixture.InstallRoot) | Out-Null

    if ($txnId) {
        $managed = @($script:G.PackageModel.ReplacedPaths) + @('_portable/install-state.json', 'bundle/cnki-research/portable.runtime.json')
        Add-CaseCheck $Ctx (Assert-BackupFilesMatchPreState -Id 'B4.backupsMatchPre' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -PreSnapshot $preInstall -ManagedRelPaths $managed) | Out-Null
        Add-CaseCheck $Ctx (Assert-TransactionAddRecords -Id 'B4.transactionAddRecords' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -Model $model) | Out-Null
        # D6 created-directory guarantee: the transaction must record exactly the
        # directories needed by operation:add payload files that did not exist
        # before the upgrade (derived dynamically from the pre-upgrade snapshot;
        # for the approved payload set this is tests/lib).
        $preExistingDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($e in @($preInstall)) { if ($e.Rel) { [void]$preExistingDirs.Add([string]$e.Rel) } }
        $expectedNewDirs = New-Object System.Collections.ArrayList
        foreach ($rel in @($script:G.PackageModel.AddedPaths)) {
            $parts = ([string]$rel) -split '/'
            $acc = ''
            for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
                $acc = if ($i -eq 0) { $parts[0] } else { "$acc/$($parts[$i])" }
                if (-not $preExistingDirs.Contains($acc) -and -not $expectedNewDirs.Contains($acc)) { [void]$expectedNewDirs.Add($acc) }
            }
        }
        Add-CaseCheck $Ctx (Assert-TransactionCreatedDirectoriesInsideInstallRoot -Id 'B4.createdDirectories' -InstallRoot $fixture.InstallRoot -TransactionId $txnId) | Out-Null
        Add-CaseCheck $Ctx (Assert-TransactionNewDirectories -Id 'B4.newDirectories' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPaths @($expectedNewDirs.ToArray())) | Out-Null
        $txnRec = Get-TransactionRecord -InstallRoot $fixture.InstallRoot -TransactionId $txnId
        $backupVerified = Get-JsonValue $txnRec 'backupVerified'
        $stagingVerified = Get-JsonValue $txnRec 'stagingVerified'
        Add-CaseCheck $Ctx (Assert-Condition -Id 'B4.backupStagingVerified' -Condition (($backupVerified -eq $true) -and ($stagingVerified -eq $true)) `
            -PassDetail 'COMMITTED transaction: backupVerified=true and stagingVerified=true' `
            -FailDetail "COMMITTED transaction: backupVerified='$backupVerified' stagingVerified='$stagingVerified'" -Expected 'true/true' -Actual "backup=$backupVerified staging=$stagingVerified") | Out-Null
        $restoreVerified = Get-JsonValue $txnRec 'restoreVerified'
        Add-CaseCheck $Ctx (Assert-Condition -Id 'B4.restoreVerifiedSuccessPath' -Condition ($restoreVerified -ne $true) `
            -PassDetail "COMMITTED success path: restoreVerified=$restoreVerified (auto-restore correctly not triggered)" `
            -FailDetail 'COMMITTED success path unexpectedly has restoreVerified=true' -Expected 'restoreVerified != true' -Actual $restoreVerified) | Out-Null
    } else {
        Add-CaseCheck $Ctx (New-AssertResult -Id 'B4.transactionEvidence' -Status FAIL -Detail 'no transaction id: backup/add-record evidence cannot be collected') | Out-Null
    }

    # preservation proofs
    $postInstall = Get-InstallSnapshot $fixture
    $postRoot = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-SubtreeEqual -Id 'B4.venvUnchanged' -Before $preInstall -After $postInstall -Prefixes @('.venv') -Label '.venv subtree') | Out-Null
    Add-CaseCheck $Ctx (Assert-UserDataUnchanged -Id 'B4.userDataUnchanged' -Before $preRoot -After $postRoot -UserDataPrefixes @('home', 'dsh-home')) | Out-Null
    $preProfilePkgSha = Get-SnapshotEntrySha -Snapshot $preRoot -Rel 'dsh-home/profiles/desktop/package.json'
    Add-CaseCheck $Ctx (Assert-JunctionsUnchanged -Id 'B4.profileUnchanged' -DshHome $fixture.DshHome -InstallRoot $fixture.InstallRoot -Profile 'desktop' -ExpectedPackageJsonSha $preProfilePkgSha) | Out-Null
    $installRel = Get-RelPath -Root $fixture.Root -Path $fixture.InstallRoot
    $outsideDiff = Compare-Snapshots -Before $preRoot -After $postRoot -IgnorePrefixes @($installRel)
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B4.noWritesOutsideInstallRoot' -Condition $outsideDiff.Equal `
        -PassDetail 'no writes outside the install root (whole-sandbox fingerprint outside install/ identical)' `
        -FailDetail ("engine wrote outside the install root:`n" + (Format-SnapshotDiff -Diff $outsideDiff)) -Expected 'identical' -Actual "added=$($outsideDiff.AddedCount) changed=$($outsideDiff.ChangedCount)") | Out-Null
    $postTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $newTxns = @($postTxnIds | Where-Object { $preTxnIds -notcontains $_ })
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B4.oneTransaction' -Condition ($newTxns.Count -eq 1) -PassDetail "exactly one new transaction directory: $($newTxns -join ', ')" -FailDetail "new transaction count=$($newTxns.Count)" -Expected 1 -Actual $newTxns.Count) | Out-Null
    Add-CaseCheck $Ctx (Assert-RuntimeActivationNotTested -Id 'B4.runtimeActivation' -Run $run.Apply) | Out-Null
    # The APPLY document's sourceState is the PRE-apply state by design; prove the
    # post-apply state with a separate read-only CHECK instead.
    $postApplyCheck = Invoke-EngineAction $Ctx 'check' -Label 'check-after-apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B4.checkAfterApply.exit' -Run $postApplyCheck -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'B4.checkAfterApplyState' -Run $postApplyCheck -Expected 'RC3_ALREADY_INSTALLED') | Out-Null
}

function Test-CaseB5 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'B5.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B5.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    $before = Get-SandboxSnapshot $fixture
    $verify = Invoke-EngineAction $Ctx 'verify' -Label 'verify'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B5.verify.exit' -Run $verify -ExpectedExit 0 -RequireJson) | Out-Null
    $outcome = Get-FileUpgradeOutcome -Json $verify.Json
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B5.fileUpgradeComplete' -Condition ($outcome.Outcome -eq 'PASS') `
        -PassDetail "FILE_UPGRADE_COMPLETE=PASS ($($outcome.Evidence))" -FailDetail "FILE_UPGRADE_COMPLETE outcome='$($outcome.Outcome)' ($($outcome.Evidence))" -Expected 'PASS' -Actual $outcome.Outcome) | Out-Null
    $runtimeToken = [string](Get-JsonValue $verify.Json 'verify.runtimeActivation')
    if (-not $runtimeToken) { $runtimeToken = [string](Get-JsonValue $verify.Json 'verify.DSH_RUNTIME_ACTIVATION_VERIFIED') }
    if (-not $runtimeToken) { $runtimeToken = [string](Get-JsonValue $verify.Json 'runtimeActivation') }
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B5.runtimeNotTested' -Condition ($runtimeToken -eq 'NOT TESTED') -PassDetail 'runtime activation reported NOT TESTED (file upgrade only)' -FailDetail "runtime activation token='$runtimeToken' (must be NOT TESTED; this task never verifies real DSH runtime)" -Expected 'NOT TESTED' -Actual $runtimeToken) | Out-Null
    $failChecks = @(Find-EngineCheck -Json $verify.Json -IdPattern 'verify.*' | Where-Object { $_.status -eq 'FAIL' })
    $verifyChecks = @(Find-EngineCheck -Json $verify.Json -IdPattern 'verify.*')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B5.verifyChecksAllPass' -Condition (($verifyChecks.Count -gt 0) -and ($failChecks.Count -eq 0)) -PassDetail "all $($verifyChecks.Count) verify.* checks are non-FAIL" -FailDetail "verify.* checks: total=$($verifyChecks.Count) fail=$($failChecks.Count) ($($failChecks.id -join ', '))" -Expected 'no verify FAIL' -Actual "total=$($verifyChecks.Count) fail=$($failChecks.Count)") | Out-Null
    $after = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-ReadOnlyAction -Id 'B5.readOnly' -Before $before -After $after -ActionLabel 'VERIFY') | Out-Null
}

function Test-CaseB6 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'B6.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B6.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    $before = Get-SandboxSnapshot $fixture
    $status = Invoke-EngineAction $Ctx 'status' -Label 'status'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B6.status.exit' -Run $status -ExpectedExit 0 -RequireJson) | Out-Null
    $installedVersion = [string](Get-JsonValue $status.Json 'status.installed.version')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B6.reportsRc3' -Condition ($installedVersion -eq '1.0.0-rc.3') -PassDetail "STATUS reports installed version 1.0.0-rc.3" -FailDetail "STATUS installed version='$installedVersion'" -Expected '1.0.0-rc.3' -Actual $installedVersion) | Out-Null
    $history = @(Get-JsonValue $status.Json 'status.transactions')
    $historyIds = @($history | ForEach-Object { [string]$_.transactionId })
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B6.history' -Condition (-not $txnId -or ($historyIds -contains $txnId)) -PassDetail "STATUS transaction history contains '$txnId' ($($history.Count) entries)" -FailDetail "STATUS history [$($historyIds -join ', ')] does not contain '$txnId'" -Expected $txnId -Actual $historyIds) | Out-Null
    $pending = Get-JsonValue $status.Json 'status.pendingTransaction'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B6.noPending' -Condition ($null -eq $pending) -PassDetail 'STATUS reports no pending transaction after COMMITTED upgrade' -FailDetail "STATUS reports pending transaction: $(($pending | ConvertTo-Json -Depth 5))" -Expected 'null' -Actual $pending) | Out-Null
    $lastUpgrade = Get-JsonValue $status.Json 'status.lastUpgrade'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B6.lastUpgrade' -Condition ($null -ne $lastUpgrade) -PassDetail 'STATUS reports last upgrade result' -FailDetail 'STATUS has no lastUpgrade information' -Expected 'present' -Actual 'ABSENT') | Out-Null
    $after = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-ReadOnlyAction -Id 'B6.readOnly' -Before $before -After $after -ActionLabel 'STATUS') | Out-Null
}

# ===========================================================================
# CASES B - RC2_HOTFIXED variants
# ===========================================================================

function Invoke-HotfixCase {
    param($Ctx, [string]$Variant, [string]$ExpectedHotfixVariant, [string]$Prefix)
    $fixture = New-CaseFixture $Ctx $Variant
    $before = Get-SandboxSnapshot $fixture
    $check = Invoke-EngineAction $Ctx 'check' -Label "check-$Variant"
    Add-CaseCheck $Ctx (Assert-EngineExit -Id "$Prefix.check.exit" -Run $check -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id "$Prefix.check.state" -Run $check -Expected 'RC2_HOTFIXED') | Out-Null
    $variantField = [string](Get-JsonValue $check.Json 'source.hotfixedVariant')
    if (-not $variantField) { $variantField = [string](Get-JsonValue $check.Json 'hotfixedVariant') }
    if (-not $variantField) {
        $raw = $check.Json | ConvertTo-Json -Depth 20
        if ($raw.Contains($ExpectedHotfixVariant)) { $variantField = $ExpectedHotfixVariant }
    }
    Add-CaseCheck $Ctx (Assert-Condition -Id "$Prefix.check.variant" -Condition ($variantField -eq $ExpectedHotfixVariant) `
        -PassDetail "detected hotfix variant=$variantField" -FailDetail "detected hotfix variant='$variantField' expected '$ExpectedHotfixVariant'" -Expected $ExpectedHotfixVariant -Actual $variantField) | Out-Null
    $afterCheck = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-ReadOnlyAction -Id "$Prefix.check.readOnly" -Before $before -After $afterCheck -ActionLabel 'CHECK on hotfixed RC2') | Out-Null
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix "$Prefix.plan"
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label "apply-$Variant"
    Add-CaseCheck $Ctx (Assert-EngineExit -Id "$Prefix.apply.exit" -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id "$Prefix.payloadEqualsRc3" -InstallRoot $fixture.InstallRoot -Label 'hotfixed RC2 upgraded tree vs frozen RC3') | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    if ($txnId) { Add-CaseCheck $Ctx (Assert-TransactionCommitted -Ctx $Ctx -Id "$Prefix.txnPhase" -TransactionId $txnId -Fixture $fixture) | Out-Null }
    Add-CaseCheck $Ctx (Assert-EnvMetadata -Id "$Prefix.envMetadata" -InstallRoot $fixture.InstallRoot -ExpectedDistribution $script:G.TargetVersion -ExpectUpgradeRecord) | Out-Null
}

function Test-CaseC1 {
    param($Ctx)
    Invoke-HotfixCase -Ctx $Ctx -Variant 'hotfixed-line' -ExpectedHotfixVariant 'HOTFIX_LINE_REMOVED' -Prefix 'C1'
}

function Test-CaseC2 {
    param($Ctx)
    Invoke-HotfixCase -Ctx $Ctx -Variant 'hotfixed-text' -ExpectedHotfixVariant 'HOTFIX_TEXT_REMOVED' -Prefix 'C2'
}

function Test-CaseC3 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $check = Invoke-EngineAction $Ctx 'check' -Label 'clean-not-hotfixed'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'C3.exit' -Run $check -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'C3.state' -Run $check -Expected 'RC2_CLEAN') | Out-Null
    $variantField = [string](Get-JsonValue $check.Json 'source.hotfixedVariant')
    $raw = if ($check.Json) { $check.Json | ConvertTo-Json -Depth 20 } else { '' }
    $notMisdetected = [string]::IsNullOrEmpty($variantField) -and (-not $raw.Contains('HOTFIX_LINE_REMOVED')) -and (-not $raw.Contains('HOTFIX_TEXT_REMOVED'))
    Add-CaseCheck $Ctx (Assert-Condition -Id 'C3.notMisdetected' -Condition $notMisdetected `
        -PassDetail 'clean RC2 is not misdetected as hotfixed (state RC2_CLEAN, no hotfixed variant)' `
        -FailDetail "clean RC2 misdetected: state=$(Get-JsonValue $check.Json 'sourceState') variant='$variantField'" -Expected 'RC2_CLEAN/no variant' -Actual $variantField) | Out-Null
}

# ===========================================================================
# CASES C - idempotent RC3 install
# ===========================================================================

function Test-CaseD1 {
    param($Ctx)
    # After a REAL upgrade the install must be recognized as RC3_ALREADY_INSTALLED
    # (UNIFIED) and a second upgrade must be a safe no-op with zero writes.
    $fixture = New-CaseFixture $Ctx 'clean'
    $run = Invoke-UpgradeToUnifiedTarget -Ctx $Ctx -Fixture $fixture -Prefix 'D1'
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id 'D1.firstApplyTarget' -InstallRoot $fixture.InstallRoot -Model $script:G.PackageModel) | Out-Null

    $before = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $check = Invoke-EngineAction $Ctx 'check' -Label 'idempotent-check'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D1.check.exit' -Run $check -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'D1.check.state' -Run $check -Expected 'RC3_ALREADY_INSTALLED') | Out-Null
    $variant = Get-DocVariant $check.Json
    Add-CaseCheck $Ctx (Assert-Condition -Id 'D1.check.variant' -Condition ($variant -eq 'UNIFIED') `
        -PassDetail "RC3_ALREADY_INSTALLED variant=$variant" -FailDetail "variant='$variant' expected 'UNIFIED'" -Expected 'UNIFIED' -Actual $variant) | Out-Null
    $failedChecks = @(Find-EngineCheck -Json $check.Json -IdPattern '*' | Where-Object { $_.status -eq 'FAIL' })
    Add-CaseCheck $Ctx (Assert-Condition -Id 'D1.check.noFailChecks' -Condition ($failedChecks.Count -eq 0) -PassDetail 'CHECK reports no FAIL checks for the upgraded unified install' -FailDetail "CHECK FAIL checks: $($failedChecks.id -join ', ')" -Expected 'none' -Actual $failedChecks.Count) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D1.check.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'CHECK on upgraded unified install') | Out-Null

    $plan = Invoke-EngineAction $Ctx 'plan' -Label 'idempotent-plan'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D1.plan.exit' -Run $plan -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'D1.plan.noOp' -Run $plan -Path 'plan.noOp' -Expected $true) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'D1.plan.actionable' -Run $plan -Path 'plan.actionable' -Expected $false) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D1.plan.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'PLAN on upgraded unified install') | Out-Null

    $noop = Invoke-EngineAction $Ctx 'apply-noop' -Label 'idempotent-apply-noop'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D1.noopApply.exit' -Run $noop -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineOutcome -Id 'D1.noopApply.outcome' -Run $noop -Expected @('NOOP_ALREADY_TARGET', 'ALREADY_AT_TARGET')) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D1.noopApply.zeroWrites' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'no-op APPLY whole-sandbox fingerprint') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'D1.noopApply.noNewTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

function Test-CaseD2 {
    param($Ctx)
    # A synthetic (byte-copied) unified install must be recognized as
    # RC3_ALREADY_INSTALLED/UNIFIED and all read-only actions must write nothing.
    $fixture = New-CaseFixture $Ctx 'rc3-unified'
    $before = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $check = Invoke-EngineAction $Ctx 'check' -Label 'synthetic-unified-check'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D2.check.exit' -Run $check -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'D2.check.state' -Run $check -Expected 'RC3_ALREADY_INSTALLED') | Out-Null
    $variant = Get-DocVariant $check.Json
    Add-CaseCheck $Ctx (Assert-Condition -Id 'D2.check.variant' -Condition ($variant -eq 'UNIFIED') -PassDetail "variant=$variant" -FailDetail "variant='$variant' expected 'UNIFIED'" -Expected 'UNIFIED' -Actual $variant) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D2.check.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'CHECK on synthetic unified install') | Out-Null
    $plan = Invoke-EngineAction $Ctx 'plan' -Label 'synthetic-unified-plan'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D2.plan.exit' -Run $plan -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'D2.plan.noOp' -Run $plan -Path 'plan.noOp' -Expected $true) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D2.plan.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'PLAN on synthetic unified install') | Out-Null
    $noop = Invoke-EngineAction $Ctx 'apply-noop' -Label 'synthetic-unified-noop'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D2.noopApply.exit' -Run $noop -ExpectedExit 0) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D2.noopApply.zeroWrites' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'no-op APPLY synthetic unified') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'D2.noopApply.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

function Test-CaseD3 {
    param($Ctx)
    # A synthetic frozen-RC3 install must be recognized as
    # RC3_ALREADY_INSTALLED (variant FROZEN_RC3): no upgrade action is performed.
    if (-not $script:G.Rc3FrozenZip -or -not [System.IO.File]::Exists($script:G.Rc3FrozenZip)) {
        Add-CaseCheck $Ctx (New-AssertResult -Id 'D3.frozenRc3Zip' -Status 'NOT TESTED' -Detail "frozen RC3 ZIP not available at '$($script:G.Rc3FrozenZip)'; the frozen-RC3 recognition variant cannot be synthesized on this host (documented limitation, not PASS)") | Out-Null
        return
    }
    $fixture = New-CaseFixture $Ctx 'rc3-frozen'
    $before = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $check = Invoke-EngineAction $Ctx 'check' -Label 'frozen-rc3-check'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D3.check.exit' -Run $check -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'D3.check.state' -Run $check -Expected 'RC3_ALREADY_INSTALLED') | Out-Null
    $variant = Get-DocVariant $check.Json
    Add-CaseCheck $Ctx (Assert-Condition -Id 'D3.check.variant' -Condition ($variant -eq 'FROZEN_RC3') -PassDetail "variant=$variant" -FailDetail "variant='$variant' expected 'FROZEN_RC3'" -Expected 'FROZEN_RC3' -Actual $variant) | Out-Null
    $checkText = if ($check.Json) { $check.Json | ConvertTo-Json -Depth 30 } else { '' }
    $mentionsAbsentAdditions = ($checkText -match 'unified') -or ($checkText -match 'setup\.ps1') -or ($checkText -match 'WARN')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'D3.check.reportsUnifiedToolingAbsent' -Condition $mentionsAbsentAdditions `
        -PassDetail 'CHECK documents that the unified tooling additions are absent (WARN/unified mention) and that no action is needed' `
        -FailDetail 'CHECK gives no indication that unified tooling files are absent for a frozen-RC3 install' -Expected 'documented limitation' -Actual (Limit-Text $checkText 300)) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D3.check.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'CHECK on frozen-RC3 install') | Out-Null
    $plan = Invoke-EngineAction $Ctx 'plan' -Label 'frozen-rc3-plan'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D3.plan.exit' -Run $plan -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineJsonValue -Id 'D3.plan.noOp' -Run $plan -Path 'plan.noOp' -Expected $true) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D3.plan.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'PLAN on frozen-RC3 install') | Out-Null
    $noop = Invoke-EngineAction $Ctx 'apply-noop' -Label 'frozen-rc3-noop'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'D3.noopApply.exit' -Run $noop -ExpectedExit 0) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'D3.noopApply.zeroWrites' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'no-op APPLY frozen-RC3') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'D3.noopApply.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

# ===========================================================================
# E10 - engine-level wrong -TargetVersion refusal (option is engine-owned; the
# user-facing setup.ps1 D8 CLI does not expose -TargetVersion)
# ===========================================================================

function Test-CaseE1 {
    param($Ctx)
    Invoke-UnknownStateRefusal -Ctx $Ctx -Prefix 'E1' -Variant 'tampered:README.md' -ExpectPath 'README.md' -ExpectCategories @('modified', 'tampered')
}

function Test-CaseE2 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    # non-hotfix edit of cordis.patch.yml: hash must match neither allowed hotfix
    Add-FixturePayloadTamper -Fixture $fixture -RelPath 'bundle/cnki-research/cordis.patch.yml' -Marker "`nSANDBOX_TAMPER_MARKER`n"
    $cordisSha = Get-Sha256File (Join-Path $fixture.InstallRoot 'bundle\cnki-research\cordis.patch.yml')
    $identity = Get-FrozenIdentity
    $neitherHotfix = ($cordisSha -ne $identity.HotfixLineRemovedSha256) -and ($cordisSha -ne $identity.HotfixTextRemovedSha256)
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E2.tamperedHashIsNotHotfix' -Condition $neitherHotfix -PassDetail 'tampered cordis hash matches neither allowed hotfix value' -FailDetail 'tampered cordis hash equals an allowed hotfix value (test fixture defect)' -Expected 'not a hotfix hash' -Actual $cordisSha) | Out-Null
    $preInstall = Get-InstallSnapshot $fixture
    $preRoot = Get-SandboxSnapshot $fixture
    $check = Invoke-EngineAction $Ctx 'check' -Label 'tampered-cordis'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E2.check.exit' -Run $check -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'E2.check.state' -Run $check -Expected 'UNKNOWN_OR_MODIFIED') | Out-Null
    $conflicts = @(Get-JsonValue $check.Json 'conflicts')
    $match = @($conflicts | Where-Object { [string]::Equals([string]$_.path, 'bundle/cnki-research/cordis.patch.yml', [System.StringComparison]::OrdinalIgnoreCase) })
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E2.conflictListed' -Condition ($match.Count -ge 1) -PassDetail 'cordis conflict listed' -FailDetail 'cordis conflict not listed' -Expected 'cordis conflict' -Actual @($conflicts | ForEach-Object { $_.path })) | Out-Null
    $apply = Invoke-EngineAction $Ctx 'apply' -Label 'apply-tampered-cordis'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E2.apply.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'E2.untouched' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E2.noWrites' -Before $preRoot -After (Get-SandboxSnapshot $fixture) -Label 'whole-sandbox') | Out-Null
}

function Test-CaseE3 {
    param($Ctx)
    Invoke-UnknownStateRefusal -Ctx $Ctx -Prefix 'E3' -Variant 'missing:CHANGELOG.md' -ExpectPath 'CHANGELOG.md' -ExpectCategories @('missing')
}

function Test-CaseE4 {
    param($Ctx)
    Invoke-UnknownStateRefusal -Ctx $Ctx -Prefix 'E4' -Variant 'mixed' -ExpectPath 'README.md' -ExpectCategories @('mixed', 'modified', 'unexpected-version') -ExpectJsonToken 'MIXED_RC2_RC3'
}

function Test-CaseE5 {
    param($Ctx)
    Invoke-UnknownStateRefusal -Ctx $Ctx -Prefix 'E5' -Variant 'clean' -ExpectPath 'VERSION' -ExpectCategories @('tampered-version', 'unexpected-version', 'modified') `
        -Prepare { param($f) Set-FixtureVersionText -Fixture $f -Text "9.9.9`n" | Out-Null }
}

function Test-CaseE6 {
    param($Ctx)
    Invoke-UnknownStateRefusal -Ctx $Ctx -Prefix 'E6' -Variant 'clean' -ExpectPath 'manifest.json' -ExpectCategories @('tampered-manifest', 'modified') `
        -Prepare { param($f) Add-FixturePayloadTamper -Fixture $f -RelPath 'manifest.json' -Marker "`nSANDBOX_MANIFEST_TAMPER`n" | Out-Null }
}

# ===========================================================================
# CASES E - failure injection (TEST-ONLY fault plans)
# ===========================================================================

function Invoke-FaultApplyCase {
    param($Ctx, [string]$Prefix, [string[]]$Faults, [string]$ExpectedPhaseToken, [switch]$NoPhaseAssert)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preInstall = Get-InstallSnapshot $fixture
    $preRoot = Get-SandboxSnapshot $fixture
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix "$Prefix.plan"
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name $Prefix -Faults $Faults
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -TestMode -Label 'fault-apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id "$Prefix.apply.exit" -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id "$Prefix.payloadRestored" -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id "$Prefix.noRc3Claim" -Fixture $fixture) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    if (-not $NoPhaseAssert) {
        if ($txnId) {
            Add-CaseCheck $Ctx (Assert-TransactionPhase -Id "$Prefix.txnPhase" -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @($ExpectedPhaseToken) -Contain) | Out-Null
        } else {
            Add-CaseCheck $Ctx (New-AssertResult -Id "$Prefix.txnPhase" -Status FAIL -Detail 'no transaction directory after injected failure (transaction record required for recovery evidence)') | Out-Null
        }
    }
    return [pscustomobject]@{ Fixture = $fixture; PreInstall = $preInstall; PreRoot = $preRoot; Apply = $apply; TxnId = $txnId; PlanId = $planId; FaultFile = $faultFile }
}

function Test-CaseG1 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $before = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G1.plan'
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name 'G1' -Faults @('FAIL_BACKUP:2')
    # NOT setting CNKI_UPGRADE_TEST_MODE: the fault-plan parameter itself must be refused
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -Label 'fault-without-testmode'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G1.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'G1.refused' -Run $apply -Token 'FAULT_INJECTION_DISALLOWED' -MustContain -Label 'fault-injection guard') | Out-Null
    $after = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'G1.untouched' -Before $before -After $after -Label 'whole-sandbox after refused fault plan') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'G1.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

function Test-CaseG2 {
    param($Ctx)
    $r = Invoke-FaultApplyCase -Ctx $Ctx -Prefix 'G2' -Faults @('FAIL_BACKUP:2') -ExpectedPhaseToken 'FAILED_RESTORED'
}

function Test-CaseG3 {
    param($Ctx)
    $r = Invoke-FaultApplyCase -Ctx $Ctx -Prefix 'G3' -Faults @('FAIL_STAGE_HASH:3') -ExpectedPhaseToken 'FAILED_RESTORED'
}

function Test-CaseG4 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preInstall = Get-InstallSnapshot $fixture
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G4.plan'
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name 'G4' -Faults @('FAIL_APPLY_INDEX:5')
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -TestMode -Label 'fail-apply-index'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G4.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    Add-CaseCheck $Ctx (Assert-Condition -Id 'G4.transactionRecorded' -Condition (-not [string]::IsNullOrEmpty($txnId)) -PassDetail "failure recorded in transaction '$txnId'" -FailDetail 'no transaction id after injected apply failure' -Expected '<id>' -Actual $txnId) | Out-Null
    if ($txnId) {
        Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'G4.txnPhase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('FAILED_RESTORED') -Contain) | Out-Null
        $txnRec = Get-TransactionRecord -InstallRoot $fixture.InstallRoot -TransactionId $txnId
        $restoreVerified = Get-JsonValue $txnRec 'restoreVerified'
        Add-CaseCheck $Ctx (Assert-Condition -Id 'G4.restoreVerified' -Condition ($restoreVerified -eq $true) -PassDetail 'auto-restore verified (transaction.restoreVerified=true)' -FailDetail "transaction.restoreVerified='$restoreVerified'" -Expected $true -Actual $restoreVerified) | Out-Null
    }
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'G4.autoRestoreAllPreBytes' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id 'G4.noRc3Claim' -Fixture $fixture) | Out-Null
    Add-CaseCheck $Ctx (Assert-EnvMetadata -Id 'G4.envUnchanged' -InstallRoot $fixture.InstallRoot -ExpectedDistribution $script:G.SourceVersion) | Out-Null
}

function Test-CaseG5 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preInstall = Get-InstallSnapshot $fixture
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G5.plan'
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name 'G5' -Faults @('CRASH_AFTER_APPLY:4')
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $crash = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -TestMode -Label 'crash-after-apply'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'G5.crashNonZeroExit' -Condition ($crash.ExitCode -ne 0) -PassDetail "simulated hard crash exited $($crash.ExitCode) (no auto-restore, as specified)" -FailDetail "CRASH_AFTER_APPLY exited 0 (should die without auto-restore)" -Expected 'nonzero' -Actual $crash.ExitCode) | Out-Null
    $postTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $newTxns = @($postTxnIds | Where-Object { $preTxnIds -notcontains $_ })
    Add-CaseCheck $Ctx (Assert-Condition -Id 'G5.txnExists' -Condition ($newTxns.Count -ge 1) -PassDetail "crash left transaction(s): $($newTxns -join ', ')" -FailDetail 'CRASH_AFTER_APPLY left no transaction state (cannot recover)' -Expected '>=1' -Actual $newTxns.Count) | Out-Null
    $txnId = if ($newTxns.Count -ge 1) { [string]$newTxns[$newTxns.Count - 1] } else { $null }
    # CHECK must report the pending transaction as FAIL
    $check = Invoke-EngineAction $Ctx 'check' -Label 'after-crash'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G5.check.exit' -Run $check -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineCheckStatus -Id 'G5.check.pendingTxn' -Run $check -CheckIdPattern 'env.pendingTransaction' -ExpectedStatus @('FAIL') -MustExist) | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'G5.check.pendingToken' -Run $check -Token 'PENDING_TRANSACTION' -MustContain -Label 'pending transaction reported') | Out-Null
    # APPLY must be refused while the transaction is pending
    $apply2 = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply-with-pending'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G5.applyRefused.exit' -Run $apply2 -ExpectedExit 2 -RequireJson) | Out-Null
    # ROLLBACK must restore pre-upgrade bytes
    if ($txnId) {
        $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback-after-crash'
        Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G5.rollback.exit' -Run $rollback -ExpectedExit 0 -RequireJson) | Out-Null
        Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'G5.rollback.phase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('ROLLED_BACK') -Contain) | Out-Null
        Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'G5.rollback.restored' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
        Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id 'G5.rollback.noRc3Claim' -Fixture $fixture) | Out-Null
    }
}

function Test-CaseG6 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preInstall = Get-InstallSnapshot $fixture
    $preRoot = Get-SandboxSnapshot $fixture
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G6.plan'
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name 'G6' -Faults @('CRASH_AFTER_BACKUP')
    $beforeCrashTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $crash = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -TestMode -Label 'crash-after-backup'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'G6.crashNonZeroExit' -Condition ($crash.ExitCode -ne 0) -PassDetail "simulated hard crash exited $($crash.ExitCode)" -FailDetail 'CRASH_AFTER_BACKUP exited 0' -Expected 'nonzero' -Actual $crash.ExitCode) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'G6.noPayloadChange' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id 'G6.noRc3Claim' -Fixture $fixture) | Out-Null
    $newTxns = @(@(Get-TransactionIds -InstallRoot $fixture.InstallRoot) | Where-Object { $beforeCrashTxnIds -notcontains $_ })
    $txnId = if ($newTxns.Count -ge 1) { [string]$newTxns[$newTxns.Count - 1] } else { $null }
    if ($txnId) {
        $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback-after-backup-crash'
        Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G6.rollback.exit' -Run $rollback -ExpectedExit 0 -RequireJson) | Out-Null
        Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'G6.rollback.phase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('ABORTED', 'ROLLED_BACK') -Contain) | Out-Null
        $second = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'second-rollback'
        Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G6.rollbackIdempotent.exit' -Run $second -ExpectedExit 0 -RequireJson) | Out-Null
        Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'G6.rollbackIdempotent.bytes' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    } else {
        Add-CaseCheck $Ctx (New-AssertResult -Id 'G6.transactionRecorded' -Status FAIL -Detail 'CRASH_AFTER_BACKUP left no transaction to roll back') | Out-Null
    }
    $installRel = Get-RelPath -Root $fixture.Root -Path $fixture.InstallRoot
    $outside = Compare-Snapshots -Before $preRoot -After (Get-SandboxSnapshot $fixture) -IgnorePrefixes @($installRel)
    Add-CaseCheck $Ctx (Assert-Condition -Id 'G6.noWritesOutside' -Condition $outside.Equal -PassDetail 'no writes outside install root' -FailDetail (Format-SnapshotDiff -Diff $outside) -Expected 'identical' -Actual "added=$($outside.AddedCount) changed=$($outside.ChangedCount)") | Out-Null
}

function Test-CaseG7 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preInstall = Get-InstallSnapshot $fixture
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G7.plan'
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name 'G7' -Faults @('FAIL_VERIFY')
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -TestMode -Label 'fail-verify'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G7.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    if ($txnId) { Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'G7.txnPhase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('FAILED_RESTORED') -Contain) | Out-Null }
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'G7.autoRestore' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id 'G7.noRc3Claim' -Fixture $fixture) | Out-Null
    Add-CaseCheck $Ctx (Assert-EnvMetadata -Id 'G7.envUnchanged' -InstallRoot $fixture.InstallRoot -ExpectedDistribution $script:G.SourceVersion) | Out-Null
}

function Test-CaseG8 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $before = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G8.plan'
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name 'G8' -Faults @('SIMULATE_DISK_LOW')
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -TestMode -Label 'simulate-disk-low'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G8.apply.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'G8.spaceReported' -Run $apply -Token 'space.sufficient' -MustContain -Label 'disk-low refusal') | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'G8.untouched' -Before $before -After (Get-SandboxSnapshot $fixture) -Label 'whole-sandbox after SIMULATE_DISK_LOW') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'G8.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
    # CHECK-level injection: ENGINE_SPEC §1 restricts -FaultPlan to apply/verify/rollback;
    # try it and report honestly if the engine ignores the parameter for CHECK.
    $check = Invoke-EngineAction $Ctx 'check' -Extra @{ FaultPlan = $faultFile } -TestMode -Label 'check-disk-low'
    if ($check.ExitCode -eq 2) {
        Add-CaseCheck $Ctx (Assert-Condition -Id 'G8.checkRefused' -Condition $true -PassDetail 'CHECK with SIMULATE_DISK_LOW also refuses (exit 2)' -FailDetail 'CHECK with SIMULATE_DISK_LOW did not refuse as expected (exit != 2)' -Expected 2 -Actual $check.ExitCode) | Out-Null
    } else {
        Add-CaseCheck $Ctx (New-AssertResult -Id 'G8.checkRefused' -Status 'NOT TESTED' `
            -Detail "ENGINE_SPEC §1 restricts -FaultPlan to apply/verify/rollback; CHECK accepted the parameter with exit $($check.ExitCode) - CHECK-level disk-low refusal is not separately injectable") | Out-Null
    }
}

function Test-CaseG9 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G9.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G9.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    if (-not $txnId) { Add-CaseCheck $Ctx (New-AssertResult -Id 'G9.txnId' -Status FAIL -Detail 'no transaction id for corrupt-transaction test'); return }
    $txnDir = Get-InstallTxnPath $fixture $txnId
    $txnFile = Join-Path $txnDir 'transaction.json'
    $backupDir = Join-Path $txnDir 'backup'
    # corrupt transaction.json (simulated post-crash corruption); keep the backup
    [System.IO.File]::WriteAllText($txnFile, '{ this is not valid json ', (New-Utf8NoBom))
    $postCorrupt = Get-InstallSnapshot $fixture
    $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback-corrupt-txn'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G9.rollback.exit' -Run $rollback -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'G9.refusalToken' -Run $rollback -Token 'TRANSACTION_CORRUPT' -MustContain -Label 'corrupt transaction refusal') | Out-Null
    Add-CaseCheck $Ctx (Assert-Condition -Id 'G9.backupKept' -Condition ([System.IO.Directory]::Exists($backupDir)) -PassDetail 'corrupt transaction refused and backup kept' -FailDetail 'backup directory missing after refused rollback' -Expected 'exists' -Actual 'ABSENT') | Out-Null
    Add-CaseCheck $Ctx (Assert-TreeMatchesSnapshot -Id 'G9.filesUntouched' -Root $fixture.InstallRoot -ExpectedSnapshot $postCorrupt -Label 'install vs pre-rollback snapshot') | Out-Null
}

function Test-CaseG10 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preInstall = Get-InstallSnapshot $fixture
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G10.plan'
    Set-FixtureReadOnlyAttribute -Fixture $fixture -RelPath 'README.md'
    $readme = Join-Path $fixture.InstallRoot 'README.md'
    $readmeSha = Get-Sha256File $readme
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply-readonly-target'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G10.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    if ($txnId) {
        Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'G10.txnPhase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('FAILED_RESTORED') -Contain) | Out-Null
        $txnRec = Get-TransactionRecord -InstallRoot $fixture.InstallRoot -TransactionId $txnId
        $restoreVerified = Get-JsonValue $txnRec 'restoreVerified'
        Add-CaseCheck $Ctx (Assert-Condition -Id 'G10.restoreVerified' -Condition ($restoreVerified -eq $true) -PassDetail 'real write-permission failure auto-restored (restoreVerified=true)' -FailDetail "transaction.restoreVerified='$restoreVerified'" -Expected $true -Actual $restoreVerified) | Out-Null
    }
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'G10.autoRestore' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    $afterSha = Get-Sha256File $readme
    Add-CaseCheck $Ctx (Assert-Condition -Id 'G10.readmePreBytes' -Condition ($afterSha -eq $readmeSha) -PassDetail 'read-only target file bytes unchanged after auto-restore' -FailDetail "README.md bytes changed (sha=$afterSha expected=$readmeSha)" -Expected $readmeSha -Actual $afterSha) | Out-Null
    Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id 'G10.noRc3Claim' -Fixture $fixture) | Out-Null
    Set-FixtureReadOnlyAttribute -Fixture $fixture -RelPath 'README.md' -Clear
}

# ===========================================================================
# CASES F - rollback
# ===========================================================================

function Test-CaseF1 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $model = $script:G.PackageModel
    $preInstall = Get-InstallSnapshot $fixture
    $preRoot = Get-SandboxSnapshot $fixture
    $run = Invoke-UpgradeToUnifiedTarget -Ctx $Ctx -Fixture $fixture -Prefix 'F1'
    $txnId = $run.TxnId
    if (-not $txnId) { Add-CaseCheck $Ctx (New-AssertResult -Id 'F1.txnId' -Status FAIL -Detail 'no transaction id after successful APPLY'); return }
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id 'F1.appliedTarget' -InstallRoot $fixture.InstallRoot -Model $model) | Out-Null
    $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F1.rollback.exit' -Run $rollback -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'F1.rollback.phase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('ROLLED_BACK') -Contain) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'F1.allPreBytes' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-AddedPayloadFilesAbsent -Id 'F1.addedFilesDeleted' -InstallRoot $fixture.InstallRoot -Model $model) | Out-Null
    Add-CaseCheck $Ctx (Assert-CreatedDirectoriesRemovedAfterRollback -Id 'F1.createdDirsRemoved' -InstallRoot $fixture.InstallRoot -TransactionId $txnId) | Out-Null
    Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id 'F1.noTargetClaim' -Fixture $fixture) | Out-Null
    Add-CaseCheck $Ctx (Assert-EnvMetadata -Id 'F1.envRestored' -InstallRoot $fixture.InstallRoot -ExpectedDistribution $script:G.SourceVersion) | Out-Null
    $postRollbackInstall = Get-InstallSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-SubtreeEqual -Id 'F1.venvUnchanged' -Before $preInstall -After $postRollbackInstall -Prefixes @('.venv') -Label '.venv subtree') | Out-Null
    $postRoot = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-UserDataUnchanged -Id 'F1.userDataUnchanged' -Before $preRoot -After $postRoot -UserDataPrefixes @('home', 'dsh-home')) | Out-Null
    $installRel = Get-RelPath -Root $fixture.Root -Path $fixture.InstallRoot
    $outside = Compare-Snapshots -Before $preRoot -After $postRoot -IgnorePrefixes @($installRel)
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F1.noWritesOutside' -Condition $outside.Equal -PassDetail 'no writes outside the install root during apply+rollback' -FailDetail (Format-SnapshotDiff -Diff $outside) -Expected 'identical' -Actual "added=$($outside.AddedCount) changed=$($outside.ChangedCount)") | Out-Null
    $second = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'second-rollback'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F1.secondRollback.exit' -Run $second -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'F1.secondRollback.phase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('ROLLED_BACK') -Contain) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'F1.secondRollback.bytes' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    $verify = Invoke-EngineAction $Ctx 'verify' -Label 'verify-after-rollback'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F1.verify.exit' -Run $verify -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-FileUpgradeComplete -Id 'F1.verifyNotComplete' -Run $verify -Expected 'FAIL') | Out-Null
}

function Test-CaseF2 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'F2.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F2.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    if (-not $txnId) { Add-CaseCheck $Ctx (New-AssertResult -Id 'F2.txnId' -Status FAIL -Detail 'no transaction id after successful APPLY'); return }
    # user edits a payload file after the upgrade
    Add-FixturePayloadTamper -Fixture $fixture -RelPath 'README.md' -Marker "`nUSER_EDIT_AFTER_UPGRADE`n"
    $editedSha = Get-Sha256File (Join-Path $fixture.InstallRoot 'README.md')
    $beforeRollback = Get-InstallSnapshot $fixture
    $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback-with-user-edit'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F2.rollback.exit' -Run $rollback -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'F2.conflictToken' -Run $rollback -Token 'ROLLBACK_CONFLICT' -MustContain -Label 'rollback conflict refusal') | Out-Null
    $afterRollback = Get-InstallSnapshot $fixture
    $afterSha = Get-Sha256File (Join-Path $fixture.InstallRoot 'README.md')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F2.userEditNotOverwritten' -Condition ($afterSha -eq $editedSha) -PassDetail 'rollback refused and did NOT overwrite the user-modified file' -FailDetail 'rollback overwrote a user-modified file (data-loss risk)' -Expected $editedSha -Actual $afterSha) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'F2.filesUntouched' -Before $beforeRollback -After $afterRollback -Label 'install tree after refused rollback') | Out-Null
    $txnRec = Get-TransactionRecord -InstallRoot $fixture.InstallRoot -TransactionId $txnId
    $phase = [string](Get-JsonValue $txnRec 'phase')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F2.txnPhaseUnchanged' -Condition ($phase -eq 'COMMITTED') -PassDetail 'refused rollback left transaction phase COMMITTED' -FailDetail "transaction phase became '$phase' after a refused rollback" -Expected 'COMMITTED' -Actual $phase) | Out-Null
}

function Test-CaseF3 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'F3.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F3.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    if (-not $txnId) { Add-CaseCheck $Ctx (New-AssertResult -Id 'F3.txnId' -Status FAIL -Detail 'no transaction id after successful APPLY'); return }
    $txnDir = Get-InstallTxnPath $fixture $txnId
    $backupReadme = Join-Path $txnDir 'backup\README.md'
    if (-not [System.IO.File]::Exists($backupReadme)) { Add-CaseCheck $Ctx (New-AssertResult -Id 'F3.backupPresent' -Status FAIL -Detail "backup file missing: $backupReadme"); return }
    # corrupt one backup file byte-exactly
    $corrupt = (New-Utf8NoBom).GetBytes("CORRUPTED_SANDBOX_BACKUP_$([guid]::NewGuid().ToString('N'))`n")
    [System.IO.File]::WriteAllBytes($backupReadme, $corrupt)
    $beforeRollback = Get-InstallSnapshot $fixture
    $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback-corrupt-backup'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F3.rollback.exit' -Run $rollback -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'F3.refusalToken' -Run $rollback -Token 'BACKUP_INCOMPLETE' -MustContain -Label 'corrupt-backup refusal') | Out-Null
    $afterRollback = Get-InstallSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'F3.filesUntouched' -Before $beforeRollback -After $afterRollback -Label 'install tree after refused rollback (corrupt backup)') | Out-Null
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F3.backupKept' -Condition ([System.IO.Directory]::Exists((Join-Path $txnDir 'backup'))) -PassDetail 'corrupt backup kept for manual recovery' -FailDetail 'backup directory deleted after refused rollback' -Expected 'exists' -Actual 'ABSENT') | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id 'F3.stillRc3' -InstallRoot $fixture.InstallRoot -Label 'install still at RC3 after refused rollback') | Out-Null
}

# ===========================================================================
# CASES G - environment / path handling / safety refusals
# ===========================================================================

function Test-CaseB9 {
    param($Ctx)
    $Ctx.SandboxRoot = Join-Path $Ctx.CaseRoot '沙箱 升级 测试 & (v1)'
    $fixture = New-CaseFixture $Ctx 'clean'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B9.pathHasChineseSpaceSpecial' -Condition ($fixture.Root.Contains('沙箱') -and $fixture.Root.Contains(' ') -and $fixture.Root.Contains('&') -and $fixture.Root.Contains('(')) `
        -PassDetail "fixture root contains Chinese characters, spaces, '&' and parentheses: $($fixture.Root)" -FailDetail "unexpected fixture root: $($fixture.Root)" -Expected 'Chinese/space/&/()' -Actual $fixture.Root) | Out-Null
    $before = Get-SandboxSnapshot $fixture
    $check = Invoke-EngineAction $Ctx 'check' -Label 'chinese-path'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B9.check.exit' -Run $check -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'B9.check.state' -Run $check -Expected 'RC2_CLEAN') | Out-Null
    Add-CaseCheck $Ctx (Assert-ReadOnlyAction -Id 'B9.check.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -ActionLabel 'CHECK on Chinese/space path') | Out-Null
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'B9.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply-chinese-path'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B9.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id 'B9.payloadEqualsRc3' -InstallRoot $fixture.InstallRoot -Label 'Chinese/space path install vs RC3') | Out-Null
    Add-CaseCheck $Ctx (Assert-EnvMetadata -Id 'B9.envMetadata' -InstallRoot $fixture.InstallRoot -ExpectedDistribution $script:G.TargetVersion -ExpectUpgradeRecord) | Out-Null
    Add-CaseCheck $Ctx (Assert-JunctionsUnchanged -Id 'B9.profileUnchanged' -DshHome $fixture.DshHome -InstallRoot $fixture.InstallRoot -Profile 'desktop') | Out-Null
    $verify = Invoke-EngineAction $Ctx 'verify' -Label 'verify'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B9.verify.exit' -Run $verify -ExpectedExit 0 -RequireJson) | Out-Null
}

function Test-CaseB10 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'long-path'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B10.pathLength' -Condition (($fixture.InstallRootPathLength -ge 160) -and ($fixture.LongestInstallFilePath -ge 220)) `
        -PassDetail "long path: install root length=$($fixture.InstallRootPathLength), longest managed file path=$($fixture.LongestInstallFilePath)" `
        -FailDetail "path not long enough: root=$($fixture.InstallRootPathLength) longest=$($fixture.LongestInstallFilePath)" -Expected 'root>=160 / file>=220' -Actual "$($fixture.InstallRootPathLength)/$($fixture.LongestInstallFilePath)") | Out-Null
    $before = Get-SandboxSnapshot $fixture
    $check = Invoke-EngineAction $Ctx 'check' -Label 'long-path'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B10.check.exit' -Run $check -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'B10.check.state' -Run $check -Expected 'RC2_CLEAN') | Out-Null
    Add-CaseCheck $Ctx (Assert-ReadOnlyAction -Id 'B10.check.readOnly' -Before $before -After (Get-SandboxSnapshot $fixture) -ActionLabel 'CHECK on long path') | Out-Null
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'B10.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply-long-path'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B10.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id 'B10.payloadEqualsRc3' -InstallRoot $fixture.InstallRoot -Label 'long-path install vs RC3') | Out-Null
    Add-CaseCheck $Ctx (Assert-EnvMetadata -Id 'B10.envMetadata' -InstallRoot $fixture.InstallRoot -ExpectedDistribution $script:G.TargetVersion -ExpectUpgradeRecord) | Out-Null
    $verify = Invoke-EngineAction $Ctx 'verify' -Label 'verify'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B10.verify.exit' -Run $verify -ExpectedExit 0 -RequireJson) | Out-Null
    $outcome = Get-FileUpgradeOutcome -Json $verify.Json
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B10.verifyOutcome' -Condition ($outcome.Outcome -eq 'PASS') -PassDetail 'long-path upgrade FILE_UPGRADE_COMPLETE=PASS' -FailDetail "long-path VERIFY outcome=$($outcome.Outcome)" -Expected 'PASS' -Actual $outcome.Outcome) | Out-Null
}

function Test-CaseE7 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $baseline = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $analysis = Join-Path $script:G.Layout.Worktree '_analysis\rc2'
    $analysisBefore = @()
    if ([System.IO.Directory]::Exists($analysis)) { $analysisBefore = @(Get-TreeSnapshot -Root $analysis) }
    $unsafe = @(
        @{ Label = 'drive-root'; Path = 'C:\' },
        @{ Label = 'windows-dir'; Path = $env:WINDIR },
        @{ Label = 'program-files'; Path = ${env:ProgramFiles} }
    )
    if ([System.IO.Directory]::Exists($analysis)) {
        $unsafe += @{ Label = 'worktree-analysis-rc2'; Path = $analysis }
    } else {
        # T10: only when the -PackageDir-inferred worktree really has no package
        # analysis dir (e.g. a custom/temp package used during pre-build
        # validation) is this sub-check honestly NOT TESTED. The final
        # frozen-package run uses the default -PackageDir, where _analysis\rc2
        # exists and the real-path refusal is exercised for real.
        $notTestedReason = "reason: package analysis path absent for this -PackageDir-inferred worktree: '$analysis' (custom/temp package); the final default-PackageDir run exercises the real path"
        Add-CaseCheck $Ctx (New-AssertResult -Id 'E7.worktree-analysis-rc2.exit' -Status 'NOT TESTED' -Detail $notTestedReason) | Out-Null
        Add-CaseCheck $Ctx (New-AssertResult -Id 'E7.worktree-analysis-rc2.refused' -Status 'NOT TESTED' -Detail $notTestedReason) | Out-Null
    }
    foreach ($item in $unsafe) {
        # Final setup CLI: CHECK on a directory without installation markers is a
        # designed NOT_INSTALLED (read-only) result; the refusal happens on the
        # mutating action. Use `-Action upgrade -Yes` (harness action apply-noop)
        # and require a fail-closed refusal with an explicit reason token.
        $run = Invoke-Engine -Ctx $Ctx -Action 'apply-noop' -InstallRoot $item.Path -DshHome $fixture.DshHome -Label ("unsafe-" + $item.Label) -Params @{}
        Add-CaseCheck $Ctx (Assert-EngineExit -Id ("E7." + $item.Label + ".exit") -Run $run -ExpectedExit 2 -RequireJson) | Out-Null
        $jsonText = if ($run.Json) { $run.Json | ConvertTo-Json -Depth 20 } else { '' }
        $refused = $jsonText -match 'TARGET_STATE_UNKNOWN' -or $jsonText -match 'NOT_INSTALLED_USE_INSTALL' -or $jsonText -match 'PACKAGE_ROOT_EQUALS_INSTALL_ROOT' -or $jsonText -match 'EXTRACTED_OVER_INSTALL' -or $jsonText -match 'INSTALL_ROOT_FORBIDDEN' -or $jsonText -match 'INSTALL_ROOT_IS_DRIVE_ROOT'
        Add-CaseCheck $Ctx (Assert-Condition -Id ("E7." + $item.Label + ".refused") -Condition $refused `
            -PassDetail "unsafe InstallRoot '$($item.Path)' refused fail-closed by the upgrade gate with an explicit reason token" `
            -FailDetail "unsafe InstallRoot was NOT refused (exit=$($run.ExitCode)): '$($item.Path)'; JSON: $(Limit-Text $jsonText 600)" -Expected 'TARGET_STATE_UNKNOWN/NOT_INSTALLED_USE_INSTALL/...' -Actual (Limit-Text $jsonText 300)) | Out-Null
    }
    # InstallRoot == extracted candidate PackageRoot is the legitimate self-mode /
    # fresh in-place layout: CHECK is read-only NOT_INSTALLED, upgrade refuses with
    # PACKAGE_ROOT_EQUALS_INSTALL_ROOT. Prove both read-only (package tree unchanged).
    $pkgTreeBefore = Get-FileTreeHash -Root $script:G.PackageRoot
    $selfCheck = Invoke-Engine -Ctx $Ctx -Action 'check' -InstallRoot $script:G.PackageRoot -DshHome $fixture.DshHome -Label 'self-mode-check' -Params @{}
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E7.upgrade-package-itself.check.exit' -Run $selfCheck -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'E7.upgrade-package-itself.check.state' -Run $selfCheck -Expected 'NOT_INSTALLED') | Out-Null
    $selfUpgrade = Invoke-Engine -Ctx $Ctx -Action 'apply-noop' -InstallRoot $script:G.PackageRoot -DshHome $fixture.DshHome -Label 'self-mode-upgrade' -Params @{}
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E7.upgrade-package-itself.exit' -Run $selfUpgrade -ExpectedExit 2 -RequireJson) | Out-Null
    $selfText = if ($selfUpgrade.Json) { $selfUpgrade.Json | ConvertTo-Json -Depth 20 } else { '' }
    $selfRefused = $selfText -match 'PACKAGE_ROOT_EQUALS_INSTALL_ROOT' -or $selfText -match 'NOT_INSTALLED_USE_INSTALL' -or $selfText -match 'TARGET_STATE_UNKNOWN' -or $selfText -match 'EXTRACTED_OVER_INSTALL'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E7.upgrade-package-itself.refused' -Condition $selfRefused `
        -PassDetail 'self-mode layout: CHECK read-only NOT_INSTALLED, upgrade refused with an explicit reason token' `
        -FailDetail "self-mode upgrade not refused with an expected token; JSON: $(Limit-Text $selfText 500)" -Expected 'PACKAGE_ROOT_EQUALS_INSTALL_ROOT' -Actual (Limit-Text $selfText 300)) | Out-Null
    $pkgTreeAfter = Get-FileTreeHash -Root $script:G.PackageRoot
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E7.upgrade-package-itself.packageTreeUnchanged' -Condition ($pkgTreeBefore.TreeSha256 -eq $pkgTreeAfter.TreeSha256) `
        -PassDetail "candidate package tree unchanged after self-mode CHECK+upgrade refusal ($($pkgTreeBefore.FileCount) files, tree sha $($pkgTreeBefore.TreeSha256))" `
        -FailDetail 'candidate package tree changed during self-mode probes (must be read-only)' -Expected $pkgTreeBefore.TreeSha256 -Actual $pkgTreeAfter.TreeSha256) | Out-Null
    $after = Get-SandboxSnapshot $fixture
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E7.sandboxUntouched' -Before $baseline -After $after -Label 'fixture sandbox while pointing at unsafe roots') | Out-Null
    if ($analysisBefore.Count -gt 0) {
        $analysisAfter = @(Get-TreeSnapshot -Root $analysis)
        Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E7.analysisUntouched' -Before $analysisBefore -After $analysisAfter -Label '_analysis\rc2 read-only proof') | Out-Null
    }
    # simulated production DSH home / .cnki-mcp refusal (never the real paths):
    # override USERPROFILE/DSH_HOME for the child to the isolated fixture home.
    $simHome = $fixture.UserHome
    $simProfileEnv = @{ USERPROFILE = $simHome; DSH_HOME = (Join-Path $simHome '.dsh') }
    $simLive = Join-Path $simHome '.dsh'
    $simCnki = Join-Path $simHome '.cnki-mcp'
    $userDataBefore = Get-TreeSnapshot -Root $simHome
    foreach ($pair in @(@{ Label = 'simulated-production-dsh-home'; Path = $simLive }, @{ Label = 'simulated-production-cnki-mcp'; Path = $simCnki })) {
        $run = Invoke-Engine -Ctx $Ctx -Action 'apply-noop' -InstallRoot $pair.Path -DshHome $fixture.DshHome -ChildEnv $simProfileEnv -Label ("sim-" + $pair.Label) -Params @{}
        Add-CaseCheck $Ctx (Assert-EngineExit -Id ("E7." + $pair.Label + ".exit") -Run $run -ExpectedExit 2 -RequireJson) | Out-Null
        $jsonText = if ($run.Json) { $run.Json | ConvertTo-Json -Depth 20 } else { '' }
        $refused = $jsonText -match 'TARGET_STATE_UNKNOWN' -or $jsonText -match 'NOT_INSTALLED_USE_INSTALL' -or $jsonText -match 'PRODUCTION' -or $jsonText -match 'INSTALL_ROOT_FORBIDDEN' -or $jsonText -match 'INSTALL_ROOT_IS_DRIVE_ROOT'
        Add-CaseCheck $Ctx (Assert-Condition -Id ("E7." + $pair.Label + ".refused") -Condition $refused `
            -PassDetail "production-like path refused fail-closed without touching it: '$($pair.Path)'" -FailDetail "production-like path NOT refused: '$($pair.Path)'; JSON: $(Limit-Text $jsonText 400)" -Expected 'refused (no writes)' -Actual (Limit-Text $jsonText 300)) | Out-Null
    }
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'E7.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
    $userDataAfter = Get-TreeSnapshot -Root $simHome
    # T6: starting a child powershell.exe with a REDIRECTED USERPROFILE makes
    # Windows PowerShell itself write its startup-profile data under
    # AppData\Local\Microsoft\Windows\PowerShell\. That is OS/host noise, not
    # an engine write (the engine only reads/parses). Keep the RAW whole-home
    # diff as evidence, classify it, then assert the real user-data subtrees:
    # .dsh / .cnki-mcp / AppData/Local/ms-playwright / Documents.
    $userDataFullDiff = Compare-Snapshots -Before $userDataBefore -After $userDataAfter
    $noiseReport = [ordered]@{
        schemaVersion = 1
        case          = 'G3-unsafe-install-roots'
        description   = 'Raw whole-simulated-home diff observed while CHECK runs against unsafe/production-like InstallRoots with redirected USERPROFILE/DSH_HOME'
        attribution   = 'Known OS/test-harness noise: a child powershell.exe created its own Windows PowerShell startup-profile data under AppData\Local\Microsoft\Windows\PowerShell\StartupProfileData-NonInteractive (plus AppData / AppData\Local / AppData\Roaming directory mtimes). This is NOT an engine write; the engine under test only reads/parses, and any non-interactive powershell.exe started with redirected USERPROFILE produces the same paths. Recorded under T6 (test-period fix).'
        addedCount    = $userDataFullDiff.AddedCount
        removedCount  = $userDataFullDiff.RemovedCount
        changedCount  = $userDataFullDiff.ChangedCount
        addedPaths    = @($userDataFullDiff.Differences | Where-Object { $_.Type -eq 'added' } | ForEach-Object { $_.Rel })
        changedPaths  = @($userDataFullDiff.Differences | Where-Object { $_.Type -eq 'changed' } | ForEach-Object { $_.Rel })
        differences   = @($userDataFullDiff.Differences)
    }
    $noiseEvidencePath = Join-Path $Ctx.OutDir 'g3-redirected-userprofile-full-diff.json'
    Write-JsonFile -Path $noiseEvidencePath -Value $noiseReport -Depth 20 | Out-Null
    Add-CaseArtifact -Context $Ctx -Path $noiseEvidencePath -Label 'G3 raw whole-home diff (known Windows PowerShell startup-profile OS noise, T6)' | Out-Null
    $noiseAllowed = {
        param($rel)
        if ([string]::Equals($rel, 'AppData', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($rel, 'AppData/Local', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($rel, 'AppData/Roaming', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($rel, 'AppData/Local/Microsoft', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($rel, 'AppData/Local/Microsoft/Windows', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($rel, 'AppData/Local/Microsoft/Windows/PowerShell', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($rel.StartsWith('AppData/Local/Microsoft/Windows/PowerShell/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        return $false
    }
    $unexpectedNoise = @($userDataFullDiff.Differences | Where-Object { -not (& $noiseAllowed ([string]$_.Rel)) })
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E7.onlyKnownOsNoise' -Condition ($unexpectedNoise.Count -eq 0) `
        -PassDetail "whole-home diff consists only of known Windows PowerShell startup-profile OS noise (added=$($userDataFullDiff.AddedCount) changed=$($userDataFullDiff.ChangedCount) removed=$($userDataFullDiff.RemovedCount)); raw diff: $noiseEvidencePath" `
        -FailDetail "unexpected (non-OS-noise) changes in the simulated home: $(@($unexpectedNoise | ForEach-Object { $_.Rel }) -join ', ')" `
        -Expected 'only AppData PowerShell startup-profile noise' -Actual @($unexpectedNoise | ForEach-Object { $_.Rel }) `
        -Data ([pscustomobject]@{ addedCount = $userDataFullDiff.AddedCount; changedCount = $userDataFullDiff.ChangedCount; removedCount = $userDataFullDiff.RemovedCount; addedPaths = @($noiseReport.addedPaths); changedPaths = @($noiseReport.changedPaths); rawDiffEvidence = $noiseEvidencePath })) | Out-Null
    $userDataPrefixes = @('.dsh', '.cnki-mcp', 'AppData/Local/ms-playwright', 'Documents')
    $userDataBeforeScoped = @(Select-SnapshotSubtree -Snapshot $userDataBefore -Prefixes $userDataPrefixes)
    $userDataAfterScoped = @(Select-SnapshotSubtree -Snapshot $userDataAfter -Prefixes $userDataPrefixes)
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E7.simulatedHomeUntouched' -Before $userDataBeforeScoped -After $userDataAfterScoped -Label 'simulated production user data (.dsh/.cnki-mcp/AppData/Local/ms-playwright/Documents)') | Out-Null
}

function Test-CaseE8 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $baseline = Get-SandboxSnapshot $fixture
    # (a) "install\." must resolve to the same install root safely
    $dotRoot = $fixture.InstallRoot + '\.'
    $runA = Invoke-Engine -Ctx $Ctx -Action 'check' -InstallRoot $dotRoot -DshHome $fixture.DshHome -Label 'install-dot' -Params @{}
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E8.dot.exit' -Run $runA -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'E8.dot.state' -Run $runA -Expected 'RC2_CLEAN') | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E8.dot.readOnly' -Before $baseline -After (Get-SandboxSnapshot $fixture) -Label 'CHECK with install\.') | Out-Null
    # (b) traversal to non-existent siblings must refuse and write nothing there
    $parent = Split-Path -Parent $fixture.InstallRoot
    $bogus1 = Join-Path $parent ('install-DOES-NOT-EXIST-' + [guid]::NewGuid().ToString('N'))
    $bogus2 = Join-Path $parent ('..\escaped-DOES-NOT-EXIST-' + [guid]::NewGuid().ToString('N'))
    foreach ($pair in @(@{ Label = 'dotdot-missing-sibling'; Path = $bogus1 }, @{ Label = 'dotdot-escape'; Path = $bogus2 })) {
        $run = Invoke-Engine -Ctx $Ctx -Action 'check' -InstallRoot $pair.Path -DshHome $fixture.DshHome -Label ("traversal-" + $pair.Label) -Params @{}
        # A non-existent traversal target has no installation markers, so the final
        # setup CLI correctly reports NOT_INSTALLED (exit 0, read-only); an unsafe
        # refusal (exit 2) is equally acceptable. The safety intent asserted here
        # is: no path is created outside the install root and nothing is written.
        $traversalState = Get-DocSourceState -Json $run.Json
        $traversalOk = (($run.ExitCode -eq 0) -and ($traversalState -eq 'NOT_INSTALLED')) -or ($run.ExitCode -eq 2)
        Add-CaseCheck $Ctx (Assert-Condition -Id ("E8." + $pair.Label + ".exit") -Condition $traversalOk `
            -PassDetail ("traversal target handled safely: exit {0}, state {1} (no writes)" -f $run.ExitCode, $traversalState) `
            -FailDetail ("unexpected traversal result: exit {0}, state {1}" -f $run.ExitCode, $traversalState) -Expected 'NOT_INSTALLED (read-only) or exit 2 refusal' -Actual $run.ExitCode) | Out-Null
        $created = Test-Path -LiteralPath $pair.Path
        Add-CaseCheck $Ctx (Assert-Condition -Id ("E8." + $pair.Label + ".notCreated") -Condition (-not $created) `
            -PassDetail "no directory was created outside the install root for '$($pair.Path)'" -FailDetail "engine created a path: $($pair.Path)" -Expected 'absent' -Actual $created) | Out-Null
    }
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E8.noWrites' -Before $baseline -After (Get-SandboxSnapshot $fixture) -Label 'traversal checks whole-sandbox') | Out-Null
}

function Test-CaseE9 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    [void](Replace-FixturePayloadDirectoryWithJunction -Fixture $fixture -RelPath 'docs')
    $baseline = Get-SandboxSnapshot $fixture
    $check = Invoke-EngineAction $Ctx 'check' -Label 'reparse-in-payload'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E9.payloadReparse.exit' -Run $check -ExpectedExit 2 -RequireJson) | Out-Null
    $reparseFails = @(Find-EngineCheck -Json $check.Json -IdPattern '*reparse*' | Where-Object { $_.status -eq 'FAIL' })
    $state = [string](Get-JsonValue $check.Json 'sourceState')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E9.payloadReparse.refused' -Condition ($reparseFails.Count -ge 1) `
        -PassDetail "reparse point inside payload refused by a reparse check (state=$state, FAIL checks: $($reparseFails.id -join ', '))" `
        -FailDetail "engine did not report a reparse FAIL for a reparse point inside the payload tree (state=$state)" -Expected 'reparse FAIL' -Actual $state) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E9.payloadReparse.readOnly' -Before $baseline -After (Get-SandboxSnapshot $fixture) -Label 'CHECK with payload junction') | Out-Null
    # InstallRoot itself as a directory junction
    $link = New-FixtureJunctionInstallRoot -Fixture $fixture -LinkName 'install-root-junction'
    $baseline2 = Get-SandboxSnapshot $fixture
    $check2 = Invoke-Engine -Ctx $Ctx -Action 'check' -InstallRoot $link -DshHome $fixture.DshHome -Label 'install-root-junction' -Params @{}
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E9.installRootJunction.exit' -Run $check2 -ExpectedExit 2 -RequireJson) | Out-Null
    $rootFails = @(Find-EngineCheck -Json $check2.Json -IdPattern 'path.installRoot*' | Where-Object { $_.status -eq 'FAIL' })
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E9.installRootJunction.refused' -Condition ($rootFails.Count -ge 1) `
        -PassDetail 'InstallRoot that is a reparse point refused (path.installRoot FAIL)' -FailDetail 'engine did not refuse a junction as InstallRoot' -Expected 'path.installRoot FAIL' -Actual $rootFails.Count) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E9.installRootJunction.readOnly' -Before $baseline2 -After (Get-SandboxSnapshot $fixture) -Label 'CHECK with install-root junction') | Out-Null
}

function Test-CaseE10 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $baseline = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $check = Invoke-Engine -Ctx $Ctx -Action 'check-engine' -Params @{ TargetVersion = '1.0.0-rc.9' } -Label 'wrong-target-version'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E10.check.exit' -Run $check -ExpectedExit 2 -RequireJson) | Out-Null
    $checkText = if ($check.Json) { $check.Json | ConvertTo-Json -Depth 30 } else { '' }
    $tokenOk = ($checkText -match 'PATCH_TARGET_MISMATCH') -or ($checkText -match 'TARGET_VERSION') -or ($checkText -match 'targetVersion')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E10.check.token' -Condition $tokenOk -PassDetail 'wrong -TargetVersion refused with an explicit target-version error token' -FailDetail "wrong -TargetVersion refusal has no target-version token: $(Limit-Text $checkText 400)" -Expected 'PATCH_TARGET_MISMATCH' -Actual '') | Out-Null
    $plan = Invoke-EngineAction $Ctx 'plan' -Label 'plan'
    $planId = [string](Get-JsonValue $plan.Json 'planId')
    $apply = Invoke-Engine -Ctx $Ctx -Action 'apply-engine' -Params @{ PlanId = $planId; TargetVersion = '1.0.0-rc.9' } -Label 'apply-wrong-target-version'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E10.apply.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E10.untouched' -Before $baseline -After (Get-SandboxSnapshot $fixture) -Label 'whole-sandbox after wrong -TargetVersion') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'E10.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

# ===========================================================================
# E13 - tampered CANDIDATE PACKAGE copy must be refused before any write
# ===========================================================================

function Test-CaseE11 {
    param($Ctx)
    Invoke-UnknownStateRefusal -Ctx $Ctx -Prefix 'E11' -Variant 'missing:bundle/cnki-research/launcher/cnki_research_launcher.py' `
        -ExpectPath 'bundle/cnki-research/launcher/cnki_research_launcher.py' -ExpectCategories @('missing')
}

function Test-CaseE12 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    [void](Add-FixturePendingTransaction -Fixture $fixture -TransactionId '20261018T000000Z-deadbeef' -Phase 'APPLYING')
    $baseline = Get-SandboxSnapshot $fixture
    $check = Invoke-EngineAction $Ctx 'check' -Label 'pending-txn'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E12.check.exit' -Run $check -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineCheckStatus -Id 'E12.check.pendingTxn' -Run $check -CheckIdPattern 'env.pendingTransaction' -ExpectedStatus @('FAIL') -MustExist) | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'E12.check.token' -Run $check -Token 'PENDING_TRANSACTION' -MustContain -Label 'pending transaction refusal') | Out-Null
    $plan = Invoke-EngineAction $Ctx 'plan' -Label 'plan-with-pending'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E12.plan.exit' -Run $plan -ExpectedExit 2 -RequireJson) | Out-Null
    $apply = Invoke-EngineAction $Ctx 'apply' -Label 'apply-with-pending'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E12.apply.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E12.untouched' -Before $baseline -After (Get-SandboxSnapshot $fixture) -Label 'whole-sandbox with pre-existing pending transaction') | Out-Null
}

function Test-CaseG11 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G11.plan'
    $preInstall = Get-InstallSnapshot $fixture   # snapshot BEFORE taking the lock (hashing itself needs read access)
    $preRoot = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $lockedPath = Join-Path $fixture.InstallRoot 'README.md'
    $lock = $null
    try {
        $lock = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply-locked-file'
    } finally {
        if ($lock) { $lock.Dispose() }
    }
    # ENGINE_SPEC §7.0 / engine-dev contract: the locked file makes the re-check
    # fail and the engine must refuse cleanly with exit 2 and zero writes.
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G11.exit' -Run $apply -ExpectedExit 2) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'G11.preBytes' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id 'G11.noMixedState' -Fixture $fixture) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'G11.noWrites' -Before $preRoot -After (Get-SandboxSnapshot $fixture) -Label 'whole-sandbox after locked-target APPLY') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'G11.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

function Test-CaseE13 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $baseline = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $copy = Join-Path $Ctx.CaseRoot 'tampered-package'
    Copy-DirectoryFilesPlain -Source $script:G.PackageRoot -Destination $copy -MaxBytes 52428800 | Out-Null
    $copyManifest = Join-Path $copy 'manifest.json'
    if (-not [System.IO.File]::Exists($copyManifest)) { Add-CaseCheck $Ctx (New-AssertResult -Id 'E13.copySetup' -Status FAIL -Detail "tampered package copy has no manifest.json: $copyManifest"); return }
    $bytes = [System.IO.File]::ReadAllBytes($copyManifest)
    $marker = (New-Utf8NoBom).GetBytes("`nSANDBOX_PACKAGE_TAMPER`n")
    $combined = New-Object byte[] ($bytes.Length + $marker.Length)
    [System.Array]::Copy($bytes, 0, $combined, 0, $bytes.Length)
    [System.Array]::Copy($marker, 0, $combined, $bytes.Length, $marker.Length)
    [System.IO.File]::WriteAllBytes($copyManifest, $combined)
    $run = Invoke-Engine -Ctx $Ctx -Action 'check' -PackageRoot $copy -Label 'tampered-package-check'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E13.check.exit' -Run $run -ExpectedExit 2 -RequireJson) | Out-Null
    $text = if ($run.Json) { $run.Json | ConvertTo-Json -Depth 30 } else { '' }
    $tokenOk = ($text -match '(?i)integrity') -or ($text -match '(?i)tamper') -or ($text -match '(?i)hash') -or ($text -match 'patch\.')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E13.check.integrityToken' -Condition $tokenOk -PassDetail 'tampered candidate package refused by package integrity checks before any write' -FailDetail "refusal does not mention package integrity/hash: $(Limit-Text $text 400)" -Expected 'integrity FAIL' -Actual '') | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E13.untouched' -Before $baseline -After (Get-SandboxSnapshot $fixture) -Label 'whole-sandbox after tampered-package CHECK') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'E13.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

# ===========================================================================
# E15 - candidate ZIP extracted over the existing RC2 install
# (PackageRoot == InstallRoot) must be refused
# ===========================================================================

function Test-CaseE14 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'separate-package-root'
    $baseline = Get-SandboxSnapshot $fixture
    $check = Invoke-EngineAction $Ctx 'check' -Label 'separate-package-root'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E14.check.exit' -Run $check -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'E14.check.state' -Run $check -Expected 'UNKNOWN_OR_MODIFIED') | Out-Null
    Add-CaseCheck $Ctx (Assert-JsonContains -Ctx $Ctx -Id 'E14.reasonToken' -Run $check -Token 'LAYOUT_SEPARATE_PACKAGE_ROOT' -MustContain -Label 'separate-package-root layout reason') | Out-Null
    $apply = Invoke-EngineAction $Ctx 'apply' -Label 'apply-separate-package-root'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E14.apply.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E14.untouched' -Before $baseline -After (Get-SandboxSnapshot $fixture) -Label 'whole-sandbox for unsupported layout') | Out-Null
}

function Test-CaseB7 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'extra-user-files'
    $preInstall = Get-InstallSnapshot $fixture
    $extraPaths = @('user-notes.txt', '我的笔记 2026.txt', 'notes/scratch.md', 'bundle/cnki-research/README.user-notes.md')
    $extraShas = @{}
    foreach ($rel in $extraPaths) {
        $full = Join-Path $fixture.InstallRoot ($rel -replace '/', '\')
        if (-not [System.IO.File]::Exists($full)) { Add-CaseCheck $Ctx (New-AssertResult -Id "B7.extraPresent.$rel" -Status FAIL -Detail "fixture extra file missing: $rel"); return }
        $extraShas[$rel] = Get-Sha256File $full
    }
    $check = Invoke-EngineAction $Ctx 'check' -Label 'extra-user-files'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B7.check.exit' -Run $check -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'B7.check.state' -Run $check -Expected 'RC2_CLEAN') | Out-Null
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'B7.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B7.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id 'B7.payloadEqualsRc3' -InstallRoot $fixture.InstallRoot -Label 'install with user extras vs RC3 payload') | Out-Null
    foreach ($rel in $extraPaths) {
        Add-CaseCheck $Ctx (Assert-FileSha -Id ("B7.extraPreserved." + ($rel -replace '[^A-Za-z0-9]+', '_')) -Path (Join-Path $fixture.InstallRoot ($rel -replace '/', '\')) -ExpectedSha $extraShas[$rel]) | Out-Null
    }
}

# ===========================================================================
# CASES H - user-data protection (sessions/storages/credentials/.cnki-mcp/browser)
# ===========================================================================

function Assert-OutsideInstallRootUnchanged {
    param($Ctx, [string]$Id, $Fixture, [AllowEmptyCollection()][object[]]$BeforeRoot, [AllowEmptyCollection()][object[]]$AfterRoot)
    $installRel = Get-RelPath -Root $Fixture.Root -Path $Fixture.InstallRoot
    $diff = Compare-Snapshots -Before $BeforeRoot -After $AfterRoot -IgnorePrefixes @($installRel)
    if ($diff.Equal) {
        return New-AssertResult -Id $Id -Status PASS -Detail 'engine wrote nothing outside the install root (whole-sandbox proof: sessions/storages/credentials/.cnki-mcp/browser-profile/DSH home untouched)'
    }
    return New-AssertResult -Id $Id -Status FAIL -Detail ("engine wrote outside the install root:`n" + (Format-SnapshotDiff -Diff $diff)) -Expected 'identical' -Actual "added=$($diff.AddedCount) removed=$($diff.RemovedCount) changed=$($diff.ChangedCount)"
}

function Test-CaseH1 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preRoot = Get-SandboxSnapshot $fixture
    $preFp = Save-FingerprintEvidence -Ctx $Ctx -Label 'before-apply' -Snapshot $preRoot -Description 'whole fixture sandbox (install + dsh-home + home) before APPLY'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'H1.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'H1.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    $postRoot = Get-SandboxSnapshot $fixture
    $postFp = Save-FingerprintEvidence -Ctx $Ctx -Label 'after-apply' -Snapshot $postRoot -Description 'whole fixture sandbox after APPLY (txn dirs are inside the install root)'
    $userDataCheck = Assert-UserDataUnchanged -Id 'H1.userData' -Before $preRoot -After $postRoot -UserDataPrefixes @('home', 'dsh-home')
    Add-CaseCheck $Ctx (Attach-FingerprintData -Result $userDataCheck -BeforeInfo $preFp -AfterInfo $postFp) | Out-Null
    $outsideCheck = Assert-OutsideInstallRootUnchanged -Ctx $Ctx -Id 'H1.outsideInstallRoot' -Fixture $fixture -BeforeRoot $preRoot -AfterRoot $postRoot
    Add-CaseCheck $Ctx (Attach-FingerprintData -Result $outsideCheck -BeforeInfo $preFp -AfterInfo $postFp) | Out-Null
    $fp = $fixture.Fingerprint
    Add-CaseCheck $Ctx (Assert-SnapshotMatchesFingerprint -Id 'H1.userHomeVsFixture' -Root $fixture.UserHome -FingerprintEntries @($fp.entries.userHome) -Label 'user home vs fixture fingerprint') | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotMatchesFingerprint -Id 'H1.dshHomeVsFixture' -Root $fixture.DshHome -FingerprintEntries @($fp.entries.dshHome) -Label 'DSH home vs fixture fingerprint') | Out-Null
    Add-CaseCheck $Ctx (Assert-JunctionsUnchanged -Id 'H1.profileJunction' -DshHome $fixture.DshHome -InstallRoot $fixture.InstallRoot -Profile 'desktop') | Out-Null
    $preVenv = @(Select-SnapshotSubtree -Snapshot $preRoot -Prefixes @('install/.venv'))
    $postVenv = @(Select-SnapshotSubtree -Snapshot $postRoot -Prefixes @('install/.venv'))
    $venvDiff = Compare-Snapshots -Before $preVenv -After $postVenv
    Add-CaseCheck $Ctx (Assert-Condition -Id 'H1.venvUnchanged' -Condition $venvDiff.Equal -PassDetail '.venv byte-identical after APPLY' -FailDetail (Format-SnapshotDiff -Diff $venvDiff) -Expected 'identical' -Actual "changed=$($venvDiff.ChangedCount)") | Out-Null
}

function Test-CaseH2 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preRoot = Get-SandboxSnapshot $fixture
    $preFp = Save-FingerprintEvidence -Ctx $Ctx -Label 'before-failed-apply' -Snapshot $preRoot -Description 'whole fixture sandbox before APPLY with FAIL_APPLY_INDEX fault (auto-restore)'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'H2.plan'
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name 'H2' -Faults @('FAIL_APPLY_INDEX:5')
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -TestMode -Label 'fail-restore'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'H2.apply.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    $postRoot = Get-SandboxSnapshot $fixture
    $postFp = Save-FingerprintEvidence -Ctx $Ctx -Label 'after-auto-restore' -Snapshot $postRoot -Description 'whole fixture sandbox after failed APPLY auto-restore'
    $userDataCheck = Assert-UserDataUnchanged -Id 'H2.userData' -Before $preRoot -After $postRoot -UserDataPrefixes @('home', 'dsh-home')
    Add-CaseCheck $Ctx (Attach-FingerprintData -Result $userDataCheck -BeforeInfo $preFp -AfterInfo $postFp) | Out-Null
    $outsideCheck = Assert-OutsideInstallRootUnchanged -Ctx $Ctx -Id 'H2.outsideInstallRoot' -Fixture $fixture -BeforeRoot $preRoot -AfterRoot $postRoot
    Add-CaseCheck $Ctx (Attach-FingerprintData -Result $outsideCheck -BeforeInfo $preFp -AfterInfo $postFp) | Out-Null
    $fp = $fixture.Fingerprint
    Add-CaseCheck $Ctx (Assert-SnapshotMatchesFingerprint -Id 'H2.userHomeVsFixture' -Root $fixture.UserHome -FingerprintEntries @($fp.entries.userHome) -Label 'user home vs fixture fingerprint') | Out-Null
}

function Test-CaseH3 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $preRoot = Get-SandboxSnapshot $fixture
    $preFp = Save-FingerprintEvidence -Ctx $Ctx -Label 'before-upgrade' -Snapshot $preRoot -Description 'whole fixture sandbox before APPLY (pre-upgrade state)'
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'H3.plan'
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'H3.apply.exit' -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    if (-not $txnId) { Add-CaseCheck $Ctx (New-AssertResult -Id 'H3.txnId' -Status FAIL -Detail 'no transaction id'); return }
    $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'H3.rollback.exit' -Run $rollback -ExpectedExit 0 -RequireJson) | Out-Null
    $postRoot = Get-SandboxSnapshot $fixture
    $postFp = Save-FingerprintEvidence -Ctx $Ctx -Label 'after-rollback' -Snapshot $postRoot -Description 'whole fixture sandbox after RC2 -> RC3 -> ROLLBACK'
    $userDataCheck = Assert-UserDataUnchanged -Id 'H3.userData' -Before $preRoot -After $postRoot -UserDataPrefixes @('home', 'dsh-home')
    Add-CaseCheck $Ctx (Attach-FingerprintData -Result $userDataCheck -BeforeInfo $preFp -AfterInfo $postFp) | Out-Null
    $outsideCheck = Assert-OutsideInstallRootUnchanged -Ctx $Ctx -Id 'H3.outsideInstallRoot' -Fixture $fixture -BeforeRoot $preRoot -AfterRoot $postRoot
    Add-CaseCheck $Ctx (Attach-FingerprintData -Result $outsideCheck -BeforeInfo $preFp -AfterInfo $postFp) | Out-Null
    $fp = $fixture.Fingerprint
    Add-CaseCheck $Ctx (Assert-SnapshotMatchesFingerprint -Id 'H3.userHomeVsFixture' -Root $fixture.UserHome -FingerprintEntries @($fp.entries.userHome) -Label 'user home vs fixture fingerprint') | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotMatchesFingerprint -Id 'H3.dshHomeVsFixture' -Root $fixture.DshHome -FingerprintEntries @($fp.entries.dshHome) -Label 'DSH home vs fixture fingerprint') | Out-Null
}

# ===========================================================================
# CASE I - read-only matrix across all source states
# ===========================================================================

function Test-CaseH4 {
    param($Ctx)
    $states = New-Object System.Collections.ArrayList
    [void]$states.Add(@{ Variant = 'clean'; Label = 'RC2_CLEAN'; Expected = @{ check = 0; plan = 0; status = 0; verify = 2 } })
    [void]$states.Add(@{ Variant = 'hotfixed-line'; Label = 'RC2_HOTFIXED'; Expected = @{ check = 0; plan = 0; status = 0; verify = 2 } })
    [void]$states.Add(@{ Variant = 'rc3-unified'; Label = 'RC3_ALREADY_INSTALLED_UNIFIED'; Expected = @{ check = 0; plan = 0; status = 0; verify = 0 } })
    if ($script:G.Rc3FrozenZip -and [System.IO.File]::Exists($script:G.Rc3FrozenZip)) {
        [void]$states.Add(@{ Variant = 'rc3-frozen'; Label = 'RC3_ALREADY_INSTALLED_FROZEN_RC3'; Expected = @{ check = 0; plan = 0; status = 0; verify = 0 } })
    } else {
        Add-CaseCheck $Ctx (New-AssertResult -Id 'H4.frozenRc3State' -Status 'NOT TESTED' -Detail "frozen RC3 ZIP unavailable; the FROZEN_RC3 read-only state is NOT TESTED (documented limitation)") | Out-Null
    }
    [void]$states.Add(@{ Variant = 'tampered:README.md'; Label = 'UNKNOWN_OR_MODIFIED'; Expected = @{ check = 2; plan = 2; status = 0; verify = 2 } })
    $fingerprintRecords = New-Object System.Collections.ArrayList
    $stateIndex = 0
    foreach ($state in @($states.ToArray())) {
        $stateIndex++
        $stateRoot = Join-Path $Ctx.SandboxRoot ("state-$stateIndex-$($state.Label)")
        $fixture = New-CaseFixture -Ctx $Ctx -Variant $state.Variant -FixtureRoot $stateRoot
        foreach ($action in @('check', 'plan', 'status', 'verify')) {
            $before = Get-SandboxSnapshot $fixture
            $beforeDigest = Get-SnapshotDigest -Snapshot $before
            $run = Invoke-EngineAction $Ctx $action -Label ("$($state.Label)-$action")
            $expectedExit = [int]$state.Expected[$action]
            Add-CaseCheck $Ctx (Assert-EngineExit -Id ("H4." + $state.Label + "." + $action + ".exit") -Run $run -ExpectedExit $expectedExit -RequireJson) | Out-Null
            $after = Get-SandboxSnapshot $fixture
            $afterDigest = Get-SnapshotDigest -Snapshot $after
            $snapshotDiff = Compare-Snapshots -Before $before -After $after
            $readOnlyResult = Assert-ReadOnlyAction -Id ("H4." + $state.Label + "." + $action + ".readOnly") -Before $before -After $after -ActionLabel "$action on $($state.Label)"
            $readOnlyResult.Data = [pscustomobject]@{
                wholeSandboxBeforeDigest     = $beforeDigest
                wholeSandboxBeforeEntryCount = @($before).Count
                wholeSandboxAfterDigest      = $afterDigest
                wholeSandboxAfterEntryCount  = @($after).Count
                digestRule                   = 'sha256 over sorted rel<TAB>kind<TAB>bytes<TAB>sha256<TAB>mtimeUtcTicks<TAB>target lines'
            }
            Add-CaseCheck $Ctx $readOnlyResult | Out-Null
            [void]$fingerprintRecords.Add([ordered]@{
                state            = $state.Label
                action           = $action
                expectedExitCode = $expectedExit
                actualExitCode   = $run.ExitCode
                beforeDigest     = $beforeDigest
                beforeEntryCount = @($before).Count
                afterDigest      = $afterDigest
                afterEntryCount  = @($after).Count
                identical        = $snapshotDiff.Equal
            })
            $txns = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
            Add-CaseCheck $Ctx (Assert-Condition -Id ("H4." + $state.Label + "." + $action + ".noTxn") -Condition ($txns.Count -eq 0) `
                -PassDetail "no transaction/backup directory created by $action" -FailDetail "unexpected transaction dirs after $action on $($state.Label): $($txns -join ', ')" -Expected 'none' -Actual $txns) | Out-Null
        }
    }
    $fingerprintEvidence = [ordered]@{
        schemaVersion = 1
        case          = 'H4-readonly-matrix'
        generatedAt   = (Get-Date).ToString('o')
        digestRule    = 'sha256_lowerhex_utf8_lf over sorted(lines "rel<TAB>kind<TAB>bytes<TAB>sha256<TAB>mtimeUtcTicks<TAB>target") with trailing LF'
        records       = @($fingerprintRecords.ToArray())
    }
    $fingerprintPath = Join-Path $Ctx.OutDir 'whole-sandbox-fingerprints.json'
    Write-JsonFile -Path $fingerprintPath -Value $fingerprintEvidence -Depth 30 | Out-Null
    Add-CaseArtifact -Context $Ctx -Path $fingerprintPath -Label 'whole-sandbox before/after fingerprint digests for every state x action pair' | Out-Null
}

function Invoke-JGateProbe {
    param($Ctx, [string]$Prefix)
    $fixture = New-CaseFixture $Ctx 'clean'
    $common = Join-Path $script:G.PackageRoot 'tools\lib\UpgradeCommon.ps1'
    if (-not (Test-Path -LiteralPath $common)) {
        Add-CaseCheck $Ctx (New-AssertResult -Id "$Prefix.available" -Status 'NOT TESTED' -Detail "engine library missing: $common") | Out-Null
        return $null
    }
    $probeScript = Join-Path $Ctx.OutDir 'j-gate-probe.ps1'
    $probeOut = Join-Path $Ctx.OutDir 'j-gate-probe.json'
    $probeErr = Join-Path $Ctx.OutDir 'j-gate-probe.stderr.txt'
    $probeText = @'
param(
    [string]$CommonPath,
    [string]$LiveDshHome,
    [string]$IsolatedDshHome,
    [string]$InstallRoot,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
try {
    . $CommonPath
    $hasGate = [bool](Get-Command -Name Test-DshApplyAllowed -ErrorAction SilentlyContinue)
    $injectable = [bool](Get-Command -Name Get-DshProcessTable -ErrorAction SilentlyContinue)
    if (-not $hasGate) {
        [ordered]@{ schemaVersion = 1; available = $false; dotSourceOk = $true; injectable = $injectable; reason = 'Test-DshApplyAllowed_not_found' } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutFile -Encoding UTF8
        exit 0
    }
    $injected = @([pscustomobject]@{ ProcessId = 424242; Name = 'DeepSeek Harness.exe'; ExecutablePath = 'C:\sandbox\fake\DeepSeek Harness.exe' })
    function global:Get-DshProcessTable { return @($injected) }
    $tableAfterOverride = @(Get-DshProcessTable)
    $results = [ordered]@{}
    $results.live_running      = Test-DshApplyAllowed -DshHome $LiveDshHome -InstallRoot $InstallRoot -DshRunning $true -UnderDshProcess $false
    $results.isolated_running  = Test-DshApplyAllowed -DshHome $IsolatedDshHome -InstallRoot $InstallRoot -DshRunning $true -UnderDshProcess $false
    $results.live_idle         = Test-DshApplyAllowed -DshHome $LiveDshHome -InstallRoot $InstallRoot -DshRunning $false -UnderDshProcess $false
    $results.injected_live     = Test-DshApplyAllowed -DshHome $LiveDshHome -InstallRoot $InstallRoot
    $results.injected_isolated = Test-DshApplyAllowed -DshHome $IsolatedDshHome -InstallRoot $InstallRoot
    [ordered]@{
        schemaVersion            = 1
        available                = $true
        dotSourceOk              = $true
        injectable               = $injectable
        tableAfterOverrideCount  = $tableAfterOverride.Count
        tableAfterOverrideName   = if ($tableAfterOverride.Count -gt 0) { [string]$tableAfterOverride[0].Name } else { '' }
        results                  = $results
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    exit 0
} catch {
    [ordered]@{ schemaVersion = 1; available = $false; dotSourceOk = $false; reason = ('probe_error: ' + $_.Exception.Message) } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    exit 1
}
'@
    [System.IO.File]::WriteAllText($probeScript, $probeText, (New-Object System.Text.UTF8Encoding($true)))
    $liveDshHome = Join-Path $fixture.UserHome '.dsh'   # fixture sessions/storages => simulated live target
    $probeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probeScript,
                   '-CommonPath', $common, '-LiveDshHome', $liveDshHome,
                   '-IsolatedDshHome', $fixture.DshHome, '-InstallRoot', $fixture.InstallRoot, '-OutFile', $probeOut)
    $stdout = (& $script:G.PsExe @probeArgs 2> $probeErr | Out-String)
    $exit = $LASTEXITCODE
    Add-CaseCommand -Context $Ctx -Label "$Prefix.probe" -Executable $script:G.PsExe -Arguments $probeArgs -ExitCode ([int]$exit) -JsonPath $probeOut -StderrPath $probeErr | Out-Null
    if (-not (Test-Path -LiteralPath $probeOut)) {
        Add-CaseCheck $Ctx (New-AssertResult -Id "$Prefix.available" -Status FAIL -Detail "J gate probe produced no JSON (exit $exit): $(Limit-Text $stdout 500)") | Out-Null
        return $null
    }
    $probe = Read-JsonFile $probeOut
    Add-CaseCheck $Ctx (Assert-Condition -Id "$Prefix.dotSource" -Condition ($probe.dotSourceOk -eq $true) -PassDetail 'UpgradeCommon.ps1 dot-sources cleanly (no side effects)' -FailDetail "dot-source failed: $($probe.reason)" -Expected $true -Actual $probe.dotSourceOk) | Out-Null
    if (-not $probe.available) {
        Add-CaseCheck $Ctx (New-AssertResult -Id "$Prefix.available" -Status 'NOT TESTED' -Detail "Test-DshApplyAllowed is not exposed by the engine ($($probe.reason)); live-DSH gate cannot be unit-tested") | Out-Null
        return $null
    }
    Add-CaseCheck $Ctx (Assert-Condition -Id "$Prefix.injectable" -Condition (($probe.injectable -eq $true) -and ([int]$probe.tableAfterOverrideCount -ge 1)) `
        -PassDetail "Get-DshProcessTable injection works (overridden table returns $($probe.tableAfterOverrideCount) fake process row)" -FailDetail 'Get-DshProcessTable injection seam failed' -Expected '>=1 injected row' -Actual $probe.tableAfterOverrideCount) | Out-Null
    return $probe
}

function Assert-GateResult {
    param($Ctx, [string]$Id, $GateResult, [bool]$ExpectRefused, [string[]]$ExpectStatus, [string[]]$ExpectReasons, [string]$Label)
    if ($null -eq $GateResult) { return (New-AssertResult -Id $Id -Status FAIL -Detail "gate result '$Label' missing from probe JSON") }
    $problems = New-Object System.Collections.ArrayList
    if ($null -ne $GateResult.refused -and ([bool]$GateResult.refused -ne $ExpectRefused)) { [void]$problems.Add("refused=$($GateResult.refused) expected=$ExpectRefused") }
    $status = [string]$GateResult.status
    if ($ExpectStatus -notcontains $status) { [void]$problems.Add("status='$status' expected [$($ExpectStatus -join ', ')]") }
    $reason = [string]$GateResult.reason
    if ($ExpectReasons -notcontains $reason) { [void]$problems.Add("reason='$reason' expected [$($ExpectReasons -join ', ')]") }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "gate '$Label': refused=$($GateResult.refused) status=$status reason=$reason checkId=$($GateResult.checkId)" }
              else { "gate '$Label' policy mismatch: " + ($problems -join '; ') + " (refused=$($GateResult.refused) status=$status reason=$reason)" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected "refused=$ExpectRefused/$($ExpectStatus -join ',')/$($ExpectReasons -join ',')" -Actual "refused=$($GateResult.refused) status=$status reason=$reason"
}

function Test-CaseJ1 {
    param($Ctx)
    $probe = Invoke-JGateProbe -Ctx $Ctx -Prefix 'J1'
    if ($null -eq $probe) { return }
    Add-CaseCheck $Ctx (Assert-GateResult -Ctx $Ctx -Id 'J1.liveRunning' -GateResult $probe.results.live_running -ExpectRefused $true -ExpectStatus @('FAIL') -ExpectReasons @('DSH_IN_USE') -Label 'live target + DSH running') | Out-Null
    Add-CaseCheck $Ctx (Assert-GateResult -Ctx $Ctx -Id 'J1.injectedProcessTable' -GateResult $probe.results.injected_live -ExpectRefused $true -ExpectStatus @('FAIL') -ExpectReasons @('DSH_IN_USE') -Label 'live target + injected DSH process table (Get-DshProcessTable seam)') | Out-Null
}

function Test-CaseJ2 {
    param($Ctx)
    $probe = Invoke-JGateProbe -Ctx $Ctx -Prefix 'J2'
    if ($null -eq $probe) { return }
    Add-CaseCheck $Ctx (Assert-GateResult -Ctx $Ctx -Id 'J2.isolatedRunning' -GateResult $probe.results.isolated_running -ExpectRefused $false -ExpectStatus @('WARN') -ExpectReasons @('DSH_RUNNING_ISOLATED_TARGET') -Label 'isolated sandbox target + DSH running') | Out-Null
    Add-CaseCheck $Ctx (Assert-GateResult -Ctx $Ctx -Id 'J2.injectedIsolated' -GateResult $probe.results.injected_isolated -ExpectRefused $false -ExpectStatus @('WARN') -ExpectReasons @('DSH_RUNNING_ISOLATED_TARGET') -Label 'isolated target + injected process table') | Out-Null
}

function Test-CaseJ3 {
    param($Ctx)
    $probe = Invoke-JGateProbe -Ctx $Ctx -Prefix 'J3'
    if ($null -eq $probe) { return }
    Add-CaseCheck $Ctx (Assert-GateResult -Ctx $Ctx -Id 'J3.liveIdle' -GateResult $probe.results.live_idle -ExpectRefused $false -ExpectStatus @('PASS') -ExpectReasons @('OK', 'NOT_IN_USE') -Label 'live target + no DSH process (user closed DSH)') | Out-Null
}

# ===========================================================================
# CASE REGISTRY (single source of truth for -Case filtering)
# ===========================================================================

function Test-CaseF4 {
    param($Ctx)
    # User modifies an ADDED file after the upgrade: ROLLBACK must refuse to
    # delete it (never silently destroy user content) and keep manual guidance.
    $fixture = New-CaseFixture $Ctx 'clean'
    $model = $script:G.PackageModel
    $run = Invoke-UpgradeToUnifiedTarget -Ctx $Ctx -Fixture $fixture -Prefix 'F4'
    $txnId = $run.TxnId
    if (-not $txnId) { Add-CaseCheck $Ctx (New-AssertResult -Id 'F4.txnId' -Status FAIL -Detail 'no transaction id after successful APPLY'); return }
    if (@($model.AddedPaths).Count -eq 0) { Add-CaseCheck $Ctx (New-AssertResult -Id 'F4.addedFilesPresent' -Status FAIL -Detail 'candidate metadata declares no operation:add files; cannot test added-file rollback conflict'); return }
    $editPath = [string](@($model.AddedPaths | Sort-Object)[0])
    $editedSha = Add-FixturePostUpgradeUserEdit -Fixture $fixture -RelPath $editPath -Marker "`nUSER_MODIFIED_ADDED_FILE`n"
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F4.userModifiedAddedFile' -Condition ($editedSha -ne $model.TargetMap[$editPath].Sha256) -PassDetail "user edit applied to added file $editPath" -FailDetail 'user edit helper did not change the added file' -Expected 'edited sha' -Actual $editedSha) | Out-Null
    $beforeRollback = Get-SandboxSnapshot $fixture
    $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback-with-modified-added-file'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F4.rollback.exit' -Run $rollback -ExpectedExit 2 -RequireJson) | Out-Null
    $text = if ($rollback.Json) { $rollback.Json | ConvertTo-Json -Depth 30 } else { $rollback.Stdout }
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F4.conflictToken' -Condition (($text -match 'ROLLBACK_CONFLICT') -or ($text -match 'ADDED_FILE_MODIFIED') -or ($text -match 'FAILED_MANUAL')) `
        -PassDetail 'rollback refused the deletion of a user-modified added file (conflict/manual guidance)' `
        -FailDetail "rollback refusal lacks conflict/manual token: $(Limit-Text $text 400)" -Expected 'ROLLBACK_CONFLICT/ADDED_FILE_MODIFIED_ON_RESTORE' -Actual '') | Out-Null
    $preservedSha = Get-Sha256File (Join-Path $fixture.InstallRoot ($editPath -replace '/', '\'))
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F4.userFilePreserved' -Condition ($preservedSha -eq $editedSha) -PassDetail 'user-modified added file preserved byte-identically (never silently deleted)' -FailDetail "user-modified added file was overwritten/deleted (sha=$preservedSha expected=$editedSha)" -Expected $editedSha -Actual $preservedSha) | Out-Null
    $txnRec = Get-TransactionRecord -InstallRoot $fixture.InstallRoot -TransactionId $txnId
    $phase = [string](Get-JsonValue $txnRec 'phase')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F4.txnPhaseManual' -Condition ($phase -ne 'ROLLED_BACK') -PassDetail "transaction phase '$phase' (rollback did not claim success)" -FailDetail "transaction phase became ROLLED_BACK although a modified added file was preserved (silent data loss risk)" -Expected 'not ROLLED_BACK' -Actual $phase) | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'F4.noPartialRollback' -Before $beforeRollback -After (Get-SandboxSnapshot $fixture) -Label 'install tree after refused rollback (no partial writes)') | Out-Null
}

function Invoke-UpgradeToUnifiedTarget {
    # Shared full-upgrade helper: CHECK/PLAN (read-only), APPLY, COMMITTED.
    param([Parameter(Mandatory = $true)]$Ctx, [Parameter(Mandatory = $true)]$Fixture, [string]$Prefix)
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix "$Prefix.plan"
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId } -Label 'apply'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id "$Prefix.apply.exit" -Run $apply -ExpectedExit 0 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    Add-CaseCheck $Ctx (Assert-Condition -Id "$Prefix.transactionId" -Condition (-not [string]::IsNullOrEmpty($txnId)) `
        -PassDetail "transaction id '$txnId'" -FailDetail 'apply JSON has no transaction id and no transaction dir was created' -Expected '<id>' -Actual $txnId) | Out-Null
    if ($txnId) {
        Add-CaseCheck $Ctx (Assert-TransactionCommitted -Ctx $Ctx -Id "$Prefix.txnPhase" -TransactionId $txnId -Fixture $Fixture) | Out-Null
        Add-CaseArtifact -Context $Ctx -Path (Join-Path (Get-InstallTxnPath $Fixture $txnId) 'transaction.json') -Label 'transaction.json' | Out-Null
    }
    return [pscustomobject]@{ PlanId = $planId; Apply = $apply; TxnId = $txnId }
}

function Test-CaseG12 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'clean'
    $model = $script:G.PackageModel
    $preInstall = Get-InstallSnapshot $fixture
    $preRoot = Get-SandboxSnapshot $fixture
    $planId = Start-FixtureUpgradePlan -Ctx $Ctx -Prefix 'G12.plan'
    if (@($model.AddedPaths).Count -eq 0) { Add-CaseCheck $Ctx (New-AssertResult -Id 'G12.addedFile' -Status FAIL -Detail 'candidate metadata declares no operation:add files; cannot inject failure at an added-file write'); return }
    $targetAdded = [string](@($model.AddedPaths | Sort-Object)[1 - 1])
    $idx = Get-ApplyIndexForPath -Path $targetAdded -Model $model
    $faultFile = Write-FaultPlanFile -Ctx $Ctx -Name 'G12' -Faults @("FAIL_APPLY_INDEX:$idx")
    $apply = Invoke-EngineAction $Ctx 'apply' -Extra @{ PlanId = $planId; FaultPlan = $faultFile } -TestMode -Label 'fail-apply-added-file'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'G12.apply.exit' -Run $apply -ExpectedExit 2 -RequireJson) | Out-Null
    $txnId = Get-RunTransactionId -Ctx $Ctx -Run $apply -AllowDiscovery
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'G12.payloadRestored' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-AddedPayloadFilesAbsent -Id 'G12.addedFilesRemoved' -InstallRoot $fixture.InstallRoot -Model $model) | Out-Null
    Add-CaseCheck $Ctx (Assert-NoTargetClaim -Ctx $Ctx -Id 'G12.noTargetClaim' -Fixture $fixture) | Out-Null
    if ($txnId) {
        Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'G12.txnPhase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('FAILED_RESTORED') -Contain) | Out-Null
        $txnRec = Get-TransactionRecord -InstallRoot $fixture.InstallRoot -TransactionId $txnId
        $restoreVerified = Get-JsonValue $txnRec 'restoreVerified'
        Add-CaseCheck $Ctx (Assert-Condition -Id 'G12.restoreVerified' -Condition ($restoreVerified -eq $true) -PassDetail 'auto-restore verified after added-file write failure (restoreVerified=true)' -FailDetail "transaction.restoreVerified='$restoreVerified'" -Expected $true -Actual $restoreVerified) | Out-Null
    }
    $installRel = Get-RelPath -Root $fixture.Root -Path $fixture.InstallRoot
    $outside = Compare-Snapshots -Before $preRoot -After (Get-SandboxSnapshot $fixture) -IgnorePrefixes @($installRel)
    Add-CaseCheck $Ctx (Assert-Condition -Id 'G12.noWritesOutside' -Condition $outside.Equal -PassDetail 'no writes outside the install root after auto-restore' -FailDetail (Format-SnapshotDiff -Diff $outside) -Expected 'identical' -Actual "added=$($outside.AddedCount) changed=$($outside.ChangedCount)") | Out-Null
}

# ===========================================================================
# H4 - read-only matrix across all source states
# ===========================================================================

function Test-CaseF5 {
    param($Ctx)
    # Explicit added-file deletion proof: exactly the metadata operation:add
    # payload files are removed by ROLLBACK, plus transaction-created empty dirs.
    $fixture = New-CaseFixture $Ctx 'clean'
    $model = $script:G.PackageModel
    $preInstall = Get-InstallSnapshot $fixture
    $run = Invoke-UpgradeToUnifiedTarget -Ctx $Ctx -Fixture $fixture -Prefix 'F5'
    $txnId = $run.TxnId
    if (-not $txnId) { Add-CaseCheck $Ctx (New-AssertResult -Id 'F5.txnId' -Status FAIL -Detail 'no transaction id after successful APPLY'); return }
    $addedBefore = New-Object System.Collections.ArrayList
    foreach ($rel in @($model.AddedPaths)) {
        $path = Join-Path $fixture.InstallRoot ($rel -replace '/', '\')
        if ([System.IO.File]::Exists($path)) { [void]$addedBefore.Add($rel) }
    }
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F5.allAddedInstalled' -Condition ($addedBefore.Count -eq @($model.AddedPaths).Count) `
        -PassDetail "all $($addedBefore.Count) added payload files were installed by APPLY" -FailDetail "only $($addedBefore.Count)/$(@($model.AddedPaths).Count) added files installed" -Expected @($model.AddedPaths).Count -Actual $addedBefore.Count) | Out-Null
    $createdDirs = @(Get-CreatedDirectories -InstallRoot $fixture.InstallRoot -TransactionId $txnId)
    $rollback = Invoke-EngineAction $Ctx 'rollback' -Extra @{ Transaction = $txnId } -Label 'rollback-added-deletion'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'F5.rollback.exit' -Run $rollback -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-AddedPayloadFilesAbsent -Id 'F5.addedFilesGone' -InstallRoot $fixture.InstallRoot -Model $model) | Out-Null
    $leftDirs = New-Object System.Collections.ArrayList
    foreach ($d in $createdDirs) {
        $rel = ConvertTo-NormalizedRelPath ([string]$d)
        if (-not $rel) { continue }
        if ([System.IO.Directory]::Exists((Join-Path $fixture.InstallRoot ($rel -replace '/', '\')))) { [void]$leftDirs.Add($rel) }
    }
    Add-CaseCheck $Ctx (Assert-Condition -Id 'F5.createdDirsRemoved' -Condition ($leftDirs.Count -eq 0) `
        -PassDetail "all $(@($createdDirs).Count) transaction-created directories were removed (exact-path cleanup)" -FailDetail "transaction-created dirs left behind: $($leftDirs -join ', ')" -Expected 'none' -Actual $leftDirs) | Out-Null
    Add-CaseCheck $Ctx (Assert-InstallRestoredToPre -Ctx $Ctx -Id 'F5.preBytesRestored' -Fixture $fixture -PreInstallSnapshot $preInstall) | Out-Null
    Add-CaseCheck $Ctx (Assert-TransactionPhase -Id 'F5.phase' -InstallRoot $fixture.InstallRoot -TransactionId $txnId -ExpectedPhase @('ROLLED_BACK') -Contain) | Out-Null
}

# ===========================================================================
# G12 - fault injection while writing an ADDED file
# ===========================================================================

function Get-DocVariant {
    param([AllowNull()]$Json)
    $variant = [string](Get-JsonValue $Json 'source.variant')
    if (-not $variant) { $variant = [string](Get-JsonValue $Json 'variant') }
    return $variant
}

function Test-CaseB8 {
    param($Ctx)
    # Lead-requested dedicated proof: installed tree == extracted candidate
    # PackageRoot distribution files exactly (payload + manifest.json); the
    # package-only metadata files (SHA256SUMS.txt, upgrade-data/**) are NOT installed.
    $fixture = New-CaseFixture $Ctx 'clean'
    $model = $script:G.PackageModel
    $run = Invoke-UpgradeToUnifiedTarget -Ctx $Ctx -Fixture $fixture -Prefix 'B8'
    Add-CaseCheck $Ctx (Assert-InstallEqualsUnifiedTarget -Id 'B8.installedEqualsCandidateTarget' -InstallRoot $fixture.InstallRoot -Model $model -Label 'installed distribution files vs extracted candidate') | Out-Null
    Add-CaseCheck $Ctx (Assert-PackageOnlyFilesNotInstalled -Id 'B8.packageOnlyNotInstalled' -InstallRoot $fixture.InstallRoot -Model $model) | Out-Null
    # byte-level re-check of every target file against the candidate package bytes
    $problems = New-Object System.Collections.ArrayList
    foreach ($entry in @($model.TargetFiles)) {
        $installed = Join-Path $fixture.InstallRoot ($entry.Path -replace '/', '\')
        $packageFile = Join-Path $model.PackageRoot ($entry.Path -replace '/', '\')
        if (-not [System.IO.File]::Exists($installed)) { [void]$problems.Add("missing installed file: $($entry.Path)"); continue }
        if (-not [System.IO.File]::Exists($packageFile)) { [void]$problems.Add("missing package file: $($entry.Path)"); continue }
        $shaInstalled = Get-Sha256File $installed
        $shaPackage = Get-Sha256File $packageFile
        if ($shaInstalled -ne $shaPackage) { [void]$problems.Add("byte mismatch: $($entry.Path)") }
    }
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B8.everyTargetFileByteIdentical' -Condition ($problems.Count -eq 0) `
        -PassDetail "all $($model.TargetFileCount) target files are byte-identical between the installed tree and the extracted candidate package" `
        -FailDetail ('target-file byte mismatches: ' + (($problems | Select-Object -First 20) -join '; ')) -Expected "$($model.TargetFileCount) files byte-identical" -Actual $problems) | Out-Null
    $sumsInstalled = Join-Path $fixture.InstallRoot 'SHA256SUMS.txt'
    $readmeInstalled = Join-Path $fixture.InstallRoot 'upgrade-data\README.md'
    $metaInstalled = Join-Path $fixture.InstallRoot 'upgrade-data\rc2-to-rc3.json'
    Add-CaseCheck $Ctx (Assert-Condition -Id 'B8.packageOnlyAbsent' -Condition ((-not [System.IO.File]::Exists($sumsInstalled)) -and (-not [System.IO.File]::Exists($readmeInstalled)) -and (-not [System.IO.File]::Exists($metaInstalled))) `
        -PassDetail 'SHA256SUMS.txt / upgrade-data/rc2-to-rc3.json / upgrade-data/README.md are package-only and were NOT installed' `
        -FailDetail 'package-only metadata file(s) leaked into the install root' -Expected 'absent' -Actual 'present') | Out-Null
    # The APPLY document's sourceState is the PRE-apply state by design (same as
    # B4); prove the post-apply state of B8 with a fresh read-only CHECK.
    $postApplyCheckB8 = Invoke-EngineAction $Ctx 'check' -Label 'check-after-apply-b8'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'B8.stateAfterApply.exit' -Run $postApplyCheckB8 -ExpectedExit 0 -RequireJson) | Out-Null
    Add-CaseCheck $Ctx (Assert-EngineState -Id 'B8.stateAfterApply' -Run $postApplyCheckB8 -Expected 'RC3_ALREADY_INSTALLED') | Out-Null
}

# ===========================================================================
# CASES D - idempotence (RC3_ALREADY_INSTALLED: UNIFIED and FROZEN_RC3)
# ===========================================================================

function Test-CaseE15 {
    param($Ctx)
    $fixture = New-CaseFixture $Ctx 'zip-over-install'
    $baseline = Get-SandboxSnapshot $fixture
    $preTxnIds = @(Get-TransactionIds -InstallRoot $fixture.InstallRoot)
    $run = Invoke-Engine -Ctx $Ctx -Action 'check' -PackageRoot $fixture.InstallRoot -InstallRoot $fixture.InstallRoot -Label 'package-root-equals-install-root'
    Add-CaseCheck $Ctx (Assert-EngineExit -Id 'E15.check.exit' -Run $run -ExpectedExit 2 -RequireJson) | Out-Null
    $text = if ($run.Json) { $run.Json | ConvertTo-Json -Depth 30 } else { '' }
    $tokenOk = ($text -match 'INSTALL_ROOT_EQUALS_UPGRADE_PACKAGE') -or ($text -match 'EXTRACTED_OVER_INSTALL') -or ($text -match 'EXTRACTED_OVER_EXISTING') -or ($text -match 'MIXED_VERSION_MARKERS') -or ($text -match 'PACKAGE_ROOT_EQUALS_INSTALL_ROOT') -or ($text -match '(?i)integrity') -or ($text -match '(?i)layout')
    Add-CaseCheck $Ctx (Assert-Condition -Id 'E15.check.refusalToken' -Condition $tokenOk `
        -PassDetail 'PackageRoot == InstallRoot (ZIP extracted over old install) refused with an explicit extracted-over/equal-roots/integrity token' `
        -FailDetail "refusal has no extracted-over/equal-roots/integrity token: $(Limit-Text $text 500)" -Expected 'EXTRACTED_OVER_INSTALL / equal-roots / integrity refusal' -Actual '') | Out-Null
    Add-CaseCheck $Ctx (Assert-SnapshotEqual -Id 'E15.untouched' -Before $baseline -After (Get-SandboxSnapshot $fixture) -Label 'whole-sandbox after PackageRoot==InstallRoot CHECK') | Out-Null
    Add-CaseCheck $Ctx (Assert-NoNewTransaction -Id 'E15.noTxn' -InstallRoot $fixture.InstallRoot -BeforeIds $preTxnIds) | Out-Null
}

# ===========================================================================
# F1/F4/F5 - rollback byte-exactness, added-file deletion and conflict safety
# ===========================================================================

function Get-CaseRegistry {
    return @(
        [pscustomobject]@{ Name = 'B1-check-clean-readonly'; Group = 'B'; Description = 'B1 CHECK on clean RC2: exit 0, RC2_CLEAN, engine route, read-only proof, no hotfix misdetection'; Fn = 'Test-CaseB1' }
        [pscustomobject]@{ Name = 'B2-plan-clean-readonly'; Group = 'B'; Description = 'B2 PLAN on clean RC2: read-only, planId, metadata-derived changed/new file lists, backup location, no writes'; Fn = 'Test-CaseB2' }
        [pscustomobject]@{ Name = 'B3-planid-gate'; Group = 'B'; Description = 'B3 planId gate: PLAN_READY without -Yes, wrong/foreign/stale PlanId refused, zero writes'; Fn = 'Test-CaseB3' }
        [pscustomobject]@{ Name = 'B4-apply-target-tree'; Group = 'B'; Description = 'B4 APPLY clean RC2: COMMITTED, installed tree == candidate target (P + manifest.json), added files, env update + non-migration fields, txn backup + add records'; Fn = 'Test-CaseB4' }
        [pscustomobject]@{ Name = 'B5-verify'; Group = 'B'; Description = 'B5 VERIFY after APPLY: FILE_UPGRADE_COMPLETE=PASS, DSH runtime activation NOT TESTED, read-only'; Fn = 'Test-CaseB5' }
        [pscustomobject]@{ Name = 'B6-status'; Group = 'B'; Description = 'B6 STATUS after APPLY: rc.3 + transaction history, no pending transaction, read-only'; Fn = 'Test-CaseB6' }
        [pscustomobject]@{ Name = 'B7-extra-user-files'; Group = 'B'; Description = 'B7 extra user files inside the install root preserved byte-identically through the upgrade'; Fn = 'Test-CaseB7' }
        [pscustomobject]@{ Name = 'B8-install-tree-exact'; Group = 'B'; Description = 'B8 installed tree exactly equals the extracted candidate distribution files (payload + manifest.json; SHA256SUMS/upgrade-data NOT installed)'; Fn = 'Test-CaseB8' }
        [pscustomobject]@{ Name = 'B9-chinese-space-path'; Group = 'B'; Description = 'B9 Chinese characters + spaces + & + () install path: full upgrade flow to the unified target'; Fn = 'Test-CaseB9' }
        [pscustomobject]@{ Name = 'B10-long-path'; Group = 'B'; Description = 'B10 long path (install root >=160 chars, managed file >=220): full upgrade flow to the unified target'; Fn = 'Test-CaseB10' }
        [pscustomobject]@{ Name = 'C1-hotfixed-line'; Group = 'C'; Description = 'C1 HOTFIX_LINE_REMOVED RC2: CHECK => RC2_HOTFIXED + variant, APPLY => unified target'; Fn = 'Test-CaseC1' }
        [pscustomobject]@{ Name = 'C2-hotfixed-text'; Group = 'C'; Description = 'C2 HOTFIX_TEXT_REMOVED RC2: CHECK => RC2_HOTFIXED + variant, APPLY => unified target'; Fn = 'Test-CaseC2' }
        [pscustomobject]@{ Name = 'C3-clean-not-hotfixed'; Group = 'C'; Description = 'C3 clean RC2 is not misdetected as hotfixed'; Fn = 'Test-CaseC3' }
        [pscustomobject]@{ Name = 'D1-upgraded-unified-idempotent'; Group = 'D'; Description = 'D1 after a real upgrade: RC3_ALREADY_INSTALLED variant UNIFIED, PLAN noOp, APPLY (upgrade) NOOP exit 0 with zero writes/backups'; Fn = 'Test-CaseD1' }
        [pscustomobject]@{ Name = 'D2-synthetic-unified-readonly'; Group = 'D'; Description = 'D2 synthetic unified install: CHECK UNIFIED + read-only, PLAN noOp, no transaction created'; Fn = 'Test-CaseD2' }
        [pscustomobject]@{ Name = 'D3-frozen-rc3-noop'; Group = 'D'; Description = 'D3 synthetic frozen-RC3 install: recognized RC3_ALREADY_INSTALLED/FROZEN_RC3, PLAN noOp, APPLY no-op (NOT TESTED if frozen RC3 ZIP unavailable)'; Fn = 'Test-CaseD3' }
        [pscustomobject]@{ Name = 'E1-tampered-payload'; Group = 'E'; Description = 'E1 modified payload file => UNKNOWN_OR_MODIFIED conflict, CHECK/PLAN/APPLY/ROLLBACK refused, bytes untouched'; Fn = 'Test-CaseE1' }
        [pscustomobject]@{ Name = 'E2-tampered-cordis'; Group = 'E'; Description = 'E2 non-hotfix cordis edit => UNKNOWN (never hotfixed); refused, untouched'; Fn = 'Test-CaseE2' }
        [pscustomobject]@{ Name = 'E3-missing-payload'; Group = 'E'; Description = 'E3 missing payload file => UNKNOWN; refused; untouched'; Fn = 'Test-CaseE3' }
        [pscustomobject]@{ Name = 'E4-mixed-rc2-unified'; Group = 'E'; Description = 'E4 mixed RC2/unified payload => UNKNOWN with MIXED_RC2_RC3; refused; untouched'; Fn = 'Test-CaseE4' }
        [pscustomobject]@{ Name = 'E5-tampered-version'; Group = 'E'; Description = 'E5 tampered VERSION => UNKNOWN (tampered-version); refused; untouched'; Fn = 'Test-CaseE5' }
        [pscustomobject]@{ Name = 'E6-tampered-manifest'; Group = 'E'; Description = 'E6 tampered manifest.json => UNKNOWN (tampered-manifest); refused; untouched'; Fn = 'Test-CaseE6' }
        [pscustomobject]@{ Name = 'E7-unsafe-install-roots'; Group = 'E'; Description = 'E7 drive root/WINDIR/ProgramFiles/package itself + simulated production DSH home/.cnki-mcp refused, no writes'; Fn = 'Test-CaseE7' }
        [pscustomobject]@{ Name = 'E8-path-traversal'; Group = 'E'; Description = 'E8 "install\." safely resolved; "..\missing" refused without creating outside paths'; Fn = 'Test-CaseE8' }
        [pscustomobject]@{ Name = 'E9-reparse-points'; Group = 'E'; Description = 'E9 reparse point inside payload and junction as InstallRoot refused, read-only'; Fn = 'Test-CaseE9' }
        [pscustomobject]@{ Name = 'E10-wrong-target-version'; Group = 'E'; Description = 'E10 engine -TargetVersion 1.0.0-rc.9 refused before any write, untouched'; Fn = 'Test-CaseE10' }
        [pscustomobject]@{ Name = 'E11-missing-payload-launcher'; Group = 'E'; Description = 'E11 missing launcher payload file => UNKNOWN, refused, untouched'; Fn = 'Test-CaseE11' }
        [pscustomobject]@{ Name = 'E12-pending-transaction'; Group = 'E'; Description = 'E12 pre-existing pending transaction => CHECK FAIL, PLAN/APPLY refused, untouched'; Fn = 'Test-CaseE12' }
        [pscustomobject]@{ Name = 'E13-tampered-package'; Group = 'E'; Description = 'E13 tampered candidate package copy => package-integrity refusal before any write'; Fn = 'Test-CaseE13' }
        [pscustomobject]@{ Name = 'E14-separate-package-root'; Group = 'E'; Description = 'E14 separate-package-root (Layout B) installation => UNKNOWN LAYOUT_SEPARATE_PACKAGE_ROOT, refused'; Fn = 'Test-CaseE14' }
        [pscustomobject]@{ Name = 'E15-package-root-equals-install'; Group = 'E'; Description = 'E15 candidate ZIP extracted over the existing RC2 install (PackageRoot == InstallRoot) => refused, no writes'; Fn = 'Test-CaseE15' }
        [pscustomobject]@{ Name = 'F1-rollback-roundtrip'; Group = 'F'; Description = 'F1 RC2->unified->ROLLBACK: all pre bytes restored, added files deleted, env restored, venv/user data/profile unchanged, idempotent'; Fn = 'Test-CaseF1' }
        [pscustomobject]@{ Name = 'F2-rollback-conflict'; Group = 'F'; Description = 'F2 post-upgrade user edit of a replaced file => ROLLBACK refused with conflict, no overwrite'; Fn = 'Test-CaseF2' }
        [pscustomobject]@{ Name = 'F3-rollback-corrupt-backup'; Group = 'F'; Description = 'F3 corrupt backup => ROLLBACK refused, files untouched, backup kept'; Fn = 'Test-CaseF3' }
        [pscustomobject]@{ Name = 'F4-rollback-added-file-conflict'; Group = 'F'; Description = 'F4 user-modified ADDED file => ROLLBACK refuses deletion (conflict/FAILED_MANUAL), file preserved, no silent delete'; Fn = 'Test-CaseF4' }
        [pscustomobject]@{ Name = 'F5-rollback-deletes-added-files'; Group = 'F'; Description = 'F5 rollback deletes exactly the added payload files + transaction-created empty dirs (byte-level proof)'; Fn = 'Test-CaseF5' }
        [pscustomobject]@{ Name = 'G1-faultplan-disallowed'; Group = 'G'; Description = 'G1 -FaultPlan without CNKI_UPGRADE_TEST_MODE=1 => refused FAULT_INJECTION_DISALLOWED, untouched'; Fn = 'Test-CaseG1' }
        [pscustomobject]@{ Name = 'G2-fail-backup'; Group = 'G'; Description = 'G2 FAIL_BACKUP => exit 2, payload restored, no target claim'; Fn = 'Test-CaseG2' }
        [pscustomobject]@{ Name = 'G3-fail-stage-hash'; Group = 'G'; Description = 'G3 FAIL_STAGE_HASH => exit 2, payload restored, no target claim'; Fn = 'Test-CaseG3' }
        [pscustomobject]@{ Name = 'G4-fail-apply-index'; Group = 'G'; Description = 'G4 FAIL_APPLY_INDEX => auto-restore all pre bytes, txn FAILED_RESTORED'; Fn = 'Test-CaseG4' }
        [pscustomobject]@{ Name = 'G5-crash-after-apply-recovery'; Group = 'G'; Description = 'G5 CRASH_AFTER_APPLY => pending txn reported, APPLY refused, ROLLBACK restores pre bytes'; Fn = 'Test-CaseG5' }
        [pscustomobject]@{ Name = 'G6-crash-after-backup'; Group = 'G'; Description = 'G6 CRASH_AFTER_BACKUP => no payload change, ROLLBACK ABORTED/ROLLED_BACK idempotent'; Fn = 'Test-CaseG6' }
        [pscustomobject]@{ Name = 'G7-fail-verify'; Group = 'G'; Description = 'G7 FAIL_VERIFY => auto-restore to pre bytes, no target claim'; Fn = 'Test-CaseG7' }
        [pscustomobject]@{ Name = 'G8-simulate-disk-low'; Group = 'G'; Description = 'G8 SIMULATE_DISK_LOW => APPLY refuses, untouched'; Fn = 'Test-CaseG8' }
        [pscustomobject]@{ Name = 'G9-corrupt-transaction'; Group = 'G'; Description = 'G9 corrupt transaction.json => ROLLBACK refuses, backup kept, files untouched'; Fn = 'Test-CaseG9' }
        [pscustomobject]@{ Name = 'G10-readonly-target'; Group = 'G'; Description = 'G10 read-only attribute on a target file => real write failure + auto-restore, pre bytes restored'; Fn = 'Test-CaseG10' }
        [pscustomobject]@{ Name = 'G11-locked-target-file'; Group = 'G'; Description = 'G11 target file locked (FileShare.None) during APPLY => clean refusal exit 2, zero writes'; Fn = 'Test-CaseG11' }
        [pscustomobject]@{ Name = 'G12-fail-apply-added-file'; Group = 'G'; Description = 'G12 FAIL_APPLY_INDEX at the position of an operation:add write => auto-restore deletes the added files, no mixed install'; Fn = 'Test-CaseG12' }
        [pscustomobject]@{ Name = 'H1-userdata-during-apply'; Group = 'H'; Description = 'H1 APPLY with simulated sessions/storages/credentials/.cnki-mcp/browser profile => all byte-identical'; Fn = 'Test-CaseH1' }
        [pscustomobject]@{ Name = 'H2-userdata-during-restore'; Group = 'H'; Description = 'H2 injected failure + auto-restore => user data byte-identical'; Fn = 'Test-CaseH2' }
        [pscustomobject]@{ Name = 'H3-userdata-during-rollback'; Group = 'H'; Description = 'H3 APPLY+ROLLBACK => user data + venv + profile unchanged'; Fn = 'Test-CaseH3' }
        [pscustomobject]@{ Name = 'H4-readonly-matrix'; Group = 'H'; Description = 'H4 CHECK/PLAN/STATUS/VERIFY on RC2 clean/hotfixed/unified/frozen-RC3/UNKNOWN => whole-sandbox fingerprint identical each time'; Fn = 'Test-CaseH4' }
    )
}

# === CASE FUNCTIONS PART 2 INSERT POINT ===

# ===========================================================================
# MAIN (executes after all functions/cases are defined)
# ===========================================================================

$finalExitCode = 1
try {
    $layout = Resolve-TestLayout
    $script:G = [ordered]@{
        Layout         = $layout
        Rc2Zip         = [System.IO.Path]::GetFullPath($Rc2Zip)
        Rc3FrozenZip   = $layout.Rc3FrozenZip
        UnifiedZip     = $layout.UnifiedZip
        PackageRoot    = ''
        PackageIdentity = $null
        PackageModel   = $null
        SetupEntry     = $null
        EngineLib      = $null
        EngineEntryScript = $null
        WorkRoot       = $layout.WorkRoot
        EvidenceDir    = $layout.EvidenceDir
        PsExe          = $layout.PsExe
        KeepSandbox    = [bool]$KeepSandbox
        InvokeCounter  = 0
        Rc2Map         = $null
        Rc2PayloadMap  = $null
        TargetMap      = $null
        TargetFileList = @()
        TargetVersion  = ''
        SourceVersion  = ''
        ChangedFileCount = 0
        StartTime      = Get-Date
        Admin          = $false
        PrereqFailures = @()
        PackageIntegrityChecks = @()
        FrozenRc2Checks = @()
        FrozenCoreChecks = @()
        FrozenCoreFailures = (New-Object System.Collections.ArrayList)
        FixtureSelfTest = [bool]$FixtureSelfTest
    }
    # load the independent oracle + fixture builder
    . $layout.LibAssert
    . $layout.LibFixtures
    if (-not [System.IO.Directory]::Exists($script:G.WorkRoot)) { [void][System.IO.Directory]::CreateDirectory($script:G.WorkRoot) }
    if (-not [System.IO.Directory]::Exists($script:G.EvidenceDir)) { [void][System.IO.Directory]::CreateDirectory($script:G.EvidenceDir) }

    Write-Host ''
    Write-Host '--- candidate package ---' -ForegroundColor Cyan
    $prereqFails = New-Object System.Collections.ArrayList
    $packageInfo = $null
    try {
        $packageInfo = Resolve-CandidatePackage -Layout $layout
        Write-Host ("  package root: {0} ({1})" -f $packageInfo.PackageRoot, $(if ($packageInfo.FromZip) { "extracted from $($layout.UnifiedZip)" } else { 'PackageDir' }))
    } catch {
        [void]$prereqFails.Add((New-AssertResult -Id 'prereq.candidatePackage' -Status FAIL -Detail $_.Exception.Message))
        Write-Host ("  [FAIL] prereq.candidatePackage :: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    $model = $null
    if ($packageInfo) {
        $script:G.PackageRoot = $packageInfo.PackageRoot
        try {
            $model = Read-UnifiedPackageModel -PackageRoot $packageInfo.PackageRoot -CandidateZip $layout.UnifiedZip
            $script:G.PackageModel = $model
        } catch {
            [void]$prereqFails.Add((New-AssertResult -Id 'prereq.candidateModel' -Status FAIL -Detail ("cannot read candidate package model: " + $_.Exception.Message)))
        }
    }

    $prereq = Initialize-TestRun -Layout $layout -PackageRoot $script:G.PackageRoot -SkipEnginePrereqs:$FixtureSelfTest.IsPresent
    $script:G.Admin = $prereq.Admin
    Write-Host ''
    Write-Host '--- prerequisites ---' -ForegroundColor Cyan
    foreach ($r in $prereq.Results) {
        $color = if ($r.Status -eq 'PASS') { 'Green' } else { 'Red' }
        Write-Host ("  [{0}] {1} :: {2}" -f $r.Status, $r.Id, (Limit-Text $r.Detail 240)) -ForegroundColor $color
        if ($r.Status -eq 'FAIL') { [void]$prereqFails.Add($r) }
    }

    # frozen RC2 zip identity + hotfix variant recomputation (read-only input oracle)
    Write-Host '--- frozen RC2 input ---' -ForegroundColor Cyan
    $frozenResult = Assert-FrozenRc2Zip -Rc2Zip $script:G.Rc2Zip
    $script:G.FrozenRc2Checks = @($frozenResult.Results)
    foreach ($r in @($frozenResult.Results)) {
        $color = if ($r.Status -eq 'PASS') { 'Green' } elseif ($r.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
        Write-Host ("  [{0}] {1} :: {2}" -f $r.Status, $r.Id, (Limit-Text $r.Detail 240)) -ForegroundColor $color
        if ($r.Status -eq 'FAIL') { [void]$prereqFails.Add($r) }
    }
    $script:G.Rc2Map = $frozenResult.Rc2Map
    $script:G.Rc2PayloadMap = $frozenResult.Rc2PayloadMap

    # independent candidate package integrity / metadata-split closure
    if ($model -and $script:G.Rc2Map) {
        Write-Host '--- candidate package integrity (independent oracle) ---' -ForegroundColor Cyan
        $integrity = @(Assert-UnifiedPackageIntegrity -Model $model -Rc2Zip $script:G.Rc2Zip -Rc2ZipMap $script:G.Rc2Map)
        $script:G.PackageIntegrityChecks = $integrity
        foreach ($r in $integrity) {
            $color = if ($r.Status -eq 'PASS') { 'Green' } elseif ($r.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
            Write-Host ("  [{0}] {1} :: {2}" -f $r.Status, $r.Id, (Limit-Text $r.Detail 220)) -ForegroundColor $color
            if ($r.Status -eq 'FAIL') { [void]$prereqFails.Add($r) }
        }
        # frozen-core equality (read-only evidence; NOT TESTED when frozen RC3 zip absent).
        # A mismatch is a RELEASE-READINESS DEFECT recorded in SUMMARY.json, not a
        # precondition: the remaining cases still execute against the package so the
        # full matrix evidence is produced, but the run exits 2.
        $script:G.FrozenCoreChecks = @(Assert-FrozenCoreEquality -Model $model -Rc3FrozenZip $script:G.Rc3FrozenZip)
        foreach ($r in @($script:G.FrozenCoreChecks)) {
            $color = if ($r.Status -eq 'PASS') { 'Green' } elseif ($r.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
            Write-Host ("  [{0}] {1} :: {2}" -f $r.Status, $r.Id, (Limit-Text $r.Detail 220)) -ForegroundColor $color
            if ($r.Status -eq 'FAIL') { [void]$script:G.FrozenCoreFailures.Add($r) }
        }
        # dynamic values consumed by the case helpers
        $script:G.TargetMap = $model.TargetMap
        $script:G.TargetFileList = $model.TargetFileList
        $script:G.TargetVersion = $model.TargetVersion
        $script:G.SourceVersion = $model.SourceVersion
        $script:G.ChangedFileCount = $model.ChangedFileCount
        $layout.SetupEntry = Join-Path $script:G.PackageRoot 'tools\setup.ps1'
        $layout.EngineLib = Join-Path $script:G.PackageRoot 'tools\lib\UpgradeCommon.ps1'
        $script:G.SetupEntry = $layout.SetupEntry
        $script:G.EngineLib = $layout.EngineLib
        $script:G.PackageIdentity = Get-PackageIdentity -Model $model -CandidateZipPath $layout.UnifiedZip -ExtractedFromZip:$packageInfo.FromZip
    }
    $script:G.PrereqFailures = @($prereqFails.ToArray())

    if ($script:G.PrereqFailures.Count -gt 0) {
        $failing = @($script:G.PrereqFailures | ForEach-Object { $_.Id })
        Write-Host ''
        Write-Host "PREREQUISITES FAILED: $($failing -join ', ')" -ForegroundColor Red
        $failSummary = [ordered]@{
            schemaVersion = 2
            tool = 'cnki-research-portable-unified-tests'
            toolVersion = $script:TestToolVersion
            generatedAt = (Get-Date).ToString('o')
            mode = $(if ($FixtureSelfTest) { 'fixture-self-test' } else { 'matrix' })
            status = 'PRECONDITION_FAILED'
            inputs = Get-TestInputsReport -Layout $layout -PackageIdentity $script:G.PackageIdentity
            packageIntegrity = [ordered]@{
                checks = @($script:G.PackageIntegrityChecks)
                fail = @($script:G.PackageIntegrityChecks | Where-Object { $_.Status -eq 'FAIL' }).Count
            }
            failures = @($script:G.PrereqFailures)
            matrix = [ordered]@{ totalCases = 0; pass = 0; fail = 0; notTested = 0; totalChecks = 0; checkPass = 0; checkFail = 0; checkWarn = 0; checkNotTested = 0; groups = @{} }
            cases = @()
            notTested = @()
            notTestedByDesign = @(
                [ordered]@{ case = 'ALL'; topic = 'DSH runtime activation'; reason = 'Always NOT TESTED by design (file-level upgrade only).' }
                [ordered]@{ case = 'ALL'; topic = 'live production target'; reason = 'Never pointed at; isolated sandboxes only.' }
                [ordered]@{ case = 'ALL'; topic = 'operating systems other than Windows 10/11'; reason = 'The portable distribution targets Windows only.' }
                [ordered]@{ case = 'ALL'; topic = 'PowerShell versions other than Windows PowerShell 5.1'; reason = 'Only Windows PowerShell 5.1 is supported/tested; PowerShell 7 was not exercised.' }
            )
            isolationDeclaration = 'No case was executed (precondition failure); nothing was written outside -WorkRoot/-EvidenceDir and no production DSH path was touched.'
            runtimeActivation = 'NOT TESTED'
            liveProductionTarget = 'NOT TESTED'
            notes = @('Nothing was executed because required inputs are missing/mismatched. Build/publish the candidate package (build-dev) and ensure tools/setup.ps1 + tools/lib/UpgradeCommon.ps1 are present.')
        }
        $summaryPath = Write-SummaryJson -SummaryObject $failSummary -Directory $script:G.EvidenceDir
        Write-Host "  -> $summaryPath"
        exit 2
    }

    # engine entry wrapper for engine-level APPLY/ROLLBACK unit evidence
    $script:G.EngineEntryScript = Initialize-EngineEntryScript

    if ($FixtureSelfTest) {
        $finalExitCode = Invoke-FixtureSelfTestMode
    } else {
        $caseFilter = '*'
        if ($Case) { $caseFilter = $Case }
        elseif ($Filter) { $caseFilter = $Filter }
        $finalExitCode = Invoke-MatrixRun -CaseFilter $caseFilter
    }
} catch {
    Write-Host ''
    Write-Host "HARNESS ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkRed
    $host.UI.WriteErrorLine("HARNESS ERROR: $($_.Exception.Message)")
    $finalExitCode = 1
}
exit $finalExitCode

