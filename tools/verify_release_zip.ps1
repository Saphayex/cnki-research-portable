# Verify a unified CNKI Research Portable candidate ZIP exactly as an end user receives it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify_release_zip.ps1 `
#     -Zip <candidate zip> [-Rc2Zip <frozen rc2 zip>] [-Rc3FrozenZip <frozen rc3 zip>] `
#     [-ReleaseManifest <RELEASE_MANIFEST.json>] [-WorkDir <dir>] [-ReportDir <dir>] [-Json]
#
# Unified RC3 candidate verifier, Z1-Z9 (independent of the builder implementation):
#   Z1 archiveIdentity         ZIP SHA-256 vs <.zip>.sha256 sidecar; optional external
#                              RELEASE_MANIFEST.json cross-check; external anchor status.
#   Z2 zipStructure            no dir entries / backslashes / duplicate or unsafe names;
#                              entries sorted Ordinal; fixed 1980-01-01 timestamps; attr 0.
#   Z3 extractAndEntryPoints   fresh extraction; entry set closure; required entry points;
#                              docs/*.md present.
#   Z4 noLeftovers             no runtime artefact, log, credential, payload/ dir, .git,
#                              internal material (_AUDIT/_SPEC/_evidence/_build/_verify/
#                              sandbox), no RELEASE_MANIFEST.json inside the archive.
#   Z5 internalSumsClosure     SHA256SUMS.txt: strict V1 format, LF/no BOM/final newline,
#                              sorted, covers every package file except itself, no self entry.
#   Z6 manifestIntegrity       manifest.json: schemaVersion 1, unified identity, files[]
#                              bytes+hashes match the extracted bytes, no metadata entries.
#   Z7 upgradeDataConsistency  upgrade-data/rc2-to-rc3.json (schemaVersion 2): constants,
#                              targetManifestHash == sha256(manifest.json), expected maps,
#                              changedFiles/operations/added-file rules, payloadSetHash,
#                              frozen RC2 anchors + hotfix variants, no cycles/self refs.
#   Z8 staticSuites            node tools/build_manifest.mjs --check; tests/test_static_package.mjs;
#                              tests/test_unified_package.mjs (node absent => NOT TESTED).
#   Z9 installerEngineChecks   portable.ps1 -Action check + setup.ps1 -Action check on the
#                              extracted copy with throwaway DSH homes, zero-write proof via
#                              a tree fingerprint, plus closure re-check under a space/CJK path.
#
# Read-only with respect to the archive and the product files: it only writes under
# -WorkDir/-ReportDir. Exit codes: 0 = no FAIL (WARN/NOT TESTED allowed), 1 = FAIL, 2 = harness error.
#
# Windows PowerShell 5.1. ASCII-only source on purpose (no BOM needed; PS 5.1 decodes it
# as ANSI safely). CJK/space verification paths are constructed from character codes.

[CmdletBinding()]
param(
    [string]$Zip,
    [string]$WorkDir,
    [string]$ReportDir,
    [string]$ReleaseManifest,
    [string]$Rc2Zip,
    [string]$Rc3FrozenZip,
    [switch]$Json,
    [switch]$KeepExtracted,
    [switch]$SkipInstallerCheck
)

$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
}
catch {
    Write-Host "FATAL: required .NET compression assemblies are unavailable: $($_.Exception.Message)"
    exit 2
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Ordinal = [System.StringComparer]::Ordinal
$script:Checks = New-Object System.Collections.ArrayList
$script:ZipInfo = $null
$script:PayloadFileCount = 0
$script:ChangedFileCount = 0
$script:ExternalAnchor = 'NOT SUPPLIED'

# Frozen identities (read-only trust anchors; independent constants).
$script:Frozen = [ordered]@{
    Rc2ZipBytes          = 388236
    Rc2ZipSha256         = '4f279f359a42e5e950cd9f66e04f0922c5e40ec4c77f9192e2168274ce1142b5'
    Rc3ZipBytes          = 395232
    Rc3ZipSha256         = 'f4e914d135eb51b8d3afbd96e7fca53997a06e0ed1a75a28cca9386c3cc7f5fd'
    Rc2ManifestSha256    = '80229318a1ef070f5cedafda39785be0cbb49ee727f7a620e7e6aab5113a6e1f'
    Rc3ManifestSha256    = '98c8bca2bd34f0eda0e1d9fb1d0c6f38e60c8c4e92990efcb1c3be507f99a5e2'
    Rc2Version           = '1.0.0-rc.2'
    Rc3Version           = '1.0.0-rc.3'
    CoreBundleVersion    = '1.0.0'
    UpgradeId            = 'cnki-portable-1.0.0-rc.2-to-1.0.0-rc.3-unified'
    UpgraderVersion      = '2.0.0'
    DistributionId       = 'cnki-research-portable-unified-1.0.0-rc.3'
    MetadataKind         = 'cnki-research-portable-unified-upgrade'
    MetadataRel          = 'upgrade-data/rc2-to-rc3.json'
    MetadataReadmeRel    = 'upgrade-data/README.md'
    SumsRel              = 'SHA256SUMS.txt'
    ManifestRel          = 'manifest.json'
    SourcePayloadCount   = 107
    CordisRelPath        = 'bundle/cnki-research/cordis.patch.yml'
    CordisRc2Bytes       = 16762
    CordisRc2Sha256      = 'afa6ffdd0684fe0440a5e3d2414c08fe36be946e64c19648c48b3770f68bf343'
    HotfixLineRemovedSha = 'edda8817e0bf449d8324f4875b1c7acd37a8dc693c3a82d044f4a5c436421778'
    HotfixTextRemovedSha = 'b5aaa79ebb7a0c1bdd6f253e6462b0c1ee3db8f4f34cf15e83e0a59a37e4c0a9'
    PersonaPrefix        = 'You are a coding agent powered by the {{model}} model.'
    ForbiddenCwdToken    = '{{cwd}}'
}

$script:ToolNames = @('easy-search', 'advanced-search', 'get-info-from-url', 'get-info-by-detail', 'list-journal', 'search-issn', 'login', 'logout')

$script:RequiredEntryPoints = @(
    'README.md', 'README_EN.md', 'START_HERE.md', 'INSTALL_PROMPT.md', 'DEPLOYMENT_README.md',
    'VERSION', 'manifest.json', 'SHA256SUMS.txt', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'CHANGELOG.md',
    'docs/provenance/README.md', 'docs/provenance/v1.0-bundle.sha256.json',
    'docs/provenance/upstream-src.sha256.json',
    'bundle/cnki-research/package.json', 'bundle/cnki-research/cordis.patch.yml',
    'bundle/cnki-research/launcher/cnki_research_launcher.py',
    'bundle/cnki-research/skills/cnki-literature-search/SKILL.md',
    'tools/portable.ps1', 'tools/lib/PortableCommon.ps1', 'tools/build_manifest.mjs',
    'tools/package_release.ps1', 'tools/verify_release_zip.ps1', 'tools/build_unified_release.ps1',
    'tools/build_release_manifest.mjs', 'tools/probe_mcp_stdio.py',
    'tools/setup.ps1', 'tools/lib/UpgradeCommon.ps1',
    'upgrade-data/rc2-to-rc3.json', 'upgrade-data/README.md',
    'tests/run_all.ps1', 'tests/test_static_package.mjs', 'tests/test_tool_schema.mjs',
    'tests/test_dsh_isolated.ps1', 'tests/Test-UnifiedMatrix.ps1', 'tests/Test-UnifiedVerification.ps1',
    'tests/lib/UnifiedFixtures.ps1', 'tests/lib/UnifiedAssert.ps1', 'tests/test_unified_package.mjs',
    'upstream/cnki-mcp/pyproject.toml', 'upstream/cnki-mcp/uv.lock', 'upstream/cnki-mcp/LICENSE'
)

$script:ForbiddenDirNames = @(
    '_scratch', '_portable', '.venv', 'node_modules', '__pycache__', 'dist', '_staging',
    '_build', '_evidence', '_verify', '_AUDIT', '_SPEC', 'sandbox', '.git', 'payload', 'test-evidence'
)
$script:ForbiddenArtifactNames = @(
    'portable.runtime.json', 'cookies.json', 'storage_state.json', '.credentials.yaml',
    'RELEASE_MANIFEST.json', '.DS_Store', 'Thumbs.db'
)
$script:ForbiddenArtifactExts = @('.pyc', '.log', '.zip', '.sha256', '.exe', '.dll', '.pyd', '.pdb')
$script:DevPathMarkers = @(
    ('F:' + '\DSH'), ('F:' + '/DSH'), ('F:' + '\cnki-mcp'), ('cnki-' + 'mcp Mode'),
    ('D:' + '\DeepSeekHarness'), ('.dsh-' + 'cnki-profile')
)

# A real developer account name is never baked into shipped sources. It is matched
# only when a maintainer injects it for the current process, the same convention as
# tests/test_static_package.mjs. When unset, only the generic markers above apply.
$script:InjectedAccountMarker = $env:CNKI_ACCOUNT_MARKER
if (-not [string]::IsNullOrEmpty($script:InjectedAccountMarker)) {
    $script:DevPathMarkers += $script:InjectedAccountMarker.Trim()
}
$script:FrozenCorePrefixes = @('bundle/', 'upstream/', 'docs/provenance/', 'tools/vendor/', 'docs/06-')
$script:FrozenCoreFiles = @('LICENSE', 'THIRD-PARTY-NOTICES.md', 'VERSION', '.gitignore', 'tools/portable.ps1', 'tools/lib/PortableCommon.ps1', 'tools/probe_mcp_stdio.py')

# =============================================================================================
# Generic helpers
# =============================================================================================
function Add-Check([string]$Id, [string]$Status, [string]$Detail) {
    [void]$script:Checks.Add([pscustomobject]@{ id = $Id; status = $Status; detail = $Detail })
    if (-not $Json) {
        switch ($Status) {
            'PASS' { Write-Host "[PASS] $Id - $Detail" }
            'WARN' { Write-Host "[WARN] $Id - $Detail" -ForegroundColor Yellow }
            'NOT TESTED' { Write-Host "[NOT TESTED] $Id - $Detail" -ForegroundColor Yellow }
            default { Write-Host "[FAIL] $Id - $Detail" -ForegroundColor Red }
        }
    }
}
function Assert-True([bool]$Condition, [string]$Id, [string]$PassDetail, [string]$FailDetail) {
    if ($Condition) { Add-Check $Id 'PASS' $PassDetail } else { Add-Check $Id 'FAIL' $FailDetail }
}
function ConvertTo-HexString([byte[]]$Bytes) {
    $sb = New-Object System.Text.StringBuilder ($Bytes.Length * 2)
    foreach ($b in $Bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}
function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-HexString ($sha.ComputeHash($Bytes))) }
    finally { $sha.Dispose() }
}
function Get-Sha256Text([string]$Text) { return (Get-Sha256Bytes ($script:Utf8NoBom.GetBytes($Text))) }
function Get-Sha256File([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { return (ConvertTo-HexString ($sha.ComputeHash($fs))) }
    finally { $fs.Dispose(); $sha.Dispose() }
}
function Get-Text([byte[]]$Bytes) {
    $offset = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $offset = 3 }
    return $script:Utf8Strict.GetString($Bytes, $offset, $Bytes.Length - $offset)
}
function Read-JsonText([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw "file must be UTF-8 without BOM: $Path" }
    return ((Get-Text $bytes) | ConvertFrom-Json)
}
function Resolve-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}
function Get-NormalizedPath([string]$Path) { return (Resolve-FullPath $Path).TrimEnd('\', '/') }
function Ensure-Directory([string]$Path) {
    if (-not [System.IO.Directory]::Exists($Path)) { [void][System.IO.Directory]::CreateDirectory($Path) }
}
function Write-TextFile([string]$Path, [string]$Text) {
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($dir)) { Ensure-Directory $dir }
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}
function Sort-Ordinal([string[]]$Items) {
    $copy = [string[]]@($Items)
    [Array]::Sort($copy, $script:Ordinal)
    return $copy
}
function Test-SortedOrdinal([string[]]$Items) {
    for ($i = 1; $i -lt $Items.Count; $i++) {
        if ([string]::CompareOrdinal($Items[$i - 1], $Items[$i]) -gt 0) { return $false }
    }
    return $true
}
function Test-StringSetEqual([string[]]$A, [string[]]$B) {
    if ($A.Count -ne $B.Count) { return $false }
    for ($i = 0; $i -lt $A.Count; $i++) { if (-not [string]::Equals($A[$i], $B[$i], [System.StringComparison]::Ordinal)) { return $false } }
    return $true
}
function Get-SafePathIssue([string]$RelPath) {
    if ([string]::IsNullOrEmpty($RelPath)) { return 'empty path' }
    if ($RelPath.StartsWith('/') -or $RelPath.StartsWith('\')) { return 'rooted path' }
    if ($RelPath -match '^[A-Za-z]:') { return 'drive-rooted path' }
    if ($RelPath.Contains('\')) { return 'backslash separator' }
    if ($RelPath.Contains(':')) { return 'colon (ADS/device)' }
    if ($RelPath -match '[\x00-\x1f]') { return 'control character' }
    $segments = $RelPath.Split([char]'/')
    foreach ($seg in $segments) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') { return "unsafe segment '$seg'" }
        if ($seg -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { return "reserved device name '$seg'" }
    }
    return $null
}
function Get-RelativeFileSet([string]$Root) {
    $root = Get-NormalizedPath $Root
    $list = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push('')
    while ($stack.Count -gt 0) {
        $relDir = [string]$stack.Pop()
        if ($relDir -eq '') { $dirFull = $root } else { $dirFull = [System.IO.Path]::Combine($root, $relDir.Replace('/', '\')) }
        $names = [System.IO.Directory]::GetFileSystemEntries($dirFull)
        $sorted = [string[]]@($names)
        [Array]::Sort($sorted, $script:Ordinal)
        foreach ($full in $sorted) {
            $name = [System.IO.Path]::GetFileName($full)
            $child = $name
            if ($relDir -ne '') { $child = $relDir + '/' + $name }
            $attrs = [System.IO.File]::GetAttributes($full)
            if ((($attrs -band [System.IO.FileAttributes]::Directory) -ne 0)) {
                if ((($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { [void]$list.Add($child + '/') } else { $stack.Push($child) }
            }
            else { [void]$list.Add($child) }
        }
    }
    return (Sort-Ordinal @($list.ToArray()))
}
function Extract-ZipSafe([string]$ZipPath, [string]$Destination) {
    Ensure-Directory $Destination
    $result = New-Object System.Collections.Specialized.OrderedDictionary
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ($name.EndsWith('/')) { continue }
            $issue = Get-SafePathIssue $name
            if ($null -ne $issue) { throw "unsafe zip entry '$name': $issue" }
            $target = [System.IO.Path]::Combine($Destination, $name.Replace('/', '\'))
            $parent = [System.IO.Path]::GetDirectoryName($target)
            if (-not [string]::IsNullOrEmpty($parent)) { Ensure-Directory $parent }
            $ms = New-Object System.IO.MemoryStream
            $stream = $entry.Open()
            try { $stream.CopyTo($ms) } finally { $stream.Dispose() }
            $bytes = $ms.ToArray()
            $ms.Dispose()
            [System.IO.File]::WriteAllBytes($target, $bytes)
            $result[$name] = [ordered]@{ sha = (Get-Sha256Bytes $bytes); bytes = [int64]$bytes.Length }
        }
    }
    finally { $archive.Dispose() }
    return $result
}
function Invoke-NodeJson([string[]]$NodeArgs, [string]$WorkingDir, [string]$ReportPath) {
    $result = @{ available = $false; exit = -1; output = ''; report = $null }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) { return $result }
    $result['available'] = $true
    $prevEap = $ErrorActionPreference
    Push-Location -LiteralPath $WorkingDir
    try {
        $ErrorActionPreference = 'Continue'
        $allArgs = @()
        foreach ($a in $NodeArgs) { $allArgs += $a }
        if (-not [string]::IsNullOrEmpty($ReportPath)) { $allArgs += @('--write-report', $ReportPath) }
        $out = & $node.Source @allArgs 2>&1 | Out-String
        $result['exit'] = $LASTEXITCODE
        $result['output'] = $out
    }
    finally {
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
    if (-not [string]::IsNullOrEmpty($ReportPath) -and [System.IO.File]::Exists($ReportPath)) {
        try { $result['report'] = Read-JsonText $ReportPath } catch { $result['report'] = $null }
    }
    return $result
}
function Get-TreeFingerprint([string]$Root) {
    $fingerprint = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($rel in (Get-RelativeFileSet $Root)) {
        if ($rel.EndsWith('/')) { continue }
        $full = [System.IO.Path]::Combine($Root, $rel.Replace('/', '\'))
        $info = New-Object System.IO.FileInfo($full)
        $fingerprint[$rel] = [ordered]@{
            bytes  = [int64]$info.Length
            mtime  = $info.LastWriteTimeUtc.ToString('o')
            sha256 = (Get-Sha256File $full)
        }
    }
    return $fingerprint
}
function Compare-Fingerprint($Before, $After) {
    $issues = New-Object System.Collections.ArrayList
    foreach ($key in $Before.Keys) {
        if (-not $After.Contains($key)) { [void]$issues.Add("removed '$key'"); continue }
        if ([int64]$Before[$key]['bytes'] -ne [int64]$After[$key]['bytes']) { [void]$issues.Add("size changed '$key'") }
        if ([string]$Before[$key]['sha256'] -cne [string]$After[$key]['sha256']) { [void]$issues.Add("content changed '$key'") }
        if ([string]$Before[$key]['mtime'] -cne [string]$After[$key]['mtime']) { [void]$issues.Add("mtime changed '$key'") }
    }
    foreach ($key in $After.Keys) { if (-not $Before.Contains($key)) { [void]$issues.Add("created '$key'") } }
    return @($issues.ToArray())
}

# =============================================================================================
# Shared model builders / closure checks (reused for the main and the space+CJK extraction)
# =============================================================================================
function Read-Rc2Model([string]$Rc2ZipPath) {
    if (-not [System.IO.File]::Exists($Rc2ZipPath)) { throw "frozen RC2 ZIP not found: '$Rc2ZipPath'" }
    $bytes = (New-Object System.IO.FileInfo($Rc2ZipPath)).Length
    $sha = Get-Sha256File $Rc2ZipPath
    if ($bytes -ne $script:Frozen['Rc2ZipBytes'] -or $sha -cne $script:Frozen['Rc2ZipSha256']) {
        throw "frozen RC2 ZIP identity mismatch (bytes=$bytes sha=$sha)"
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Rc2ZipPath)
    try {
        $manifestEntry = $archive.GetEntry('manifest.json')
        if ($null -eq $manifestEntry) { throw 'frozen RC2 ZIP has no manifest.json' }
        $ms = New-Object System.IO.MemoryStream
        $s = $manifestEntry.Open()
        try { $s.CopyTo($ms) } finally { $s.Dispose() }
        $manifestBytes = $ms.ToArray()
        $ms.Dispose()
        $manifestSha = Get-Sha256Bytes $manifestBytes
        if ($manifestSha -cne $script:Frozen['Rc2ManifestSha256']) { throw "frozen RC2 manifest.json hash mismatch ($manifestSha)" }
        $json = (Get-Text $manifestBytes) | ConvertFrom-Json
        $map = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($entry in @($json.files)) { $map[[string]$entry.path] = [string]$entry.sha256 }
        $cordisBytes = $null
        $cordisEntry = $archive.GetEntry($script:Frozen['CordisRelPath'].Replace('/', '\'))
        if ($null -eq $cordisEntry) { $cordisEntry = $archive.GetEntry($script:Frozen['CordisRelPath']) }
        if ($null -ne $cordisEntry) {
            $ms2 = New-Object System.IO.MemoryStream
            $s2 = $cordisEntry.Open()
            try { $s2.CopyTo($ms2) } finally { $s2.Dispose() }
            $cordisBytes = $ms2.ToArray()
            $ms2.Dispose()
        }
        return [ordered]@{ Map = $map; ManifestSha256 = $manifestSha; CordisBytes = $cordisBytes }
    }
    finally { $archive.Dispose() }
}

function Read-Rc3Model([string]$Rc3ZipPath) {
    if (-not [System.IO.File]::Exists($Rc3ZipPath)) { throw "frozen RC3 ZIP not found: '$Rc3ZipPath'" }
    $bytes = (New-Object System.IO.FileInfo($Rc3ZipPath)).Length
    $sha = Get-Sha256File $Rc3ZipPath
    if ($bytes -ne $script:Frozen['Rc3ZipBytes'] -or $sha -cne $script:Frozen['Rc3ZipSha256']) {
        throw "frozen RC3 ZIP identity mismatch (bytes=$bytes sha=$sha)"
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Rc3ZipPath)
    try {
        $manifestEntry = $archive.GetEntry('manifest.json')
        if ($null -eq $manifestEntry) { throw 'frozen RC3 ZIP has no manifest.json' }
        $ms = New-Object System.IO.MemoryStream
        $s = $manifestEntry.Open()
        try { $s.CopyTo($ms) } finally { $s.Dispose() }
        $manifestBytes = $ms.ToArray()
        $ms.Dispose()
        $shaActual = Get-Sha256Bytes $manifestBytes
        if ($shaActual -cne $script:Frozen['Rc3ManifestSha256']) { throw "frozen RC3 manifest.json hash mismatch ($shaActual)" }
        $json = (Get-Text $manifestBytes) | ConvertFrom-Json
        $map = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($entry in @($json.files)) { $map[[string]$entry.path] = [string]$entry.sha256 }
        return [ordered]@{ Map = $map }
    }
    finally { $archive.Dispose() }
}

function Get-HotfixVariants([byte[]]$CordisRc2) {
    $needle = [System.Text.Encoding]::ASCII.GetBytes('suffix: Your working directory is {{cwd}}.')
    $hitIndexes = New-Object System.Collections.ArrayList
    for ($i = 0; $i -le $CordisRc2.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($CordisRc2[$i + $j] -ne $needle[$j]) { $match = $false; break }
        }
        if ($match) { [void]$hitIndexes.Add($i) }
    }
    if ($hitIndexes.Count -ne 1) { return $null }
    $suffixIdx = [int]($hitIndexes[0])
    $lineStart = $suffixIdx
    while ($lineStart -gt 0 -and $CordisRc2[$lineStart - 1] -ne 10) { $lineStart-- }
    $lineEnd = $suffixIdx
    while ($lineEnd -lt $CordisRc2.Length -and $CordisRc2[$lineEnd] -ne 10) { $lineEnd++ }
    $lineEnd = $lineEnd + 1
    $lineBytes = New-Object byte[] ($lineEnd - $lineStart)
    [Array]::Copy($CordisRc2, $lineStart, $lineBytes, 0, $lineBytes.Length)
    $textOnly = New-Object byte[] ($lineBytes.Length - 1)
    [Array]::Copy($lineBytes, 0, $textOnly, 0, $textOnly.Length)
    $lineRemoved = New-Object byte[] ($CordisRc2.Length - $lineBytes.Length)
    [Array]::Copy($CordisRc2, 0, $lineRemoved, 0, $lineStart)
    [Array]::Copy($CordisRc2, $lineEnd, $lineRemoved, $lineStart, $CordisRc2.Length - $lineEnd)
    $textRemoved = New-Object byte[] ($CordisRc2.Length - $textOnly.Length)
    [Array]::Copy($CordisRc2, 0, $textRemoved, 0, $lineStart)
    [Array]::Copy($CordisRc2, $lineStart + $textOnly.Length, $textRemoved, $lineStart, $CordisRc2.Length - ($lineStart + $textOnly.Length))
    return [ordered]@{
        LineRemovedSha = (Get-Sha256Bytes $lineRemoved)
        TextRemovedSha = (Get-Sha256Bytes $textRemoved)
    }
}

function Test-Manifest($Root) {
    $issues = New-Object System.Collections.ArrayList
    $result = [ordered]@{ Issues = $issues; Json = $null; Sha256 = ''; Bytes = [int64]0; Map = $null; Paths = @() }
    $path = [System.IO.Path]::Combine($Root, 'manifest.json')
    if (-not [System.IO.File]::Exists($path)) { [void]$issues.Add('manifest.json missing'); return $result }
    $raw = [System.IO.File]::ReadAllBytes($path)
    if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { [void]$issues.Add('manifest.json has a UTF-8 BOM') }
    $json = $null
    try { $json = (Get-Text $raw) | ConvertFrom-Json } catch { [void]$issues.Add("manifest.json is not valid JSON: $($_.Exception.Message)"); return $result }
    $result['Json'] = $json
    $result['Bytes'] = [int64]$raw.Length
    $result['Sha256'] = Get-Sha256Bytes $raw
    if ($json.schemaVersion -ne 1) { [void]$issues.Add('schemaVersion != 1') }
    if ([string]$json.distribution.version -cne $script:Frozen['Rc3Version']) { [void]$issues.Add('distribution.version != 1.0.0-rc.3') }
    if ([string]$json.distribution.variant -cne 'unified-installer') { [void]$issues.Add('distribution.variant != unified-installer') }
    if ($json.distribution.candidate -ne $true) { [void]$issues.Add('distribution.candidate != true') }
    if ([string]$json.bundle.version -cne $script:Frozen['CoreBundleVersion']) { [void]$issues.Add('bundle.version != 1.0.0') }
    if ([string]$json.install.entryPoint -cne 'tools/portable.ps1') { [void]$issues.Add('install.entryPoint != tools/portable.ps1') }
    if ([string]$json.install.setupEntryPoint -cne 'tools/setup.ps1') { [void]$issues.Add('install.setupEntryPoint != tools/setup.ps1') }
    if ($json.upgrade.schemaVersion -ne 2) { [void]$issues.Add('upgrade.schemaVersion != 2') }
    if ([string]$json.upgrade.data -cne $script:Frozen['MetadataRel']) { [void]$issues.Add('upgrade.data path mismatch') }
    if ([string]$json.upgrade.upgradeId -cne $script:Frozen['UpgradeId']) { [void]$issues.Add('upgrade.upgradeId mismatch') }
    if ([string]$json.upgrade.engine -cne 'tools/lib/UpgradeCommon.ps1') { [void]$issues.Add('upgrade.engine mismatch') }
    if ([string]$json.upgrade.setup -cne 'tools/setup.ps1') { [void]$issues.Add('upgrade.setup mismatch') }
    if ([string]$json.upgrade.sourceVersion -cne $script:Frozen['Rc2Version']) { [void]$issues.Add('upgrade.sourceVersion mismatch') }
    if ([string]$json.upgrade.targetVersion -cne $script:Frozen['Rc3Version']) { [void]$issues.Add('upgrade.targetVersion mismatch') }
    $states = @($json.upgrade.allowedSourceStates)
    if (-not ($states -contains 'RC2_CLEAN') -or -not ($states -contains 'RC2_HOTFIXED')) { [void]$issues.Add('upgrade.allowedSourceStates mismatch') }
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    $paths = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($json.files)) {
        $rel = [string]$entry.path
        $pathIssue = Get-SafePathIssue $rel
        if ($null -ne $pathIssue) { [void]$issues.Add("unsafe manifest path '$rel' ($pathIssue)"); continue }
        if (-not $seen.Add($rel)) { [void]$issues.Add("duplicate manifest path '$rel'") }
        if ($rel -ceq 'manifest.json' -or $rel -ceq $script:Frozen['SumsRel'] -or $rel -ceq $script:Frozen['MetadataRel'] -or $rel -ceq $script:Frozen['MetadataReadmeRel']) {
            [void]$issues.Add("manifest must not list package-only file '$rel'")
        }
        if ([string]$entry.sha256 -notmatch '^[0-9a-f]{64}$') { [void]$issues.Add("invalid sha256 for '$rel'") }
        $map[$rel] = [ordered]@{ sha256 = [string]$entry.sha256; bytes = [int64]$entry.bytes }
        [void]$paths.Add($rel)
        $full = [System.IO.Path]::Combine($Root, $rel.Replace('/', '\'))
        if (-not [System.IO.File]::Exists($full)) { [void]$issues.Add("manifest lists '$rel' but the file is missing"); continue }
        $actualBytes = (New-Object System.IO.FileInfo($full)).Length
        $actualSha = Get-Sha256File $full
        if ([int64]$entry.bytes -ne [int64]$actualBytes) { [void]$issues.Add("manifest bytes mismatch '$rel'") }
        if ([string]$entry.sha256 -cne $actualSha) { [void]$issues.Add("manifest sha256 mismatch '$rel'") }
    }
    $result['Map'] = $map
    $result['Paths'] = @($paths.ToArray())
    return $result
}

function Test-InternalSums($Root, $ManifestModel) {
    $issues = New-Object System.Collections.ArrayList
    $sumsPath = [System.IO.Path]::Combine($Root, 'SHA256SUMS.txt')
    if (-not [System.IO.File]::Exists($sumsPath)) { [void]$issues.Add('SHA256SUMS.txt missing'); return $issues }
    $raw = [System.IO.File]::ReadAllBytes($sumsPath)
    if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { [void]$issues.Add('SHA256SUMS.txt has a UTF-8 BOM') }
    $text = $null
    try { $text = Get-Text $raw } catch { [void]$issues.Add('SHA256SUMS.txt is not valid UTF-8'); return $issues }
    if ($text.Contains("`r")) { [void]$issues.Add('SHA256SUMS.txt contains CR bytes') }
    if (-not $text.EndsWith("`n")) { [void]$issues.Add('SHA256SUMS.txt lacks the final newline') }
    $lines = @($text.Split([char]"`n") | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -eq 0) { [void]$issues.Add('SHA256SUMS.txt is empty'); return $issues }
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    $listedPaths = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ($line -notmatch '^([0-9a-f]{64})  \*(.+)$') { [void]$issues.Add("invalid SHA256SUMS.txt line: '$line'"); continue }
        $sha = $Matches[1]
        $rel = $Matches[2]
        $pathIssue = Get-SafePathIssue $rel
        if ($null -ne $pathIssue) { [void]$issues.Add("unsafe SHA256SUMS.txt path '$rel' ($pathIssue)"); continue }
        if ($map.Contains($rel)) { [void]$issues.Add("SHA256SUMS.txt lists '$rel' more than once") }
        $map[$rel] = $sha
        [void]$listedPaths.Add($rel)
    }
    if ($map.Contains('SHA256SUMS.txt')) { [void]$issues.Add('SHA256SUMS.txt lists itself') }
    if (-not (Test-SortedOrdinal @($listedPaths.ToArray()))) { [void]$issues.Add('SHA256SUMS.txt entries are not sorted Ordinal by path') }
    $expected = New-Object System.Collections.ArrayList
    [void]$expected.Add('manifest.json')
    foreach ($p in $ManifestModel['Paths']) { [void]$expected.Add($p) }
    [void]$expected.Add($script:Frozen['MetadataRel'])
    [void]$expected.Add($script:Frozen['MetadataReadmeRel'])
    $expectedSorted = Sort-Ordinal @($expected.ToArray())
    $actualSorted = Sort-Ordinal @($map.Keys)
    if (-not (Test-StringSetEqual $expectedSorted $actualSorted)) {
        $onlySums = @($actualSorted | Where-Object { $expectedSorted -notcontains $_ })
        $onlyPkg = @($expectedSorted | Where-Object { $actualSorted -notcontains $_ })
        [void]$issues.Add("file set mismatch (sums-only=[$($onlySums -join ', ')] package-only=[$($onlyPkg -join ', ')])")
    }
    foreach ($rel in $actualSorted) {
        $full = [System.IO.Path]::Combine($Root, $rel.Replace('/', '\'))
        if (-not [System.IO.File]::Exists($full)) { [void]$issues.Add("SHA256SUMS.txt lists missing file '$rel'"); continue }
        if ([string]$map[$rel] -cne (Get-Sha256File $full)) { [void]$issues.Add("SHA256SUMS.txt hash mismatch '$rel'") }
    }
    foreach ($rel in (Get-RelativeFileSet $Root)) {
        if ($rel.EndsWith('/')) { continue }
        if ($rel -ceq 'SHA256SUMS.txt') { continue }
        if (-not $map.Contains($rel)) { [void]$issues.Add("unlisted package file '$rel'") }
    }
    return $issues
}

function Test-UpgradeData($Root, $ManifestModel, $Rc2Model) {
    $issues = New-Object System.Collections.ArrayList
    $metaPath = [System.IO.Path]::Combine($Root, $script:Frozen['MetadataRel'].Replace('/', '\'))
    if (-not [System.IO.File]::Exists($metaPath)) { [void]$issues.Add('upgrade-data/rc2-to-rc3.json missing'); return $issues }
    $raw = [System.IO.File]::ReadAllBytes($metaPath)
    if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { [void]$issues.Add('upgrade-data metadata has a UTF-8 BOM') }
    $json = $null
    try { $json = (Get-Text $raw) | ConvertFrom-Json } catch { [void]$issues.Add("upgrade-data is not valid JSON: $($_.Exception.Message)"); return $issues }
    $metaSha = Get-Sha256Bytes $raw
    $sumsPath = [System.IO.Path]::Combine($Root, 'SHA256SUMS.txt')
    $sumsText = Get-Text ([System.IO.File]::ReadAllBytes($sumsPath))
    if ($json.schemaVersion -ne 2) { [void]$issues.Add('U.schemaVersion != 2') }
    if ([string]$json.kind -cne $script:Frozen['MetadataKind']) { [void]$issues.Add('U.kind mismatch') }
    if ([string]$json.upgradeId -cne $script:Frozen['UpgradeId']) { [void]$issues.Add('U.upgradeId mismatch') }
    if ([string]$json.upgraderVersion -cne $script:Frozen['UpgraderVersion']) { [void]$issues.Add('U.upgraderVersion mismatch') }
    if ([string]$json.distributionId -cne $script:Frozen['DistributionId']) { [void]$issues.Add('U.distributionId mismatch') }
    if ([string]$json.sourceDistributionVersion -cne $script:Frozen['Rc2Version']) { [void]$issues.Add('U.sourceDistributionVersion mismatch') }
    if ([string]$json.targetDistributionVersion -cne $script:Frozen['Rc3Version']) { [void]$issues.Add('U.targetDistributionVersion mismatch') }
    if ([string]$json.payloadRoot -cne '.') { [void]$issues.Add('U.payloadRoot != .') }
    if ([string]$json.sourceManifestHash -cne $script:Frozen['Rc2ManifestSha256']) { [void]$issues.Add('U.sourceManifestHash mismatch') }
    if ([string]$json.sourcePackageHash -cne $script:Frozen['Rc2ZipSha256']) { [void]$issues.Add('U.sourcePackageHash mismatch') }
    if ([int64]$json.sourcePackageBytes -ne [int64]$script:Frozen['Rc2ZipBytes']) { [void]$issues.Add('U.sourcePackageBytes mismatch') }
    if ($null -ne $json.targetPackageHash -and [string]$json.targetPackageHash -ne '') { [void]$issues.Add('U.targetPackageHash must be null') }
    if ([int64]$json.distributionManifestSchemaVersion -ne 1) { [void]$issues.Add('U.distributionManifestSchemaVersion != 1') }
    if ([string]$json.targetManifestHash -cne [string]$ManifestModel['Sha256']) { [void]$issues.Add('U.targetManifestHash != sha256(manifest.json)') }
    $states = @($json.allowedSourceStates)
    if (-not ($states -contains 'RC2_CLEAN') -or -not ($states -contains 'RC2_HOTFIXED')) { [void]$issues.Add('U.allowedSourceStates mismatch') }
    if ([int64]$json.removedFileCount -ne 0) { [void]$issues.Add('U.removedFileCount != 0') }
    if ([int64]$json.payloadFileCount -ne [int64]@($ManifestModel['Paths']).Count) { [void]$issues.Add('U.payloadFileCount != manifest files count') }
    if ([int64]$json.sourcePayloadFileCount -ne [int64]@($json.expectedSourceHashes.PSObject.Properties).Count) { [void]$issues.Add('U.sourcePayloadFileCount != expectedSourceHashes count') }
    if ([int64]$json.sourcePayloadFileCount -ne [int64]$script:Frozen['SourcePayloadCount']) { [void]$issues.Add('U.sourcePayloadFileCount != 107') }
    $targetHashCount = @($json.expectedTargetHashes.PSObject.Properties).Count
    if ($targetHashCount -ne $ManifestModel['Map'].Count) { [void]$issues.Add("U.expectedTargetHashes count $targetHashCount != manifest count $($ManifestModel['Map'].Count)") }
    foreach ($rel in $ManifestModel['Map'].Keys) {
        $prop = $json.expectedTargetHashes.PSObject.Properties[$rel]
        if ($null -eq $prop) { [void]$issues.Add("U.expectedTargetHashes missing '$rel'"); continue }
        if ([string]$prop.Value -cne [string]$ManifestModel['Map'][$rel]['sha256']) { [void]$issues.Add("U.expectedTargetHashes mismatch '$rel'") }
    }
    foreach ($prop in @($json.expectedTargetHashes.PSObject.Properties)) {
        if (-not $ManifestModel['Map'].Contains([string]$prop.Name)) { [void]$issues.Add("U.expectedTargetHashes extra '$($prop.Name)'") }
    }
    if (@($json.expectedSourceHashes.PSObject.Properties).Count -ne $script:Frozen['SourcePayloadCount']) { [void]$issues.Add('U.expectedSourceHashes count != 107') }
    if ($null -ne $Rc2Model) {
        foreach ($prop in @($json.expectedSourceHashes.PSObject.Properties)) {
            if (-not $Rc2Model['Map'].Contains([string]$prop.Name)) { [void]$issues.Add("U.expectedSourceHashes unknown path '$($prop.Name)'"); continue }
            if ([string]$prop.Value -cne [string]$Rc2Model['Map'][[string]$prop.Name]) { [void]$issues.Add("U.expectedSourceHashes mismatch '$($prop.Name)'") }
        }
        foreach ($rel in $Rc2Model['Map'].Keys) {
            $prop = $json.expectedSourceHashes.PSObject.Properties[$rel]
            if ($null -eq $prop) { [void]$issues.Add("U.expectedSourceHashes missing RC2 path '$rel'") }
        }
    }
    $changed = @($json.changedFiles)
    if ([int64]$json.changedFileCount -ne $changed.Count) { [void]$issues.Add('U.changedFileCount != changedFiles count') }
    $cfPaths = @($changed | ForEach-Object { [string]$_.path })
    if (-not (Test-StringSetEqual (Sort-Ordinal $cfPaths) $cfPaths)) { [void]$issues.Add('U.changedFiles are not sorted by path') }
    $manifestPathList = @($ManifestModel['Paths'])
    $addCount = 0
    foreach ($cf in $changed) {
        $rel = [string]$cf.path
        if ($cf.PSObject.Properties.Name -contains 'hashSource') { [void]$issues.Add("U.changedFiles['$rel'] uses hashSource (not allowed in schemaVersion 2)") }
        if ([string]$cf.targetSha256 -notmatch '^[0-9a-f]{64}$') { [void]$issues.Add("U.changedFiles['$rel'] has no inline targetSha256") }
        if ($null -eq $cf.targetBytes) { [void]$issues.Add("U.changedFiles['$rel'] has no targetBytes") }
        if ([string]$cf.operation -eq 'add') {
            $addCount++
            if ($null -ne $cf.sourceSha256 -and [string]$cf.sourceSha256 -ne '') { [void]$issues.Add("U add entry '$rel' must have sourceSha256 null") }
            if ($null -ne $Rc2Model -and $Rc2Model['Map'].Contains($rel)) { [void]$issues.Add("U add entry '$rel' exists in the RC2 source") }
            if (-not ($manifestPathList -contains $rel)) { [void]$issues.Add("U add entry '$rel' is not a manifest payload file") }
        }
        elseif ([string]$cf.operation -eq 'replace') {
            if ($rel -cne 'manifest.json' -and $null -ne $Rc2Model -and -not $Rc2Model['Map'].Contains($rel)) { [void]$issues.Add("U replace entry '$rel' missing from the RC2 source") }
            if ($rel -ceq 'manifest.json') {
                if ([string]$cf.classification -cne 'distribution-metadata') { [void]$issues.Add('U manifest.json entry classification must be distribution-metadata') }
                if ([string]$cf.sourceSha256 -cne $script:Frozen['Rc2ManifestSha256']) { [void]$issues.Add('U manifest.json entry sourceSha256 mismatch') }
                if ([string]$cf.targetSha256 -cne [string]$ManifestModel['Sha256']) { [void]$issues.Add('U manifest.json entry targetSha256 mismatch') }
                if ([int64]$cf.targetBytes -ne [int64]$ManifestModel['Bytes']) { [void]$issues.Add('U manifest.json entry targetBytes mismatch') }
                continue
            }
        }
        else { [void]$issues.Add("U changedFiles['$rel'] invalid operation '$($cf.operation)'") }
        if ([string]$cf.classification -cne 'payload') { [void]$issues.Add("U changedFiles['$rel'] classification must be payload") }
        $prop = $json.expectedTargetHashes.PSObject.Properties[$rel]
        if ($null -ne $prop -and [string]$prop.Value -cne [string]$cf.targetSha256) { [void]$issues.Add("U changedFiles['$rel'] targetSha256 != expectedTargetHashes") }
        $full = [System.IO.Path]::Combine($Root, $rel.Replace('/', '\'))
        if ([System.IO.File]::Exists($full)) {
            if ([int64]$cf.targetBytes -ne (New-Object System.IO.FileInfo($full)).Length) { [void]$issues.Add("U changedFiles['$rel'] targetBytes != actual package size") }
            if ([string]$cf.targetSha256 -cne (Get-Sha256File $full)) { [void]$issues.Add("U changedFiles['$rel'] targetSha256 != actual package bytes") }
        }
        else { [void]$issues.Add("U changedFiles['$rel'] not found in the package") }
    }
    if ([int64]$json.addedFileCount -ne $addCount) { [void]$issues.Add("U.addedFileCount $($json.addedFileCount) != add entries $addCount") }
    if (-not ($cfPaths -contains 'manifest.json')) { [void]$issues.Add('U.changedFiles missing manifest.json entry') }
    if ($cfPaths -contains $script:Frozen['MetadataRel']) { [void]$issues.Add('U.changedFiles must not list the metadata file itself') }
    if ($null -ne $Rc2Model) {
        $computed = New-Object System.Collections.ArrayList
        foreach ($rel in $ManifestModel['Paths']) {
            if ($Rc2Model['Map'].Contains($rel)) {
                if ([string]$Rc2Model['Map'][$rel] -cne [string]$ManifestModel['Map'][$rel]['sha256']) { [void]$computed.Add($rel) }
            }
            else { [void]$computed.Add($rel) }
        }
        [void]$computed.Add('manifest.json')
        $computedSorted = Sort-Ordinal @($computed.ToArray())
        $declaredSorted = Sort-Ordinal $cfPaths
        if (-not (Test-StringSetEqual $computedSorted $declaredSorted)) {
            $missing = @($computedSorted | Where-Object { $declaredSorted -notcontains $_ })
            $extra = @($declaredSorted | Where-Object { $computedSorted -notcontains $_ })
            [void]$issues.Add("U.changedFiles set != (RC2->target diff + manifest.json): missing=[$($missing -join ', ')] extra=[$($extra -join ', ')]")
        }
    }
    $inlineMaterial = New-Object System.Text.StringBuilder
    foreach ($cf in $changed) {
        if ([string]$cf.classification -ne 'payload') { continue }
        $marker = 'ADD'
        if ($null -ne $cf.sourceSha256) { $marker = [string]$cf.sourceSha256 }
        [void]$inlineMaterial.Append([string]$cf.path + "`t" + $marker + "`t" + [string]$cf.targetSha256 + "`n")
    }
    if ((Get-Sha256Text $inlineMaterial.ToString()) -cne [string]$json.payloadSetHash) { [void]$issues.Add('U.payloadSetHash mismatch') }
    $setMaterial = New-Object System.Text.StringBuilder
    $sortedChanged = Sort-Ordinal @($changed | ForEach-Object { [string]$_.path })
    foreach ($rel in $sortedChanged) {
        $cf = $changed | Where-Object { [string]$_.path -ceq $rel } | Select-Object -First 1
        [void]$setMaterial.Append($rel + "`t" + [string]$cf.operation + "`n")
    }
    if ((Get-Sha256Text $setMaterial.ToString()) -cne [string]$json.changedFileSetHash) { [void]$issues.Add('U.changedFileSetHash mismatch') }
    $sourceMaterial = New-Object System.Text.StringBuilder
    foreach ($prop in @($json.expectedSourceHashes.PSObject.Properties)) { [void]$sourceMaterial.Append([string]$prop.Name + "`t" + [string]$prop.Value + "`n") }
    if ((Get-Sha256Text $sourceMaterial.ToString()) -cne [string]$json.sourcePayloadSetHash) { [void]$issues.Add('U.sourcePayloadSetHash mismatch') }
    $override = $json.hotfixedSourceOverrides.PSObject.Properties[$script:Frozen['CordisRelPath']]
    if ($null -eq $override) { [void]$issues.Add('U.hotfixedSourceOverrides missing cordis.patch.yml') }
    else {
        if ([string]$override.Value.HOTFIX_LINE_REMOVED -cne $script:Frozen['HotfixLineRemovedSha']) { [void]$issues.Add('U hotfix LINE hash mismatch') }
        if ([string]$override.Value.HOTFIX_TEXT_REMOVED -cne $script:Frozen['HotfixTextRemovedSha']) { [void]$issues.Add('U hotfix TEXT hash mismatch') }
    }
    if ($null -ne $Rc2Model -and $null -ne $Rc2Model['CordisBytes']) {
        $variants = Get-HotfixVariants ([byte[]]$Rc2Model['CordisBytes'])
        if ($null -eq $variants) { [void]$issues.Add('could not derive the hotfix variants from the frozen RC2 cordis bytes') }
        else {
            if ([string]$variants['LineRemovedSha'] -cne $script:Frozen['HotfixLineRemovedSha']) { [void]$issues.Add('derived HOTFIX_LINE_REMOVED hash mismatch') }
            if ([string]$variants['TextRemovedSha'] -cne $script:Frozen['HotfixTextRemovedSha']) { [void]$issues.Add('derived HOTFIX_TEXT_REMOVED hash mismatch') }
        }
    }
    $env = @($json.environmentFiles)
    if ($env.Count -ne 2) { [void]$issues.Add('U.environmentFiles count != 2') }
    else {
        if ([string]$env[0].path -cne '_portable/install-state.json') { [void]$issues.Add('U.environmentFiles[0] path mismatch') }
        if ([string]$env[1].path -cne 'bundle/cnki-research/portable.runtime.json') { [void]$issues.Add('U.environmentFiles[1] path mismatch') }
        if (@($env[1].addFields).Count -ne 2 -or [string]$env[1].addFields[0].value -cne '<now>') { [void]$issues.Add('U.environmentFiles runtime addFields mismatch') }
    }
    if (@($json.preservedDirectories).Count -lt 1) { [void]$issues.Add('U.preservedDirectories empty') }
    if ($json.rollbackMetadata.supported -ne $true) { [void]$issues.Add('U.rollbackMetadata.supported != true') }
    if ($json.rollbackMetadata.addedFilesDeleteOnRollback -ne $true) { [void]$issues.Add('U.rollbackMetadata.addedFilesDeleteOnRollback != true') }
    if ($json.rollbackMetadata.addedFilesDeleteOnlyIfTargetHashMatches -ne $true) { [void]$issues.Add('U.rollbackMetadata.addedFilesDeleteOnlyIfTargetHashMatches != true') }
    if ($json.rollbackMetadata.createdDirectoriesCleanup -ne $true) { [void]$issues.Add('U.rollbackMetadata.createdDirectoriesCleanup != true') }
    $forbiddenPaths = @($json.forbiddenPaths)
    if ($forbiddenPaths.Count -lt 1) { [void]$issues.Add('U.forbiddenPaths is empty') }
    foreach ($forbiddenPath in $forbiddenPaths) {
        if ([string]$forbiddenPath -match '(?<![A-Za-z0-9_])[A-Za-z]:[\\/]') { [void]$issues.Add("U.forbiddenPaths entry '$forbiddenPath' looks like an absolute drive path") }
    }
    if ([string]$json.minimumRequirements.os -cne 'Windows' -or [string]$json.minimumRequirements.powershell -cne '5.1') { [void]$issues.Add('U.minimumRequirements mismatch') }
    $tools = @($json.validation.toolNames)
    if ((($tools | Sort-Object) -join ',') -ne (($script:ToolNames | Sort-Object) -join ',')) { [void]$issues.Add('U.validation.toolNames mismatch') }
    if (-not (@($json.validation.mcpResources) -contains 'profile://list')) { [void]$issues.Add('U.validation.mcpResources missing profile://list') }
    if ([string]$json.validation.personaPrefix -cne $script:Frozen['PersonaPrefix']) { [void]$issues.Add('U.validation.personaPrefix mismatch') }
    if ([string]$json.validation.forbiddenCwdToken -cne $script:Frozen['ForbiddenCwdToken']) { [void]$issues.Add('U.validation.forbiddenCwdToken mismatch') }
    $requiredFiles = Sort-Ordinal @($json.validation.requiredFiles)
    if (-not (Test-StringSetEqual $requiredFiles (Sort-Ordinal $cfPaths))) { [void]$issues.Add('U.validation.requiredFiles != changedFiles paths') }
    $text = Get-Text $raw
    $sumsSha = Get-Sha256File $sumsPath
    if ($text.IndexOf($metaSha, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$issues.Add('U contains its own SHA-256 (self-cycle)') }
    if ($text.IndexOf($sumsSha, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$issues.Add('U contains the SHA256SUMS.txt hash (cycle)') }
    if ($null -ne $script:ZipInfo -and $text.IndexOf([string]$script:ZipInfo['Sha256'], [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$issues.Add('U contains the candidate ZIP hash') }
    if ($text -match '(?<![A-Za-z0-9_])[A-Za-z]:[\\/]') { [void]$issues.Add('U contains an absolute drive path') }
    if ($text.IndexOf('"hashSource"', [System.StringComparison]::Ordinal) -ge 0) { [void]$issues.Add('U contains a hashSource key') }
    if ($text.IndexOf('"targetSumsHash"', [System.StringComparison]::Ordinal) -ge 0) { [void]$issues.Add('U contains a targetSumsHash key') }
    $sumsMap = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($line in @($sumsText.Split([char]"`n") | Where-Object { $_.Length -gt 0 })) {
        if ($line -match '^([0-9a-f]{64})  \*(.+)$') { $sumsMap[$Matches[2]] = $Matches[1] }
    }
    if (-not $sumsMap.Contains('manifest.json') -or [string]$sumsMap['manifest.json'] -cne [string]$ManifestModel['Sha256']) { [void]$issues.Add('SHA256SUMS.txt does not authenticate manifest.json') }
    if (-not $sumsMap.Contains($script:Frozen['MetadataRel']) -or [string]$sumsMap[$script:Frozen['MetadataRel']] -cne $metaSha) { [void]$issues.Add('SHA256SUMS.txt does not authenticate the metadata file') }
    $script:ChangedFileCount = $changed.Count
    return $issues
}

function Test-FrozenCoreEquality($Root, $Rc3Model) {
    $issues = New-Object System.Collections.ArrayList
    if ($null -eq $Rc3Model) { return $issues }
    foreach ($rel in $Rc3Model['Map'].Keys) {
        $isCore = $false
        foreach ($p in $script:FrozenCoreFiles) { if ($p -ceq $rel) { $isCore = $true } }
        foreach ($p in $script:FrozenCorePrefixes) { if ($rel.StartsWith($p, [System.StringComparison]::Ordinal)) { $isCore = $true } }
        if (-not $isCore) { continue }
        $full = [System.IO.Path]::Combine($Root, $rel.Replace('/', '\'))
        if (-not [System.IO.File]::Exists($full)) { [void]$issues.Add("frozen-core file missing '$rel'"); continue }
        if ((Get-Sha256File $full) -cne [string]$Rc3Model['Map'][$rel]) { [void]$issues.Add("frozen-core file differs from frozen RC3 '$rel'") }
    }
    return $issues
}

# =============================================================================================
# Main
# =============================================================================================
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = (Get-Item -LiteralPath (Join-Path $scriptDir '..')).FullName
$repoParent = Split-Path -Parent $repoRoot
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

if ([string]::IsNullOrWhiteSpace($Zip)) {
    $candidates = @(
        (Join-Path $repoParent 'RELEASE_ASSETS_CANDIDATE\CNKI-Research-Portable-1.0.0-rc.3-unified-candidate.zip'),
        (Join-Path $repoRoot 'dist\CNKI-Research-Portable-1.0.0-rc.3-unified-candidate.zip')
    )
    foreach ($candidate in $candidates) { if ([System.IO.File]::Exists($candidate)) { $Zip = $candidate; break } }
    if ([string]::IsNullOrWhiteSpace($Zip)) { throw 'no candidate ZIP found; pass -Zip <path>' }
}
$Zip = Get-NormalizedPath $Zip
if (-not [System.IO.File]::Exists($Zip)) { throw "candidate ZIP not found: '$Zip'" }
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Join-Path $repoParent ('_verify\archive-run-' + $stamp) }
$WorkDir = Get-NormalizedPath $WorkDir
if ([string]::IsNullOrWhiteSpace($ReportDir)) { $ReportDir = $WorkDir }
$ReportDir = Get-NormalizedPath $ReportDir
Ensure-Directory $WorkDir
Ensure-Directory $ReportDir
$extractRoot = Join-Path $WorkDir 'extracted'
if ([System.IO.Directory]::Exists($extractRoot)) { [System.IO.Directory]::Delete($extractRoot, $true) }
Ensure-Directory $extractRoot

if (-not $Json) { Write-Host "Verifying unified candidate archive: $Zip" }

$script:ZipInfo = [ordered]@{ Path = $Zip; Bytes = [int64]0; Sha256 = '' }

# --- Z1 archive identity -----------------------------------------------------------------
$script:ZipInfo['Bytes'] = (New-Object System.IO.FileInfo($Zip)).Length
$script:ZipInfo['Sha256'] = Get-Sha256File $Zip
$sidecar = "$Zip.sha256"
if ([System.IO.File]::Exists($sidecar)) {
    $sidecarText = Get-Text ([System.IO.File]::ReadAllBytes($sidecar))
    $sidecarOk = $false
    if ($sidecarText -match '^([0-9a-f]{64})\s+\*(.+?)\s*$') {
        $recorded = $Matches[1]
        $recordedName = $Matches[2]
        $actualName = [System.IO.Path]::GetFileName($Zip)
        $sidecarOk = ($recorded -ceq $script:ZipInfo['Sha256']) -and ($recordedName -ceq $actualName)
        if ($sidecarOk) { Add-Check 'Z1.zipHash' 'PASS' "ZIP SHA-256 $($script:ZipInfo['Sha256']) matches $actualName.sha256" }
        else { Add-Check 'Z1.zipHash' 'FAIL' "sidecar mismatch: recorded=$recorded/$recordedName actual=$($script:ZipInfo['Sha256'])/$actualName" }
    }
    else { Add-Check 'Z1.zipHash' 'FAIL' 'sidecar is not in the "<sha256> *<zip name>" format' }
    if ($sidecarOk) { $script:ExternalAnchor = 'SIDECAR MATCHED' }
}
else {
    Add-Check 'Z1.zipHash' 'WARN' "no sidecar next to the archive ($sidecar): archive identity is not anchored beside the file"
}
if (-not [string]::IsNullOrWhiteSpace($ReleaseManifest)) {
    $ReleaseManifest = Get-NormalizedPath $ReleaseManifest
    if (-not [System.IO.File]::Exists($ReleaseManifest)) { Add-Check 'Z1.releaseManifest' 'FAIL' "release manifest not found: '$ReleaseManifest'" }
    else {
        $releaseJson = $null
        try { $releaseJson = Read-JsonText $ReleaseManifest } catch { $releaseJson = $null }
        if ($null -eq $releaseJson) { Add-Check 'Z1.releaseManifest' 'FAIL' 'external RELEASE_MANIFEST.json is not valid JSON' }
        else {
            $issues = New-Object System.Collections.ArrayList
            if ([string]$releaseJson.candidatePackage.zipSha256 -cne $script:ZipInfo['Sha256']) { [void]$issues.Add('zipSha256') }
            if ([int64]$releaseJson.candidatePackage.zipBytes -ne [int64]$script:ZipInfo['Bytes']) { [void]$issues.Add('zipBytes') }
            if ([string]$releaseJson.candidatePackage.zipName -cne [System.IO.Path]::GetFileName($Zip)) { [void]$issues.Add('zipName') }
            Assert-True ($issues.Count -eq 0) 'Z1.releaseManifest' `
                'external RELEASE_MANIFEST.json anchors the archive identity (name/bytes/sha256)' `
                ("external RELEASE_MANIFEST.json archive identity mismatch: " + ($issues -join ', '))
            if ($issues.Count -eq 0) { $script:ExternalAnchor = 'RELEASE_MANIFEST MATCHED' }
        }
    }
}

# --- Z2 archive structure ----------------------------------------------------------------
$structureIssues = New-Object System.Collections.ArrayList
$zipEntryFiles = New-Object System.Collections.Specialized.OrderedDictionary
$archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
try {
    $names = New-Object System.Collections.ArrayList
    foreach ($entry in $archive.Entries) {
        $raw = $entry.FullName
        if ($raw.EndsWith('/') -or $raw.EndsWith('\')) { [void]$structureIssues.Add("directory entry '$raw'"); continue }
        $name = $raw.Replace('\', '/')
        $pathIssue = Get-SafePathIssue $name
        if ($null -ne $pathIssue) { [void]$structureIssues.Add("unsafe entry '$name' ($pathIssue)") }
        if ($zipEntryFiles.Contains($name)) { [void]$structureIssues.Add("duplicate entry '$name'") }
        $ms = New-Object System.IO.MemoryStream
        $stream = $entry.Open()
        try { $stream.CopyTo($ms) } finally { $stream.Dispose() }
        $bytes = $ms.ToArray()
        $ms.Dispose()
        $zipEntryFiles[$name] = [ordered]@{ sha = (Get-Sha256Bytes $bytes); bytes = [int64]$bytes.Length }
        [void]$names.Add($name)
        $lt = $entry.LastWriteTime
        if (-not ($lt.Year -eq 1980 -and $lt.Month -eq 1 -and $lt.Day -eq 1 -and $lt.Hour -eq 0 -and $lt.Minute -eq 0 -and $lt.Second -eq 0)) { [void]$structureIssues.Add("timestamp not fixed for '$name'") }
        if ([int]($entry.ExternalAttributes) -ne 0) { [void]$structureIssues.Add("non-zero ExternalAttributes for '$name'") }
    }
    $sortedNames = Sort-Ordinal @($names.ToArray())
    if (-not (Test-StringSetEqual $sortedNames @($names.ToArray()))) { [void]$structureIssues.Add('entries are not sorted Ordinal') }
}
finally { $archive.Dispose() }
Assert-True ($structureIssues.Count -eq 0) 'Z2.zipStructure' `
    ("archive structure is clean: {0} file entries, no directory entries, no backslashes, forward-slash relative paths, sorted, fixed 1980 timestamps, ExternalAttributes=0" -f $zipEntryFiles.Count) `
    ("archive structure problems: " + ((@($structureIssues | Select-Object -First 10)) -join '; '))
if ($script:ZipInfo['Sha256'] -ceq $script:Frozen['Rc3ZipSha256']) { Add-Check 'Z1.newIdentity' 'FAIL' 'candidate ZIP reuses the frozen RC3 archive hash (must be a new identity)' }
else { Add-Check 'Z1.newIdentity' 'PASS' 'candidate ZIP has a new archive identity (not the frozen RC3 ZIP hash)' }

# --- Z3 extraction + entry set ------------------------------------------------------------
$extractOk = $false
$manifestModel = $null
try {
    $extractedMap = Extract-ZipSafe $Zip $extractRoot
    $extractOk = $true
    Add-Check 'Z3.extract' 'PASS' ("extracted {0} file(s) into a fresh directory" -f $extractedMap.Count)
}
catch {
    Add-Check 'Z3.extract' 'FAIL' "extraction failed: $($_.Exception.Message)"
}
if ($extractOk) {
    $extractedPaths = Sort-Ordinal @($extractedMap.Keys)
    $manifestPath = [System.IO.Path]::Combine($extractRoot, 'manifest.json')
    if (-not [System.IO.File]::Exists($manifestPath)) { Add-Check 'Z6.manifestIntegrity' 'FAIL' 'manifest.json is missing from the archive' }
    else {
        $manifestModel = Test-Manifest $extractRoot
        $manifestIssues = @($manifestModel['Issues'])
        Assert-True ($manifestIssues.Count -eq 0) 'Z6.manifestIntegrity' `
            ("manifest.json: schemaVersion 1, unified-installer identity, {0} payload files; every files[] entry matches the extracted bytes" -f @($manifestModel['Paths']).Count) `
            ("manifest.json problems: " + ($manifestIssues -join '; '))
        $script:PayloadFileCount = @($manifestModel['Paths']).Count
        $expectedEntries = New-Object System.Collections.ArrayList
        [void]$expectedEntries.Add('manifest.json')
        [void]$expectedEntries.Add('SHA256SUMS.txt')
        [void]$expectedEntries.Add($script:Frozen['MetadataRel'])
        [void]$expectedEntries.Add($script:Frozen['MetadataReadmeRel'])
        foreach ($p in $manifestModel['Paths']) { [void]$expectedEntries.Add($p) }
        $expectedSorted = Sort-Ordinal @($expectedEntries.ToArray())
        Assert-True (Test-StringSetEqual $expectedSorted $extractedPaths) 'Z3.entrySet' `
            ("entry set closure: {0} entries == {1} payload files + manifest.json + SHA256SUMS.txt + upgrade-data metadata" -f $extractedPaths.Count, @($manifestModel['Paths']).Count) `
            ("entry set mismatch: archive has {0} entries but the payload closure requires {1}" -f $extractedPaths.Count, $expectedSorted.Count)
        $missingEntryPoints = @($script:RequiredEntryPoints | Where-Object { -not ($extractedPaths -contains $_) })
        Assert-True ($missingEntryPoints.Count -eq 0) 'Z3.entryPoints' `
            ("all {0} required entry points are present after extraction" -f $script:RequiredEntryPoints.Count) `
            ("missing entry points after extraction: " + ($missingEntryPoints -join ', '))
        $docsDir = Join-Path $extractRoot 'docs'
        $docsMd = @()
        if ([System.IO.Directory]::Exists($docsDir)) { $docsMd = @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue) }
        Assert-True ($docsMd.Count -ge 6) 'Z3.docsPages' ("docs/*.md pages present: $($docsMd.Count)") ("docs/*.md pages: expected >= 6, found $($docsMd.Count)")
    }
}

# --- Z4 no leftovers / internal material --------------------------------------------------
if ($extractOk) {
    $leftoverIssues = New-Object System.Collections.ArrayList
    foreach ($rel in $extractedPaths) {
        $segments = $rel.Split([char]'/')
        foreach ($seg in $segments) {
            if ($script:ForbiddenDirNames -contains $seg) { [void]$leftoverIssues.Add("$rel (forbidden directory name '$seg')") }
        }
        $leaf = $segments[$segments.Count - 1]
        if ($script:ForbiddenArtifactNames -contains $leaf) { [void]$leftoverIssues.Add("$rel (forbidden artefact)") }
        foreach ($ext in $script:ForbiddenArtifactExts) { if ($leaf.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$leftoverIssues.Add("$rel (forbidden extension '$ext')") } }
        if ($leaf -match '^(?i)UNIFIED_.*\.md$') { [void]$leftoverIssues.Add("$rel (internal report file)") }
        $full = [System.IO.Path]::Combine($extractRoot, $rel.Replace('/', '\'))
        $bytes = [System.IO.File]::ReadAllBytes($full)
        try { [void]$script:Utf8Strict.GetString($bytes) } catch { [void]$leftoverIssues.Add("$rel (not valid UTF-8 text)") }
    }
    Assert-True ($leftoverIssues.Count -eq 0) 'Z4.noLeftovers' `
        'no runtime artefact, log, credential, payload/ dir, .git or internal material inside the archive' `
        ("forbidden content in the archive: " + (($leftoverIssues | Select-Object -First 8) -join '; '))
}

# --- Z5 internal sums closure -------------------------------------------------------------
if ($extractOk -and $null -ne $manifestModel) {
    $sumsIssues = @(Test-InternalSums $extractRoot $manifestModel)
    Assert-True ($sumsIssues.Count -eq 0) 'Z5.internalSums' `
        ("SHA256SUMS.txt closure: V1 format '<sha256>  *<path>', LF/UTF-8-no-BOM, sorted, covers manifest.json + upgrade-data/** + all {0} payload files, excludes itself" -f @($manifestModel['Paths']).Count) `
        ("SHA256SUMS.txt problems: " + ($sumsIssues -join '; '))
}

# --- Z7 upgrade-data consistency ----------------------------------------------------------
$rc2Model = $null
$rc3Model = $null
if (-not [string]::IsNullOrWhiteSpace($Rc2Zip)) {
    try { $rc2Model = Read-Rc2Model (Get-NormalizedPath $Rc2Zip); Add-Check 'Z7.rc2Source' 'PASS' "frozen RC2 ZIP identity verified ($($script:Frozen['Rc2ZipSha256'])) and its 107 payload hashes loaded" }
    catch { Add-Check 'Z7.rc2Source' 'FAIL' "frozen RC2 ZIP could not be loaded: $($_.Exception.Message)" }
}
else { Add-Check 'Z7.rc2Source' 'WARN' 'no -Rc2Zip supplied: expectedSourceHashes are checked for count/constants only (external source identity NOT SUPPLIED)' }
if (-not [string]::IsNullOrWhiteSpace($Rc3FrozenZip)) {
    try { $rc3Model = Read-Rc3Model (Get-NormalizedPath $Rc3FrozenZip); Add-Check 'Z7.rc3Oracle' 'PASS' "frozen RC3 ZIP identity verified ($($script:Frozen['Rc3ZipSha256'])); frozen-core equality will be checked" }
    catch { Add-Check 'Z7.rc3Oracle' 'FAIL' "frozen RC3 ZIP could not be loaded: $($_.Exception.Message)" }
}
else { Add-Check 'Z7.rc3Oracle' 'WARN' 'no -Rc3FrozenZip supplied: frozen-core equality vs RC3 is NOT CHECKED' }
if ($extractOk -and $null -ne $manifestModel) {
    $upgradeIssues = @(Test-UpgradeData $extractRoot $manifestModel $rc2Model)
    Assert-True ($upgradeIssues.Count -eq 0) 'Z7.upgradeData' `
        ("upgrade-data/rc2-to-rc3.json: schemaVersion 2, targetManifestHash == sha256(manifest.json), expectedTargetHashes == manifest.files, changedFiles/operations/added rules consistent, payloadSetHash recomputed, frozen RC2 anchors + hotfix variants verified, no self/cycle references ({0} changed files)" -f $script:ChangedFileCount) `
        ("upgrade-data problems: " + ($upgradeIssues -join '; '))
    if ($null -ne $rc3Model) {
        $coreIssues = @(Test-FrozenCoreEquality $extractRoot $rc3Model)
        Assert-True ($coreIssues.Count -eq 0) 'Z7.frozenCore' `
            'frozen-core files (bundle/**, upstream/**, LICENSE, THIRD-PARTY-NOTICES.md, docs/provenance/**, tools/portable.ps1, tools/lib/PortableCommon.ps1, tools/probe_mcp_stdio.py, docs/06, VERSION, js-yaml vendor) are byte-identical to frozen RC3; the Lead-approved docs/02 LEGACY clarification is an explicit allowed change' `
            ("frozen-core changes: " + ($coreIssues -join '; '))
    }
}

# --- Z8 static suites ---------------------------------------------------------------------
if ($extractOk) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) {
        Add-Check 'Z8.manifestCheck' 'NOT TESTED' 'node is unavailable: build_manifest --check not executed (never reported as PASS)'
        Add-Check 'Z8.staticSuite' 'NOT TESTED' 'node is unavailable: tests/test_static_package.mjs not executed (never reported as PASS)'
        Add-Check 'Z8.unifiedSuite' 'NOT TESTED' 'node is unavailable: tests/test_unified_package.mjs not executed (never reported as PASS)'
    }
    else {
        $gateDir = Join-Path $WorkDir 'static-gates'
        Ensure-Directory $gateDir
        $checkResult = Invoke-NodeJson @('tools\build_manifest.mjs', '--check') $extractRoot $null
        Assert-True ($checkResult['exit'] -eq 0) 'Z8.manifestCheck' `
            ("node tools/build_manifest.mjs --check PASS in the extracted archive: {0} payload file(s) current" -f $script:PayloadFileCount) `
            ("node tools/build_manifest.mjs --check FAILED (exit $($checkResult['exit'])): " + (($checkResult['output'] -split "`n" | Select-Object -Last 3) -join ' | '))
        $staticResult = Invoke-NodeJson @('tests\test_static_package.mjs', '--json') $extractRoot (Join-Path $gateDir 'static-report.json')
        $staticReport = $staticResult['report']
        if ($null -eq $staticReport) { Add-Check 'Z8.staticSuite' 'FAIL' ("tests/test_static_package.mjs produced no machine report (exit $($staticResult['exit'])): " + (($staticResult['output'] -split "`n" | Select-Object -Last 3) -join ' | ')) }
        else {
            $staticFails = @($staticReport.checks | Where-Object { $_.status -eq 'FAIL' })
            $staticPass = @($staticReport.checks | Where-Object { $_.status -eq 'PASS' }).Count
            Assert-True ($staticResult['exit'] -eq 0 -and $staticFails.Count -eq 0) 'Z8.staticSuite' `
                ("tests/test_static_package.mjs: {0} check(s) PASS, 0 FAIL on the extracted archive" -f $staticPass) `
                ("tests/test_static_package.mjs FAILED: " + (($staticFails | ForEach-Object { $_.id + ': ' + $_.detail }) -join '; '))
        }
        $unifiedResult = Invoke-NodeJson @('tests\test_unified_package.mjs', '--json', '--package-root', $extractRoot) $extractRoot (Join-Path $gateDir 'unified-report.json')
        $unifiedReport = $unifiedResult['report']
        if ($null -eq $unifiedReport) { Add-Check 'Z8.unifiedSuite' 'FAIL' ("tests/test_unified_package.mjs produced no machine report (exit $($unifiedResult['exit'])): " + (($unifiedResult['output'] -split "`n" | Select-Object -Last 3) -join ' | ')) }
        else {
            $unifiedFails = @($unifiedReport.checks | Where-Object { $_.status -eq 'FAIL' })
            $unifiedPass = @($unifiedReport.checks | Where-Object { $_.status -eq 'PASS' }).Count
            Assert-True ($unifiedResult['exit'] -eq 0 -and $unifiedFails.Count -eq 0) 'Z8.unifiedSuite' `
                ("tests/test_unified_package.mjs: {0} check(s) PASS, 0 FAIL (package hash graph re-derived from the extracted bytes)" -f $unifiedPass) `
                ("tests/test_unified_package.mjs FAILED: " + (($unifiedFails | ForEach-Object { $_.id + ': ' + $_.detail }) -join '; '))
        }
    }
}

# --- Z9 installer/engine read-only checks + tricky path -----------------------------------
function Invoke-InstallerJson([string]$ScriptPath, [string]$PackageRoot, [string]$InstallRoot, [string]$DshHome) {
    $result = @{ exit = -1; output = ''; json = $null }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath `
            -Action check -PackageRoot $PackageRoot -InstallRoot $InstallRoot -DshHome $DshHome -DshProfile probe -Json 2>&1 | Out-String
        $result['exit'] = $LASTEXITCODE
        $result['output'] = $out
    }
    finally { $ErrorActionPreference = $prevEap }
    try { $result['json'] = ($result['output'] | ConvertFrom-Json) } catch { $result['json'] = $null }
    return $result
}

if ($extractOk -and -not $SkipInstallerCheck) {
    $probeRoot = Join-Path $WorkDir 'probe'
    Ensure-Directory $probeRoot
    $probeHome = Join-Path $probeRoot 'dsh-home'
    Ensure-Directory $probeHome
    $emptyInstall = Join-Path $probeRoot 'empty-install-root'
    Ensure-Directory $emptyInstall
    $portable = Join-Path $extractRoot 'tools\portable.ps1'
    if (-not [System.IO.File]::Exists($portable)) { Add-Check 'Z9.installerCheck' 'FAIL' 'tools/portable.ps1 is missing from the archive' }
    else {
        $portableResult = Invoke-InstallerJson $portable $extractRoot $extractRoot $probeHome
        if ($null -eq $portableResult['json']) { Add-Check 'Z9.installerCheck' 'FAIL' 'portable.ps1 -Action check produced no JSON document' }
        else {
            $structuralFails = @($portableResult['json'].checks | Where-Object { $_.status -eq 'FAIL' -and ($_.id -like 'package.*' -or $_.id -like 'bundle.*' -or $_.id -like 'upstream.*') })
            Assert-True ($structuralFails.Count -eq 0) 'Z9.installerCheck' `
                ("portable.ps1 -Action check on the extracted archive: {0} PASS, 0 structural FAIL" -f @($portableResult['json'].checks | Where-Object { $_.status -eq 'PASS' }).Count) `
                ("portable.ps1 structural failures: " + (($structuralFails | ForEach-Object { $_.id }) -join ', '))
        }
    }
    $setup = Join-Path $extractRoot 'tools\setup.ps1'
    if (-not [System.IO.File]::Exists($setup)) { Add-Check 'Z9.setupCheck' 'NOT TESTED' 'tools/setup.ps1 is missing from the archive' }
    else {
        $before = Get-TreeFingerprint $extractRoot
        $setupResult = Invoke-InstallerJson $setup $extractRoot $emptyInstall $probeHome
        $after = Get-TreeFingerprint $extractRoot
        $writeIssues = @(Compare-Fingerprint $before $after)
        if ($null -eq $setupResult['json']) { Add-Check 'Z9.setupCheck' 'FAIL' ("setup.ps1 -Action check produced no JSON document (exit $($setupResult['exit'])): " + (($setupResult['output'] -split "`n" | Select-Object -Last 3) -join ' | ')) }
        else {
            $setupFails = @($setupResult['json'].checks | Where-Object { $_.status -eq 'FAIL' })
            $setupAllowedExit = ($setupResult['exit'] -eq 0) -or ($setupResult['exit'] -eq 2)
            $setupState = [string]$setupResult['json'].sourceState
            Assert-True ($setupAllowedExit) 'Z9.setupCheck.exit' `
                ("setup.ps1 -Action check exit code $($setupResult['exit']) is within the contract (0/2)") `
                ("setup.ps1 -Action check exit code $($setupResult['exit']) outside the contract (0/2)")
            Add-Check 'Z9.setupCheck' 'PASS' ("setup.ps1 -Action check parsed: sourceState='$setupState', {0} check(s), {1} FAIL (probe package root; no install performed)" -f @($setupResult['json'].checks).Count, $setupFails.Count)
        }
        Assert-True ($writeIssues.Count -eq 0) 'Z9.readOnly' `
            'setup.ps1 -Action check wrote nothing into the extracted package (tree fingerprint unchanged: paths+bytes+mtimes)' `
            ("read-only violation: " + (($writeIssues | Select-Object -First 10) -join '; '))
    }
}
elseif ($SkipInstallerCheck) { Add-Check 'Z9.installerEngineChecks' 'NOT TESTED' '-SkipInstallerCheck was passed' }

# --- Z9b closure re-check under a space + CJK path ----------------------------------------
if ($extractOk) {
    $trickyBase = Join-Path ([System.IO.Path]::GetTempPath()) ('cnki portable ' + [string][char]0x9A8C + [string][char]0x8BC1 + ' ' + [string][char]0x76EE + [string][char]0x5F55)
    $trickyRoot = Join-Path $trickyBase $stamp
    try {
        if ([System.IO.Directory]::Exists($trickyRoot)) { [System.IO.Directory]::Delete($trickyRoot, $true) }
        Ensure-Directory $trickyRoot
        [void](Extract-ZipSafe $Zip $trickyRoot)
        $trickyManifest = Test-Manifest $trickyRoot
        $trickyIssues = New-Object System.Collections.ArrayList
        foreach ($issue in @($trickyManifest['Issues'])) { [void]$trickyIssues.Add("manifest: $issue") }
        if (@($trickyManifest['Issues']).Count -eq 0) {
            foreach ($issue in @(Test-InternalSums $trickyRoot $trickyManifest)) { [void]$trickyIssues.Add("sums: $issue") }
            foreach ($issue in @(Test-UpgradeData $trickyRoot $trickyManifest $rc2Model)) { [void]$trickyIssues.Add("metadata: $issue") }
            if (-not (Test-StringSetEqual (Sort-Ordinal @((Get-RelativeFileSet $trickyRoot))) (Sort-Ordinal @($extractedMap.Keys)))) { [void]$trickyIssues.Add('file set differs after extraction under a space/CJK path') }
        }
        Assert-True ($trickyIssues.Count -eq 0) 'Z9.trickyPath' `
            ("the archive re-extracts and passes the manifest/SHA256SUMS/upgrade-data closure under a space+CJK path ('$trickyRoot')") `
            ("space/CJK path verification failed: " + (($trickyIssues | Select-Object -First 8) -join '; '))
    }
    catch { Add-Check 'Z9.trickyPath' 'FAIL' "could not verify under a space/CJK path: $($_.Exception.Message)" }
    finally {
        if (-not $KeepExtracted) { try { [System.IO.Directory]::Delete($trickyBase, $true) } catch { } }
    }
}

# =============================================================================================
# Report
# =============================================================================================
$fails = @($script:Checks | Where-Object { $_.status -eq 'FAIL' })
$warns = @($script:Checks | Where-Object { $_.status -eq 'WARN' })
$notTested = @($script:Checks | Where-Object { $_.status -eq 'NOT TESTED' })
$passes = @($script:Checks | Where-Object { $_.status -eq 'PASS' })

$metaPath = [System.IO.Path]::Combine($extractRoot, $script:Frozen['MetadataRel'].Replace('/', '\'))
$sumsPath = [System.IO.Path]::Combine($extractRoot, 'SHA256SUMS.txt')
$manifestPath = [System.IO.Path]::Combine($extractRoot, 'manifest.json')
$manifestSha = ''
$sumsSha = ''
$metaSha = ''
if ([System.IO.File]::Exists($manifestPath)) { $manifestSha = Get-Sha256File $manifestPath }
if ([System.IO.File]::Exists($sumsPath)) { $sumsSha = Get-Sha256File $sumsPath }
if ([System.IO.File]::Exists($metaPath)) { $metaSha = Get-Sha256File $metaPath }
$report = [ordered]@{
    suite              = 'release-zip-unified'
    verifier           = 'tools/verify_release_zip.ps1'
    verifierVersion    = '2.0.0'
    zip                = $Zip
    zipName            = [System.IO.Path]::GetFileName($Zip)
    zipBytes           = [int64]$script:ZipInfo['Bytes']
    zipSha256          = [string]$script:ZipInfo['Sha256']
    zipEntryCount      = [int64]$zipEntryFiles.Count
    payloadFileCount   = [int64]$script:PayloadFileCount
    manifestSha256     = $manifestSha
    internalSumsSha256 = $sumsSha
    upgradeDataSha256  = $metaSha
    changedFileCount   = [int64]$script:ChangedFileCount
    externalAnchor     = $script:ExternalAnchor
    frozenRc2ZipSha256 = $script:Frozen['Rc2ZipSha256']
    frozenRc3ZipSha256 = $script:Frozen['Rc3ZipSha256']
    runtimeActivation  = 'NOT TESTED'
    summary            = [ordered]@{
        pass      = $passes.Count
        warn      = $warns.Count
        fail      = $fails.Count
        notTested = $notTested.Count
    }
    ok                 = ($fails.Count -eq 0)
    checks             = @($script:Checks)
}
$reportPath = Join-Path $ReportDir 'archive-verification.json'
Write-TextFile $reportPath ((ConvertTo-Json $report -Depth 12) + "`n")

if ($Json) { Write-Output (ConvertTo-Json $report -Depth 12) }
else {
    Write-Host ''
    Write-Host "summary: $($passes.Count) PASS, $($warns.Count) WARN, $($fails.Count) FAIL, $($notTested.Count) NOT TESTED"
    Write-Host "report : $reportPath"
    if ($fails.Count -eq 0) { Write-Host '[PASS] the archive verifies as a unified RC3 candidate release' }
    else { Write-Host "[FAIL] $($fails.Count) problem(s) found" -ForegroundColor Red }
}
if ($fails.Count -gt 0) { exit 1 }
exit 0
