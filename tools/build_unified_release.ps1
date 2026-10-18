# Deterministic, reproducible build of the unified CNKI Research Portable RC3 candidate.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_unified_release.ps1 `
#     -Rc2Zip       <frozen RC2 ZIP> `
#     -Rc3FrozenZip <frozen RC3 ZIP> `
#     -Repo         <candidate repo root> `
#     -OutDir       <RELEASE_ASSETS_CANDIDATE>
#
# Build order (cycle-free by construction):
#   1. payload walk / frozen-core + change-set validation
#   2. node tools\build_manifest.mjs   -> manifest.json (distribution payload only)
#   3. compute sha256(manifest.json) and the target payload hashes
#   4. generate upgrade-data\rc2-to-rc3.json (package-only metadata, embeds sha256(M))
#   5. generate SHA256SUMS.txt over payload + manifest.json + upgrade-data/**
#   6. deterministic ZIP (sorted, forward slashes, fixed 1980 timestamps, no attr bits)
#   7. closure / cycle assertions + two-build byte equality
#   8. external release identity into -OutDir (sidecar, release SHA256SUMS.txt,
#      RELEASE_MANIFEST.json, DEPLOYMENT_README_release.md) - never inside the ZIP
#
# Modes: -NoZip (data artifacts only), -VerifyOnly (no writes to the repo; re-derive
# everything and compare to existing artifacts), -ReproCheck (two full clean builds and
# byte-equality proof), -SkipNode (test-only; manifest.json must already exist).
# Exit codes: 0 success / 2 build-validation failure / 1 tool or internal error.
#
# Windows PowerShell 5.1 only. No network, no Node/Python/Git requirement at install
# time: node is only used here to generate manifest.json. Frozen inputs are read-only.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Rc2Zip,
    [Parameter(Mandatory = $true)][string]$Rc3FrozenZip,
    [string]$Repo = '',
    [string]$OutDir = '',
    [string]$WorkDir = '',
    [string]$DistDir = '',
    [string]$EvidenceDir = '',
    [string]$Zip = '',
    [string]$ExpectedChangeSet = '',
    [switch]$VerifyOnly,
    [switch]$NoZip,
    [switch]$ReproCheck,
    [switch]$SkipNode,
    [switch]$RequireComplete,
    [switch]$RunStaticGate,
    [switch]$CleanCloneCheck,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# =============================================================================================
# 0. Assemblies + script-wide state + frozen constants
# =============================================================================================
try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
}
catch {
    Write-Host "FATAL: required .NET compression assemblies are unavailable: $($_.Exception.Message)"
    exit 1
}

$script:StartedAtUtc = (Get-Date).ToUniversalTime()
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Ordinal = [System.StringComparer]::Ordinal
$script:OrdinalIgnoreCase = [System.StringComparer]::OrdinalIgnoreCase
$script:ScriptPath = $PSCommandPath
$script:Report = $null
$script:ReportPath = $null
$script:Failures = New-Object System.Collections.ArrayList
$script:ExitCode = 1
$script:Checks = New-Object System.Collections.ArrayList
$script:Identity = $null
$script:StaticGateStatus = 'NOT TESTED'
$script:CleanCloneStatus = 'NOT TESTED'
$script:ZipVsRepoStatus = 'NOT TESTED'

# Frozen identities (single source of truth; never edit).
$script:Frozen = [ordered]@{
    Rc2ZipBytes              = 388236
    Rc2ZipSha256             = '4f279f359a42e5e950cd9f66e04f0922c5e40ec4c77f9192e2168274ce1142b5'
    Rc3ZipBytes              = 395232
    Rc3ZipSha256             = 'f4e914d135eb51b8d3afbd96e7fca53997a06e0ed1a75a28cca9386c3cc7f5fd'
    Rc2ManifestSha256        = '80229318a1ef070f5cedafda39785be0cbb49ee727f7a620e7e6aab5113a6e1f'
    Rc3ManifestSha256        = '98c8bca2bd34f0eda0e1d9fb1d0c6f38e60c8c4e92990efcb1c3be507f99a5e2'
    Rc2Version               = '1.0.0-rc.2'
    Rc3Version               = '1.0.0-rc.3'
    CoreBundleVersion        = '1.0.0'
    Rc2VersionSha256         = '0c654c00f94741d78169de333d4d9e866be0667b41f9c54cafe3c6b700b15a43'
    Rc3VersionSha256         = 'd458c8db8288a8a159c5b25dbea651430713bd1417c213dd83048058fe5fe228'
    CordisRelPath            = 'bundle/cnki-research/cordis.patch.yml'
    CordisRc2Bytes           = 16762
    CordisRc2Sha256          = 'afa6ffdd0684fe0440a5e3d2414c08fe36be946e64c19648c48b3770f68bf343'
    CordisRc3Bytes           = 16705
    CordisRc3Sha256          = 'edda8817e0bf449d8324f4875b1c7acd37a8dc693c3a82d044f4a5c436421778'
    HotfixLineRemovedSha     = 'edda8817e0bf449d8324f4875b1c7acd37a8dc693c3a82d044f4a5c436421778'
    HotfixTextRemovedSha     = 'b5aaa79ebb7a0c1bdd6f253e6462b0c1ee3db8f4f34cf15e83e0a59a37e4c0a9'
    HotfixLineBytes          = 57
    HotfixTextBytes          = 56
    SourcePayloadFileCount   = 107
    ExpectedPayloadCountFull = 115
    ExpectedAddCountFull     = 8
    UpgradeId                = 'cnki-portable-1.0.0-rc.2-to-1.0.0-rc.3-unified'
    UpgraderVersion          = '2.0.0'
    DistributionId           = 'cnki-research-portable-unified-1.0.0-rc.3'
    MetadataKind             = 'cnki-research-portable-unified-upgrade'
    CreatedUtc               = '2026-10-18T00:00:00Z'
    MetadataRel              = 'upgrade-data/rc2-to-rc3.json'
    MetadataReadmeRel        = 'upgrade-data/README.md'
    ZipName                  = 'CNKI-Research-Portable-1.0.0-rc.3-unified-candidate.zip'
    ReleaseDocName           = 'DEPLOYMENT_README_release.md'
    ReleaseManifestName      = 'RELEASE_MANIFEST.json'
    ExternalSumsName         = 'SHA256SUMS.txt'
    BundlePackageJsonRel     = 'bundle/cnki-research/package.json'
    FreeBytesFormula         = 'max(52428800, 4*sumChangedBytes + 8388608)'
    PersonaPrefix            = 'You are a coding agent powered by the {{model}} model.'
    ForbiddenCwdToken        = '{{cwd}}'
    TmpNamePrefix            = 'cnki-portable-unified-'
}

$script:ToolNames = @(
    'easy-search',
    'advanced-search',
    'get-info-from-url',
    'get-info-by-detail',
    'list-journal',
    'search-issn',
    'login',
    'logout'
)

# Payload files this round is expected to add on top of the frozen RC3 payload set.
$script:ExpectedNewPayloadFiles = @(
    'tools/setup.ps1',
    'tools/lib/UpgradeCommon.ps1',
    'tools/build_unified_release.ps1',
    'tests/Test-UnifiedMatrix.ps1',
    'tests/lib/UnifiedFixtures.ps1',
    'tests/lib/UnifiedAssert.ps1',
    'tests/Test-UnifiedVerification.ps1',
    'tests/test_unified_package.mjs'
)

# Files an approved unified round may modify relative to the frozen RC3 payload set.
# Every other frozen-RC3 payload file must stay byte-identical (core equality).
$script:AllowedChangedFiles = @(
    'README.md', 'README_EN.md', 'CHANGELOG.md', 'INSTALL_PROMPT.md', 'START_HERE.md', 'DEPLOYMENT_README.md',
    'tools/build_manifest.mjs', 'tools/package_release.ps1', 'tools/verify_release_zip.ps1',
    'tools/build_release_manifest.mjs',
    'tests/test_static_package.mjs', 'tests/run_all.ps1', 'tests/test_dsh_isolated.ps1'
)
$script:AllowedChangedPrefixes = @('docs/01-', 'docs/02-', 'docs/03-', 'docs/04-', 'docs/05-')

# Frozen-core predicates: these files must equal the frozen RC3 bytes exactly.
$script:FrozenCoreFiles = @(
    'LICENSE', 'THIRD-PARTY-NOTICES.md', 'VERSION', '.gitignore',
    'tools/portable.ps1', 'tools/lib/PortableCommon.ps1', 'tools/probe_mcp_stdio.py'
)
$script:FrozenCorePrefixes = @('bundle/', 'upstream/', 'docs/provenance/', 'tools/vendor/', 'docs/06-')

$script:ExcludedDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($d in @('_scratch', 'dist', '_portable', 'node_modules', '__pycache__', '.venv', '.git', 'test-evidence', 'upgrade-data')) {
    [void]$script:ExcludedDirs.Add($d)
}
$script:ExcludedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($f in @('manifest.json', '.DS_Store', 'Thumbs.db', 'portable.runtime.json', 'RELEASE_MANIFEST.json', 'SHA256SUMS.txt')) {
    [void]$script:ExcludedFiles.Add($f)
}

$script:PackageMetadataExpected = @($script:Frozen['MetadataRel'], $script:Frozen['MetadataReadmeRel'])
$script:InternalDirNames = @('_AUDIT', '_SPEC', '_evidence', '_build', '_verify', 'sandbox', 'dist', '_staging')
$script:ProductionFileNames = @('cookies.json', 'storage_state.json', '.credentials.yaml', 'portable.runtime.json')
# Development-machine markers that must never appear in shipped payload. The generic
# markers are split into fragments on purpose: this builder script is itself a payload
# file, so it must not contain the markers it scans for.
$script:DevPathMarkers = @(
    ('F:' + '\DSH'),
    ('F:' + '/DSH'),
    ('F:' + '\cnki-mcp'),
    ('cnki-' + 'mcp Mode'),
    ('D:' + '\DeepSeekHarness'),
    ('.dsh-' + 'cnki-profile')
)

# A real developer account name is never baked into shipped sources. It is matched
# only when a maintainer injects it for the current process, the same convention as
# tests/test_static_package.mjs. When unset, only the generic markers above apply.
$script:InjectedAccountMarker = $env:CNKI_ACCOUNT_MARKER
if (-not [string]::IsNullOrEmpty($script:InjectedAccountMarker)) {
    $script:DevPathMarkers += $script:InjectedAccountMarker.Trim()
}

# =============================================================================================
# 1. Generic helpers
# =============================================================================================
function Fail([string]$Message) {
    [void]$script:Failures.Add($Message)
    throw (New-Object System.Exception("BUILD_VALIDATION_FAILED: $Message"))
}

function Test-BytesEqual([byte[]]$A, [byte[]]$B) {
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) {
        if ($A[$i] -ne $B[$i]) { return $false }
    }
    return $true
}

function ConvertTo-HexString([byte[]]$Bytes) {
    $sb = New-Object System.Text.StringBuilder ($Bytes.Length * 2)
    foreach ($b in $Bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-HexString $sha.ComputeHash($Bytes)) }
    finally { $sha.Dispose() }
}

function Get-Sha256Text([string]$Text) {
    return (Get-Sha256Bytes ($script:Utf8NoBom.GetBytes($Text)))
}

function Get-Sha256File([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { return (ConvertTo-HexString $sha.ComputeHash($fs)) }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Resolve-FullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { Fail 'a required path argument is empty' }
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Remove-TrailingSeparator([string]$Path) {
    $p = $Path
    while ($p.Length -gt 3 -and ($p.EndsWith('\') -or $p.EndsWith('/'))) { $p = $p.Substring(0, $p.Length - 1) }
    return $p
}

function Get-NormalizedPath([string]$Path) {
    return (Remove-TrailingSeparator (Resolve-FullPath $Path))
}

function Test-PathUnder([string]$Child, [string]$Parent) {
    if ([string]::IsNullOrEmpty($Child) -or [string]::IsNullOrEmpty($Parent)) { return $false }
    $c = Get-NormalizedPath $Child
    $p = Get-NormalizedPath $Parent
    if ([string]::Equals($c, $p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Ensure-ParentDirectory([string]$FilePath) {
    $dir = [System.IO.Path]::GetDirectoryName($FilePath)
    if (-not [string]::IsNullOrEmpty($dir) -and -not [System.IO.Directory]::Exists($dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
}

function Ensure-Directory([string]$Path) {
    if (-not [System.IO.Directory]::Exists($Path)) { [void][System.IO.Directory]::CreateDirectory($Path) }
}

function Write-TextFile([string]$Path, [string]$Text) {
    Ensure-ParentDirectory $Path
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Remove-DirectorySafe([string]$Path, [string]$AllowedRoot) {
    $p = Get-NormalizedPath $Path
    $root = Get-NormalizedPath $AllowedRoot
    if (-not (Test-PathUnder $p $root)) { Fail "refusing to delete directory '$p': it is not under the expected root '$root'" }
    if ([string]::Equals($p, $root, [System.StringComparison]::OrdinalIgnoreCase)) { Fail "refusing to delete the allowed root directory itself: '$p'" }
    if (-not [System.IO.Directory]::Exists($p)) { return }
    $attrs = [System.IO.File]::GetAttributes($p)
    if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "refusing recursive delete of reparse point '$p' (junction-safe policy)"
    }
    try {
        [System.IO.Directory]::Delete($p, $true)
    }
    catch [System.UnauthorizedAccessException] {
        # A clean git clone contains read-only object files. Clear the read-only
        # attribute on regular files (never touching reparse points) and retry once.
        foreach ($file in [System.IO.Directory]::GetFiles($p, '*', [System.IO.SearchOption]::AllDirectories)) {
            try {
                $fileAttrs = [System.IO.File]::GetAttributes($file)
                if (($fileAttrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if (($fileAttrs -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                    [System.IO.File]::SetAttributes($file, ($fileAttrs -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
                }
            }
            catch { }
        }
        [System.IO.Directory]::Delete($p, $true)
    }
}

function Reset-Directory([string]$Path, [string]$AllowedRoot) {
    if ([System.IO.Directory]::Exists($Path)) { Remove-DirectorySafe $Path $AllowedRoot }
    Ensure-Directory $Path
}

function Add-Validation([string]$Id, [string]$Status, [string]$Detail) {
    $entry = [ordered]@{ id = $Id; status = $Status; detail = $Detail }
    [void]$script:Checks.Add($entry)
    if ($null -ne $script:Report) {
        [void]$script:Report['validations'].Add($entry)
    }
    $line = "[$Status] $Id - $Detail"
    switch ($Status) {
        'PASS' { Write-Host $line }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Red }
    }
}

function Assert-Condition([bool]$Condition, [string]$Id, [string]$PassDetail, [string]$FailDetail) {
    if ($Condition) {
        Add-Validation $Id 'PASS' $PassDetail
    }
    else {
        Add-Validation $Id 'FAIL' $FailDetail
        Fail "[$Id] $FailDetail"
    }
}

# Soft assertion: a FAIL only in a -RequireComplete (authoritative) build; WARN otherwise.
# Intermediate builds run while product files are still being written by their owners, so
# transient authoring defects must not abort the integration build.
function Assert-ConditionSoft([bool]$Condition, [string]$Id, [string]$PassDetail, [string]$FailDetail) {
    if ($Condition) {
        Add-Validation $Id 'PASS' $PassDetail
    }
    elseif ($RequireComplete) {
        Add-Validation $Id 'FAIL' $FailDetail
        Fail "[$Id] $FailDetail"
    }
    else {
        Add-Validation $Id 'WARN' ($FailDetail + ' (intermediate build: not enforced; re-run with -RequireComplete for the authoritative build)')
    }
}

function Test-StringArrayEqual([string[]]$A, [string[]]$B) {
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    if ($A.Count -ne $B.Count) { return $false }
    for ($i = 0; $i -lt $A.Count; $i++) {
        if (-not [string]::Equals($A[$i], $B[$i], [System.StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Sort-Ordinal([string[]]$Items) {
    $copy = [string[]]@($Items)
    [Array]::Sort($copy, $script:Ordinal)
    return $copy
}

function Get-Utf8TextFromBytes([byte[]]$Bytes) {
    $offset = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $offset = 3 }
    try { return $script:Utf8Strict.GetString($Bytes, $offset, $Bytes.Length - $offset) }
    catch { Fail "file content is not valid UTF-8: $($_.Exception.Message)" }
}

function Assert-SafeRelativePath([string]$Path, [string]$Context) {
    if ([string]::IsNullOrEmpty($Path)) { Fail "$Context`: empty relative path" }
    if ($Path.Length -gt 4096) { Fail "$Context`: path too long ($($Path.Length) chars)" }
    if ($Path.StartsWith('/') -or $Path.StartsWith('\')) { Fail "$Context`: rooted path '$Path'" }
    if ($Path -match '^[A-Za-z]:') { Fail "$Context`: drive-rooted path '$Path'" }
    if ($Path.Contains(':')) { Fail "$Context`: colon in path (drive/ADS/device form) '$Path'" }
    if ($Path -match '[\x00-\x1f]') { Fail "$Context`: control character in path '$Path'" }
    if ($Path.EndsWith(' ') -or $Path.EndsWith('.')) { Fail "$Context`: trailing space/dot path '$Path'" }
    $segments = $Path.Split([char]'/')
    foreach ($seg in $segments) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') { Fail "$Context`: unsafe path segment '$seg' in '$Path'" }
        if ($seg -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { Fail "$Context`: reserved device name segment '$seg' in '$Path'" }
    }
}

# =============================================================================================
# 2. Deterministic JSON serializer (UTF-8-safe, 2-space, LF, ordinal keys, no timestamps)
# =============================================================================================
function ConvertTo-JsonStringLiteral([string]$Value) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        switch ($code) {
            8 { [void]$sb.Append('\b'); break }
            9 { [void]$sb.Append('\t'); break }
            10 { [void]$sb.Append('\n'); break }
            12 { [void]$sb.Append('\f'); break }
            13 { [void]$sb.Append('\r'); break }
            34 { [void]$sb.Append('\"'); break }
            92 { [void]$sb.Append('\\'); break }
            default {
                if ($code -lt 32 -or $code -gt 126) {
                    [void]$sb.Append('\u')
                    [void]$sb.Append($code.ToString('x4'))
                }
                else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Add-JsonValue([System.Text.StringBuilder]$Sb, $Value, [int]$Indent) {
    $pad = ' ' * ($Indent * 2)
    $padIn = ' ' * (($Indent + 1) * 2)
    if ($null -eq $Value) { [void]$Sb.Append('null'); return }
    if ($Value -is [bool]) {
        if ($Value) { [void]$Sb.Append('true') } else { [void]$Sb.Append('false') }
        return
    }
    if ($Value -is [string]) { [void]$Sb.Append((ConvertTo-JsonStringLiteral $Value)); return }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @()
        if ($Value -is [System.Collections.Specialized.OrderedDictionary]) { $keys = @($Value.Keys) }
        else {
            $keys = @($Value.Keys)
            [Array]::Sort($keys, $script:Ordinal)
        }
        if ($keys.Count -eq 0) { [void]$Sb.Append('{}'); return }
        [void]$Sb.Append("{`n")
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $k = [string]$keys[$i]
            [void]$Sb.Append($padIn)
            [void]$Sb.Append((ConvertTo-JsonStringLiteral $k))
            [void]$Sb.Append(': ')
            Add-JsonValue $Sb $Value[$k] ($Indent + 1)
            if ($i -lt $keys.Count - 1) { [void]$Sb.Append(',') }
            [void]$Sb.Append("`n")
        }
        [void]$Sb.Append($pad)
        [void]$Sb.Append('}')
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { [void]$Sb.Append('[]'); return }
        [void]$Sb.Append("[`n")
        for ($i = 0; $i -lt $items.Count; $i++) {
            [void]$Sb.Append($padIn)
            Add-JsonValue $Sb $items[$i] ($Indent + 1)
            if ($i -lt $items.Count - 1) { [void]$Sb.Append(',') }
            [void]$Sb.Append("`n")
        }
        [void]$Sb.Append($pad)
        [void]$Sb.Append(']')
        return
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [int64] -or $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64]) {
        [void]$Sb.Append([System.Convert]::ToString($Value, $script:Invariant))
        return
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        [void]$Sb.Append(([System.Convert]::ToDouble($Value, $script:Invariant)).ToString('R', $script:Invariant))
        return
    }
    Fail "JSON serializer: unsupported value type '$($Value.GetType().FullName)'"
}

function ConvertTo-DeterministicJson($Value) {
    $sb = New-Object System.Text.StringBuilder
    Add-JsonValue $sb $Value 0
    return $sb.ToString()
}

function Write-JsonFile([string]$Path, $Value) {
    $text = (ConvertTo-DeterministicJson $Value) + "`n"
    Write-TextFile $Path $text
}

# =============================================================================================
# 3. ZIP reading / extraction / deterministic writing + verification
# =============================================================================================
function Get-ZipSnapshot([string]$ZipPath, [string]$Label) {
    $snap = [ordered]@{
        Label      = $Label
        ZipPath    = $ZipPath
        EntryCount = 0
        DirEntries = New-Object System.Collections.ArrayList
        Files      = New-Object System.Collections.Specialized.OrderedDictionary
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $snap['EntryCount'] = $archive.Entries.Count
        foreach ($entry in $archive.Entries) {
            $raw = $entry.FullName
            $isDir = $false
            if ($raw.EndsWith('\') -or $raw.EndsWith('/')) { $isDir = $true }
            $name = $raw.Replace('\', '/')
            if ($name.EndsWith('/')) { $name = $name.TrimEnd('/') }
            Assert-SafeRelativePath $name "$Label zip entry"
            if ($isDir) {
                [void]$snap['DirEntries'].Add($name)
                continue
            }
            if ($snap['Files'].Contains($name)) { Fail "$Label`: duplicate zip entry '$name'" }
            $ms = New-Object System.IO.MemoryStream
            $stream = $entry.Open()
            try { $stream.CopyTo($ms) } finally { $stream.Dispose() }
            $bytes = $ms.ToArray()
            $ms.Dispose()
            $snap['Files'][$name] = [ordered]@{
                sha   = (Get-Sha256Bytes $bytes)
                bytes = [int64]($bytes.Length)
                data  = $bytes
            }
        }
    }
    finally { $archive.Dispose() }
    return $snap
}

function Read-ProducedZip([string]$ZipPath, [string]$Label) {
    $result = [ordered]@{
        Path       = $ZipPath
        Bytes      = [int64]0
        Sha256     = ''
        EntryCount = 0
        Files      = New-Object System.Collections.Specialized.OrderedDictionary
    }
    $info = New-Object System.IO.FileInfo($ZipPath)
    $result['Bytes'] = [int64]($info.Length)
    $result['Sha256'] = Get-Sha256File $ZipPath
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $result['EntryCount'] = $archive.Entries.Count
        $timesOk = $true
        $attrIssues = New-Object System.Collections.ArrayList
        foreach ($entry in $archive.Entries) {
            $raw = $entry.FullName
            if ($raw.EndsWith('/') -or $raw.EndsWith('\')) { Fail "$Label`: produced zip contains a directory entry '$raw' (entries must be files only)" }
            if ($raw.Contains('\')) { Fail "$Label`: produced zip entry uses a backslash separator: '$raw'" }
            Assert-SafeRelativePath $raw "$Label produced zip entry"
            if ($result['Files'].Contains($raw)) { Fail "$Label`: produced zip contains duplicate entry '$raw'" }
            $ms = New-Object System.IO.MemoryStream
            $stream = $entry.Open()
            try { $stream.CopyTo($ms) } finally { $stream.Dispose() }
            $bytes = $ms.ToArray()
            $ms.Dispose()
            $result['Files'][$raw] = [ordered]@{ sha = (Get-Sha256Bytes $bytes); bytes = [int64]($bytes.Length) }
            $lt = $entry.LastWriteTime
            if (-not ($lt.Year -eq 1980 -and $lt.Month -eq 1 -and $lt.Day -eq 1 -and $lt.Hour -eq 0 -and $lt.Minute -eq 0 -and $lt.Second -eq 0)) { $timesOk = $false }
            if ([int]($entry.ExternalAttributes) -ne 0) { [void]$attrIssues.Add($raw) }
        }
        Assert-Condition $timesOk "$Label.zip.timestamps" `
            'every zip entry carries the fixed 1980-01-01T00:00:00 DOS timestamp' `
            'at least one zip entry does not carry the fixed 1980-01-01T00:00:00 timestamp'
        Assert-Condition ($attrIssues.Count -eq 0) "$Label.zip.externalAttributes" `
            'every zip entry has ExternalAttributes=0 (no DOS/Unix link or attribute bits)' `
            "zip entries carry non-zero ExternalAttributes: $(@($attrIssues) -join ',')"
    }
    finally { $archive.Dispose() }
    return $result
}

function New-DeterministicZipFile([string]$OutFile, [string]$PackageDir, [string[]]$RelPaths) {
    Ensure-ParentDirectory $OutFile
    $fixedTime = [System.DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
    $fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($rel in $RelPaths) {
                Assert-SafeRelativePath $rel 'zip build entry'
                $full = [System.IO.Path]::Combine($PackageDir, $rel.Replace('/', '\'))
                if (-not [System.IO.File]::Exists($full)) { Fail "zip entry source file is missing: '$rel'" }
                $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $fixedTime
                $stream = $entry.Open()
                try {
                    $bytes = [System.IO.File]::ReadAllBytes($full)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                }
                finally { $stream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $fs.Dispose() }
}

# =============================================================================================
# 4. SHA256SUMS.txt generation / parsing
# =============================================================================================
function New-Sha256SumsLines([string]$PackageDir, [string[]]$RelPaths) {
    $lines = New-Object System.Collections.ArrayList
    foreach ($rel in $RelPaths) {
        $full = [System.IO.Path]::Combine($PackageDir, $rel.Replace('/', '\'))
        if (-not [System.IO.File]::Exists($full)) { Fail "SHA256SUMS source file is missing: '$rel'" }
        [void]$lines.Add((Get-Sha256File $full) + '  *' + $rel)
    }
    return @($lines.ToArray())
}

function New-Sha256SumsText([string]$PackageDir, [string[]]$RelPaths) {
    $lines = New-Sha256SumsLines $PackageDir $RelPaths
    return (($lines -join "`n") + "`n")
}

function Read-Sha256SumsFile([string]$Path, [string]$Label) {
    if (-not [System.IO.File]::Exists($Path)) { Fail "$Label`: SHA256SUMS.txt not found: '$Path'" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Fail "$Label`: SHA256SUMS.txt must be UTF-8 without BOM" }
    $text = Get-Utf8TextFromBytes $bytes
    if ($text.Contains("`r")) { Fail "$Label`: SHA256SUMS.txt must use LF line endings only" }
    if (-not $text.EndsWith("`n")) { Fail "$Label`: SHA256SUMS.txt must end with a final newline" }
    $lines = @($text.Split([char]"`n") | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -eq 0) { Fail "$Label`: SHA256SUMS.txt is empty" }
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($line in $lines) {
        if ($line -notmatch '^([0-9a-f]{64})  \*(.+)$') { Fail "$Label`: SHA256SUMS.txt line has invalid format: '$line'" }
        $sha = $Matches[1]
        $rel = $Matches[2]
        Assert-SafeRelativePath $rel "$Label SHA256SUMS.txt entry"
        if ($map.Contains($rel)) { Fail "$Label`: SHA256SUMS.txt lists '$rel' more than once" }
        $map[$rel] = $sha
    }
    return [ordered]@{ Lines = $lines; Map = $map; Text = $text }
}

# =============================================================================================
# 5. Frozen input identity + payload-set walk (mirrors tools/build_manifest.mjs rules)
# =============================================================================================
function Assert-FrozenZip([string]$Path, [string]$Label, [int64]$ExpectedBytes, [string]$ExpectedSha) {
    if (-not [System.IO.File]::Exists($Path)) { Fail "$Label ZIP not found: '$Path'" }
    $info = New-Object System.IO.FileInfo($Path)
    $sha = Get-Sha256File $Path
    Assert-Condition ($info.Length -eq $ExpectedBytes) "input.$Label.bytes" `
        "$Label ZIP size $($info.Length) bytes matches the frozen identity" `
        "$Label ZIP size mismatch: expected $ExpectedBytes, actual $($info.Length) ($Path)"
    Assert-Condition ($sha -eq $ExpectedSha) "input.$Label.sha256" `
        "$Label ZIP SHA-256 $sha matches the frozen identity" `
        "$Label ZIP SHA-256 mismatch: expected $ExpectedSha, actual $sha ($Path)"
    return [ordered]@{ path = $Path; bytes = [int64]($info.Length); sha256 = $sha }
}

function Get-FrozenArchiveModel([string]$ZipPath, [string]$Label, [int64]$ExpectedBytes, [string]$ExpectedSha, [string]$ExpectedVersion, [string]$ExpectedManifestSha) {
    $identity = Assert-FrozenZip $ZipPath $Label $ExpectedBytes $ExpectedSha
    $snap = Get-ZipSnapshot $ZipPath $Label
    $entry = $snap.Files['manifest.json']
    Assert-Condition ($null -ne $entry) "$Label.manifest.present" "$Label`: manifest.json present in the archive" "$Label`: manifest.json missing from the archive"
    Assert-Condition ($entry['sha'] -eq $ExpectedManifestSha) "$Label.manifest.sha256" `
        "$Label`: manifest.json SHA-256 $($entry['sha']) matches the frozen identity" `
        "$Label`: manifest.json SHA-256 mismatch: expected $ExpectedManifestSha, actual $($entry['sha'])"
    $text = Get-Utf8TextFromBytes $entry['data']
    $json = $null
    try { $json = $text | ConvertFrom-Json }
    catch { Fail "$Label`: manifest.json is not valid JSON: $($_.Exception.Message)" }
    Assert-Condition ($json.schemaVersion -eq 1) "$Label.manifest.schemaVersion" "$Label`: manifest schemaVersion=1" "$Label`: manifest schemaVersion is not 1"
    Assert-Condition ($json.distribution.version -eq $ExpectedVersion) "$Label.manifest.distributionVersion" `
        "$Label`: manifest distribution.version=$ExpectedVersion" `
        "$Label`: manifest distribution.version mismatch: expected $ExpectedVersion, actual '$($json.distribution.version)'"
    Assert-Condition ($json.bundle.version -eq $script:Frozen['CoreBundleVersion']) "$Label.manifest.bundleVersion" `
        "$Label`: manifest bundle.version=$($script:Frozen['CoreBundleVersion'])" `
        "$Label`: manifest bundle.version mismatch"
    $files = @($json.files)
    $payloadCount = $script:Frozen['SourcePayloadFileCount']
    Assert-Condition ($files.Count -eq $payloadCount) "$Label.manifest.fileCount" `
        "$Label`: manifest lists exactly $payloadCount payload files" `
        "$Label`: manifest lists $($files.Count) payload files, expected $payloadCount"
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $payloadPaths = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $p = [string]$f.path
        Assert-SafeRelativePath $p "$Label manifest file path"
        if (-not $seen.Add($p)) { Fail "$Label`: manifest lists '$p' more than once" }
        if ($p -eq 'manifest.json') { Fail "$Label`: manifest.json must not list itself in files[]" }
        if ([string]$f.sha256 -notmatch '^[0-9a-f]{64}$') { Fail "$Label`: manifest entry '$p' has an invalid sha256 value" }
        $map[$p] = [ordered]@{ sha256 = [string]$f.sha256; bytes = [int64]($f.bytes) }
        [void]$payloadPaths.Add($p)
        $actual = $snap.Files[$p]
        if ($null -eq $actual) { Fail "$Label`: manifest lists '$p' but the archive does not contain it" }
        if ($actual['sha'] -ne $map[$p]['sha256']) { Fail "$Label`: archive bytes for '$p' do not match manifest sha256" }
        if ($actual['bytes'] -ne $map[$p]['bytes']) { Fail "$Label`: archive size for '$p' does not match manifest bytes" }
    }
    $archivePayloadPaths = @($snap.Files.Keys | Where-Object { $_ -ne 'manifest.json' })
    Assert-Condition ((Test-StringArrayEqual (Sort-Ordinal $archivePayloadPaths) (Sort-Ordinal @($payloadPaths.ToArray())))) `
        "$Label.manifest.payloadSet" "$Label`: archive payload file set equals manifest files[] set" `
        "$Label`: archive payload file set differs from manifest files[] set"
    $versionBytes = $null
    $versionEntry = $snap.Files['VERSION']
    Assert-Condition ($null -ne $versionEntry) "$Label.versionFile.present" "$Label`: VERSION present" "$Label`: VERSION missing"
    $versionBytes = [byte[]]$versionEntry['data']
    $expectedVersionSha = $script:Frozen['Rc2VersionSha256']
    if ($Label -eq 'rc3') { $expectedVersionSha = $script:Frozen['Rc3VersionSha256'] }
    Assert-Condition ((Get-Sha256Bytes $versionBytes) -eq $expectedVersionSha) "$Label.versionFile.sha256" `
        "$Label`: VERSION SHA-256 matches the frozen identity" `
        "$Label`: VERSION SHA-256 mismatch"
    return [ordered]@{
        Label         = $Label
        Identity      = $identity
        Snapshot      = $snap
        ManifestJson  = $json
        ManifestSha256 = $ExpectedManifestSha
        ManifestBytes = [int64]$entry['bytes']
        Map           = $map
        PayloadPaths  = @($payloadPaths.ToArray())
    }
}

function Get-PayloadWalk([string]$Root) {
    $root = Get-NormalizedPath $Root
    $results = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push('')
    while ($stack.Count -gt 0) {
        $relDir = [string]$stack.Pop()
        if ($relDir -eq '') { $dirFull = $root } else { $dirFull = [System.IO.Path]::Combine($root, $relDir.Replace('/', '\')) }
        $names = [System.IO.Directory]::GetFileSystemEntries($dirFull)
        $sortedNames = [string[]]@($names)
        [Array]::Sort($sortedNames, $script:Ordinal)
        foreach ($full in $sortedNames) {
            $name = [System.IO.Path]::GetFileName($full)
            if ($name.StartsWith('.') -and $name -ne '.gitignore') { continue }
            $attrs = [System.IO.File]::GetAttributes($full)
            if ((($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                Fail "reparse point (junction/symlink) found in the package tree: '$full' (payload walk must not silently skip payload)"
            }
            if ((($attrs -band [System.IO.FileAttributes]::Directory) -ne 0)) {
                if ($script:ExcludedDirs.Contains($name)) { continue }
                $childRel = $name
                if ($relDir -ne '') { $childRel = $relDir + '/' + $name }
                $stack.Push($childRel)
            }
            else {
                if ($script:ExcludedFiles.Contains($name)) { continue }
                $rel = $name
                if ($relDir -ne '') { $rel = $relDir + '/' + $name }
                Assert-SafeRelativePath $rel 'payload file'
                $bytes = [int64]((New-Object System.IO.FileInfo($full)).Length)
                [void]$results.Add([ordered]@{ path = $rel; bytes = $bytes; sha256 = (Get-Sha256File $full) })
            }
        }
    }
    return (Sort-EntriesByPath @($results.ToArray()))
}

function Sort-EntriesByPath($Entries) {
    $byPath = New-Object System.Collections.Hashtable ($script:OrdinalIgnoreCase)
    foreach ($e in $Entries) { $byPath[[string]$e['path']] = $e }
    $paths = Sort-Ordinal @($Entries | ForEach-Object { [string]$_['path'] })
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $paths) { [void]$out.Add($byPath[$p]) }
    return @($out.ToArray())
}

function Get-EntryMap($Entries) {
    $map = New-Object System.Collections.Hashtable ($script:OrdinalIgnoreCase)
    foreach ($e in $Entries) { $map[[string]$e['path']] = $e }
    return $map
}

function Test-AllowedChangedPath([string]$Path) {
    foreach ($p in $script:AllowedChangedFiles) { if ($p -ceq $Path) { return $true } }
    foreach ($pre in $script:AllowedChangedPrefixes) { if ($Path.StartsWith($pre, [System.StringComparison]::Ordinal)) { return $true } }
    return $false
}

function Test-FrozenCorePath([string]$Path) {
    foreach ($p in $script:FrozenCoreFiles) { if ($p -ceq $Path) { return $true } }
    foreach ($pre in $script:FrozenCorePrefixes) { if ($Path.StartsWith($pre, [System.StringComparison]::Ordinal)) { return $true } }
    return $false
}

function Assert-PayloadHygiene($PayloadEntries) {
    $issues = New-Object System.Collections.ArrayList
    $binary = New-Object System.Collections.ArrayList
    $crFiles = New-Object System.Collections.ArrayList
    $psNoBom = New-Object System.Collections.ArrayList
    $totalBytes = [int64]0
    foreach ($e in $PayloadEntries) {
        $rel = [string]$e['path']
        $totalBytes += [int64]$e['bytes']
        $segments = $rel.Split([char]'/')
        foreach ($seg in $segments) {
            if ($script:InternalDirNames -contains $seg) { [void]$issues.Add("$rel (internal dir name '$seg')") }
        }
        $leaf = $segments[$segments.Count - 1]
        if ($leaf -match '^(?i)UNIFIED_.*\.md$') { [void]$issues.Add("$rel (internal report file)") }
        if ($script:ProductionFileNames -contains $leaf) { [void]$issues.Add("$rel (runtime/credential artefact)") }
        if ($leaf -match '^(?i).*\.(pyc|log|zip|exe|dll|pyd|pdb|sha256)$') { [void]$issues.Add("$rel (forbidden artefact type)") }
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $isText = $true
        try { [void]$script:Utf8Strict.GetString($bytes) } catch { $isText = $false; [void]$binary.Add($rel) }
        if ($isText) {
            foreach ($b in $bytes) { if ($b -eq 13) { [void]$crFiles.Add($rel); break } }
            if ($leaf -match '^(?i).*\.(ps1|psm1)$') {
                if ($bytes.Length -ge 1) {
                    $hasNonAscii = $false
                    foreach ($b in $bytes) { if ($b -ge 0x80) { $hasNonAscii = $true; break } }
                    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
                    if ($hasNonAscii -and -not $hasBom) { [void]$psNoBom.Add($rel) }
                }
            }
        }
    }
    Assert-Condition ($issues.Count -eq 0) 'D9.noLeaks' `
        "payload contains no internal directory name, report file, runtime artefact or forbidden binary type ($( $PayloadEntries.Count ) files)" `
        "payload contains forbidden entries: [$(@($issues) -join '; ')]"
    Assert-ConditionSoft ($binary.Count -eq 0) 'D9.allText' `
        "every payload file is valid UTF-8 text ($($PayloadEntries.Count) files)" `
        "non-UTF-8/binary payload files: [$(@($binary) -join ', ')]"
    Assert-ConditionSoft ($crFiles.Count -eq 0) 'D9.lfOnly' `
        'no payload file contains CR bytes (LF-only policy)' `
        "payload files contain CR bytes: [$(@($crFiles) -join ', ')]"
    Assert-ConditionSoft ($psNoBom.Count -eq 0) 'D9.psBom' `
        'every non-ASCII PowerShell payload file starts with a UTF-8 BOM (PS 5.1 requirement)' `
        "non-ASCII .ps1/.psm1 files without UTF-8 BOM: [$(@($psNoBom) -join ', ')]"
    return $totalBytes
}

function Assert-NoDevPaths($PayloadEntries) {
    $hits = New-Object System.Collections.ArrayList
    $exemptPrefixes = @('docs/provenance/', 'tests/test_static_package.mjs')
    foreach ($e in $PayloadEntries) {
        $rel = [string]$e['path']
        $exempt = $false
        foreach ($pre in $exemptPrefixes) { if ($rel.StartsWith($pre, [System.StringComparison]::Ordinal)) { $exempt = $true } }
        if ($exempt) { continue }
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        $text = Get-Utf8TextFromBytes ([System.IO.File]::ReadAllBytes($full))
        foreach ($marker in $script:DevPathMarkers) {
            if ($text.IndexOf($marker, [System.StringComparison]::Ordinal) -ge 0) { [void]$hits.Add("$rel ($marker)"); break }
        }
        if ($text -match '[A-Za-z]:[\\/](Users|\u7528\u6237)[\\/]') { [void]$hits.Add("$rel (user-home absolute path)") }
    }
    Assert-ConditionSoft ($hits.Count -eq 0) 'D10.noDevPaths' `
        "no development-machine absolute path in $($PayloadEntries.Count) payload file(s)" `
        "development-machine absolute paths found: [$(@($hits) -join '; ')]"
}

function Test-CoreEqualityAndChangeSet($PayloadEntries, $ModelRc2, $ModelRc3) {
    $targetMap = Get-EntryMap $PayloadEntries
    $targetPaths = Sort-Ordinal @($PayloadEntries | ForEach-Object { [string]$_['path'] })
    $rc3Paths = Sort-Ordinal @($ModelRc3['PayloadPaths'])
    $rc2Paths = Sort-Ordinal @($ModelRc2['PayloadPaths'])

    $deleted = New-Object System.Collections.ArrayList
    foreach ($p in $rc3Paths) { if (-not $targetMap.ContainsKey($p)) { [void]$deleted.Add($p) } }
    Assert-Condition ($deleted.Count -eq 0) 'B4.noDeletions' `
        "no frozen RC3 payload file is deleted (target set is a superset of the $($rc3Paths.Count) frozen payload files)" `
        "frozen RC3 payload files are missing from the candidate tree: [$(@($deleted) -join ', ')]"

    $unapproved = New-Object System.Collections.ArrayList
    $coreViolations = New-Object System.Collections.ArrayList
    $changedVersusRc3 = New-Object System.Collections.ArrayList
    foreach ($p in $rc3Paths) {
        if (-not $targetMap.ContainsKey($p)) { continue }
        $actualSha = [string]$targetMap[$p]['sha256']
        $oracleSha = [string]$ModelRc3['Map'][$p]['sha256']
        if ($actualSha -ceq $oracleSha) { continue }
        [void]$changedVersusRc3.Add($p)
        if (-not (Test-AllowedChangedPath $p)) { [void]$unapproved.Add($p) }
        if (Test-FrozenCorePath $p) { [void]$coreViolations.Add($p) }
    }
    Assert-Condition ($unapproved.Count -eq 0) 'B3.onlyApprovedChanges' `
        "every RC3 payload file that changed is on the approved-change list ($($changedVersusRc3.Count) changed vs frozen RC3)" `
        "unapproved edits to frozen RC3 payload files: [$(@($unapproved) -join ', ')]"
    Assert-Condition ($coreViolations.Count -eq 0) 'B2.coreEquality' `
        'every frozen-core file (bundle/**, upstream/**, LICENSE, THIRD-PARTY-NOTICES.md, docs/provenance/**, tools/portable.ps1, tools/lib/PortableCommon.ps1, tools/probe_mcp_stdio.py, docs/06, VERSION, js-yaml vendor) is byte-identical to frozen RC3 (docs/02 carries the Lead-approved LEGACY clarification)' `
        "frozen-core files changed vs frozen RC3: [$(@($coreViolations) -join ', ')]"

    $addedVersusRc3 = New-Object System.Collections.ArrayList
    foreach ($p in $targetPaths) { if (-not $ModelRc3['Map'].Contains($p)) { [void]$addedVersusRc3.Add($p) } }
    $unexpectedAdds = New-Object System.Collections.ArrayList
    foreach ($p in $addedVersusRc3) {
        $expected = $false
        foreach ($x in $script:ExpectedNewPayloadFiles) { if ($x -ceq $p) { $expected = $true } }
        if (-not $expected) { [void]$unexpectedAdds.Add($p) }
    }
    $missingExpected = New-Object System.Collections.ArrayList
    foreach ($x in $script:ExpectedNewPayloadFiles) {
        if (-not $targetMap.ContainsKey($x)) { [void]$missingExpected.Add($x) }
    }

    $replace = New-Object System.Collections.ArrayList
    $added = New-Object System.Collections.ArrayList
    foreach ($p in $targetPaths) {
        if (-not $ModelRc2['Map'].Contains($p)) { [void]$added.Add($p); continue }
        if ([string]$targetMap[$p]['sha256'] -cne [string]$ModelRc2['Map'][$p]['sha256']) { [void]$replace.Add($p) }
    }

    $report = [ordered]@{
        addedVersusRc3   = @($addedVersusRc3.ToArray())
        unexpectedAdds   = @($unexpectedAdds.ToArray())
        missingExpected  = @($missingExpected.ToArray())
        changedVersusRc3 = @($changedVersusRc3.ToArray())
        replaceVersusRc2 = @($replace.ToArray())
        addedVersusRc2   = @($added.ToArray())
        deleted          = @($deleted.ToArray())
        payloadFileCount = $targetPaths.Count
    }
    Add-Validation 'B1.changeSet' 'PASS' `
        ("payload={0} files; added={1}; changed-vs-RC2={2}; deleted=0; changed-vs-frozenRC3={3}; unexpected-adds={4}; missing-expected={5}" -f `
            $targetPaths.Count, $report['addedVersusRc3'].Count, $replace.Count, $changedVersusRc3.Count, $unexpectedAdds.Count, $missingExpected.Count)
    Write-Host ("  added files    : " + (($report['addedVersusRc3'] | ForEach-Object { $_ }) -join ', '))
    Write-Host ("  changed (RC2)  : " + (($replace | ForEach-Object { $_ }) -join ', '))
    Write-Host ("  deleted files  : (none)")
    return $report
}

# =============================================================================================
# 6. RC2 hotfix variants + upgrade-data object construction (schemaVersion 2)
# =============================================================================================
function Get-HotfixDerivation($ModelRc2, $ModelRc3) {
    $cordis2 = [byte[]]$ModelRc2['Snapshot'].Files[$script:Frozen['CordisRelPath']]['data']
    $cordis3 = [byte[]]$ModelRc3['Snapshot'].Files[$script:Frozen['CordisRelPath']]['data']
    Assert-Condition ((Get-Sha256Bytes $cordis2) -eq $script:Frozen['CordisRc2Sha256'] -and $cordis2.Length -eq $script:Frozen['CordisRc2Bytes']) 'cordis.rc2Identity' `
        "rc.2 cordis.patch.yml identity ($($script:Frozen['CordisRc2Bytes']) bytes, $($script:Frozen['CordisRc2Sha256'])) matches the frozen facts" `
        'rc.2 cordis.patch.yml size/SHA-256 do not match the frozen facts'
    Assert-Condition ((Get-Sha256Bytes $cordis3) -eq $script:Frozen['CordisRc3Sha256'] -and $cordis3.Length -eq $script:Frozen['CordisRc3Bytes']) 'cordis.rc3Identity' `
        "rc.3 cordis.patch.yml identity ($($script:Frozen['CordisRc3Bytes']) bytes, $($script:Frozen['CordisRc3Sha256'])) matches the frozen facts" `
        'rc.3 cordis.patch.yml size/SHA-256 do not match the frozen facts'
    $needle = [System.Text.Encoding]::ASCII.GetBytes('suffix: Your working directory is {{cwd}}.')
    $hitIndexes = New-Object System.Collections.ArrayList
    for ($i = 0; $i -le $cordis2.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($cordis2[$i + $j] -ne $needle[$j]) { $match = $false; break }
        }
        if ($match) { [void]$hitIndexes.Add($i) }
    }
    Assert-Condition ($hitIndexes.Count -eq 1) 'hotfix.candidateLineUnique' `
        "rc.2 cordis.patch.yml contains exactly one '{{cwd}}' suffix line" `
        "rc.2 cordis.patch.yml contains $($hitIndexes.Count) '{{cwd}}' suffix lines, expected exactly 1"
    $suffixIdx = [int]($hitIndexes[0])
    $lineStart = $suffixIdx
    while ($lineStart -gt 0 -and $cordis2[$lineStart - 1] -ne 10) { $lineStart-- }
    $lineEnd = $suffixIdx
    while ($lineEnd -lt $cordis2.Length -and $cordis2[$lineEnd] -ne 10) { $lineEnd++ }
    $lineEnd = $lineEnd + 1
    $lineBytes = New-Object byte[] ($lineEnd - $lineStart)
    [Array]::Copy($cordis2, $lineStart, $lineBytes, 0, $lineBytes.Length)
    $lineText = Get-Utf8TextFromBytes $lineBytes
    Assert-Condition ($lineText -match '^ {14}suffix: Your working directory is \{\{cwd\}\}\.\n$') 'hotfix.lineShape' `
        'the deleted line has the frozen shape: 14 spaces + suffix text + LF (56+1 bytes)' `
        "the '{{cwd}}' line does not have the frozen shape: '$($lineText -replace "`n", '\n')'"
    $textOnly = New-Object byte[] ($lineBytes.Length - 1)
    [Array]::Copy($lineBytes, 0, $textOnly, 0, $textOnly.Length)
    $lineRemoved = New-Object byte[] ($cordis2.Length - $lineBytes.Length)
    [Array]::Copy($cordis2, 0, $lineRemoved, 0, $lineStart)
    [Array]::Copy($cordis2, $lineEnd, $lineRemoved, $lineStart, $cordis2.Length - $lineEnd)
    $textRemoved = New-Object byte[] ($cordis2.Length - $textOnly.Length)
    [Array]::Copy($cordis2, 0, $textRemoved, 0, $lineStart)
    [Array]::Copy($cordis2, $lineStart + $textOnly.Length, $textRemoved, $lineStart, $cordis2.Length - ($lineStart + $textOnly.Length))
    $lineRemovedSha = Get-Sha256Bytes $lineRemoved
    $textRemovedSha = Get-Sha256Bytes $textRemoved
    Assert-Condition ($lineBytes.Length -eq $script:Frozen['HotfixLineBytes'] -and $lineRemoved.Length -eq ($script:Frozen['CordisRc2Bytes'] - $script:Frozen['HotfixLineBytes']) -and $lineRemovedSha -eq $script:Frozen['HotfixLineRemovedSha']) 'hotfix.lineRemoved' `
        "HOTFIX_LINE_REMOVED: deleted $($lineBytes.Length)-byte line -> $($lineRemoved.Length) bytes, SHA-256 $lineRemovedSha (matches frozen allow-list)" `
        'HOTFIX_LINE_REMOVED derivation mismatch'
    Assert-Condition ((Test-BytesEqual $lineRemoved $cordis3)) 'hotfix.lineRemovedEqualsRc3' `
        'HOTFIX_LINE_REMOVED bytes are byte-identical to the rc.3 cordis.patch.yml' `
        'HOTFIX_LINE_REMOVED bytes differ from the rc.3 cordis.patch.yml'
    Assert-Condition ($textOnly.Length -eq $script:Frozen['HotfixTextBytes'] -and $textRemoved.Length -eq ($script:Frozen['CordisRc2Bytes'] - $script:Frozen['HotfixTextBytes']) -and $textRemovedSha -eq $script:Frozen['HotfixTextRemovedSha']) 'hotfix.textRemoved' `
        "HOTFIX_TEXT_REMOVED: deleted $($textOnly.Length) text bytes (LF kept) -> $($textRemoved.Length) bytes, SHA-256 $textRemovedSha (matches frozen allow-list)" `
        'HOTFIX_TEXT_REMOVED derivation mismatch'
    return [ordered]@{
        LineRemovedSha = $lineRemovedSha
        TextRemovedSha = $textRemovedSha
    }
}

function New-EnvironmentFilesObject {
    $envFiles = @(
        [ordered]@{
            path      = '_portable/install-state.json'
            format    = 'json'
            mustExist = $false
            updates   = @([ordered]@{ jsonPath = 'distribution'; expectedBefore = $script:Frozen['Rc2Version']; value = $script:Frozen['Rc3Version'] })
            addFields = @([ordered]@{
                    jsonPath = 'upgrade'
                    value    = [ordered]@{
                        lastUpgradeId = $script:Frozen['UpgradeId']
                        fromVersion   = $script:Frozen['Rc2Version']
                        toVersion     = $script:Frozen['Rc3Version']
                        by            = 'tools/setup.ps1'
                    }
                })
        },
        [ordered]@{
            path      = 'bundle/cnki-research/portable.runtime.json'
            format    = 'json'
            mustExist = $false
            updates   = @([ordered]@{ jsonPath = 'distribution'; expectedBefore = $script:Frozen['Rc2Version']; value = $script:Frozen['Rc3Version'] })
            addFields = @(
                [ordered]@{ jsonPath = 'upgradedAt'; value = '<now>' },
                [ordered]@{ jsonPath = 'upgradedBy'; value = 'tools/setup.ps1' }
            )
        }
    )
    return $envFiles
}

function New-UpgradeDataObject($PayloadEntries, $ManifestModel, $ChangeInfo, $HotfixInfo) {
    $targetMap = Get-EntryMap $PayloadEntries
    $targetPaths = Sort-Ordinal @($PayloadEntries | ForEach-Object { [string]$_['path'] })
    $sourceMap = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($p in (Sort-Ordinal @($script:ModelRc2['PayloadPaths']))) {
        $sourceMap[$p] = [string]$script:ModelRc2['Map'][$p]['sha256']
    }

    $changedFiles = New-Object System.Collections.ArrayList
    $inlineMaterial = New-Object System.Text.StringBuilder
    $setMaterial = New-Object System.Text.StringBuilder
    $replaceCount = 0
    $addCount = 0
    foreach ($p in $targetPaths) {
        $targetSha = [string]$targetMap[$p]['sha256']
        $targetBytes = [int64]$targetMap[$p]['bytes']
        if ($script:ModelRc2['Map'].Contains($p)) {
            $sourceSha = [string]$script:ModelRc2['Map'][$p]['sha256']
            if ($sourceSha -ceq $targetSha) { continue }
            $replaceCount++
            [void]$changedFiles.Add([ordered]@{
                    path           = $p
                    operation      = 'replace'
                    classification = 'payload'
                    sourceSha256   = $sourceSha
                    targetSha256   = $targetSha
                    targetBytes    = $targetBytes
                })
            [void]$inlineMaterial.Append($p + "`t" + $sourceSha + "`t" + $targetSha + "`n")
        }
        else {
            $addCount++
            [void]$changedFiles.Add([ordered]@{
                    path           = $p
                    operation      = 'add'
                    classification = 'payload'
                    sourceSha256   = $null
                    targetSha256   = $targetSha
                    targetBytes    = $targetBytes
                })
            [void]$inlineMaterial.Append($p + "`t" + 'ADD' + "`t" + $targetSha + "`n")
        }
    }
    # manifest.json: distribution metadata, inline target hash = sha256(manifest.json)
    [void]$changedFiles.Add([ordered]@{
            path           = 'manifest.json'
            operation      = 'replace'
            classification = 'distribution-metadata'
            sourceSha256   = $script:Frozen['Rc2ManifestSha256']
            targetSha256   = [string]$ManifestModel['Sha256']
            targetBytes    = [int64]$ManifestModel['Bytes']
        })
    $changedSorted = @($changedFiles.ToArray())
    $sortedPaths = Sort-Ordinal @($changedSorted | ForEach-Object { [string]$_['path'] })
    $changedOut = New-Object System.Collections.ArrayList
    $byPath = New-Object System.Collections.Hashtable ($script:OrdinalIgnoreCase)
    foreach ($cf in $changedSorted) { $byPath[[string]$cf['path']] = $cf }
    foreach ($p in $sortedPaths) { [void]$changedOut.Add($byPath[$p]) }

    foreach ($p in $sortedPaths) {
        $cf = $byPath[$p]
        [void]$setMaterial.Append($p + "`t" + [string]$cf['operation'] + "`n")
    }
    $payloadSetHash = Get-Sha256Text $inlineMaterial.ToString()
    $changedFileSetHash = Get-Sha256Text $setMaterial.ToString()

    $sourceMaterial = New-Object System.Text.StringBuilder
    foreach ($p in $sourceMap.Keys) { [void]$sourceMaterial.Append($p + "`t" + $sourceMap[$p] + "`n") }
    $sourcePayloadSetHash = Get-Sha256Text $sourceMaterial.ToString()

    $expectedTargetHashes = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($p in (Sort-Ordinal @($ManifestModel['Map'].Keys))) {
        $expectedTargetHashes[$p] = [string]$ManifestModel['Map'][$p]['sha256']
    }

    $requiredFiles = Sort-Ordinal @($changedOut | ForEach-Object { [string]$_['path'] })

    $obj = [ordered]@{
        schemaVersion                    = 2
        kind                             = $script:Frozen['MetadataKind']
        upgradeId                        = $script:Frozen['UpgradeId']
        upgraderVersion                  = $script:Frozen['UpgraderVersion']
        distributionId                   = $script:Frozen['DistributionId']
        createdUtc                       = $script:Frozen['CreatedUtc']
        sourceDistributionVersion        = $script:Frozen['Rc2Version']
        targetDistributionVersion        = $script:Frozen['Rc3Version']
        payloadRoot                      = '.'
        sourceManifestHash               = $script:Frozen['Rc2ManifestSha256']
        targetManifestHash               = [string]$ManifestModel['Sha256']
        sourcePackageHash                = $script:Frozen['Rc2ZipSha256']
        sourcePackageBytes               = [int64]$script:Frozen['Rc2ZipBytes']
        targetPackageHash                = $null
        sourcePayloadFileCount           = [int64]$sourceMap.Count
        payloadFileCount                 = [int64]$targetPaths.Count
        changedFileCount                 = [int64]$changedOut.Count
        addedFileCount                   = [int64]$addCount
        removedFileCount                 = [int64]0
        distributionManifestSchemaVersion = 1
        allowedSourceStates              = @('RC2_CLEAN', 'RC2_HOTFIXED')
        payloadSetHash                   = $payloadSetHash
        changedFileSetHash               = $changedFileSetHash
        sourcePayloadSetHash             = $sourcePayloadSetHash
        expectedSourceHashes             = $sourceMap
        expectedTargetHashes             = $expectedTargetHashes
        changedFiles                     = @($changedOut.ToArray())
        hotfixedSourceOverrides          = [ordered]@{
            $script:Frozen['CordisRelPath'] = [ordered]@{
                HOTFIX_LINE_REMOVED = $HotfixInfo['LineRemovedSha']
                HOTFIX_TEXT_REMOVED = $HotfixInfo['TextRemovedSha']
            }
        }
        environmentFiles                 = New-EnvironmentFilesObject
        preservedDirectories             = @('.venv', '_portable/backups', 'upstream/cnki-mcp', 'user files outside payload')
        rollbackMetadata                 = [ordered]@{
            supported                                = $true
            backupLayout                             = '_portable/upgrades/<transactionId>/backup'
            transactionFile                          = 'transaction.json'
            restoreOrder                             = 'reverse-apply-order'
            addedFilesDeleteOnRollback               = $true
            addedFilesDeleteOnlyIfTargetHashMatches  = $true
            createdDirectoriesCleanup                = $true
        }
        minimumRequirements              = [ordered]@{
            os               = 'Windows'
            powershell       = '5.1'
            freeBytesFormula = $script:Frozen['FreeBytesFormula']
            network          = $false
            nodeGitPython    = $false
        }
        forbiddenPaths                   = @(
            '.git',
            'node_modules',
            'dist',
            '.venv',
            '_portable/backups',
            '_portable/upgrades',
            'bundle/cnki-research/portable.runtime.json',
            'cookies.json',
            'storage_state.json',
            '.credentials.yaml',
            '.dsh',
            '.cnki-mcp',
            '<drive-root>',
            '%WINDIR%',
            '%ProgramFiles%',
            '%USERPROFILE%',
            '%LOCALAPPDATA%/ms-playwright'
        )
        validation                       = [ordered]@{
            toolNames         = @($script:ToolNames)
            mcpResources      = @('profile://list')
            personaPrefix     = $script:Frozen['PersonaPrefix']
            forbiddenCwdToken = $script:Frozen['ForbiddenCwdToken']
            requiredFiles     = @($requiredFiles)
        }
    }
    $jsonText = (ConvertTo-DeterministicJson $obj) + "`n"
    return [ordered]@{
        Object             = $obj
        JsonText           = $jsonText
        Bytes              = $script:Utf8NoBom.GetBytes($jsonText)
        PayloadSetHash     = $payloadSetHash
        ChangedFileSetHash = $changedFileSetHash
        SourcePayloadSetHash = $sourcePayloadSetHash
        ChangeInfo         = $ChangeInfo
        ReplaceCount       = $replaceCount
        AddCount           = $addCount
        ExpectedTargetHashes = $expectedTargetHashes
    }
}

function Test-UpgradeDataConsistency($Built, $PayloadEntries, $ManifestModel, $HotfixInfo) {
    $u = $Built['Object']
    $targetMap = Get-EntryMap $PayloadEntries
    $issues = New-Object System.Collections.ArrayList
    if ($u['schemaVersion'] -ne 2) { [void]$issues.Add('schemaVersion != 2') }
    if ($u['kind'] -cne $script:Frozen['MetadataKind']) { [void]$issues.Add('kind mismatch') }
    if ($u['upgradeId'] -cne $script:Frozen['UpgradeId']) { [void]$issues.Add('upgradeId mismatch') }
    if ($u['upgraderVersion'] -cne $script:Frozen['UpgraderVersion']) { [void]$issues.Add('upgraderVersion mismatch') }
    if ($u['distributionId'] -cne $script:Frozen['DistributionId']) { [void]$issues.Add('distributionId mismatch') }
    if ($u['createdUtc'] -cne $script:Frozen['CreatedUtc']) { [void]$issues.Add('createdUtc mismatch') }
    if ($u['sourceDistributionVersion'] -cne $script:Frozen['Rc2Version']) { [void]$issues.Add('sourceDistributionVersion mismatch') }
    if ($u['targetDistributionVersion'] -cne $script:Frozen['Rc3Version']) { [void]$issues.Add('targetDistributionVersion mismatch') }
    if ($u['payloadRoot'] -cne '.') { [void]$issues.Add('payloadRoot != .') }
    if ($u['sourceManifestHash'] -cne $script:Frozen['Rc2ManifestSha256']) { [void]$issues.Add('sourceManifestHash mismatch') }
    if ($u['targetManifestHash'] -cne [string]$ManifestModel['Sha256']) { [void]$issues.Add('targetManifestHash != sha256(manifest.json)') }
    if ($u['sourcePackageHash'] -cne $script:Frozen['Rc2ZipSha256']) { [void]$issues.Add('sourcePackageHash mismatch') }
    if ([int64]$u['sourcePackageBytes'] -ne [int64]$script:Frozen['Rc2ZipBytes']) { [void]$issues.Add('sourcePackageBytes mismatch') }
    if ($null -ne $u['targetPackageHash']) { [void]$issues.Add('targetPackageHash must be null') }
    if ([int64]$u['sourcePayloadFileCount'] -ne [int64]$script:Frozen['SourcePayloadFileCount']) { [void]$issues.Add('sourcePayloadFileCount mismatch') }
    if ([int64]$u['payloadFileCount'] -ne [int64]$PayloadEntries.Count) { [void]$issues.Add('payloadFileCount != payload walk count') }
    if ([int64]$u['distributionManifestSchemaVersion'] -ne 1) { [void]$issues.Add('distributionManifestSchemaVersion != 1') }
    if (@($u['allowedSourceStates']).Count -ne 2 -or -not (@($u['allowedSourceStates']) -contains 'RC2_CLEAN') -or -not (@($u['allowedSourceStates']) -contains 'RC2_HOTFIXED')) { [void]$issues.Add('allowedSourceStates mismatch') }
    if ([int64]$u['removedFileCount'] -ne 0) { [void]$issues.Add('removedFileCount != 0') }
    if ($u['hotfixedSourceOverrides'][$script:Frozen['CordisRelPath']]['HOTFIX_LINE_REMOVED'] -cne $HotfixInfo['LineRemovedSha']) { [void]$issues.Add('hotfix LINE hash mismatch') }
    if ($u['hotfixedSourceOverrides'][$script:Frozen['CordisRelPath']]['HOTFIX_TEXT_REMOVED'] -cne $HotfixInfo['TextRemovedSha']) { [void]$issues.Add('hotfix TEXT hash mismatch') }
    # rollback / preservation contract required by the adapted engine
    if ($u['rollbackMetadata']['supported'] -ne $true) { [void]$issues.Add('rollbackMetadata.supported != true') }
    if ($u['rollbackMetadata']['addedFilesDeleteOnRollback'] -ne $true) { [void]$issues.Add('rollbackMetadata.addedFilesDeleteOnRollback != true') }
    if ($u['rollbackMetadata']['addedFilesDeleteOnlyIfTargetHashMatches'] -ne $true) { [void]$issues.Add('rollbackMetadata.addedFilesDeleteOnlyIfTargetHashMatches != true') }
    if ($u['rollbackMetadata']['createdDirectoriesCleanup'] -ne $true) { [void]$issues.Add('rollbackMetadata.createdDirectoriesCleanup != true') }
    if (@($u['preservedDirectories']).Count -lt 1) { [void]$issues.Add('preservedDirectories is empty') }
    $forbidden = @($u['forbiddenPaths'])
    if ($forbidden.Count -lt 1) { [void]$issues.Add('forbiddenPaths is empty') }
    foreach ($forbiddenPath in $forbidden) {
        if ([string]$forbiddenPath -match '(?<![A-Za-z0-9_])[A-Za-z]:[\\/]') { [void]$issues.Add("forbiddenPaths entry '$forbiddenPath' looks like an absolute drive path") }
    }

    # expected source hashes
    if ($u['expectedSourceHashes'].Count -ne $script:Frozen['SourcePayloadFileCount']) { [void]$issues.Add('expectedSourceHashes count mismatch') }
    foreach ($p in $script:ModelRc2['PayloadPaths']) {
        if (-not $u['expectedSourceHashes'].Contains($p)) { [void]$issues.Add("expectedSourceHashes missing '$p'"); continue }
        if ([string]$u['expectedSourceHashes'][$p] -cne [string]$script:ModelRc2['Map'][$p]['sha256']) { [void]$issues.Add("expectedSourceHashes mismatch '$p'") }
    }
    # expected target hashes
    if ($u['expectedTargetHashes'].Count -ne $PayloadEntries.Count) { [void]$issues.Add('expectedTargetHashes count mismatch') }
    foreach ($p in $ManifestModel['Map'].Keys) {
        if (-not $u['expectedTargetHashes'].Contains($p)) { [void]$issues.Add("expectedTargetHashes missing '$p'"); continue }
        if ([string]$u['expectedTargetHashes'][$p] -cne [string]$ManifestModel['Map'][$p]['sha256']) { [void]$issues.Add("expectedTargetHashes mismatch '$p'") }
    }
    foreach ($p in $u['expectedTargetHashes'].Keys) {
        if (-not $ManifestModel['Map'].Contains($p)) { [void]$issues.Add("expectedTargetHashes extra '$p'") }
    }
    if ($u['expectedTargetHashes'].Contains($script:Frozen['MetadataRel'])) { [void]$issues.Add('expectedTargetHashes must not list the metadata file') }

    # changedFiles
    $cfPaths = @($u['changedFiles'] | ForEach-Object { [string]$_['path'] })
    $cfSorted = Sort-Ordinal $cfPaths
    if (-not (Test-StringArrayEqual $cfPaths $cfSorted)) { [void]$issues.Add('changedFiles not sorted by path') }
    if ($cfPaths.Count -ne ([int64]$u['changedFileCount'])) { [void]$issues.Add('changedFileCount mismatch') }
    $addEntries = @($u['changedFiles'] | Where-Object { $_['operation'] -eq 'add' })
    $replaceEntries = @($u['changedFiles'] | Where-Object { $_['operation'] -eq 'replace' })
    if ($addEntries.Count -ne ([int64]$u['addedFileCount'])) { [void]$issues.Add('addedFileCount mismatch') }
    foreach ($cf in $u['changedFiles']) {
        $p = [string]$cf['path']
        if ($p -ceq $script:Frozen['MetadataRel']) { [void]$issues.Add('changedFiles must not contain the metadata file itself') }
        if ($cf['operation'] -eq 'add') {
            if ($null -ne $cf['sourceSha256']) { [void]$issues.Add("add entry '$p' must have sourceSha256 null") }
            if (-not $targetMap.ContainsKey($p)) { [void]$issues.Add("add entry '$p' not in target payload") }
            if ($script:ModelRc2['Map'].Contains($p)) { [void]$issues.Add("add entry '$p' exists in the RC2 source") }
        }
        elseif ($cf['operation'] -eq 'replace') {
            if ($p -cne 'manifest.json' -and -not $script:ModelRc2['Map'].Contains($p)) { [void]$issues.Add("replace entry '$p' missing from the RC2 source") }
            if ($p -cne 'manifest.json' -and -not $targetMap.ContainsKey($p)) { [void]$issues.Add("replace entry '$p' missing from the target payload") }
        }
        else { [void]$issues.Add("invalid operation '$($cf['operation'])' for '$p'") }
        if ($cf['classification'] -notin @('payload', 'distribution-metadata')) { [void]$issues.Add("invalid classification '$($cf['classification'])' for '$p'") }
        if ($cf['classification'] -eq 'distribution-metadata' -and $p -cne 'manifest.json') { [void]$issues.Add("unexpected distribution-metadata entry '$p'") }
        if ($cf.Contains('hashSource')) { [void]$issues.Add("hashSource is not allowed in schemaVersion 2 entry '$p'") }
        if ($null -eq $cf['targetSha256'] -or [string]$cf['targetSha256'] -notmatch '^[0-9a-f]{64}$') { [void]$issues.Add("entry '$p' missing a literal targetSha256") }
        if ($null -eq $cf['targetBytes']) { [void]$issues.Add("entry '$p' missing targetBytes") }
        if ($p -ceq 'manifest.json') {
            if ([string]$cf['sourceSha256'] -cne $script:Frozen['Rc2ManifestSha256']) { [void]$issues.Add('manifest.json sourceSha256 mismatch') }
            if ([string]$cf['targetSha256'] -cne [string]$ManifestModel['Sha256']) { [void]$issues.Add('manifest.json targetSha256 mismatch') }
            if ([int64]$cf['targetBytes'] -ne [int64]$ManifestModel['Bytes']) { [void]$issues.Add('manifest.json targetBytes mismatch') }
            if ($cf['classification'] -cne 'distribution-metadata') { [void]$issues.Add('manifest.json classification must be distribution-metadata') }
        }
        else {
            if ($cf['classification'] -cne 'payload') { [void]$issues.Add("entry '$p' classification must be payload") }
            if (-not $targetMap.ContainsKey($p)) { [void]$issues.Add("entry '$p' missing from target payload") }
            else {
                if ([string]$cf['targetSha256'] -cne [string]$targetMap[$p]['sha256']) { [void]$issues.Add("entry '$p' targetSha256 mismatch") }
                if ([int64]$cf['targetBytes'] -ne [int64]$targetMap[$p]['bytes']) { [void]$issues.Add("entry '$p' targetBytes mismatch") }
            }
        }
    }
    if (-not ($cfPaths -contains 'manifest.json')) { [void]$issues.Add('changedFiles missing manifest.json') }

    # payloadSetHash / changedFileSetHash / sourcePayloadSetHash recomputation
    $inlineMaterial = New-Object System.Text.StringBuilder
    foreach ($cf in $u['changedFiles']) {
        if ($cf['classification'] -ne 'payload') { continue }
        $sourceMarker = 'ADD'
        if ($null -ne $cf['sourceSha256']) { $sourceMarker = [string]$cf['sourceSha256'] }
        [void]$inlineMaterial.Append([string]$cf['path'] + "`t" + $sourceMarker + "`t" + [string]$cf['targetSha256'] + "`n")
    }
    if ((Get-Sha256Text $inlineMaterial.ToString()) -cne [string]$u['payloadSetHash']) { [void]$issues.Add('payloadSetHash mismatch') }
    $setMaterial = New-Object System.Text.StringBuilder
    foreach ($cf in $u['changedFiles']) { [void]$setMaterial.Append([string]$cf['path'] + "`t" + [string]$cf['operation'] + "`n") }
    if ((Get-Sha256Text $setMaterial.ToString()) -cne [string]$u['changedFileSetHash']) { [void]$issues.Add('changedFileSetHash mismatch') }
    $sourceMaterial = New-Object System.Text.StringBuilder
    foreach ($p in $u['expectedSourceHashes'].Keys) { [void]$sourceMaterial.Append($p + "`t" + [string]$u['expectedSourceHashes'][$p] + "`n") }
    if ((Get-Sha256Text $sourceMaterial.ToString()) -cne [string]$u['sourcePayloadSetHash']) { [void]$issues.Add('sourcePayloadSetHash mismatch') }

    # requiredFiles
    if (-not (Test-StringArrayEqual (Sort-Ordinal @($u['validation'].requiredFiles)) $cfSorted)) { [void]$issues.Add('validation.requiredFiles != changedFiles paths') }
    # environmentFiles shape
    $env = @($u['environmentFiles'])
    if ($env.Count -ne 2) { [void]$issues.Add('environmentFiles count != 2') }
    else {
        if ($env[0].path -cne '_portable/install-state.json' -or $env[1].path -cne 'bundle/cnki-research/portable.runtime.json') { [void]$issues.Add('environmentFiles paths mismatch') }
        if ($env[1].addFields.Count -ne 2 -or $env[1].addFields[0].value -cne '<now>') { [void]$issues.Add('runtime env addFields mismatch') }
    }
    # banned literals / names in the serialized metadata
    $text = [string]$Built['JsonText']
    foreach ($banned in @('targetSumsHash', 'hashSource')) {
        if ($text.IndexOf('"' + $banned + '"', [System.StringComparison]::Ordinal) -ge 0) { [void]$issues.Add("banned key '$banned' present") }
    }
    if ($text -match '(?<![A-Za-z0-9_])[A-Za-z]:[\\/]') {
        $m = [regex]::Match($text, '(?<![A-Za-z0-9_])[A-Za-z]:[\\/]')
        $startAt = [Math]::Max(0, $m.Index - 24)
        $snippet = $text.Substring($startAt, [Math]::Min(64, $text.Length - $startAt))
        [void]$issues.Add("metadata contains an absolute drive path near: '$snippet'")
    }
    if ($text.Contains("`r")) { [void]$issues.Add('metadata contains CR bytes') }
    if (-not $text.EndsWith("`n")) { [void]$issues.Add('metadata lacks the final newline') }

    Assert-Condition ($issues.Count -eq 0) 'C.metadata.selfConsistent' `
        ("upgrade-data object is internally consistent (schemaVersion 2, payload={0}, changed={1}, adds={2}, replaces={3})" -f $u['payloadFileCount'], $u['changedFileCount'], $u['addedFileCount'], $replaceEntries.Count) `
        ("upgrade-data inconsistencies: " + (@($issues) -join '; '))
}

# =============================================================================================
# 7. manifest + SHA256SUMS validation, closure graph
# =============================================================================================
function Test-ManifestAgainstTree($PayloadEntries) {
    $path = [System.IO.Path]::Combine($script:RepoRoot, 'manifest.json')
    if (-not [System.IO.File]::Exists($path)) { Fail "manifest.json is missing after generation: '$path'" }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Fail 'manifest.json must be UTF-8 without BOM' }
    $json = $null
    try { $json = (Get-Utf8TextFromBytes $bytes) | ConvertFrom-Json }
    catch { Fail "manifest.json is not valid JSON: $($_.Exception.Message)" }
    $issues = New-Object System.Collections.ArrayList
    if ($json.schemaVersion -ne 1) { [void]$issues.Add('schemaVersion != 1') }
    if ($json.distribution.version -cne $script:Frozen['Rc3Version']) { [void]$issues.Add('distribution.version != 1.0.0-rc.3') }
    if ($json.distribution.variant -cne 'unified-installer') { [void]$issues.Add('distribution.variant != unified-installer') }
    if ($json.distribution.candidate -ne $true) { [void]$issues.Add('distribution.candidate != true') }
    if ($json.bundle.version -cne $script:Frozen['CoreBundleVersion']) { [void]$issues.Add('bundle.version != 1.0.0') }
    if ($json.install.entryPoint -cne 'tools/portable.ps1') { [void]$issues.Add('install.entryPoint must stay tools/portable.ps1') }
    if ($json.install.setupEntryPoint -cne 'tools/setup.ps1') { [void]$issues.Add('install.setupEntryPoint != tools/setup.ps1') }
    if ($json.upgrade.schemaVersion -ne 2) { [void]$issues.Add('upgrade.schemaVersion != 2') }
    if ($json.upgrade.data -cne $script:Frozen['MetadataRel']) { [void]$issues.Add('upgrade.data != upgrade-data/rc2-to-rc3.json') }
    if ($json.upgrade.upgradeId -cne $script:Frozen['UpgradeId']) { [void]$issues.Add('upgrade.upgradeId mismatch') }
    if ($json.upgrade.engine -cne 'tools/lib/UpgradeCommon.ps1') { [void]$issues.Add('upgrade.engine mismatch') }
    if ($json.upgrade.setup -cne 'tools/setup.ps1') { [void]$issues.Add('upgrade.setup mismatch') }
    if ($json.upgrade.sourceVersion -cne $script:Frozen['Rc2Version']) { [void]$issues.Add('upgrade.sourceVersion mismatch') }
    if ($json.upgrade.targetVersion -cne $script:Frozen['Rc3Version']) { [void]$issues.Add('upgrade.targetVersion mismatch') }
    $states = @($json.upgrade.allowedSourceStates)
    if (-not ($states -contains 'RC2_CLEAN') -or -not ($states -contains 'RC2_HOTFIXED')) { [void]$issues.Add('upgrade.allowedSourceStates mismatch') }

    $files = @($json.files)
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($f in $files) {
        $p = [string]$f.path
        Assert-SafeRelativePath $p 'manifest file path'
        if (-not $seen.Add($p)) { [void]$issues.Add("duplicate manifest path '$p'") }
        if ($p -ceq 'manifest.json') { [void]$issues.Add('manifest.json must not list itself') }
        if ($p -ceq $script:Frozen['MetadataRel'] -or $p -ceq $script:Frozen['MetadataReadmeRel']) { [void]$issues.Add("manifest must not list package-only metadata '$p'") }
        if ($p -ceq 'SHA256SUMS.txt') { [void]$issues.Add('manifest must not list SHA256SUMS.txt') }
        if ([string]$f.sha256 -notmatch '^[0-9a-f]{64}$') { [void]$issues.Add("invalid sha256 for '$p'") }
        $map[$p] = [ordered]@{ sha256 = [string]$f.sha256; bytes = [int64]$f.bytes }
    }
    $diskMap = Get-EntryMap $PayloadEntries
    $manifestPaths = Sort-Ordinal @($map.Keys)
    $diskPaths = Sort-Ordinal @($PayloadEntries | ForEach-Object { [string]$_['path'] })
    if (-not (Test-StringArrayEqual $manifestPaths $diskPaths)) { [void]$issues.Add('manifest files[] set != payload walk set') }
    foreach ($p in $diskPaths) {
        if (-not $map.Contains($p)) { continue }
        if ([int64]$map[$p]['bytes'] -ne [int64]$diskMap[$p]['bytes']) { [void]$issues.Add("manifest bytes mismatch '$p'") }
        if ([string]$map[$p]['sha256'] -cne [string]$diskMap[$p]['sha256']) { [void]$issues.Add("manifest sha256 mismatch '$p'") }
    }
    Assert-Condition ($issues.Count -eq 0) 'D.manifest' `
        "manifest.json is current, deterministic and consistent: schemaVersion 1, distribution 1.0.0-rc.3 unified-installer, $(@($files).Count) payload files, upgrade block schemaVersion 2" `
        ("manifest.json problems: " + (@($issues) -join '; '))
    return [ordered]@{
        Json    = $json
        Bytes   = [int64]($bytes.Length)
        Sha256  = (Get-Sha256Bytes $bytes)
        Map     = $map
        Files   = $files
        Paths   = $manifestPaths
    }
}

function Invoke-ManifestGenerator([string]$Label) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) {
        if ($SkipNode) {
            Add-Validation "$Label.manifest.node" 'WARN' 'node is unavailable and -SkipNode was given: manifest.json is validated structurally but not regenerated byte-for-byte'
            return
        }
        Fail 'node is unavailable: tools/build_manifest.mjs must be run to regenerate manifest.json (pass -SkipNode only in controlled test mode when manifest.json is already generated)'
    }
    $scriptPath = [System.IO.Path]::Combine($script:RepoRoot, 'tools\build_manifest.mjs')
    if (-not [System.IO.File]::Exists($scriptPath)) { Fail "tools\build_manifest.mjs is missing from the candidate repo: '$scriptPath'" }
    $previous = Get-Location
    $prevEap = $ErrorActionPreference
    try {
        Set-Location -LiteralPath $script:RepoRoot
        $ErrorActionPreference = 'Continue'
        $output = & $node.Source $scriptPath 2>&1 | Out-String
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
        Set-Location -LiteralPath $previous
    }
    Assert-Condition ($exit -eq 0) "$Label.manifest.generate" `
        ("node tools/build_manifest.mjs regenerated manifest.json (exit 0): " + (($output.Trim() -split "`n" | Select-Object -Last 1))) `
        ("node tools/build_manifest.mjs failed (exit $exit): " + $output)
}

function Test-UpgradeDataOnDisk($Built) {
    $path = [System.IO.Path]::Combine($script:RepoRoot, $script:Frozen['MetadataRel'].Replace('/', '\'))
    Assert-Condition ([System.IO.File]::Exists($path)) 'C.metadata.present' `
        "upgrade-data/rc2-to-rc3.json exists ($($Built['Bytes'].Length) bytes)" `
        "upgrade-data/rc2-to-rc3.json is missing: '$path'"
    $disk = [System.IO.File]::ReadAllBytes($path)
    Assert-Condition (Test-BytesEqual $disk ([byte[]]$Built['Bytes'])) 'C.metadata.deterministic' `
        "upgrade-data/rc2-to-rc3.json is byte-identical to the deterministic regeneration (SHA-256 $(Get-Sha256Bytes $disk))" `
        "upgrade-data/rc2-to-rc3.json differs from the deterministic regeneration"
}

function Get-PackageFileSet($PayloadEntries) {
    $entries = New-Object System.Collections.ArrayList
    foreach ($e in $PayloadEntries) { [void]$entries.Add([string]$e['path']) }
    [void]$entries.Add('manifest.json')
    [void]$entries.Add($script:Frozen['MetadataRel'])
    [void]$entries.Add($script:Frozen['MetadataReadmeRel'])
    return (Sort-Ordinal @($entries.ToArray()))
}

function Assert-UpgradeDataInputs {
    $dir = [System.IO.Path]::Combine($script:RepoRoot, 'upgrade-data')
    Assert-Condition ([System.IO.Directory]::Exists($dir)) 'D3.upgradeDataDir' 'upgrade-data/ directory exists' 'upgrade-data/ directory is missing'
    $names = New-Object System.Collections.ArrayList
    foreach ($f in [System.IO.Directory]::GetFiles($dir)) { [void]$names.Add([System.IO.Path]::GetFileName($f)) }
    $unexpected = New-Object System.Collections.ArrayList
    foreach ($name in $names) {
        if ($name -cne 'rc2-to-rc3.json' -and $name -cne 'README.md') { [void]$unexpected.Add($name) }
    }
    Assert-Condition ($unexpected.Count -eq 0) 'D3.upgradeDataInputs' `
        'upgrade-data/ holds no unexpected file (only rc2-to-rc3.json and README.md are allowed)' `
        ("upgrade-data/ contains unexpected entries: " + ($unexpected -join ', '))
    $readme = [System.IO.Path]::Combine($dir, 'README.md')
    Assert-Condition ([System.IO.File]::Exists($readme)) 'D3.upgradeDataReadme' 'upgrade-data/README.md present' 'upgrade-data/README.md is missing'
}

function Assert-PackageMetadataLayout {
    Assert-UpgradeDataInputs
    $dir = [System.IO.Path]::Combine($script:RepoRoot, 'upgrade-data')
    $names = New-Object System.Collections.ArrayList
    foreach ($f in [System.IO.Directory]::GetFiles($dir)) { [void]$names.Add([System.IO.Path]::GetFileName($f)) }
    $sorted = Sort-Ordinal @($names.ToArray())
    $expected = Sort-Ordinal @('rc2-to-rc3.json', 'README.md')
    Assert-Condition ((Test-StringArrayEqual $sorted $expected)) 'D3.upgradeDataContents' `
        'upgrade-data/ contains exactly rc2-to-rc3.json + README.md (no file copies / no duplicate payload)' `
        "upgrade-data/ contains unexpected entries: [$($sorted -join ', ')]"
    $readme = [System.IO.Path]::Combine($dir, 'README.md')
    $readmeText = Get-Utf8TextFromBytes ([System.IO.File]::ReadAllBytes($readme))
    $hashHits = [regex]::Matches($readmeText, '(?i)\b[0-9a-f]{64}\b')
    Assert-Condition ($hashHits.Count -eq 0) 'C10.readmeNoHashes' `
        'upgrade-data/README.md uses placeholders only (no literal 64-hex hash; cannot create a hash cycle)' `
        "upgrade-data/README.md contains $($hashHits.Count) literal 64-hex hash(es)"
}

function Test-SumsAgainstPackage($Sums, $pkgPaths) {
    $expected = Sort-Ordinal @($pkgPaths)
    $actual = Sort-Ordinal @($Sums['Map'].Keys)
    $issues = New-Object System.Collections.ArrayList
    if (-not (Test-StringArrayEqual $actual $expected)) { [void]$issues.Add('SHA256SUMS file set != package file set minus itself') }
    foreach ($rel in $expected) {
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        if (-not [System.IO.File]::Exists($full)) { [void]$issues.Add("missing file '$rel'"); continue }
        $sha = Get-Sha256File $full
        if ($Sums['Map'].Contains($rel)) {
            if ([string]$Sums['Map'][$rel] -cne $sha) { [void]$issues.Add("hash mismatch '$rel'") }
        }
    }
    Assert-Condition ($issues.Count -eq 0) 'D4.sumsIntegrity' `
        ("SHA256SUMS.txt covers every package file except itself ({0} entries, sorted Ordinal, LF, UTF-8 no BOM) and every hash matches" -f $expected.Count) `
        ("SHA256SUMS.txt problems: " + (@($issues) -join '; '))
}

function Test-ClosureGraph($pkgPaths, $Sums, $ManifestModel, $Built) {
    $issues = New-Object System.Collections.ArrayList
    $shaToPaths = New-Object System.Collections.Hashtable ($script:OrdinalIgnoreCase)
    $pathToSha = New-Object System.Collections.Hashtable ($script:OrdinalIgnoreCase)
    foreach ($rel in $pkgPaths) {
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        $sha = Get-Sha256File $full
        $pathToSha[$rel] = $sha
        if (-not $shaToPaths.ContainsKey($sha)) { $shaToPaths[$sha] = New-Object System.Collections.ArrayList }
        [void]$shaToPaths[$sha].Add($rel)
    }
    $sumsSha = Get-Sha256File ([System.IO.Path]::Combine($script:RepoRoot, 'SHA256SUMS.txt'))
    $pathToSha['SHA256SUMS.txt'] = $sumsSha
    if (-not $shaToPaths.ContainsKey($sumsSha)) { $shaToPaths[$sumsSha] = New-Object System.Collections.ArrayList }
    [void]$shaToPaths[$sumsSha].Add('SHA256SUMS.txt')

    $metaSha = [string]$pathToSha[$script:Frozen['MetadataRel']]
    $manifestSha = [string]$pathToSha['manifest.json']

    # 1) manifest authenticity: its hash is covered by SHA256SUMS.txt
    if (-not $Sums['Map'].Contains('manifest.json')) { [void]$issues.Add('SHA256SUMS.txt does not cover manifest.json') }
    elseif ([string]$Sums['Map']['manifest.json'] -cne $manifestSha) { [void]$issues.Add('SHA256SUMS.txt manifest.json hash mismatch') }
    # 2) metadata authenticity: covered by SHA256SUMS.txt and targetManifestHash == sha256(manifest.json)
    if (-not $Sums['Map'].Contains($script:Frozen['MetadataRel'])) { [void]$issues.Add('SHA256SUMS.txt does not cover the metadata file') }
    elseif ([string]$Sums['Map'][$script:Frozen['MetadataRel']] -cne $metaSha) { [void]$issues.Add('SHA256SUMS.txt metadata hash mismatch') }
    if ([string]$Built['Object']['targetManifestHash'] -cne $manifestSha) { [void]$issues.Add('metadata targetManifestHash != sha256(manifest.json)') }
    # 3) expectedTargetHashes == manifest files[] exactly
    $manifestPaths = Sort-Ordinal @($ManifestModel['Map'].Keys)
    $targetPaths = Sort-Ordinal @($Built['Object']['expectedTargetHashes'].Keys)
    if (-not (Test-StringArrayEqual $manifestPaths $targetPaths)) { [void]$issues.Add('expectedTargetHashes keys != manifest files[] paths') }
    foreach ($p in $manifestPaths) {
        if (-not $Built['Object']['expectedTargetHashes'].Contains($p)) { continue }
        if ([string]$Built['Object']['expectedTargetHashes'][$p] -cne [string]$ManifestModel['Map'][$p]['sha256']) { [void]$issues.Add("expectedTargetHashes mismatch '$p'") }
    }
    # 4) metadata must not contain its own hash or the sums hash
    $metaText = [string]$Built['JsonText']
    if ($metaText.IndexOf($metaSha, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$issues.Add('metadata contains its own SHA-256 (self-cycle)') }
    if ($metaText.IndexOf($sumsSha, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$issues.Add('metadata contains the SHA256SUMS.txt hash (cycle)') }
    # 5) no file other than SHA256SUMS.txt may embed the metadata hash (that would be an unnecessary cycle edge)
    foreach ($rel in $pkgPaths) {
        if ($rel -ceq $script:Frozen['MetadataRel']) { continue }
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $text = $null
        try { $text = $script:Utf8Strict.GetString($bytes) } catch { continue }
        if ($text.IndexOf($metaSha, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$issues.Add("file '$rel' embeds the metadata hash") }
    }
    # 6) full dependency graph: file -> files whose SHA-256 literal it embeds; must be acyclic
    $nodes = New-Object System.Collections.ArrayList
    foreach ($rel in $pkgPaths) { [void]$nodes.Add($rel) }
    [void]$nodes.Add('SHA256SUMS.txt')
    $nodeSorted = Sort-Ordinal @($nodes.ToArray())
    $edges = New-Object System.Collections.Hashtable ($script:OrdinalIgnoreCase)
    foreach ($rel in $nodeSorted) { $edges[$rel] = New-Object System.Collections.ArrayList }
    $hexRegex = New-Object System.Text.RegularExpressions.Regex('[0-9a-fA-F]{64}')
    foreach ($rel in $nodeSorted) {
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $text = $null
        try { $text = $script:Utf8Strict.GetString($bytes) } catch { continue }
        $matches = $hexRegex.Matches($text)
        $seenLocal = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($m in $matches) {
            $hex = $m.Value.ToLowerInvariant()
            if (-not $shaToPaths.ContainsKey($hex)) { continue }
            foreach ($target in $shaToPaths[$hex]) {
                if ($target -ceq $rel) { [void]$issues.Add("file '$rel' embeds its own SHA-256") }
                if ($seenLocal.Add($target)) { [void]$edges[$rel].Add($target) }
            }
        }
    }
    $cycle = Find-GraphCycle $edges $nodeSorted
    if ($null -ne $cycle) { [void]$issues.Add("hash dependency cycle detected: $cycle") }
    $unexpectedUEdge = $false
    foreach ($to in $edges[$script:Frozen['MetadataRel']]) {
        if ($to -ceq 'SHA256SUMS.txt') { $unexpectedUEdge = $true }
    }
    if ($unexpectedUEdge) { [void]$issues.Add('metadata embeds the SHA256SUMS.txt hash directly') }
    Assert-Condition ($issues.Count -eq 0) 'E.closure' `
        ("hash closure proven: SHA256SUMS.txt covers manifest.json + upgrade-data + payload; metadata.targetManifestHash == sha256(manifest.json); expectedTargetHashes == manifest files[] ({0} entries); no self reference; dependency graph acyclic" -f $manifestPaths.Count) `
        ("closure problems: " + (@($issues) -join '; '))
}

function Find-GraphCycle($Edges, [string[]]$Nodes) {
    $state = New-Object System.Collections.Hashtable ($script:OrdinalIgnoreCase)
    foreach ($n in $Nodes) { $state[$n] = 0 }
    foreach ($n in $Nodes) {
        if ($state[$n] -ne 0) { continue }
        $path = New-Object System.Collections.ArrayList
        $found = Visit-GraphNode $n $Edges $state $path
        if ($null -ne $found) { return $found }
    }
    return $null
}

function Visit-GraphNode([string]$Node, $Edges, $State, $Path) {
    $State[$Node] = 1
    [void]$Path.Add($Node)
    if ($Edges.ContainsKey($Node)) {
        foreach ($next in $Edges[$Node]) {
            $nextState = $State[$next]
            if ($nextState -eq 1) {
                $cyclePath = New-Object System.Collections.ArrayList
                $started = $false
                foreach ($step in $Path) {
                    if ($step -ceq $next) { $started = $true }
                    if ($started) { [void]$cyclePath.Add($step) }
                }
                [void]$cyclePath.Add($next)
                return (@($cyclePath.ToArray()) -join ' -> ')
            }
            if ($nextState -eq 0) {
                $result = Visit-GraphNode $next $Edges $State $Path
                if ($null -ne $result) { return $result }
            }
        }
    }
    $State[$Node] = 2
    [void]$Path.RemoveAt($Path.Count - 1)
    return $null
}

# =============================================================================================
# 8. ZIP proof + external release identity
# =============================================================================================
function Build-ZipProof([string]$PassRoot, [string]$Label, [string[]]$ZipPaths) {
    $proofDir = Join-Path $PassRoot 'zip-proof'
    Reset-Directory $proofDir $script:RepoParent
    $aPath = Join-Path $proofDir 'build-a.zip'
    $bPath = Join-Path $proofDir 'build-b.zip'
    New-DeterministicZipFile $aPath $script:RepoRoot $ZipPaths
    New-DeterministicZipFile $bPath $script:RepoRoot $ZipPaths
    $shaA = Get-Sha256File $aPath
    $shaB = Get-Sha256File $bPath
    Assert-Condition ($shaA -eq $shaB) "$Label.zip.deterministic" `
        "two independent ZIP builds produced byte-identical archives ($shaA); DETERMINISTIC_ZIP=PASS" `
        "deterministic ZIP check FAILED: build-a=$shaA build-b=$shaB"
    $zipInfo = Read-ProducedZip $aPath $Label
    $expectedPaths = Sort-Ordinal $ZipPaths
    $actualPaths = Sort-Ordinal @($zipInfo['Files'].Keys)
    $issues = New-Object System.Collections.ArrayList
    if (-not (Test-StringArrayEqual $actualPaths $expectedPaths)) { [void]$issues.Add('produced ZIP entry set != expected package file set') }
    if ($zipInfo['EntryCount'] -ne $expectedPaths.Count) { [void]$issues.Add("entry count $($zipInfo['EntryCount']) != $($expectedPaths.Count)") }
    foreach ($rel in $expectedPaths) {
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        $fileSha = Get-Sha256File $full
        if (-not $zipInfo['Files'].Contains($rel)) { [void]$issues.Add("missing entry '$rel'"); continue }
        if ([string]$zipInfo['Files'][$rel]['sha'] -cne $fileSha) { [void]$issues.Add("entry hash mismatch '$rel'") }
        if ([int64]$zipInfo['Files'][$rel]['bytes'] -ne (New-Object System.IO.FileInfo($full)).Length) { [void]$issues.Add("entry size mismatch '$rel'") }
    }
    Assert-Condition ($issues.Count -eq 0) "$Label.zip.entrySet" `
        ("produced ZIP has exactly {0} file entries, forward slashes, no directory entries, every entry hash/size matches the package" -f $expectedPaths.Count) `
        ("produced ZIP problems: " + (@($issues) -join '; '))
    Assert-Condition ($shaA -cne $script:Frozen['Rc3ZipSha256']) "$Label.zip.newIdentity" `
        "candidate ZIP SHA-256 differs from the frozen RC3 ZIP (old identity not reused)" `
        'candidate ZIP SHA-256 equals the frozen RC3 ZIP hash (unexpected)'
    return [ordered]@{
        Label        = $Label
        Path         = $aPath
        ProofPathB   = $bPath
        Bytes        = [int64]$zipInfo['Bytes']
        Sha256       = $shaA
        EntryCount   = [int64]$zipInfo['EntryCount']
        ZipPaths     = $expectedPaths
    }
}

function New-ReleaseManifestObject($Final, $pkgPaths) {
    $repo = $script:RepoRoot
    $manifestPath = [System.IO.Path]::Combine($repo, 'manifest.json')
    $sumsPath = [System.IO.Path]::Combine($repo, 'SHA256SUMS.txt')
    $metaPath = [System.IO.Path]::Combine($repo, $script:Frozen['MetadataRel'].Replace('/', '\'))
    $manifestBytes = (New-Object System.IO.FileInfo($manifestPath)).Length
    $manifestSha = Get-Sha256File $manifestPath
    $sumsBytes = (New-Object System.IO.FileInfo($sumsPath)).Length
    $sumsSha = Get-Sha256File $sumsPath
    $metaBytes = (New-Object System.IO.FileInfo($metaPath)).Length
    $metaSha = Get-Sha256File $metaPath
    $payloadBytes = [int64]0
    foreach ($e in $script:PayloadEntries) { $payloadBytes += [int64]$e['bytes'] }
    $object = [ordered]@{
        schemaVersion      = 1
        kind               = 'cnki-research-portable-release'
        grade              = 'UNIFIED-CANDIDATE'
        candidate          = $true
        distribution       = [ordered]@{
            name     = 'cnki-research-portable'
            title    = 'CNKI Research Portable'
            version  = $script:Frozen['Rc3Version']
            license  = 'GPL-3.0-only'
            platform = @('windows-x64')
            variant  = 'unified-installer'
            candidate = $true
        }
        upgrade            = [ordered]@{
            upgradeId        = $script:Frozen['UpgradeId']
            upgraderVersion  = $script:Frozen['UpgraderVersion']
            distributionId   = $script:Frozen['DistributionId']
            metadataPath     = $script:Frozen['MetadataRel']
            metadataSchemaVersion = 2
            sourceVersion    = $script:Frozen['Rc2Version']
            targetVersion    = $script:Frozen['Rc3Version']
            allowedSourceStates = @('RC2_CLEAN', 'RC2_HOTFIXED')
            runtimeActivation = 'NOT TESTED'
        }
        candidatePackage   = [ordered]@{
            zipName          = $script:Frozen['ZipName']
            zipBytes         = [int64]$Final['ZipBytes']
            zipSha256        = [string]$Final['ZipSha256']
            sidecar          = $script:Frozen['ZipName'] + '.sha256'
            internalSums     = [ordered]@{ path = 'SHA256SUMS.txt'; bytes = [int64]$sumsBytes; sha256 = $sumsSha; scope = 'in-package trust root; covers payload + manifest.json + upgrade-data/**; excludes itself' }
            manifest         = [ordered]@{ path = 'manifest.json'; bytes = [int64]$manifestBytes; sha256 = $manifestSha; scope = 'distribution payload manifest (schemaVersion 1)' }
            upgradeData      = [ordered]@{ path = $script:Frozen['MetadataRel']; bytes = [int64]$metaBytes; sha256 = $metaSha; scope = 'package-only upgrade metadata (schemaVersion 2)' }
            payloadFileCount = [int64]$script:PayloadEntries.Count
            packageFileCount = [int64]$pkgPaths.Count
            zipEntryCount    = [int64]$Final['ZipEntryCount']
            changedFileCount = [int64]$Final['ChangedFileCount']
            addedFileCount   = [int64]$Final['AddedFileCount']
        }
        sourceIdentity     = [ordered]@{
            distributionVersion = $script:Frozen['Rc2Version']
            packageSha256       = $script:Frozen['Rc2ZipSha256']
            packageBytes        = [int64]$script:Frozen['Rc2ZipBytes']
            manifestSha256      = $script:Frozen['Rc2ManifestSha256']
            payloadFileCount    = [int64]$script:Frozen['SourcePayloadFileCount']
        }
        frozenRc3Identity  = [ordered]@{
            packageSha256  = $script:Frozen['Rc3ZipSha256']
            packageBytes   = [int64]$script:Frozen['Rc3ZipBytes']
            manifestSha256 = $script:Frozen['Rc3ManifestSha256']
            payloadFileCount = [int64]$script:Frozen['SourcePayloadFileCount']
            note           = 'read-only core-equality oracle; frozen RC3 payload files that the unified round does not change stay byte-identical'
        }
        payload            = [ordered]@{
            manifest   = 'manifest.json'
            fileCount  = [int64]$script:PayloadEntries.Count
            totalBytes = [int64]$payloadBytes
        }
        build              = [ordered]@{
            generatedBy          = 'tools/build_unified_release.ps1'
            intermediate         = [bool]$Final['Intermediate']
            deterministicZip     = 'PASS'
            secondBuildSha256    = [string]$Final['SecondBuildSha256']
            cleanRebuildSha256   = [string]$Final['CleanRebuildSha256']
            reproducibleBuild    = [string]$Final['ReproducibleBuild']
            closureChecks        = 'PASS'
            frozenInputsUnchanged = 'PASS'
            staticGate           = 'NOT TESTED'
        }
        releaseAssets      = @(
            [ordered]@{ name = $script:Frozen['ZipName']; role = 'candidate archive'; bytes = [int64]$Final['ZipBytes']; sha256 = [string]$Final['ZipSha256'] }
            [ordered]@{ name = $script:Frozen['ZipName'] + '.sha256'; role = 'archive sidecar'; sha256 = [string]$Final['SidecarSha256'] }
            [ordered]@{ name = $script:Frozen['ReleaseDocName']; role = 'release deployment readme copy'; sha256 = [string]$Final['ReleaseDocSha256'] }
        )
        verification       = [ordered]@{
            verifyCommands = @(
                'node tools/build_manifest.mjs --check',
                'powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify_release_zip.ps1 -Zip <candidate.zip>',
                'powershell -NoProfile -ExecutionPolicy Bypass -File tools/build_unified_release.ps1 -VerifyOnly -Rc2Zip <rc2.zip> -Rc3FrozenZip <rc3.zip> -Zip <candidate.zip>'
            )
            runtimeActivation = 'NOT TESTED'
            productionEnvironmentChanged = $false
        }
    }
    return $object
}

function New-ReleaseSumsText($final) {
    $sidecarName = $script:Frozen['ZipName'] + '.sha256'
    $names = Sort-Ordinal @($script:Frozen['ZipName'], $sidecarName, $script:Frozen['ReleaseDocName'], $script:Frozen['ReleaseManifestName'])
    $lines = New-Object System.Collections.ArrayList
    foreach ($name in $names) {
        $path = [System.IO.Path]::Combine($script:OutRoot, $name)
        if (-not [System.IO.File]::Exists($path)) { Fail "release asset is missing for the external checksum list: '$name'" }
        [void]$lines.Add((Get-Sha256File $path) + '  ' + $name)
    }
    return (($lines.ToArray() -join "`n") + "`n")
}

function Write-ExternalAssets($Final, $pkgPaths) {
    Ensure-Directory $script:DistRoot
    Ensure-Directory $script:OutRoot
    $proofZip = [string]$Final['ZipPath']
    $zipSha = Get-Sha256File $proofZip
    if ($zipSha -cne [string]$Final['ZipSha256']) { Fail 'internal error: proof ZIP hash changed before release copy' }
    $distZip = [System.IO.Path]::Combine($script:DistRoot, $script:Frozen['ZipName'])
    [System.IO.File]::Copy($proofZip, $distZip, $true)
    $sidecarText = $zipSha + ' *' + $script:Frozen['ZipName'] + "`n"
    $distSidecar = $distZip + '.sha256'
    Write-TextFile $distSidecar $sidecarText
    $outZip = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ZipName'])
    [System.IO.File]::Copy($proofZip, $outZip, $true)
    $outSidecar = $outZip + '.sha256'
    Write-TextFile $outSidecar $sidecarText
    Assert-Condition ((Get-Sha256File $outZip) -eq $zipSha) 'release.zipCopy' `
        "release ZIP written: $outZip ($($Final['ZipBytes']) bytes, SHA-256 $zipSha)" `
        'release ZIP copy does not match the deterministic proof build'

    $docSource = [System.IO.Path]::Combine($script:RepoRoot, 'DEPLOYMENT_README.md')
    $docTarget = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ReleaseDocName'])
    $docSha = $null
    if ([System.IO.File]::Exists($docSource)) {
        [System.IO.File]::Copy($docSource, $docTarget, $true)
        $docSha = Get-Sha256File $docTarget
        Assert-Condition ($docSha -eq (Get-Sha256File $docSource)) 'release.docCopy' `
            "DEPLOYMENT_README_release.md copy is byte-identical to the package doc ($docSha)" `
            'DEPLOYMENT_README_release.md copy differs from the package doc'
    }
    else {
        Fail 'DEPLOYMENT_README.md is missing from the candidate repo; the release documentation copy cannot be produced'
    }

    $Final['SidecarSha256'] = Get-Sha256File $outSidecar
    $Final['ReleaseDocSha256'] = $docSha

    $releaseObject = New-ReleaseManifestObject $Final $pkgPaths
    $releaseText = (ConvertTo-DeterministicJson $releaseObject) + "`n"
    $releasePath = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ReleaseManifestName'])
    Write-TextFile $releasePath $releaseText
    $Final['ReleaseManifestPath'] = $releasePath
    $Final['ReleaseManifestSha256'] = Get-Sha256File $releasePath

    $externalSumsText = New-ReleaseSumsText $Final
    $externalSumsPath = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ExternalSumsName'])
    Write-TextFile $externalSumsPath $externalSumsText
    $Final['ExternalSumsPath'] = $externalSumsPath
    $Final['ExternalSumsSha256'] = Get-Sha256File $externalSumsPath

    # verify the external identity: sums cover exactly the release assets (not itself)
    $parsed = Read-ReleaseSumsFile $externalSumsPath
    $expectedNames = Sort-Ordinal @($script:Frozen['ZipName'], ($script:Frozen['ZipName'] + '.sha256'), $script:Frozen['ReleaseDocName'], $script:Frozen['ReleaseManifestName'])
    Assert-Condition ((Test-StringArrayEqual (Sort-Ordinal @($parsed.Keys)) $expectedNames)) 'release.sumsFileSet' `
        ("external release SHA256SUMS.txt lists exactly the release assets: " + ($expectedNames -join ', ')) `
        'external release SHA256SUMS.txt file set is unexpected'
    $issues = New-Object System.Collections.ArrayList
    foreach ($name in $expectedNames) {
        $full = [System.IO.Path]::Combine($script:OutRoot, $name)
        if (-not [System.IO.File]::Exists($full)) { [void]$issues.Add("$name (missing)"); continue }
        if ([string]$parsed[$name] -cne (Get-Sha256File $full)) { [void]$issues.Add($name) }
    }
    Assert-Condition ($issues.Count -eq 0) 'release.sumsHashes' `
        'external release SHA256SUMS.txt hashes match the release assets' `
        ("external release SHA256SUMS.txt hash mismatches: " + ($issues -join ', '))

    # verify the release identity document against the actual artifacts
    $identityIssues = New-Object System.Collections.ArrayList
    $releaseInfo = $releaseObject['candidatePackage']
    if ([string]$releaseInfo['zipSha256'] -cne $zipSha) { [void]$identityIssues.Add('zipSha256') }
    if ([int64]$releaseInfo['zipBytes'] -ne [int64]$Final['ZipBytes']) { [void]$identityIssues.Add('zipBytes') }
    if ([string]$releaseInfo['internalSums']['sha256'] -cne (Get-Sha256File ([System.IO.Path]::Combine($script:RepoRoot, 'SHA256SUMS.txt')))) { [void]$identityIssues.Add('internalSums.sha256') }
    if ([string]$releaseInfo['manifest']['sha256'] -cne (Get-Sha256File ([System.IO.Path]::Combine($script:RepoRoot, 'manifest.json')))) { [void]$identityIssues.Add('manifest.sha256') }
    if ([string]$releaseInfo['upgradeData']['sha256'] -cne (Get-Sha256File ([System.IO.Path]::Combine($script:RepoRoot, $script:Frozen['MetadataRel'].Replace('/', '\'))))) { [void]$identityIssues.Add('upgradeData.sha256') }
    if ([int64]$releaseInfo['payloadFileCount'] -ne [int64]$script:PayloadEntries.Count) { [void]$identityIssues.Add('payloadFileCount') }
    if ([int64]$releaseInfo['zipEntryCount'] -ne [int64]$Final['ZipEntryCount']) { [void]$identityIssues.Add('zipEntryCount') }
    Assert-Condition ($identityIssues.Count -eq 0) 'release.identityConsistent' `
        'external RELEASE_MANIFEST.json identity matches the actual ZIP / manifest / sums / metadata artifacts' `
        ("external RELEASE_MANIFEST.json inconsistencies: " + ($identityIssues -join ', '))

    Add-Validation 'release.assets' 'PASS' `
        ("release assets written to OutDir: " + $script:Frozen['ZipName'] + ', ' + $script:Frozen['ZipName'] + '.sha256, ' + $script:Frozen['ReleaseDocName'] + ', ' + $script:Frozen['ReleaseManifestName'] + ', ' + $script:Frozen['ExternalSumsName'])
}

function Read-ReleaseSumsFile([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { Fail "release checksum list not found: '$Path'" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Fail 'release SHA256SUMS.txt must be UTF-8 without BOM' }
    $text = Get-Utf8TextFromBytes $bytes
    if ($text.Contains("`r")) { Fail 'release SHA256SUMS.txt must use LF line endings only' }
    if (-not $text.EndsWith("`n")) { Fail 'release SHA256SUMS.txt must end with a final newline' }
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($line in @($text.Split([char]"`n") | Where-Object { $_.Length -gt 0 })) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { Fail "release SHA256SUMS.txt line has invalid format: '$line'" }
        $name = $Matches[2]
        if ($name.Contains('/') -or $name.Contains('\')) { Fail "release SHA256SUMS.txt must list flat release-asset names, got '$name'" }
        if ($map.Contains($name)) { Fail "release SHA256SUMS.txt lists '$name' more than once" }
        $map[$name] = $Matches[1]
    }
    return $map
}

# =============================================================================================
# 8b. Final-gate helpers: ZIP == repo tree, static suites, clean-clone reproducibility
# =============================================================================================
function Invoke-NodeCapture([string[]]$NodeArgs, [string]$WorkingDir) {
    $result = @{ available = $false; exit = -1; output = '' }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) { return $result }
    $result['available'] = $true
    $prevEap = $ErrorActionPreference
    Push-Location -LiteralPath $WorkingDir
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $node.Source @NodeArgs 2>&1 | Out-String
        $result['exit'] = $LASTEXITCODE
        $result['output'] = $out
    }
    finally {
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
    return $result
}

function Read-ChecksReport([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    try {
        return ((Get-Utf8TextFromBytes ([System.IO.File]::ReadAllBytes($Path))) | ConvertFrom-Json)
    }
    catch { return $null }
}

function Assert-StaticGates($Final) {
    $gateRoot = Join-Path $script:WorkRoot 'static-gates'
    Reset-Directory $gateRoot $script:RepoParent
    if ($null -eq (Get-Command node -ErrorAction SilentlyContinue)) {
        if ($SkipNode) {
            Add-Validation 'D12.staticGate' 'WARN' 'node is unavailable: static suites were not executed (NOT TESTED, never PASS)'
            return
        }
        Fail 'node is unavailable: the authoritative -RequireComplete build requires node for the static gates'
    }

    # The static suites must judge the package as SHIPPED (the extracted archive), not the
    # development repo: the repo has git-only files (.gitattributes, .git/) that are
    # correctly absent from the package, and `--check` must be proven on the shipped tree.
    $zipPath = [string]$Final['ZipPath']
    if (-not [System.IO.File]::Exists($zipPath)) { $zipPath = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ZipName']) }
    Assert-Condition ([System.IO.File]::Exists($zipPath)) 'D12.staticGate.zip' `
        "static gates run against the extracted final ZIP: $zipPath" `
        "static gates cannot run: the final ZIP is missing ('$zipPath')"
    $staticRoot = Join-Path $gateRoot 'extracted'
    Ensure-Directory $staticRoot
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $staticRoot)
    }
    catch {
        Fail "could not extract the final ZIP for the static gates: $($_.Exception.Message)"
    }
    finally { $ErrorActionPreference = $prevEap }

    $checkResult = Invoke-NodeCapture @('tools\build_manifest.mjs', '--check') $staticRoot
    Assert-Condition ($checkResult['exit'] -eq 0) 'D12.manifestCheck' `
        'node tools/build_manifest.mjs --check: manifest.json is current in the extracted package' `
        ("node tools/build_manifest.mjs --check failed (exit $($checkResult['exit'])): " + $checkResult['output'])

    $staticReport = Join-Path $gateRoot 'static-package-report.json'
    $staticResult = Invoke-NodeCapture @('tests\test_static_package.mjs', '--json', '--write-report', $staticReport) $staticRoot
    $staticJson = Read-ChecksReport $staticReport
    if ($null -eq $staticJson) {
        Assert-Condition $false 'D12.staticSuite' 'tests/test_static_package.mjs produced a machine report' `
            ("tests/test_static_package.mjs produced no JSON report (exit $($staticResult['exit'])): " + (($staticResult['output'] -split "`n" | Select-Object -Last 3) -join ' | '))
    }
    else {
        $staticFails = @($staticJson.checks | Where-Object { $_.status -eq 'FAIL' })
        Assert-Condition ($staticResult['exit'] -eq 0 -and $staticFails.Count -eq 0) 'D12.staticSuite' `
            ("tests/test_static_package.mjs: {0} check(s) PASS, 0 FAIL in the extracted package" -f @($staticJson.checks | Where-Object { $_.status -eq 'PASS' }).Count) `
            ("tests/test_static_package.mjs failures: " + (($staticFails | ForEach-Object { $_.id + ': ' + $_.detail }) -join '; '))
    }

    $unifiedReport = Join-Path $gateRoot 'unified-package-report.json'
    $unifiedResult = Invoke-NodeCapture @('tests\test_unified_package.mjs', '--json', '--write-report', $unifiedReport, '--package-root', $staticRoot) $staticRoot
    $unifiedJson = Read-ChecksReport $unifiedReport
    if ($null -eq $unifiedJson) {
        Assert-Condition $false 'D12.unifiedSuite' 'tests/test_unified_package.mjs produced a machine report' `
            ("tests/test_unified_package.mjs produced no JSON report (exit $($unifiedResult['exit'])): " + (($unifiedResult['output'] -split "`n" | Select-Object -Last 3) -join ' | '))
    }
    else {
        $unifiedFails = @($unifiedJson.checks | Where-Object { $_.status -eq 'FAIL' })
        Assert-Condition ($unifiedResult['exit'] -eq 0 -and $unifiedFails.Count -eq 0) 'D12.unifiedSuite' `
            ("tests/test_unified_package.mjs: {0} check(s) PASS, 0 FAIL (package hash graph re-derived independently in the extracted package)" -f @($unifiedJson.checks | Where-Object { $_.status -eq 'PASS' }).Count) `
            ("tests/test_unified_package.mjs failures: " + (($unifiedFails | ForEach-Object { $_.id + ': ' + $_.detail }) -join '; '))
    }

    foreach ($reportPath in @($staticReport, $unifiedReport)) {
        if ([System.IO.File]::Exists($reportPath)) {
            [System.IO.File]::Copy($reportPath, (Join-Path $script:EvidenceRoot ([System.IO.Path]::GetFileName($reportPath))), $true)
        }
    }
    $script:StaticGateStatus = 'PASS'
}

function Assert-ZipMatchesRepoTree($Final, $pkgPaths) {
    $issues = New-Object System.Collections.ArrayList
    $zipPath = [string]$Final['ZipPath']
    if (-not [System.IO.File]::Exists($zipPath)) {
        $zipPath = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ZipName'])
    }
    Assert-Condition ([System.IO.File]::Exists($zipPath)) 'D5.zip.present' "candidate ZIP present for the ZIP-vs-repo comparison: $zipPath" "candidate ZIP missing for the ZIP-vs-repo comparison: '$zipPath'"
    $zipInfo = Read-ProducedZip $zipPath 'final'
    $expected = Sort-Ordinal @(@($pkgPaths) + @('SHA256SUMS.txt'))
    $actual = Sort-Ordinal @($zipInfo['Files'].Keys)
    if (-not (Test-StringArrayEqual $actual $expected)) {
        $onlyZip = @($actual | Where-Object { $expected -notcontains $_ })
        $onlyRepo = @($expected | Where-Object { $actual -notcontains $_ })
        [void]$issues.Add("entry set mismatch (zip-only=[$($onlyZip -join ', ')] repo-only=[$($onlyRepo -join ', ')])")
    }
    foreach ($rel in $expected) {
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        if (-not [System.IO.File]::Exists($full)) { [void]$issues.Add("repo file missing '$rel'"); continue }
        if (-not $zipInfo['Files'].Contains($rel)) { [void]$issues.Add("ZIP entry missing '$rel'"); continue }
        if ([string]$zipInfo['Files'][$rel]['sha'] -cne (Get-Sha256File $full)) { [void]$issues.Add("ZIP/repo bytes differ '$rel'") }
        if ([int64]$zipInfo['Files'][$rel]['bytes'] -ne (New-Object System.IO.FileInfo($full)).Length) { [void]$issues.Add("ZIP/repo size differs '$rel'") }
    }
    Assert-Condition ($issues.Count -eq 0) 'D5.zipMatchesRepo' `
        ("every file in the candidate ZIP is byte-identical to the candidate repo tree (same set, no extras/missing): {0} files" -f $expected.Count) `
        ("ZIP-vs-repo mismatch: " + ($issues -join '; '))
    $script:ZipVsRepoStatus = 'PASS'
}

function Invoke-CleanCloneCheck($Final, $Pass) {
    $cloneRoot = Join-Path $script:WorkRoot 'clean-clone'
    Reset-Directory $cloneRoot $script:RepoParent
    $cloneRepo = Join-Path $cloneRoot 'PUBLIC_REPO_CANDIDATE'
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { Fail 'git is unavailable: the authoritative -RequireComplete build requires git for the clean-clone reproducibility proof' }

    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $statusOut = (& $git.Source -C $script:RepoRoot status --porcelain 2>&1 | Out-String)
        $headOut = (& $git.Source -C $script:RepoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
    }
    finally { $ErrorActionPreference = $prevEap }
    Assert-Condition ($statusOut.Trim() -eq '') 'D8.gitClean' `
        ("candidate repo git status is clean at HEAD $headOut (committed tree == built tree)") `
        ("candidate repo has uncommitted changes; commit the final tree before the authoritative build. git status: " + $statusOut.Trim())

    try {
        $ErrorActionPreference = 'Continue'
        $cloneOut = (& $git.Source clone --no-hardlinks --quiet $script:RepoRoot $cloneRepo 2>&1 | Out-String)
        $cloneExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    Assert-Condition ($cloneExit -eq 0 -and [System.IO.Directory]::Exists((Join-Path $cloneRepo 'tools'))) 'D8.cleanClone' `
        "clean clone created: $cloneRepo" `
        ("git clone failed (exit $cloneExit): " + $cloneOut)

    $cloneBuilder = Join-Path $cloneRepo 'tools\build_unified_release.ps1'
    Assert-Condition ([System.IO.File]::Exists($cloneBuilder)) 'D8.cleanClone.builder' 'committed builder present in the clean clone' 'tools/build_unified_release.ps1 missing from the clean clone'
    $cloneOutDir = Join-Path $cloneRoot 'release'
    $cloneWorkDir = Join-Path $cloneRoot 'build'
    $cloneEvidence = Join-Path $cloneRoot 'evidence'
    $childArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cloneBuilder,
        '-Rc2Zip', (Get-NormalizedPath $Rc2Zip),
        '-Rc3FrozenZip', (Get-NormalizedPath $Rc3FrozenZip),
        '-Repo', $cloneRepo,
        '-OutDir', $cloneOutDir,
        '-WorkDir', $cloneWorkDir,
        '-EvidenceDir', $cloneEvidence
    )
    if ($SkipNode) { $childArgs += '-SkipNode' }
    Write-Host '  running the full builder against the clean clone...'
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $childOutput = & powershell.exe @childArgs 2>&1 | Out-String
        $childExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    Assert-Condition ($childExit -eq 0) 'D8.cleanCloneBuild' `
        'the full builder succeeded against the clean clone' `
        ("the builder failed against the clean clone (exit $childExit): " + (($childOutput -split "`n" | Select-Object -Last 8) -join ' | '))

    $cloneZip = Join-Path $cloneOutDir $script:Frozen['ZipName']
    Assert-Condition ([System.IO.File]::Exists($cloneZip)) 'D8.cleanCloneZip' 'clean clone produced a candidate ZIP' "clean clone did not produce '$cloneZip'"
    $cloneZipSha = Get-Sha256File $cloneZip
    $cloneZipBytes = (New-Object System.IO.FileInfo($cloneZip)).Length
    $cloneIdentityPath = Join-Path $cloneEvidence 'build-identity.json'
    $cloneIdentity = $null
    if ([System.IO.File]::Exists($cloneIdentityPath)) {
        try { $cloneIdentity = ((Get-Utf8TextFromBytes ([System.IO.File]::ReadAllBytes($cloneIdentityPath))) | ConvertFrom-Json) } catch { $cloneIdentity = $null }
    }
    $problems = New-Object System.Collections.ArrayList
    if ($cloneZipSha -cne [string]$Final['ZipSha256']) { [void]$problems.Add("ZIP SHA-256 (main=$($Final['ZipSha256']) clone=$cloneZipSha)") }
    if ($cloneZipBytes -ne [int64]$Final['ZipBytes']) { [void]$problems.Add('ZIP bytes') }
    if ($null -ne $cloneIdentity) {
        foreach ($field in @('manifestSha256', 'sumsSha256', 'upgradeDataSha256')) {
            if ([string]$cloneIdentity.$field -cne [string]$Pass[$field]) {
                [void]$problems.Add("$field (main=$($Pass[$field]) clone=$($cloneIdentity.$field))")
            }
        }
        if ([int64]$cloneIdentity.payloadFileCount -ne [int64]$Pass['payloadFileCount']) { [void]$problems.Add('payloadFileCount') }
        if ([int64]$cloneIdentity.zipEntryCount -ne [int64]$Pass['zipEntryCount']) { [void]$problems.Add('zipEntryCount') }
        if ([int64]$cloneIdentity.changedFileCount -ne [int64]$Pass['changedFileCount']) { [void]$problems.Add('changedFileCount') }
        if ([int64]$cloneIdentity.addedFileCount -ne [int64]$Pass['addedFileCount']) { [void]$problems.Add('addedFileCount') }
    }
    else {
        Add-Validation 'D8.cleanCloneIdentity' 'WARN' 'the clean-clone build wrote no build-identity.json; ZIP equality is still checked'
    }
    Assert-Condition ($problems.Count -eq 0) 'D8.cleanCloneReproducible' `
        ("CLEAN_CLONE_REPRODUCIBLE=PASS: the committed candidate tree (HEAD {0}) rebuilds the identical candidate ZIP ({1} bytes, SHA-256 {2}); manifest/SHA256SUMS/upgrade-data hashes also identical" -f $headOut, $cloneZipBytes, $cloneZipSha) `
        ("clean-clone build differs from the main build: " + ($problems -join '; '))
    $cloneRecord = [ordered]@{
        tool                = 'cnki-portable-unified-builder'
        status              = 'PASS'
        cloneRepo           = $cloneRepo
        cloneHead           = $headOut
        gitStatusClean      = $true
        cloneZipBytes       = [int64]$cloneZipBytes
        cloneZipSha256      = $cloneZipSha
        mainZipBytes        = [int64]$Final['ZipBytes']
        mainZipSha256       = [string]$Final['ZipSha256']
        identical           = $true
    }
    Write-TextFile (Join-Path $script:WorkRoot 'clean-clone-reproducibility.json') ((ConvertTo-DeterministicJson $cloneRecord) + "`n")
    Write-TextFile (Join-Path $script:EvidenceRoot 'clean-clone-reproducibility.json') ((ConvertTo-DeterministicJson $cloneRecord) + "`n")
    $script:CleanCloneStatus = 'PASS'
    $script:Report['cleanClone'] = $cloneRecord
}

# =============================================================================================
# 9. Build driver
# =============================================================================================
function Initialize-Build {
    $repoInput = $Repo
    if ([string]::IsNullOrWhiteSpace($repoInput)) { $repoInput = Split-Path -Parent (Split-Path -Parent $script:ScriptPath) }
    $script:RepoRoot = Get-NormalizedPath (Resolve-FullPath $repoInput)
    $script:RepoParent = Get-NormalizedPath (Split-Path -Parent $script:RepoRoot)
    $script:OutRoot = $OutDir
    if ([string]::IsNullOrWhiteSpace($script:OutRoot)) { $script:OutRoot = Join-Path $script:RepoParent 'RELEASE_ASSETS_CANDIDATE' }
    $script:OutRoot = Get-NormalizedPath $script:OutRoot
    $script:WorkRoot = $WorkDir
    if ([string]::IsNullOrWhiteSpace($script:WorkRoot)) { $script:WorkRoot = Join-Path $script:RepoParent '_build\unified-build' }
    $script:WorkRoot = Get-NormalizedPath $script:WorkRoot
    $script:DistRoot = $DistDir
    if ([string]::IsNullOrWhiteSpace($script:DistRoot)) { $script:DistRoot = Join-Path $script:RepoRoot 'dist' }
    $script:DistRoot = Get-NormalizedPath $script:DistRoot
    $script:EvidenceRoot = $EvidenceDir
    if ([string]::IsNullOrWhiteSpace($script:EvidenceRoot)) { $script:EvidenceRoot = Join-Path $script:RepoParent '_evidence\build' }
    $script:EvidenceRoot = Get-NormalizedPath $script:EvidenceRoot

    # script must live inside <Repo>\tools
    $toolsDir = [System.IO.Path]::Combine($script:RepoRoot, 'tools')
    Assert-Condition (Test-PathUnder $script:ScriptPath $toolsDir) 'A5.scriptLocation' `
        "builder lives inside '<Repo>\tools\': $($script:ScriptPath)" `
        "this build script must live inside '<Repo>\tools\' (script='$($script:ScriptPath)', repo='$($script:RepoRoot)')"

    # never build into the candidate repo or into a frozen tree
    Assert-Condition (-not (Test-PathUnder $script:OutRoot $script:RepoRoot) -and -not (Test-PathUnder $script:RepoRoot $script:OutRoot)) 'A7.outDirSafety' `
        "OutDir is outside the candidate repo: $($script:OutRoot)" `
        'OutDir must not be inside the candidate repo (it would pollute the payload walk / --check)'
    Assert-Condition (-not (Test-PathUnder $script:WorkRoot $script:RepoRoot)) 'A7.workDirSafety' `
        "WorkDir is outside the candidate repo: $($script:WorkRoot)" `
        'WorkDir must not be inside the candidate repo'
    Assert-Condition (-not (Test-PathUnder $script:EvidenceRoot $script:RepoRoot)) 'A7.evidenceDirSafety' `
        "EvidenceDir is outside the candidate repo: $($script:EvidenceRoot)" `
        'EvidenceDir must not be inside the candidate repo'
    Assert-Condition (Test-PathUnder $script:DistRoot $script:RepoRoot) 'A7.distDirSafety' `
        "DistDir is inside the candidate repo (gitignored dist/): $($script:DistRoot)" `
        'DistDir must be the candidate repo dist/ directory'
    Assert-Condition (-not [string]::Equals($script:RepoRoot, $script:RepoParent, [System.StringComparison]::OrdinalIgnoreCase)) 'A7.repoRoot' 'candidate repo root resolved' 'invalid repo/parent relationship'
    Assert-Condition (-not (Test-PathUnder (Get-NormalizedPath $Rc2Zip) $script:RepoRoot) -and -not (Test-PathUnder (Get-NormalizedPath $Rc3FrozenZip) $script:RepoRoot)) 'A7.frozenInputsOutsideRepo' `
        'frozen input ZIPs are outside the candidate repo (read-only inputs)' `
        'frozen input ZIPs must not live inside the candidate repo'

    $versionPath = [System.IO.Path]::Combine($script:RepoRoot, 'VERSION')
    Assert-Condition ([System.IO.File]::Exists($versionPath)) 'A5.version' 'VERSION present in the candidate repo' 'VERSION is missing from the candidate repo'
    $versionText = (Get-Utf8TextFromBytes ([System.IO.File]::ReadAllBytes($versionPath))).Trim()
    Assert-Condition ($versionText -ceq $script:Frozen['Rc3Version']) 'A5.versionValue' `
        "VERSION is $($script:Frozen['Rc3Version']) (candidate keeps the frozen version; only the ZIP name carries -unified-candidate)" `
        "VERSION is '$versionText', expected '$($script:Frozen['Rc3Version'])'"
    $portablePath = [System.IO.Path]::Combine($script:RepoRoot, 'tools\portable.ps1')
    Assert-Condition ([System.IO.File]::Exists($portablePath)) 'A5.portable' 'tools/portable.ps1 present (frozen installer payload)' 'tools/portable.ps1 missing (frozen core)'

    Ensure-Directory $script:WorkRoot
    Ensure-Directory $script:EvidenceRoot
    $script:Mode = 'full'
    if ($VerifyOnly -and $NoZip) { $script:Mode = 'verify-data-only' }
    elseif ($VerifyOnly) { $script:Mode = 'verify-only' }
    elseif ($NoZip) { $script:Mode = 'data-only' }
    $script:IntermediateBuild = ($script:Mode -eq 'data-only') -or ($script:Mode -eq 'verify-data-only')

    $freeSpace = $null
    try {
        $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($script:RepoRoot))
        $freeSpace = [int64]$drive.AvailableFreeSpace
        Assert-Condition ($freeSpace -ge (100MB)) 'A9.disk' "free disk space $([math]::Round($freeSpace / 1MB, 1)) MB on the build volume" "free disk space is below 100 MB ($freeSpace bytes)"
    }
    catch {
        Add-Validation 'A9.disk' 'WARN' 'could not determine free disk space'
    }

    $command = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $script:ScriptPath + '"'
    $command += ' -Rc2Zip "' + (Get-NormalizedPath $Rc2Zip) + '"'
    $command += ' -Rc3FrozenZip "' + (Get-NormalizedPath $Rc3FrozenZip) + '"'
    $command += ' -Repo "' + $script:RepoRoot + '"'
    $command += ' -OutDir "' + $script:OutRoot + '"'
    if ($VerifyOnly) { $command += ' -VerifyOnly' }
    if ($NoZip) { $command += ' -NoZip' }
    if ($ReproCheck) { $command += ' -ReproCheck' }
    if ($SkipNode) { $command += ' -SkipNode' }
    if ($RequireComplete) { $command += ' -RequireComplete' }
    if ($RunStaticGate) { $command += ' -RunStaticGate' }
    if ($CleanCloneCheck) { $command += ' -CleanCloneCheck' }
    if (-not [string]::IsNullOrWhiteSpace($Zip)) { $command += ' -Zip "' + (Get-NormalizedPath $Zip) + '"' }
    $script:CommandText = $command

    $initialManifestPath = [System.IO.Path]::Combine($script:RepoRoot, 'manifest.json')
    $initialManifestSha = $null
    if ([System.IO.File]::Exists($initialManifestPath)) { $initialManifestSha = Get-Sha256File $initialManifestPath }
    $script:Report = [ordered]@{
        schemaVersion  = 1
        tool           = 'cnki-portable-unified-builder'
        toolVersion    = $script:Frozen['UpgraderVersion']
        status         = 'RUNNING'
        mode           = $script:Mode
        intermediate   = [bool]$script:IntermediateBuild
        command        = $command
        startedAtUtc   = $script:StartedAtUtc.ToString('o')
        finishedAtUtc  = $null
        exitCode       = $null
        repo           = $script:RepoRoot
        repoParent     = $script:RepoParent
        outDir         = $script:OutRoot
        distDir        = $script:DistRoot
        workDir        = $script:WorkRoot
        evidenceDir    = $script:EvidenceRoot
        scriptPath     = $script:ScriptPath
        host           = [ordered]@{
            psVersion = $PSVersionTable.PSVersion.ToString()
            os        = [System.Environment]::OSVersion.VersionString
            clr       = [System.Environment]::Version.ToString()
            node      = $null
        }
        inputs         = [ordered]@{}
        frozenIdentity = [ordered]@{}
        changeSet      = [ordered]@{}
        packages       = [ordered]@{}
        passes         = New-Object System.Collections.ArrayList
        reproducibility = [ordered]@{}
        release        = [ordered]@{}
        validations    = New-Object System.Collections.ArrayList
        errors         = New-Object System.Collections.ArrayList
    }
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($null -ne $nodeCmd) { $script:Report['host']['node'] = (& $nodeCmd.Source --version 2>$null | Out-String).Trim() }
    Write-Host '======================================================================'
    Write-Host ' CNKI Research Portable unified RC3 candidate build'
    Write-Host " mode=$($script:Mode)  reproCheck=$([bool]$ReproCheck)  complete=$([bool]$RequireComplete)"
    Write-Host " repo=$($script:RepoRoot)"
    Write-Host " outDir=$($script:OutRoot)"
    Write-Host " workDir=$($script:WorkRoot)"
    Write-Host '======================================================================'
}

function Invoke-BuildPass([string]$Label, [string]$PassRoot) {
    $passRecord = [ordered]@{
        label    = $Label
        passRoot = $PassRoot
        payloadFileCount = 0
        packageFileCount = 0
        zipEntryCount    = 0
        upgradeDataSha256 = ''
        manifestSha256    = ''
        sumsSha256        = ''
        zipSha256         = ''
        zipBytes          = [int64]0
        zipPath           = ''
        changedFileCount  = 0
        addedFileCount    = 0
        changedFileSetHash = ''
        payloadSetHash     = ''
    }
    Write-Host ''
    Write-Host "--- [$Label] 1/6 payload walk + frozen-core equality ---"
    $payloadEntries = Get-PayloadWalk $script:RepoRoot
    $script:PayloadEntries = $payloadEntries
    Assert-Condition ($payloadEntries.Count -gt 0) "$Label.payload.nonEmpty" "payload walk found $($payloadEntries.Count) file(s)" 'payload walk found no files'
    [void](Assert-PayloadHygiene $payloadEntries)
    [void](Assert-NoDevPaths $payloadEntries)
    $changeInfo = Test-CoreEqualityAndChangeSet $payloadEntries $script:ModelRc2 $script:ModelRc3
    $script:Report['changeSet'] = $changeInfo

    if ($RequireComplete) {
        Assert-Condition ($changeInfo['missingExpected'].Count -eq 0) 'B5.expectedNewFiles' `
            "all $($script:ExpectedNewPayloadFiles.Count) expected new payload files are present" `
            ("full build requires every expected new payload file; missing: " + ($changeInfo['missingExpected'] -join ', '))
        Assert-Condition ($changeInfo['unexpectedAdds'].Count -eq 0) 'B5.noUnexpectedAdds' `
            'no payload file outside the approved new-file list was added' `
            ("unexpected added payload files (Lead approval required): " + ($changeInfo['unexpectedAdds'] -join ', '))
        Assert-Condition ($payloadEntries.Count -eq $script:Frozen['ExpectedPayloadCountFull']) 'B5.payloadCount' `
            "payload file count is exactly $($script:Frozen['ExpectedPayloadCountFull']) (107 frozen + 8 new)" `
            "payload file count is $($payloadEntries.Count), expected $($script:Frozen['ExpectedPayloadCountFull'])"
        Assert-Condition ($changeInfo['addedVersusRc3'].Count -eq $script:Frozen['ExpectedAddCountFull']) 'B5.addCount' `
            "added payload file count is exactly $($script:Frozen['ExpectedAddCountFull'])" `
            "added payload file count is $($changeInfo['addedVersusRc3'].Count), expected $($script:Frozen['ExpectedAddCountFull'])"
    }
    else {
        if ($changeInfo['missingExpected'].Count -gt 0) {
            Add-Validation 'B5.expectedNewFiles' 'WARN' ("intermediate build: expected new payload files not present yet: " + ($changeInfo['missingExpected'] -join ', '))
        }
        else {
            Add-Validation 'B5.expectedNewFiles' 'PASS' "all $($script:ExpectedNewPayloadFiles.Count) expected new payload files are present"
        }
        if ($changeInfo['unexpectedAdds'].Count -gt 0) {
            Add-Validation 'B5.noUnexpectedAdds' 'WARN' ("intermediate build: payload files outside the approved new-file list: " + ($changeInfo['unexpectedAdds'] -join ', '))
        }
    }

    Write-Host ''
    Write-Host "--- [$Label] 2/6 regenerate manifest.json (node tools/build_manifest.mjs) ---"
    Invoke-ManifestGenerator $Label
    $manifestModel = Test-ManifestAgainstTree $payloadEntries
    Assert-Condition ($manifestModel['Map'].Count -eq $payloadEntries.Count) "$Label.manifest.count" `
        "manifest.json lists exactly the $($payloadEntries.Count) payload file(s)" `
        "manifest.json lists $($manifestModel['Map'].Count) file(s) but the payload walk found $($payloadEntries.Count)"

    Write-Host ''
    Write-Host "--- [$Label] 3/6 generate upgrade-data/rc2-to-rc3.json (schemaVersion 2) ---"
    Assert-UpgradeDataInputs
    $hotfix = Get-HotfixDerivation $script:ModelRc2 $script:ModelRc3
    $built = New-UpgradeDataObject $payloadEntries $manifestModel $changeInfo $hotfix
    Test-UpgradeDataConsistency $built $payloadEntries $manifestModel $hotfix
    $metaPath = [System.IO.Path]::Combine($script:RepoRoot, $script:Frozen['MetadataRel'].Replace('/', '\'))
    Write-TextFile $metaPath ([string]$built['JsonText'])
    Test-UpgradeDataOnDisk $built
    Assert-PackageMetadataLayout
    $passRecord['changedFileCount'] = [int64]$built['Object']['changedFileCount']
    $passRecord['addedFileCount'] = [int64]$built['Object']['addedFileCount']
    $passRecord['changedFileSetHash'] = [string]$built['ChangedFileSetHash']
    $passRecord['payloadSetHash'] = [string]$built['PayloadSetHash']
    Add-Validation "$Label.metadata" 'PASS' `
        ("upgrade-data/rc2-to-rc3.json generated: {0} bytes, SHA-256 {1}, payload={2}, changed={3}, adds={4}" -f $built['Bytes'].Length, (Get-Sha256Bytes $built['Bytes']), $built['Object']['payloadFileCount'], $built['Object']['changedFileCount'], $built['Object']['addedFileCount'])

    Write-Host ''
    Write-Host "--- [$Label] 4/6 generate SHA256SUMS.txt (trust root) ---"
    $pkgPaths = Get-PackageFileSet $payloadEntries
    $sumsText = New-Sha256SumsText $script:RepoRoot $pkgPaths
    $sumsPath = [System.IO.Path]::Combine($script:RepoRoot, 'SHA256SUMS.txt')
    Write-TextFile $sumsPath $sumsText
    $sums = Read-Sha256SumsFile $sumsPath $Label
    Test-SumsAgainstPackage $sums $pkgPaths
    Assert-Condition ((Test-StringArrayEqual (Sort-Ordinal @($sums['Map'].Keys)) (Sort-Ordinal $pkgPaths))) "$Label.sums.set" `
        "SHA256SUMS.txt lists every package file except itself ($($pkgPaths.Count) entries)" `
        'SHA256SUMS.txt file set mismatch'

    Write-Host ''
    Write-Host "--- [$Label] 5/6 hash-closure / cycle assertions ---"
    Test-ClosureGraph $pkgPaths $sums $manifestModel $built

    if ($script:Mode -eq 'data-only' -or $script:Mode -eq 'verify-data-only') {
        $passRecord['payloadFileCount'] = [int64]$payloadEntries.Count
        $passRecord['packageFileCount'] = [int64]$pkgPaths.Count
        $passRecord['upgradeDataSha256'] = Get-Sha256File $metaPath
        $passRecord['manifestSha256'] = [string]$manifestModel['Sha256']
        $passRecord['sumsSha256'] = Get-Sha256File $sumsPath
        Add-Validation "$Label.dataOnly" 'PASS' 'data-only build completed: payload + manifest.json + upgrade-data + SHA256SUMS.txt; no ZIP produced'
        Assert-TreeStable $payloadEntries ([string]$passRecord['manifestSha256']) ([string]$passRecord['sumsSha256']) ([string]$passRecord['upgradeDataSha256']) $Label
        return $passRecord
    }

    Write-Host ''
    Write-Host "--- [$Label] 6/6 deterministic ZIP (two independent builds) ---"
    $zipPaths = Sort-Ordinal @(@($pkgPaths) + @('SHA256SUMS.txt'))
    $zipProof = Build-ZipProof $PassRoot $Label $zipPaths
    $passRecord['payloadFileCount'] = [int64]$payloadEntries.Count
    $passRecord['packageFileCount'] = [int64]$pkgPaths.Count
    $passRecord['zipEntryCount'] = [int64]$zipProof['EntryCount']
    $passRecord['upgradeDataSha256'] = Get-Sha256File $metaPath
    $passRecord['manifestSha256'] = [string]$manifestModel['Sha256']
    $passRecord['sumsSha256'] = Get-Sha256File $sumsPath
    $passRecord['zipSha256'] = [string]$zipProof['Sha256']
    $passRecord['zipBytes'] = [int64]$zipProof['Bytes']
    $passRecord['zipPath'] = [string]$zipProof['Path']
    Assert-TreeStable $payloadEntries ([string]$passRecord['manifestSha256']) ([string]$passRecord['sumsSha256']) ([string]$passRecord['upgradeDataSha256']) $Label
    return $passRecord
}

function Assert-FrozenInputsUnchanged($rc2Identity, $rc3Identity) {
    $sha1 = Get-Sha256File $rc2Identity['path']
    $sha2 = Get-Sha256File $rc3Identity['path']
    $ok = ($sha1 -ceq $script:Frozen['Rc2ZipSha256']) -and ($sha2 -ceq $script:Frozen['Rc3ZipSha256'])
    Assert-Condition $ok 'A7.frozenUnchanged' `
        'frozen input ZIPs are byte-unchanged after the build (read-only inputs respected)' `
        'frozen input ZIPs changed during the build (HARD RULE VIOLATION)'
}

# A release build must run against a frozen tree. If any payload file or generated file is
# written while the build runs, the artifacts are internally inconsistent; detect it
# explicitly instead of silently publishing a torn package.
function Assert-TreeStable($ExpectedPayloadEntries, [string]$ExpectedManifestSha, [string]$ExpectedSumsSha, [string]$ExpectedMetaSha, [string]$Label) {
    $issues = New-Object System.Collections.ArrayList
    $now = @(Get-PayloadWalk $script:RepoRoot)
    $expectedMap = Get-EntryMap $ExpectedPayloadEntries
    $nowMap = Get-EntryMap $now
    if ($now.Count -ne @($ExpectedPayloadEntries).Count) { [void]$issues.Add("payload file count changed ($(@($ExpectedPayloadEntries).Count) -> $($now.Count))") }
    foreach ($p in $expectedMap.Keys) {
        if (-not $nowMap.ContainsKey($p)) { [void]$issues.Add("payload file disappeared '$p'"); continue }
        if ([string]$nowMap[$p]['sha256'] -cne [string]$expectedMap[$p]['sha256']) { [void]$issues.Add("payload file changed during the build '$p'") }
    }
    foreach ($p in $nowMap.Keys) { if (-not $expectedMap.ContainsKey($p)) { [void]$issues.Add("payload file appeared during the build '$p'") } }
    foreach ($pair in @(@('manifest.json', $ExpectedManifestSha), @('SHA256SUMS.txt', $ExpectedSumsSha), @($script:Frozen['MetadataRel'], $ExpectedMetaSha))) {
        $rel = [string]$pair[0]
        $expectedSha = [string]$pair[1]
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        if (-not [System.IO.File]::Exists($full)) { [void]$issues.Add("generated file missing '$rel'"); continue }
        if ((Get-Sha256File $full) -cne $expectedSha) { [void]$issues.Add("generated file changed during the build '$rel'") }
    }
    Assert-Condition ($issues.Count -eq 0) "$Label.treeStable" `
        'candidate tree stayed byte-stable for the whole build pass (payload + manifest.json + SHA256SUMS.txt + upgrade-data)' `
        ("candidate tree changed DURING the build (freeze the tree and rebuild): " + (($issues | Select-Object -First 8) -join '; '))
}

function Invoke-FullBuild {
    Write-Host ''
    Write-Host '--- [build] 1/3 validate frozen input identity ---'
    $script:ModelRc2 = Get-FrozenArchiveModel (Get-NormalizedPath $Rc2Zip) 'rc2' $script:Frozen['Rc2ZipBytes'] $script:Frozen['Rc2ZipSha256'] $script:Frozen['Rc2Version'] $script:Frozen['Rc2ManifestSha256']
    $script:ModelRc3 = Get-FrozenArchiveModel (Get-NormalizedPath $Rc3FrozenZip) 'rc3' $script:Frozen['Rc3ZipBytes'] $script:Frozen['Rc3ZipSha256'] $script:Frozen['Rc3Version'] $script:Frozen['Rc3ManifestSha256']
    $script:Report['inputs']['rc2'] = $script:ModelRc2['Identity']
    $script:Report['inputs']['rc3'] = $script:ModelRc3['Identity']
    $script:Report['frozenIdentity'] = [ordered]@{
        rc2 = [ordered]@{ bytes = [int64]$script:Frozen['Rc2ZipBytes']; sha256 = $script:Frozen['Rc2ZipSha256']; manifestSha256 = $script:Frozen['Rc2ManifestSha256']; payloadFileCount = [int64]$script:Frozen['SourcePayloadFileCount'] }
        rc3 = [ordered]@{ bytes = [int64]$script:Frozen['Rc3ZipBytes']; sha256 = $script:Frozen['Rc3ZipSha256']; manifestSha256 = $script:Frozen['Rc3ManifestSha256']; payloadFileCount = [int64]$script:Frozen['SourcePayloadFileCount'] }
    }

    # byte-identical core assertion against the extracted oracle map (per-file, from the ZIP snapshot)
    $versionEntry = $script:ModelRc3['Snapshot'].Files['VERSION']
    Assert-Condition ((Get-Sha256Bytes ([byte[]]$versionEntry['data'])) -eq $script:Frozen['Rc3VersionSha256']) 'B6.version' `
        'frozen RC3 VERSION identity confirmed (candidate keeps the target version)' `
        'frozen RC3 VERSION identity mismatch'

    Write-Host ''
    Write-Host '--- [build] 2/3 first full build pass ---'
    $pass1 = Invoke-BuildPass 'build-1' (Join-Path $script:WorkRoot 'pass-1')
    [void]$script:Report['passes'].Add($pass1)

    $pass2 = $null
    $reproducible = 'NOT TESTED'
    $cleanRebuildSha = $null
    if (-not $NoZip) {
        Write-Host ''
        Write-Host '--- [build] 3/3 second clean build pass (all generated artifacts removed first) ---'
        foreach ($rel in @('manifest.json', 'SHA256SUMS.txt', $script:Frozen['MetadataRel'])) {
            $p = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
            if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) }
        }
        Add-Validation 'D8.cleanState' 'PASS' 'generated artifacts (manifest.json, SHA256SUMS.txt, upgrade-data metadata) removed before the second build pass'
        $pass2 = Invoke-BuildPass 'build-2' (Join-Path $script:WorkRoot 'pass-2')
        [void]$script:Report['passes'].Add($pass2)
        $issues = New-Object System.Collections.ArrayList
        foreach ($field in @('upgradeDataSha256', 'manifestSha256', 'sumsSha256', 'zipSha256', 'zipBytes', 'zipEntryCount', 'payloadFileCount', 'packageFileCount', 'changedFileSetHash', 'payloadSetHash')) {
            if ([string]$pass1[$field] -cne [string]$pass2[$field]) { [void]$issues.Add("$field (build-1=$($pass1[$field]) build-2=$($pass2[$field]))") }
        }
        $reproducible = 'PASS'
        if ($issues.Count -gt 0) { $reproducible = 'FAIL' }
        Assert-Condition ($issues.Count -eq 0) 'D8.reproducibleBuild' `
            ("two full clean builds are byte-identical: ZIP {0}, manifest.json {1}, SHA256SUMS.txt {2}, upgrade-data {3}" -f $pass1['zipSha256'], $pass1['manifestSha256'], $pass1['sumsSha256'], $pass1['upgradeDataSha256']) `
            ("reproducibility FAILED: " + ($issues -join '; '))
        $cleanRebuildSha = [string]$pass2['zipSha256']
        $script:Report['reproducibility'] = [ordered]@{
            status          = $reproducible
            cleanRebuild    = $true
            generatedRemoved = $true
            upgradeDataSha256 = @($pass1['upgradeDataSha256'], $pass2['upgradeDataSha256'])
            manifestSha256    = @($pass1['manifestSha256'], $pass2['manifestSha256'])
            sumsSha256        = @($pass1['sumsSha256'], $pass2['sumsSha256'])
            zipSha256         = @($pass1['zipSha256'], $pass2['zipSha256'])
        }
    }
    else {
        Add-Validation 'D8.reproducibleBuild' 'WARN' 'data-only build: ZIP reproducibility not tested'
    }

    $final = [ordered]@{
        ZipPath            = [string]$pass1['zipPath']
        ZipBytes           = [int64]$pass1['zipBytes']
        ZipSha256          = [string]$pass1['zipSha256']
        ZipEntryCount      = [int64]$pass1['zipEntryCount']
        SecondBuildSha256  = [string]$pass1['zipSha256']
        CleanRebuildSha256 = [string]$cleanRebuildSha
        ReproducibleBuild  = $reproducible
        ChangedFileCount   = [int64]$pass1['changedFileCount']
        AddedFileCount     = [int64]$pass1['addedFileCount']
        Intermediate       = [bool]$script:IntermediateBuild
        SidecarSha256      = ''
        ReleaseDocSha256   = ''
    }

    $lastPass = $pass1
    if ($null -ne $pass2) { $lastPass = $pass2 }
    Assert-TreeStable $script:PayloadEntries ([string]$lastPass['manifestSha256']) ([string]$lastPass['sumsSha256']) ([string]$lastPass['upgradeDataSha256']) 'final'

    Write-Host ''
    Write-Host '--- [build] verify frozen inputs unchanged ---'
    [void](Assert-FrozenInputsUnchanged $script:Report['inputs']['rc2'] $script:Report['inputs']['rc3'])

    $pkgPaths = Get-PackageFileSet $script:PayloadEntries
    if ($NoZip) {
        Add-Validation 'build.dataOnly' 'PASS' 'data-only build: payload + manifest.json + upgrade-data + SHA256SUMS.txt produced; no release ZIP or external assets'
        $script:Report['release'] = [ordered]@{
            outDir = $script:OutRoot
            distDir = $script:DistRoot
            note   = 'data-only build: no release assets produced'
        }
        $script:Identity = New-IdentityObject $final @() $pass1 $reproducible
        return $final
    }

    Write-Host ''
    Write-Host '--- [build] write release assets + external identity ---'
    Write-ExternalAssets $final $pkgPaths

    Write-Host ''
    Write-Host '--- [build] final gate: ZIP tree == candidate repo tree ---'
    [void](Assert-ZipMatchesRepoTree $final $pkgPaths)

    if ($RequireComplete -or $RunStaticGate) {
        Write-Host ''
        Write-Host '--- [build] final gate: static suites (manifest --check + static package + unified package) ---'
        Assert-StaticGates $final
    }
    if ($RequireComplete -or $CleanCloneCheck) {
        Write-Host ''
        Write-Host '--- [build] final gate: clean-clone reproducibility (committed tree rebuilds identical ZIP) ---'
        Invoke-CleanCloneCheck $final $lastPass
    }
    $script:Report['release'] = [ordered]@{
        outDir             = $script:OutRoot
        distDir            = $script:DistRoot
        zipName            = $script:Frozen['ZipName']
        zipBytes           = [int64]$final['ZipBytes']
        zipSha256          = [string]$final['ZipSha256']
        zipEntryCount      = [int64]$final['ZipEntryCount']
        sidecarSha256      = [string]$final['SidecarSha256']
        releaseManifest    = [string]$final['ReleaseManifestPath']
        releaseManifestSha256 = [string]$final['ReleaseManifestSha256']
        externalSums       = [string]$final['ExternalSumsPath']
        externalSumsSha256 = [string]$final['ExternalSumsSha256']
        releaseDoc         = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ReleaseDocName'])
        releaseDocSha256   = [string]$final['ReleaseDocSha256']
        reproducibleBuild  = $reproducible
    }
    $script:Identity = New-IdentityObject $final $pkgPaths $pass1 $reproducible
    return $final
}

function Invoke-VerifyOnly {
    Write-Host ''
    Write-Host '--- [verify] 1/6 validate frozen input identity (read-only) ---'
    $script:ModelRc2 = Get-FrozenArchiveModel (Get-NormalizedPath $Rc2Zip) 'rc2' $script:Frozen['Rc2ZipBytes'] $script:Frozen['Rc2ZipSha256'] $script:Frozen['Rc2Version'] $script:Frozen['Rc2ManifestSha256']
    $script:ModelRc3 = Get-FrozenArchiveModel (Get-NormalizedPath $Rc3FrozenZip) 'rc3' $script:Frozen['Rc3ZipBytes'] $script:Frozen['Rc3ZipSha256'] $script:Frozen['Rc3Version'] $script:Frozen['Rc3ManifestSha256']

    $zipPath = $Zip
    if ([string]::IsNullOrWhiteSpace($zipPath)) {
        $candidate = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ZipName'])
        if (-not [System.IO.File]::Exists($candidate)) { $candidate = [System.IO.Path]::Combine($script:DistRoot, $script:Frozen['ZipName']) }
        $zipPath = $candidate
    }
    $zipPath = Get-NormalizedPath $zipPath
    Assert-Condition ([System.IO.File]::Exists($zipPath)) 'verify.zip.present' "candidate ZIP found: $zipPath" "candidate ZIP not found: '$zipPath'"

    Write-Host ''
    Write-Host '--- [verify] 2/6 payload walk + frozen-core equality ---'
    $payloadEntries = Get-PayloadWalk $script:RepoRoot
    $script:PayloadEntries = $payloadEntries
    [void](Assert-PayloadHygiene $payloadEntries)
    [void](Assert-NoDevPaths $payloadEntries)
    $changeInfo = Test-CoreEqualityAndChangeSet $payloadEntries $script:ModelRc2 $script:ModelRc3

    Write-Host ''
    Write-Host '--- [verify] 3/6 manifest.json is current + structurally valid (node --check, read-only) ---'
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -ne $node) {
        $manifestScript = [System.IO.Path]::Combine($script:RepoRoot, 'tools\build_manifest.mjs')
        $previous = Get-Location
        $prevEap = $ErrorActionPreference
        try {
            Set-Location -LiteralPath $script:RepoRoot
            $ErrorActionPreference = 'Continue'
            $checkOut = & $node.Source $manifestScript --check 2>&1 | Out-String
            $checkExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEap
            Set-Location -LiteralPath $previous
        }
        Assert-Condition ($checkExit -eq 0) 'verify.manifest.check' `
            ("node tools/build_manifest.mjs --check: " + $checkOut.Trim()) `
            ("node tools/build_manifest.mjs --check failed (exit $checkExit): " + $checkOut)
    }
    else {
        Add-Validation 'verify.manifest.check' 'WARN' 'node is unavailable: manifest.json is validated structurally only'
    }
    $manifestModel = Test-ManifestAgainstTree $payloadEntries

    Write-Host ''
    Write-Host '--- [verify] 4/6 re-derive upgrade-data + SHA256SUMS.txt and compare (no repo writes) ---'
    Assert-PackageMetadataLayout
    $hotfix = Get-HotfixDerivation $script:ModelRc2 $script:ModelRc3
    $built = New-UpgradeDataObject $payloadEntries $manifestModel $changeInfo $hotfix
    Test-UpgradeDataConsistency $built $payloadEntries $manifestModel $hotfix
    $metaPath = [System.IO.Path]::Combine($script:RepoRoot, $script:Frozen['MetadataRel'].Replace('/', '\'))
    Assert-Condition ([System.IO.File]::Exists($metaPath)) 'C.metadata.present' 'upgrade-data/rc2-to-rc3.json present' 'upgrade-data/rc2-to-rc3.json missing'
    $metaBytes = [System.IO.File]::ReadAllBytes($metaPath)
    Assert-Condition (Test-BytesEqual $metaBytes ([byte[]]$built['Bytes'])) 'C.metadata.deterministic' `
        ("upgrade-data/rc2-to-rc3.json is byte-identical to the deterministic re-derivation ($(Get-Sha256Bytes $metaBytes))") `
        'upgrade-data/rc2-to-rc3.json differs from the deterministic re-derivation'
    $pkgPaths = Get-PackageFileSet $payloadEntries
    $sumsPath = [System.IO.Path]::Combine($script:RepoRoot, 'SHA256SUMS.txt')
    Assert-Condition ([System.IO.File]::Exists($sumsPath)) 'D4.sums.present' 'SHA256SUMS.txt present' 'SHA256SUMS.txt missing'
    $sumsExpected = New-Sha256SumsText $script:RepoRoot $pkgPaths
    $sumsDisk = [System.IO.File]::ReadAllBytes($sumsPath)
    Assert-Condition (Test-BytesEqual $sumsDisk ($script:Utf8NoBom.GetBytes($sumsExpected))) 'D4.sums.deterministic' `
        'SHA256SUMS.txt is byte-identical to the deterministic regeneration' `
        'SHA256SUMS.txt differs from the deterministic regeneration'
    $sums = Read-Sha256SumsFile $sumsPath 'verify'
    Test-SumsAgainstPackage $sums $pkgPaths

    Write-Host ''
    Write-Host '--- [verify] 5/6 hash-closure / cycle assertions ---'
    Test-ClosureGraph $pkgPaths $sums $manifestModel $built

    if ($script:Mode -eq 'verify-data-only') {
        Add-Validation 'verify.dataOnly' 'PASS' 'data-only verification completed (payload + manifest.json + upgrade-data + SHA256SUMS.txt); no ZIP involved'
        $final = [ordered]@{
            ZipPath            = ''
            ZipBytes           = [int64]0
            ZipSha256          = ''
            ZipEntryCount      = [int64]0
            SecondBuildSha256  = ''
            CleanRebuildSha256 = ''
            ReproducibleBuild  = 'NOT TESTED (data-only)'
            ChangedFileCount   = [int64]$built['Object']['changedFileCount']
            AddedFileCount     = [int64]$built['Object']['addedFileCount']
            Intermediate       = [bool]$script:IntermediateBuild
            SidecarSha256      = ''
            ReleaseDocSha256   = ''
        }
        $passInfo = @{ upgradeDataSha256 = (Get-Sha256File $metaPath); manifestSha256 = (Get-Sha256File ([System.IO.Path]::Combine($script:RepoRoot, 'manifest.json'))); sumsSha256 = (Get-Sha256File $sumsPath); payloadFileCount = $payloadEntries.Count; packageFileCount = $pkgPaths.Count; changedFileCount = $built['Object']['changedFileCount']; addedFileCount = $built['Object']['addedFileCount'] }
        $script:Report['changeSet'] = $changeInfo
        $script:Report['reproducibility'] = [ordered]@{ status = 'NOT TESTED'; reason = 'data-only verification' }
        $script:Identity = New-IdentityObject $final @() $passInfo 'NOT TESTED (data-only)'
        return $final
    }

    Write-Host ''
    Write-Host '--- [verify] 6/6 candidate ZIP: sidecar, structure, entry set, reproducible rebuild ---'
    $zipSha = Get-Sha256File $zipPath
    $zipBytes = (New-Object System.IO.FileInfo($zipPath)).Length
    $sidecar = "$zipPath.sha256"
    if ([System.IO.File]::Exists($sidecar)) {
        $sidecarText = Get-Utf8TextFromBytes ([System.IO.File]::ReadAllBytes($sidecar))
        $recorded = $null
        if ($sidecarText -match '^([0-9a-f]{64})\s+\*(.+?)\s*$') { $recorded = $Matches[1] }
        Assert-Condition ($null -ne $recorded -and $recorded -ceq $zipSha) 'Z1.zipHash' `
            "candidate ZIP SHA-256 $zipSha matches the sidecar" `
            "candidate ZIP SHA-256 $zipSha does not match the sidecar"
    }
    else {
        Add-Validation 'Z1.zipHash' 'WARN' "no sidecar next to '$zipPath': archive identity is not anchored beside the file"
    }
    $zipPaths = Sort-Ordinal @(@($pkgPaths) + @('SHA256SUMS.txt'))
    $verifyDir = Join-Path $script:WorkRoot 'verify'
    Reset-Directory $verifyDir $script:RepoParent
    $rebuiltPath = Join-Path $verifyDir 'rebuilt.zip'
    New-DeterministicZipFile $rebuiltPath $script:RepoRoot $zipPaths
    $rebuiltSha = Get-Sha256File $rebuiltPath
    Assert-Condition ($rebuiltSha -ceq $zipSha) 'verify.zip.reproducible' `
        "candidate ZIP is byte-identical to a fresh deterministic rebuild from the current package ($rebuiltSha)" `
        "candidate ZIP is not reproducible: archive=$zipSha rebuilt=$rebuiltSha (package changed after the ZIP was built?)"
    $zipInfo = Read-ProducedZip $zipPath 'verify'
    $actualPaths = Sort-Ordinal @($zipInfo['Files'].Keys)
    $entryIssues = New-Object System.Collections.ArrayList
    if (-not (Test-StringArrayEqual $actualPaths $zipPaths)) { [void]$entryIssues.Add('entry set mismatch') }
    if ([int64]$zipInfo['EntryCount'] -ne $zipPaths.Count) { [void]$entryIssues.Add('entry count mismatch') }
    foreach ($rel in $zipPaths) {
        if (-not $zipInfo['Files'].Contains($rel)) { continue }
        $full = [System.IO.Path]::Combine($script:RepoRoot, $rel.Replace('/', '\'))
        if ([string]$zipInfo['Files'][$rel]['sha'] -cne (Get-Sha256File $full)) { [void]$entryIssues.Add("hash mismatch '$rel'") }
    }
    Assert-Condition ($entryIssues.Count -eq 0) 'Z2.zipEntries' `
        ("candidate ZIP has exactly {0} file entries and every entry matches the package bytes" -f $zipPaths.Count) `
        ("candidate ZIP problems: " + ($entryIssues -join '; '))
    Assert-Condition ($zipSha -cne $script:Frozen['Rc3ZipSha256']) 'verify.zip.newIdentity' `
        'candidate ZIP hash is a new identity (not the frozen RC3 archive hash)' `
        'candidate ZIP hash equals the frozen RC3 archive hash'

    # external identity (optional but verified when present)
    $outManifest = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ReleaseManifestName'])
    if ([System.IO.File]::Exists($outManifest)) {
        $releaseJson = $null
        try { $releaseJson = (Get-Utf8TextFromBytes ([System.IO.File]::ReadAllBytes($outManifest))) | ConvertFrom-Json }
        catch { Fail "external RELEASE_MANIFEST.json is not valid JSON: $($_.Exception.Message)" }
        $identityIssues = New-Object System.Collections.ArrayList
        if ([string]$releaseJson.candidatePackage.zipSha256 -cne $zipSha) { [void]$identityIssues.Add('candidatePackage.zipSha256') }
        if ([int64]$releaseJson.candidatePackage.zipBytes -ne [int64]$zipBytes) { [void]$identityIssues.Add('candidatePackage.zipBytes') }
        if ([string]$releaseJson.candidatePackage.manifest.sha256 -cne (Get-Sha256File ([System.IO.Path]::Combine($script:RepoRoot, 'manifest.json')))) { [void]$identityIssues.Add('candidatePackage.manifest.sha256') }
        if ([string]$releaseJson.candidatePackage.internalSums.sha256 -cne (Get-Sha256File $sumsPath)) { [void]$identityIssues.Add('candidatePackage.internalSums.sha256') }
        if ([string]$releaseJson.candidatePackage.upgradeData.sha256 -cne (Get-Sha256File $metaPath)) { [void]$identityIssues.Add('candidatePackage.upgradeData.sha256') }
        if ([int64]$releaseJson.candidatePackage.payloadFileCount -ne [int64]$payloadEntries.Count) { [void]$identityIssues.Add('candidatePackage.payloadFileCount') }
        if ([int64]$releaseJson.candidatePackage.zipEntryCount -ne [int64]$zipPaths.Count) { [void]$identityIssues.Add('candidatePackage.zipEntryCount') }
        Assert-Condition ($identityIssues.Count -eq 0) 'verify.releaseManifest' `
            'external RELEASE_MANIFEST.json matches the candidate ZIP / manifest / sums / metadata' `
            ("external RELEASE_MANIFEST.json inconsistencies: " + ($identityIssues -join ', '))
        $externalSums = [System.IO.Path]::Combine($script:OutRoot, $script:Frozen['ExternalSumsName'])
        if ([System.IO.File]::Exists($externalSums)) {
            $parsed = Read-ReleaseSumsFile $externalSums
            $sumIssues = New-Object System.Collections.ArrayList
            foreach ($name in $parsed.Keys) {
                $full = [System.IO.Path]::Combine($script:OutRoot, $name)
                if (-not [System.IO.File]::Exists($full)) { [void]$sumIssues.Add("$name (missing)"); continue }
                if ([string]$parsed[$name] -cne (Get-Sha256File $full)) { [void]$sumIssues.Add($name) }
            }
            Assert-Condition ($sumIssues.Count -eq 0) 'verify.releaseSums' `
                "external release SHA256SUMS.txt matches the release assets ($($parsed.Count) entries)" `
                ("external release SHA256SUMS.txt hash mismatches: " + ($sumIssues -join ', '))
        }
        else {
            Add-Validation 'verify.releaseSums' 'WARN' 'external release SHA256SUMS.txt not present in OutDir'
        }
    }
    else {
        Add-Validation 'verify.releaseManifest' 'WARN' 'external RELEASE_MANIFEST.json not present in OutDir (archive-only verification)'
    }

    $final = [ordered]@{
        ZipPath            = $zipPath
        ZipBytes           = [int64]$zipBytes
        ZipSha256          = [string]$zipSha
        ZipEntryCount      = [int64]$zipInfo['EntryCount']
        SecondBuildSha256  = [string]$rebuiltSha
        CleanRebuildSha256 = [string]$rebuiltSha
        ReproducibleBuild  = 'PASS (rebuilt from current package)'
        ChangedFileCount   = [int64]$built['Object']['changedFileCount']
        AddedFileCount     = [int64]$built['Object']['addedFileCount']
        Intermediate       = [bool]$script:IntermediateBuild
        SidecarSha256      = ''
        ReleaseDocSha256   = ''
    }
    $script:Report['changeSet'] = $changeInfo
    $script:Report['reproducibility'] = [ordered]@{ status = 'PASS (verify-only rebuild equality)'; rebuiltSha256 = $rebuiltSha }
    $script:Identity = New-IdentityObject $final $pkgPaths @{ upgradeDataSha256 = (Get-Sha256File $metaPath); manifestSha256 = (Get-Sha256File ([System.IO.Path]::Combine($script:RepoRoot, 'manifest.json'))); sumsSha256 = (Get-Sha256File $sumsPath); zipSha256 = $zipSha; zipBytes = $zipBytes; zipEntryCount = $zipInfo['EntryCount']; payloadFileCount = $payloadEntries.Count; packageFileCount = $pkgPaths.Count; changedFileCount = $built['Object']['changedFileCount']; addedFileCount = $built['Object']['addedFileCount'] } 'PASS (verify-only)'
    return $final
}

function New-IdentityObject($Final, $pkgPaths, $Pass, $Reproducible) {
    $change = $script:Report['changeSet']
    $identity = [ordered]@{
        ok                 = $true
        buildStatus        = 'PASS'
        mode               = $script:Mode
        intermediate       = [bool]$script:IntermediateBuild
        candidate          = $true
        version            = $script:Frozen['Rc3Version']
        variant            = 'unified-installer'
        zipName            = $script:Frozen['ZipName']
        zipPath            = [string]$Final['ZipPath']
        zipBytes           = [int64]$Final['ZipBytes']
        zipSha256          = [string]$Final['ZipSha256']
        zipEntryCount      = [int64]$Final['ZipEntryCount']
        payloadFileCount   = [int64]$Pass['payloadFileCount']
        packageFileCount   = [int64]$Pass['packageFileCount']
        manifestSha256     = [string]$Pass['manifestSha256']
        sumsSha256         = [string]$Pass['sumsSha256']
        upgradeDataPath    = $script:Frozen['MetadataRel']
        upgradeDataSha256  = [string]$Pass['upgradeDataSha256']
        upgradeId          = $script:Frozen['UpgradeId']
        upgraderVersion    = $script:Frozen['UpgraderVersion']
        changedFileCount   = [int64]$Pass['changedFileCount']
        addedFileCount     = [int64]$Pass['addedFileCount']
        changedFileSetHash = [string]$Pass['changedFileSetHash']
        payloadSetHash     = [string]$Pass['payloadSetHash']
        addedFiles         = @($change['addedVersusRc3'])
        changedFiles       = @($change['replaceVersusRc2'])
        deletedFiles       = @()
        missingExpectedNew = @($change['missingExpected'])
        unexpectedAdds     = @($change['unexpectedAdds'])
        deterministicZip   = 'PASS'
        hashClosure        = 'PASS'
        reproducibleBuild  = [string]$Reproducible
        staticGate         = [string]$script:StaticGateStatus
        cleanCloneReproducibility = [string]$script:CleanCloneStatus
        zipMatchesRepoTree = [string]$script:ZipVsRepoStatus
        frozenInputsUnchanged = 'PASS'
        frozenRc2ZipSha256 = $script:Frozen['Rc2ZipSha256']
        frozenRc3ZipSha256 = $script:Frozen['Rc3ZipSha256']
        outDir             = $script:OutRoot
        distDir            = $script:DistRoot
        releaseManifest    = [string]$script:Report['release']['releaseManifest']
        externalSums       = [string]$script:Report['release']['externalSums']
        buildReport        = [string]$script:ReportPath
        runtimeActivation  = 'NOT TESTED'
    }
    return $identity
}

function Complete-Build([int]$ExitCode) {
    $script:Report['status'] = 'PASS'
    $script:Report['exitCode'] = $ExitCode
    $script:Report['finishedAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    $script:Report['identity'] = $script:Identity
    if ($script:Mode -eq 'data-only') {
        $script:Report['intermediateReason'] = 'data-only build (-NoZip): payload + manifest.json + upgrade-data + SHA256SUMS.txt only; no ZIP built. Re-run without -NoZip for the authoritative package.'
    }
    elseif ($script:IntermediateBuild) {
        $script:Report['intermediateReason'] = 'intermediate build: not all expected product payload files were present when this build ran; the authoritative final build must be re-run with -RequireComplete.'
    }
    Write-JsonFile $script:ReportPath $script:Report
    if ($null -ne $script:Identity) {
        $identityJson = (ConvertTo-DeterministicJson $script:Identity) + "`n"
        $identityPath = Join-Path $script:WorkRoot 'build-identity.json'
        Write-TextFile $identityPath $identityJson
        if ($null -ne $script:EvidenceRoot) {
            Ensure-Directory $script:EvidenceRoot
            Write-TextFile (Join-Path $script:EvidenceRoot 'build-identity.json') $identityJson
            Write-TextFile (Join-Path $script:EvidenceRoot 'build-report.json') ((ConvertTo-DeterministicJson $script:Report) + "`n")
        }
        if (-not [string]::IsNullOrWhiteSpace($script:Identity['reproducibleBuild'])) {
            $repro = [ordered]@{
                tool          = 'cnki-portable-unified-builder'
                zipName       = $script:Frozen['ZipName']
                reproducibleBuild = $script:Identity['reproducibleBuild']
                deterministicZip  = 'PASS'
                payloadFileCount  = $script:Identity['payloadFileCount']
                zipEntryCount     = $script:Identity['zipEntryCount']
                zipSha256         = $script:Identity['zipSha256']
                manifestSha256    = $script:Identity['manifestSha256']
                sumsSha256        = $script:Identity['sumsSha256']
                upgradeDataSha256 = $script:Identity['upgradeDataSha256']
                frozenRc2ZipSha256 = $script:Frozen['Rc2ZipSha256']
                frozenRc3ZipSha256 = $script:Frozen['Rc3ZipSha256']
                passes = @($script:Report['passes'])
            }
            Write-TextFile (Join-Path $script:WorkRoot 'reproducibility.json') ((ConvertTo-DeterministicJson $repro) + "`n")
            if ($null -ne $script:EvidenceRoot) { Write-TextFile (Join-Path $script:EvidenceRoot 'reproducibility.json') ((ConvertTo-DeterministicJson $repro) + "`n") }
        }
    }
    Write-Host ''
    Write-Host '======================================================================'
    Write-Host " BUILD_STATUS=$($script:Report['status'])  MODE=$($script:Mode)  INTERMEDIATE=$($script:IntermediateBuild)"
    if ($null -ne $script:Identity) {
        Write-Host " PAYLOAD_FILE_COUNT=$($script:Identity['payloadFileCount'])"
        Write-Host " PACKAGE_FILE_COUNT=$($script:Identity['packageFileCount'])"
        Write-Host " ZIP_ENTRY_COUNT=$($script:Identity['zipEntryCount'])"
        Write-Host " MANIFEST_SHA256=$($script:Identity['manifestSha256'])"
        Write-Host " SHA256SUMS_TXT_SHA256=$($script:Identity['sumsSha256'])"
        Write-Host " UPGRADE_DATA_SHA256=$($script:Identity['upgradeDataSha256'])"
        Write-Host " ZIP_NAME=$($script:Identity['zipName'])"
        Write-Host " ZIP_BYTES=$($script:Identity['zipBytes'])"
        Write-Host " ZIP_SHA256=$($script:Identity['zipSha256'])"
        Write-Host " DETERMINISTIC_ZIP=PASS"
        Write-Host " HASH_CLOSURE=PASS"
        Write-Host " REPRODUCIBLE_BUILD=$($script:Identity['reproducibleBuild'])"
        Write-Host " FROZEN_INPUTS_UNCHANGED=PASS"
        Write-Host (" ADDED_FILES=" + (@($script:Identity['addedFiles']) -join ','))
        Write-Host (" CHANGED_FILES=" + (@($script:Identity['changedFiles']) -join ','))
        Write-Host ' DELETED_FILES=(none)'
        Write-Host (" BUILD_IDENTITY_JSON=" + (($script:Identity | ConvertTo-Json -Depth 12 -Compress)))
    }
    Write-Host " BUILD_REPORT=$($script:ReportPath)"
    Write-Host " EXIT=$ExitCode"
    Write-Host '======================================================================'
    return $ExitCode
}

# =============================================================================================
# 10. Entry point
# =============================================================================================
$script:FinalExitCode = 1
try {
    Initialize-Build
    $script:ReportPath = Join-Path $script:WorkRoot 'build-report.json'
    if ($script:Mode -eq 'verify-only' -or $script:Mode -eq 'verify-data-only') {
        [void](Invoke-VerifyOnly)
    }
    else {
        [void](Invoke-FullBuild)
    }
    $script:FinalExitCode = Complete-Build 0
}
catch {
    $message = $_.Exception.Message
    Write-Host ''
    Write-Host "[FAIL] $message" -ForegroundColor Red
    if ($null -ne $script:Report) {
        try {
            $script:Report['status'] = 'FAILED'
            $script:Report['finishedAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')
            [void]$script:Report['errors'].Add($message)
            foreach ($f in $script:Failures) { if ($f -ne $message) { [void]$script:Report['errors'].Add([string]$f) } }
            $isValidation = $message -like 'BUILD_VALIDATION_FAILED:*'
            $script:Report['exitCode'] = 2
            if (-not $isValidation) { $script:Report['exitCode'] = 1 }
            $script:FinalExitCode = $script:Report['exitCode']
            if ($null -ne $script:ReportPath) {
                Write-JsonFile $script:ReportPath $script:Report
                Write-Host " BUILD_REPORT=$($script:ReportPath)"
            }
        }
        catch {
            Write-Host "[FAIL] could not write build report: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if ($message -like 'BUILD_VALIDATION_FAILED:*') { $script:FinalExitCode = 2 }
    else { $script:FinalExitCode = 1 }
}
Write-Host "EXIT=$($script:FinalExitCode)"
exit $script:FinalExitCode
