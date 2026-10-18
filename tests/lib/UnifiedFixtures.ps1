# =============================================================================
# UnifiedFixtures.ps1 - isolated sandbox fixture builder for the
# CNKI Research Portable unified RC3 test matrix (RC2 install -> unified RC3
# in-place upgrade / rollback / failure injection / user-data protection).
#
# Owner: test-dev.  Shipped as part of the candidate repository tests\lib\.
#
# Every fixture is byte-derived from read-only inputs.  Nothing here is
# hand-written payload:
#   * RC2 Layout-A installs are exact extractions of the frozen RC2 ZIP plus a
#     fake venv, realistic installer env metadata, simulated user data, an
#     isolated DSH home with a REAL directory junction, and synthetic user files;
#   * unified (target) trees are copied byte-for-byte from the candidate package
#     (payload set P + manifest.json; package-only metadata is NOT installed);
#   * frozen-RC3 trees are exact extractions of the frozen RC3 ZIP (only when
#     the read-only frozen ZIP is available for FROZEN_RC3 recognition tests);
#   * hotfixed variants are byte-exact transforms of the frozen RC2 cordis.
#
# SAFETY
#   * writes only below the -Root passed by the caller;
#   * the DSH profile reference is an isolated fixture directory under -Root,
#     never the real %USERPROFILE%\.dsh;
#   * junctions are only ever removed with [System.IO.Directory]::Delete($p,$false);
#   * this file never points the engine at production paths.
#
# Depends on lib\UnifiedAssert.ps1 being dot-sourced first (Get-ZipMap,
# Expand-ZipToDirectory, Read-UnifiedPackageModel, Write-JsonFile,
# Get-TreeSnapshot, ... - independent oracle helpers, NOT engine code).
#
# Windows PowerShell 5.1 only.  UTF-8 with BOM (contains non-ASCII literals).
# =============================================================================

function Assert-FixtureDependencies {
    $required = @('Get-ZipMap', 'Expand-ZipToDirectory', 'Write-JsonFile', 'Get-TreeSnapshot',
                  'Get-Sha256File', 'Get-Sha256Bytes', 'Read-JsonFile', 'Get-FullPath',
                  'Test-PathUnder', 'Get-RelPath', 'Remove-CordisTargetLine',
                  'Read-UnifiedPackageModel', 'ConvertTo-NormalizedRelPath', 'Get-ApplyIndexForPath')
    $missing = @()
    foreach ($fn in $required) { if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { $missing += $fn } }
    if ($missing.Count -gt 0) { throw "UnifiedFixtures.ps1 requires lib\UnifiedAssert.ps1 to be dot-sourced first; missing: $($missing -join ', ')" }
}

function Get-FixtureVariants {
    @(
        'clean', 'hotfixed-line', 'hotfixed-text',
        'rc3-unified', 'rc3-frozen',
        'mixed', 'target-files-present', 'zip-over-install',
        'extra-user-files', 'long-path', 'no-venv', 'no-profile',
        'separate-package-root',
        'tampered:<rel-path>', 'missing:<rel-path>'
    )
}


# ---------------------------------------------------------------------------
# Junction-safe tree deletion (tests only; restricted to -AllowedRoot)
# ---------------------------------------------------------------------------

function Remove-DirectoryContentsJunctionSafe {
    param([Parameter(Mandatory = $true)][string]$Directory)
    foreach ($child in @([System.IO.Directory]::EnumerateFileSystemEntries($Directory))) {
        $attrs = [System.IO.File]::GetAttributes($child)
        if ([bool]($attrs -band [System.IO.FileAttributes]::ReparsePoint)) {
            if ([bool]($attrs -band [System.IO.FileAttributes]::Directory)) {
                # unlink the junction itself; never touch the target contents
                [System.IO.Directory]::Delete($child, $false)
            } else {
                [System.IO.File]::Delete($child)
            }
            continue
        }
        if ([bool]($attrs -band [System.IO.FileAttributes]::Directory)) {
            Remove-DirectoryContentsJunctionSafe -Directory $child
            [System.IO.Directory]::Delete($child, $false)
        } else {
            if ([bool]($attrs -band [System.IO.FileAttributes]::ReadOnly)) {
                [System.IO.File]::SetAttributes($child, [System.IO.FileAttributes]::Normal)
            }
            [System.IO.File]::Delete($child)
        }
    }
}

function Remove-TreeJunctionSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [switch]$WhatIfOnly
    )
    $full = Get-FullPath $Path
    $allowed = Get-FullPath $AllowedRoot
    if (-not (Test-PathUnder -Child $full -Parent $allowed)) {
        throw "Remove-TreeJunctionSafe REFUSED: '$full' is not under the allowed root '$allowed'"
    }
    if (-not [System.IO.Directory]::Exists($full)) { return }
    if ($WhatIfOnly) { return }
    Remove-DirectoryContentsJunctionSafe -Directory $full
    [System.IO.Directory]::Delete($full, $false)
}

function Copy-DirectoryFilesPlain {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [long]$MaxBytes = 26214400
    )
    $src = Get-FullPath $Source
    $dst = Get-FullPath $Destination
    if (-not [System.IO.Directory]::Exists($src)) { return @() }
    if (-not [System.IO.Directory]::Exists($dst)) { [void][System.IO.Directory]::CreateDirectory($dst) }
    $copied = New-Object System.Collections.ArrayList
    $total = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ Abs = $src; Rel = '' })
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        foreach ($child in @([System.IO.Directory]::EnumerateFileSystemEntries($item.Abs))) {
            $attrs = [System.IO.File]::GetAttributes($child)
            if ([bool]($attrs -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
            $rel = if ($item.Rel) { "$($item.Rel)/$([System.IO.Path]::GetFileName($child))" } else { [System.IO.Path]::GetFileName($child) }
            if ([bool]($attrs -band [System.IO.FileAttributes]::Directory)) {
                $stack.Push(@{ Abs = $child; Rel = $rel })
                continue
            }
            $len = (New-Object System.IO.FileInfo($child)).Length
            if ($total + $len -gt $MaxBytes) { continue }
            $target = Join-Path $dst ($rel -replace '/', '\')
            $parent = [System.IO.Path]::GetDirectoryName($target)
            if ($parent -and -not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
            [System.IO.File]::Copy($child, $target, $true)
            $total += $len
            [void]$copied.Add($rel)
        }
    }
    return @($copied.ToArray())
}

function Get-DeterministicBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Seed,
        [Parameter(Mandatory = $true)][int]$Length
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $seedBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Seed)
        $buffer = New-Object byte[] $Length
        $offset = 0
        $counter = 0
        while ($offset -lt $Length) {
            $counterBytes = [System.BitConverter]::GetBytes([int]$counter)
            $combined = New-Object byte[] ($seedBytes.Length + 4)
            [System.Array]::Copy($seedBytes, 0, $combined, 0, $seedBytes.Length)
            [System.Array]::Copy($counterBytes, 0, $combined, $seedBytes.Length, 4)
            $block = $sha.ComputeHash($combined)
            $take = [Math]::Min($block.Length, $Length - $offset)
            [System.Array]::Copy($block, 0, $buffer, $offset, $take)
            $offset += $take
            $counter++
        }
        return $buffer
    } finally { $sha.Dispose() }
}

function Test-LongPathSupport {
    param([Parameter(Mandatory = $true)][string]$BaseDir)
    $root = Get-FullPath $BaseDir
    if (-not [System.IO.Directory]::Exists($root)) { [void][System.IO.Directory]::CreateDirectory($root) }
    $probe = Join-Path $root '_lp-probe'
    $ok = $false
    try {
        if ([System.IO.Directory]::Exists($probe)) { Remove-TreeJunctionSafe -Path $probe -AllowedRoot $root }
        $deep = $probe
        while ($deep.Length -lt ($root.Length + 190)) { $deep = Join-Path $deep ('probe-segment-' + ('x' * 16)) }
        [void][System.IO.Directory]::CreateDirectory($deep)
        $file = Join-Path $deep (('p' * 40) + '.bin')
        [System.IO.File]::WriteAllBytes($file, [byte[]](1, 2, 3))
        $ok = [System.IO.File]::Exists($file) -and ($file.Length -gt 260)
    } catch { $ok = $false }
    finally {
        try { Remove-TreeJunctionSafe -Path $probe -AllowedRoot $root } catch { }
    }
    return $ok
}

function New-FixtureDirectoryJunction {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Target)
    $parent = [System.IO.Path]::GetDirectoryName((Get-FullPath $Path))
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    if (Test-Path -LiteralPath $Path) { Remove-TreeJunctionSafe -Path $Path -AllowedRoot ([System.IO.Path]::GetDirectoryName((Get-FullPath $Path))) }
    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    if (-not (Test-IsReparsePoint $Path)) { throw "failed to create directory junction: $Path -> $Target" }
}

# ---------------------------------------------------------------------------
# Fake environment files (realistic installer schemas from the RC2 package's
# own tools\portable.ps1 - schema only, no execution)
# ---------------------------------------------------------------------------

function New-FixtureEnvFiles {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DshHome,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string]$InstalledAt,
        [string]$UpgradeId = '',
        [string]$UpgradeFrom = '',
        [string]$UpgradeTo = '',
        [string]$UpgradedBy = 'tools/setup.ps1'
    )
    $bundle = Join-Path $InstallRoot 'bundle\cnki-research'
    $venvDir = Join-Path $InstallRoot '.venv'
    $venvPython = Join-Path $venvDir 'Scripts\python.exe'
    $stateDir = Join-Path $InstallRoot '_portable'
    $backupDir = Join-Path $stateDir 'backups\20261001-120000'
    [void][System.IO.Directory]::CreateDirectory($backupDir)

    $fakeDshCli = Join-Path $Root 'fake-dsh-bin\dsh.cmd'
    $state = [ordered]@{
        schemaVersion  = 1
        distribution   = $Distribution
        bundle         = '@local/dsh-cnki-research@1.0.0'
        installedAt    = $InstalledAt
        installRoot    = $InstallRoot
        packageRoot    = $InstallRoot
        dshHome        = $DshHome
        dshProfile     = $Profile
        dshProfileDir  = (Join-Path (Join-Path $DshHome 'profiles') $Profile)
        dshCli         = $fakeDshCli
        dshVersion     = '2.0.0-sandbox'
        linkMode       = 'link'
        bundleDir      = $bundle
        venvDir        = $venvDir
        python         = $venvPython
        backupDir      = $backupDir
        upstream       = 'vendor'
        packages       = 'cnki-mcp=0.1.0|mcp=1.9.0|playwright=1.48.0'
        verified       = [ordered]@{ profileDependency = $true; linkTarget = $bundle }
        restartRequired = $false
    }
    if ($UpgradeId) {
        $state['upgrade'] = [ordered]@{
            lastUpgradeId = $UpgradeId
            fromVersion   = $UpgradeFrom
            toVersion     = $UpgradeTo
            by            = $UpgradedBy
        }
    }
    Write-JsonFile -Path (Join-Path $stateDir 'install-state.json') -Value $state -Depth 15 | Out-Null

    $runtime = [ordered]@{
        schemaVersion  = 1
        distribution   = $Distribution
        bundle         = '@local/dsh-cnki-research@1.0.0'
        installRoot    = $InstallRoot
        python         = $venvPython
        launcher       = (Join-Path $bundle 'launcher\cnki_research_launcher.py')
        upstream       = 'vendor'
        upstreamDir    = (Join-Path $InstallRoot 'upstream\cnki-mcp')
        cnkiProfile    = $null
        sanitizeSchema = $true
        installedAt    = $InstalledAt
        installedBy    = 'tools/portable.ps1'
    }
    if ($UpgradeId) {
        $runtime['upgradedAt'] = '2026-10-18T00:00:00Z'
        $runtime['upgradedBy'] = $UpgradedBy
    }
    Write-JsonFile -Path (Join-Path $bundle 'portable.runtime.json') -Value $runtime -Depth 15 | Out-Null

    # Fake installer backup of the profile files (schema of New-ProfileBackup).
    $backup = [ordered]@{
        schemaVersion = 1
        createdAt     = $InstalledAt
        reason        = 'install'
        profileDir    = (Join-Path (Join-Path $DshHome 'profiles') $Profile)
        files         = @('package.json', 'pnpm-lock.yaml')
    }
    Write-JsonFile -Path (Join-Path $backupDir 'backup.json') -Value $backup -Depth 10 | Out-Null
    $lockText = "# sandbox fixture pnpm lockfile (fake)`nlockfileVersion: '9.0'`nimporters:`n  .: {}`n"
    [System.IO.File]::WriteAllText((Join-Path $backupDir 'pnpm-lock.yaml'), $lockText, (New-Utf8NoBom))
    $backupPkg = [ordered]@{
        name    = 'desktop'
        private = $true
        dependencies = [ordered]@{ '@local/dsh-cnki-research' = ('link:' + $bundle) }
        dsh     = [ordered]@{ profile = [ordered]@{ bundles = @('@local/dsh-cnki-research') } }
    }
    Write-JsonFile -Path (Join-Path $backupDir 'package.json') -Value $backupPkg -Depth 10 | Out-Null
}

function New-FakeVenv {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Seed,
        [switch]$WithBulkData
    )
    $venv = Join-Path $InstallRoot '.venv'
    $site = Join-Path $venv 'Lib\site-packages'
    foreach ($dir in @((Join-Path $venv 'Scripts'), $site, (Join-Path $site 'cnki_mcp\core'), (Join-Path $site 'mcp'),
                       (Join-Path $site 'playwright'), (Join-Path $venv 'Lib\site-packages\_fixture_data'))) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    $utf8 = New-Utf8NoBom
    $fakePythonDir = Join-Path $InstallRoot '..\fake-python-3.11.9'
    $cfg = @(
        "home = $fakePythonDir"
        'include-system-site-packages = false'
        'version = 3.11.9'
        'executable = ' + (Join-Path $venv 'Scripts\python.exe')
        'command = sandbox-fixture non-executable sentinel'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $venv 'pyvenv.cfg'), $cfg + "`n", $utf8)

    # Deliberately NOT a valid PE image: the engine must never execute the venv.
    $sentinel = "SANDBOX-FAKE-VENV-PYTHON-NOT-EXECUTABLE:do-not-run`n"
    [System.IO.File]::WriteAllText((Join-Path $venv 'Scripts\python.exe'),
        $sentinel + [System.Convert]::ToBase64String((Get-DeterministicBytes -Seed "$Seed/python" -Length 96)), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $venv 'Scripts\pythonw.exe'),
        "SANDBOX-FAKE-VENV-PYTHONW-NOT-EXECUTABLE`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $venv 'Scripts\pip.exe'),
        "SANDBOX-FAKE-VENV-PIP-NOT-EXECUTABLE`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $venv 'Scripts\activate.ps1'),
        "# sandbox fake venv - never executed`n", $utf8)

    $pyFiles = @(
        @{ Rel = 'cnki_mcp\__init__.py'; Text = "__version__ = '0.1.0'`n# sandbox fixture`n" }
        @{ Rel = 'cnki_mcp\core\__init__.py'; Text = "# sandbox fixture`n" }
        @{ Rel = 'cnki_mcp\core\config.py'; Text = "SANDBOX = True`n" }
        @{ Rel = 'mcp\__init__.py'; Text = "__version__ = '1.9.0'`n" }
        @{ Rel = 'playwright\__init__.py'; Text = "__version__ = '1.48.0'`n" }
        @{ Rel = 'cnki_mcp-0.1.0.dist-info\METADATA'; Text = "Metadata-Version: 2.1`nName: cnki-mcp`nVersion: 0.1.0`n" }
    )
    foreach ($f in $pyFiles) {
        $path = Join-Path $site $f.Rel
        $parent = [System.IO.Path]::GetDirectoryName($path)
        if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllText($path, $f.Text, $utf8)
    }
    if (-not $WithBulkData) {
        # 1 MB-ish nested fake package data with recorded pseudo-random bytes.
        $total = 0
        for ($i = 1; $i -le 20; $i++) {
            $rel = if ($i % 4 -eq 0) { "_fixture_data\nested\a\blob-$('{0:d3}' -f $i).bin" }
                   elseif ($i % 3 -eq 0) { "_fixture_data\nested\blob-$('{0:d3}' -f $i).bin" }
                   else { "_fixture_data\blob-$('{0:d3}' -f $i).bin" }
            $path = Join-Path $site $rel
            $parent = [System.IO.Path]::GetDirectoryName($path)
            if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
            $bytes = Get-DeterministicBytes -Seed "$Seed/data/$rel" -Length 51200
            [System.IO.File]::WriteAllBytes($path, $bytes)
            $total += $bytes.Length
        }
    }
}

function New-UserDataFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$UserHome,
        [Parameter(Mandatory = $true)][string]$Seed
    )
    $utf8 = New-Utf8NoBom
    $dirs = @(
        (Join-Path $UserHome '.dsh\sessions')
        (Join-Path $UserHome '.dsh\storages\kv')
        (Join-Path $UserHome '.cnki-mcp\profiles')
        (Join-Path $UserHome 'AppData\Local\ms-playwright\chromium-9999\fake-browser\Default\Local Storage\leveldb')
        (Join-Path $UserHome 'Documents\笔记')
    )
    foreach ($d in $dirs) { [void][System.IO.Directory]::CreateDirectory($d) }

    # fake DSH session/storage data - placeholders only, no real user data
    [System.IO.File]::WriteAllText((Join-Path $UserHome '.dsh\sessions\s1.jsonl'),
        '{"schema":"sandbox-fixture","role":"user","content":"沙箱测试会话占位"}' + "`n" +
        '{"schema":"sandbox-fixture","role":"assistant","content":"SANDBOX_ONLY"}' + "`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $UserHome '.dsh\sessions\s2.jsonl'),
        '{"schema":"sandbox-fixture","role":"user","content":"SANDBOX_SESSION_TWO"}' + "`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $UserHome '.dsh\storages\settings.json'),
        '{"theme":"sandbox","sandbox":true}' + "`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $UserHome '.dsh\storages\kv\app-state.json'),
        '{"sandbox":true,"sessionCount":2}' + "`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $UserHome '.dsh\.credentials.yaml'),
        "# FAKE CREDENTIAL PLACEHOLDER - SANDBOX ONLY, NOT A REAL SECRET`nprovider: sandbox`napiKey: sandbox-not-a-real-key`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $UserHome '.cnki-mcp\profiles\config.json'),
        '{"default":"沙箱机构占位","profiles":{"沙箱机构占位":{"institution":"SANDBOX-INSTITUTION","fake":true}}}' + "`n", $utf8)
    [System.IO.File]::WriteAllBytes((Join-Path $UserHome 'AppData\Local\ms-playwright\chromium-9999\fake-browser\Default\Cookies'),
        (Get-DeterministicBytes -Seed "$Seed/cookies" -Length 2048))
    [System.IO.File]::WriteAllBytes((Join-Path $UserHome 'AppData\Local\ms-playwright\chromium-9999\fake-browser\Default\Local Storage\leveldb\000003.log'),
        (Get-DeterministicBytes -Seed "$Seed/leveldb" -Length 4096))
    [System.IO.File]::WriteAllText((Join-Path $UserHome 'Documents\笔记\论文笔记.md'),
        "# 沙箱笔记占位`n`n这不是真实用户数据，仅用于升级测试。" + "`n", $utf8)
}

function New-DshProfileFixture {
    param(
        [Parameter(Mandatory = $true)][string]$DshHome,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Profile,
        [switch]$NoJunction
    )
    $profileDir = Join-Path (Join-Path $DshHome 'profiles') $Profile
    [void][System.IO.Directory]::CreateDirectory($profileDir)
    $bundle = Join-Path (Get-FullPath $InstallRoot) 'bundle\cnki-research'
    $utf8 = New-Utf8NoBom
    $profilePkg = [ordered]@{
        name         = $Profile
        version      = '0.0.0'
        private      = $true
        dependencies = [ordered]@{ '@local/dsh-cnki-research' = ('link:' + (Get-FullPath $bundle)) }
        dsh          = [ordered]@{ profile = [ordered]@{ bundles = @('@local/dsh-cnki-research') } }
    }
    Write-JsonFile -Path (Join-Path $profileDir 'package.json') -Value $profilePkg -Depth 10 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $profileDir 'pnpm-lock.yaml'),
        "# sandbox fixture profile lockfile (fake)`nlockfileVersion: '9.0'`nimporters:`n  .:`n    dependencies:`n      '@local/dsh-cnki-research':`n        specifier: link:../bundle`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $profileDir 'cordis.patch.yml'),
        "# sandbox fixture profile patch sentinel - the upgrade must never touch this`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $profileDir 'pnpm-workspace.yaml'),
        "packages:`n  - '.'`n", $utf8)
    if (-not $NoJunction) {
        $nodeModules = Join-Path $profileDir 'node_modules'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $nodeModules '@local'))
        $junction = Join-Path $nodeModules '@local\dsh-cnki-research'
        if (Test-Path -LiteralPath $junction) { [System.IO.Directory]::Delete((Get-FullPath $junction), $false) }
        New-Item -ItemType Junction -Path $junction -Target (Get-FullPath $bundle) -ErrorAction Stop | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Main fixture builder
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Main fixture builder (unified)
#
# Variants:
#   clean / hotfixed-line / hotfixed-text   exact frozen RC2 Layout-A install
#                                            (+ 2 byte-exact hotfix transforms)
#   rc3-unified                              synthetic already-upgraded unified
#                                            tree = candidate target (P + manifest)
#   rc3-frozen                               exact frozen RC3 ZIP extraction
#   mixed                                    RC2 install with some unified target
#                                            payload files copied over it
#   target-files-present                     RC2 install + one operation:add
#                                            target file already present
#   zip-over-install                         RC2 install with the candidate ZIP
#                                            extracted over it (package root ==
#                                            install root; env state stays RC2)
#   tampered:<rel> / missing:<rel>           RC2 install with one payload change
#   extra-user-files, long-path, no-venv, no-profile, separate-package-root
# ---------------------------------------------------------------------------

function Copy-PackageFileToTree {
    param(
        [Parameter(Mandatory = $true)]$Model,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$RelPath
    )
    $rel = ConvertTo-NormalizedRelPath $RelPath
    $source = Join-Path $Model.PackageRoot ($rel -replace '/', '\')
    if (-not [System.IO.File]::Exists($source)) { throw "Copy-PackageFileToTree: package file missing: $rel" }
    $target = Join-Path (Get-FullPath $DestinationRoot) ($rel -replace '/', '\')
    $parent = [System.IO.Path]::GetDirectoryName($target)
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::Copy($source, $target, $true)
    return $target
}

function Copy-PackageTargetTree {
    param(
        [Parameter(Mandatory = $true)]$Model,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )
    $copied = New-Object System.Collections.ArrayList
    foreach ($entry in @($Model.TargetFiles)) {
        [void](Copy-PackageFileToTree -Model $Model -DestinationRoot $DestinationRoot -RelPath $entry.Path)
        [void]$copied.Add($entry.Path)
    }
    return @($copied.ToArray())
}

function New-UnifiedSandbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Rc2Zip,
        [string]$PackageDir = '',
        [string]$Rc3FrozenZip = '',
        [string]$Variant = 'clean',
        [string]$CaseName = '',
        [string]$Profile = 'desktop',
        [switch]$Force
    )
    Assert-FixtureDependencies
    $rootFull = Get-FullPath $Root
    $variantText = [string]$Variant
    if ($variantText -notmatch '^(clean|hotfixed-line|hotfixed-text|rc3-unified|rc3-frozen|mixed|target-files-present|zip-over-install|extra-user-files|long-path|no-venv|no-profile|separate-package-root|tampered:.+|missing:.+)$') {
        throw "New-UnifiedSandbox: unsupported variant '$Variant'. Supported: $((Get-FixtureVariants) -join ', '), tampered:<rel>, missing:<rel>"
    }
    $baseKind = if ($variantText -match '^tampered:(.+)$') { 'tampered' }
                elseif ($variantText -match '^missing:(.+)$') { 'missing' }
                else { $variantText }
    $variantTarget = $null
    if ($variantText -match '^(tampered|missing):(.+)$') {
        $variantTarget = ConvertTo-NormalizedRelPath $matches[2]
    }
    $needPackage = @('rc3-unified', 'mixed', 'target-files-present', 'zip-over-install') -contains $baseKind
    $needFrozenRc3 = ($baseKind -eq 'rc3-frozen')
    if ($needPackage -and -not $PackageDir) { throw "New-UnifiedSandbox: variant '$Variant' requires -PackageDir (candidate package root)" }
    if ($needFrozenRc3 -and -not $Rc3FrozenZip) { throw "New-UnifiedSandbox: variant '$Variant' requires -Rc3FrozenZip (read-only frozen RC3 ZIP)" }

    $model = $null
    if ($PackageDir) { $model = Read-UnifiedPackageModel -PackageRoot $PackageDir }
    if ($needFrozenRc3) {
        $frozen = Get-FrozenIdentity
        if ((Get-Sha256File $Rc3FrozenZip) -ne $frozen.Rc3ZipSha256) { throw "New-UnifiedSandbox: frozen RC3 ZIP identity mismatch: $Rc3FrozenZip (read-only input protected)" }
    }

    if (Test-Path -LiteralPath $rootFull) {
        if (-not $Force) { throw "New-UnifiedSandbox: fixture root already exists: $rootFull (use -Force to replace it)" }
        $parent = [System.IO.Path]::GetDirectoryName($rootFull)
        Remove-TreeJunctionSafe -Path $rootFull -AllowedRoot $parent
    }
    [void][System.IO.Directory]::CreateDirectory($rootFull)

    $seed = if ($CaseName) { $CaseName } else { [System.IO.Path]::GetFileName($rootFull) }
    $fixture = New-FixtureObject -Root $rootFull -Variant $variantText -Profile $Profile
    $fixture.Rc2Zip = Get-FullPath $Rc2Zip
    if ($Rc3FrozenZip) { $fixture.Rc3FrozenZip = Get-FullPath $Rc3FrozenZip }
    if ($PackageDir) { $fixture.PackageDir = (Get-FullPath $PackageDir) }
    $fixture.Model = $model
    $frozenIdentity = Get-FrozenIdentity

    # --- locate the install root -------------------------------------------------
    $installRoot = $null
    $longPathSupported = $false
    if ($baseKind -eq 'long-path') {
        $longPathSupported = Test-LongPathSupport -BaseDir $rootFull
        if (-not $longPathSupported) {
            throw "LONG_PATH_UNSUPPORTED: this host/filesystem cannot create paths beyond MAX_PATH; the long-path case must be reported NOT TESTED"
        }
        $installRoot = Join-Path $rootFull 'long-path'
        while ($installRoot.Length -lt 170) { $installRoot = Join-Path $installRoot ('segment-' + ('x' * 16)) }
        $installRoot = Join-Path $installRoot 'install'
    } else {
        $installRoot = Join-Path $rootFull 'install'
    }
    $fixture.InstallRoot = Get-FullPath $installRoot
    $fixture.LongPathSupported = [bool]$longPathSupported

    $rc2Map = Get-ZipMap $Rc2Zip
    $fixture.Rc2FileCount = $rc2Map.FileCount
    $fixture.Rc2Map = $rc2Map

    # --- base tree ---------------------------------------------------------------
    $targetVersion = if ($model) { $model.TargetVersion } else { $frozenIdentity.Rc3Version }
    if ($baseKind -eq 'separate-package-root') {
        # Layout B: separate package root + an install root that only carries
        # bundle/upstream/_portable (no root VERSION/manifest) - must be refused.
        $packageRoot = Join-Path $rootFull 'package'
        [void](Expand-ZipToDirectory -ZipPath $Rc2Zip -Destination $packageRoot)
        $fixture.PackageRoot = Get-FullPath $packageRoot
        [void][System.IO.Directory]::CreateDirectory($fixture.InstallRoot)
        $bundleSrc = Join-Path $packageRoot 'bundle\cnki-research'
        $bundleDst = Join-Path $fixture.InstallRoot 'bundle\cnki-research'
        [void][System.IO.Directory]::CreateDirectory($bundleDst)
        Copy-DirectoryFilesPlain -Source $bundleSrc -Destination $bundleDst | Out-Null
        Copy-DirectoryFilesPlain -Source (Join-Path $packageRoot 'upstream\cnki-mcp') -Destination (Join-Path $fixture.InstallRoot 'upstream\cnki-mcp') | Out-Null
        [void][System.IO.Directory]::CreateDirectory((Join-Path $fixture.InstallRoot '_portable'))
        $fixture.BaseDistribution = $frozenIdentity.Rc2Version
        $fixture.PackageRootIsInstallRoot = $false
    } elseif ($baseKind -eq 'rc3-frozen') {
        [void](Expand-ZipToDirectory -ZipPath $Rc3FrozenZip -Destination $fixture.InstallRoot)
        $fixture.PackageRoot = $fixture.InstallRoot
        $fixture.PackageRootIsInstallRoot = $true
        $fixture.BaseDistribution = $targetVersion
        $fixture.UpgradeApplied = $true
    } elseif ($baseKind -eq 'rc3-unified') {
        [void][System.IO.Directory]::CreateDirectory($fixture.InstallRoot)
        [void](Copy-PackageTargetTree -Model $model -DestinationRoot $fixture.InstallRoot)
        $fixture.PackageRoot = $model.PackageRoot
        $fixture.PackageRootIsInstallRoot = $false
        $fixture.BaseDistribution = $targetVersion
        $fixture.UpgradeApplied = $true
    } elseif ($baseKind -eq 'zip-over-install') {
        # A user extracted the candidate ZIP over an existing RC2 install dir.
        [void](Expand-ZipToDirectory -ZipPath $Rc2Zip -Destination $fixture.InstallRoot)
        [void](Copy-PackageTargetTree -Model $model -DestinationRoot $fixture.InstallRoot)
        $fixture.PackageRoot = $fixture.InstallRoot
        $fixture.PackageRootIsInstallRoot = $true
        $fixture.BaseDistribution = $frozenIdentity.Rc2Version   # env state still RC2
    } else {
        [void](Expand-ZipToDirectory -ZipPath $Rc2Zip -Destination $fixture.InstallRoot)
        # In the unified flow the package root is the extracted CANDIDATE, not the
        # install root; for pure-RC2 variants the fixture records the candidate.
        $fixture.PackageRoot = if ($PackageDir) { $model.PackageRoot } else { $fixture.InstallRoot }
        $fixture.PackageRootIsInstallRoot = (-not $PackageDir)
        $fixture.BaseDistribution = $frozenIdentity.Rc2Version
    }
    $fixture.BundleDir = Join-Path $fixture.InstallRoot 'bundle\cnki-research'
    $fixture.VenvDir = Join-Path $fixture.InstallRoot '.venv'
    $fixture.StateDir = Join-Path $fixture.InstallRoot '_portable'
    $fixture.InstallStateFile = Join-Path $fixture.StateDir 'install-state.json'
    $fixture.RuntimeFile = Join-Path $fixture.BundleDir 'portable.runtime.json'

    # --- variant mutations on the extracted payload ------------------------------
    switch -Regex ($baseKind) {
        '^hotfixed-line$' {
            $cordisBytes = Get-ZipEntryBytes -ZipPath $Rc2Zip -RelPath $frozenIdentity.CordisPath
            $hot = Remove-CordisTargetLine -Rc2CordisBytes $cordisBytes -Mode 'line'
            $sha = Get-Sha256Bytes $hot
            if ($sha -ne $frozenIdentity.HotfixLineRemovedSha256) { throw "fixture: hotfixed-line hash $sha != allowed $($frozenIdentity.HotfixLineRemovedSha256)" }
            [System.IO.File]::WriteAllBytes((Join-Path $fixture.InstallRoot ($frozenIdentity.CordisPath -replace '/', '\')), $hot)
            $fixture.HotfixVariant = 'HOTFIX_LINE_REMOVED'
            break
        }
        '^hotfixed-text$' {
            $cordisBytes = Get-ZipEntryBytes -ZipPath $Rc2Zip -RelPath $frozenIdentity.CordisPath
            $hot = Remove-CordisTargetLine -Rc2CordisBytes $cordisBytes -Mode 'text'
            $sha = Get-Sha256Bytes $hot
            if ($sha -ne $frozenIdentity.HotfixTextRemovedSha256) { throw "fixture: hotfixed-text hash $sha != allowed $($frozenIdentity.HotfixTextRemovedSha256)" }
            [System.IO.File]::WriteAllBytes((Join-Path $fixture.InstallRoot ($frozenIdentity.CordisPath -replace '/', '\')), $hot)
            $fixture.HotfixVariant = 'HOTFIX_TEXT_REMOVED'
            break
        }
        '^tampered$' {
            $targetFile = Join-Path $fixture.InstallRoot ($variantTarget -replace '/', '\')
            if (-not [System.IO.File]::Exists($targetFile)) { throw "fixture: tampered target not found in the base tree: $variantTarget" }
            $old = [System.IO.File]::ReadAllBytes($targetFile)
            $marker = (New-Utf8NoBom).GetBytes("`nSANDBOX_TAMPER_MARKER_$($seed)`n")
            $combined = New-Object byte[] ($old.Length + $marker.Length)
            [System.Array]::Copy($old, 0, $combined, 0, $old.Length)
            [System.Array]::Copy($marker, 0, $combined, $old.Length, $marker.Length)
            [System.IO.File]::WriteAllBytes($targetFile, $combined)
            $fixture.TamperedPath = $variantTarget
            break
        }
        '^missing$' {
            $targetFile = Join-Path $fixture.InstallRoot ($variantTarget -replace '/', '\')
            if (-not [System.IO.File]::Exists($targetFile)) { throw "fixture: missing target not found in the base tree: $variantTarget" }
            [System.IO.File]::Delete($targetFile)
            $fixture.MissingPath = $variantTarget
            break
        }
        '^mixed$' {
            # Some unified target payload files copied over the RC2 install: a
            # mixed RC2/unified state that must be detected as UNKNOWN.
            $candidates = @('README.md', 'CHANGELOG.md', 'VERSION', 'START_HERE.md')
            $mixedPaths = New-Object System.Collections.ArrayList
            foreach ($rel in $candidates) {
                if ($mixedPaths.Count -ge 3) { break }
                if (-not $model.ReplacedPaths -contains $rel) { continue }
                if ($null -eq $rc2Map.Map[$rel]) { continue }
                [void](Copy-PackageFileToTree -Model $model -DestinationRoot $fixture.InstallRoot -RelPath $rel)
                [void]$mixedPaths.Add($rel)
            }
            if ($mixedPaths.Count -eq 0) { throw 'fixture: mixed variant found no candidate replaced payload path' }
            $fixture.MixedPaths = @($mixedPaths.ToArray())
            break
        }
        '^target-files-present$' {
            $added = @($model.AddedPaths | Sort-Object)
            if ($added.Count -eq 0) { throw 'fixture: target-files-present variant requires at least one operation:add payload file' }
            $rel = [string]$added[0]
            [void](Copy-PackageFileToTree -Model $model -DestinationRoot $fixture.InstallRoot -RelPath $rel)
            $fixture.PresentTargetOnlyPath = $rel
            break
        }
    }

    # --- fake venv --------------------------------------------------------------
    if ($baseKind -ne 'no-venv') {
        New-FakeVenv -InstallRoot $fixture.InstallRoot -Seed $seed
        $fixture.VenvPresent = $true
    } else {
        $fixture.VenvPresent = $false
    }

    # --- env files (installer state) -------------------------------------------
    $installedAt = '2026-10-01T12:00:00+08:00'
    if ($fixture.BaseDistribution -eq $targetVersion) { $installedAt = '2026-10-05T12:00:00+08:00' }
    if ($baseKind -eq 'rc3-unified' -and $model) {
        New-FixtureEnvFiles -InstallRoot $fixture.InstallRoot -Root $rootFull -DshHome (Join-Path $rootFull 'dsh-home') `
            -Profile $Profile -Distribution $fixture.BaseDistribution -InstalledAt $installedAt `
            -UpgradeId $model.UpgradeId -UpgradeFrom $model.SourceVersion -UpgradeTo $model.TargetVersion -UpgradedBy 'tools/setup.ps1'
    } else {
        New-FixtureEnvFiles -InstallRoot $fixture.InstallRoot -Root $rootFull -DshHome (Join-Path $rootFull 'dsh-home') `
            -Profile $Profile -Distribution $fixture.BaseDistribution -InstalledAt $installedAt
    }

    # --- simulated user data + extra user files --------------------------------
    $fixture.UserHome = Join-Path $rootFull 'home'
    [void][System.IO.Directory]::CreateDirectory($fixture.UserHome)
    New-UserDataFixture -Root $rootFull -UserHome $fixture.UserHome -Seed $seed
    $utf8 = New-Utf8NoBom
    [System.IO.File]::WriteAllText((Join-Path $fixture.InstallRoot 'user-notes.txt'),
        "# 用户自建笔记（沙箱占位，升级必须原样保留）`nsandbox user note`n", $utf8)
    if ($baseKind -eq 'extra-user-files') {
        [System.IO.File]::WriteAllText((Join-Path $fixture.InstallRoot '我的笔记 2026.txt'),
            "沙箱额外用户文件，升级必须保留。`n", $utf8)
        [void][System.IO.Directory]::CreateDirectory((Join-Path $fixture.InstallRoot 'notes'))
        [System.IO.File]::WriteAllText((Join-Path $fixture.InstallRoot 'notes\scratch.md'),
            "# sandbox scratch user file`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $fixture.InstallRoot 'bundle\cnki-research\README.user-notes.md'),
            "# sandbox user note next to the bundle`n", $utf8)
    }

    # --- isolated DSH home + profile + real directory junction ------------------
    $fixture.DshHome = Join-Path $rootFull 'dsh-home'
    $fixture.Profile = $Profile
    $fixture.ProfileDir = Join-Path (Join-Path $fixture.DshHome 'profiles') $Profile
    [void][System.IO.Directory]::CreateDirectory($fixture.DshHome)
    $fixture.JunctionPath = Join-Path $fixture.ProfileDir 'node_modules\@local\dsh-cnki-research'
    $fixture.JunctionTarget = Get-FullPath $fixture.BundleDir
    if ($baseKind -ne 'no-profile') {
        $junctionError = $null
        try {
            New-DshProfileFixture -DshHome $fixture.DshHome -InstallRoot $fixture.InstallRoot -Profile $Profile
        } catch {
            # long-path fixtures may hit a host limit on junction targets; the
            # profile then stays absent and the engine must WARN, not fail.
            $junctionError = $_.Exception.Message
            try { New-DshProfileFixture -DshHome $fixture.DshHome -InstallRoot $fixture.InstallRoot -Profile $Profile -NoJunction } catch { $junctionError = $_.Exception.Message }
        }
        $fixture.JunctionCreated = Test-IsReparsePoint $fixture.JunctionPath
        $fixture.JunctionError = $junctionError
    } else {
        $fixture.JunctionCreated = $false
    }

    # --- fixture fingerprint (independent baseline for oracle assertions) ------
    $fingerprint = New-FixtureFingerprint -Fixture $fixture -Root $rootFull -Seed $seed
    $fixture.Fingerprint = $fingerprint
    $fixture.FingerprintFile = Write-JsonFile -Path (Join-Path $rootFull 'fixture-fingerprint.json') -Value $fingerprint -Depth 30

    $fixture.InstallRootPathLength = $fixture.InstallRoot.Length
    $maxRel = ($fingerprint.entries.install | ForEach-Object { $_.Rel.Length } | Measure-Object -Maximum).Maximum
    if ($null -eq $maxRel) { $maxRel = 0 }
    $fixture.LongestInstallRelPath = $maxRel
    $fixture.LongestInstallFilePath = $fixture.InstallRoot.Length + 1 + $maxRel
    return $fixture
}

function New-FixtureObject {
    param([string]$Root, [string]$Variant, [string]$Profile)
    [pscustomobject]@{
        Root              = Get-FullPath $Root
        Variant           = $Variant
        Profile           = $Profile
        Rc2Zip            = $null
        Rc3FrozenZip      = $null
        PackageDir        = $null
        Model             = $null
        Rc2Map            = $null
        Rc2FileCount      = 0
        InstallRoot       = $null
        PackageRoot       = $null
        PackageRootIsInstallRoot = $false
        BundleDir         = $null
        VenvDir           = $null
        StateDir          = $null
        InstallStateFile  = $null
        RuntimeFile       = $null
        DshHome           = $null
        ProfileDir        = $null
        UserHome          = $null
        JunctionPath      = $null
        JunctionTarget    = $null
        JunctionCreated   = $false
        JunctionError     = $null
        Fingerprint       = $null
        FingerprintFile   = $null
        BaseDistribution  = $null
        UpgradeApplied    = $false
        HotfixVariant     = $null
        TamperedPath      = $null
        MissingPath       = $null
        MixedPaths        = @()
        PresentTargetOnlyPath = $null
        VenvPresent       = $false
        LongPathSupported = $false
        InstallRootPathLength = 0
        LongestInstallRelPath = 0
        LongestInstallFilePath = 0
    }
}

function New-FixtureFingerprint {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Seed
    )
    $rootFull = Get-FullPath $Root
    $installEntries = @(Get-TreeSnapshot -Root $Fixture.InstallRoot | Where-Object { $_.Rel -ne '' })
    $dshEntries = @()
    if ([System.IO.Directory]::Exists($Fixture.DshHome)) { $dshEntries = @(Get-TreeSnapshot -Root $Fixture.DshHome | Where-Object { $_.Rel -ne '' }) }
    $userEntries = @()
    if ($Fixture.UserHome -and [System.IO.Directory]::Exists($Fixture.UserHome)) { $userEntries = @(Get-TreeSnapshot -Root $Fixture.UserHome | Where-Object { $_.Rel -ne '' }) }
    $packageEntries = @()
    if ($Fixture.PackageRoot -and [System.IO.Directory]::Exists($Fixture.PackageRoot) -and
        -not [string]::Equals($Fixture.PackageRoot, $Fixture.InstallRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-PathUnder -Child $Fixture.PackageRoot -Parent $rootFull)) {
        $packageEntries = @(Get-TreeSnapshot -Root $Fixture.PackageRoot | Where-Object { $_.Rel -ne '' })
    }
    $junction = $null
    if ($Fixture.JunctionCreated) {
        $junction = [ordered]@{
            path   = $Fixture.JunctionPath
            target = (Get-ReparseTarget $Fixture.JunctionPath)
            isReparse = [bool](Test-IsReparsePoint $Fixture.JunctionPath)
        }
    } else {
        $junction = [ordered]@{ path = $Fixture.JunctionPath; target = $null; isReparse = $false; created = $false }
    }
    return [ordered]@{
        schemaVersion     = 1
        fixture           = $Fixture.Variant
        caseName          = $Seed
        createdUtc        = (Get-Date).ToString('o')
        root              = $rootFull
        installRoot       = $Fixture.InstallRoot
        packageRoot       = $Fixture.PackageRoot
        dshHome           = $Fixture.DshHome
        userHome          = $Fixture.UserHome
        profile           = $Fixture.Profile
        baseDistribution  = $Fixture.BaseDistribution
        hotfixVariant     = $Fixture.HotfixVariant
        longPathSupported = [bool]$Fixture.LongPathSupported
        venvSeed          = $Seed
        junction          = $junction
        entries           = [ordered]@{
            install = @($installEntries | ForEach-Object { ConvertTo-FingerprintEntry $_ })
            dshHome = @($dshEntries | ForEach-Object { ConvertTo-FingerprintEntry $_ })
            userHome = @($userEntries | ForEach-Object { ConvertTo-FingerprintEntry $_ })
            package = @($packageEntries | ForEach-Object { ConvertTo-FingerprintEntry $_ })
        }
    }
}

function ConvertTo-FingerprintEntry {
    param($Entry)
    [ordered]@{
        Rel           = $Entry.Rel
        Kind          = $Entry.Kind
        Bytes         = $Entry.Bytes
        Sha256        = $Entry.Sha256
        MtimeUtcTicks = $Entry.MtimeUtcTicks
        Target        = $Entry.Target
    }
}

# ---------------------------------------------------------------------------
# In-place fixture modifiers shared by several matrix cases
# (each may be used repeatedly on a fresh fixture; all under the fixture root)
# ---------------------------------------------------------------------------

function Assert-FixturePathSafe {
    param($Fixture, [string]$Path)
    if (-not (Test-PathUnder -Child $Path -Parent $Fixture.Root)) {
        throw "refusing to touch path outside the sandbox fixture root: $Path"
    }
}

function Set-FixtureFileBytes {
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$RelPath, [Parameter(Mandatory = $true)][byte[]]$Bytes)
    $path = Join-Path $Fixture.InstallRoot ($RelPath -replace '/', '\')
    Assert-FixturePathSafe -Fixture $Fixture -Path $path
    $parent = [System.IO.Path]::GetDirectoryName($path)
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllBytes($path, $Bytes)
}

function Add-FixturePayloadTamper {
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$RelPath, [string]$Marker = '')
    $path = Join-Path $Fixture.InstallRoot ($RelPath -replace '/', '\')
    Assert-FixturePathSafe -Fixture $Fixture -Path $path
    if (-not [System.IO.File]::Exists($path)) { throw "Add-FixturePayloadTamper: file not found: $RelPath" }
    $old = [System.IO.File]::ReadAllBytes($path)
    $markerBytes = (New-Utf8NoBom).GetBytes($Marker)
    $combined = New-Object byte[] ($old.Length + $markerBytes.Length)
    [System.Array]::Copy($old, 0, $combined, 0, $old.Length)
    [System.Array]::Copy($markerBytes, 0, $combined, $old.Length, $markerBytes.Length)
    [System.IO.File]::WriteAllBytes($path, $combined)
}

function Remove-FixturePayloadFile {
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$RelPath)
    $path = Join-Path $Fixture.InstallRoot ($RelPath -replace '/', '\')
    Assert-FixturePathSafe -Fixture $Fixture -Path $path
    if (-not [System.IO.File]::Exists($path)) { throw "Remove-FixturePayloadFile: file not found: $RelPath" }
    [System.IO.File]::Delete($path)
}

function Copy-FixtureTargetFile {
    # Copies one candidate-package TARGET file (payload or manifest.json) into
    # the install root byte-exactly (used by mixed / target-only fixtures).
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$RelPath)
    if (-not $Fixture.Model) { throw 'Copy-FixtureTargetFile: fixture has no candidate package model' }
    return (Copy-PackageFileToTree -Model $Fixture.Model -DestinationRoot $Fixture.InstallRoot -RelPath $RelPath)
}

function Add-FixturePostUpgradeUserEdit {
    # Appends user bytes to an installed file (simulates a user edit after an
    # upgrade).  Used for rollback-conflict and unknown-state fixtures.
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$RelPath,
        [string]$Marker = "`nUSER_EDIT_AFTER_UPGRADE_SANDBOX`n"
    )
    Add-FixturePayloadTamper -Fixture $Fixture -RelPath $RelPath -Marker $Marker
    return (Get-Sha256File (Join-Path $Fixture.InstallRoot ($RelPath -replace '/', '\')))
}

function Add-FixtureTargetOnlyFile {
    # Places one operation:add target file into an RC2 install: the engine must
    # classify the state as UNKNOWN_OR_MODIFIED (TARGET_ONLY_FILES_PRESENT).
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$RelPath)
    if (-not $Fixture.Model) { throw 'Add-FixtureTargetOnlyFile: fixture has no candidate package model' }
    [void](Copy-PackageFileToTree -Model $Fixture.Model -DestinationRoot $Fixture.InstallRoot -RelPath $RelPath)
    return $RelPath
}

function Remove-FixtureInstalledFile {
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$RelPath)
    $path = Join-Path $Fixture.InstallRoot ($RelPath -replace '/', '\')
    Assert-FixturePathSafe -Fixture $Fixture -Path $path
    if (-not [System.IO.File]::Exists($path)) { throw "Remove-FixtureInstalledFile: file not found: $RelPath" }
    [System.IO.File]::Delete($path)
}

function Set-FixtureVersionText {
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$Text)
    Set-FixtureFileBytes -Fixture $Fixture -RelPath 'VERSION' -Bytes ((New-Utf8NoBom).GetBytes($Text))
}

function Set-FixtureInstallStateDistribution {
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$Distribution)
    $state = Read-JsonFile $Fixture.InstallStateFile
    $state.distribution = $Distribution
    Write-JsonFile -Path $Fixture.InstallStateFile -Value $state -Depth 15 | Out-Null
}

function Add-FixturePendingTransaction {
    # Synthesizes a leftover transaction directory (simulated interrupted apply).
    # Schema follows the v2 engine transaction record (charter D6 / engine contract).
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [string]$TransactionId = '20261018T000000Z-deadbeef',
        [string]$Phase = 'APPLYING'
    )
    $txnDir = Join-Path $Fixture.StateDir ("upgrades\" + $TransactionId)
    [void][System.IO.Directory]::CreateDirectory($txnDir)
    $identity = Get-FrozenIdentity
    $model = $Fixture.Model
    $upgradeId = if ($model) { $model.UpgradeId } else { 'cnki-portable-1.0.0-rc.2-to-1.0.0-rc.3-unified' }
    $sourceVersion = if ($model) { $model.SourceVersion } else { $identity.Rc2Version }
    $targetVersion = if ($model) { $model.TargetVersion } else { $identity.Rc3Version }
    $targetManifestSha = if ($model) { $model.ManifestSha256 } else { $identity.Rc3ManifestSha256 }
    $txn = [ordered]@{
        schemaVersion    = 1
        tool             = 'cnki-portable-upgrader'
        toolVersion      = '1.0.0-unified'
        upgradeId        = $upgradeId
        transactionId    = $TransactionId
        transactionDir   = $txnDir
        installRoot      = $Fixture.InstallRoot
        packageRoot      = $Fixture.PackageRoot
        sourceState      = 'RC2_CLEAN'
        sourceVersion    = $sourceVersion
        targetVersion    = $targetVersion
        sourceManifestSha256 = $identity.Rc2ManifestSha256
        targetManifestSha256 = $targetManifestSha
        planId           = ('0' * 64)
        phase            = $Phase
        backupDir        = (Join-Path $txnDir 'backup')
        stagingDir       = (Join-Path $txnDir 'staging')
        backupVerified   = $false
        stagingVerified  = $false
        restoreVerified  = $false
        files            = @()
        envFiles         = @()
        createdDirectories = @()
    }
    Write-JsonFile -Path (Join-Path $txnDir 'transaction.json') -Value $txn -Depth 20 | Out-Null
    return $txnDir
}

function Replace-FixturePayloadDirectoryWithJunction {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$RelPath,
        [string]$JunctionTarget = ''
    )
    $dir = Join-Path $Fixture.InstallRoot ($RelPath -replace '/', '\')
    Assert-FixturePathSafe -Fixture $Fixture -Path $dir
    if (-not [System.IO.Directory]::Exists($dir)) { throw "payload directory not found: $RelPath" }
    if (Test-IsReparsePoint $dir) { throw "already a reparse point: $RelPath" }
    if (-not $JunctionTarget) { $JunctionTarget = Join-Path $Fixture.Root ('_junction-targets\' + ($RelPath -replace '[/\\]', '_')) }
    [void][System.IO.Directory]::CreateDirectory($JunctionTarget)
    [System.IO.File]::WriteAllText((Join-Path $JunctionTarget 'redirected.txt'),
        'sandbox junction redirection target - engine must refuse to write through it' + "`n", (New-Utf8NoBom))
    Remove-DirectoryContentsJunctionSafe -Directory $dir
    [System.IO.Directory]::Delete($dir, $false)
    New-FixtureDirectoryJunction -Path $dir -Target $JunctionTarget
    return $JunctionTarget
}

function New-FixtureJunctionInstallRoot {
    param([Parameter(Mandatory = $true)]$Fixture, [string]$LinkName = 'install-junction')
    $link = Join-Path $Fixture.Root $LinkName
    New-FixtureDirectoryJunction -Path $link -Target $Fixture.InstallRoot
    return $link
}

function Set-FixtureReadOnlyAttribute {
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$RelPath, [switch]$Clear)
    $path = Join-Path $Fixture.InstallRoot ($RelPath -replace '/', '\')
    Assert-FixturePathSafe -Fixture $Fixture -Path $path
    if (-not [System.IO.File]::Exists($path)) { throw "Set-FixtureReadOnlyAttribute: file not found: $RelPath" }
    $attrs = [System.IO.File]::GetAttributes($path)
    if ($Clear) { $attrs = $attrs -band (-bnot [System.IO.FileAttributes]::ReadOnly) }
    else { $attrs = $attrs -bor [System.IO.FileAttributes]::ReadOnly }
    [System.IO.File]::SetAttributes($path, $attrs)
}

# ===========================================================================
# End of UnifiedFixtures.ps1
# ===========================================================================
