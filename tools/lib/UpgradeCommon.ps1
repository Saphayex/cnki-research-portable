# =====================================================================================
# UpgradeCommon.ps1 - CNKI Research Portable unified upgrader engine (v2)
#
# DERIVED WORK: this library is an adaptation of the frozen Upgrader V1 engine
#   (UPGRADE_RC2_RC3_WORKTREE\UPGRADE_PACKAGE\tools\lib\UpgradeCommon.ps1,
#    cnki-portable-upgrader 1.0.0, 4715 lines, sha256 8a51c1e2... see _SPEC\ENGINE_ADAPTATION_NOTES.md).
# The transaction model, planId gate, backup/staging verification, atomic replace, state
# machine, auto-restore, rollback, user-data protection and fault-injection surface are
# preserved from V1. The adaptation replaces the standalone patch-package layout
# (payload\ + standalone contract manifest + hard-coded 107/16 counts + compiled-in target
# manifest/package hashes) with the unified distribution package model:
#
#   PackageRoot IS the RC3 distribution tree. Target bytes are read directly from
#   <PackageRoot>\<rel> (payloadRoot "."), the target distribution manifest is
#   <PackageRoot>\manifest.json, and the upgrade contract is the package-only metadata
#   file <PackageRoot>\upgrade-data\rc2-to-rc3.json (schemaVersion 2).
#
#   Hash closure (acyclic, see _SPEC\ENGINE_ADAPTATION_NOTES.md):
#     SHA256SUMS.txt -> { payload files, manifest.json, upgrade-data/rc2-to-rc3.json, upgrade-data/README.md }
#     upgrade-data/rc2-to-rc3.json -> { sha256(manifest.json), target payload hashes, frozen RC2 anchors }
#     manifest.json -> { target payload files }
#     (upgrade-data is NOT listed in manifest.json.files[], so no cycle exists)
#   Therefore targetManifestHash IS an embeddable field of the upgrade-data file, while
#   manifest.json remains schemaVersion 1 and the engine keeps only source-side trust
#   anchors as compile-time constants (RC2 manifest/package hashes, hotfix variants,
#   frozen RC3 manifest hash for frozen-RC3 already-installed recognition).
#
# Shared library for tools\setup.ps1 / tools\upgrade.ps1.  Dot-sourceable: definitions
# only, no side effects. Windows PowerShell 5.1 compatible. Offline. No child processes.
# No network. No Remove-Item -Recurse.
#
# Transaction record: schemaVersion 2 (adds operation/existed=false/newDirectories).
# New-file (operation "add") safety: backup records existed=false without a copy; apply
# creates parent directories inside the install root (recorded before creation); apply
# writes atomically; auto-restore/ROLLBACK delete an added file ONLY when its current
# bytes equal the applied target hash (a user-modified added file is a conflict /
# FAILED_MANUAL, never silently deleted); only directories created by this transaction
# are removed, deepest-first, empty-only, exact path - never recursive.
#
# planId note (kept from V1): the env-file line of the canonical planId material is
#     path TAB actualCurrentSha256 TAB expectedAfterFormat LF
# where expectedAfterFormat is the deterministic manifest-only JSON of the declared
# environment-file operation. Both CHECK/PLAN and APPLY compute it with the same
# function, so an external edit of the env file changes the planId ("re-run PLAN").
#
# Test hooks (overridable by dot-sourcing tests): Get-DshProcessTable,
# Test-DshApplyAllowed, Get-ProductionDshHome.
# =====================================================================================

#region ============================== constants ======================================

$script:ToolName        = 'cnki-portable-upgrader'
$script:ToolVersion     = '2.0.0'
$script:EnvelopeSchema  = 1

# Unified package identity (release contract; upgrade-data must agree).
$script:PackageKind         = 'cnki-research-portable-unified-upgrade'
$script:ManifestKind        = 'cnki-research-portable-unified-upgrade'
$script:UpgradeId           = 'cnki-portable-1.0.0-rc.2-to-1.0.0-rc.3-unified'
$script:DistributionId      = 'cnki-research-portable-unified-1.0.0-rc.3'
$script:MetadataSchemaVersion = 2
$script:TransactionSchemaVersion = 2

$script:SourceVersion       = '1.0.0-rc.2'
$script:TargetVersion       = '1.0.0-rc.3'
$script:BundleVersion       = '1.0.0'

# Unified package layout constants (fixed relative paths inside PackageRoot).
$script:UpgradeDataRelPath          = 'upgrade-data/rc2-to-rc3.json'
$script:UpgradeDataReadmeRelPath    = 'upgrade-data/README.md'
$script:DistributionManifestRelPath = 'manifest.json'
$script:SumsFileName                = 'SHA256SUMS.txt'
$script:PayloadRootDefault          = '.'
$script:PortableEntryPoint          = 'tools/portable.ps1'

# Source-side trust anchors (frozen RC2 facts; independent of the unified target package).
$script:SourceManifestHash  = '80229318a1ef070f5cedafda39785be0cbb49ee727f7a620e7e6aab5113a6e1f'
$script:SourcePackageHash   = '4f279f359a42e5e950cd9f66e04f0922c5e40ec4c77f9192e2168274ce1142b5'
$script:SourcePackageBytes  = 388236
$script:SourcePayloadFileCount = 107
# Frozen RC3 distribution manifest hash - independent constant used ONLY to recognise an
# already-installed frozen-RC3 core (no automatic refresh). Not a hash of the new package.
$script:FrozenRc3ManifestHash = '98c8bca2bd34f0eda0e1d9fb1d0c6f38e60c8c4e92990efcb1c3be507f99a5e2'

$script:CordisPath      = 'bundle/cnki-research/cordis.patch.yml'
$script:CordisPresetId  = 'preset-cnki-research'
$script:CordisMcpClient = '@deepseek-ai/dsh-mcp-client'
$script:PersonaPrefix   = 'You are a coding agent powered by the {{model}} model.'
$script:ForbiddenCwd    = '{{cwd}}'
$script:BundlePackageJson = 'bundle/cnki-research/package.json'
$script:LauncherPath    = 'bundle/cnki-research/launcher/cnki_research_launcher.py'
$script:ServerPyPath    = 'upstream/cnki-mcp/src/cnki_mcp/server/cnki_mcp_server.py'
$script:ToolRegistryPyPath = 'upstream/cnki-mcp/src/cnki_mcp/server/tool_registry.py'

$script:RequiredToolNames = @(
    'easy-search', 'advanced-search', 'get-info-from-url', 'get-info-by-detail',
    'list-journal', 'search-issn', 'login', 'logout'
)
$script:RequiredMcpResources = @('profile://list')

# Allowed RC2 hotfix variants for bundle/cnki-research/cordis.patch.yml (values are sha256).
$script:HotfixedOverrides = [ordered]@{
    'HOTFIX_LINE_REMOVED' = 'edda8817e0bf449d8324f4875b1c7acd37a8dc693c3a82d044f4a5c436421778'
    'HOTFIX_TEXT_REMOVED' = 'b5aaa79ebb7a0c1bdd6f253e6462b0c1ee3db8f4f34cf15e83e0a59a37e4c0a9'
}

# Files that may exist in an in-place (self-mode) extracted package root without being
# listed in SHA256SUMS.txt because the installer creates them at install time.
$script:SelfModeAllowedExtraPaths = @(
    'bundle/cnki-research/portable.runtime.json'
)

$script:KnownEnvMetadataPaths = @(
    '_portable/install-state.json',
    'bundle/cnki-research/portable.runtime.json'
)

$script:TerminalTransactionPhases = @('COMMITTED', 'ROLLED_BACK', 'FAILED_RESTORED', 'ABORTED', 'NOOP_ALREADY_TARGET')
$script:KnownTransactionPhases = @(
    'PRECHECKED', 'BACKED_UP', 'STAGED', 'APPLYING', 'APPLIED', 'VERIFIED', 'COMMITTED',
    'FAILED_RESTORED', 'FAILED_MANUAL', 'ROLLBACK_STARTED', 'ROLLED_BACK', 'ABORTED',
    'ROLLBACK_FAILED_MANUAL', 'NOOP_ALREADY_TARGET'
)
$script:DefaultUpgradesDirName = '_portable\upgrades'

#endregion

#region ============================== small utilities =================================

function Sort-Ordinal {
    param([string[]]$Items)
    if ($null -eq $Items) { return @() }
    $list = @($Items)
    if ($list.Count -eq 0) { return @() }
    $copy = [string[]]::new($list.Count)
    for ($i = 0; $i -lt $list.Count; $i++) { $copy[$i] = [string]$list[$i] }
    [System.Array]::Sort($copy, [System.StringComparer]::Ordinal)
    return $copy
}

function Get-NormalizedFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is empty' }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -match '^[A-Za-z]:\\$') { return $full }
    if ($full -match '^\\\\[^\\]+\\[^\\]+\\$') { return $full.TrimEnd('\') }
    while ($full.Length -gt 1 -and $full.EndsWith('\')) { $full = $full.Substring(0, $full.Length - 1) }
    return $full
}

function ConvertTo-FsPath {
    param([string]$Path)
    if ($null -eq $Path) { return '' }
    return ([string]$Path).Replace('/', '\')
}

function ConvertTo-ManifestPath {
    param([string]$Path)
    if ($null -eq $Path) { return '' }
    return ([string]$Path).Replace('\', '/')
}

function Test-PathUnder {
    param([string]$Child, [string]$Parent)
    if ([string]::IsNullOrEmpty($Child) -or [string]::IsNullOrEmpty($Parent)) { return $false }
    $c = Get-NormalizedFullPath $Child
    $p = Get-NormalizedFullPath $Parent
    if ([string]::Equals($c, $p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $p
    if (-not $prefix.EndsWith('\')) { $prefix = $prefix + '\' }
    return $c.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

# Long-path tolerant bridge for [System.IO.*] calls (Windows MAX_PATH).
function Get-IoPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.Length -ge 240 -and $Path -match '^[A-Za-z]:\\') { return '\\?\' + $Path }
    if ($Path.Length -ge 240 -and $Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return $Path
}

function ConvertFrom-IoPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Test-FileExists {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try { return [System.IO.File]::Exists((Get-IoPath $Path)) } catch { return $false }
}

function Test-DirExists {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try { return [System.IO.Directory]::Exists((Get-IoPath $Path)) } catch { return $false }
}

function Get-FileAttributesSafe {
    param([string]$Path)
    try { return [System.IO.File]::GetAttributes((Get-IoPath $Path)) } catch { return $null }
}

function Get-FileLengthSafe {
    param([string]$Path)
    try { return ([System.IO.FileInfo]::new((Get-IoPath $Path))).Length } catch { return -1 }
}

function Get-LastWriteUtcTicksSafe {
    param([string]$Path)
    try { return [System.IO.File]::GetLastWriteTimeUtc((Get-IoPath $Path)).Ticks } catch { return 0 }
}

function Get-DirectoryEntries {
    param([string]$Directory)
    $dir = Get-NormalizedFullPath $Directory
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-DirExists $dir)) { return $out.ToArray() }
    try {
        foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries((Get-IoPath $dir))) {
            [void]$out.Add((ConvertFrom-IoPath $e))
        }
    } catch {
        # Unreadable directory: caller decides. Return what we could enumerate.
    }
    return $out.ToArray()
}

function Get-RelativePathUnder {
    param([string]$Path, [string]$Root)
    $p = Get-NormalizedFullPath $Path
    $r = Get-NormalizedFullPath $Root
    if ([string]::Equals($p, $r, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    $prefix = $r
    if (-not $prefix.EndsWith('\')) { $prefix = $prefix + '\' }
    if (-not $p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "path '$p' is not under '$r'"
    }
    return (ConvertTo-ManifestPath $p.Substring($prefix.Length))
}

function Remove-FileExact {
    param([string]$Path)
    if (Test-FileExists $Path) {
        try { [System.IO.File]::Delete((Get-IoPath $Path)) } catch { }
    }
}

#endregion

#region ============================== hashing =========================================

function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

function Get-Sha256File {
    param([string]$Path)
    if (-not (Test-FileExists $Path)) { throw "file not found for hashing: $Path" }
    $stream = $null
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open((Get-IoPath $Path), [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $hash = $sha.ComputeHash($stream)
    } finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

function Get-Sha256Text {
    param([string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    return (Get-Sha256Bytes ($enc.GetBytes([string]$Text)))
}

function Get-Utf8NoBomBytes {
    param([string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    return $enc.GetBytes([string]$Text)
}

function Read-TextFileUtf8 {
    param([string]$Path)
    if (-not (Test-FileExists $Path)) { throw "file not found: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes((Get-IoPath $Path))
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $strict.GetString($bytes) } catch { return [System.Text.Encoding]::Default.GetString($bytes) }
}

#endregion

#region ============================== atomic JSON / text IO ===========================

function ConvertTo-StableJson {
    param($Value)
    $json = $Value | ConvertTo-Json -Depth 30
    if ($null -eq $json) { $json = 'null' }
    return ($json -replace "`r`n", "`n")
}

function Write-TextFileAtomic {
    param([string]$Path, [string]$Text, [switch]$NoCreateDirectory)
    $full = Get-NormalizedFullPath $Path
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ($dir -and -not (Test-DirExists $dir)) {
        if ($NoCreateDirectory) { throw "output directory does not exist: $dir" }
        [void][System.IO.Directory]::CreateDirectory((Get-IoPath $dir))
    }
    $bytes = Get-Utf8NoBomBytes $Text
    $expected = Get-Sha256Bytes $bytes
    $tmp = $full + '.tmp-' + [System.Guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllBytes((Get-IoPath $tmp), $bytes)
        $actual = Get-Sha256File $tmp
        if (-not [string]::Equals($actual, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "atomic write verification failed for temporary file '$tmp'"
        }
        if (Test-FileExists $full) {
            [System.IO.File]::Replace((Get-IoPath $tmp), (Get-IoPath $full), [System.Management.Automation.Language.NullString]::Value)
        } else {
            [System.IO.File]::Move((Get-IoPath $tmp), (Get-IoPath $full))
        }
        $final = Get-Sha256File $full
        if (-not [string]::Equals($final, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "atomic write verification failed for '$full'"
        }
    } finally {
        if (Test-FileExists $tmp) { Remove-FileExact $tmp }
    }
}

function Write-JsonAtomic {
    param([string]$Path, $Value)
    $json = ConvertTo-StableJson $Value
    Write-TextFileAtomic -Path $Path -Text $json
    return $json
}

function Test-JsonDuplicateKeys {
    # Lightweight JSON scanner: throws on duplicate keys inside the same object.
    # Tolerant of whitespace; only used before ConvertFrom-Json for safety.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $len = $Text.Length
    $i = 0
    $stack = New-Object System.Collections.Stack
    $inString = $false
    $escape = $false
    $sb = $null
    $stringIsKey = $false
    while ($i -lt $len) {
        $ch = $Text[$i]
        if ($inString) {
            if ($escape) { $escape = $false; if ($null -ne $sb) { [void]$sb.Append($ch) }; $i++; continue }
            if ($ch -eq '\') { $escape = $true; if ($null -ne $sb) { [void]$sb.Append($ch) }; $i++; continue }
            if ($ch -eq '"') {
                $inString = $false
                if ($stringIsKey) {
                    $frame = $stack.Peek()
                    $key = $sb.ToString()
                    if ($frame.keys.ContainsKey($key)) { throw "duplicate JSON key '$key'" }
                    [void]$frame.keys.Add($key, $true)
                    $frame.expectKey = $false
                }
                $sb = $null
                $i++; continue
            }
            if ($null -ne $sb) { [void]$sb.Append($ch) }
            $i++; continue
        }
        switch ($ch) {
            '"' {
                $inString = $true
                $escape = $false
                $stringIsKey = $false
                if ($stack.Count -gt 0) {
                    $top = $stack.Peek()
                    if ($top.kind -eq 'object' -and $top.expectKey) {
                        $stringIsKey = $true
                        $sb = New-Object System.Text.StringBuilder
                    }
                }
                $i++; continue
            }
            '{' {
                $frame = @{ kind = 'object'; expectKey = $true; keys = (New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::Ordinal)) }
                $stack.Push($frame)
                $i++; continue
            }
            '[' {
                $frame = @{ kind = 'array'; expectKey = $false; keys = $null }
                $stack.Push($frame)
                $i++; continue
            }
            '}' { if ($stack.Count -gt 0) { [void]$stack.Pop() }; $i++; continue }
            ']' { if ($stack.Count -gt 0) { [void]$stack.Pop() }; $i++; continue }
            ',' {
                if ($stack.Count -gt 0) {
                    $top = $stack.Peek()
                    if ($top.kind -eq 'object') { $top.expectKey = $true }
                }
                $i++; continue
            }
            ':' { $i++; continue }
            default { $i++; continue }
        }
    }
}

function Read-JsonDocument {
    param([string]$Path)
    if (-not (Test-FileExists $Path)) { throw "JSON document not found: $Path" }
    $raw = Read-TextFileUtf8 $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "JSON document is empty: $Path" }
    try { Test-JsonDuplicateKeys $raw } catch { throw "invalid JSON in '$Path': $($_.Exception.Message)" }
    try { return ($raw | ConvertFrom-Json) } catch { throw "invalid JSON in '$Path': $($_.Exception.Message)" }
}

function Read-JsonFromText {
    param([string]$Text, [string]$SourceName)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw "JSON document is empty: $SourceName" }
    try { Test-JsonDuplicateKeys $Text } catch { throw "invalid JSON in '$SourceName': $($_.Exception.Message)" }
    try { return ($Text | ConvertFrom-Json) } catch { throw "invalid JSON in '$SourceName': $($_.Exception.Message)" }
}

function ConvertTo-DictDeep {
    # Recursively converts JSON PSCustomObjects into ordered dictionaries so that both the
    # in-memory (APPLY) and the disk-loaded (ROLLBACK/VERIFY) transaction records use the
    # same key-indexer access style.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in @($Value.Keys)) { $out[[string]$k] = (ConvertTo-DictDeep $Value[$k]) }
        return $out
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $out[[string]$p.Name] = (ConvertTo-DictDeep $p.Value) }
        return $out
    }
    if ($Value -is [System.Array]) {
        $arr = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$arr.Add((ConvertTo-DictDeep $item)) }
        return , $arr.ToArray()
    }
    return $Value
}

function Copy-FileVerified {
    param([string]$Source, [string]$Destination)
    if (-not (Test-FileExists $Source)) { throw "copy source not found: $Source" }
    $destFull = Get-NormalizedFullPath $Destination
    $dir = [System.IO.Path]::GetDirectoryName($destFull)
    if ($dir -and -not (Test-DirExists $dir)) { [void][System.IO.Directory]::CreateDirectory((Get-IoPath $dir)) }
    if (Test-FileExists $destFull) { throw "refusing to overwrite existing file: $destFull" }
    $srcSha = Get-Sha256File $Source
    $srcLen = Get-FileLengthSafe $Source
    [System.IO.File]::Copy((Get-IoPath $Source), (Get-IoPath $destFull), $false)
    $dstSha = Get-Sha256File $destFull
    $dstLen = Get-FileLengthSafe $destFull
    if (-not [string]::Equals($srcSha, $dstSha, [System.StringComparison]::OrdinalIgnoreCase) -or $srcLen -ne $dstLen) {
        throw "copy verification failed: '$Source' -> '$destFull'"
    }
    return $dstSha
}

#endregion

#region ============================== reparse points / fingerprints ===================

function Test-ReparsePoint {
    param([string]$Path)
    $attr = Get-FileAttributesSafe $Path
    if ($null -eq $attr) { return $false }
    return (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-ReparsePointsInPath {
    # Ancestors between $StopAt (exclusive) and $Path (inclusive) that are reparse points.
    param([string]$Path, [string]$StopAt)
    $hits = New-Object System.Collections.ArrayList
    try { $stop = Get-NormalizedFullPath $StopAt } catch { return @() }
    try { $cur = Get-NormalizedFullPath $Path } catch { return @() }
    $guard = 0
    while ($cur.Length -gt $stop.Length -and $guard -lt 512) {
        $guard++
        if (Test-ReparsePoint $cur) { [void]$hits.Add($cur) }
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrEmpty($parent)) { break }
        $cur = $parent
    }
    return $hits.ToArray()
}

function Get-TreeFingerprint {
    # Deterministic lowercase sha256 over sorted "relpath\0size\0lastWriteUtcTicks\0" lines.
    # Missing root -> 'ABSENT'. Directory reparse points are not followed and are skipped.
    param([string]$Root, [string[]]$ExcludePrefixes)
    if (-not (Test-DirExists $Root)) { return 'ABSENT' }
    $rootFull = Get-NormalizedFullPath $Root
    $excludes = New-Object System.Collections.ArrayList
    if ($null -ne $ExcludePrefixes) {
        foreach ($p in $ExcludePrefixes) {
            $np = ConvertTo-ManifestPath ([string]$p).Trim('/')
            if ($np.Length -gt 0) { [void]$excludes.Add($np) }
        }
    }
    $lines = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        foreach ($entry in (Get-DirectoryEntries $dir)) {
            $rel = ConvertTo-ManifestPath (Get-RelativePathUnder $entry $rootFull)
            $skip = $false
            foreach ($ex in $excludes) {
                if ($rel -ieq $ex -or $rel.StartsWith($ex + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
            }
            if ($skip) { continue }
            $attr = Get-FileAttributesSafe $entry
            if ($null -eq $attr) { continue }
            if (($attr -band [System.IO.FileAttributes]::Directory) -ne 0) {
                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($entry)
            } else {
                $size = Get-FileLengthSafe $entry
                $ticks = Get-LastWriteUtcTicksSafe $entry
                [void]$lines.Add($rel + [char]0 + $size + [char]0 + $ticks + [char]0)
            }
        }
    }
    $arr = $lines.ToArray()
    if ($arr.Length -gt 1) { [System.Array]::Sort($arr, [System.StringComparer]::Ordinal) }
    return (Get-Sha256Text ($arr -join "`n"))
}

#endregion

#region ============================== checks / summary ===============================

function New-CheckList {
    return ,(New-Object System.Collections.ArrayList)
}

function Add-Check {
    param($Checks, [string]$Id, [string]$Status, [string]$Detail)
    [void]$Checks.Add([ordered]@{ id = $Id; status = $Status; detail = $Detail })
}

function Get-ChecksArray {
    param($Checks)
    if ($null -eq $Checks) { return @() }
    return [object[]]$Checks.ToArray()
}

function Get-CheckSummary {
    param($Checks)
    $pass = 0; $warn = 0; $fail = 0; $nt = 0
    if ($null -ne $Checks) {
        foreach ($c in $Checks) {
            $st = [string]$c['status']
            if ($st -eq 'PASS') { $pass++ }
            elseif ($st -eq 'WARN') { $warn++ }
            elseif ($st -eq 'FAIL') { $fail++ }
            elseif ($st -eq 'NOT TESTED') { $nt++ }
        }
    }
    return [ordered]@{ pass = $pass; warn = $warn; fail = $fail; notTested = $nt; refused = $false; outcome = '' }
}

function Test-ChecksHaveFail {
    param($Checks)
    if ($null -eq $Checks) { return $false }
    foreach ($c in $Checks) { if ([string]$c['status'] -eq 'FAIL') { return $true } }
    return $false
}

function Get-FailedCheckIds {
    param($Checks)
    $out = New-Object System.Collections.ArrayList
    if ($null -ne $Checks) {
        foreach ($c in $Checks) { if ([string]$c['status'] -eq 'FAIL') { [void]$out.Add([string]$c['id']) } }
    }
    return $out.ToArray()
}

#endregion

#region ============================== JSON helpers ===================================

function ConvertTo-CompactJson {
    param($Value)
    $json = $Value | ConvertTo-Json -Depth 20 -Compress
    if ($null -eq $json) { return 'null' }
    return ($json -replace "`r?`n", '')
}

function Get-JsonPathSegments {
    param([string]$JsonPath)
    $p = [string]$JsonPath
    if ([string]::IsNullOrWhiteSpace($p)) { throw 'jsonPath is empty' }
    $p = $p.Trim()
    if ($p.StartsWith('$.')) { $p = $p.Substring(2) }
    elseif ($p.StartsWith('$')) { $p = $p.Substring(1).TrimStart('.') }
    if ($p.Length -eq 0) { throw "invalid jsonPath: '$JsonPath'" }
    $segments = @($p.Split('.'))
    return , $segments
}

function Get-JsonPropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-JsonPathValue {
    param($Object, [string]$JsonPath)
    $segments = Get-JsonPathSegments $JsonPath
    $cur = $Object
    foreach ($seg in $segments) {
        if ($null -eq $cur) { return $null }
        $cur = Get-JsonPropertyValue $cur $seg
    }
    return $cur
}

function Test-JsonPathExists {
    param($Object, [string]$JsonPath)
    $sentinel = New-Object object
    $segments = Get-JsonPathSegments $JsonPath
    $cur = $Object
    foreach ($seg in $segments) {
        if ($null -eq $cur) { return $false }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($seg)) { return $false }
            $cur = $cur[$seg]
        } else {
            $prop = $cur.PSObject.Properties[$seg]
            if ($null -eq $prop) { return $false }
            $cur = $prop.Value
        }
    }
    return $true
}

function Set-JsonPathValue {
    param($Object, [string]$JsonPath, $Value)
    $segments = Get-JsonPathSegments $JsonPath
    $cur = $Object
    for ($i = 0; $i -lt $segments.Length; $i++) {
        $seg = $segments[$i]
        $isLast = ($i -eq $segments.Length - 1)
        if ($cur -is [System.Collections.IDictionary]) {
            if ($isLast) { $cur[$seg] = $Value; return }
            if (-not $cur.Contains($seg) -or $null -eq $cur[$seg]) { $cur[$seg] = [ordered]@{} }
            $cur = $cur[$seg]
        } else {
            $prop = $cur.PSObject.Properties[$seg]
            if ($isLast) {
                if ($null -eq $prop) { $cur | Add-Member -NotePropertyName $seg -NotePropertyValue $Value }
                else { $prop.Value = $Value }
                return
            }
            if ($null -eq $prop -or $null -eq $prop.Value) {
                $child = [ordered]@{}
                if ($null -eq $prop) { $cur | Add-Member -NotePropertyName $seg -NotePropertyValue $child }
                else { $prop.Value = $child }
                $cur = $child
            } else {
                $cur = $prop.Value
            }
        }
    }
}

function Get-EnvDeclarationAfterFormat {
    # planId material helper - see planId note at the top of this file. Deterministic,
    # computed only from the upgrade-data declaration (literal '<now>' kept as-is).
    param($EnvDecl)
    if ($null -eq $EnvDecl) { throw 'environment file declaration is null' }
    $format = 'json'
    $fmtProp = $EnvDecl.PSObject.Properties['format']
    if ($null -ne $fmtProp -and -not [string]::IsNullOrEmpty([string]$fmtProp.Value)) { $format = [string]$fmtProp.Value }
    $updates = New-Object System.Collections.ArrayList
    $declUpdates = Get-JsonPropertyValue $EnvDecl 'updates'
    if ($null -ne $declUpdates) {
        foreach ($u in @($declUpdates)) {
            $jp = [string](Get-JsonPropertyValue $u 'jsonPath')
            $val = Get-JsonPropertyValue $u 'value'
            [void]$updates.Add([ordered]@{ jsonPath = $jp; value = $val })
        }
    }
    $adds = New-Object System.Collections.ArrayList
    $declAdds = Get-JsonPropertyValue $EnvDecl 'addFields'
    if ($null -ne $declAdds) {
        $declAddsArray = @($declAdds)
        $declObjectForm = $false
        if ($declAddsArray.Count -eq 1 -and $null -ne $declAddsArray[0] -and $declAddsArray[0] -isnot [string] -and
            $null -eq $declAddsArray[0].PSObject.Properties['jsonPath']) {
            $declObjectForm = $true
        }
        if ($declObjectForm) {
            foreach ($prop in $declAddsArray[0].PSObject.Properties) {
                [void]$adds.Add([ordered]@{ jsonPath = [string]$prop.Name; value = $prop.Value })
            }
        } else {
            foreach ($a in $declAddsArray) {
                if ($null -eq $a -or $a -is [string]) { continue }
                [void]$adds.Add([ordered]@{ jsonPath = [string](Get-JsonPropertyValue $a 'jsonPath'); value = (Get-JsonPropertyValue $a 'value') })
            }
        }
    }
    $canonical = [ordered]@{ format = $format; updates = $updates.ToArray(); addFields = $adds.ToArray() }
    return (ConvertTo-CompactJson $canonical)
}

#endregion

#region ============================== path validation ================================

function Test-SafeRelativePath {
    # Returns array of problem strings for a manifest relative path ('' separator form ok).
    param([string]$RelativePath)
    $problems = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($RelativePath)) {
        [void]$problems.Add('EMPTY_PATH')
        return $problems.ToArray()
    }
    $raw = [string]$RelativePath
    if ($raw.IndexOf([char]0) -ge 0) { [void]$problems.Add('NUL_CHARACTER') }
    if ($raw -match '^[\\/]') { [void]$problems.Add('ROOTED_PATH') }
    if ($raw -match '^[A-Za-z]:') { [void]$problems.Add('DRIVE_LETTER') }
    if ($raw -match '^\\\\|^//') { [void]$problems.Add('UNC_PATH') }
    if ($raw -match '^\\\\\?|^\\\\\.') { [void]$problems.Add('DEVICE_PATH') }
    $alt = $raw.Replace('/', '\')
    $segments = $alt.Split('\')
    $reserved = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    foreach ($seg in $segments) {
        if ([string]::IsNullOrEmpty($seg)) { [void]$problems.Add('EMPTY_COMPONENT'); continue }
        if ($seg -eq '.' -or $seg -eq '..') { [void]$problems.Add('DOT_COMPONENT'); continue }
        if ($seg.IndexOf([char]':') -ge 0) { [void]$problems.Add('ADS_COLON'); continue }
        if ($seg.Length -gt 255) { [void]$problems.Add('COMPONENT_TOO_LONG'); continue }
        $base = $seg.Split('.')[0]
        foreach ($r in $reserved) {
            if ($base -ieq $r) { [void]$problems.Add('RESERVED_DEVICE_NAME'); break }
        }
    }
    return $problems.ToArray()
}

#endregion

#region ============================== DSH inspection =================================

function Get-ProductionDshHome {
    if (-not [string]::IsNullOrEmpty($env:DSH_HOME)) {
        try { return (Get-NormalizedFullPath $env:DSH_HOME) } catch { }
    }
    if ([string]::IsNullOrEmpty($env:USERPROFILE)) { return $null }
    try { return (Get-NormalizedFullPath (Join-Path $env:USERPROFILE '.dsh')) } catch { return $null }
}

function Get-DshProcessTable {
    # Read-only DSH host process probe. Injectable: tests may redefine this function.
    $result = New-Object System.Collections.ArrayList
    try { $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { return @() }
    foreach ($p in $procs) {
        $name = [string]$p.Name
        $isHost = $false
        if ($name -match '(?i)^(DeepSeek[ _-]?Harness|deepseek-harness|dsh|dsh-host)(\.exe|\.cmd)?$') {
            $isHost = $true
        } elseif ($name -match '(?i)^(node|nodejs)\.exe$') {
            $cl = [string]$p.CommandLine
            if ($cl -match '(?i)deepseek|dsh') { $isHost = $true }
        }
        if ($isHost) {
            [void]$result.Add([ordered]@{
                pid         = [int]$p.ProcessId
                name        = $name
                path        = [string]$p.ExecutablePath
                commandLine = [string]$p.CommandLine
                parentPid   = [int]$p.ParentProcessId
            })
        }
    }
    return $result.ToArray()
}

function Get-ProcessParentChain {
    param([int]$ProcessId)
    $result = New-Object System.Collections.ArrayList
    $cur = $ProcessId
    $guard = 0
    while ($cur -gt 0 -and $guard -lt 64) {
        $guard++
        $p = $null
        try { $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$cur" -ErrorAction Stop } catch { $p = $null }
        if ($null -eq $p) { break }
        [void]$result.Add([ordered]@{
            pid       = [int]$p.ProcessId
            name      = [string]$p.Name
            parentPid = [int]$p.ParentProcessId
        })
        $next = [int]$p.ParentProcessId
        if ($next -le 0 -or $next -eq $cur) { break }
        $cur = $next
    }
    return $result.ToArray()
}

function Get-DshAncestry {
    param($ProcessTable, [int]$ProcessId = $PID)
    $chain = @(Get-ProcessParentChain -ProcessId $ProcessId)
    $dshPids = @{}
    if ($null -ne $ProcessTable) {
        foreach ($p in @($ProcessTable)) { $dshPids[[int]$p.pid] = $true }
    }
    $matched = 0
    foreach ($c in $chain) {
        if ($dshPids.ContainsKey([int]$c.pid)) { $matched = [int]$c.pid; break }
    }
    return [ordered]@{
        underDshProcess = ($matched -gt 0)
        matchedPid      = $matched
        chain           = $chain
    }
}

function Test-DirHasEntries {
    param([string]$Path)
    if (-not (Test-DirExists $Path)) { return $false }
    try {
        foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries((Get-IoPath $Path))) { return $true }
    } catch { return $false }
    return $false
}

function Test-DshApplyAllowed {
    # APPLY / ROLLBACK live-DSH gate (ENGINE_SPEC section 5, dsh.inUse).
    # Injectable/unit-testable: pass -DshRunning / -UnderDshProcess to bypass probes.
    param(
        [string]$DshHome,
        [string]$InstallRoot,
        [System.Nullable[bool]]$DshRunning = $null,
        [System.Nullable[bool]]$UnderDshProcess = $null
    )
    $prod = Get-ProductionDshHome
    $dshHomePath = $null
    if (-not [string]::IsNullOrEmpty($DshHome)) {
        try { $dshHomePath = Get-NormalizedFullPath $DshHome } catch { $dshHomePath = $null }
    }
    if ($null -eq $dshHomePath) { $dshHomePath = $prod }
    $isLive = $false
    if ($null -ne $prod -and $null -ne $dshHomePath -and [string]::Equals($dshHomePath, $prod, [System.StringComparison]::OrdinalIgnoreCase)) {
        $isLive = $true
    }
    if ($null -ne $dshHomePath) {
        if ((Test-DirHasEntries (Join-Path $dshHomePath 'sessions')) -or (Test-DirHasEntries (Join-Path $dshHomePath 'storages'))) {
            $isLive = $true
        }
    }
    $running = $false
    if ($null -ne $DshRunning) {
        $running = [bool]$DshRunning
    } else {
        $table = @(Get-DshProcessTable)
        $running = ($table.Count -gt 0)
    }
    $under = $false
    if ($null -ne $UnderDshProcess) {
        $under = [bool]$UnderDshProcess
    } else {
        $table = @(Get-DshProcessTable)
        $anc = Get-DshAncestry -ProcessTable $table
        $under = [bool]$anc.underDshProcess
    }
    $refused = $false
    $status = 'PASS'
    $reason = 'NOT_IN_USE'
    $message = 'No DSH host process is running; APPLY may proceed.'
    if ($isLive -and ($running -or $under)) {
        $refused = $true
        $status = 'FAIL'
        $reason = 'DSH_IN_USE'
        $message = ('DSH is running (or this process is a child of DSH) while the target DSH home ' +
            'is the LIVE production home. Close DSH normally (do not force-kill), then run APPLY ' +
            'from a separate PowerShell window.')
    } elseif ($running) {
        $status = 'WARN'
        $reason = 'DSH_RUNNING_ISOLATED_TARGET'
        $message = ('A DSH host process is running, but the target DSH home is an isolated/sandbox profile; ' +
            'continuing (the production DSH profile is not touched).')
    }
    return [pscustomobject]@{
        refused         = $refused
        status          = $status
        checkId         = 'dsh.inUse'
        reason          = $reason
        message         = $message
        isLiveTarget    = $isLive
        dshRunning      = $running
        underDshProcess = $under
        dshHome         = $dshHomePath
        productionDshHome = $prod
        requiresDshExit = ($isLive -and $running)
    }
}

function Get-DshProfileInfo {
    # Read-only inspection of DSH profiles for the '@local/dsh-cnki-research' bundle reference.
    param([string]$DshHome, [string]$InstallRoot, [string]$DshProfile)
    $info = [ordered]@{
        home             = $null
        profilesDir      = $null
        profilesDirExists = $false
        profiles         = @()
        matches          = @()
        selectedName     = $null
        selectedDir      = $null
        packageJsonSha256 = $null
        dependencyValue  = $null
        junctionPath     = $null
        junctionIsReparse = $false
        junctionTarget   = $null
        expectedTarget   = $null
        outcome          = 'NOT_FOUND'
        detail           = ''
        fingerprint      = 'ABSENT'
    }
    $bundleRel = '@local/dsh-cnki-research'
    if ([string]::IsNullOrEmpty($DshHome)) { $DshHome = Get-ProductionDshHome }
    if ([string]::IsNullOrEmpty($DshHome)) {
        $info.detail = 'no DSH home could be resolved'
        return [pscustomobject]$info
    }
    try { $dshHomePath = Get-NormalizedFullPath $DshHome } catch {
        $info.detail = 'DSH home path is invalid'
        return [pscustomobject]$info
    }
    $info.home = $dshHomePath
    $profilesDir = Join-Path $dshHomePath 'profiles'
    $info.profilesDir = $profilesDir
    if (-not (Test-DirExists $profilesDir)) {
        $info.detail = "profiles directory not found: $profilesDir"
        return [pscustomobject]$info
    }
    $info.profilesDirExists = $true
    $profiles = New-Object System.Collections.ArrayList
    $matches = New-Object System.Collections.ArrayList
    foreach ($entry in (Get-DirectoryEntries $profilesDir)) {
        $attr = Get-FileAttributesSafe $entry
        if ($null -eq $attr) { continue }
        if (($attr -band [System.IO.FileAttributes]::Directory) -eq 0) { continue }
        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $name = [System.IO.Path]::GetFileName($entry)
        $pkgPath = Join-Path $entry 'package.json'
        $declared = $false
        $depValue = $null
        $readable = $true
        if (Test-FileExists $pkgPath) {
            try {
                $pkg = Read-JsonDocument $pkgPath
                $deps = Get-JsonPropertyValue $pkg 'dependencies'
                $depValue = Get-JsonPropertyValue $deps $bundleRel
                if ($null -ne $depValue) { $declared = $true }
                $dsh = Get-JsonPropertyValue $pkg 'dsh'
                $profile = Get-JsonPropertyValue $dsh 'profile'
                $bundles = Get-JsonPropertyValue $profile 'bundles'
                if ($null -ne $bundles) {
                    foreach ($b in @($bundles)) { if ([string]$b -eq $bundleRel) { $declared = $true; break } }
                }
            } catch { $readable = $false }
        }
        [void]$profiles.Add([ordered]@{ name = $name; dir = $entry; declared = $declared; dependencyValue = $depValue; readable = $readable })
        if ($declared -and $readable) { [void]$matches.Add($name) }
    }
    $info.profiles = $profiles.ToArray()
    $info.matches = $matches.ToArray()

    $selectedName = $null
    if (-not [string]::IsNullOrEmpty($DshProfile)) {
        $selectedName = $DshProfile
    } elseif ($matches.Count -eq 1) {
        $selectedName = [string]$matches[0]
    } elseif ($matches.Count -eq 0) {
        if (Test-DirExists (Join-Path $profilesDir 'desktop')) { $selectedName = 'desktop' }
    } else {
        if ($matches -contains 'desktop') { $selectedName = 'desktop' } else { $selectedName = [string]$matches[0] }
    }
    if ([string]::IsNullOrEmpty($selectedName)) {
        $info.outcome = 'NOT_FOUND'
        $info.detail = ('no DSH profile declares "' + $bundleRel + '" under ' + $profilesDir)
        return [pscustomobject]$info
    }
    $selectedDir = Join-Path $profilesDir $selectedName
    $info.selectedName = $selectedName
    $info.selectedDir = $selectedDir
    if (-not (Test-DirExists $selectedDir)) {
        $info.outcome = 'NOT_FOUND'
        $info.detail = "selected profile '$selectedName' does not exist under $profilesDir"
        return [pscustomobject]$info
    }
    $pkgPath = Join-Path $selectedDir 'package.json'
    if (Test-FileExists $pkgPath) {
        try {
            $info.packageJsonSha256 = Get-Sha256File $pkgPath
            $pkg = Read-JsonDocument $pkgPath
            $deps = Get-JsonPropertyValue $pkg 'dependencies'
            $depValue = Get-JsonPropertyValue $deps $bundleRel
            if ($null -ne $depValue) { $info.dependencyValue = [string]$depValue }
        } catch {
            $info.detail = 'selected profile package.json is unreadable'
        }
    }
    $junctionPath = Join-Path $selectedDir 'node_modules\@local\dsh-cnki-research'
    $info.junctionPath = $junctionPath
    $info.junctionIsReparse = (Test-ReparsePoint $junctionPath)
    if ($info.junctionIsReparse) {
        try {
            $item = Get-Item -LiteralPath (Get-IoPath $junctionPath) -Force -ErrorAction Stop
            $targetVal = $item.Target
            if ($targetVal -is [array]) { $targetVal = $targetVal[0] }
            if (-not [string]::IsNullOrEmpty([string]$targetVal)) {
                $info.junctionTarget = Get-NormalizedFullPath ([string]$targetVal)
            }
        } catch { $info.junctionTarget = $null }
    }
    $expected = Join-Path $InstallRoot 'bundle\cnki-research'
    try { $info.expectedTarget = Get-NormalizedFullPath $expected } catch { $info.expectedTarget = $null }
    if (-not [string]::IsNullOrEmpty($info.packageJsonSha256)) {
        $fpText = ([string]$selectedName) + "`n" + $info.packageJsonSha256 + "`n" +
            ([string]$info.dependencyValue) + "`n" + ([string]$info.junctionTarget) + "`n"
        $info.fingerprint = Get-Sha256Text $fpText
    }
    if (-not $info.junctionIsReparse) {
        $info.outcome = 'NOT_THIS_INSTALL'
        $info.detail = ("profile '$selectedName' does not resolve $bundleRel through a directory junction " +
            "(missing node_modules link or copy mode); the upgrade of this install root will not affect that DSH profile")
    } elseif ([string]::IsNullOrEmpty($info.junctionTarget)) {
        $info.outcome = 'NOT_THIS_INSTALL'
        $info.detail = ("profile '$selectedName' junction target could not be resolved")
    } elseif ($info.expectedTarget -and [string]::Equals($info.junctionTarget, $info.expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
        $info.outcome = 'MATCH'
        $info.detail = "profile '$selectedName' resolves $bundleRel -> $($info.junctionTarget)"
    } else {
        $info.outcome = 'NOT_THIS_INSTALL'
        $info.detail = ("profile '$selectedName' resolves $bundleRel -> '$($info.junctionTarget)' " +
            "which is not this install root's bundle directory '$($info.expectedTarget)'")
    }
    return [pscustomobject]$info
}

function Get-DriveFreeBytes {
    param([string]$Path)
    try {
        $full = Get-NormalizedFullPath $Path
        $root = [System.IO.Path]::GetPathRoot($full)
        $di = New-Object System.IO.DriveInfo($root)
        return [long]$di.AvailableFreeSpace
    } catch { return -1 }
}

function Get-WriteAccessAssessment {
    # ACL-only assessment (never writes, never probes). PASS or WARN(WRITE_ACCESS_UNPROVEN).
    # v2: directories that do not exist yet (parents of operation="add" files) are resolved
    # to their nearest existing ancestor; the engine will create them inside the install
    # root, so a missing directory is not itself a problem.
    param([string]$InstallRoot, [string[]]$FilePaths)
    $issues = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    [void]$dirs.Add($InstallRoot)
    if ($null -ne $FilePaths) {
        foreach ($f in $FilePaths) {
            $parent = [System.IO.Path]::GetDirectoryName((ConvertTo-FsPath $f))
            if ([string]::IsNullOrEmpty($parent)) { continue }
            $full = Join-Path $InstallRoot $parent
            $known = $false
            foreach ($d in $dirs) { if ([string]::Equals($d, $full, [System.StringComparison]::OrdinalIgnoreCase)) { $known = $true; break } }
            if (-not $known) { [void]$dirs.Add($full) }
        }
    }
    $rootFull = $InstallRoot
    foreach ($d in $dirs) {
        $probe = $d
        $guard = 0
        while (-not (Test-DirExists $probe) -and $guard -lt 64) {
            $guard++
            $parentDir = [System.IO.Path]::GetDirectoryName($probe)
            if ([string]::IsNullOrEmpty($parentDir)) { break }
            if (-not (Test-PathUnder $probe $rootFull) -and -not [string]::Equals($probe, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { break }
            $probe = $parentDir
        }
        if (-not (Test-DirExists $probe)) { [void]$issues.Add("directory missing and no existing ancestor: $d"); continue }
        $allowed = $false
        try {
            $acl = Get-Acl -LiteralPath (Get-IoPath $probe) -ErrorAction Stop
            foreach ($rule in @($acl.Access)) {
                if ([string]$rule.AccessControlType -ne 'Allow') { continue }
                $rights = [string]$rule.FileSystemRights
                if ($rights -match '(?i)Write|Modify|FullControl|CreateFiles|AppendData') { $allowed = $true; break }
            }
        } catch { $allowed = $false }
        if (-not $allowed) { [void]$issues.Add("write permission could not be proven for directory: $probe") }
    }
    if ($null -ne $FilePaths) {
        foreach ($f in $FilePaths) {
            $full = Join-Path $InstallRoot (ConvertTo-FsPath $f)
            $attr = Get-FileAttributesSafe $full
            if ($null -ne $attr -and (($attr -band [System.IO.FileAttributes]::ReadOnly) -ne 0)) {
                [void]$issues.Add("target file has the ReadOnly attribute: $f")
            }
        }
    }
    if ($issues.Count -eq 0) {
        return [ordered]@{ status = 'PASS'; detail = 'current user appears to have write access to the install root and all changed-file directories (directories to be created are checked via their nearest existing ancestor)' }
    }
    $first = @($issues | Select-Object -First 5) -join '; '
    return [ordered]@{ status = 'WARN'; detail = ('WRITE_ACCESS_UNPROVEN: ' + $first) }
}


#endregion

#region ============================== package inventory / integrity ==================

function Get-PackageFileInventory {
    # Files under a directory as manifest-style relative paths ('/'), no reparse-point
    # descent. Optional -ExcludePrefixes skips whole subtrees (self-mode package roots
    # contain installer-generated .venv/ and _portable/ directories).
    param([string]$Root, [string[]]$ExcludePrefixes)
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-DirExists $Root)) { return $out.ToArray() }
    $rootFull = Get-NormalizedFullPath $Root
    $excludes = New-Object System.Collections.ArrayList
    if ($null -ne $ExcludePrefixes) {
        foreach ($p in $ExcludePrefixes) {
            $np = ConvertTo-ManifestPath ([string]$p).Trim('/')
            if ($np.Length -gt 0) { [void]$excludes.Add($np) }
        }
    }
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        foreach ($entry in (Get-DirectoryEntries $dir)) {
            $attr = Get-FileAttributesSafe $entry
            if ($null -eq $attr) { continue }
            $rel = ConvertTo-ManifestPath (Get-RelativePathUnder $entry $rootFull)
            $skip = $false
            foreach ($ex in $excludes) {
                if ($rel -ieq $ex -or $rel.StartsWith($ex + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
            }
            if ($skip) { continue }
            if (($attr -band [System.IO.FileAttributes]::Directory) -ne 0) {
                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($entry)
            } else {
                [void]$out.Add($rel)
            }
        }
    }
    return $out.ToArray()
}


function ConvertTo-ShaMap {
    param($JsonObject, [string]$MapName, [string]$ChecksCheckId)
    $map = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $JsonObject) { throw "$MapName is missing" }
    foreach ($prop in $JsonObject.PSObject.Properties) {
        $key = [string]$prop.Name
        $val = [string]$prop.Value
        if ($val -notmatch '^[0-9a-fA-F]{64}$') { throw "$MapName['$key'] is not a sha256" }
        if ($map.ContainsKey($key)) { throw "$MapName contains duplicate path '$key'" }
        $map[$key] = $val.ToLowerInvariant()
    }
    return $map
}

function Get-PackageIntegrity {
    # v2 package self-integrity for the unified distribution package
    # (package root IS the RC3 distribution tree; no payload/ directory).
    # Verifies: SHA256SUMS.txt (parse/set/hashes) -> manifest.json (schema 1, identity,
    # files[] map equality) -> upgrade-data/rc2-to-rc3.json (schema 2, identity, operation
    # rules, payloadSetHash, acyclic hash rules) -> target bytes present with target hashes.
    # Adds patch.* checks; returns a data object consumed by Invoke-CoreChecks.
    # Optional -InstallRoot enables self-mode (PackageRoot == InstallRoot) relaxation of
    # the package file-set sealing for installer-generated files only.
    param([string]$PackageRoot, $Checks, [string]$InstallRoot)
    $data = [ordered]@{
        valid                  = $false
        packageRoot            = $null
        selfMode               = $false
        sumsPath               = $null
        sumsSha256             = $null
        sumsEntries            = @()
        sumsMap                = $null
        manifestPath           = $null
        manifestSha256         = $null
        manifestRelPath        = $script:DistributionManifestRelPath
        metadataPath           = $null
        metadataSha256         = $null
        metadataDoc            = $null
        targetManifest         = $null
        targetFilesMap         = $null
        targetFileBytesMap     = $null
        expectedSource         = $null
        expectedTarget         = $null
        sourcePayloadPaths     = @()
        targetPayloadPaths     = @()
        addedPayloadPaths      = @()
        payloadPathSet         = $null
        resolvedTargetHashes   = $null
        payloadRoot            = $script:PayloadRootDefault
        targetRoot             = $null
        sourcePayloadFileCount = 0
        targetPayloadFileCount = 0
        changedFileCount       = 0
        addedFileCount         = 0
        changedFiles           = @()
        envFiles               = @()
        allowedSourceStates    = @()
        payloadNamespaces      = @()
        upgraderVersion        = $null
        upgradeId              = $null
        distributionId         = $null
        forbiddenPaths         = @()
        requiredFiles          = @()
        sourceIdentity         = [ordered]@{}
        targetManifestInfo     = [ordered]@{}
    }
    try { $data.packageRoot = Get-NormalizedFullPath $PackageRoot } catch { $data.packageRoot = $PackageRoot }
    $root = [string]$data.packageRoot
    try {
        if (-not [string]::IsNullOrEmpty($InstallRoot)) {
            $ir = Get-NormalizedFullPath $InstallRoot
            if ([string]::Equals($ir, $root, [System.StringComparison]::OrdinalIgnoreCase)) { $data.selfMode = $true }
        }
    } catch { }
    $selfMode = [bool]$data.selfMode

    # ---- patch.sumsFile -------------------------------------------------------------
    $sumsPath = Join-Path $root $script:SumsFileName
    $data.sumsPath = $sumsPath
    if (-not (Test-DirExists $root)) {
        Add-Check $Checks 'patch.sumsFile' 'FAIL' "package root does not exist: $root"
        return [pscustomobject]$data
    }
    if (-not (Test-FileExists $sumsPath)) {
        Add-Check $Checks 'patch.sumsFile' 'FAIL' "SHA256SUMS.txt not found at package root: $sumsPath"
        return [pscustomobject]$data
    }
    $data.sumsSha256 = Get-Sha256File $sumsPath
    $sumsEntries = New-Object System.Collections.ArrayList
    $sumsProblems = New-Object System.Collections.ArrayList
    $lineNo = 0
    foreach ($line in ((Read-TextFileUtf8 $sumsPath) -split "`n")) {
        $lineNo++
        $t = $line.TrimEnd("`r")
        if ($t.Trim().Length -eq 0) { continue }
        $m = [regex]::Match($t, '^([0-9a-fA-F]{64})\s+\*?(.+)$')
        if (-not $m.Success) { [void]$sumsProblems.Add("line $lineNo has invalid format"); continue }
        $rel = ($m.Groups[2].Value).Trim()
        $rel = $rel.Replace('\', '/')
        if ($rel -match '^\./') { $rel = $rel.Substring(2) }
        $pathProblems = @(Test-SafeRelativePath $rel)
        if ($pathProblems.Count -gt 0) { [void]$sumsProblems.Add("line $lineNo has unsafe path '$rel': $($pathProblems -join ',')"); continue }
        [void]$sumsEntries.Add([ordered]@{ sha256 = $m.Groups[1].Value.ToLowerInvariant(); path = $rel })
    }
    $dupePaths = @{}
    foreach ($e in $sumsEntries) {
        $lk = ([string]$e['path']).ToLowerInvariant()
        if ($dupePaths.ContainsKey($lk)) { [void]$sumsProblems.Add("duplicate path in SHA256SUMS.txt: $($e['path'])") }
        else { $dupePaths[$lk] = $true }
    }
    if ($sumsProblems.Count -gt 0) {
        Add-Check $Checks 'patch.sumsFile' 'FAIL' ("SHA256SUMS.txt is invalid: " + ((@($sumsProblems) | Select-Object -First 5) -join '; '))
        return [pscustomobject]$data
    }
    $sumsMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $sumsEntries) { $sumsMap[[string]$e['path']] = [string]$e['sha256'] }
    $data.sumsEntries = $sumsEntries.ToArray()
    $data.sumsMap = $sumsMap
    Add-Check $Checks 'patch.sumsFile' 'PASS' ("SHA256SUMS.txt parsed: $($sumsEntries.Count) entries, sha256 $($data.sumsSha256)")

    # ---- patch.layout ---------------------------------------------------------------
    $layoutProblems = New-Object System.Collections.ArrayList
    $layoutNotes = New-Object System.Collections.ArrayList
    if (Test-DirExists (Join-Path $root 'payload')) {
        [void]$layoutProblems.Add(('a payload/ directory exists in the package root; the unified package must not duplicate the target payload (target bytes are read from the package root itself)'))
    }
    $manifestPath = Join-Path $root $script:DistributionManifestRelPath
    $metadataPath = Join-Path $root (ConvertTo-FsPath $script:UpgradeDataRelPath)
    $data.manifestPath = $manifestPath
    $data.metadataPath = $metadataPath
    if (-not (Test-FileExists $manifestPath)) { [void]$layoutProblems.Add("target distribution manifest is missing: $script:DistributionManifestRelPath") }
    if (-not (Test-FileExists $metadataPath)) { [void]$layoutProblems.Add("upgrade metadata file is missing: $($script:UpgradeDataRelPath)") }
    if (-not (Test-FileExists (Join-Path $root 'VERSION'))) { [void]$layoutProblems.Add('VERSION is missing at the package root') }
    if (-not (Test-FileExists (Join-Path $root $script:UpgradeDataReadmeRelPath))) { [void]$layoutNotes.Add("optional package metadata not present: $($script:UpgradeDataReadmeRelPath)") }
    if ($selfMode) { [void]$layoutNotes.Add('SELF_MODE: PackageRoot equals InstallRoot; package-root sealing is relaxed for installer-generated files') }
    if ($layoutProblems.Count -gt 0) {
        Add-Check $Checks 'patch.layout' 'FAIL' ((@($layoutProblems) | Select-Object -First 10) -join '; ')
        return [pscustomobject]$data
    }
    $layoutDetail = 'package layout valid: payloadRoot=".", manifest.json + VERSION + upgrade-data/rc2-to-rc3.json + SHA256SUMS.txt present, no payload/ directory'
    if ($layoutNotes.Count -gt 0) { $layoutDetail = $layoutDetail + ' | ' + ((@($layoutNotes)) -join '; ') }
    Add-Check $Checks 'patch.layout' 'PASS' $layoutDetail

    # ---- patch.metadataFile (upgrade-data/rc2-to-rc3.json) --------------------------
    $metadataSha = Get-Sha256File $metadataPath
    $data.metadataSha256 = $metadataSha
    $metaListedSha = ''
    if ($sumsMap.ContainsKey($script:UpgradeDataRelPath)) { $metaListedSha = [string]$sumsMap[$script:UpgradeDataRelPath] }
    if ([string]::IsNullOrEmpty($metaListedSha)) {
        Add-Check $Checks 'patch.metadataFile' 'FAIL' "SHA256SUMS.txt does not list $($script:UpgradeDataRelPath)"
        return [pscustomobject]$data
    }
    if (-not [string]::Equals($metaListedSha, $metadataSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Check $Checks 'patch.metadataFile' 'FAIL' ("SHA256SUMS.txt hash for $($script:UpgradeDataRelPath) does not match the actual file")
        return [pscustomobject]$data
    }
    $metadata = $null
    try { $metadata = Read-JsonDocument $metadataPath } catch {
        Add-Check $Checks 'patch.metadataFile' 'FAIL' "upgrade-data is unreadable: $($_.Exception.Message)"
        return [pscustomobject]$data
    }
    $data.metadataDoc = $metadata
    if ([int](Get-JsonPropertyValue $metadata 'schemaVersion') -ne $script:MetadataSchemaVersion) {
        Add-Check $Checks 'patch.metadataFile' 'FAIL' ("upgrade-data schemaVersion must be $($script:MetadataSchemaVersion) (got '" + [string](Get-JsonPropertyValue $metadata 'schemaVersion') + "')")
        return [pscustomobject]$data
    }
    Add-Check $Checks 'patch.metadataFile' 'PASS' ("upgrade-data/rc2-to-rc3.json present, listed in SHA256SUMS.txt and parsed (sha256 $metadataSha)")

    # ---- patch.fileSet --------------------------------------------------------------
    $excludePrefixes = @()
    if ($selfMode) { $excludePrefixes = @('.venv', '_portable') }
    $actual = @(Get-PackageFileInventory -Root $root -ExcludePrefixes $excludePrefixes)
    $actualSet = @{}
    $unknown = New-Object System.Collections.ArrayList
    foreach ($rel in $actual) {
        $lk = ([string]$rel).ToLowerInvariant()
        if ($lk -eq 'sha256sums.txt') { continue }
        $actualSet[$lk] = $rel
        if (-not $sumsMap.ContainsKey([string]$rel)) { [void]$unknown.Add([string]$rel) }
    }
    $missingListed = New-Object System.Collections.ArrayList
    foreach ($e in $sumsEntries) {
        $lk = ([string]$e['path']).ToLowerInvariant()
        if (-not $actualSet.ContainsKey($lk)) { [void]$missingListed.Add([string]$e['path']) }
    }
    if ($missingListed.Count -gt 0) {
        Add-Check $Checks 'patch.fileSet' 'FAIL' ('listed in SHA256SUMS.txt but missing from the package: ' + ((@($missingListed) | Select-Object -First 10) -join ', '))
        return [pscustomobject]$data
    }
    if (-not $selfMode) {
        if ($unknown.Count -gt 0) {
            Add-Check $Checks 'patch.fileSet' 'FAIL' ('unlisted files in the package root (package sealing broken): ' + ((@($unknown) | Select-Object -First 10) -join ', '))
            return [pscustomobject]$data
        }
        Add-Check $Checks 'patch.fileSet' 'PASS' ("package file set matches SHA256SUMS.txt exactly ($($sumsEntries.Count) files)")
    } else {
        # Self-mode: installer-generated files and user files may exist. Unlisted files
        # below a payload namespace are a tampering signal (FAIL); anything else is WARN.
        $payloadNamespaceSet = @{}
        $payloadNamespaces = New-Object System.Collections.ArrayList
        $expectedTargetForNamespaces = Get-JsonPropertyValue $metadata 'expectedTargetHashes'
        if ($null -ne $expectedTargetForNamespaces) {
            foreach ($prop in $expectedTargetForNamespaces.PSObject.Properties) {
                $np = [string]$prop.Name
                $idx = $np.IndexOf('/')
                $ns = ''
                if ($idx -gt 0) { $ns = $np.Substring(0, $idx) } else { $ns = $np }
                if (-not $payloadNamespaceSet.ContainsKey($ns)) { $payloadNamespaceSet[$ns] = $true; [void]$payloadNamespaces.Add($ns) }
            }
        }
        $data.payloadNamespaces = $payloadNamespaces.ToArray()
        $allowedExtra = @{}
        foreach ($p in $script:SelfModeAllowedExtraPaths) { $allowedExtra[(ConvertTo-ManifestPath $p).ToLowerInvariant()] = $true }
        $badUnlisted = New-Object System.Collections.ArrayList
        $warnUnlisted = New-Object System.Collections.ArrayList
        foreach ($rel in $unknown) {
            $lk = ([string]$rel).ToLowerInvariant()
            if ($allowedExtra.ContainsKey($lk)) { continue }
            $idx = ([string]$rel).IndexOf('/')
            $ns = ''
            if ($idx -gt 0) { $ns = ([string]$rel).Substring(0, $idx) }
            if ($ns.Length -gt 0 -and $payloadNamespaceSet.ContainsKey($ns)) { [void]$badUnlisted.Add([string]$rel) }
            else { [void]$warnUnlisted.Add([string]$rel) }
        }
        if ($badUnlisted.Count -gt 0) {
            Add-Check $Checks 'patch.fileSet' 'FAIL' ('unlisted file(s) below a payload namespace in self mode: ' + ((@($badUnlisted) | Select-Object -First 10) -join ', '))
            return [pscustomobject]$data
        }
        if ($warnUnlisted.Count -gt 0) {
            Add-Check $Checks 'patch.fileSet' 'WARN' ("SELF_MODE: package sealed except for installer/user files: " + ((@($warnUnlisted) | Select-Object -First 10) -join ', '))
        } else {
            Add-Check $Checks 'patch.fileSet' 'PASS' ("SELF_MODE: package file set matches SHA256SUMS.txt ($($sumsEntries.Count) files) after excluding installer-generated .venv/_portable")
        }
    }

    # ---- patch.hashes ---------------------------------------------------------------
    $hashProblems = New-Object System.Collections.ArrayList
    foreach ($e in $sumsEntries) {
        $full = Join-Path $root (ConvertTo-FsPath ([string]$e['path']))
        if (-not (Test-FileExists $full)) { [void]$hashProblems.Add("missing: $($e['path'])"); continue }
        try { $actualSha = Get-Sha256File $full } catch { [void]$hashProblems.Add("unreadable: $($e['path'])"); continue }
        if (-not [string]::Equals($actualSha, [string]$e['sha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$hashProblems.Add("hash mismatch: $($e['path'])")
        }
    }
    if ($hashProblems.Count -gt 0) {
        Add-Check $Checks 'patch.hashes' 'FAIL' ((@($hashProblems) | Select-Object -First 10) -join '; ')
        return [pscustomobject]$data
    }
    Add-Check $Checks 'patch.hashes' 'PASS' ("all $($sumsEntries.Count) package files match their SHA256SUMS.txt hashes")

    # ---- patch.manifest (upgrade-data schema/identity/rules) -----------------------
    $manifestProblems = New-Object System.Collections.ArrayList
    $kind = [string](Get-JsonPropertyValue $metadata 'kind')
    if ($kind -ne $script:ManifestKind) { [void]$manifestProblems.Add("kind must be '$($script:ManifestKind)' (got '$kind')") }
    $upgradeId = [string](Get-JsonPropertyValue $metadata 'upgradeId')
    if ($upgradeId -ne $script:UpgradeId) { [void]$manifestProblems.Add("upgradeId must be '$($script:UpgradeId)' (got '$upgradeId')") }
    $upgraderVersion = [string](Get-JsonPropertyValue $metadata 'upgraderVersion')
    if ($upgraderVersion -ne $script:ToolVersion) { [void]$manifestProblems.Add("upgraderVersion must be '$($script:ToolVersion)' (got '$upgraderVersion')") }
    $distributionId = [string](Get-JsonPropertyValue $metadata 'distributionId')
    if ($distributionId -ne $script:DistributionId) { [void]$manifestProblems.Add("distributionId must be '$($script:DistributionId)' (got '$distributionId')") }
    $createdUtc = [string](Get-JsonPropertyValue $metadata 'createdUtc')
    if ([string]::IsNullOrEmpty($createdUtc)) { [void]$manifestProblems.Add('createdUtc is missing (reproducible fixed constant required)') }
    if ([string](Get-JsonPropertyValue $metadata 'sourceDistributionVersion') -ne $script:SourceVersion) {
        [void]$manifestProblems.Add("sourceDistributionVersion must be '$($script:SourceVersion)'")
    }
    if ([string](Get-JsonPropertyValue $metadata 'targetDistributionVersion') -ne $script:TargetVersion) {
        [void]$manifestProblems.Add("targetDistributionVersion must be '$($script:TargetVersion)'")
    }
    $payloadRoot = [string](Get-JsonPropertyValue $metadata 'payloadRoot')
    if ($payloadRoot -ne $script:PayloadRootDefault) {
        [void]$manifestProblems.Add("payloadRoot must be '$($script:PayloadRootDefault)' (got '$payloadRoot')")
    }
    $distManifestSchema = Get-JsonPropertyValue $metadata 'distributionManifestSchemaVersion'
    if ($null -eq $distManifestSchema -or [int]$distManifestSchema -ne 1) {
        [void]$manifestProblems.Add('distributionManifestSchemaVersion must be 1 (the distribution manifest stays schemaVersion 1)')
    }
    $removedFileCount = Get-JsonPropertyValue $metadata 'removedFileCount'
    if ($null -ne $removedFileCount -and [int]$removedFileCount -ne 0) {
        [void]$manifestProblems.Add('removedFileCount must be 0 (payload removals are not supported)')
    }
    $changedFilesRaw = Get-JsonPropertyValue $metadata 'changedFiles'
    $envFilesRaw = Get-JsonPropertyValue $metadata 'environmentFiles'
    $allowedStatesRaw = Get-JsonPropertyValue $metadata 'allowedSourceStates'
    $expectedSourceRaw = Get-JsonPropertyValue $metadata 'expectedSourceHashes'
    $expectedTargetRaw = Get-JsonPropertyValue $metadata 'expectedTargetHashes'
    if ($null -eq $changedFilesRaw) { [void]$manifestProblems.Add('changedFiles is missing') }
    if ($null -eq $envFilesRaw) { [void]$manifestProblems.Add('environmentFiles is missing') }
    if ($null -eq $allowedStatesRaw) { [void]$manifestProblems.Add('allowedSourceStates is missing') }
    foreach ($section in @('hotfixedSourceOverrides', 'preservedDirectories', 'rollbackMetadata', 'minimumRequirements', 'validation', 'forbiddenPaths')) {
        if ($null -eq (Get-JsonPropertyValue $metadata $section)) { [void]$manifestProblems.Add("$section is missing") }
    }
    $allowedStates = New-Object System.Collections.ArrayList
    if ($null -ne $allowedStatesRaw) {
        foreach ($s in @($allowedStatesRaw)) { [void]$allowedStates.Add([string]$s) }
        foreach ($state in @('RC2_CLEAN', 'RC2_HOTFIXED')) {
            if (-not ($allowedStates -contains $state)) { [void]$manifestProblems.Add("allowedSourceStates is missing '$state'") }
        }
    }
    $expectedSource = $null
    $expectedTarget = $null
    try {
        $expectedSource = ConvertTo-ShaMap $expectedSourceRaw 'expectedSourceHashes' 'patch.manifest'
        $expectedTarget = ConvertTo-ShaMap $expectedTargetRaw 'expectedTargetHashes' 'patch.manifest'
    } catch { [void]$manifestProblems.Add($_.Exception.Message) }
    $sourcePayloadFileCount = [int](Get-JsonPropertyValue $metadata 'sourcePayloadFileCount')
    $payloadFileCount = [int](Get-JsonPropertyValue $metadata 'payloadFileCount')
    if ($null -ne $expectedSource -and $sourcePayloadFileCount -ne $expectedSource.Count) {
        [void]$manifestProblems.Add("sourcePayloadFileCount ($sourcePayloadFileCount) does not equal expectedSourceHashes.Count ($($expectedSource.Count))")
    }
    if ($null -ne $expectedTarget -and $payloadFileCount -ne $expectedTarget.Count) {
        [void]$manifestProblems.Add("payloadFileCount ($payloadFileCount) does not equal expectedTargetHashes.Count ($($expectedTarget.Count))")
    }
    if ($sourcePayloadFileCount -ne $script:SourcePayloadFileCount) {
        [void]$manifestProblems.Add("sourcePayloadFileCount must be $($script:SourcePayloadFileCount) (frozen RC2 payload anchor); got $sourcePayloadFileCount")
    }
    $changedFiles = @()
    if ($null -ne $changedFilesRaw) { $changedFiles = @($changedFilesRaw) }
    $envFiles = @()
    if ($null -ne $envFilesRaw) { $envFiles = @($envFilesRaw) }
    $changedFileCount = Get-JsonPropertyValue $metadata 'changedFileCount'
    $addedFileCount = Get-JsonPropertyValue $metadata 'addedFileCount'
    if ($null -eq $changedFileCount -or [int]$changedFileCount -ne $changedFiles.Count) {
        [void]$manifestProblems.Add("changedFileCount (" + [string]$changedFileCount + ") does not equal changedFiles.Count (" + $changedFiles.Count + ")")
    }
    $t = Get-JsonPropertyValue $metadata 'targetManifestHash'
    if ([string]::IsNullOrEmpty([string]$t) -or ([string]$t) -notmatch '^[0-9a-fA-F]{64}$') {
        [void]$manifestProblems.Add('targetManifestHash is missing or not a sha256')
    }
    if ($manifestProblems.Count -gt 0) {
        Add-Check $Checks 'patch.manifest' 'FAIL' ((@($manifestProblems) | Select-Object -First 10) -join '; ')
        return [pscustomobject]$data
    }
    $data.expectedSource = $expectedSource
    $data.expectedTarget = $expectedTarget
    $data.changedFiles = $changedFiles
    $data.envFiles = $envFiles
    $data.allowedSourceStates = $allowedStates.ToArray()
    $data.payloadRoot = $payloadRoot
    $data.upgraderVersion = $upgraderVersion
    $data.upgradeId = $upgradeId
    $data.distributionId = $distributionId
    $data.sourcePayloadFileCount = $sourcePayloadFileCount
    $data.targetPayloadFileCount = $payloadFileCount
    $data.changedFileCount = $changedFiles.Count
    $forbiddenPaths = @()
    $forbiddenRaw = Get-JsonPropertyValue $metadata 'forbiddenPaths'
    if ($null -ne $forbiddenRaw) { foreach ($fp in @($forbiddenRaw)) { $forbiddenPaths += [string]$fp } }
    $data.forbiddenPaths = $forbiddenPaths
    $targetRoot = Join-Path $root (ConvertTo-FsPath $payloadRoot)
    try { $targetRoot = Get-NormalizedFullPath $targetRoot } catch { }
    $data.targetRoot = $targetRoot
    $sourcePaths = New-Object System.Collections.ArrayList
    foreach ($k in @($expectedSource.Keys)) { [void]$sourcePaths.Add([string]$k) }
    $targetPaths = New-Object System.Collections.ArrayList
    foreach ($k in @($expectedTarget.Keys)) { [void]$targetPaths.Add([string]$k) }
    $data.sourcePayloadPaths = @(Sort-Ordinal $sourcePaths.ToArray())
    $data.targetPayloadPaths = @(Sort-Ordinal $targetPaths.ToArray())
    $payloadSet = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $data.sourcePayloadPaths) { $payloadSet[$p] = $true }
    foreach ($p in $data.targetPayloadPaths) { $payloadSet[$p] = $true }
    $data.payloadPathSet = $payloadSet
    Add-Check $Checks 'patch.manifest' 'PASS' ("upgrade-data valid: schemaVersion $($script:MetadataSchemaVersion), $($changedFiles.Count) changed files, " +
        "$sourcePayloadFileCount/$payloadFileCount expected source/target hashes, sha256 $metadataSha")

    # ---- patch.identity (schema-2 identity + source anchors + hotfix whitelist) ----
    $identityProblems = New-Object System.Collections.ArrayList
    $identityFields = @(
        @{ name = 'sourceManifestHash'; expected = $script:SourceManifestHash },
        @{ name = 'sourcePackageHash'; expected = $script:SourcePackageHash }
    )
    foreach ($f in $identityFields) {
        $actualVal = [string](Get-JsonPropertyValue $metadata $f.name)
        if ([string]::IsNullOrEmpty($actualVal)) { [void]$identityProblems.Add("metadata field '$($f.name)' is missing") }
        elseif (-not [string]::Equals($actualVal.ToLowerInvariant(), ([string]$f.expected).ToLowerInvariant(), [System.StringComparison]::Ordinal)) {
            [void]$identityProblems.Add("metadata field '$($f.name)' does not match the frozen RC2 trust anchor")
        }
    }
    $sourceBytes = Get-JsonPropertyValue $metadata 'sourcePackageBytes'
    if ($null -eq $sourceBytes -or [long]$sourceBytes -ne [long]$script:SourcePackageBytes) {
        [void]$identityProblems.Add("sourcePackageBytes must be $($script:SourcePackageBytes)")
    }
    $targetPkgHashProp = $metadata.PSObject.Properties['targetPackageHash']
    if ($null -ne $targetPkgHashProp -and $null -ne $targetPkgHashProp.Value -and -not [string]::IsNullOrEmpty([string]$targetPkgHashProp.Value)) {
        [void]$identityProblems.Add('targetPackageHash must be null/absent (the release ZIP hash can only be anchored externally; embedding it would create a hash cycle)')
    }
    foreach ($banned in @('targetSumsHash', 'sha256')) {
        if ($null -ne $metadata.PSObject.Properties[$banned]) { [void]$identityProblems.Add("forbidden cyclic field '$banned' is present in upgrade-data") }
    }
    $hotfixed = Get-JsonPropertyValue $metadata 'hotfixedSourceOverrides'
    if ($null -ne $hotfixed) {
        foreach ($variant in @($script:HotfixedOverrides.Keys)) {
            $cordisNode = Get-JsonPropertyValue $hotfixed $script:CordisPath
            $val = $null
            if ($null -ne $cordisNode) { $val = Get-JsonPropertyValue $cordisNode $variant }
            if ([string]::IsNullOrEmpty([string]$val)) {
                [void]$identityProblems.Add("hotfixedSourceOverrides is missing '$script:CordisPath'/'$variant'")
            } elseif (-not [string]::Equals(([string]$val).ToLowerInvariant(), ([string]$script:HotfixedOverrides[$variant]).ToLowerInvariant(), [System.StringComparison]::Ordinal)) {
                [void]$identityProblems.Add("hotfixed override '$variant' does not match the trust anchor")
            }
        }
    }
    $rollbackMeta = Get-JsonPropertyValue $metadata 'rollbackMetadata'
    if ($null -ne $rollbackMeta) {
        if ([string](Get-JsonPropertyValue $rollbackMeta 'supported') -ne 'True') { [void]$identityProblems.Add('rollbackMetadata.supported must be true') }
        if ([string](Get-JsonPropertyValue $rollbackMeta 'addedFilesDeleteOnRollback') -ne 'True') { [void]$identityProblems.Add('rollbackMetadata.addedFilesDeleteOnRollback must be true') }
        if ([string](Get-JsonPropertyValue $rollbackMeta 'createdDirectoriesCleanup') -ne 'True') { [void]$identityProblems.Add('rollbackMetadata.createdDirectoriesCleanup must be true') }
    }
    # Acyclic hash rule: upgrade-data must not contain a hash of itself or of SHA256SUMS.txt.
    $allStringValues = @(Get-JsonStringValues $metadata)
    foreach ($s in $allStringValues) {
        if ([string]::Equals([string]$s, $metadataSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$identityProblems.Add('upgrade-data contains its own sha256 (self-reference / hash cycle)')
            break
        }
        if ([string]::Equals([string]$s, [string]$data.sumsSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$identityProblems.Add('upgrade-data contains the sha256 of SHA256SUMS.txt (hash cycle)')
            break
        }
    }
    if ($identityProblems.Count -gt 0) {
        Add-Check $Checks 'patch.identity' 'FAIL' ((@($identityProblems) | Select-Object -First 10) -join '; ')
    } else {
        Add-Check $Checks 'patch.identity' 'PASS' ('upgrade-data identity matches the engine release contract (schema 2 / unified upgradeId / upgrader 2.0.0 / distributionId) and the frozen RC2 anchors + hotfix whitelist; no hash cycle')
    }
    $data.targetManifestInfo = [ordered]@{
        hashEmbedded  = [string]$t
        sourceIdentity = [ordered]@{
            manifestSha256 = $script:SourceManifestHash
            packageSha256  = $script:SourcePackageHash
            packageBytes   = $script:SourcePackageBytes
            payloadFileCount = $script:SourcePayloadFileCount
        }
    }

    # ---- patch.targetManifest (distribution manifest.json, schema 1) ----------------
    $manifestSha = Get-Sha256File $manifestPath
    $data.manifestSha256 = $manifestSha
    $tmProblems = New-Object System.Collections.ArrayList
    $listedManifestSha = ''
    if ($sumsMap.ContainsKey($script:DistributionManifestRelPath)) { $listedManifestSha = [string]$sumsMap[$script:DistributionManifestRelPath] }
    if ([string]::IsNullOrEmpty($listedManifestSha)) {
        [void]$tmProblems.Add('SHA256SUMS.txt does not list manifest.json')
    } elseif (-not [string]::Equals($listedManifestSha, $manifestSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        [void]$tmProblems.Add('SHA256SUMS.txt hash for manifest.json does not match the actual file')
    }
    if (-not [string]::Equals([string]$t, $manifestSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        [void]$tmProblems.Add('upgrade-data.targetManifestHash does not equal the actual manifest.json sha256')
    }
    $targetManifest = $null
    try { $targetManifest = Read-JsonDocument $manifestPath } catch { [void]$tmProblems.Add("manifest.json is unreadable: $($_.Exception.Message)") }
    $targetFilesMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    $targetBytesMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $targetManifest) {
        $data.targetManifest = $targetManifest
        if ([int](Get-JsonPropertyValue $targetManifest 'schemaVersion') -ne 1) { [void]$tmProblems.Add('manifest.json schemaVersion must be 1') }
        $dist = Get-JsonPropertyValue $targetManifest 'distribution'
        if ([string](Get-JsonPropertyValue $dist 'version') -ne $script:TargetVersion) { [void]$tmProblems.Add("manifest.json distribution.version must be '$($script:TargetVersion)'") }
        $bundle = Get-JsonPropertyValue $targetManifest 'bundle'
        if ([string](Get-JsonPropertyValue $bundle 'version') -ne $script:BundleVersion) { [void]$tmProblems.Add("manifest.json bundle.version must be '$($script:BundleVersion)'") }
        $installNode = Get-JsonPropertyValue $targetManifest 'install'
        if ($null -ne $installNode) {
            $entryPoint = [string](Get-JsonPropertyValue $installNode 'entryPoint')
            if (-not [string]::IsNullOrEmpty($entryPoint) -and $entryPoint -ne $script:PortableEntryPoint) {
                [void]$tmProblems.Add("manifest.json install.entryPoint must stay '$($script:PortableEntryPoint)'")
            }
        }
        $files = @(Get-JsonPropertyValue $targetManifest 'files')
        if ($files.Count -ne $payloadFileCount) { [void]$tmProblems.Add("manifest.json files[] must have $payloadFileCount entries (got $($files.Count))") }
        foreach ($f in $files) {
            $fp = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $f 'path'))
            $fs = ([string](Get-JsonPropertyValue $f 'sha256')).ToLowerInvariant()
            $fb = Get-JsonPropertyValue $f 'bytes'
            if ([string]::IsNullOrEmpty($fp)) { [void]$tmProblems.Add('manifest.json files[] entry without path'); continue }
            $probs = @(Test-SafeRelativePath $fp)
            if ($probs.Count -gt 0) { [void]$tmProblems.Add("manifest.json has an unsafe payload path '$fp'"); continue }
            if ($targetFilesMap.ContainsKey($fp)) { [void]$tmProblems.Add("manifest.json lists duplicate path '$fp'"); continue }
            if ($fs -notmatch '^[0-9a-f]{64}$') { [void]$tmProblems.Add("manifest.json files[] hash for '$fp' is not a sha256"); continue }
            $targetFilesMap[$fp] = $fs
            if ($null -ne $fb) { $targetBytesMap[$fp] = [long]$fb }
            if ($fp -ieq $script:UpgradeDataRelPath) {
                [void]$tmProblems.Add('manifest.json must NOT list upgrade-data/rc2-to-rc3.json (package-only metadata; listing it would create a hash cycle)')
            }
        }
        # expectedTargetHashes must equal manifest files[] exactly.
        if ($targetFilesMap.Count -ne $expectedTarget.Count) {
            [void]$tmProblems.Add("manifest.json files[] key set differs from expectedTargetHashes (manifest=$($targetFilesMap.Count), metadata=$($expectedTarget.Count))")
        } else {
            foreach ($k in @($expectedTarget.Keys)) {
                if (-not $targetFilesMap.ContainsKey([string]$k)) { [void]$tmProblems.Add("manifest.json is missing target payload file '$k'"); break }
                if (-not [string]::Equals([string]$targetFilesMap[[string]$k], [string]$expectedTarget[[string]$k], [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$tmProblems.Add("manifest.json hash for '$k' does not equal expectedTargetHashes"); break
                }
            }
        }
    }
    $data.targetFilesMap = $targetFilesMap
    $data.targetFileBytesMap = $targetBytesMap
    if ($tmProblems.Count -gt 0) {
        Add-Check $Checks 'patch.targetManifest' 'FAIL' ((@($tmProblems) | Select-Object -First 10) -join '; ')
        return [pscustomobject]$data
    }
    Add-Check $Checks 'patch.targetManifest' 'PASS' ("manifest.json authentic by SHA256SUMS.txt + upgrade-data.targetManifestHash; $payloadFileCount payload entries equal expectedTargetHashes (sha256 $manifestSha)")

    # ---- path safety of metadata paths ---------------------------------------------
    $pathProblems = New-Object System.Collections.ArrayList
    foreach ($p in @($data.targetPayloadPaths)) {
        $probs = @(Test-SafeRelativePath $p)
        if ($probs.Count -gt 0) { [void]$pathProblems.Add("target payload path '$p': $($probs -join ',')") }
    }
    $changedSeen = @{}
    $addedPaths = New-Object System.Collections.ArrayList
    $changedPaths = New-Object System.Collections.ArrayList
    foreach ($cf in $changedFiles) {
        $p = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path'))
        if ([string]::IsNullOrEmpty($p)) { [void]$pathProblems.Add('changedFiles entry without path'); continue }
        if ($changedSeen.ContainsKey($p.ToLowerInvariant())) { [void]$pathProblems.Add("changedFiles lists duplicate path '$p'"); continue }
        $changedSeen[$p.ToLowerInvariant()] = $true
        [void]$changedPaths.Add($p)
        $probs = @(Test-SafeRelativePath $p)
        if ($probs.Count -gt 0) { [void]$pathProblems.Add("changed file path '$p': $($probs -join ',')") }
        $op = [string](Get-JsonPropertyValue $cf 'operation')
        if ($op -ne 'replace' -and $op -ne 'add') { [void]$pathProblems.Add("changed file '$p' has invalid operation '$op'") }
        if ($op -eq 'add') { [void]$addedPaths.Add($p) }
        $cls = [string](Get-JsonPropertyValue $cf 'classification')
        if ($cls -ne 'payload' -and $cls -ne 'distribution-metadata') { [void]$pathProblems.Add("changed file '$p' has invalid classification '$cls'") }
        foreach ($legacy in @('hashSource')) {
            if ($null -ne $cf.PSObject.Properties[$legacy]) { [void]$pathProblems.Add("changed file '$p' uses removed/cyclic field '$legacy'") }
        }
    }
    if ($pathProblems.Count -gt 0) {
        Add-Check $Checks 'patch.manifestSelfConsistent' 'FAIL' ((@($pathProblems) | Select-Object -First 10) -join '; ')
        return [pscustomobject]$data
    }

    # ---- patch.manifestSelfConsistent ----------------------------------------------
    $selfProblems = New-Object System.Collections.ArrayList
    # (a) no payload deletions: every source payload path must exist in the target map.
    foreach ($k in @($expectedSource.Keys)) {
        if (-not $expectedTarget.ContainsKey([string]$k)) { [void]$selfProblems.Add("source payload file '$k' is missing from expectedTargetHashes (payload deletions are not supported)"); break }
    }
    # (b) changedFiles must equal the real diff set + manifest.json.
    $diffSet = New-Object System.Collections.ArrayList
    foreach ($k in @($expectedTarget.Keys)) {
        $kp = [string]$k
        if (-not $expectedSource.ContainsKey($kp)) { [void]$diffSet.Add($kp) }
        elseif (-not [string]::Equals([string]$expectedTarget[$kp], [string]$expectedSource[$kp], [System.StringComparison]::OrdinalIgnoreCase)) { [void]$diffSet.Add($kp) }
    }
    [void]$diffSet.Add($script:DistributionManifestRelPath)
    $diffLower = @{}
    foreach ($p in $diffSet) { $diffLower[([string]$p).ToLowerInvariant()] = [string]$p }
    foreach ($p in $changedPaths) {
        if (-not $diffLower.ContainsKey($p.ToLowerInvariant())) { [void]$selfProblems.Add("changedFiles lists '$p' but its target bytes equal the RC2 bytes (not a real change)") }
    }
    foreach ($p in $diffSet) {
        if (-not $changedSeen.ContainsKey(([string]$p).ToLowerInvariant())) { [void]$selfProblems.Add("changed/added file '$p' is missing from changedFiles"); break }
    }
    # (c) per-entry rules.
    $resolvedTargetHashes = new-object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($cf in $changedFiles) {
        $p = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path'))
        $op = [string](Get-JsonPropertyValue $cf 'operation')
        $cls = [string](Get-JsonPropertyValue $cf 'classification')
        $srcSha = [string](Get-JsonPropertyValue $cf 'sourceSha256')
        $tgtSha = [string](Get-JsonPropertyValue $cf 'targetSha256')
        if ($p -ieq $script:DistributionManifestRelPath) {
            if ($op -ne 'replace') { [void]$selfProblems.Add('changedFiles manifest.json entry must be operation=replace') }
            if ($cls -ne 'distribution-metadata') { [void]$selfProblems.Add('changedFiles manifest.json entry must be classification=distribution-metadata') }
            if (-not [string]::Equals($srcSha, $script:SourceManifestHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$selfProblems.Add('changedFiles manifest.json sourceSha256 does not equal the frozen RC2 manifest hash')
            }
            if (-not [string]::Equals($tgtSha, [string]$t, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$selfProblems.Add('changedFiles manifest.json targetSha256 does not equal targetManifestHash')
            }
            $resolvedTargetHashes[$p] = [string]$t
            continue
        }
        if ($op -eq 'add') {
            if ($null -ne $cf.PSObject.Properties['sourceSha256'] -and -not [string]::IsNullOrEmpty($srcSha)) {
                [void]$selfProblems.Add("changedFiles '$p' is an add but has a sourceSha256")
            }
            if ($expectedSource.ContainsKey($p)) { [void]$selfProblems.Add("changedFiles '$p' is an add but exists in expectedSourceHashes") }
            if (-not $expectedTarget.ContainsKey($p)) { [void]$selfProblems.Add("changedFiles add '$p' is missing from expectedTargetHashes") }
            if ($tgtSha -notmatch '^[0-9a-f]{64}$') { [void]$selfProblems.Add("changedFiles add '$p' has no inline targetSha256") }
            elseif ($expectedTarget.ContainsKey($p) -and -not [string]::Equals($tgtSha, [string]$expectedTarget[$p], [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$selfProblems.Add("changedFiles add '$p' targetSha256 does not equal expectedTargetHashes")
            }
            $resolvedTargetHashes[$p] = $tgtSha
        } else {
            if (-not $expectedSource.ContainsKey($p)) {
                [void]$selfProblems.Add("changedFiles replace '$p' is missing from expectedSourceHashes")
            } else {
                $base = [string]$expectedSource[$p]
                if (-not [string]::Equals($srcSha, $base, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hotfixOk = $false
                    if ($p -ieq $script:CordisPath) {
                        foreach ($variant in @($script:HotfixedOverrides.Keys)) {
                            if ([string]::Equals($srcSha, [string]$script:HotfixedOverrides[$variant], [System.StringComparison]::OrdinalIgnoreCase)) { $hotfixOk = $true; break }
                        }
                    }
                    if (-not $hotfixOk) { [void]$selfProblems.Add("changedFiles replace '$p' sourceSha256 matches neither expectedSourceHashes nor an allowed hotfix hash") }
                }
            }
            if (-not $expectedTarget.ContainsKey($p)) { [void]$selfProblems.Add("changedFiles replace '$p' is missing from expectedTargetHashes") }
            if ($tgtSha -notmatch '^[0-9a-f]{64}$') { [void]$selfProblems.Add("changedFiles '$p' has no inline targetSha256") }
            elseif ($expectedTarget.ContainsKey($p) -and -not [string]::Equals($tgtSha, [string]$expectedTarget[$p], [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$selfProblems.Add("changedFiles '$p' targetSha256 does not equal expectedTargetHashes")
            }
            $resolvedTargetHashes[$p] = $tgtSha
        }
    }
    $resolvedTargetHashes[$script:DistributionManifestRelPath] = [string]$t
    $data.resolvedTargetHashes = $resolvedTargetHashes
    $data.addedPayloadPaths = @(Sort-Ordinal $addedPaths.ToArray())
    $data.addedFileCount = $addedPaths.Count
    if ($null -ne $addedFileCount -and [int]$addedFileCount -ne $addedPaths.Count) {
        [void]$selfProblems.Add("addedFileCount (" + [string]$addedFileCount + ") does not equal the number of operation=add changedFiles (" + $addedPaths.Count + ")")
    }
    # (d) validation.requiredFiles must cover the changed set.
    $validationNode = Get-JsonPropertyValue $metadata 'validation'
    if ($null -ne $validationNode) {
        $requiredRaw = Get-JsonPropertyValue $validationNode 'requiredFiles'
        if ($null -eq $requiredRaw) { [void]$selfProblems.Add('validation.requiredFiles is missing') }
        else {
            $requiredSet = @{}
            foreach ($rf in @($requiredRaw)) { $requiredSet[([string]$rf).ToLowerInvariant()] = [string]$rf }
            foreach ($p in $changedPaths) {
                if (-not $requiredSet.ContainsKey($p.ToLowerInvariant())) { [void]$selfProblems.Add("validation.requiredFiles is missing changed file '$p'"); break }
            }
        }
        $validationToolNames = @(Get-JsonPropertyValue $validationNode 'toolNames')
        if ($validationToolNames.Count -ne $script:RequiredToolNames.Count) { [void]$selfProblems.Add("validation.toolNames must list $($script:RequiredToolNames.Count) MCP tool names") }
        $validationResources = @(Get-JsonPropertyValue $validationNode 'mcpResources')
        if (-not ($validationResources -contains 'profile://list')) { [void]$selfProblems.Add("validation.mcpResources must list 'profile://list'") }
    }
    if ($selfProblems.Count -gt 0) {
        Add-Check $Checks 'patch.manifestSelfConsistent' 'FAIL' ((@($selfProblems) | Select-Object -First 10) -join '; ')
    } else {
        Add-Check $Checks 'patch.manifestSelfConsistent' 'PASS' ("changedFiles ($($changedPaths.Count)) equal the real RC2->target diff + manifest.json; $($addedPaths.Count) add operation(s); no payload deletions; expected maps and validation.requiredFiles consistent")
    }

    # ---- patch.targetBytes (target bytes live in the package root) -----------------
    $targetProblems = New-Object System.Collections.ArrayList
    foreach ($p in @($data.targetPayloadPaths)) {
        $full = Join-Path $targetRoot (ConvertTo-FsPath $p)
        if (-not (Test-FileExists $full)) { [void]$targetProblems.Add("target payload file missing from the package: $p"); continue }
        try {
            $sha = Get-Sha256File $full
            if (-not [string]::Equals($sha, [string]$expectedTarget[$p], [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$targetProblems.Add("target payload hash mismatch: $p")
            }
            if ($targetBytesMap.ContainsKey($p)) {
                $len = Get-FileLengthSafe $full
                if ($len -ne [long]$targetBytesMap[$p]) { [void]$targetProblems.Add("target payload byte size mismatch: $p") }
            }
        } catch { [void]$targetProblems.Add("target payload unreadable: $p") }
    }
    # declared targetBytes for changedFiles must match the actual package bytes.
    foreach ($cf in $changedFiles) {
        $p = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path'))
        $declaredBytes = Get-JsonPropertyValue $cf 'targetBytes'
        $full = Join-Path $targetRoot (ConvertTo-FsPath $p)
        if (-not (Test-FileExists $full)) { [void]$targetProblems.Add("changed file missing from the package: $p"); continue }
        if ($null -ne $declaredBytes) {
            $len = Get-FileLengthSafe $full
            if ($len -ne [long]$declaredBytes) { [void]$targetProblems.Add("changedFiles targetBytes mismatch for '$p' (declared $declaredBytes, actual $len)") }
        }
    }
    if ($targetProblems.Count -gt 0) {
        Add-Check $Checks 'patch.payloadSet' 'FAIL' ((@($targetProblems) | Select-Object -First 10) -join '; ')
    } else {
        Add-Check $Checks 'patch.payloadSet' 'PASS' ("all $payloadFileCount target payload files are present at the package root with their target hashes (target bytes read directly from PackageRoot; no duplicated payload/)")
    }

    # ---- patch.payloadSetHash -------------------------------------------------------
    $payloadSetHashProblems = New-Object System.Collections.ArrayList
    $declaredPayloadSetHash = [string](Get-JsonPropertyValue $metadata 'payloadSetHash')
    $inlineEntries = New-Object System.Collections.ArrayList
    foreach ($cf in $changedFiles) {
        if ([string](Get-JsonPropertyValue $cf 'classification') -ne 'payload') { continue }
        [void]$inlineEntries.Add($cf)
    }
    $inlinePaths = New-Object System.Collections.ArrayList
    foreach ($cf in $inlineEntries) { [void]$inlinePaths.Add((ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path')))) }
    $sortedInline = @(Sort-Ordinal $inlinePaths.ToArray())
    $material = New-Object System.Text.StringBuilder
    foreach ($p in $sortedInline) {
        $cf = $inlineEntries | Where-Object { (ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $_ 'path'))) -ceq $p } | Select-Object -First 1
        $srcSha = [string](Get-JsonPropertyValue $cf 'sourceSha256')
        $srcMarker = 'ADD'
        if ([string](Get-JsonPropertyValue $cf 'operation') -eq 'replace') { $srcMarker = $srcSha.ToLowerInvariant() }
        $tgtSha = ([string](Get-JsonPropertyValue $cf 'targetSha256')).ToLowerInvariant()
        [void]$material.Append($p + "`t" + $srcMarker + "`t" + $tgtSha + "`n")
    }
    $computedPayloadSetHash = Get-Sha256Text $material.ToString()
    if ([string]::IsNullOrEmpty($declaredPayloadSetHash)) {
        [void]$payloadSetHashProblems.Add('payloadSetHash is absent from upgrade-data (informational only)')
        Add-Check $Checks 'patch.payloadSetHash' 'WARN' $payloadSetHashProblems[0]
    } elseif (-not [string]::Equals($declaredPayloadSetHash.ToLowerInvariant(), $computedPayloadSetHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Check $Checks 'patch.payloadSetHash' 'FAIL' "upgrade-data payloadSetHash does not match the computed value ($computedPayloadSetHash)"
    } else {
        Add-Check $Checks 'patch.payloadSetHash' 'PASS' "payloadSetHash verified: $computedPayloadSetHash"
    }
    $declaredSourceSetHash = [string](Get-JsonPropertyValue $metadata 'sourcePayloadSetHash')
    if (-not [string]::IsNullOrEmpty($declaredSourceSetHash)) {
        $srcMaterial = New-Object System.Text.StringBuilder
        $srcPaths = New-Object System.Collections.ArrayList
        foreach ($k in @($expectedSource.Keys)) { [void]$srcPaths.Add([string]$k) }
        foreach ($p in @(Sort-Ordinal $srcPaths.ToArray())) {
            [void]$srcMaterial.Append($p + "`t" + ([string]$expectedSource[$p]).ToLowerInvariant() + "`n")
        }
        $computedSourceSetHash = Get-Sha256Text $srcMaterial.ToString()
        if (-not [string]::Equals($declaredSourceSetHash.ToLowerInvariant(), $computedSourceSetHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Check $Checks 'patch.sourcePayloadSetHash' 'FAIL' "upgrade-data sourcePayloadSetHash does not match the computed value ($computedSourceSetHash)"
        } else {
            Add-Check $Checks 'patch.sourcePayloadSetHash' 'PASS' "sourcePayloadSetHash verified: $computedSourceSetHash"
        }
    } else {
        Add-Check $Checks 'patch.sourcePayloadSetHash' 'WARN' 'sourcePayloadSetHash is absent from upgrade-data (optional second RC2 source anchor)'
    }
    $declaredChangedSetHash = [string](Get-JsonPropertyValue $metadata 'changedFileSetHash')
    if (-not [string]::IsNullOrEmpty($declaredChangedSetHash)) {
        $changedMaterial = New-Object System.Text.StringBuilder
        $changedPathList = New-Object System.Collections.ArrayList
        foreach ($cf in $changedFiles) { [void]$changedPathList.Add((ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path')))) }
        foreach ($p in @(Sort-Ordinal $changedPathList.ToArray())) {
            $cf = $changedFiles | Where-Object { (ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $_ 'path'))) -ceq $p } | Select-Object -First 1
            [void]$changedMaterial.Append($p + "`t" + [string](Get-JsonPropertyValue $cf 'operation') + "`n")
        }
        $computedChangedSetHash = Get-Sha256Text $changedMaterial.ToString()
        if (-not [string]::Equals($declaredChangedSetHash.ToLowerInvariant(), $computedChangedSetHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Check $Checks 'patch.changedFileSetHash' 'FAIL' "upgrade-data changedFileSetHash does not match the computed value ($computedChangedSetHash)"
        } else {
            Add-Check $Checks 'patch.changedFileSetHash' 'PASS' "changedFileSetHash verified: $computedChangedSetHash"
        }
    }

    # ---- patch.minimumRequirements --------------------------------------------------
    $minReq = Get-JsonPropertyValue $metadata 'minimumRequirements'
    $minProblems = New-Object System.Collections.ArrayList
    $minWarnings = New-Object System.Collections.ArrayList
    if ($null -eq $minReq) {
        [void]$minProblems.Add('minimumRequirements is missing')
    } else {
        $os = [string](Get-JsonPropertyValue $minReq 'os')
        if ($os -ne 'Windows') { [void]$minProblems.Add("minimumRequirements.os must be 'Windows' (got '$os')") }
        $psReq = [string](Get-JsonPropertyValue $minReq 'powershell')
        if ([string]::IsNullOrEmpty($psReq)) { [void]$minWarnings.Add('minimumRequirements.powershell is unspecified') }
        $major = [int]$PSVersionTable.PSVersion.Major
        if ($major -ne 5) { [void]$minWarnings.Add("PowerShell major version $major detected; target platform is Windows PowerShell 5.1") }
    }
    if ($minProblems.Count -gt 0) {
        Add-Check $Checks 'patch.minimumRequirements' 'FAIL' ((@($minProblems) -join '; '))
    } elseif ($minWarnings.Count -gt 0) {
        Add-Check $Checks 'patch.minimumRequirements' 'WARN' ((@($minWarnings) -join '; '))
    } else {
        Add-Check $Checks 'patch.minimumRequirements' 'PASS' 'Windows + Windows PowerShell 5.1 minimum requirements satisfied'
    }

    # ---- patch.releaseIdentity (external anchoring only) ---------------------------
    Add-Check $Checks 'patch.releaseIdentity' 'NOT TESTED' ('the unified release ZIP identity can only be verified against the externally published ZIP sha256 + external SHA256SUMS.txt/RELEASE_MANIFEST.json; no external identity file is supplied to the engine, so package authenticity rests on SHA256SUMS.txt inside the package root')

    # ---- final validity -------------------------------------------------------------
    $data.valid = -not (Test-ChecksHaveFail $Checks)
    return [pscustomobject]$data
}


#endregion

#region ============================== install-root layout / detection ================

function Test-InstallRootPathSafety {
    # Returns list of FAIL reasons for the install root itself (path.installRootSafe).
    # v2: symmetric package/install ancestry refusal:
    #   equal roots            -> INSTALL_ROOT_EQUALS_UPGRADE_PACKAGE (allowed only in self mode)
    #   install under package  -> INSTALL_ROOT_INSIDE_UPGRADE_PACKAGE
    #   package under install  -> UPGRADE_PACKAGE_INSIDE_INSTALL_ROOT (fresh/extracted tree is
    #                             never allowed to be consumed from inside an existing install)
    param([string]$InstallRoot, [string]$PackageRoot, [switch]$SelfMode)
    $reasons = New-Object System.Collections.ArrayList
    $root = Get-NormalizedFullPath $InstallRoot
    if ($root -match '^[A-Za-z]:\\$') { [void]$reasons.Add('INSTALL_ROOT_IS_DRIVE_ROOT') }
    $compareExact = New-Object System.Collections.ArrayList
    $compareUnder = New-Object System.Collections.ArrayList
    foreach ($name in @('WINDIR', 'SystemRoot', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432')) {
        $v = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($v)) { [void]$compareExact.Add($v) }
    }
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) { [void]$compareExact.Add($env:USERPROFILE) }
    $prodDsh = Get-ProductionDshHome
    if ($prodDsh) {
        [void]$compareExact.Add($prodDsh)
        [void]$compareUnder.Add($prodDsh)
    }
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) {
        [void]$compareUnder.Add((Join-Path $env:USERPROFILE '.cnki-mcp'))
    }
    if (-not [string]::IsNullOrEmpty($env:LOCALAPPDATA)) {
        [void]$compareUnder.Add((Join-Path $env:LOCALAPPDATA 'ms-playwright'))
    }
    foreach ($candidate in $compareExact) {
        try {
            if ([string]::Equals($root, (Get-NormalizedFullPath $candidate), [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$reasons.Add("INSTALL_ROOT_FORBIDDEN_LOCATION ($candidate)")
            }
        } catch { }
    }
    foreach ($candidate in $compareUnder) {
        try {
            $c = Get-NormalizedFullPath $candidate
            if ([string]::Equals($root, $c, [System.StringComparison]::OrdinalIgnoreCase) -or
                (Test-PathUnder $root $c)) {
                [void]$reasons.Add("INSTALL_ROOT_INSIDE_USER_DATA_OR_TOOL_DIR ($candidate)")
            }
        } catch { }
    }
    if (-not [string]::IsNullOrEmpty($PackageRoot)) {
        try {
            $pkg = Get-NormalizedFullPath $PackageRoot
            if ([string]::Equals($root, $pkg, [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not $SelfMode) { [void]$reasons.Add('INSTALL_ROOT_EQUALS_UPGRADE_PACKAGE') }
            } elseif (Test-PathUnder $root $pkg) {
                [void]$reasons.Add('INSTALL_ROOT_INSIDE_UPGRADE_PACKAGE')
            }
            if (-not [string]::Equals($root, $pkg, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-PathUnder $pkg $root)) {
                [void]$reasons.Add('UPGRADE_PACKAGE_INSIDE_INSTALL_ROOT')
            }
            $parent = [System.IO.Path]::GetDirectoryName($pkg)
            if (-not [string]::IsNullOrEmpty($parent)) {
                foreach ($sub in @('_analysis', '_build')) {
                    $c = Join-Path $parent $sub
                    if ([string]::Equals($root, (Get-NormalizedFullPath $c), [System.StringComparison]::OrdinalIgnoreCase) -or (Test-PathUnder $root $c)) {
                        [void]$reasons.Add("INSTALL_ROOT_INSIDE_$($sub.ToUpperInvariant())")
                    }
                }
            }
        } catch { }
    }
    return $reasons.ToArray()
}


function Get-InstallTreeHashes {
    # Hashes all expected payload paths under the install root. Records missing/unreadable status.
    param([string]$InstallRoot, [string[]]$Paths)
    $hashes = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    $kinds = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rel in @($Paths)) {
        $p = ConvertTo-ManifestPath $rel
        $full = Join-Path $InstallRoot (ConvertTo-FsPath $p)
        if (-not (Test-FileExists $full)) { $hashes[$p] = 'ABSENT'; $kinds[$p] = 'missing'; continue }
        $attr = Get-FileAttributesSafe $full
        if ($null -ne $attr -and (($attr -band [System.IO.FileAttributes]::Directory) -ne 0)) {
            $hashes[$p] = 'IS_DIRECTORY'; $kinds[$p] = 'directory'; continue
        }
        if ($null -ne $attr -and (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            $hashes[$p] = 'REPARSE_POINT'; $kinds[$p] = 'reparse'; continue
        }
        try { $hashes[$p] = Get-Sha256File $full; $kinds[$p] = 'file' } catch { $hashes[$p] = 'UNREADABLE'; $kinds[$p] = 'unreadable' }
    }
    return [ordered]@{ hashes = $hashes; kinds = $kinds }
}

function Get-LayoutDetection {
    # source.layout detection, including the separate-package-root refusal (Layout A only).
    param([string]$InstallRoot, $Checks)
    $result = [ordered]@{
        ok                = $false
        separatePackageRoot = $false
        reasons           = @()
        rootMarkers       = [ordered]@{}
        installRootExists = (Test-DirExists $InstallRoot)
    }
    if (-not $result.installRootExists) {
        Add-Check $Checks 'source.layout' 'FAIL' "install root does not exist: $InstallRoot"
        $result.reasons = @('INSTALL_ROOT_MISSING')
        return [pscustomobject]$result
    }
    $root = Get-NormalizedFullPath $InstallRoot
    $manifestPath = Join-Path $root 'manifest.json'
    $versionPath = Join-Path $root 'VERSION'
    $bundleDir = Join-Path $root 'bundle\cnki-research'
    $upstreamDir = Join-Path $root 'upstream\cnki-mcp'
    $bundlePkg = Join-Path $bundleDir 'package.json'
    $cordis = Join-Path $bundleDir 'cordis.patch.yml'
    $installState = Join-Path $root '_portable\install-state.json'
    $missing = New-Object System.Collections.ArrayList
    if (-not (Test-FileExists $manifestPath)) { [void]$missing.Add('manifest.json') }
    if (-not (Test-FileExists $versionPath)) { [void]$missing.Add('VERSION') }
    if (-not (Test-DirExists $bundleDir)) { [void]$missing.Add('bundle/cnki-research/') }
    if (-not (Test-DirExists $upstreamDir)) { [void]$missing.Add('upstream/cnki-mcp/') }
    if (-not (Test-FileExists $bundlePkg)) { [void]$missing.Add('bundle/cnki-research/package.json') }
    $result.rootMarkers = [ordered]@{
        manifestJson = (Test-FileExists $manifestPath)
        version      = (Test-FileExists $versionPath)
        bundleDir    = (Test-DirExists $bundleDir)
        upstreamDir  = (Test-DirExists $upstreamDir)
        bundlePackageJson = (Test-FileExists $bundlePkg)
    }
    if ($missing.Count -eq 0) {
        $result.ok = $true
        Add-Check $Checks 'source.layout' 'PASS' 'Layout-A in-place installation markers found (manifest.json, VERSION, bundle/cnki-research, upstream/cnki-mcp, bundle package.json)'
        return [pscustomobject]$result
    }
    $hasRootVersion = (Test-FileExists $versionPath) -or (Test-FileExists $manifestPath)
    $separate = (-not $hasRootVersion) -and (Test-FileExists $cordis) -and (Test-FileExists $installState)
    if ($separate) {
        $result.separatePackageRoot = $true
        $result.reasons = @('LAYOUT_SEPARATE_PACKAGE_ROOT')
        Add-Check $Checks 'source.layout' 'FAIL' ("LAYOUT_SEPARATE_PACKAGE_ROOT: this install root has no root manifest.json/VERSION " +
            "but has bundle/cnki-research+cordis.patch.yml and _portable/install-state.json. This upgrader supports only the " +
            "standard in-place Layout A install. Recover with: run the RC3 full package installer ('-Action install -Force') into " +
            "this install root, or re-extract RC2 and install in place, then re-run this upgrader.")
        return [pscustomobject]$result
    }
    $result.reasons = @('LAYOUT_INCOMPLETE')
    Add-Check $Checks 'source.layout' 'FAIL' ("LAYOUT_INCOMPLETE: missing required install-root markers: " + ((@($missing)) -join ', '))
    return [pscustomobject]$result
}

#endregion

#region ============================== transaction inventory ==========================

function New-TransactionId {
    $now = (Get-Date).ToUniversalTime()
    $stamp = $now.ToString('yyyyMMdd') + 'T' + $now.ToString('HHmmss') + 'Z'
    return ($stamp + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Test-TransactionIdPattern {
    param([string]$TransactionId)
    if ([string]::IsNullOrEmpty($TransactionId)) { return $false }
    return ($TransactionId -match '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$')
}

function Get-DefaultTransactionRoot {
    param([string]$InstallRoot)
    return (Get-NormalizedFullPath (Join-Path $InstallRoot $script:DefaultUpgradesDirName))
}

function Get-TransactionList {
    # Newest first (ordinal sort of directory names, reversed). Corrupt entries are reported, never deleted.
    param([string]$TransactionRoot)
    $result = New-Object System.Collections.ArrayList
    if (-not (Test-DirExists $TransactionRoot)) { return $result.ToArray() }
    $names = New-Object System.Collections.ArrayList
    foreach ($entry in (Get-DirectoryEntries $TransactionRoot)) {
        $attr = Get-FileAttributesSafe $entry
        if ($null -eq $attr) { continue }
        if (($attr -band [System.IO.FileAttributes]::Directory) -eq 0) { continue }
        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        [void]$names.Add([System.IO.Path]::GetFileName($entry))
    }
    $arr = $names.ToArray()
    if ($arr.Length -gt 1) { [System.Array]::Sort($arr, [System.StringComparer]::Ordinal) }
    $rev = New-Object System.Collections.ArrayList
    for ($i = $arr.Length - 1; $i -ge 0; $i--) {
        $id = [string]$arr[$i]
        $dir = Join-Path $TransactionRoot $id
        $txnPath = Join-Path $dir 'transaction.json'
        $rec = [ordered]@{
            id              = $id
            dir             = $dir
            transactionPath = $txnPath
            corrupt         = $false
            error           = $null
            phase           = $null
            upgradeId       = $null
            startedAt       = $null
            updatedAt       = $null
            committedAt     = $null
            raw             = $null
        }
        if (-not (Test-FileExists $txnPath)) {
            $rec.corrupt = $true
            $rec.error = 'transaction.json is missing'
        } else {
            try {
                $raw = Read-JsonDocument $txnPath
                $rec.raw = $raw
                $rec.phase = [string](Get-JsonPropertyValue $raw 'phase')
                $rec.upgradeId = [string](Get-JsonPropertyValue $raw 'upgradeId')
                $rec.startedAt = [string](Get-JsonPropertyValue $raw 'startedAt')
                $rec.updatedAt = [string](Get-JsonPropertyValue $raw 'updatedAt')
                $rec.committedAt = [string](Get-JsonPropertyValue $raw 'committedAt')
                if ([string]::IsNullOrEmpty($rec.phase)) { $rec.corrupt = $true; $rec.error = 'transaction.json has no phase' }
            } catch {
                $rec.corrupt = $true
                $rec.error = $_.Exception.Message
            }
        }
        [void]$rev.Add($rec)
    }
    return $rev.ToArray()
}

#endregion

#region ============================== source-state detection =========================

function Get-SourceStateDetection {
    # D5 source-state machine for the unified package (first match wins):
    #   1. RC3_ALREADY_INSTALLED variant UNIFIED   (installed manifest == package manifest,
    #      all target payload files at target bytes, VERSION/distribution rc.3)
    #   2. RC3_ALREADY_INSTALLED variant FROZEN_RC3 (installed manifest == frozen RC3 anchor,
    #      installed manifest self-consistent, VERSION/distribution rc.3) -> safe no-op
    #   3. RC2_CLEAN      (RC2 manifest/VERSION/distribution, 107 source payload bytes,
    #                      every target-only add path absent)
    #   4. RC2_HOTFIXED   (same, cordis.patch.yml is one of the 2 whitelisted variants)
    #   5. UNKNOWN_OR_MODIFIED (fail-closed; conflicts[] reported)
    # Mutates $Ctx (sourceState/rc3Variant/hotfixedVariant/reasons/conflicts/counts).
    param($Ctx)
    $expectedSource = $Ctx.expectedSource
    $expectedTarget = $Ctx.expectedTarget
    $hashes = $Ctx.hashes
    $sourcePaths = @($Ctx.sourcePayloadPaths)
    $targetPaths = @($Ctx.targetPayloadPaths)
    $reasons = New-Object System.Collections.ArrayList
    $conflicts = New-Object System.Collections.ArrayList
    $sourceMatch = 0
    $targetMatch = 0
    $missingCount = 0
    $unreadableCount = 0
    $modifiedCount = 0
    $unsafeCount = 0
    $hotfixShaToVariant = @{}
    foreach ($variant in @($script:HotfixedOverrides.Keys)) {
        $hotfixShaToVariant[([string]$script:HotfixedOverrides[$variant]).ToLowerInvariant()] = $variant
    }
    $cordisActual = ''
    if ($null -ne $hashes -and $hashes.ContainsKey($script:CordisPath)) { $cordisActual = [string]$hashes[$script:CordisPath] }
    $cordisVariant = $null
    if ($hotfixShaToVariant.ContainsKey($cordisActual.ToLowerInvariant())) { $cordisVariant = $hotfixShaToVariant[$cordisActual.ToLowerInvariant()] }
    # target-only (operation "add") paths are the target payload paths absent from RC2.
    $addedPaths = New-Object System.Collections.ArrayList
    foreach ($p in $targetPaths) { if (-not $expectedSource.ContainsKey($p)) { [void]$addedPaths.Add($p) } }
    $allTarget = ($targetPaths.Length -gt 0)
    foreach ($p in $targetPaths) {
        $actual = ''
        if ($null -ne $hashes -and $hashes.ContainsKey($p)) { $actual = [string]$hashes[$p] }
        if ([string]::Equals($actual, [string]$expectedTarget[$p], [System.StringComparison]::OrdinalIgnoreCase)) { $targetMatch++ } else { $allTarget = $false }
    }
    $allSource = ($sourcePaths.Length -gt 0)
    $othersAllSource = $true
    $addFailed = $false
    foreach ($p in $sourcePaths) {
        $actual = ''
        if ($null -ne $hashes -and $hashes.ContainsKey($p)) { $actual = [string]$hashes[$p] }
        $isSource = [string]::Equals($actual, [string]$expectedSource[$p], [System.StringComparison]::OrdinalIgnoreCase)
        $isTarget = $false
        if ($expectedTarget.ContainsKey($p)) { $isTarget = [string]::Equals($actual, [string]$expectedTarget[$p], [System.StringComparison]::OrdinalIgnoreCase) }
        $isHotfixed = ($p -ieq $script:CordisPath -and $null -ne $cordisVariant)
        if ($isSource) { $sourceMatch++ } else { $allSource = $false }
        if ($p -ieq $script:CordisPath) { }
        elseif (-not $isSource) { $othersAllSource = $false }
        $allowed = ($isSource -or $isTarget -or $isHotfixed)
        if (-not $allowed) {
            $category = 'modified'
            if ($actual -eq 'ABSENT') { $category = 'missing'; $missingCount++ }
            elseif ($actual -eq 'UNREADABLE') { $category = 'modified'; $unreadableCount++ }
            elseif ($actual -eq 'IS_DIRECTORY' -or $actual -eq 'REPARSE_POINT') { $category = 'modified'; $unsafeCount++ }
            elseif ($p -ieq 'VERSION') { $category = 'tampered-version' }
            elseif ($p -ieq $script:CordisPath) { $category = 'modified' }
            elseif ($isTarget) { $category = 'unexpected-version' }
            else { $modifiedCount++ }
            [void]$conflicts.Add([ordered]@{
                path           = $p
                expectedSource = [string]$expectedSource[$p]
                expectedTarget = $(if ($expectedTarget.ContainsKey($p)) { [string]$expectedTarget[$p] } else { '' })
                actual         = $actual
                category       = $category
            })
        }
    }
    foreach ($p in $addedPaths) {
        $actual = ''
        if ($null -ne $hashes -and $hashes.ContainsKey($p)) { $actual = [string]$hashes[$p] }
        if ($actual -eq 'ABSENT') { continue }
        # A target-only file that exists while the tree is otherwise RC2 is fail-closed.
        $category = 'unexpected-target-file'
        if ($actual -eq 'UNREADABLE') { $category = 'modified' }
        [void]$conflicts.Add([ordered]@{
            path           = $p
            expectedSource = 'ABSENT'
            expectedTarget = [string]$expectedTarget[$p]
            actual         = $actual
            category       = $category
        })
        $addFailed = $true
    }
    $manifestSha = [string]$Ctx.installManifestSha256
    $packageManifestSha = ''
    if ($null -ne $Ctx.packageData) { $packageManifestSha = [string]$Ctx.packageData.manifestSha256 }
    $manifestIsSource = [string]::Equals($manifestSha, $script:SourceManifestHash, [System.StringComparison]::OrdinalIgnoreCase)
    $manifestIsTarget = ([string]::IsNullOrEmpty($packageManifestSha) -eq $false) -and [string]::Equals($manifestSha, $packageManifestSha, [System.StringComparison]::OrdinalIgnoreCase)
    $manifestIsFrozen = [string]::Equals($manifestSha, $script:FrozenRc3ManifestHash, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $manifestIsSource -and -not $manifestIsTarget -and -not $manifestIsFrozen) {
        [void]$conflicts.Add([ordered]@{
            path           = $script:DistributionManifestRelPath
            expectedSource = $script:SourceManifestHash
            expectedTarget = $packageManifestSha
            actual         = $manifestSha
            category       = 'tampered-manifest'
        })
        [void]$reasons.Add('TAMPERED_MANIFEST')
    }
    $distVersion = [string]$Ctx.installManifestDistributionVersion
    $versionTrim = [string]$Ctx.installVersionTrim
    # Frozen-RC3 self-consistency: authentic frozen manifest + every files[] hash on disk.
    $frozenSelfConsistent = $false
    if ($manifestIsFrozen -and $null -ne $Ctx.installManifestJson) {
        try {
            $dfiles = @(Get-JsonPropertyValue $Ctx.installManifestJson 'files')
            if ($dfiles.Count -eq $script:SourcePayloadFileCount) {
                $frozenSelfConsistent = $true
                foreach ($df in $dfiles) {
                    $dp = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $df 'path'))
                    $dh = ([string](Get-JsonPropertyValue $df 'sha256')).ToLowerInvariant()
                    $actual = ''
                    if ($null -ne $hashes -and $hashes.ContainsKey($dp)) { $actual = [string]$hashes[$dp] }
                    if (-not [string]::Equals($actual, $dh, [System.StringComparison]::OrdinalIgnoreCase)) { $frozenSelfConsistent = $false; break }
                }
            }
        } catch { $frozenSelfConsistent = $false }
    }
    $state = 'UNKNOWN_OR_MODIFIED'
    $hotfixedVariant = $null
    $rc3Variant = $null
    if ($manifestIsTarget -and $distVersion -eq $script:TargetVersion -and $versionTrim -eq $script:TargetVersion -and $allTarget) {
        $state = 'RC3_ALREADY_INSTALLED'
        $rc3Variant = 'UNIFIED'
    } elseif ($manifestIsFrozen -and $distVersion -eq $script:TargetVersion -and $versionTrim -eq $script:TargetVersion -and $frozenSelfConsistent) {
        $state = 'RC3_ALREADY_INSTALLED'
        $rc3Variant = 'FROZEN_RC3'
    } elseif ($manifestIsSource -and $distVersion -eq $script:SourceVersion -and $versionTrim -eq $script:SourceVersion -and $allSource -and -not $addFailed) {
        $state = 'RC2_CLEAN'
    } elseif ($manifestIsSource -and $distVersion -eq $script:SourceVersion -and $versionTrim -eq $script:SourceVersion -and $null -ne $cordisVariant -and $othersAllSource -and -not $addFailed) {
        $state = 'RC2_HOTFIXED'
        $hotfixedVariant = $cordisVariant
    }
    if ($state -ne 'UNKNOWN_OR_MODIFIED') {
        # Accepted states carry no conflicts; reasons stay empty for action documents.
        $conflicts = New-Object System.Collections.ArrayList
        $reasons = New-Object System.Collections.ArrayList
    } else {
        if ($missingCount -gt 0) { [void]$reasons.Add('MISSING_FILES') }
        if ($unreadableCount -gt 0) { [void]$reasons.Add('UNREADABLE_FILES') }
        if ($unsafeCount -gt 0) { [void]$reasons.Add('UNSAFE_PAYLOAD_PATHS') }
        if ($addFailed) { [void]$reasons.Add('TARGET_ONLY_FILES_PRESENT') }
        if ($sourceMatch -gt 0 -and $targetMatch -gt 0) {
            [void]$reasons.Add('MIXED_RC2_RC3')
            foreach ($p in $targetPaths) {
                $actualMixed = ''
                if ($hashes.ContainsKey($p)) { $actualMixed = [string]$hashes[$p] }
                if ([string]::Equals($actualMixed, [string]$expectedTarget[$p], [System.StringComparison]::OrdinalIgnoreCase)) {
                    $srcMixed = ''
                    if ($expectedSource.ContainsKey($p)) { $srcMixed = [string]$expectedSource[$p] }
                    [void]$conflicts.Add([ordered]@{ path = $p; expectedSource = $srcMixed; expectedTarget = [string]$expectedTarget[$p]; actual = $actualMixed; category = 'unexpected-version' })
                }
            }
        }
        if ($modifiedCount -gt 0 -and -not ($reasons -contains 'TAMPERED_MANIFEST')) { [void]$reasons.Add('MODIFIED_FILES') }
        if ($frozenSelfConsistent -eq $false -and $manifestIsFrozen) { [void]$reasons.Add('FROZEN_RC3_MANIFEST_INCONSISTENT') }
        if ([string]::IsNullOrEmpty($distVersion) -or ($distVersion -ne $script:SourceVersion -and $distVersion -ne $script:TargetVersion)) {
            [void]$reasons.Add('UNEXPECTED_DISTRIBUTION_VERSION')
        }
        if ([string]::IsNullOrEmpty($versionTrim) -or ($versionTrim -ne $script:SourceVersion -and $versionTrim -ne $script:TargetVersion)) {
            [void]$reasons.Add('TAMPERED_VERSION_MARKER')
        }
        if ($manifestIsSource -and $distVersion -eq $script:SourceVersion -and $versionTrim -eq $script:TargetVersion) { [void]$reasons.Add('INCONSISTENT_VERSION_MARKERS') }
        if (($manifestIsTarget -or $manifestIsFrozen) -and $distVersion -eq $script:TargetVersion -and $versionTrim -eq $script:SourceVersion) { [void]$reasons.Add('INCONSISTENT_VERSION_MARKERS') }
        if ($reasons.Count -eq 0) { [void]$reasons.Add('STATE_INCONSISTENT') }
    }
    $Ctx.sourceState = $state
    $Ctx.rc3Variant = $rc3Variant
    $Ctx.hotfixedVariant = $hotfixedVariant
    $Ctx.reasons = $reasons.ToArray()
    $Ctx.conflicts = $conflicts.ToArray()
    $Ctx.sourceMatchCount = $sourceMatch
    $Ctx.targetMatchCount = $targetMatch
    $Ctx.sourceVersion = $versionTrim
    return $Ctx
}


function Get-InstallExtraFiles {
    # Recursive inventory of install-root files that are NOT payload/env/known env or ignored dirs.
    param([string]$InstallRoot, $PayloadPathSet, $EnvPathSet)
    $out = New-Object System.Collections.ArrayList
    $root = Get-NormalizedFullPath $InstallRoot
    $excludedDirNames = @('.venv', '_portable', '.git', '__pycache__', '.pytest_cache', 'node_modules', 'dist')
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        foreach ($entry in (Get-DirectoryEntries $dir)) {
            $attr = Get-FileAttributesSafe $entry
            if ($null -eq $attr) { continue }
            $name = [System.IO.Path]::GetFileName($entry)
            $isDir = (($attr -band [System.IO.FileAttributes]::Directory) -ne 0)
            if ($isDir) {
                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $skip = $false
                foreach ($ex in $excludedDirNames) { if ($name -ieq $ex) { $skip = $true; break } }
                if (-not $skip) { $stack.Push($entry) }
                continue
            }
            $rel = ConvertTo-ManifestPath (Get-RelativePathUnder $entry $root)
            if ($rel -ieq 'manifest.json') { continue }
            if ($null -ne $PayloadPathSet -and $PayloadPathSet.ContainsKey($rel)) { continue }
            if ($null -ne $EnvPathSet -and $EnvPathSet.ContainsKey($rel)) { continue }
            [void]$out.Add($rel)
        }
    }
    $arr = $out.ToArray()
    if ($arr.Length -gt 1) { [System.Array]::Sort($arr, [System.StringComparer]::Ordinal) }
    return $arr
}

function Get-ManagedReparsePoints {
    param([string]$InstallRoot, [string[]]$RelativePaths)
    $hits = New-Object System.Collections.ArrayList
    $seen = @{}
    $root = Get-NormalizedFullPath $InstallRoot
    foreach ($rel in @($RelativePaths)) {
        $full = Join-Path $root (ConvertTo-FsPath ([string]$rel))
        foreach ($hit in @(Get-ReparsePointsInPath $full $root)) {
            $key = $hit.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [void]$hits.Add($hit) }
        }
    }
    return $hits.ToArray()
}

#endregion

#region ============================== core check context =============================

function Invoke-CoreChecks {
    # Read-only CHECK pipeline shared by check/plan/apply/verify/status/rollback.
    # v2: unified package model (no payload/ dir, target bytes at the package root),
    # operation "add" awareness, self-mode policy and NOT_INSTALLED detection.
    param(
        [string]$InstallRoot,
        [string]$PackageRoot,
        [string]$DshHome,
        [string]$DshProfile,
        [string]$Mode = 'check',
        $FaultModel = $null,
        [switch]$SkipPendingTransactionCheck
    )
    $checks = New-CheckList
    $ctx = @{
        mode              = $Mode
        installRoot       = $null
        packageRoot       = $null
        selfMode          = $false
        notInstalled      = $false
        notInstalledReason = $null
        packageValid      = $false
        packageData       = $null
        manifest          = $null
        expectedSource    = $null
        expectedTarget    = $null
        sourcePayloadPaths = @()
        targetPayloadPaths = @()
        addedPayloadPaths = @()
        payloadPathSet    = $null
        resolvedTargetHashes = $null
        payloadRoot       = $script:PayloadRootDefault
        targetRoot        = $null
        sourcePayloadFileCount = 0
        targetPayloadFileCount = 0
        addedFileCount    = 0
        changedFiles      = @()
        envFiles          = @()
        checks            = $checks
        sourceState       = 'UNKNOWN_OR_MODIFIED'
        rc3Variant        = $null
        sourceVersion     = $null
        hotfixedVariant   = $null
        reasons           = @()
        conflicts         = @()
        hashes            = @{}
        kinds             = @{}
        installManifest   = $null
        installManifestJson = $null
        installManifestSha256 = 'ABSENT'
        installManifestDistributionVersion = ''
        installVersionTrim = ''
        layout            = $null
        transactionRoot   = $null
        transactions      = @()
        pendingTransactions = @()
        corruptTransactions = @()
        dshHome           = $null
        dshProfileInfo    = $null
        dshPolicy         = $null
        dshProcessTable   = @()
        preservedFingerprints = [ordered]@{}
        space             = [ordered]@{}
        faults            = $FaultModel
        hasFail           = $false
    }
    $rootOk = $false
    try {
        $ctx.installRoot = Get-NormalizedFullPath $InstallRoot
        $rootOk = $true
    } catch {
        Add-Check $checks 'path.installRoot' 'FAIL' "invalid -InstallRoot path: $($_.Exception.Message)"
    }
    try { $ctx.packageRoot = Get-NormalizedFullPath $PackageRoot } catch {
        $ctx.packageRoot = $PackageRoot
        Add-Check $checks 'patch.sumsFile' 'FAIL' "invalid -PackageRoot path: $($_.Exception.Message)"
    }
    if ($rootOk -and $null -ne $ctx.packageRoot) {
        try {
            if ([string]::Equals([string]$ctx.installRoot, [string]$ctx.packageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $ctx.selfMode = $true
            }
        } catch { }
    }

    # ---------------- package self-integrity ----------------
    $pkg = $null
    if ($null -ne $ctx.packageRoot) {
        try { $pkg = Get-PackageIntegrity -PackageRoot $ctx.packageRoot -Checks $checks -InstallRoot ([string]$ctx.installRoot) } catch {
            $pkg = $null
            Add-Check $checks 'patch.manifest' 'FAIL' "package integrity inspection failed: $($_.Exception.Message)"
        }
    }
    if ($null -ne $pkg) {
        $ctx.packageData = $pkg
        $ctx.packageValid = [bool]$pkg.valid
        if ($null -ne $pkg.expectedSource) {
            $ctx.manifest = $pkg.metadataDoc
            $ctx.expectedSource = $pkg.expectedSource
            $ctx.expectedTarget = $pkg.expectedTarget
            $ctx.sourcePayloadPaths = @($pkg.sourcePayloadPaths)
            $ctx.targetPayloadPaths = @($pkg.targetPayloadPaths)
            $ctx.addedPayloadPaths = @($pkg.addedPayloadPaths)
            $ctx.payloadPathSet = $pkg.payloadPathSet
            $ctx.resolvedTargetHashes = $pkg.resolvedTargetHashes
            $ctx.payloadRoot = [string]$pkg.payloadRoot
            $ctx.targetRoot = $pkg.targetRoot
            $ctx.sourcePayloadFileCount = [int]$pkg.sourcePayloadFileCount
            $ctx.targetPayloadFileCount = [int]$pkg.targetPayloadFileCount
            $ctx.addedFileCount = [int]$pkg.addedFileCount
            $ctx.changedFiles = @($pkg.changedFiles)
            $ctx.envFiles = @($pkg.envFiles)
        }
    }

    $changedRelPaths = New-Object System.Collections.ArrayList
    if ($ctx.packageValid) {
        foreach ($cf in $ctx.changedFiles) { [void]$changedRelPaths.Add([string](Get-JsonPropertyValue $cf 'path')) }
    }
    $envRelPaths = New-Object System.Collections.ArrayList
    if ($ctx.packageValid) {
        foreach ($ef in $ctx.envFiles) { [void]$envRelPaths.Add([string](Get-JsonPropertyValue $ef 'path')) }
    }

    # ---------------- path.* checks ----------------
    $hardPathFail = $false
    $rootExists = $false
    $rootIsEmpty = $false
    if ($rootOk) {
        $rootExists = Test-DirExists $ctx.installRoot
        if ($rootExists) { $rootIsEmpty = -not (Test-DirHasEntries $ctx.installRoot) }
        if (-not $rootExists) {
            Add-Check $checks 'path.installRoot' 'WARN' "install root does not exist: $($ctx.installRoot) (reported as NOT_INSTALLED)"
        } elseif (Test-ReparsePoint $ctx.installRoot) {
            Add-Check $checks 'path.installRoot' 'FAIL' "INSTALL_ROOT_IS_REPARSE_POINT: $($ctx.installRoot)"
            $hardPathFail = $true
        } elseif ($rootIsEmpty) {
            Add-Check $checks 'path.installRoot' 'WARN' "install root is an empty directory: $($ctx.installRoot) (reported as NOT_INSTALLED)"
        } else {
            Add-Check $checks 'path.installRoot' 'PASS' "install root exists and is a plain directory: $($ctx.installRoot)"
        }
    } else {
        $hardPathFail = $true
    }
    if ($rootOk -and $rootExists -and -not $hardPathFail) {
        $safeReasons = @(Test-InstallRootPathSafety -InstallRoot $ctx.installRoot -PackageRoot $ctx.packageRoot -SelfMode:$ctx.selfMode)
        if ($safeReasons.Count -gt 0) {
            Add-Check $checks 'path.installRootSafe' 'FAIL' (($safeReasons) -join '; ')
            $hardPathFail = $true
        } else {
            Add-Check $checks 'path.installRootSafe' 'PASS' 'install root is not a system/drive-root/user-data/package location and does not intersect the package root unsafely'
        }
    } elseif ($rootOk -and -not $rootExists) {
        Add-Check $checks 'path.installRootSafe' 'NOT TESTED' 'skipped: install root does not exist (NOT_INSTALLED)'
    } elseif ($rootOk) {
        Add-Check $checks 'path.installRootSafe' 'NOT TESTED' 'skipped: install root failed the basic path check'
    }
    # package root shape / reparse
    if ($rootOk -and $null -ne $ctx.packageRoot) {
        $pkgRootExists = Test-DirExists $ctx.packageRoot
        if (-not $pkgRootExists) {
            Add-Check $checks 'path.packageRoot' 'FAIL' "package root does not exist: $($ctx.packageRoot)"
        } elseif (Test-ReparsePoint $ctx.packageRoot) {
            Add-Check $checks 'path.packageRoot' 'FAIL' "PACKAGE_ROOT_IS_REPARSE_POINT: $($ctx.packageRoot)"
        } else {
            Add-Check $checks 'path.packageRoot' 'PASS' 'package root exists and is a plain directory (target bytes are read read-only from it)'
        }
    } else {
        Add-Check $checks 'path.packageRoot' 'NOT TESTED' 'skipped: package root is unavailable'
    }
    if ($ctx.selfMode) {
        Add-Check $checks 'path.selfMode' 'WARN' 'SELF_MODE_IN_PLACE_PACKAGE_ROOT: install root equals package root (extracted package tree); read-only actions allowed, APPLY/ROLLBACK refuse to write in self mode'
    } else {
        Add-Check $checks 'path.selfMode' 'PASS' 'strict mode: package root and install root are separate trees'
    }
    if ($rootOk -and $ctx.packageValid) {
        $escapeProblems = New-Object System.Collections.ArrayList
        foreach ($rel in @($changedRelPaths.ToArray()) + @($envRelPaths.ToArray())) {
            $problems = Test-SafeRelativePath $rel
            foreach ($p in @($problems)) { [void]$escapeProblems.Add("unsafe path '$rel': $p") }
            $full = Join-Path $ctx.installRoot (ConvertTo-FsPath $rel)
            try {
                if (-not (Test-PathUnder $full $ctx.installRoot)) { [void]$escapeProblems.Add("target escapes install root: $rel") }
            } catch { [void]$escapeProblems.Add("target path is invalid: $rel") }
        }
        $upgradesRel = ConvertTo-ManifestPath $script:DefaultUpgradesDirName
        $problems = Test-SafeRelativePath $upgradesRel
        foreach ($p in @($problems)) { [void]$escapeProblems.Add("unsafe path '$upgradesRel': $p") }
        if ($escapeProblems.Count -gt 0) {
            Add-Check $checks 'path.noEscape' 'FAIL' ((@($escapeProblems) | Select-Object -First 10) -join '; ')
            $hardPathFail = $true
        } else {
            Add-Check $checks 'path.noEscape' 'PASS' 'all managed targets resolve inside the install root (no .., rooted, UNC, ADS or reserved names)'
        }
    } elseif ($rootOk) {
        Add-Check $checks 'path.noEscape' 'NOT TESTED' 'skipped: package manifest is not available'
    }
    if ($rootOk -and $rootExists -and -not $hardPathFail -and $ctx.packageValid) {
        $targets = @($changedRelPaths.ToArray()) + @($envRelPaths.ToArray())
        $reparseHits = @(Get-ManagedReparsePoints -InstallRoot $ctx.installRoot -RelativePaths $targets)
        if ($reparseHits.Count -gt 0) {
            Add-Check $checks 'path.reparseSearch' 'FAIL' ('reparse points in managed target ancestry: ' + ((@($reparseHits) | Select-Object -First 10) -join ', '))
            $hardPathFail = $true
        } else {
            Add-Check $checks 'path.reparseSearch' 'PASS' 'no reparse points in the ancestry of managed targets'
        }
    } elseif ($rootOk) {
        Add-Check $checks 'path.reparseSearch' 'NOT TESTED' 'skipped: package manifest is not available (or install root is absent)'
    }

    # ---------------- layout + source detection ----------------
    $layout = $null
    $layoutOk = $false
    if ($rootOk -and $rootExists -and -not $hardPathFail) {
        $layout = Get-LayoutDetection -InstallRoot $ctx.installRoot -Checks $checks
        $ctx.layout = $layout
        if ($null -ne $layout -and $layout.ok) { $layoutOk = $true }
    } elseif ($rootOk -and -not $rootExists) {
        Add-Check $checks 'source.layout' 'NOT TESTED' 'skipped: install root does not exist (NOT_INSTALLED)'
    } else {
        Add-Check $checks 'source.layout' 'NOT TESTED' 'skipped: install root failed a hard path safety check'
    }
    # NOT_INSTALLED detection: absent/empty root, or an extracted package tree that was never installed.
    $installEvidence = $false
    if ($rootExists) {
        if ((Test-DirExists (Join-Path $ctx.installRoot '.venv')) -or
            (Test-DirExists (Join-Path $ctx.installRoot '_portable')) -or
            (Test-FileExists (Join-Path $ctx.installRoot '_portable\install-state.json'))) {
            $installEvidence = $true
        }
    }
    $notInstalled = $false
    $notInstalledReason = $null
    if ($rootOk -and $ctx.packageValid) {
        if (-not $rootExists) { $notInstalled = $true; $notInstalledReason = 'INSTALL_ROOT_ABSENT' }
        elseif ($rootIsEmpty) { $notInstalled = $true; $notInstalledReason = 'INSTALL_ROOT_EMPTY' }
        elseif ($ctx.selfMode -and $layoutOk -and -not $installEvidence) { $notInstalled = $true; $notInstalledReason = 'EXTRACTED_PACKAGE_TREE_NOT_INSTALLED' }
    }
    $ctx.notInstalled = $notInstalled
    $ctx.notInstalledReason = $notInstalledReason

    if ($notInstalled) {
        Add-Check $checks 'source.manifest' 'NOT TESTED' 'skipped: nothing is installed yet (NOT_INSTALLED)'
        Add-Check $checks 'source.version' 'NOT TESTED' 'skipped: nothing is installed yet (NOT_INSTALLED)'
        Add-Check $checks 'source.payloadHashes' 'NOT TESTED' 'skipped: nothing is installed yet (NOT_INSTALLED)'
        Add-Check $checks 'source.addedFiles' 'NOT TESTED' 'skipped: nothing is installed yet (NOT_INSTALLED)'
        Add-Check $checks 'source.envMarkers' 'NOT TESTED' 'skipped: nothing is installed yet (NOT_INSTALLED)'
        Add-Check $checks 'source.extraFiles' 'NOT TESTED' 'skipped: nothing is installed yet (NOT_INSTALLED)'
        Add-Check $checks 'source.reparsePoints' 'NOT TESTED' 'skipped: nothing is installed yet (NOT_INSTALLED)'
        $ctx.sourceState = 'NOT_INSTALLED'
        $ctx.rc3Variant = $null
        $ctx.hotfixedVariant = $null
        $ctx.reasons = @()
        $ctx.conflicts = @()
        $ctx.sourceVersion = $null
        $ctx.sourceMatchCount = 0
        $ctx.targetMatchCount = 0
        $stateDetail = 'NOT_INSTALLED'
        if ($notInstalledReason -eq 'EXTRACTED_PACKAGE_TREE_NOT_INSTALLED') {
            $stateDetail = 'NOT_INSTALLED (extracted package tree is complete, but no installation evidence: no .venv/_portable present)'
        }
        Add-Check $checks 'source.state' 'PASS' ($stateDetail + ' - a fresh install is the appropriate action; upgrade actions require an existing installation')
    } elseif ($rootOk -and $rootExists -and -not $hardPathFail -and $layoutOk -and $ctx.packageValid) {
        $hashPaths = New-Object System.Collections.ArrayList
        foreach ($p in @($ctx.sourcePayloadPaths)) { [void]$hashPaths.Add([string]$p) }
        foreach ($p in @($ctx.targetPayloadPaths)) {
            $known = $false
            foreach ($q in $hashPaths) { if ([string]::Equals([string]$q, [string]$p, [System.StringComparison]::OrdinalIgnoreCase)) { $known = $true; break } }
            if (-not $known) { [void]$hashPaths.Add([string]$p) }
        }
        $hashInfo = Get-InstallTreeHashes -InstallRoot $ctx.installRoot -Paths $hashPaths.ToArray()
        $ctx.hashes = $hashInfo.hashes
        $ctx.kinds = $hashInfo.kinds
        # install manifest + VERSION
        $installManifestPath = Join-Path $ctx.installRoot 'manifest.json'
        $installVersionPath = Join-Path $ctx.installRoot 'VERSION'
        if (Test-FileExists $installManifestPath) {
            try {
                $ctx.installManifestSha256 = Get-Sha256File $installManifestPath
                $ctx.installManifest = Read-JsonDocument $installManifestPath
                $ctx.installManifestJson = $ctx.installManifest
                $dist = Get-JsonPropertyValue $ctx.installManifest 'distribution'
                $dv = Get-JsonPropertyValue $dist 'version'
                if ($null -ne $dv) { $ctx.installManifestDistributionVersion = [string]$dv }
            } catch {
                Add-Check $checks 'source.manifest' 'FAIL' "install manifest.json is unreadable: $($_.Exception.Message)"
            }
        } else {
            $ctx.installManifestSha256 = 'ABSENT'
        }
        if (Test-FileExists $installVersionPath) {
            try { $ctx.installVersionTrim = (Read-TextFileUtf8 $installVersionPath).Trim() } catch { $ctx.installVersionTrim = '' }
        }
        # source.manifest
        if (@($checks | Where-Object { $_['id'] -eq 'source.manifest' }).Count -eq 0) {
            $ms = [string]$ctx.installManifestSha256
            $dv = [string]$ctx.installManifestDistributionVersion
            $packageManifestSha = ''
            if ($null -ne $ctx.packageData) { $packageManifestSha = [string]$ctx.packageData.manifestSha256 }
            $shaIsSource = [string]::Equals($ms, $script:SourceManifestHash, [System.StringComparison]::OrdinalIgnoreCase)
            $shaIsTarget = [string]::Equals($ms, $packageManifestSha, [System.StringComparison]::OrdinalIgnoreCase)
            $shaIsFrozen = [string]::Equals($ms, $script:FrozenRc3ManifestHash, [System.StringComparison]::OrdinalIgnoreCase)
            if (($shaIsSource -and $dv -eq $script:SourceVersion) -or (($shaIsTarget -or $shaIsFrozen) -and $dv -eq $script:TargetVersion)) {
                Add-Check $checks 'source.manifest' 'PASS' "manifest.json sha256 matches $dv (${ms})"
            } elseif (-not $shaIsSource -and -not $shaIsTarget -and -not $shaIsFrozen) {
                Add-Check $checks 'source.manifest' 'FAIL' "manifest.json sha256 '$ms' matches neither the rc.2, the unified-package nor the frozen rc.3 manifest"
            } else {
                Add-Check $checks 'source.manifest' 'FAIL' "manifest.json sha256 matches one release but distribution.version is '$dv' (inconsistent markers)"
            }
        }
        # source.version
        $vTrim = [string]$ctx.installVersionTrim
        $shaIsSourceV = [string]::Equals([string]$ctx.installManifestSha256, $script:SourceManifestHash, [System.StringComparison]::OrdinalIgnoreCase)
        $packageManifestShaV = ''
        if ($null -ne $ctx.packageData) { $packageManifestShaV = [string]$ctx.packageData.manifestSha256 }
        $shaIsTargetV = [string]::Equals([string]$ctx.installManifestSha256, $packageManifestShaV, [System.StringComparison]::OrdinalIgnoreCase)
        $shaIsFrozenV = [string]::Equals([string]$ctx.installManifestSha256, $script:FrozenRc3ManifestHash, [System.StringComparison]::OrdinalIgnoreCase)
        if (($vTrim -eq $script:SourceVersion -and $shaIsSourceV) -or ($vTrim -eq $script:TargetVersion -and ($shaIsTargetV -or $shaIsFrozenV))) {
            Add-Check $checks 'source.version' 'PASS' "VERSION file content is '$vTrim' and matches the manifest release"
        } else {
            Add-Check $checks 'source.version' 'FAIL' "VERSION file content is '$vTrim' which does not match the manifest release"
        }
        # base detection
        [void](Get-SourceStateDetection $ctx)
        # env markers (may downgrade CLEAN/HOTFIXED to UNKNOWN on rc.3 metadata)
        [void](Update-EnvMarkersForDetection $ctx)
        # source.payloadHashes
        $sm = [int]$ctx.sourceMatchCount
        $tm = [int]$ctx.targetMatchCount
        $hotfixedOk = ($null -ne $ctx.hotfixedVariant)
        if ($ctx.sourceState -eq 'RC3_ALREADY_INSTALLED' -and $ctx.rc3Variant -eq 'FROZEN_RC3') {
            Add-Check $checks 'source.payloadHashes' 'PASS' 'frozen rc.3 install: installed manifest is authentic and self-consistent (107 payload files match its files[] map); unified tooling additions are not installed'
        } elseif ($sm -eq $ctx.sourcePayloadFileCount -or $tm -eq $ctx.targetPayloadFileCount -or $hotfixedOk) {
            Add-Check $checks 'source.payloadHashes' 'PASS' ("payload hashes: $sm/$($ctx.sourcePayloadFileCount) rc.2, $tm/$($ctx.targetPayloadFileCount) rc.3 target" +
                $(if ($hotfixedOk) { ", hotfixed cordis variant $($ctx.hotfixedVariant)" } else { '' }))
        } else {
            Add-Check $checks 'source.payloadHashes' 'FAIL' ("payload hashes: $sm/$($ctx.sourcePayloadFileCount) rc.2, $tm/$($ctx.targetPayloadFileCount) rc.3 target, " +
                "$($ctx.conflicts.Count) conflict(s)")
        }
        # source.addedFiles (operation "add" target-only paths)
        if ($ctx.sourceState -eq 'RC2_CLEAN' -or $ctx.sourceState -eq 'RC2_HOTFIXED') {
            Add-Check $checks 'source.addedFiles' 'PASS' ("$($ctx.addedFileCount) target-only (add) file(s) are absent as required for an RC2 source state")
        } elseif ($ctx.sourceState -eq 'RC3_ALREADY_INSTALLED' -and $ctx.rc3Variant -eq 'UNIFIED') {
            Add-Check $checks 'source.addedFiles' 'PASS' ("all $($ctx.addedFileCount) add files are present at their target bytes (unified install complete)")
        } elseif ($ctx.sourceState -eq 'RC3_ALREADY_INSTALLED' -and $ctx.rc3Variant -eq 'FROZEN_RC3') {
            Add-Check $checks 'source.addedFiles' 'WARN' ("FROZEN_RC3: core rc.3 is complete but the $($ctx.addedFileCount) unified tooling additions are NOT installed; no automatic refresh is offered (documented limitation)")
        } else {
            Add-Check $checks 'source.addedFiles' 'FAIL' ("target-only (add) files cannot be accounted for; $($ctx.conflicts.Count) conflict(s)")
        }
        # env markers check
        $envCheck = Get-EnvMarkersCheckState $ctx
        Add-Check $checks 'source.envMarkers' $envCheck.status $envCheck.detail
        # source.state
        if ($ctx.sourceState -eq 'UNKNOWN_OR_MODIFIED') {
            $rs = @($ctx.reasons) -join ','
            Add-Check $checks 'source.state' 'FAIL' ("UNKNOWN_OR_MODIFIED: reasons=$rs; conflicts=$($ctx.conflicts.Count)")
        } else {
            $extra = ''
            if ($ctx.sourceState -eq 'RC2_HOTFIXED') { $extra = " hotfixedVariant=$($ctx.hotfixedVariant)" }
            if ($ctx.sourceState -eq 'RC3_ALREADY_INSTALLED') { $extra = " variant=$($ctx.rc3Variant)" }
            Add-Check $checks 'source.state' 'PASS' ("$($ctx.sourceState) (VERSION=$($ctx.sourceVersion))$extra")
        }
        # extra files
        $envSet = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($rel in @($envRelPaths.ToArray())) { $envSet[(ConvertTo-ManifestPath $rel)] = $true }
        try {
            $extras = @(Get-InstallExtraFiles -InstallRoot $ctx.installRoot -PayloadPathSet $ctx.payloadPathSet -EnvPathSet $envSet)
            if ($extras.Count -eq 0) {
                Add-Check $checks 'source.extraFiles' 'PASS' 'no unexpected extra files inside the install root (payload + env files excluded)'
            } else {
                $first = (@($extras) | Select-Object -First 50) -join ', '
                Add-Check $checks 'source.extraFiles' 'WARN' ("UNEXPECTED_EXTRA_FILES: $($extras.Count) extra file(s) will be preserved, e.g. $first")
            }
        } catch {
            Add-Check $checks 'source.extraFiles' 'WARN' "extra-file inventory could not be completed: $($_.Exception.Message)"
        }
        # reparse points across the payload tree
        try {
            $payloadReparse = @(Get-ManagedReparsePoints -InstallRoot $ctx.installRoot -RelativePaths (@($ctx.sourcePayloadPaths) + @($ctx.targetPayloadPaths)))
            if ($payloadReparse.Count -gt 0) {
                Add-Check $checks 'source.reparsePoints' 'FAIL' ('reparse points inside the payload tree: ' + ((@($payloadReparse) | Select-Object -First 10) -join ', '))
            } else {
                Add-Check $checks 'source.reparsePoints' 'PASS' 'no reparse points inside the payload tree'
            }
        } catch {
            Add-Check $checks 'source.reparsePoints' 'WARN' "reparse-point scan failed: $($_.Exception.Message)"
        }
    } else {
        if ($hardPathFail) {
            Add-Check $checks 'source.manifest' 'NOT TESTED' 'skipped: install root failed a hard path safety check'
            Add-Check $checks 'source.version' 'NOT TESTED' 'skipped: install root failed a hard path safety check'
            Add-Check $checks 'source.payloadHashes' 'NOT TESTED' 'skipped: install root failed a hard path safety check'
            Add-Check $checks 'source.addedFiles' 'NOT TESTED' 'skipped: install root failed a hard path safety check'
            Add-Check $checks 'source.envMarkers' 'NOT TESTED' 'skipped: install root failed a hard path safety check'
            Add-Check $checks 'source.state' 'FAIL' 'UNKNOWN_OR_MODIFIED: install root failed a hard path safety check'
            Add-Check $checks 'source.extraFiles' 'NOT TESTED' 'skipped: install root failed a hard path safety check'
            Add-Check $checks 'source.reparsePoints' 'NOT TESTED' 'skipped: install root failed a hard path safety check'
            $ctx.reasons = @('PATH_SAFETY_FAILED')
        } else {
            $layoutReasons = @()
            if ($null -ne $layout) { $layoutReasons = @($layout.reasons) }
            if ($layoutReasons.Count -eq 0) { $layoutReasons = @('PACKAGE_INTEGRITY_FAILED') }
            Add-Check $checks 'source.manifest' 'NOT TESTED' 'skipped: package manifest is not trustworthy'
            Add-Check $checks 'source.version' 'NOT TESTED' 'skipped: package manifest is not trustworthy'
            Add-Check $checks 'source.payloadHashes' 'NOT TESTED' 'skipped: package manifest is not trustworthy'
            Add-Check $checks 'source.addedFiles' 'NOT TESTED' 'skipped: package manifest is not trustworthy'
            Add-Check $checks 'source.envMarkers' 'NOT TESTED' 'skipped: package manifest is not trustworthy'
            Add-Check $checks 'source.state' 'FAIL' ("UNKNOWN_OR_MODIFIED: reasons=" + ($layoutReasons -join ','))
            Add-Check $checks 'source.extraFiles' 'NOT TESTED' 'skipped: package manifest is not trustworthy'
            Add-Check $checks 'source.reparsePoints' 'NOT TESTED' 'skipped: package manifest is not trustworthy'
            $ctx.sourceState = 'UNKNOWN_OR_MODIFIED'
            $ctx.reasons = $layoutReasons
        }
    }

    # ---------------- env.writeAccess ----------------
    if ($ctx.packageValid -and $rootOk -and $rootExists -and -not $hardPathFail) {
        try {
            $wa = Get-WriteAccessAssessment -InstallRoot $ctx.installRoot -FilePaths @($changedRelPaths.ToArray())
            Add-Check $checks 'env.writeAccess' $wa.status $wa.detail
        } catch {
            Add-Check $checks 'env.writeAccess' 'WARN' "WRITE_ACCESS_UNPROVEN: $($_.Exception.Message)"
        }
    } else {
        Add-Check $checks 'env.writeAccess' 'NOT TESTED' 'skipped: package manifest or install root is unavailable'
    }

    # ---------------- space.sufficient ----------------
    $sumChangedBytes = [long]0
    foreach ($cf in $ctx.changedFiles) {
        $tb = [long](Get-JsonPropertyValue $cf 'targetBytes')
        if ($tb -le 0 -and $null -ne $ctx.packageData) {
            $pp = Join-Path ([string]$ctx.packageData.targetRoot) (ConvertTo-FsPath ([string](Get-JsonPropertyValue $cf 'path')))
            $len = Get-FileLengthSafe $pp
            if ($len -gt 0) { $tb = $len }
        }
        $sumChangedBytes += $tb
    }
    $requiredBytes = [long]([Math]::Max([double]52428800, (4.0 * [double]$sumChangedBytes) + 8388608.0))
    $simulateDiskLow = $false
    if ($null -ne $FaultModel) { $simulateDiskLow = (Test-FaultPresent $FaultModel 'SIMULATE_DISK_LOW') }
    if ($simulateDiskLow) {
        Add-Check $checks 'space.sufficient' 'FAIL' ("SIMULATED_DISK_LOW: free space check forced to fail (test-only fault injection); required=$requiredBytes bytes")
        $ctx.space = [ordered]@{ freeBytes = 0; requiredBytes = $requiredBytes; sumChangedBytes = $sumChangedBytes; simulated = $true }
    } elseif ($rootOk -and $ctx.packageValid) {
        $free = Get-DriveFreeBytes ([string]$ctx.installRoot)
        $ctx.space = [ordered]@{ freeBytes = $free; requiredBytes = $requiredBytes; sumChangedBytes = $sumChangedBytes; simulated = $false }
        if ($free -lt 0) {
            Add-Check $checks 'space.sufficient' 'WARN' 'free disk space could not be determined'
        } elseif ($free -lt $requiredBytes) {
            Add-Check $checks 'space.sufficient' 'FAIL' ("insufficient free space: free=$free bytes, required>=$requiredBytes bytes")
        } else {
            Add-Check $checks 'space.sufficient' 'PASS' ("free=$free bytes >= required=$requiredBytes bytes")
        }
    } else {
        Add-Check $checks 'space.sufficient' 'NOT TESTED' 'skipped: package manifest or install root is unavailable'
    }

    # ---------------- dsh.* ----------------
    $dshHomeEffective = $DshHome
    if ([string]::IsNullOrEmpty($dshHomeEffective)) { $dshHomeEffective = Get-ProductionDshHome }
    $ctx.dshHome = $dshHomeEffective
    $table = @(Get-DshProcessTable)
    $ctx.dshProcessTable = $table
    if ($table.Count -eq 0) {
        Add-Check $checks 'dsh.processTable' 'PASS' 'no DSH host process detected (read-only CIM probe)'
    } else {
        $names = New-Object System.Collections.ArrayList
        foreach ($p in $table) { [void]$names.Add(("{0}:{1}" -f $p.pid, $p.name)) }
        Add-Check $checks 'dsh.processTable' 'PASS' ("DSH host processes detected: " + ((@($names)) -join ', '))
    }
    $profInfo = $null
    if ($rootOk -and $rootExists) {
        try {
            $profInfo = Get-DshProfileInfo -DshHome $dshHomeEffective -InstallRoot $ctx.installRoot -DshProfile $DshProfile
        } catch {
            $profInfo = $null
        }
    }
    $ctx.dshProfileInfo = $profInfo
    if ($null -ne $profInfo) {
        $matchCount = @($profInfo.matches).Count
        switch ($profInfo.outcome) {
            'MATCH' { Add-Check $checks 'dsh.profileReference' 'PASS' ($profInfo.detail + " (matches=$matchCount)") }
            'NOT_THIS_INSTALL' { Add-Check $checks 'dsh.profileReference' 'WARN' ("PROFILE_REFERENCE_NOT_THIS_INSTALL: " + $profInfo.detail + " (matches=$matchCount)") }
            default { Add-Check $checks 'dsh.profileReference' 'WARN' ("PROFILE_REFERENCE_NOT_FOUND: " + $profInfo.detail) }
        }
    } else {
        Add-Check $checks 'dsh.profileReference' 'WARN' 'PROFILE_REFERENCE_NOT_FOUND: DSH home is unavailable or unreadable'
    }
    $anc = Get-DshAncestry -ProcessTable $table
    $policy = Test-DshApplyAllowed -DshHome $dshHomeEffective -InstallRoot ([string]$ctx.installRoot) -DshRunning ($table.Count -gt 0) -UnderDshProcess ([bool]$anc.underDshProcess)
    $ctx.dshPolicy = $policy
    if ($Mode -eq 'apply' -or $Mode -eq 'rollback') {
        Add-Check $checks 'dsh.inUse' $policy.status $policy.message
    } else {
        if ($policy.refused -or $policy.status -eq 'WARN') {
            Add-Check $checks 'dsh.inUse' 'WARN' ('REQUIRES_DSH_EXIT_BEFORE_APPLY: ' + $policy.message)
        } else {
            Add-Check $checks 'dsh.inUse' 'PASS' $policy.message
        }
    }

    # ---------------- env.pendingTransaction ----------------
    if ($rootOk -and $rootExists) {
        $ctx.transactionRoot = Get-DefaultTransactionRoot $ctx.installRoot
        $txns = @(Get-TransactionList $ctx.transactionRoot)
        $ctx.transactions = $txns
        $pending = New-Object System.Collections.ArrayList
        $corrupt = New-Object System.Collections.ArrayList
        foreach ($t in $txns) {
            if ($t.corrupt) { [void]$corrupt.Add($t.id) }
            elseif ($script:TerminalTransactionPhases -notcontains [string]$t.phase) { [void]$pending.Add($t.id + ':' + [string]$t.phase) }
        }
        $ctx.pendingTransactions = $pending.ToArray()
        $ctx.corruptTransactions = $corrupt.ToArray()
        if ($SkipPendingTransactionCheck) {
            Add-Check $checks 'env.pendingTransaction' 'NOT TESTED' 'skipped for rollback (the rollback action recovers pending transactions)'
        } elseif ($corrupt.Count -gt 0) {
            Add-Check $checks 'env.pendingTransaction' 'FAIL' ("TRANSACTION_CORRUPT: unparseable transaction record(s): " + ((@($corrupt)) -join ', '))
        } elseif ($pending.Count -gt 0) {
            Add-Check $checks 'env.pendingTransaction' 'FAIL' ("PENDING_TRANSACTION: " + ((@($pending)) -join ', ') +
                " - run '-Action rollback' (or '-Action check' after recovery); the upgrader will not start a second transaction")
        } else {
            Add-Check $checks 'env.pendingTransaction' 'PASS' 'no pending upgrade transaction'
        }
    } else {
        Add-Check $checks 'env.pendingTransaction' 'NOT TESTED' 'skipped: install root is unavailable'
    }

    # ---------------- env.userDataUntouched ----------------
    $fps = [ordered]@{}
    if ($rootExists) {
        $fps['.venv'] = Get-TreeFingerprint -Root (Join-Path $ctx.installRoot '.venv') -ExcludePrefixes @()
        $fps['_portable/backups'] = Get-TreeFingerprint -Root (Join-Path $ctx.installRoot '_portable\backups') -ExcludePrefixes @()
        $fps['_portable'] = Get-TreeFingerprint -Root (Join-Path $ctx.installRoot '_portable') -ExcludePrefixes @('upgrades')
        if ($null -ne $profInfo) { $fps['dshProfile'] = $profInfo.fingerprint } else { $fps['dshProfile'] = 'ABSENT' }
    } else {
        $fps['.venv'] = 'ABSENT'; $fps['_portable/backups'] = 'ABSENT'; $fps['_portable'] = 'ABSENT'; $fps['dshProfile'] = 'ABSENT'
    }
    $ctx.preservedFingerprints = $fps
    if ($ctx.packageValid -and $rootOk -and $rootExists) {
        $violations = New-Object System.Collections.ArrayList
        foreach ($cf in $ctx.changedFiles) {
            $rel = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path'))
            if ($rel.StartsWith('.venv/', [System.StringComparison]::OrdinalIgnoreCase) -or
                $rel.StartsWith('_portable/backups/', [System.StringComparison]::OrdinalIgnoreCase) -or
                $rel.StartsWith('_portable/upgrades/', [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$violations.Add("managed payload path under preserved user data: $rel")
            }
        }
        foreach ($forbidden in @($ctx.packageData.forbiddenPaths)) {
            $fp = ([string]$forbidden).Trim()
            if ([string]::IsNullOrEmpty($fp)) { continue }
            if ($fp.StartsWith('<') -or $fp.StartsWith('%') -or $fp.Contains('*')) { continue }
            $fpNorm = ConvertTo-ManifestPath $fp
            foreach ($cf in $ctx.changedFiles) {
                $rel = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path'))
                if ([string]::Equals($rel, $fpNorm, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $rel.StartsWith($fpNorm + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$violations.Add("managed payload path matches forbiddenPaths entry '$fpNorm': $rel")
                }
            }
        }
        if ($violations.Count -gt 0) {
            Add-Check $checks 'env.userDataUntouched' 'FAIL' ((@($violations) | Select-Object -First 10) -join '; ')
        } else {
            Add-Check $checks 'env.userDataUntouched' 'PASS' ('no managed path lies under .venv/_portable backups/upgrades, DSH home, .cnki-mcp or a forbiddenPaths entry; preserved fingerprints recorded')
        }
    } else {
        Add-Check $checks 'env.userDataUntouched' 'NOT TESTED' 'skipped: package manifest or install root is unavailable'
    }

    $ctx.hasFail = Test-ChecksHaveFail $checks
    return $ctx
}


#endregion

#region ============================== env markers ==================================

function Read-EnvFileState {
    param([string]$Path)
    $r = [ordered]@{
        path = $Path; exists = $false; parseOk = $true; parseError = $null; json = $null; distribution = $null
    }
    if (-not (Test-FileExists $Path)) { return [pscustomobject]$r }
    $r.exists = $true
    try {
        $r.json = Read-JsonDocument $Path
        $r.distribution = Get-JsonPropertyValue $r.json 'distribution'
    } catch {
        $r.parseOk = $false
        $r.parseError = $_.Exception.Message
    }
    return [pscustomobject]$r
}

function Update-EnvMarkersForDetection {
    # Applies "distribution must be rc.2 for CLEAN/HOTFIXED; rc.3 => conflict" to the detected state.
    param($Ctx)
    if ($Ctx.sourceState -ne 'RC2_CLEAN' -and $Ctx.sourceState -ne 'RC2_HOTFIXED') { return $Ctx }
    $conflicts = New-Object System.Collections.ArrayList
    foreach ($c in @($Ctx.conflicts)) { [void]$conflicts.Add($c) }
    $reasons = New-Object System.Collections.ArrayList
    foreach ($r in @($Ctx.reasons)) { [void]$reasons.Add($r) }
    $envDecls = @($Ctx.envFiles)
    foreach ($decl in $envDecls) {
        $rel = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $decl 'path'))
        if ($rel -ne '_portable/install-state.json' -and $rel -ne 'bundle/cnki-research/portable.runtime.json') { continue }
        $full = Join-Path $Ctx.installRoot (ConvertTo-FsPath $rel)
        $state = Read-EnvFileState $full
        if (-not $state.exists -or -not $state.parseOk) { continue }
        $dv = [string]$state.distribution
        if ($dv -eq $script:TargetVersion) {
            [void]$conflicts.Add([ordered]@{
                path           = $rel
                expectedSource = $script:SourceVersion
                expectedTarget = $script:TargetVersion
                actual         = $dv
                category       = 'unexpected-version'
            })
            [void]$reasons.Add('ENV_METADATA_CONFLICT')
        }
    }
    if ($reasons.Count -gt 0) {
        $Ctx.reasons = $reasons.ToArray()
        $Ctx.conflicts = $conflicts.ToArray()
        $Ctx.sourceState = 'UNKNOWN_OR_MODIFIED'
    }
    return $Ctx
}

function Get-EnvMarkersCheckState {
    param($Ctx)
    $issues = New-Object System.Collections.ArrayList
    $warns = New-Object System.Collections.ArrayList
    $ok = New-Object System.Collections.ArrayList
    $state = [string]$Ctx.sourceState
    foreach ($decl in @($Ctx.envFiles)) {
        $rel = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $decl 'path'))
        if ($rel -ne '_portable/install-state.json' -and $rel -ne 'bundle/cnki-research/portable.runtime.json') { continue }
        $mustExist = $false
        $meProp = $decl.PSObject.Properties['mustExist']
        if ($null -ne $meProp) { $mustExist = [bool]$meProp.Value }
        $full = Join-Path ([string]$Ctx.installRoot) (ConvertTo-FsPath $rel)
        $envState = Read-EnvFileState $full
        if (-not $envState.exists) {
            if ($mustExist) { [void]$issues.Add("required environment file is missing: $rel") }
            else { [void]$warns.Add("environment file absent (skipped): $rel") }
            continue
        }
        if (-not $envState.parseOk) { [void]$issues.Add("ENV_FILE_INVALID: $rel ($($envState.parseError))"); continue }
        $dv = [string]$envState.distribution
        if ($state -eq 'RC2_CLEAN' -or $state -eq 'RC2_HOTFIXED') {
            if ($dv -eq $script:SourceVersion) { [void]$ok.Add("$rel=$dv") }
            elseif ($dv -eq $script:TargetVersion) { [void]$issues.Add("ENV_METADATA_CONFLICT: $rel reports $dv while payload is rc.2") }
            else { [void]$warns.Add("$rel distribution='$dv' (unexpected)") }
        } elseif ($state -eq 'RC3_ALREADY_INSTALLED') {
            if ($dv -eq $script:TargetVersion) { [void]$ok.Add("$rel=$dv") }
            elseif ($dv -eq $script:SourceVersion) { [void]$warns.Add("$rel still reports rc.2 metadata") }
            else { [void]$warns.Add("$rel distribution='$dv' (unexpected)") }
        } else {
            if ([string]::IsNullOrEmpty($dv)) { [void]$warns.Add("$rel has no distribution field") }
            else { [void]$ok.Add("$rel=$dv") }
        }
    }
    $venvDir = Join-Path ([string]$Ctx.installRoot) '.venv'
    if (Test-DirExists $venvDir) { [void]$ok.Add('.venv present (preserved)') } else { [void]$warns.Add('.venv directory is absent (runtime may be broken independently; the upgrader never creates or repairs it)') }
    if ($issues.Count -gt 0) {
        return [ordered]@{ status = 'FAIL'; detail = ((@($issues)) -join '; ') }
    }
    if ($warns.Count -gt 0) {
        return [ordered]@{ status = 'WARN'; detail = (((@($ok)) -join '; ') + ' | ' + ((@($warns)) -join '; ')).Trim(' |') }
    }
    return [ordered]@{ status = 'PASS'; detail = ((@($ok)) -join '; ') }
}

#endregion

#region ============================== fault injection (test-only) ====================

function Get-FaultModelFromOptions {
    # Bounded, test-only fault injection. Refused unless CNKI_UPGRADE_TEST_MODE=1.
    param($Options)
    $result = [ordered]@{ ok = $true; error = $null; kind = $null; model = $null; used = $false }
    $faultPlanPath = $null
    if ($null -ne $Options) { $faultPlanPath = $Options.FaultPlan }
    if ([string]::IsNullOrEmpty($faultPlanPath)) { return [pscustomobject]$result }
    $result.used = $true
    $result.kind = 'FAULT_INJECTION_DISALLOWED'
    if ($env:CNKI_UPGRADE_TEST_MODE -ne '1') {
        $result.ok = $false
        $result.error = 'FAULT_INJECTION_DISALLOWED: -FaultPlan is test-only and is refused unless $env:CNKI_UPGRADE_TEST_MODE=1'
        return [pscustomobject]$result
    }
    $result.kind = 'FAULT_PLAN_INVALID'
    if (-not (Test-FileExists $faultPlanPath)) {
        $result.ok = $false
        $result.error = "FAULT_PLAN_INVALID: fault plan file not found: $faultPlanPath"
        return [pscustomobject]$result
    }
    try { $raw = Read-JsonDocument $faultPlanPath } catch {
        $result.ok = $false
        $result.error = "FAULT_PLAN_INVALID: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    $faultValues = @(Get-JsonPropertyValue $raw 'faults')
    if ($faultValues.Count -eq 0) {
        $result.ok = $false
        $result.error = 'FAULT_PLAN_INVALID: "faults" must be a non-empty array of fault tokens'
        return [pscustomobject]$result
    }
    if ($faultValues.Count -gt 16) {
        $result.ok = $false
        $result.error = 'FAULT_PLAN_INVALID: at most 16 fault tokens are allowed'
        return [pscustomobject]$result
    }
    $pattern = '^(FAIL_BACKUP|FAIL_STAGE_HASH)(:[0-9]{1,3})?$|^FAIL_APPLY_INDEX:[0-9]{1,3}$|^CRASH_AFTER_APPLY:[0-9]{1,3}$|^CRASH_AFTER_BACKUP$|^FAIL_VERIFY$|^FAIL_ENV_UPDATE$|^SIMULATE_DISK_LOW$'
    $tokens = New-Object System.Collections.ArrayList
    foreach ($f in $faultValues) {
        $t = [string]$f
        if ($t -notmatch $pattern) {
            $result.ok = $false
            $result.error = "FAULT_PLAN_INVALID: unknown fault token '$t'"
            return [pscustomobject]$result
        }
        [void]$tokens.Add($t)
    }
    $result.model = [pscustomobject]@{ tokens = $tokens.ToArray(); used = $true }
    $result.kind = $null
    return [pscustomobject]$result
}

function Test-FaultPresent {
    param($Model, [string]$Kind)
    if ($null -eq $Model) { return $false }
    foreach ($t in @($Model.tokens)) {
        if ($t -eq $Kind -or $t -like ($Kind + ':*')) { return $true }
    }
    return $false
}

function Get-FaultIndex {
    # 1-based index for indexed faults; 1 when the token has no explicit index; -1 if absent.
    param($Model, [string]$Kind)
    if ($null -eq $Model) { return -1 }
    foreach ($t in @($Model.tokens)) {
        $m = [regex]::Match([string]$t, '^' + [regex]::Escape($Kind) + '(?::([0-9]{1,3}))?$')
        if ($m.Success) {
            if ($m.Groups[1].Success) { return [int]$m.Groups[1].Value }
            return 1
        }
    }
    return -1
}

#endregion

#region ============================== document envelope ==============================

function New-ActionDocument {
    param([string]$Action)
    return [ordered]@{
        schemaVersion  = $script:EnvelopeSchema
        tool           = $script:ToolName
        toolVersion    = $script:ToolVersion
        action         = $Action
        generatedAt    = (Get-Date).ToString('o')
        ok             = $false
        exitCode       = 1
        summary        = $null
        checks         = @()
        sourceState    = $null
        sourceVersion  = $null
        targetVersion  = $script:TargetVersion
        installRoot    = $null
    }
}

function Complete-ActionDocument {
    param($Doc)
    $order = @('schemaVersion', 'tool', 'toolVersion', 'action', 'generatedAt', 'ok', 'exitCode',
        'summary', 'checks', 'sourceState', 'sourceVersion', 'targetVersion', 'installRoot', 'packageRoot',
        'planId', 'plan', 'transaction', 'verify', 'status', 'source', 'conflicts', 'preservedFingerprints',
        'faultInjection', 'errors', 'warnings', 'runtimeActivation')
    $out = [ordered]@{}
    foreach ($k in $order) {
        if ($Doc.Contains($k)) { $out[$k] = $Doc[$k] }
    }
    foreach ($k in @($Doc.Keys)) {
        if (-not $out.Contains($k)) { $out[$k] = $Doc[$k] }
    }
    return $out
}

function Set-ActionOutcome {
    param($Doc, $Checks, [int]$ExitCode, [string]$Outcome, [bool]$Refused = $false, $Errors = @(), $Warnings = @())
    $checksArray = @()
    if ($null -ne $Checks) {
        if ($Checks -is [System.Collections.ArrayList]) { $checksArray = [object[]]$Checks.ToArray() }
        elseif ($Checks -is [System.Array]) { $checksArray = [object[]]$Checks }
        else { $checksArray = [object[]]@($Checks) }
    }
    $Doc.checks = $checksArray
    $summary = Get-CheckSummary $Checks
    $summary.refused = $Refused
    $summary.outcome = $Outcome
    $Doc.summary = $summary
    $Doc.exitCode = $ExitCode
    $Doc.ok = ($ExitCode -eq 0)
    $errList = New-Object System.Collections.ArrayList
    foreach ($e in @($Errors)) { if (-not [string]::IsNullOrEmpty([string]$e)) { [void]$errList.Add([string]$e) } }
    foreach ($c in $checksArray) {
        if ([string]$c['status'] -eq 'FAIL') { [void]$errList.Add('CHECK_FAILED: ' + [string]$c['id'] + ' - ' + [string]$c['detail']) }
    }
    $warnList = New-Object System.Collections.ArrayList
    foreach ($w in @($Warnings)) { if (-not [string]::IsNullOrEmpty([string]$w)) { [void]$warnList.Add([string]$w) } }
    foreach ($c in $checksArray) {
        if ([string]$c['status'] -eq 'WARN') { [void]$warnList.Add('CHECK_WARN: ' + [string]$c['id'] + ' - ' + [string]$c['detail']) }
    }
    $Doc.errors = $errList.ToArray()
    $Doc.warnings = $warnList.ToArray()
    $Doc.runtimeActivation = 'NOT TESTED'
}

function Merge-CheckLists {
    param($BaseChecks, $ExtraChecks)
    $merged = New-Object System.Collections.ArrayList
    foreach ($c in @($BaseChecks)) { if ($null -ne $c) { [void]$merged.Add($c) } }
    foreach ($c in @($ExtraChecks)) { if ($null -ne $c) { [void]$merged.Add($c) } }
    return $merged
}

function Set-SourceDocumentFields {
    param($Doc, $Ctx)
    $Doc.installRoot = $Ctx.installRoot
    if ($null -ne $Ctx.packageRoot) { $Doc.packageRoot = $Ctx.packageRoot }
    $Doc.sourceState = $Ctx.sourceState
    $Doc.sourceVersion = $Ctx.sourceVersion
    if ($Ctx.notInstalled) { $Doc.notInstalled = $true; $Doc.notInstalledReason = [string]$Ctx.notInstalledReason }
    if ($Ctx.selfMode) { $Doc.selfMode = $true }
    $source = [ordered]@{
        state           = $Ctx.sourceState
        version         = $Ctx.sourceVersion
        variant         = $Ctx.rc3Variant
        hotfixedVariant = $Ctx.hotfixedVariant
        reasons         = @($Ctx.reasons)
        conflicts       = @($Ctx.conflicts)
        sourceMatches   = [int]$Ctx.sourceMatchCount
        targetMatches   = [int]$Ctx.targetMatchCount
        sourcePayloadFileCount = [int]$Ctx.sourcePayloadFileCount
        payloadFileCount = [int]$Ctx.targetPayloadFileCount
        addedFileCount  = [int]$Ctx.addedFileCount
        payloadRoot     = [string]$Ctx.payloadRoot
    }
    $Doc.source = $source
    if (@($Ctx.conflicts).Count -gt 0) { $Doc.conflicts = @($Ctx.conflicts) }
    $Doc.preservedFingerprints = $Ctx.preservedFingerprints
    return $Doc
}


#endregion

#region ============================== PLAN ===========================================

function Get-PayloadApplyOrder {
    # Normative apply order: all payload files except VERSION/manifest.json (Ordinal),
    # then manifest.json, then VERSION. (Version markers last.)
    param($Ctx)
    $paths = New-Object System.Collections.ArrayList
    foreach ($cf in @($Ctx.changedFiles)) { [void]$paths.Add((ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path')))) }
    $present = @{}
    foreach ($p in $paths) { $present[$p.ToLowerInvariant()] = $p }
    $others = New-Object System.Collections.ArrayList
    foreach ($p in $paths) {
        if ($p -ieq 'VERSION' -or $p -ieq 'manifest.json') { continue }
        [void]$others.Add($p)
    }
    $sortedOthers = @(Sort-Ordinal $others.ToArray())
    $result = New-Object System.Collections.ArrayList
    foreach ($p in $sortedOthers) { [void]$result.Add($p) }
    if ($present.ContainsKey('manifest.json')) { [void]$result.Add($present['manifest.json']) }
    if ($present.ContainsKey('version')) { [void]$result.Add($present['version']) }
    return $result.ToArray()
}

function Get-PlanIdMaterial {
    # Deterministic planId material (no timestamps, no random values). The same function
    # is used by PLAN and by APPLY's planId gate, so an unchanged install yields the same
    # planId across invocations. v2 adds the target package anchors (manifest + metadata
    # hashes), the payload counts and the changed-file operation.
    param($Ctx, [string]$InstallRootCanonical, $PlanFiles, $PlanEnvFiles)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append([string]$script:UpgradeId + "`n")
    [void]$sb.Append($InstallRootCanonical + "`n")
    [void]$sb.Append([string]$Ctx.sourceState + "`n")
    if ($Ctx.sourceState -eq 'RC2_HOTFIXED') { [void]$sb.Append([string]$Ctx.hotfixedVariant + "`n") }
    else { [void]$sb.Append("`n") }
    $sumsSha = ''
    if ($null -ne $Ctx.packageData) { $sumsSha = [string]$Ctx.packageData.sumsSha256 }
    [void]$sb.Append($sumsSha + "`n")
    $manifestSha = ''
    $metadataSha = ''
    if ($null -ne $Ctx.packageData) {
        $manifestSha = [string]$Ctx.packageData.manifestSha256
        $metadataSha = [string]$Ctx.packageData.metadataSha256
    }
    [void]$sb.Append($manifestSha + "`n")
    [void]$sb.Append($metadataSha + "`n")
    [void]$sb.Append([string]$Ctx.payloadRoot + "`n")
    [void]$sb.Append([string]$Ctx.sourcePayloadFileCount + "`n")
    [void]$sb.Append([string]$Ctx.targetPayloadFileCount + "`n")
    [void]$sb.Append([string]$Ctx.addedFileCount + "`n")
    foreach ($f in @($PlanFiles)) {
        [void]$sb.Append([string]$f['path'] + "`t" + [string]$f['operation'] + "`t" + [string]$f['sourceSha256'] + "`t" +
            [string]$f['declaredSourceSha256'] + "`t" + [string]$f['targetSha256'] + "`n")
    }
    foreach ($e in @($PlanEnvFiles)) {
        [void]$sb.Append([string]$e['path'] + "`t" + [string]$e['beforeSha256'] + "`t" + [string]$e['afterFormat'] + "`n")
    }
    $fp = 'ABSENT'
    if ($null -ne $Ctx.dshProfileInfo) { $fp = [string]$Ctx.dshProfileInfo.fingerprint }
    [void]$sb.Append($fp + "`n")
    return $sb.ToString()
}


function New-ApplyPlan {
    param($Ctx, $Options, [switch]$ForNoOp)
    $root = [string]$Ctx.installRoot
    $backupRoot = $null
    if ($null -ne $Options -and -not [string]::IsNullOrEmpty($Options.BackupRoot)) {
        try { $backupRoot = Get-NormalizedFullPath $Options.BackupRoot } catch { $backupRoot = $null }
    }
    if ([string]::IsNullOrEmpty($backupRoot)) { $backupRoot = Get-DefaultTransactionRoot $root }
    $plannedTxnId = '(not-created)'
    if (-not $ForNoOp) { $plannedTxnId = New-TransactionId }
    $plannedTxnDir = Join-Path $backupRoot $plannedTxnId
    $plan = [ordered]@{}
    $plan.actionable = (($Ctx.sourceState -eq 'RC2_CLEAN' -or $Ctx.sourceState -eq 'RC2_HOTFIXED') -and (-not $Ctx.hasFail))
    $plan.noOp = ($Ctx.sourceState -eq 'RC3_ALREADY_INSTALLED')
    $plan.sourceState = $Ctx.sourceState
    $plan.sourceVersion = $Ctx.sourceVersion
    $plan.variant = $Ctx.rc3Variant
    $plan.hotfixedVariant = $Ctx.hotfixedVariant
    $plan.targetVersion = $script:TargetVersion
    $plan.upgradeId = $script:UpgradeId
    $plan.installRoot = $root
    $plan.packageRoot = $Ctx.packageRoot
    $plan.payloadRoot = [string]$Ctx.payloadRoot
    $plan.sourcePayloadFileCount = [int]$Ctx.sourcePayloadFileCount
    $plan.targetPayloadFileCount = [int]$Ctx.targetPayloadFileCount
    $plan.addedFileCount = [int]$Ctx.addedFileCount
    $plan.packageSumsSha256 = ''
    $plan.packageManifestSha256 = ''
    $plan.metadataSha256 = ''
    $plan.sourceManifestHash = $script:SourceManifestHash
    $plan.targetManifestHash = ''
    if ($null -ne $Ctx.packageData) {
        $plan.packageSumsSha256 = [string]$Ctx.packageData.sumsSha256
        $plan.packageManifestSha256 = [string]$Ctx.packageData.manifestSha256
        $plan.metadataSha256 = [string]$Ctx.packageData.metadataSha256
        $plan.targetManifestHash = [string]$Ctx.packageData.manifestSha256
        $plan.manifestSha256 = [string]$Ctx.packageData.manifestSha256
    }
    # changed files (Ordinal sorted by path)
    $changed = New-Object System.Collections.ArrayList
    foreach ($cf in @($Ctx.changedFiles)) {
        $p = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $cf 'path'))
        $operation = 'replace'
        $operationVal = [string](Get-JsonPropertyValue $cf 'operation')
        if (-not [string]::IsNullOrEmpty($operationVal)) { $operation = $operationVal }
        $actual = 'ABSENT'
        if ($null -ne $Ctx.hashes -and $Ctx.hashes.ContainsKey($p)) { $actual = [string]$Ctx.hashes[$p] }
        $declared = ''
        if ($null -ne $Ctx.expectedSource -and $Ctx.expectedSource.ContainsKey($p)) { $declared = [string]$Ctx.expectedSource[$p] }
        $target = ''
        if ($null -ne $Ctx.resolvedTargetHashes -and $Ctx.resolvedTargetHashes.ContainsKey($p)) { $target = [string]$Ctx.resolvedTargetHashes[$p] }
        if ([string]::IsNullOrEmpty($target)) { throw "PATCH_TARGET_SHA_UNRESOLVED: no target hash for changed file '$p'" }
        if ($p -ieq $script:DistributionManifestRelPath) {
            $actual = [string]$Ctx.installManifestSha256
            $declared = $script:SourceManifestHash
        }
        $tbytes = [long](Get-JsonPropertyValue $cf 'targetBytes')
        if ($tbytes -le 0 -and $null -ne $Ctx.packageData) {
            $len = Get-FileLengthSafe (Join-Path ([string]$Ctx.packageData.targetRoot) (ConvertTo-FsPath $p))
            if ($len -gt 0) { $tbytes = $len }
        }
        $entry = [ordered]@{
            path                 = $p
            operation            = $operation
            classification       = [string](Get-JsonPropertyValue $cf 'classification')
            existed              = $(if ($operation -eq 'add') { $false } else { (Test-FileExists (Join-Path $root (ConvertTo-FsPath $p))) })
            sourceSha256         = $actual
            declaredSourceSha256 = $declared
            targetSha256         = $target
            targetBytes          = $tbytes
        }
        if ($p -ieq $script:CordisPath -and $null -ne $Ctx.hotfixedVariant) { $entry['hotfixVariant'] = $Ctx.hotfixedVariant }
        [void]$changed.Add($entry)
    }
    $pathsOnly = New-Object System.Collections.ArrayList
    foreach ($c in $changed) { [void]$pathsOnly.Add([string]$c['path']) }
    $sortedPaths = @(Sort-Ordinal $pathsOnly.ToArray())
    $cfByPath = @{}
    foreach ($c in $changed) { $cfByPath[([string]$c['path']).ToLowerInvariant()] = $c }
    $planChanged = New-Object System.Collections.ArrayList
    foreach ($p in $sortedPaths) { [void]$planChanged.Add($cfByPath[$p.ToLowerInvariant()]) }
    $plan.changedFiles = $planChanged.ToArray()
    $plan.changedFileCount = $plan.changedFiles.Count
    $addedList = New-Object System.Collections.ArrayList
    $replacedList = New-Object System.Collections.ArrayList
    foreach ($c in $plan.changedFiles) {
        if ([string]$c['operation'] -eq 'add') { [void]$addedList.Add($c) } else { [void]$replacedList.Add($c) }
    }
    $plan.addedFiles = $addedList.ToArray()
    $plan.replacedFiles = $replacedList.ToArray()
    $plan.addedFileCount = $addedList.Count
    $plan.replacedFileCount = $replacedList.Count
    # directories that the transaction must create for operation "add" targets
    $addPaths = New-Object System.Collections.ArrayList
    foreach ($c in $addedList) { [void]$addPaths.Add([string]$c['path']) }
    $plan.createDirectories = @(Get-CreatedDirectoryPlan -InstallRoot $root -FilePaths $addPaths.ToArray())
    # environment updates (Ordinal sorted by path)
    $envEntries = New-Object System.Collections.ArrayList
    foreach ($decl in @($Ctx.envFiles)) {
        $p = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $decl 'path'))
        $full = Join-Path $root (ConvertTo-FsPath $p)
        $exists = Test-FileExists $full
        $beforeSha = 'ABSENT'
        if ($exists) { try { $beforeSha = Get-Sha256File $full } catch { $beforeSha = 'UNREADABLE' } }
        $mustExist = $false
        $meProp = $decl.PSObject.Properties['mustExist']
        if ($null -ne $meProp) { $mustExist = [bool]$meProp.Value }
        $updates = @(Get-JsonPropertyValue $decl 'updates')
        $expectedBefore = $null
        if ($updates.Count -gt 0) {
            $expectedBefore = Get-JsonPropertyValue $updates[0] 'expectedBefore'
        }
        $entry = [ordered]@{
            path           = $p
            format         = 'json'
            mustExist      = $mustExist
            exists         = $exists
            skipped        = (-not $exists)
            skipReason     = $(if ($exists) { $null } else { 'ENV_FILE_ABSENT' })
            beforeSha256   = $beforeSha
            expectedBefore = $expectedBefore
            updates        = $updates
            afterFormat    = (Get-EnvDeclarationAfterFormat $decl)
            willApply      = ($exists -and -not $plan.noOp -and $plan.actionable)
        }
        [void]$envEntries.Add($entry)
    }
    $envList = New-Object System.Collections.ArrayList
    foreach ($e in $envEntries) { [void]$envList.Add([string]$e['path']) }
    $envSortedPaths = @(Sort-Ordinal $envList.ToArray())
    $envByPath = @{}
    foreach ($e in $envEntries) { $envByPath[([string]$e['path']).ToLowerInvariant()] = $e }
    $planEnv = New-Object System.Collections.ArrayList
    foreach ($p in $envSortedPaths) { [void]$planEnv.Add($envByPath[$p.ToLowerInvariant()]) }
    $plan.environmentUpdates = $planEnv.ToArray()
    $plan.environmentFileCount = $plan.environmentUpdates.Count
    # locations
    $plan.backupLocation = (Join-Path $plannedTxnDir 'backup')
    $plan.backup = [ordered]@{ plannedPath = $plan.backupLocation; planned = $true; created = $false }
    $plan.stagingLocation = (Join-Path $plannedTxnDir 'staging')
    $plan.staging = [ordered]@{ plannedPath = $plan.stagingLocation; planned = $true; created = $false }
    $plan.plannedTransactionId = $plannedTxnId
    $plan.transactionRoot = $backupRoot
    # write scope
    $scope = New-Object System.Collections.ArrayList
    foreach ($c in $plan.changedFiles) { [void]$scope.Add((Join-Path $root (ConvertTo-FsPath ([string]$c['path'])))) }
    foreach ($e in $plan.environmentUpdates) { if ($e['exists']) { [void]$scope.Add((Join-Path $root (ConvertTo-FsPath ([string]$e['path'])))) } }
    foreach ($d in @($plan.createDirectories)) { [void]$scope.Add((Join-Path $root (ConvertTo-FsPath ([string]$d)))) }
    [void]$scope.Add($plannedTxnDir)
    $plan.writeScope = @(Sort-Ordinal @($scope.ToArray()))
    $plan.requiresDshExit = $false
    if ($null -ne $Ctx.dshPolicy) { $plan.requiresDshExit = [bool]$Ctx.dshPolicy.requiresDshExit }
    $plan.recommendDshExit = $true
    $plan.activation = [ordered]@{
        method             = 'normal DSH restart'
        note               = 'close and reopen the DSH application normally; do not force-kill processes and do not edit the DSH profile'
        pluginManagerRerun = $false
        venvRebuild        = $false
        profileEdit        = $false
    }
    $plan.failureRecovery = 'transactional APPLY: on any failure the engine auto-restores from the per-file backup (replaced files) and deletes only the added files whose bytes still equal the applied target hash, then exits 2; a later -Action rollback restores from the transaction. Added files modified by the user are never silently deleted.'
    $plan.conflicts = @($Ctx.conflicts)
    $plan.reasons = @($Ctx.reasons)
    $warnings = New-Object System.Collections.ArrayList
    foreach ($c in @($Ctx.checks)) {
        if ([string]$c['status'] -eq 'WARN') { [void]$warnings.Add([string]$c['id'] + ': ' + [string]$c['detail']) }
    }
    $plan.warnings = $warnings.ToArray()
    $plan.preservedFingerprints = $Ctx.preservedFingerprints
    $dshProfile = [ordered]@{ name = $null; outcome = 'NOT_FOUND'; dependencyValue = $null; junctionTarget = $null; fingerprint = 'ABSENT' }
    if ($null -ne $Ctx.dshProfileInfo) {
        $dshProfile.name = $Ctx.dshProfileInfo.selectedName
        $dshProfile.outcome = $Ctx.dshProfileInfo.outcome
        $dshProfile.dependencyValue = $Ctx.dshProfileInfo.dependencyValue
        $dshProfile.junctionTarget = $Ctx.dshProfileInfo.junctionTarget
        $dshProfile.fingerprint = $Ctx.dshProfileInfo.fingerprint
        $dshProfile.profileDir = $Ctx.dshProfileInfo.selectedDir
        $dshProfile.packageJsonSha256 = $Ctx.dshProfileInfo.packageJsonSha256
    }
    $plan.dshProfile = $dshProfile
    # planId
    $material = Get-PlanIdMaterial -Ctx $Ctx -InstallRootCanonical $root -PlanFiles $plan.changedFiles -PlanEnvFiles $plan.environmentUpdates
    $planId = Get-Sha256Text $material
    $plan.materialSha256 = $planId
    return [pscustomobject]@{ plan = $plan; planId = $planId; material = $material; backupRoot = $backupRoot; plannedTxnId = $plannedTxnId }
}


#endregion

#region ============================== VERIFY =========================================

function Get-InstallManifestInfo {
    param([string]$InstallRoot)
    $r = [ordered]@{ exists = $false; path = $null; sha256 = 'ABSENT'; json = $null; parseOk = $false; error = $null }
    $p = Join-Path $InstallRoot 'manifest.json'
    $r.path = $p
    if (-not (Test-FileExists $p)) { return [pscustomobject]$r }
    $r.exists = $true
    try {
        $r.sha256 = Get-Sha256File $p
        $r.json = Read-JsonDocument $p
        $r.parseOk = $true
    } catch {
        $r.error = $_.Exception.Message
    }
    return [pscustomobject]$r
}

function Get-FileToolNameCount {
    param([string]$Text, [string]$ToolName)
    return ([regex]::Matches($Text, [regex]::Escape('name="' + $ToolName + '"'))).Count
}

function Get-TargetVerifyChecks {
    # Full read-only target-state verification (adapted from V1 ENGINE_SPEC section 8).
    # v2: the expected manifest identity is resolved at runtime from the package
    # (SHA256SUMS.txt -> manifest.json); the target payload map covers all P files
    # (including operation="add" files). A frozen-RC3 install (recognised via the
    # independent frozen manifest constant) is verified against its own authentic
    # manifest files[] map and reported as complete core with a WARN.
    param($Ctx, $Txn)
    $checks = New-CheckList
    $root = [string]$Ctx.installRoot
    $state = [string]$Ctx.sourceState
    $variant = [string]$Ctx.rc3Variant
    $frozenCore = ($state -eq 'RC3_ALREADY_INSTALLED' -and $variant -eq 'FROZEN_RC3')
    $expectedManifestSha = ''
    $expectedPayloadMap = $null
    $expectedPayloadCount = 0
    if ($null -ne $Ctx.packageData -and [bool]$Ctx.packageValid) {
        $expectedManifestSha = [string]$Ctx.packageData.manifestSha256
        $expectedPayloadMap = $Ctx.packageData.targetFilesMap
        $expectedPayloadCount = [int]$Ctx.packageData.targetPayloadFileCount
    }
    if ($frozenCore) {
        $expectedManifestSha = $script:FrozenRc3ManifestHash
        $imFrozen = Get-InstallManifestInfo $root
        $frozenMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)
        if ($imFrozen.parseOk) {
            foreach ($f in @(Get-JsonPropertyValue $imFrozen.json 'files')) {
                $fp = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $f 'path'))
                if (-not [string]::IsNullOrEmpty($fp)) { $frozenMap[$fp] = ([string](Get-JsonPropertyValue $f 'sha256')).ToLowerInvariant() }
            }
        }
        $expectedPayloadMap = $frozenMap
        $expectedPayloadCount = $frozenMap.Count
    }
    $packageContext = ($null -ne $expectedPayloadMap -and $expectedPayloadCount -gt 0)
    if (-not $packageContext) {
        Add-Check $checks 'verify.version' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.manifest' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.payloadHashes' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.upgradeData' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.preset' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.launcher' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.tools' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.pathContract' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.userData' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.envMetadata' 'NOT TESTED' 'skipped: package manifest is unavailable'
        Add-Check $checks 'verify.packageVariant' 'NOT TESTED' 'skipped: package manifest is unavailable'
        return [pscustomobject]@{ checks = $checks; fileUpgradeComplete = $false; failCount = 1; variant = $Ctx.rc3Variant; payloadFileCount = 0; addedFileCount = 0 }
    }
    if (-not (Test-DirExists $root)) {
        foreach ($id in @('verify.version', 'verify.manifest', 'verify.payloadHashes', 'verify.upgradeData', 'verify.preset', 'verify.launcher', 'verify.tools', 'verify.pathContract')) {
            Add-Check $checks $id 'FAIL' 'install root does not exist'
        }
        Add-Check $checks 'verify.userData' 'NOT TESTED' 'install root does not exist'
        Add-Check $checks 'verify.envMetadata' 'NOT TESTED' 'install root does not exist'
        Add-Check $checks 'verify.packageVariant' 'NOT TESTED' 'install root does not exist'
        return [pscustomobject]@{ checks = $checks; fileUpgradeComplete = $false; failCount = 1; variant = $Ctx.rc3Variant; payloadFileCount = $expectedPayloadCount; addedFileCount = [int]$Ctx.addedFileCount }
    }
    # 1. version
    $versionPath = Join-Path $root 'VERSION'
    $versionTrim = ''
    if (Test-FileExists $versionPath) {
        try { $versionTrim = (Read-TextFileUtf8 $versionPath).Trim() } catch { }
    }
    if ($versionTrim -eq $script:TargetVersion) {
        Add-Check $checks 'verify.version' 'PASS' "VERSION is '$versionTrim'"
    } else {
        Add-Check $checks 'verify.version' 'FAIL' "VERSION is '$versionTrim', expected '$($script:TargetVersion)'"
    }
    # 2. manifest
    $im = Get-InstallManifestInfo $root
    if (-not $im.exists) {
        Add-Check $checks 'verify.manifest' 'FAIL' 'manifest.json is missing'
    } elseif (-not $im.parseOk) {
        Add-Check $checks 'verify.manifest' 'FAIL' "manifest.json is unreadable: $($im.error)"
    } else {
        $mproblems = New-Object System.Collections.ArrayList
        if (-not [string]::IsNullOrEmpty($expectedManifestSha) -and
            -not [string]::Equals([string]$im.sha256, $expectedManifestSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            $mproblems.Add("manifest.json sha256 does not equal the expected target manifest hash")
        }
        if ([int](Get-JsonPropertyValue $im.json 'schemaVersion') -ne 1) { $mproblems.Add('schemaVersion != 1') }
        $dist = Get-JsonPropertyValue $im.json 'distribution'
        if ([string](Get-JsonPropertyValue $dist 'version') -ne $script:TargetVersion) { $mproblems.Add('distribution.version is not the target version') }
        $bundle = Get-JsonPropertyValue $im.json 'bundle'
        if ([string](Get-JsonPropertyValue $bundle 'version') -ne $script:BundleVersion) { $mproblems.Add('bundle.version is not 1.0.0') }
        $files = @(Get-JsonPropertyValue $im.json 'files')
        if ($files.Count -ne $expectedPayloadCount) { $mproblems.Add("manifest files[] has $($files.Count) entries, expected $expectedPayloadCount") }
        $fm = @{}
        foreach ($f in $files) {
            $fp = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $f 'path'))
            $fs = ([string](Get-JsonPropertyValue $f 'sha256')).ToLowerInvariant()
            $fm[$fp.ToLowerInvariant()] = $fs
            $full = Join-Path $root (ConvertTo-FsPath $fp)
            if (-not (Test-FileExists $full)) { $mproblems.Add("listed file missing: $fp"); continue }
            try {
                $actual = Get-Sha256File $full
                if (-not [string]::Equals($actual, $fs, [System.StringComparison]::OrdinalIgnoreCase)) { $mproblems.Add("listed hash mismatch: $fp") }
            } catch { $mproblems.Add("listed file unreadable: $fp") }
        }
        foreach ($k in @($expectedPayloadMap.Keys)) {
            if (-not $fm.ContainsKey(([string]$k).ToLowerInvariant())) { $mproblems.Add("target payload file not listed in manifest: $k"); break }
        }
        if ($fm.Count -ne $expectedPayloadMap.Count) { $mproblems.Add('manifest files[] key set differs from the expected target payload map') }
        if ($mproblems.Count -gt 0) {
            Add-Check $checks 'verify.manifest' 'FAIL' ((@($mproblems) | Select-Object -First 10) -join '; ')
        } else {
            Add-Check $checks 'verify.manifest' 'PASS' "manifest.json sha256 matches the target identity; $($files.Count) listed files verified"
        }
    }
    # 3. payload hashes (independent of the install manifest)
    $hashInfo = Get-InstallTreeHashes -InstallRoot $root -Paths @($expectedPayloadMap.Keys)
    $mismatches = New-Object System.Collections.ArrayList
    foreach ($k in @($expectedPayloadMap.Keys)) {
        $actual = [string]$hashInfo.hashes[$k]
        if (-not [string]::Equals($actual, [string]$expectedPayloadMap[$k], [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$mismatches.Add("$k=$actual")
        }
    }
    if ($mismatches.Count -eq 0) {
        Add-Check $checks 'verify.payloadHashes' 'PASS' "all $expectedPayloadCount target payload files match expectedTargetHashes ($([int]$Ctx.addedFileCount) of them are operation=add files)"
    } else {
        Add-Check $checks 'verify.payloadHashes' 'FAIL' ("$($mismatches.Count) payload file(s) differ from target: " + (((@($mismatches)) | Select-Object -First 10) -join ', '))
    }
    # 4. upgrade metadata placement (package-only by design)
    if ($frozenCore) {
        Add-Check $checks 'verify.upgradeData' 'WARN' 'FROZEN_RC3: core rc.3 complete but unified tooling additions (tools/setup.ps1, tools/lib/UpgradeCommon.ps1, upgrade-data) are not installed; no automatic refresh is offered (documented limitation)'
    } else {
        $installedMetadata = Join-Path $root (ConvertTo-FsPath $script:UpgradeDataRelPath)
        if (Test-FileExists $installedMetadata) {
            Add-Check $checks 'verify.upgradeData' 'WARN' ("upgrade-data is package-only metadata but an installed copy exists at $($script:UpgradeDataRelPath); it is not part of the managed target payload and was not written by this engine")
        } else {
            Add-Check $checks 'verify.upgradeData' 'PASS' 'upgrade-data/README.md and upgrade-data/rc2-to-rc3.json are package-only metadata; the installed target is exactly the payload set + manifest.json (package-side hashes were verified by the package integrity checks)'
        }
    }
    # 5. preset (cordis.patch.yml)
    $cordisPath = Join-Path $root (ConvertTo-FsPath $script:CordisPath)
    if (-not (Test-FileExists $cordisPath)) {
        Add-Check $checks 'verify.preset' 'FAIL' "cordis.patch.yml is missing: $($script:CordisPath)"
    } else {
        $pproblems = New-Object System.Collections.ArrayList
        $ctext = Read-TextFileUtf8 $cordisPath
        if ($ctext.IndexOf($script:CordisPresetId) -lt 0) { [void]$pproblems.Add("missing '$($script:CordisPresetId)'") }
        if ($ctext.IndexOf($script:CordisMcpClient) -lt 0) { [void]$pproblems.Add("missing '$($script:CordisMcpClient)'") }
        if ($ctext.IndexOf('serverName: cnki') -lt 0) { [void]$pproblems.Add("missing 'serverName: cnki'") }
        if ($ctext.IndexOf('failOnStartupError: false') -lt 0) { [void]$pproblems.Add("missing 'failOnStartupError: false'") }
        $cwdCount = ([regex]::Matches($ctext, [regex]::Escape($script:ForbiddenCwd))).Count
        if ($cwdCount -ne 0) { [void]$pproblems.Add("contains $cwdCount occurrence(s) of the forbidden '$($script:ForbiddenCwd)' token") }
        if ($ctext.IndexOf($script:PersonaPrefix) -lt 0) { [void]$pproblems.Add("missing persona prefix '$($script:PersonaPrefix)'") }
        if ($ctext -match '[A-Za-z]:[\\/]') { [void]$pproblems.Add('contains an absolute Windows path') }
        if ($ctext -match '\\\\[A-Za-z0-9_.-]+\\') { [void]$pproblems.Add('contains a UNC path') }
        if ($ctext -match '(?i)[A-Za-z]:\\Users\\') { [void]$pproblems.Add('contains a user-profile absolute path') }
        if ($pproblems.Count -gt 0) {
            Add-Check $checks 'verify.preset' 'FAIL' ((@($pproblems) | Select-Object -First 10) -join '; ')
        } else {
            Add-Check $checks 'verify.preset' 'PASS' 'cordis.patch.yml preset/mcp/persona assertions pass; no {{cwd}} and no absolute/UNC/user paths'
        }
    }
    # 6. launcher
    $launcherPath = Join-Path $root (ConvertTo-FsPath $script:LauncherPath)
    if (-not (Test-FileExists $launcherPath)) {
        Add-Check $checks 'verify.launcher' 'FAIL' "launcher is missing: $($script:LauncherPath)"
    } else {
        $lproblems = New-Object System.Collections.ArrayList
        try {
            $lsha = Get-Sha256File $launcherPath
            $expectedLauncherSha = ''
            if ($expectedPayloadMap.ContainsKey($script:LauncherPath)) { $expectedLauncherSha = [string]$expectedPayloadMap[$script:LauncherPath] }
            if ([string]::IsNullOrEmpty($expectedLauncherSha)) { [void]$lproblems.Add('launcher is not part of the target payload map') }
            elseif (-not [string]::Equals($lsha, $expectedLauncherSha, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$lproblems.Add('launcher sha256 does not match the target payload map') }
        } catch { [void]$lproblems.Add('launcher is unreadable') }
        try {
            $ltext = Read-TextFileUtf8 $launcherPath
            if ($ltext.IndexOf('--selfcheck') -lt 0) { [void]$lproblems.Add("missing '--selfcheck'") }
            if ($ltext.IndexOf('--tools-json') -lt 0) { [void]$lproblems.Add("missing '--tools-json'") }
            if ($ltext.IndexOf('McpToolService') -lt 0) { [void]$lproblems.Add("missing 'McpToolService'") }
        } catch { [void]$lproblems.Add('launcher content is unreadable') }
        if ($lproblems.Count -gt 0) { Add-Check $checks 'verify.launcher' 'FAIL' ((@($lproblems)) -join '; ') }
        else { Add-Check $checks 'verify.launcher' 'PASS' 'launcher exists, hash matches, --selfcheck/--tools-json/McpToolService present' }
    }
    # 7. tools (static only - never claim served schema)
    $tproblems = New-Object System.Collections.ArrayList
    $serverPath = Join-Path $root (ConvertTo-FsPath $script:ServerPyPath)
    $registryPath = Join-Path $root (ConvertTo-FsPath $script:ToolRegistryPyPath)
    if (-not (Test-FileExists $serverPath)) { [void]$tproblems.Add('cnki_mcp_server.py is missing') }
    else {
        try {
            $stext = Read-TextFileUtf8 $serverPath
            foreach ($tool in $script:RequiredToolNames) {
                $cnt = Get-FileToolNameCount $stext $tool
                if ($cnt -ne 1) { [void]$tproblems.Add("MCP tool '$tool' appears $cnt times as name=""$tool"" (expected 1)") }
            }
        } catch { [void]$tproblems.Add('cnki_mcp_server.py is unreadable') }
    }
    if (-not (Test-FileExists $registryPath)) { [void]$tproblems.Add('tool_registry.py is missing') }
    else {
        try {
            $rtext = Read-TextFileUtf8 $registryPath
            $idx = $rtext.IndexOf('def get_info_by_detail(')
            if ($idx -lt 0) { [void]$tproblems.Add('tool_registry.py has no get_info_by_detail definition') }
            else {
                $window = $rtext.Substring($idx, [Math]::Min(8000, $rtext.Length - $idx))
                if ($window -notmatch '(?s)\btitle: str') { [void]$tproblems.Add('get_info_by_detail has no required positional title: str parameter') }
                if ($window -match 'title\s*:\s*str\s*=') { [void]$tproblems.Add('get_info_by_detail title parameter has a default value') }
            }
        } catch { [void]$tproblems.Add('tool_registry.py is unreadable') }
    }
    $im2 = Get-InstallManifestInfo $root
    if ($im2.parseOk) {
        $bundle2 = Get-JsonPropertyValue $im2.json 'bundle'
        $tools = @(Get-JsonPropertyValue $bundle2 'mcpTools')
        $toolSet = @{}
        foreach ($t in $tools) { $toolSet[([string]$t)] = $true }
        foreach ($tool in $script:RequiredToolNames) {
            if (-not $toolSet.ContainsKey($tool)) { [void]$tproblems.Add("manifest bundle.mcpTools is missing '$tool'") }
        }
        if ($tools.Count -ne $script:RequiredToolNames.Count) { [void]$tproblems.Add("manifest bundle.mcpTools count $($tools.Count) != $($script:RequiredToolNames.Count)") }
        $resources = @(Get-JsonPropertyValue $bundle2 'mcpResources')
        foreach ($res in $script:RequiredMcpResources) {
            $found = $false
            foreach ($r in $resources) { if ([string]$r -eq $res) { $found = $true; break } }
            if (-not $found) { [void]$tproblems.Add("manifest bundle.mcpResources is missing '$res'") }
        }
    } else {
        [void]$tproblems.Add('install manifest is unavailable for mcpTools/mcpResources verification')
    }
    if ($tproblems.Count -gt 0) {
        Add-Check $checks 'verify.tools' 'FAIL' ((@($tproblems) | Select-Object -First 10) -join '; ')
    } else {
        Add-Check $checks 'verify.tools' 'PASS' 'static tool/resource checks pass (8 MCP tool names, title required, manifest mcpTools/mcpResources); served schema NOT TESTED'
    }
    # 8. path contract
    $pcProblems = New-Object System.Collections.ArrayList
    $bundlePkgPath = Join-Path $root (ConvertTo-FsPath $script:BundlePackageJson)
    if (-not (Test-FileExists $bundlePkgPath)) {
        [void]$pcProblems.Add('bundle/cnki-research/package.json is missing')
    } else {
        try {
            $bp = Read-JsonDocument $bundlePkgPath
            if ([string](Get-JsonPropertyValue $bp 'name') -ne '@local/dsh-cnki-research') { [void]$pcProblems.Add('bundle package name is not @local/dsh-cnki-research') }
            if ([string](Get-JsonPropertyValue $bp 'version') -ne '1.0.0') { [void]$pcProblems.Add('bundle package version is not 1.0.0') }
            $dshNode = Get-JsonPropertyValue $bp 'dsh'
            $bundleNode = Get-JsonPropertyValue $dshNode 'bundle'
            if ([string](Get-JsonPropertyValue $bundleNode 'patch') -ne './cordis.patch.yml') { [void]$pcProblems.Add('dsh.bundle.patch is not ./cordis.patch.yml') }
        } catch { [void]$pcProblems.Add('bundle package.json is unreadable') }
    }
    if ($null -ne $Ctx.dshProfileInfo) {
        if ($Ctx.dshProfileInfo.outcome -eq 'MATCH') {
            $expectedBundle = Join-Path $root 'bundle\cnki-research'
            if (-not [string]::Equals([string]$Ctx.dshProfileInfo.junctionTarget, $expectedBundle, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$pcProblems.Add('DSH profile junction no longer resolves to this install root bundle')
            }
            if ($null -ne $Txn -and $null -ne $Txn.dshProfile) {
                $preDep = [string](Get-JsonPropertyValue $Txn.dshProfile 'dependencyValue')
                if (-not [string]::IsNullOrEmpty($preDep) -and -not [string]::Equals([string]$Ctx.dshProfileInfo.dependencyValue, $preDep, [System.StringComparison]::Ordinal)) {
                    [void]$pcProblems.Add('DSH profile dependency value changed since the transaction started')
                }
            }
        }
    }
    if ($pcProblems.Count -gt 0) { Add-Check $checks 'verify.pathContract' 'FAIL' ((@($pcProblems)) -join '; ') }
    else { Add-Check $checks 'verify.pathContract' 'PASS' 'bundle package identity/dsh.bundle.patch correct; DSH profile reference unchanged' }
    # 9. user data preservation
    if ($null -ne $Txn) {
        $udProblems = New-Object System.Collections.ArrayList
        $preFps = Get-JsonPropertyValue $Txn 'preservedFingerprintsPre'
        if ($null -eq $preFps) { $preFps = Get-JsonPropertyValue $Txn 'preservedFingerprints' }
        if ($null -ne $preFps) {
            $venvNow = Get-TreeFingerprint -Root (Join-Path $root '.venv') -ExcludePrefixes @()
            $backupsNow = Get-TreeFingerprint -Root (Join-Path $root '_portable\backups') -ExcludePrefixes @()
            $venvPre = [string](Get-JsonPropertyValue $preFps '.venv')
            $backupsPre = [string](Get-JsonPropertyValue $preFps '_portable/backups')
            if (-not [string]::Equals($venvNow, $venvPre, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$udProblems.Add('.venv fingerprint changed since the transaction started') }
            if (-not [string]::Equals($backupsNow, $backupsPre, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$udProblems.Add('_portable/backups fingerprint changed since the transaction started') }
        } else {
            Add-Check $checks 'verify.userData' 'WARN' 'transaction has no preserved fingerprints (VENV_UNCHANGED NOT TESTED)'
            $udProblems = $null
        }
        if ($null -ne $udProblems) {
            if ($null -ne $Ctx.dshProfileInfo -and $Ctx.dshProfileInfo.outcome -eq 'MATCH' -and $null -ne $Txn.dshProfile) {
                $preProfileFp = [string](Get-JsonPropertyValue $Txn.dshProfile 'fingerprintBefore')
                if (-not [string]::IsNullOrEmpty($preProfileFp) -and -not [string]::Equals([string]$Ctx.dshProfileInfo.fingerprint, $preProfileFp, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$udProblems.Add('DSH profile fingerprint changed since the transaction started')
                }
            }
            if ($udProblems.Count -gt 0) { Add-Check $checks 'verify.userData' 'FAIL' ((@($udProblems)) -join '; ') }
            else { Add-Check $checks 'verify.userData' 'PASS' '.venv, installer backups and DSH profile fingerprints unchanged (preserved byte-for-byte)' }
        }
    } else {
        Add-Check $checks 'verify.userData' 'NOT TESTED' 'no transaction for this upgrade; incremental-preservation checks unavailable (DSH_PROFILE_UNCHANGED/VENV_UNCHANGED NOT TESTED)'
    }
    # 10. env metadata
    $envProblems = New-Object System.Collections.ArrayList
    $envWarns = New-Object System.Collections.ArrayList
    foreach ($decl in @($Ctx.envFiles)) {
        $rel = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $decl 'path'))
        $full = Join-Path $root (ConvertTo-FsPath $rel)
        $st = Read-EnvFileState $full
        if (-not $st.exists) { [void]$envWarns.Add("$rel absent; skipped"); continue }
        if (-not $st.parseOk) { [void]$envProblems.Add("$rel unreadable"); continue }
        if ([string]$st.distribution -ne $script:TargetVersion) { [void]$envWarns.Add("$rel reports distribution='$($st.distribution)' (expected $($script:TargetVersion))") }
    }
    if ($envProblems.Count -gt 0) { Add-Check $checks 'verify.envMetadata' 'FAIL' ((@($envProblems)) -join '; ') }
    elseif ($envWarns.Count -gt 0) { Add-Check $checks 'verify.envMetadata' 'WARN' ((@($envWarns)) -join '; ') }
    else { Add-Check $checks 'verify.envMetadata' 'PASS' 'environment files report the target distribution version' }
    # 11. package variant
    if ($frozenCore) {
        Add-Check $checks 'verify.packageVariant' 'WARN' 'FROZEN_RC3: the installed tree is an authentic frozen rc.3 core; the unified package would add 8 payload files (tools/setup.ps1, tools/lib/UpgradeCommon.ps1, tools/build_unified_release.ps1, tests/...) but no automatic refresh is offered - reinstall from the unified ZIP if those tools are needed'
    } elseif ($state -eq 'RC3_ALREADY_INSTALLED' -and $variant -eq 'UNIFIED') {
        Add-Check $checks 'verify.packageVariant' 'PASS' 'UNIFIED: the installed tree matches the unified package target (payload set + manifest.json)'
    } elseif ($state -eq 'NOT_INSTALLED') {
        Add-Check $checks 'verify.packageVariant' 'NOT TESTED' 'nothing is installed (NOT_INSTALLED)'
    } else {
        Add-Check $checks 'verify.packageVariant' 'NOT TESTED' ("verified against the unified package target; source state is $state")
    }
    # roll-up
    $failCount = 0
    foreach ($c in $checks) { if ([string]$c['status'] -eq 'FAIL') { $failCount++ } }
    $fileComplete = ($failCount -eq 0)
    return [pscustomobject]@{
        checks            = $checks
        fileUpgradeComplete = $fileComplete
        failCount         = $failCount
        variant           = $Ctx.rc3Variant
        payloadFileCount  = $expectedPayloadCount
        addedFileCount    = $(if ($null -ne $Ctx.packageData) { [int]$Ctx.addedFileCount } else { 0 })
    }
}


function Find-LatestCommittedTransaction {
    param($Ctx)
    if ($null -eq $Ctx.transactions) { return $null }
    foreach ($t in @($Ctx.transactions)) {
        if (-not $t.corrupt -and [string]$t.phase -eq 'COMMITTED') { return $t }
    }
    return $null
}

#endregion

#region ============================== STATUS =========================================

function New-StatusDocument {
    param($Ctx)
    $status = [ordered]@{}
    $root = [string]$Ctx.installRoot
    # installed distribution
    $im = Get-InstallManifestInfo $root
    $installed = [ordered]@{
        version             = [string]$Ctx.installVersionTrim
        manifestSha256      = [string]$im.sha256
        manifestParses      = [bool]$im.parseOk
        distributionVersion = [string]$Ctx.installManifestDistributionVersion
        bundleVersion       = $null
        fileCount           = 0
    }
    if ($im.parseOk) {
        $bundle = Get-JsonPropertyValue $im.json 'bundle'
        $installed.bundleVersion = [string](Get-JsonPropertyValue $bundle 'version')
        $installed.fileCount = @(Get-JsonPropertyValue $im.json 'files').Count
    }
    $status.installed = $installed
    # package (unified) identity
    $package = [ordered]@{
        root                = [string]$Ctx.packageRoot
        selfMode            = [bool]$Ctx.selfMode
        payloadRoot         = [string]$Ctx.payloadRoot
        manifestSha256      = ''
        metadataSha256      = ''
        sumsSha256          = ''
        payloadFileCount    = [int]$Ctx.targetPayloadFileCount
        sourcePayloadFileCount = [int]$Ctx.sourcePayloadFileCount
        addedFileCount      = [int]$Ctx.addedFileCount
        upgradeId           = $script:UpgradeId
        upgraderVersion     = $script:ToolVersion
    }
    if ($null -ne $Ctx.packageData) {
        $package.manifestSha256 = [string]$Ctx.packageData.manifestSha256
        $package.metadataSha256 = [string]$Ctx.packageData.metadataSha256
        $package.sumsSha256 = [string]$Ctx.packageData.sumsSha256
    }
    $status.package = $package
    # payload quick integrity
    $payload = [ordered]@{
        state         = [string]$Ctx.sourceState
        variant       = $Ctx.rc3Variant
        notInstalled  = [bool]$Ctx.notInstalled
        notInstalledReason = $Ctx.notInstalledReason
        sourceMatches = [int]$Ctx.sourceMatchCount
        targetMatches = [int]$Ctx.targetMatchCount
        conflicts     = @($Ctx.conflicts)
        reasons       = @($Ctx.reasons)
    }
    $status.payload = $payload
    # env metadata
    $envStatus = New-Object System.Collections.ArrayList
    foreach ($decl in @($Ctx.envFiles)) {
        $rel = ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $decl 'path'))
        $st = Read-EnvFileState (Join-Path $root (ConvertTo-FsPath $rel))
        [void]$envStatus.Add([ordered]@{ path = $rel; exists = $st.exists; parseOk = $st.parseOk; distribution = [string]$st.distribution })
    }
    $status.environmentFiles = $envStatus.ToArray()
    # dsh
    $dsh = [ordered]@{
        home          = [string]$Ctx.dshHome
        productionHome = Get-ProductionDshHome
        profile       = $null
        referenceOutcome = 'NOT_FOUND'
        junctionTarget = $null
        dshRunning    = $false
        isLiveTarget  = $false
        underDshProcess = $false
    }
    if ($null -ne $Ctx.dshProfileInfo) {
        $dsh.profile = $Ctx.dshProfileInfo.selectedName
        $dsh.referenceOutcome = $Ctx.dshProfileInfo.outcome
        $dsh.junctionTarget = $Ctx.dshProfileInfo.junctionTarget
        $dsh.matches = @($Ctx.dshProfileInfo.matches)
    }
    if ($null -ne $Ctx.dshPolicy) {
        $dsh.dshRunning = [bool]$Ctx.dshPolicy.dshRunning
        $dsh.isLiveTarget = [bool]$Ctx.dshPolicy.isLiveTarget
        $dsh.underDshProcess = [bool]$Ctx.dshPolicy.underDshProcess
    }
    $dsh.processes = @($Ctx.dshProcessTable)
    $status.dsh = $dsh
    # transactions
    $txnHistory = New-Object System.Collections.ArrayList
    foreach ($t in @($Ctx.transactions)) {
        [void]$txnHistory.Add([ordered]@{
            transactionId = $t.id
            phase         = $(if ($t.corrupt) { 'CORRUPT' } else { [string]$t.phase })
            upgradeId     = [string]$t.upgradeId
            startedAt     = [string]$t.startedAt
            updatedAt     = [string]$t.updatedAt
            committedAt   = [string]$t.committedAt
            corrupt       = [bool]$t.corrupt
            error         = [string]$t.error
        })
    }
    $status.transactions = $txnHistory.ToArray()
    $status.transactionRoot = $Ctx.transactionRoot
    # pending
    $pending = $null
    foreach ($t in @($Ctx.transactions)) {
        if ($t.corrupt) { $pending = [ordered]@{ transactionId = $t.id; corrupt = $true; guidance = 'transaction.json is corrupt; do not delete it - inspect and recover manually' }; break }
        if ($script:TerminalTransactionPhases -notcontains [string]$t.phase) {
            $pending = [ordered]@{ transactionId = $t.id; phase = [string]$t.phase; guidance = "a pending upgrade transaction exists; run '-Action rollback -Transaction $($t.id)' to restore the pre-upgrade state, or inspect $($t.transactionPath)" }
            break
        }
    }
    $status.pendingTransaction = $pending
    # last upgrade
    $last = $null
    foreach ($t in @($Ctx.transactions)) {
        if (-not $t.corrupt -and [string]$t.phase -eq 'COMMITTED') {
            $last = [ordered]@{ transactionId = $t.id; phase = [string]$t.phase; committedAt = [string]$t.committedAt; startedAt = [string]$t.startedAt; upgradeId = [string]$t.upgradeId }
            break
        }
    }
    $status.lastUpgrade = $last
    $status.preservedFingerprints = $Ctx.preservedFingerprints
    return $status
}


#endregion

#region ============================== transaction records ============================

function New-TransactionDocument {
    param([string]$TransactionId, [string]$TxnDir, $Plan, $Ctx)
    $now = (Get-Date).ToString('o')
    $txn = [ordered]@{
        schemaVersion       = $script:TransactionSchemaVersion
        tool                = $script:ToolName
        toolVersion         = $script:ToolVersion
        upgradeId           = $script:UpgradeId
        distributionId      = $script:DistributionId
        transactionId       = $TransactionId
        transactionDir      = $TxnDir
        installRoot         = [string]$Plan.installRoot
        packageRoot         = [string]$Plan.packageRoot
        payloadRoot         = [string]$Plan.payloadRoot
        sourceState         = [string]$Plan.sourceState
        sourceVersion       = [string]$Plan.sourceVersion
        targetVersion       = [string]$Plan.targetVersion
        hotfixedVariant     = [string]$Plan.hotfixedVariant
        sourceManifestSha256 = $script:SourceManifestHash
        targetManifestSha256 = [string]$Plan.packageManifestSha256
        metadataSha256      = [string]$Plan.metadataSha256
        planId              = [string]$Plan.materialSha256
        packageSumsSha256   = [string]$Plan.packageSumsSha256
        startedAt           = $now
        updatedAt           = $now
        phase               = 'PRECHECKED'
        committedAt         = $null
        restoredAt          = $null
        backupDir           = (Join-Path $TxnDir 'backup')
        stagingDir          = (Join-Path $TxnDir 'staging')
        evidenceDir         = (Join-Path $TxnDir 'evidence')
        backupVerified      = $false
        stagingVerified     = $false
        restoreVerified     = $false
        rollbackVerified    = $false
        rollbackRepeated    = $false
        failure             = $null
        manualRecovery      = @()
        preservedFingerprintsPre = $Ctx.preservedFingerprints
        preservedFingerprintsPost = $null
        dshProfile          = [ordered]@{
            name                = $null
            packageJsonSha256   = $null
            dependencyValue     = $null
            junctionTarget      = $null
            fingerprintBefore   = $null
            fingerprintAfter    = $null
        }
        verifySummary       = $null
        files               = @()
        envFiles            = @()
        newDirectories      = @()
        log                 = @()
    }
    if ($null -ne $Ctx.dshProfileInfo) {
        $txn.dshProfile.name = $Ctx.dshProfileInfo.selectedName
        $txn.dshProfile.packageJsonSha256 = $Ctx.dshProfileInfo.packageJsonSha256
        $txn.dshProfile.dependencyValue = $Ctx.dshProfileInfo.dependencyValue
        $txn.dshProfile.junctionTarget = $Ctx.dshProfileInfo.junctionTarget
        $txn.dshProfile.fingerprintBefore = $Ctx.dshProfileInfo.fingerprint
    }
    $files = New-Object System.Collections.ArrayList
    foreach ($cf in @($Plan.changedFiles)) {
        $p = [string]$cf['path']
        $operation = 'replace'
        if (-not [string]::IsNullOrEmpty([string]$cf['operation'])) { $operation = [string]$cf['operation'] }
        $target = Join-Path ([string]$Plan.installRoot) (ConvertTo-FsPath $p)
        $existed = Test-FileExists $target
        $pre = $null
        if ($existed) {
            try { $pre = Get-Sha256File $target } catch { $pre = 'UNREADABLE' }
        }
        [void]$files.Add([ordered]@{
            path               = $p
            operation          = $operation
            classification     = [string]$cf['classification']
            existed            = $existed
            existedExpected    = $(if ($operation -eq 'add') { $false } else { $true })
            sourceSha256       = [string]$cf['declaredSourceSha256']
            preApplySha256     = $pre
            targetSha256       = [string]$cf['targetSha256']
            targetBytes        = [long]$cf['targetBytes']
            backupSha256       = $null
            stagingSha256      = $null
            applied            = $false
            appliedAt          = $null
            restored           = $false
        })
    }
    $txn.files = $files.ToArray()
    $envFiles = New-Object System.Collections.ArrayList
    foreach ($e in @($Plan.environmentUpdates)) {
        [void]$envFiles.Add([ordered]@{
            path               = [string]$e['path']
            format             = [string]$e['format']
            existed            = [bool]$e['exists']
            preApplySha256     = [string]$e['beforeSha256']
            postApplySha256    = $null
            backupSha256       = $null
            applied            = $false
            appliedAt          = $null
            skipped            = [bool]$e['skipped']
            skipReason         = [string]$e['skipReason']
            afterFormat        = [string]$e['afterFormat']
            restored           = $false
        })
    }
    $txn.envFiles = $envFiles.ToArray()
    $newDirs = New-Object System.Collections.ArrayList
    foreach ($d in @($Plan.createDirectories)) {
        [void]$newDirs.Add([ordered]@{ path = [string]$d; created = $false; removed = $false })
    }
    $txn.newDirectories = $newDirs.ToArray()
    return $txn
}


function Save-TransactionRecord {
    param($Txn, [string]$TxnDir)
    $Txn.updatedAt = (Get-Date).ToString('o')
    $path = Join-Path $TxnDir 'transaction.json'
    Write-JsonAtomic -Path $path -Value $Txn | Out-Null
}

function Add-TransactionLog {
    param($Txn, [string]$TxnDir, [string]$Message)
    $line = (Get-Date).ToString('o') + ' ' + $Message
    $log = New-Object System.Collections.ArrayList
    foreach ($l in @($Txn.log)) { [void]$log.Add($l) }
    [void]$log.Add($line)
    $Txn.log = $log.ToArray()
    try {
        $evidenceDir = Join-Path $TxnDir 'evidence'
        if (-not (Test-DirExists $evidenceDir)) { [void][System.IO.Directory]::CreateDirectory((Get-IoPath $evidenceDir)) }
        $logPath = Join-Path $evidenceDir 'apply.log'
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText((Get-IoPath $logPath), $line + "`n", $enc)
    } catch { }
}

function Find-TransactionFileRecord {
    param($Txn, [string]$Path)
    if ($null -eq $Txn) { return $null }
    foreach ($r in @($Txn.files)) { if ([string]$r['path'] -ieq $Path) { return $r } }
    return $null
}

function Find-TransactionEnvRecord {
    param($Txn, [string]$Path)
    if ($null -eq $Txn) { return $null }
    foreach ($r in @($Txn.envFiles)) { if ([string]$r['path'] -ieq $Path) { return $r } }
    return $null
}

function Get-TransactionPayloadPaths {
    param($Txn)
    $out = New-Object System.Collections.ArrayList
    foreach ($r in @($Txn.files)) { [void]$out.Add([string]$r['path']) }
    return $out.ToArray()
}

function Get-RestoreOrderForTransaction {
    # Rollback restore order = reverse of apply order: env files (reverse ordinal), then
    # payload: VERSION, manifest.json, remaining payload files (reverse ordinal).
    param($Txn)
    $paths = @(Get-TransactionPayloadPaths $Txn)
    $present = @{}
    foreach ($p in $paths) { $present[$p.ToLowerInvariant()] = $p }
    $others = New-Object System.Collections.ArrayList
    foreach ($p in $paths) { if ($p -ieq 'VERSION' -or $p -ieq 'manifest.json') { continue }; [void]$others.Add($p) }
    $sortedOthers = @(Sort-Ordinal $others.ToArray())
    $payloadOrder = New-Object System.Collections.ArrayList
    if ($present.ContainsKey('version')) { [void]$payloadOrder.Add($present['version']) }
    if ($present.ContainsKey('manifest.json')) { [void]$payloadOrder.Add($present['manifest.json']) }
    for ($i = $sortedOthers.Length - 1; $i -ge 0; $i--) { [void]$payloadOrder.Add($sortedOthers[$i]) }
    $envOrder = New-Object System.Collections.ArrayList
    $envPaths = New-Object System.Collections.ArrayList
    foreach ($r in @($Txn.envFiles)) { [void]$envPaths.Add([string]$r['path']) }
    $sortedEnv = @(Sort-Ordinal $envPaths.ToArray())
    for ($i = $sortedEnv.Length - 1; $i -ge 0; $i--) { [void]$envOrder.Add($sortedEnv[$i]) }
    return [ordered]@{ env = $envOrder.ToArray(); payload = $payloadOrder.ToArray() }
}

#endregion

#region ============================== atomic file writes / restore ===================

function Write-FileAtomicFromSource {
    # Copies $Source to $Target through a transaction-scoped temp file + File.Replace/Move.
    param([string]$Source, [string]$Target, [string]$TransactionId, [string]$ExpectedSha256)
    if (-not (Test-FileExists $Source)) { throw "source file not found: $Source" }
    if ((Get-FileLengthSafe $Source) -lt 0) { throw "source file is unreadable: $Source" }
    $targetFull = Get-NormalizedFullPath $Target
    $targetDir = [System.IO.Path]::GetDirectoryName($targetFull)
    if ([string]::IsNullOrEmpty($targetDir)) { throw "target has no parent directory: $Target" }
    if (-not (Test-DirExists $targetDir)) { throw "target directory does not exist: $targetDir" }
    $leaf = [System.IO.Path]::GetFileName($targetFull)
    $tmp = Join-Path $targetDir ($leaf + '.upgrade-' + $TransactionId + '.tmp')
    if (Test-FileExists $tmp) { Remove-FileExact $tmp }
    $srcSha = Get-Sha256File $Source
    if (-not [string]::IsNullOrEmpty($ExpectedSha256) -and
        -not [string]::Equals($srcSha, $ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "staged file hash mismatch for '$Source': $srcSha != $ExpectedSha256"
    }
    [System.IO.File]::Copy((Get-IoPath $Source), (Get-IoPath $tmp), $false)
    $tmpSha = Get-Sha256File $tmp
    if (-not [string]::Equals($tmpSha, $srcSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-FileExact $tmp
        throw "temp copy verification failed: $tmp"
    }
    if (Test-FileExists $targetFull) {
        $attr = Get-FileAttributesSafe $targetFull
        if ($null -ne $attr -and (($attr -band [System.IO.FileAttributes]::ReadOnly) -ne 0)) {
            Remove-FileExact $tmp
            throw "TARGET_FILE_READONLY: refusing to replace a file with the ReadOnly attribute set: $targetFull"
        }
        [System.IO.File]::Replace((Get-IoPath $tmp), (Get-IoPath $targetFull), [System.Management.Automation.Language.NullString]::Value)
    } else {
        [System.IO.File]::Move((Get-IoPath $tmp), (Get-IoPath $targetFull))
    }
    $finalSha = Get-Sha256File $targetFull
    if (-not [string]::Equals($finalSha, $srcSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "post-write verification failed for '$targetFull': $finalSha != $srcSha"
    }
    return $finalSha
}

function Restore-TransactionFileRecord {
    # Restores one payload/env record from the transaction backup (existed=true), or
    # deletes an operation="add" file (existed=false) ONLY when its current bytes equal the
    # applied target hash. Returns $null on success, or an error string on failure.
    param($Record, [string]$TxnDir, [string]$InstallRoot, [string]$TransactionId)
    $rel = [string]$Record['path']
    $target = Join-Path $InstallRoot (ConvertTo-FsPath $rel)
    try {
        if ([bool]$Record['existed']) {
            $backup = Join-Path (Join-Path $TxnDir 'backup') (ConvertTo-FsPath $rel)
            if (-not (Test-FileExists $backup)) { return "backup file missing: $backup" }
            $backupSha = Get-Sha256File $backup
            $preSha = [string]$Record['preApplySha256']
            if (-not [string]::Equals($backupSha, $preSha, [System.StringComparison]::OrdinalIgnoreCase)) {
                return "backup hash mismatch for '$rel': $backupSha != $preSha"
            }
            if (-not (Test-FileExists $target)) {
                $targetDir = [System.IO.Path]::GetDirectoryName($target)
                if ($targetDir -and -not (Test-DirExists $targetDir)) { [void][System.IO.Directory]::CreateDirectory((Get-IoPath $targetDir)) }
            }
            [void](Write-FileAtomicFromSource -Source $backup -Target $target -TransactionId $TransactionId -ExpectedSha256 $preSha)
            $Record['restored'] = $true
            return $null
        } else {
            if (-not (Test-FileExists $target)) {
                $Record['restored'] = $true
                return $null
            }
            $current = ''
            try { $current = Get-Sha256File $target } catch { return "added file is unreadable (not deleting): $rel" }
            $targetSha = [string]$Record['targetSha256']
            if (-not [string]::Equals($current, $targetSha, [System.StringComparison]::OrdinalIgnoreCase)) {
                return ("ADDED_FILE_MODIFIED_ON_RESTORE: '$rel' was modified after APPLY; refusing to delete user-modified content")
            }
            [System.IO.File]::Delete((Get-IoPath $target))
            $Record['restored'] = $true
            return $null
        }
    } catch {
        return $_.Exception.Message
    }
}


function New-ManualRecoveryCommands {
    param($Txn, [string]$TxnDir)
    $lines = New-Object System.Collections.ArrayList
    foreach ($r in @($Txn.files)) {
        if ([bool]$r['existed']) {
            $backup = Join-Path (Join-Path $TxnDir 'backup') (ConvertTo-FsPath ([string]$r['path']))
            $target = Join-Path ([string]$Txn.installRoot) (ConvertTo-FsPath ([string]$r['path']))
            [void]$lines.Add("Copy-Item -LiteralPath '$backup' -Destination '$target' -Force")
        } else {
            $target = Join-Path ([string]$Txn.installRoot) (ConvertTo-FsPath ([string]$r['path']))
            [void]$lines.Add("Remove-Item -LiteralPath '$target' -Force -ErrorAction SilentlyContinue")
        }
    }
    foreach ($r in @($Txn.envFiles)) {
        if (-not [bool]$r['existed']) { continue }
        $backup = Join-Path (Join-Path $TxnDir 'backup') (ConvertTo-FsPath ([string]$r['path']))
        $target = Join-Path ([string]$Txn.installRoot) (ConvertTo-FsPath ([string]$r['path']))
        [void]$lines.Add("Copy-Item -LiteralPath '$backup' -Destination '$target' -Force")
    }
    foreach ($d in @($Txn.newDirectories)) {
        if ($null -eq $d) { continue }
        if ([string]::IsNullOrEmpty([string]$d['path'])) { continue }
        $full = Join-Path ([string]$Txn.installRoot) (ConvertTo-FsPath ([string]$d['path']))
        [void]$lines.Add("[System.IO.Directory]::Delete('$full', `$false)")
    }
    return $lines.ToArray()
}


#endregion

#region ============================== environment file apply helpers ================

function Resolve-EnvDeclaredValue {
    param($Value)
    if ($Value -is [string]) {
        if ($Value -eq '<now>' -or $Value -eq '$now') { return (Get-Date).ToString('o') }
    }
    return $Value
}

function Get-EnvAddFieldDeclarations {
    param($Decl)
    $out = New-Object System.Collections.ArrayList
    $rawAdds = Get-JsonPropertyValue $Decl 'addFields'
    if ($null -eq $rawAdds) { return $out.ToArray() }
    $addsArray = @($rawAdds)
    $objectForm = $false
    if ($addsArray.Count -eq 1 -and $null -ne $addsArray[0] -and $addsArray[0] -isnot [string] -and
        $null -eq $addsArray[0].PSObject.Properties['jsonPath']) {
        $objectForm = $true
    }
    if ($objectForm) {
        foreach ($prop in $addsArray[0].PSObject.Properties) {
            [void]$out.Add([ordered]@{ jsonPath = [string]$prop.Name; value = $prop.Value })
        }
    } else {
        foreach ($a in $addsArray) {
            if ($null -eq $a -or $a -is [string]) { continue }
            [void]$out.Add([ordered]@{ jsonPath = [string](Get-JsonPropertyValue $a 'jsonPath'); value = (Get-JsonPropertyValue $a 'value') })
        }
    }
    return $out.ToArray()
}

function New-EnvFileContentBytes {
    # Declarative JSON merge for one environment file (ENGINE_SPEC 7.6). Throws on precondition failure.
    param($Decl, [string]$CurrentPath, [string]$RelPath)
    $raw = Read-TextFileUtf8 $CurrentPath
    $obj = Read-JsonFromText $raw $CurrentPath
    $updates = @(Get-JsonPropertyValue $Decl 'updates')
    foreach ($u in $updates) {
        $jp = [string](Get-JsonPropertyValue $u 'jsonPath')
        if ([string]::IsNullOrEmpty($jp)) { throw "ENV_DECLARATION_INVALID: update without jsonPath in $RelPath" }
        $expectedBefore = Get-JsonPropertyValue $u 'expectedBefore'
        if ($null -ne $expectedBefore) {
            if (-not (Test-JsonPathExists $obj $jp)) { throw "ENV_PRECONDITION: '$jp' is missing in $RelPath" }
            $actual = Get-JsonPathValue $obj $jp
            if (-not [string]::Equals([string]$actual, [string]$expectedBefore, [System.StringComparison]::Ordinal)) {
                throw "ENV_PRECONDITION: $RelPath '$jp' is '$actual', expected '$expectedBefore'"
            }
        }
        $value = Resolve-EnvDeclaredValue (Get-JsonPropertyValue $u 'value')
        Set-JsonPathValue $obj $jp $value
    }
    foreach ($a in @(Get-EnvAddFieldDeclarations $Decl)) {
        $jp = [string]$a['jsonPath']
        if ([string]::IsNullOrEmpty($jp)) { throw "ENV_DECLARATION_INVALID: addField without jsonPath in $RelPath" }
        $value = Resolve-EnvDeclaredValue $a['value']
        Set-JsonPathValue $obj $jp $value
    }
    $json = ConvertTo-StableJson $obj
    return (Get-Utf8NoBomBytes $json)
}

function Test-EnvFileFieldsAfterApply {
    param($Decl, [string]$Path, [string]$RelPath)
    $obj = Read-JsonDocument $Path
    $updates = @(Get-JsonPropertyValue $Decl 'updates')
    foreach ($u in $updates) {
        $jp = [string](Get-JsonPropertyValue $u 'jsonPath')
        $expected = Resolve-EnvDeclaredValue (Get-JsonPropertyValue $u 'value')
        if (-not (Test-JsonPathExists $obj $jp)) { throw "ENV_VERIFY_FAILED: '$jp' missing after update in $RelPath" }
        $actual = Get-JsonPathValue $obj $jp
        if (-not [string]::Equals([string]$actual, [string]$expected, [System.StringComparison]::Ordinal)) {
            throw "ENV_VERIFY_FAILED: '$jp' is '$actual', expected '$expected' in $RelPath"
        }
    }
    foreach ($a in @(Get-EnvAddFieldDeclarations $Decl)) {
        $jp = [string]$a['jsonPath']
        if (-not (Test-JsonPathExists $obj $jp)) { throw "ENV_VERIFY_FAILED: added field '$jp' missing in $RelPath" }
    }
}

function Find-EnvDeclaration {
    param($Ctx, [string]$RelPath)
    foreach ($decl in @($Ctx.envFiles)) {
        if ((ConvertTo-ManifestPath ([string](Get-JsonPropertyValue $decl 'path'))) -ieq $RelPath) { return $decl }
    }
    return $null
}

function Get-PreservedFingerprintSnapshot {
    param([string]$InstallRoot, $ProfInfo)
    $fps = [ordered]@{}
    $fps['.venv'] = Get-TreeFingerprint -Root (Join-Path $InstallRoot '.venv') -ExcludePrefixes @()
    $fps['_portable/backups'] = Get-TreeFingerprint -Root (Join-Path $InstallRoot '_portable\backups') -ExcludePrefixes @()
    $fps['_portable'] = Get-TreeFingerprint -Root (Join-Path $InstallRoot '_portable') -ExcludePrefixes @('upgrades')
    if ($null -ne $ProfInfo) { $fps['dshProfile'] = $ProfInfo.fingerprint } else { $fps['dshProfile'] = 'ABSENT' }
    return $fps
}

#endregion

#region ============================== APPLY transaction ==============================

function Invoke-AutoRestore {
    # Restores every applied record inside APPLY on failure: replaced files from the
    # per-file backup; operation="add" files are deleted only when their current bytes
    # equal the applied target hash (never user-modified content). Transaction-created
    # directories are removed afterwards, deepest-first, empty-only.
    param($Txn, [string]$TxnDir, [string]$InstallRoot)
    $failures = New-Object System.Collections.ArrayList
    $order = Get-RestoreOrderForTransaction $Txn
    $envByPath = @{}
    foreach ($r in @($Txn.envFiles)) { $envByPath[([string]$r['path']).ToLowerInvariant()] = $r }
    $fileByPath = @{}
    foreach ($r in @($Txn.files)) { $fileByPath[([string]$r['path']).ToLowerInvariant()] = $r }
    foreach ($rel in @($order.env)) {
        $rec = $envByPath[$rel.ToLowerInvariant()]
        if ($null -eq $rec -or -not [bool]$rec['applied']) { continue }
        $err = Restore-TransactionFileRecord -Record $rec -TxnDir $TxnDir -InstallRoot $InstallRoot -TransactionId $Txn.transactionId
        if ($null -ne $err) { [void]$failures.Add("env $rel`: $err") }
    }
    foreach ($rel in @($order.payload)) {
        $rec = $fileByPath[$rel.ToLowerInvariant()]
        if ($null -eq $rec -or -not [bool]$rec['applied']) { continue }
        $err = Restore-TransactionFileRecord -Record $rec -TxnDir $TxnDir -InstallRoot $InstallRoot -TransactionId $Txn.transactionId
        if ($null -ne $err) { [void]$failures.Add("file $rel`: $err") }
    }
    # remove transaction-created directories (exact paths, empty-only, non-recursive)
    $dirResult = Remove-CreatedDirectories -Txn $Txn -InstallRoot $InstallRoot
    foreach ($df in @($dirResult.failures)) { [void]$failures.Add("dir: $df") }
    # clean up exact per-file temp leftovers
    foreach ($r in @($Txn.files) + @($Txn.envFiles)) {
        if (-not [bool]$r['applied']) { continue }
        $target = Join-Path $InstallRoot (ConvertTo-FsPath ([string]$r['path']))
        $dir = [System.IO.Path]::GetDirectoryName($target)
        if ([string]::IsNullOrEmpty($dir)) { continue }
        $tmp = Join-Path $dir ([System.IO.Path]::GetFileName($target) + '.upgrade-' + $Txn.transactionId + '.tmp')
        if (Test-FileExists $tmp) { Remove-FileExact $tmp }
    }
    # verify restore against pre-apply state
    if ($failures.Count -eq 0) {
        foreach ($r in @($Txn.files)) {
            if (-not [bool]$r['applied']) { continue }
            $target = Join-Path $InstallRoot (ConvertTo-FsPath ([string]$r['path']))
            if ([bool]$r['existed']) {
                try {
                    $sha = Get-Sha256File $target
                    if (-not [string]::Equals($sha, [string]$r['preApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                        [void]$failures.Add("restored hash mismatch for '$($r['path'])'")
                    }
                } catch { [void]$failures.Add("restored file unreadable: $($r['path'])") }
            } else {
                if (Test-FileExists $target) { [void]$failures.Add("added file still present after restore: $($r['path'])") }
            }
        }
        foreach ($r in @($Txn.envFiles)) {
            if (-not [bool]$r['applied']) { continue }
            $target = Join-Path $InstallRoot (ConvertTo-FsPath ([string]$r['path']))
            try {
                $sha = Get-Sha256File $target
                if (-not [string]::Equals($sha, [string]$r['preApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$failures.Add("restored env hash mismatch for '$($r['path'])'")
                }
            } catch { [void]$failures.Add("restored env file unreadable: $($r['path'])") }
        }
    }
    if ($failures.Count -eq 0) {
        $Txn.phase = 'FAILED_RESTORED'
        $Txn.restoreVerified = $true
        $Txn.restoredAt = (Get-Date).ToString('o')
        return [pscustomobject]@{ restored = $true; failures = @(); manualRecovery = @() }
    }
    $Txn.phase = 'FAILED_MANUAL'
    $Txn.restoreVerified = $false
    $manual = @(New-ManualRecoveryCommands -Txn $Txn -TxnDir $TxnDir)
    $Txn.manualRecovery = $manual
    return [pscustomobject]@{ restored = $false; failures = $failures.ToArray(); manualRecovery = $manual }
}


function Invoke-ApplyTransaction {
    # Full transaction: PRECHECKED -> BACKED_UP -> STAGED -> APPLYING -> APPLIED -> VERIFIED -> COMMITTED.
    # v2: target bytes are read from <PackageRoot>\<payloadRoot>\<rel> (no payload/ copy);
    # operation="add" records are absent pre-upgrade (no backup copy) and are created with
    # engine-made parent directories recorded in the transaction before creation.
    param($Ctx, $PlanResult, $Options, $FaultModel)
    $plan = $PlanResult.plan
    $planId = [string]$PlanResult.planId
    $root = [string]$Ctx.installRoot
    $packageRoot = [string]$Ctx.packageRoot
    $payloadRoot = [string]$Ctx.payloadRoot
    $targetRoot = Join-Path $packageRoot (ConvertTo-FsPath $payloadRoot)
    $backupRoot = [string]$PlanResult.backupRoot
    if (-not (Test-PathUnder $backupRoot $root)) {
        return [pscustomobject]@{ success = $false; preflightError = "BACKUP_ROOT_OUTSIDE_INSTALL_ROOT: $backupRoot"; txn = $null; txnDir = $null }
    }
    # exclusive transaction directory (never overwrite)
    $txnId = $null
    $txnDir = $null
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $candidate = New-TransactionId
        $candidateDir = Join-Path $backupRoot $candidate
        if (-not (Test-DirExists $candidateDir) -and -not (Test-FileExists $candidateDir)) {
            $txnId = $candidate
            $txnDir = $candidateDir
            break
        }
    }
    if ($null -eq $txnId) {
        return [pscustomobject]@{ success = $false; preflightError = 'TRANSACTION_ID_COLLISION: could not allocate an exclusive transaction directory'; txn = $null; txnDir = $null }
    }
    try {
        [void][System.IO.Directory]::CreateDirectory((Get-IoPath (Join-Path $txnDir 'backup')))
        [void][System.IO.Directory]::CreateDirectory((Get-IoPath (Join-Path $txnDir 'staging')))
        [void][System.IO.Directory]::CreateDirectory((Get-IoPath (Join-Path $txnDir 'evidence')))
    } catch {
        return [pscustomobject]@{ success = $false; preflightError = "TRANSACTION_DIR_CREATE_FAILED: $($_.Exception.Message)"; txn = $null; txnDir = $null }
    }
    $txn = New-TransactionDocument -TransactionId $txnId -TxnDir $txnDir -Plan $plan -Ctx $Ctx
    Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("apply start planId=" + $planId + " state=" + $plan.sourceState + " txn=" + $txnId)
    Save-TransactionRecord -Txn $txn -TxnDir $txnDir
    $writesStarted = $false
    $stageName = 'pre-write'
    try {
        # ---------- backup phase ----------
        $stageName = 'backup'
        $faultBackupIdx = Get-FaultIndex $FaultModel 'FAIL_BACKUP'
        $idx = 0
        foreach ($rec in @($txn.files)) {
            $idx++
            if ($faultBackupIdx -eq $idx) { throw "FAULT_FAIL_BACKUP:$idx" }
            $operation = [string]$rec['operation']
            $target = Join-Path $root (ConvertTo-FsPath ([string]$rec['path']))
            $existed = Test-FileExists $target
            if ($operation -eq 'add') {
                if ($existed) { throw ("ADD_TARGET_PRESENT: operation=add target already exists: " + [string]$rec['path']) }
                $rec['existed'] = $false
                $rec['preApplySha256'] = $null
                $rec['backupSha256'] = $null
                Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("backup add-file (absent) " + [string]$rec['path'])
                continue
            }
            if (-not $existed) { throw ("payload file disappeared before backup: " + [string]$rec['path']) }
            $rec['existed'] = $true
            $pre = Get-Sha256File $target
            $rec['preApplySha256'] = $pre
            $backupFile = Join-Path (Join-Path $txnDir 'backup') (ConvertTo-FsPath ([string]$rec['path']))
            $rec['backupSha256'] = Copy-FileVerified -Source $target -Destination $backupFile
            Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("backup " + [string]$rec['path'] + " sha=" + $pre)
        }
        foreach ($rec in @($txn.envFiles)) {
            if (-not [bool]$rec['existed']) { continue }
            $idx++
            if ($faultBackupIdx -eq $idx) { throw "FAULT_FAIL_BACKUP:$idx" }
            $target = Join-Path $root (ConvertTo-FsPath ([string]$rec['path']))
            $pre = Get-Sha256File $target
            $rec['preApplySha256'] = $pre
            $backupFile = Join-Path (Join-Path $txnDir 'backup') (ConvertTo-FsPath ([string]$rec['path']))
            $rec['backupSha256'] = Copy-FileVerified -Source $target -Destination $backupFile
            Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("backup env " + [string]$rec['path'] + " sha=" + $pre)
        }
        # verify backups
        foreach ($rec in @($txn.files)) {
            if (-not [bool]$rec['existed']) { continue }
            $backupFile = Join-Path (Join-Path $txnDir 'backup') (ConvertTo-FsPath ([string]$rec['path']))
            $sha = Get-Sha256File $backupFile
            if (-not [string]::Equals($sha, [string]$rec['backupSha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "backup verification failed for '$($rec['path'])'"
            }
            if (-not [string]::Equals($sha, [string]$rec['preApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "backup does not match the pre-apply bytes for '$($rec['path'])'"
            }
        }
        foreach ($rec in @($txn.envFiles)) {
            if (-not [bool]$rec['existed']) { continue }
            $backupFile = Join-Path (Join-Path $txnDir 'backup') (ConvertTo-FsPath ([string]$rec['path']))
            $sha = Get-Sha256File $backupFile
            if (-not [string]::Equals($sha, [string]$rec['backupSha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "env backup verification failed for '$($rec['path'])'"
            }
        }
        $txn.backupVerified = $true
        $txn.phase = 'BACKED_UP'
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'backup verified; phase=BACKED_UP'
        if (Test-FaultPresent $FaultModel 'CRASH_AFTER_BACKUP') {
            Save-TransactionRecord -Txn $txn -TxnDir $txnDir
            Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'FAULT CRASH_AFTER_BACKUP: hard exit without auto-restore'
            [System.Environment]::Exit(71)
        }

        # ---------- staging phase ----------
        $stageName = 'staging'
        $faultStageIdx = Get-FaultIndex $FaultModel 'FAIL_STAGE_HASH'
        $idx = 0
        foreach ($rec in @($txn.files)) {
            $idx++
            if ($faultStageIdx -eq $idx) { throw "FAULT_FAIL_STAGE_HASH:$idx" }
            $rel = [string]$rec['path']
            $src = Join-Path $targetRoot (ConvertTo-FsPath $rel)
            if (-not (Test-FileExists $src)) { throw "staged payload file missing in package: $rel" }
            $dst = Join-Path (Join-Path $txnDir 'staging') (ConvertTo-FsPath $rel)
            $sha = Copy-FileVerified -Source $src -Destination $dst
            if (-not [string]::Equals($sha, [string]$rec['targetSha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "staged payload hash does not match expected target for '$rel'"
            }
            $rec['stagingSha256'] = $sha
        }
        foreach ($rec in @($txn.envFiles)) {
            if (-not [bool]$rec['existed']) { continue }
            $rel = [string]$rec['path']
            $decl = Find-EnvDeclaration -Ctx $Ctx -RelPath $rel
            if ($null -eq $decl) { throw "environment file declaration disappeared from the manifest: $rel" }
            $current = Join-Path $root (ConvertTo-FsPath $rel)
            $bytes = New-EnvFileContentBytes -Decl $decl -CurrentPath $current -RelPath $rel
            $dst = Join-Path (Join-Path $txnDir 'staging') (ConvertTo-FsPath $rel)
            $dstDir = [System.IO.Path]::GetDirectoryName($dst)
            if ($dstDir -and -not (Test-DirExists $dstDir)) { [void][System.IO.Directory]::CreateDirectory((Get-IoPath $dstDir)) }
            [System.IO.File]::WriteAllBytes((Get-IoPath $dst), $bytes)
            $sha = Get-Sha256File $dst
            $rec['postApplySha256'] = $sha
            Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("staged env " + $rel + " new sha=" + $sha)
        }
        # staging verification
        foreach ($rec in @($txn.files)) {
            $dst = Join-Path (Join-Path $txnDir 'staging') (ConvertTo-FsPath ([string]$rec['path']))
            $sha = Get-Sha256File $dst
            if (-not [string]::Equals($sha, [string]$rec['stagingSha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "staging verification failed for '$($rec['path'])'"
            }
        }
        foreach ($rec in @($txn.envFiles)) {
            if (-not [bool]$rec['existed']) { continue }
            $dst = Join-Path (Join-Path $txnDir 'staging') (ConvertTo-FsPath ([string]$rec['path']))
            $sha = Get-Sha256File $dst
            if (-not [string]::Equals($sha, [string]$rec['postApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "env staging verification failed for '$($rec['path'])'"
            }
        }
        $txn.stagingVerified = $true
        $txn.phase = 'STAGED'
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'staging verified; phase=STAGED'

        # ---------- apply payload phase (version markers last) ----------
        $stageName = 'apply-payload'
        $txn.phase = 'APPLYING'
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'phase=APPLYING'
        $writesStarted = $true
        $applyOrder = @(Get-PayloadApplyOrder $Ctx)
        $faultApplyIdx = Get-FaultIndex $FaultModel 'FAIL_APPLY_INDEX'
        $faultCrashAfter = Get-FaultIndex $FaultModel 'CRASH_AFTER_APPLY'
        $appliedCount = 0
        foreach ($rel in $applyOrder) {
            $appliedCount++
            if ($faultApplyIdx -eq $appliedCount) { throw "FAULT_FAIL_APPLY_INDEX:$appliedCount" }
            $rec = Find-TransactionFileRecord -Txn $txn -Path $rel
            if ($null -eq $rec) { throw "transaction record missing for '$rel'" }
            $target = Join-Path $root (ConvertTo-FsPath $rel)
            if ([string]$rec['operation'] -eq 'add') {
                if (Test-FileExists $target) { throw "ADD_TARGET_APPEARED: '$rel' appeared after PLAN checked the source state" }
                $dirResult = Ensure-TargetDirectories -Txn $txn -TxnDir $txnDir -InstallRoot $root -RelativeFilePath $rel
                if (@($dirResult.failures).Count -gt 0) { throw ("TARGET_DIRECTORY_CREATE_FAILED: " + ((@($dirResult.failures)) -join '; ')) }
                if (Test-FileExists $target) { throw "ADD_TARGET_APPEARED: '$rel' appeared while preparing the transaction" }
            } else {
                $attr = Get-FileAttributesSafe $target
                if ($null -ne $attr -and (($attr -band [System.IO.FileAttributes]::ReadOnly) -ne 0)) {
                    throw "TARGET_FILE_READONLY: cannot replace '$rel' (ReadOnly attribute is set)"
                }
            }
            $staged = Join-Path (Join-Path $txnDir 'staging') (ConvertTo-FsPath $rel)
            [void](Write-FileAtomicFromSource -Source $staged -Target $target -TransactionId $txnId -ExpectedSha256 ([string]$rec['targetSha256']))
            $rec['applied'] = $true
            $rec['appliedAt'] = (Get-Date).ToString('o')
            Save-TransactionRecord -Txn $txn -TxnDir $txnDir
            Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("applied " + $rel)
            if ($faultCrashAfter -eq $appliedCount) {
                Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("FAULT CRASH_AFTER_APPLY:" + $appliedCount + ": hard exit without auto-restore")
                [System.Environment]::Exit(70)
            }
        }
        # full target-state verification (routine from section 8) before phase APPLIED
        $preVerify = Get-TargetVerifyChecks -Ctx $Ctx -Txn $txn
        if (-not $preVerify.fileUpgradeComplete) {
            $failedIds = New-Object System.Collections.ArrayList
            foreach ($c in @($preVerify.checks)) { if ([string]$c['status'] -eq 'FAIL') { [void]$failedIds.Add([string]$c['id']) } }
            throw ("PAYLOAD_VERIFY_FAILED: " + ((@($failedIds)) -join ','))
        }
        $txn.phase = 'APPLIED'
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'payload target state verified; phase=APPLIED'

        # ---------- environment file updates ----------
        $stageName = 'apply-env'
        if (Test-FaultPresent $FaultModel 'FAIL_ENV_UPDATE') { throw 'FAULT_FAIL_ENV_UPDATE' }
        foreach ($rec in @($txn.envFiles)) {
            if ([bool]$rec['skipped']) { continue }
            if (-not [bool]$rec['existed']) { continue }
            $rel = [string]$rec['path']
            $target = Join-Path $root (ConvertTo-FsPath $rel)
            $staged = Join-Path (Join-Path $txnDir 'staging') (ConvertTo-FsPath $rel)
            [void](Write-FileAtomicFromSource -Source $staged -Target $target -TransactionId $txnId -ExpectedSha256 ([string]$rec['postApplySha256']))
            $decl = Find-EnvDeclaration -Ctx $Ctx -RelPath $rel
            if ($null -ne $decl) { Test-EnvFileFieldsAfterApply -Decl $decl -Path $target -RelPath $rel }
            $rec['applied'] = $true
            $rec['appliedAt'] = (Get-Date).ToString('o')
            Save-TransactionRecord -Txn $txn -TxnDir $txnDir
            Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("applied env " + $rel)
        }
        $txn.phase = 'VERIFIED'
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'phase=VERIFIED'

        # ---------- final verification ----------
        if (Test-FaultPresent $FaultModel 'FAIL_VERIFY') { throw 'FAULT_FAIL_VERIFY' }
        $verify = Get-TargetVerifyChecks -Ctx $Ctx -Txn $txn
        if (-not $verify.fileUpgradeComplete) {
            $failedIds = New-Object System.Collections.ArrayList
            foreach ($c in @($verify.checks)) { if ([string]$c['status'] -eq 'FAIL') { [void]$failedIds.Add([string]$c['id']) } }
            throw ("FINAL_VERIFY_FAILED: " + ((@($failedIds)) -join ','))
        }
        # post fingerprints (prove nothing outside the write scope changed)
        $txn.preservedFingerprintsPost = Get-PreservedFingerprintSnapshot -InstallRoot $root -ProfInfo $Ctx.dshProfileInfo
        if ($null -ne $Ctx.dshProfileInfo) { $txn.dshProfile.fingerprintAfter = $Ctx.dshProfileInfo.fingerprint }
        $verifySummary = Get-CheckSummary $verify.checks
        $verifySummary.refused = $false
        $verifySummary.outcome = 'FILE_UPGRADE_COMPLETE'
        $txn.verifySummary = $verifySummary
        $txn.phase = 'COMMITTED'
        $txn.committedAt = (Get-Date).ToString('o')
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'verify PASS; phase=COMMITTED'
        return [pscustomobject]@{
            success          = $true
            preflightError   = $null
            txn              = $txn
            txnDir           = $txnDir
            verify           = $verify
            appliedFileCount = $appliedCount
            manualRecovery   = @()
        }
    } catch {
        $errMessage = $_.Exception.Message
        Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("FAILURE (" + $stageName + "): " + $errMessage)
        $txn.failure = [ordered]@{ stage = $stageName; message = $errMessage; at = (Get-Date).ToString('o') }
        if ($writesStarted) {
            $restore = Invoke-AutoRestore -Txn $txn -TxnDir $txnDir -InstallRoot $root
            $txn.failure = [ordered]@{
                stage           = $stageName
                message         = $errMessage
                at              = (Get-Date).ToString('o')
                autoRestored    = [bool]$restore.restored
                restoreFailures = @($restore.failures)
            }
            Save-TransactionRecord -Txn $txn -TxnDir $txnDir
            Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("auto-restore: restored=" + [bool]$restore.restored + " phase=" + $txn.phase)
            return [pscustomobject]@{
                success          = $false
                preflightError   = $null
                txn              = $txn
                txnDir           = $txnDir
                verify           = $null
                appliedFileCount = 0
                manualRecovery   = @($restore.manualRecovery)
                error            = $errMessage
            }
        } else {
            $txn.phase = 'FAILED_RESTORED'
            $txn.restoreVerified = $true
            $txn.restoredAt = (Get-Date).ToString('o')
            $txn.manualRecovery = @()
            $txn.failure = [ordered]@{ stage = $stageName; message = $errMessage; at = (Get-Date).ToString('o'); autoRestored = $true; restoreFailures = @() }
            Save-TransactionRecord -Txn $txn -TxnDir $txnDir
            Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'no payload write happened before the failure; phase=FAILED_RESTORED'
            return [pscustomobject]@{
                success          = $false
                preflightError   = $null
                txn              = $txn
                txnDir           = $txnDir
                verify           = $null
                appliedFileCount = 0
                manualRecovery   = @()
                error            = $errMessage
            }
        }
    }
}


#endregion

#region ============================== ROLLBACK =======================================

function Test-RollbackBackupCompleteness {
    param($Txn, [string]$TxnDir)
    $problems = New-Object System.Collections.ArrayList
    foreach ($r in @($Txn.files)) {
        if (-not [bool]$r['existed']) { continue }
        $rel = [string]$r['path']
        $backup = Join-Path (Join-Path $TxnDir 'backup') (ConvertTo-FsPath $rel)
        if (-not (Test-FileExists $backup)) { [void]$problems.Add("backup missing: $rel"); continue }
        try { $sha = Get-Sha256File $backup } catch { [void]$problems.Add("backup unreadable: $rel"); continue }
        if (-not [string]::Equals($sha, [string]$r['backupSha256'], [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($sha, [string]$r['preApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add("backup hash mismatch: $rel")
        }
    }
    foreach ($r in @($Txn.envFiles)) {
        if (-not [bool]$r['existed']) { continue }
        $rel = [string]$r['path']
        $backup = Join-Path (Join-Path $TxnDir 'backup') (ConvertTo-FsPath $rel)
        if (-not (Test-FileExists $backup)) { [void]$problems.Add("env backup missing: $rel"); continue }
        try { $sha = Get-Sha256File $backup } catch { [void]$problems.Add("env backup unreadable: $rel"); continue }
        if (-not [string]::Equals($sha, [string]$r['backupSha256'], [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($sha, [string]$r['preApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add("env backup hash mismatch: $rel")
        }
    }
    return $problems.ToArray()
}

function Get-RollbackCurrentState {
    # For every managed record: current disk hash, whether restore is needed and whether a
    # conflict exists. v2: for operation="add" records (existed=false) both ABSENT (already
    # pre-upgrade) and the applied target hash (delete needed) are legal current states; any
    # other current bytes mean the user modified the added file -> ROLLBACK_CONFLICT.
    param($Txn, [string]$InstallRoot)
    $records = New-Object System.Collections.ArrayList
    $conflicts = New-Object System.Collections.ArrayList
    $restoreNeeded = 0
    $alreadyPre = 0
    foreach ($r in @($Txn.files)) {
        $rel = [string]$r['path']
        $operation = 'replace'
        if (-not [string]::IsNullOrEmpty([string]$r['operation'])) { $operation = [string]$r['operation'] }
        $target = Join-Path $InstallRoot (ConvertTo-FsPath $rel)
        $current = 'ABSENT'
        if (Test-FileExists $target) {
            try { $current = Get-Sha256File $target } catch { $current = 'UNREADABLE' }
        }
        $pre = [string]$r['preApplySha256']
        $targetSha = [string]$r['targetSha256']
        if ([bool]$r['existed']) {
            $allowed = @($pre)
            if (-not [string]::IsNullOrEmpty($targetSha)) { $allowed += $targetSha }
            $ok = $false
            foreach ($a in $allowed) { if ([string]::Equals($current, $a, [System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break } }
            if (-not $ok) {
                [void]$conflicts.Add([ordered]@{ path = $rel; expected = ($allowed -join ' | '); actual = $current; category = 'ROLLBACK_CONFLICT' })
                continue
            }
            if ([string]::Equals($current, $pre, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyPre++
                [void]$records.Add([ordered]@{ record = $r; kind = 'file'; current = $current; needsRestore = $false })
            } else {
                $restoreNeeded++
                [void]$records.Add([ordered]@{ record = $r; kind = 'file'; current = $current; needsRestore = $true })
            }
        } else {
            $allowed = @('ABSENT')
            if (-not [string]::IsNullOrEmpty($targetSha)) { $allowed += $targetSha }
            $ok = $false
            foreach ($a in $allowed) { if ([string]::Equals($current, $a, [System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break } }
            if (-not $ok) {
                [void]$conflicts.Add([ordered]@{ path = $rel; expected = ($allowed -join ' | '); actual = $current; category = 'ROLLBACK_CONFLICT' })
                continue
            }
            if ($current -eq 'ABSENT') {
                $alreadyPre++
                [void]$records.Add([ordered]@{ record = $r; kind = 'file'; current = $current; needsRestore = $false })
            } else {
                $restoreNeeded++
                [void]$records.Add([ordered]@{ record = $r; kind = 'file'; current = $current; needsRestore = $true })
            }
        }
    }
    foreach ($r in @($Txn.envFiles)) {
        $rel = [string]$r['path']
        $target = Join-Path $InstallRoot (ConvertTo-FsPath $rel)
        $current = 'ABSENT'
        if (Test-FileExists $target) {
            try { $current = Get-Sha256File $target } catch { $current = 'UNREADABLE' }
        }
        $pre = [string]$r['preApplySha256']
        $post = [string]$r['postApplySha256']
        if ([bool]$r['skipped'] -or -not [bool]$r['existed']) {
            if ($current -eq 'ABSENT' -or [string]::Equals($current, $pre, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyPre++
                [void]$records.Add([ordered]@{ record = $r; kind = 'env'; current = $current; needsRestore = $false })
            } else {
                [void]$conflicts.Add([ordered]@{ path = $rel; expected = 'ABSENT (skipped)'; actual = $current; category = 'ROLLBACK_CONFLICT' })
            }
            continue
        }
        $allowed = @($pre)
        if (-not [string]::IsNullOrEmpty($post)) { $allowed += $post }
        $ok = $false
        foreach ($a in $allowed) { if ([string]::Equals($current, $a, [System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break } }
        if (-not $ok) {
            [void]$conflicts.Add([ordered]@{ path = $rel; expected = ($allowed -join ' | '); actual = $current; category = 'ROLLBACK_CONFLICT' })
            continue
        }
        if ([string]::Equals($current, $pre, [System.StringComparison]::OrdinalIgnoreCase)) {
            $alreadyPre++
            [void]$records.Add([ordered]@{ record = $r; kind = 'env'; current = $current; needsRestore = $false })
        } else {
            $restoreNeeded++
            [void]$records.Add([ordered]@{ record = $r; kind = 'env'; current = $current; needsRestore = $true })
        }
    }
    return [pscustomobject]@{
        records       = $records.ToArray()
        conflicts     = $conflicts.ToArray()
        restoreNeeded = $restoreNeeded
        alreadyPre    = $alreadyPre
    }
}


function Test-RollbackOriginalState {
    # After rollback: every RC2 payload file must equal the recorded original source state,
    # env files must equal their pre-apply bytes, every operation="add" target must be ABSENT
    # again, the install manifest must be the RC2 manifest, and transaction-created
    # directories must be gone (or empty leftovers reported for manual handling).
    param($Ctx, $Txn)
    $problems = New-Object System.Collections.ArrayList
    $root = [string]$Ctx.installRoot
    $expectedSource = $Ctx.expectedSource
    $sourceState = [string]$Txn.sourceState
    if ($null -ne $expectedSource) {
        $hashInfo = Get-InstallTreeHashes -InstallRoot $root -Paths @($expectedSource.Keys)
        foreach ($k in @($expectedSource.Keys)) {
            $actual = [string]$hashInfo.hashes[$k]
            $expected = [string]$expectedSource[$k]
            if ($k -ieq $script:CordisPath -and $sourceState -eq 'RC2_HOTFIXED') {
                $variant = [string]$Txn.hotfixedVariant
                if (-not [string]::IsNullOrEmpty($variant)) { $expected = [string]$script:HotfixedOverrides[$variant] }
            }
            if (-not [string]::Equals($actual, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$problems.Add("$k=$actual")
            }
        }
    } else {
        [void]$problems.Add('package expectedSourceHashes unavailable')
    }
    # install manifest must be back at the frozen RC2 manifest
    $im = Get-InstallManifestInfo $root
    if (-not $im.exists) { [void]$problems.Add('manifest.json is missing after rollback') }
    elseif (-not [string]::Equals([string]$im.sha256, $script:SourceManifestHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        [void]$problems.Add('manifest.json is not the frozen RC2 manifest after rollback')
    }
    # added files must be absent again
    foreach ($r in @($Txn.files)) {
        $operation = 'replace'
        if (-not [string]::IsNullOrEmpty([string]$r['operation'])) { $operation = [string]$r['operation'] }
        if ($operation -ne 'add') { continue }
        $rel = [string]$r['path']
        $target = Join-Path $root (ConvertTo-FsPath $rel)
        if (Test-FileExists $target) { [void]$problems.Add("added file still present after rollback: $rel") }
    }
    # transaction-created directories must be removed (empty leftovers are a hard problem too)
    foreach ($d in @($Txn.newDirectories)) {
        if ($null -eq $d) { continue }
        $rel = [string]$d['path']
        if ([string]::IsNullOrEmpty($rel)) { continue }
        $full = Join-Path $root (ConvertTo-FsPath $rel)
        if (-not (Test-DirExists $full)) { continue }
        if (Test-DirHasEntries $full) { [void]$problems.Add("ROLLBACK_LEFTOVER_DIRECTORY: created directory '$rel' still contains files (left in place, not deleted)") }
        else { [void]$problems.Add("transaction-created directory still exists after rollback: $rel") }
    }
    foreach ($r in @($Txn.envFiles)) {
        if (-not [bool]$r['existed']) { continue }
        $rel = [string]$r['path']
        $target = Join-Path $root (ConvertTo-FsPath $rel)
        try {
            $sha = Get-Sha256File $target
            if (-not [string]::Equals($sha, [string]$r['preApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$problems.Add("env $rel has wrong pre-apply bytes")
            }
        } catch { [void]$problems.Add("env $rel is unreadable") }
    }
    return $problems.ToArray()
}


function Invoke-RollbackAction {
    param($Options)
    $doc = New-ActionDocument 'rollback'
    $faultResult = Get-FaultModelFromOptions $Options
    $extra = New-CheckList
    if (-not $faultResult.ok) {
        [void](Add-Check $extra 'apply.preconditions' 'FAIL' $faultResult.error)
        Set-ActionOutcome -Doc $doc -Checks $extra -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($faultResult.error)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $ctx = Invoke-CoreChecks -InstallRoot $Options.InstallRoot -PackageRoot $Options.PackageRoot -DshHome $Options.DshHome -DshProfile $Options.DshProfile -Mode 'rollback' -FaultModel $faultResult.model -SkipPendingTransactionCheck
    [void](Set-SourceDocumentFields $doc $ctx)
    $identity = Get-IdentityOptionErrors $Options
    if ($identity.errors.Count -gt 0) {
        foreach ($c in @($identity.checks)) { [void]$extra.Add($c) }
        $allChecks = Merge-CheckLists $ctx.checks $extra
        Set-ActionOutcome -Doc $doc -Checks $allChecks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($identity.errors)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if (-not $ctx.packageValid) {
        Add-Check $extra 'rollback.transaction' 'FAIL' 'package self-integrity failed; rollback needs a trustworthy package manifest'
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('PACKAGE_INTEGRITY_FAILED')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if ($ctx.selfMode) {
        Add-Check $extra 'rollback.preconditions' 'FAIL' 'INSTALL_ROOT_EQUALS_UPGRADE_PACKAGE: run rollback from the unified package against a separate RC2 install root (self mode writes are refused)'
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('INSTALL_ROOT_EQUALS_UPGRADE_PACKAGE')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    # resolve transaction root / transaction
    $txnRoot = $null
    if (-not [string]::IsNullOrEmpty($Options.BackupRoot)) {
        try { $txnRoot = Get-NormalizedFullPath $Options.BackupRoot } catch { $txnRoot = $null }
    }
    if ([string]::IsNullOrEmpty($txnRoot)) { $txnRoot = Get-DefaultTransactionRoot $ctx.installRoot }
    if (-not (Test-PathUnder $txnRoot $ctx.installRoot)) {
        Add-Check $extra 'rollback.transaction' 'FAIL' "BACKUP_ROOT_OUTSIDE_INSTALL_ROOT: $txnRoot"
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('BACKUP_ROOT_OUTSIDE_INSTALL_ROOT')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $selected = $null
    $selectionError = $null
    if (-not [string]::IsNullOrEmpty($Options.Transaction)) {
        if (-not (Test-TransactionIdPattern $Options.Transaction)) { $selectionError = "ROLLBACK_TRANSACTION_NOT_FOUND: invalid transaction id '$($Options.Transaction)'" }
        else {
            $candidateDir = Join-Path $txnRoot $Options.Transaction
            if (-not (Test-DirExists $candidateDir)) { $selectionError = "ROLLBACK_TRANSACTION_NOT_FOUND: $candidateDir" }
            else {
                foreach ($t in @(Get-TransactionList $txnRoot)) { if ($t.id -eq $Options.Transaction) { $selected = $t; break } }
                if ($null -eq $selected) { $selectionError = "ROLLBACK_TRANSACTION_NOT_FOUND: transaction.json missing or unreadable under $candidateDir" }
            }
        }
    } else {
        $list = @(Get-TransactionList $txnRoot)
        if ($list.Count -eq 0) { $selectionError = "ROLLBACK_TRANSACTION_NOT_FOUND: no transaction directories under $txnRoot" }
        else { $selected = $list[0] }
    }
    if ($null -ne $selectionError) {
        Add-Check $extra 'rollback.transaction' 'FAIL' $selectionError
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($selectionError)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if ($selected.corrupt) {
        Add-Check $extra 'rollback.transaction' 'FAIL' ("TRANSACTION_CORRUPT: " + [string]$selected.error)
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('TRANSACTION_CORRUPT')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $txn = ConvertTo-DictDeep $selected.raw
    $txnDir = $selected.dir
    $phase = [string]$txn.phase
    Add-Check $extra 'rollback.transaction' 'PASS' "transaction $($selected.id) phase=$phase"
    # structural validation (v2 transaction schema only; legacy V1 transactions are refused)
    $structureProblems = New-Object System.Collections.ArrayList
    $txnSchema = Get-JsonPropertyValue $txn 'schemaVersion'
    if ($null -eq $txnSchema -or [int]$txnSchema -ne $script:TransactionSchemaVersion) {
        [void]$structureProblems.Add("ROLLBACK_TRANSACTION_UNSUPPORTED_SCHEMA: transaction schemaVersion '" + [string]$txnSchema + "' is not $($script:TransactionSchemaVersion) (legacy standalone-upgrader transactions cannot be rolled back by the unified engine)")
    }
    if ([string](Get-JsonPropertyValue $txn 'tool') -ne $script:ToolName) { [void]$structureProblems.Add('tool field mismatch') }
    if ([string](Get-JsonPropertyValue $txn 'upgradeId') -ne $script:UpgradeId) { [void]$structureProblems.Add('upgradeId mismatch') }
    $txnInstallRoot = [string](Get-JsonPropertyValue $txn 'installRoot')
    $txnRootOk = $false
    try { $txnRootOk = [string]::Equals((Get-NormalizedFullPath $txnInstallRoot), $ctx.installRoot, [System.StringComparison]::OrdinalIgnoreCase) } catch { $txnRootOk = $false }
    if (-not $txnRootOk) { [void]$structureProblems.Add("installRoot mismatch: '$txnInstallRoot'") }
    if ($script:KnownTransactionPhases -notcontains $phase) { [void]$structureProblems.Add("unknown transaction phase '$phase'") }
    $txnPayloadRoot = [string](Get-JsonPropertyValue $txn 'payloadRoot')
    if (-not [string]::IsNullOrEmpty($txnPayloadRoot) -and $txnPayloadRoot -ne $script:PayloadRootDefault) { [void]$structureProblems.Add("payloadRoot mismatch: '$txnPayloadRoot'") }
    $txnSourceState = [string](Get-JsonPropertyValue $txn 'sourceState')
    if ($txnSourceState -ne 'RC2_CLEAN' -and $txnSourceState -ne 'RC2_HOTFIXED') { [void]$structureProblems.Add("unexpected transaction sourceState '$txnSourceState'") }
    if ($structureProblems.Count -gt 0) {
        Add-Check $extra 'rollback.transaction' 'FAIL' ((@($structureProblems)) -join '; ')
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('ROLLBACK_TRANSACTION_INVALID')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    # other pending/corrupt transactions must not interfere
    $otherProblems = New-Object System.Collections.ArrayList
    foreach ($t in @(Get-TransactionList $txnRoot)) {
        if ($t.id -eq $selected.id) { continue }
        if ($t.corrupt) { [void]$otherProblems.Add("corrupt transaction: $($t.id)") }
        elseif ($script:TerminalTransactionPhases -notcontains [string]$t.phase) { [void]$otherProblems.Add("pending transaction: $($t.id):$($t.phase)") }
    }
    if ($otherProblems.Count -gt 0) {
        Add-Check $extra 'rollback.preconditions' 'FAIL' ("PENDING_TRANSACTION: " + ((@($otherProblems)) -join ', '))
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('PENDING_TRANSACTION')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    # backup completeness (existed=true records only)
    $backupProblems = @(Test-RollbackBackupCompleteness -Txn $txn -TxnDir $txnDir)
    if ($backupProblems.Count -gt 0) {
        Add-Check $extra 'rollback.backup' 'FAIL' ("ROLLBACK_BACKUP_INCOMPLETE: " + ((@($backupProblems) | Select-Object -First 10) -join '; '))
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('ROLLBACK_BACKUP_INCOMPLETE')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    Add-Check $extra 'rollback.backup' 'PASS' 'all transaction backup files are present with pre-apply hashes (operation=add records have no backup by design)'
    # current-state conflicts (never overwrite conflicts; never delete user-modified added files)
    $rollbackState = Get-RollbackCurrentState -Txn $txn -InstallRoot $ctx.installRoot
    if (@($rollbackState.conflicts).Count -gt 0) {
        $conflictText = New-Object System.Collections.ArrayList
        foreach ($c in @($rollbackState.conflicts | Select-Object -First 20)) { [void]$conflictText.Add(([string]$c['path'] + ' actual=' + [string]$c['actual'])) }
        Add-Check $extra 'rollback.conflicts' 'FAIL' ("ROLLBACK_CONFLICT: " + ((@($conflictText)) -join '; ') + ' (files modified after the upgrade were NOT overwritten or deleted)')
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('ROLLBACK_CONFLICT')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    Add-Check $extra 'rollback.conflicts' 'PASS' 'no user-modified payload/env/added-file conflicts detected'
    # DSH in-use gate
    if ($null -ne $ctx.dshPolicy -and $ctx.dshPolicy.refused) {
        Add-Check $extra 'rollback.preconditions' 'FAIL' ('DSH_IN_USE: ' + $ctx.dshPolicy.message)
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('DSH_IN_USE')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if (-not $Options.Yes) {
        $confirmed = Confirm-ApplyOrRollbackPrompt $Options
        if (-not $confirmed) {
            Add-Check $extra 'rollback.preconditions' 'FAIL' 'ROLLBACK_CANCELLED: not confirmed (pass -Yes for non-interactive use)'
            Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('ROLLBACK_CANCELLED')
            return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
        }
    }
    # terminal no-op handling
    $allPre = ($rollbackState.restoreNeeded -eq 0)
    if ($allPre -and ($script:TerminalTransactionPhases -contains $phase)) {
        Add-Check $extra 'rollback.restore' 'PASS' 'installation already at its pre-upgrade state (nothing to restore)'
        Add-Check $extra 'rollback.verifyState' 'PASS' 'all transaction files match pre-apply hashes; added files are absent'
        $doc.transaction = $txn
        $doc.rollback = [ordered]@{ phaseBefore = $phase; phaseAfter = $phase; restoredCount = 0; rollbackRepeated = ($phase -eq 'ROLLED_BACK'); noOp = $true }
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 0 -Outcome 'ROLLBACK_NOOP'
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 0 }
    }
    if ($allPre -and ($phase -eq 'PRECHECKED' -or $phase -eq 'BACKED_UP' -or $phase -eq 'STAGED')) {
        $txn.phase = 'ABORTED'
        $txn.restoredAt = (Get-Date).ToString('o')
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-Check $extra 'rollback.restore' 'PASS' 'transaction never modified payload files; marked ABORTED'
        Add-Check $extra 'rollback.verifyState' 'PASS' 'installation is at its pre-upgrade state'
        $doc.transaction = $txn
        $doc.rollback = [ordered]@{ phaseBefore = $phase; phaseAfter = 'ABORTED'; restoredCount = 0; rollbackRepeated = $false; noOp = $true }
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 0 -Outcome 'ABORTED'
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 0 }
    }
    # execute rollback
    $phaseBefore = $phase
    $txn.phase = 'ROLLBACK_STARTED'
    Save-TransactionRecord -Txn $txn -TxnDir $txnDir
    Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message ("rollback start (from phase " + $phaseBefore + ")")
    $restoredCount = 0
    $failures = New-Object System.Collections.ArrayList
    $order = Get-RestoreOrderForTransaction $txn
    $envByPath = @{}
    foreach ($r in @($txn.envFiles)) { $envByPath[([string]$r['path']).ToLowerInvariant()] = $r }
    $fileByPath = @{}
    foreach ($r in @($txn.files)) { $fileByPath[([string]$r['path']).ToLowerInvariant()] = $r }
    foreach ($rel in @($order.env)) {
        $rec = $envByPath[$rel.ToLowerInvariant()]
        if ($null -eq $rec) { continue }
        if ([bool]$rec['skipped'] -or -not [bool]$rec['existed']) { continue }
        $target = Join-Path $ctx.installRoot (ConvertTo-FsPath $rel)
        $current = 'ABSENT'
        if (Test-FileExists $target) { try { $current = Get-Sha256File $target } catch { $current = 'UNREADABLE' } }
        if ([string]::Equals($current, [string]$rec['preApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $err = Restore-TransactionFileRecord -Record $rec -TxnDir $txnDir -InstallRoot $ctx.installRoot -TransactionId $txn.transactionId
        if ($null -ne $err) { [void]$failures.Add("env ${rel}: $err") } else { $restoredCount++ }
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
    }
    foreach ($rel in @($order.payload)) {
        $rec = $fileByPath[$rel.ToLowerInvariant()]
        if ($null -eq $rec) { continue }
        $target = Join-Path $ctx.installRoot (ConvertTo-FsPath $rel)
        $current = 'ABSENT'
        if (Test-FileExists $target) { try { $current = Get-Sha256File $target } catch { $current = 'UNREADABLE' } }
        if ([bool]$rec['existed']) {
            if ([string]::Equals($current, [string]$rec['preApplySha256'], [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        } elseif ($current -eq 'ABSENT') { continue }
        $err = Restore-TransactionFileRecord -Record $rec -TxnDir $txnDir -InstallRoot $ctx.installRoot -TransactionId $txn.transactionId
        if ($null -ne $err) { [void]$failures.Add("file ${rel}: $err") } else { $restoredCount++ }
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
    }
    # remove transaction-created directories (exact paths, empty-only, non-recursive)
    $dirResult = Remove-CreatedDirectories -Txn $txn -InstallRoot $ctx.installRoot
    foreach ($df in @($dirResult.failures)) { [void]$failures.Add("dir: $df") }
    # cleanup per-file temp leftovers by exact path
    foreach ($r in @($txn.files) + @($txn.envFiles)) {
        $target = Join-Path $ctx.installRoot (ConvertTo-FsPath ([string]$r['path']))
        $dir = [System.IO.Path]::GetDirectoryName($target)
        if ([string]::IsNullOrEmpty($dir)) { continue }
        $tmp = Join-Path $dir ([System.IO.Path]::GetFileName($target) + '.upgrade-' + $txn.transactionId + '.tmp')
        if (Test-FileExists $tmp) { Remove-FileExact $tmp }
    }
    if ($failures.Count -gt 0) {
        $txn.phase = 'ROLLBACK_FAILED_MANUAL'
        $manual = @(New-ManualRecoveryCommands -Txn $txn -TxnDir $txnDir)
        $txn.manualRecovery = $manual
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-Check $extra 'rollback.restore' 'FAIL' ("ROLLBACK_FAILED_MANUAL: " + ((@($failures) | Select-Object -First 10) -join '; '))
        $doc.transaction = $txn
        $doc.rollback = [ordered]@{ phaseBefore = $phaseBefore; phaseAfter = 'ROLLBACK_FAILED_MANUAL'; restoredCount = $restoredCount; rollbackRepeated = $false; noOp = $false; manualRecovery = $manual }
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'ROLLBACK_FAILED_MANUAL' -Errors @('ROLLBACK_FAILED_MANUAL')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    Add-Check $extra 'rollback.restore' 'PASS' ("restored $restoredCount file(s) from the transaction backup and deleted the added files whose bytes matched the applied target")
    # restore verification against the original state recorded in the transaction
    $origProblems = @(Test-RollbackOriginalState -Ctx $ctx -Txn $txn)
    if ($origProblems.Count -gt 0) {
        $txn.phase = 'ROLLBACK_FAILED_MANUAL'
        Save-TransactionRecord -Txn $txn -TxnDir $txnDir
        Add-Check $extra 'rollback.verifyState' 'FAIL' ("restored state does not equal the recorded original state: " + ((@($origProblems) | Select-Object -First 10) -join '; '))
        $doc.transaction = $txn
        $doc.rollback = [ordered]@{ phaseBefore = $phaseBefore; phaseAfter = 'ROLLBACK_FAILED_MANUAL'; restoredCount = $restoredCount; rollbackRepeated = $false; noOp = $false }
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'ROLLBACK_FAILED_MANUAL' -Errors @('ROLLBACK_VERIFY_FAILED')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    Add-Check $extra 'rollback.verifyState' 'PASS' ("installation restored to the recorded original state (" + [string]$txn.sourceState + "), added files removed, created directories cleaned")
    $txn.phase = 'ROLLED_BACK'
    $txn.restoredAt = (Get-Date).ToString('o')
    $txn.rollbackVerified = $true
    Save-TransactionRecord -Txn $txn -TxnDir $txnDir
    Add-TransactionLog -Txn $txn -TxnDir $txnDir -Message 'rollback verified; phase=ROLLED_BACK'
    Add-Check $extra 'rollback.commit' 'PASS' 'transaction phase is ROLLED_BACK; backup directory kept'
    $doc.transaction = $txn
    $doc.rollback = [ordered]@{ phaseBefore = $phaseBefore; phaseAfter = 'ROLLED_BACK'; restoredCount = $restoredCount; rollbackRepeated = $false; noOp = $false }
    Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 0 -Outcome 'ROLLED_BACK'
    return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 0 }
}


#endregion

#region ============================== option validation / prompts ====================

function Get-IdentityOptionErrors {
    param($Options)
    $errors = New-Object System.Collections.ArrayList
    $checks = New-CheckList
    if (-not [string]::IsNullOrEmpty($Options.TargetVersion)) {
        if ($Options.TargetVersion -ne $script:TargetVersion) {
            [void]$errors.Add("PATCH_TARGET_MISMATCH: -TargetVersion '$($Options.TargetVersion)' is not '$($script:TargetVersion)'")
            [void](Add-Check $checks 'patch.targetVersion' 'FAIL' "PATCH_TARGET_MISMATCH: requested target version '$($Options.TargetVersion)' but this package upgrades to '$($script:TargetVersion)'")
        }
    }
    if (-not [string]::IsNullOrEmpty($Options.UpgradeId)) {
        if ($Options.UpgradeId -ne $script:UpgradeId) {
            [void]$errors.Add("PATCH_UPGRADE_ID_MISMATCH: -UpgradeId '$($Options.UpgradeId)' is not '$($script:UpgradeId)'")
            [void](Add-Check $checks 'patch.upgradeId' 'FAIL' "PATCH_UPGRADE_ID_MISMATCH: requested upgradeId '$($Options.UpgradeId)' but this package is '$($script:UpgradeId)'")
        }
    }
    return [pscustomobject]@{ errors = $errors.ToArray(); checks = $checks }
}

function Confirm-ApplyOrRollbackPrompt {
    param($Options)
    try {
        $answer = Read-Host 'Confirm execution (type y to continue)'
        return ($answer -match '^(?i)y(es)?$')
    } catch {
        return $false
    }
}


#endregion

#region ============================== ACTION WRAPPERS ================================

function Invoke-CheckAction {
    param($Options)
    $doc = New-ActionDocument 'check'
    $faultResult = Get-FaultModelFromOptions $Options
    if (-not $faultResult.ok) {
        $checks = New-CheckList
        Add-Check $checks 'apply.preconditions' 'FAIL' $faultResult.error
        Set-ActionOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($faultResult.error)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $ctx = Invoke-CoreChecks -InstallRoot $Options.InstallRoot -PackageRoot $Options.PackageRoot -DshHome $Options.DshHome -DshProfile $Options.DshProfile -Mode 'check' -FaultModel $faultResult.model
    [void](Set-SourceDocumentFields $doc $ctx)
    $identity = Get-IdentityOptionErrors $Options
    $extra = $identity.checks
    $allChecks = Merge-CheckLists $ctx.checks $extra
    $exitCode = 0
    $outcome = [string]$ctx.sourceState
    if ($ctx.hasFail) { $exitCode = 2 }
    if ($identity.errors.Count -gt 0) { $exitCode = 2; $outcome = 'REFUSED' }
    if ($ctx.sourceState -eq 'UNKNOWN_OR_MODIFIED' -and $identity.errors.Count -eq 0) { $outcome = 'UNKNOWN_OR_MODIFIED' }
    Set-ActionOutcome -Doc $doc -Checks $allChecks -ExitCode $exitCode -Outcome $outcome -Refused ($identity.errors.Count -gt 0) -Errors $identity.errors
    return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = $exitCode }
}

function Invoke-PlanAction {
    param($Options)
    $doc = New-ActionDocument 'plan'
    $faultResult = Get-FaultModelFromOptions $Options
    if (-not $faultResult.ok) {
        $checks = New-CheckList
        Add-Check $checks 'apply.preconditions' 'FAIL' $faultResult.error
        Set-ActionOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($faultResult.error)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $ctx = Invoke-CoreChecks -InstallRoot $Options.InstallRoot -PackageRoot $Options.PackageRoot -DshHome $Options.DshHome -DshProfile $Options.DshProfile -Mode 'plan' -FaultModel $faultResult.model
    [void](Set-SourceDocumentFields $doc $ctx)
    $identity = Get-IdentityOptionErrors $Options
    $extra = $identity.checks
    $planResult = $null
    if ($ctx.notInstalled) {
        Add-Check $extra 'plan.installRequired' 'WARN' 'NOT_INSTALLED: there is no existing installation to upgrade; a fresh install (tools/portable.ps1 -Action install) is the appropriate action'
    } elseif ($ctx.packageValid) {
        try {
            $forNoOp = ($ctx.sourceState -eq 'RC3_ALREADY_INSTALLED')
            $planResult = New-ApplyPlan -Ctx $ctx -Options $Options -ForNoOp:$forNoOp
            $doc.planId = $planResult.planId
            $doc.plan = $planResult.plan
        } catch {
            Add-Check $extra 'plan.build' 'FAIL' "plan could not be constructed: $($_.Exception.Message)"
        }
    } else {
        Add-Check $extra 'plan.build' 'FAIL' 'plan cannot be constructed: package self-integrity failed'
    }
    $allChecks = Merge-CheckLists $ctx.checks $extra
    $exitCode = 2
    $outcome = 'PLAN_BLOCKED'
    if ($identity.errors.Count -gt 0) { $outcome = 'REFUSED' }
    elseif ($ctx.notInstalled) { $exitCode = 0; $outcome = 'NOT_INSTALLED' }
    elseif ($ctx.hasFail) { $outcome = 'PLAN_BLOCKED' }
    elseif ($null -ne $planResult) {
        if ($planResult.plan.noOp) { $exitCode = 0; $outcome = 'NOOP_ALREADY_TARGET' }
        elseif ($planResult.plan.actionable) { $exitCode = 0; $outcome = 'PLAN_READY' }
    }
    Set-ActionOutcome -Doc $doc -Checks $allChecks -ExitCode $exitCode -Outcome $outcome -Refused ($identity.errors.Count -gt 0) -Errors $identity.errors
    return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = $exitCode }
}


function Invoke-VerifyAction {
    param($Options)
    $doc = New-ActionDocument 'verify'
    $faultResult = Get-FaultModelFromOptions $Options
    if (-not $faultResult.ok) {
        $checks = New-CheckList
        Add-Check $checks 'apply.preconditions' 'FAIL' $faultResult.error
        Set-ActionOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($faultResult.error)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $ctx = Invoke-CoreChecks -InstallRoot $Options.InstallRoot -PackageRoot $Options.PackageRoot -DshHome $Options.DshHome -DshProfile $Options.DshProfile -Mode 'verify' -FaultModel $faultResult.model
    [void](Set-SourceDocumentFields $doc $ctx)
    $identity = Get-IdentityOptionErrors $Options
    $checks = New-Object System.Collections.ArrayList
    foreach ($c in @($ctx.checks)) { if ([string]$c['id'] -like 'patch.*') { [void]$checks.Add($c) } }
    foreach ($c in @($identity.checks)) { [void]$checks.Add($c) }
    $verifyResult = $null
    if ($ctx.packageValid) {
        $latestTxn = Find-LatestCommittedTransaction $ctx
        $txnRaw = $null
        if ($null -ne $latestTxn) { $txnRaw = $latestTxn.raw }
        $verifyResult = Get-TargetVerifyChecks -Ctx $ctx -Txn $txnRaw
        foreach ($c in @($verifyResult.checks)) { [void]$checks.Add($c) }
    } else {
        $vr = Get-TargetVerifyChecks -Ctx $ctx -Txn $null
        $verifyResult = $vr
        foreach ($c in @($vr.checks)) { [void]$checks.Add($c) }
    }
    $fileComplete = $false
    if ($null -ne $verifyResult) { $fileComplete = [bool]$verifyResult.fileUpgradeComplete }
    if ($identity.errors.Count -gt 0) { $fileComplete = $false }
    $verifyObj = [ordered]@{
        fileUpgradeComplete          = $fileComplete
        FILE_UPGRADE_COMPLETE        = $(if ($fileComplete) { 'PASS' } else { 'FAIL' })
        runtimeActivation            = 'NOT TESTED'
        DSH_RUNTIME_ACTIVATION_VERIFIED = 'NOT TESTED'
        targetVersion                = $script:TargetVersion
        payloadFileCount             = [int]$ctx.targetPayloadFileCount
        sourcePayloadFileCount       = [int]$ctx.sourcePayloadFileCount
        addedFileCount               = [int]$ctx.addedFileCount
        variant                      = $ctx.rc3Variant
        sourceState                  = [string]$ctx.sourceState
        summary                      = (Get-CheckSummary $verifyResult.checks)
    }
    $doc.verify = $verifyObj
    $exitCode = 2
    $outcome = 'FILE_UPGRADE_INCOMPLETE'
    if ($identity.errors.Count -gt 0) { $outcome = 'REFUSED' }
    elseif ($fileComplete) { $exitCode = 0; $outcome = 'FILE_UPGRADE_COMPLETE' }
    Set-ActionOutcome -Doc $doc -Checks $checks -ExitCode $exitCode -Outcome $outcome -Refused ($identity.errors.Count -gt 0) -Errors $identity.errors
    return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = $exitCode }
}


function Invoke-StatusAction {
    param($Options)
    $doc = New-ActionDocument 'status'
    $faultResult = Get-FaultModelFromOptions $Options
    if (-not $faultResult.ok) {
        $checks = New-CheckList
        Add-Check $checks 'apply.preconditions' 'FAIL' $faultResult.error
        Set-ActionOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($faultResult.error)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $ctx = Invoke-CoreChecks -InstallRoot $Options.InstallRoot -PackageRoot $Options.PackageRoot -DshHome $Options.DshHome -DshProfile $Options.DshProfile -Mode 'status' -FaultModel $faultResult.model
    [void](Set-SourceDocumentFields $doc $ctx)
    $identity = Get-IdentityOptionErrors $Options
    $allChecks = Merge-CheckLists $ctx.checks $identity.checks
    try {
        $doc.status = New-StatusDocument $ctx
    } catch {
        Add-Check $identity.checks 'status.summary' 'FAIL' "status summary could not be built: $($_.Exception.Message)"
        $allChecks = Merge-CheckLists $ctx.checks $identity.checks
    }
    Set-ActionOutcome -Doc $doc -Checks $allChecks -ExitCode 0 -Outcome ([string]$ctx.sourceState) -Refused $false
    return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 0 }
}

function Invoke-ApplyAction {
    param($Options)
    $doc = New-ActionDocument 'apply'
    $faultResult = Get-FaultModelFromOptions $Options
    if (-not $faultResult.ok) {
        $checks = New-CheckList
        Add-Check $checks 'apply.preconditions' 'FAIL' $faultResult.error
        Set-ActionOutcome -Doc $doc -Checks $checks -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($faultResult.error)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $ctx = Invoke-CoreChecks -InstallRoot $Options.InstallRoot -PackageRoot $Options.PackageRoot -DshHome $Options.DshHome -DshProfile $Options.DshProfile -Mode 'apply' -FaultModel $faultResult.model
    [void](Set-SourceDocumentFields $doc $ctx)
    $identity = Get-IdentityOptionErrors $Options
    $extra = $identity.checks
    if ($identity.errors.Count -gt 0) {
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors $identity.errors
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if (-not $ctx.packageValid) {
        Add-Check $extra 'apply.preconditions' 'FAIL' 'package self-integrity failed; APPLY refuses to run'
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('PACKAGE_INTEGRITY_FAILED')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if ($ctx.notInstalled) {
        Add-Check $extra 'apply.preconditions' 'FAIL' 'UPGRADE_REQUIRES_EXISTING_INSTALL: nothing is installed at the install root; use a fresh install (tools/portable.ps1 -Action install) instead'
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('UPGRADE_REQUIRES_EXISTING_INSTALL')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if ($ctx.selfMode) {
        Add-Check $extra 'apply.preconditions' 'FAIL' 'INSTALL_ROOT_EQUALS_UPGRADE_PACKAGE: run upgrades from the new unified package against a separate RC2 install root; never from the install tree itself'
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('INSTALL_ROOT_EQUALS_UPGRADE_PACKAGE')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if ($ctx.sourceState -eq 'UNKNOWN_OR_MODIFIED') {
        Add-Check $extra 'apply.preconditions' 'FAIL' ('UNKNOWN_OR_MODIFIED: ' + (($ctx.reasons) -join ',') + "; resolve the conflicts (no file is auto-repaired) and re-run CHECK/PLAN")
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('UNKNOWN_OR_MODIFIED')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if ($ctx.hasFail) {
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('PRECHECK_FAILED')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $planResult = New-ApplyPlan -Ctx $ctx -Options $Options
    $doc.planId = $planResult.planId
    if ($ctx.sourceState -eq 'RC3_ALREADY_INSTALLED') {
        $noopDetail = 'installation already at 1.0.0-rc.3 (variant ' + [string]$ctx.rc3Variant + '); APPLY is a no-op (no transaction, no backup, nothing written)'
        if ($ctx.rc3Variant -eq 'FROZEN_RC3') {
            $noopDetail = 'installation is an authentic frozen rc.3 core (variant FROZEN_RC3); APPLY is a no-op (no transaction, no backup, nothing written); the unified tooling additions are not installed and no automatic refresh is offered'
        }
        Add-Check $extra 'apply.noop' 'PASS' $noopDetail
        $doc.transaction = [ordered]@{
            transactionId   = $null
            transactionDir  = $null
            phase           = 'NOOP_ALREADY_TARGET'
            planId          = $planResult.planId
            noOp            = $true
            variant         = $ctx.rc3Variant
            files           = @()
            envFiles        = @()
            newDirectories  = @()
            restoreVerified = $true
            backupVerified  = $true
            stagingVerified = $true
        }
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 0 -Outcome 'ALREADY_AT_TARGET' -Refused $false
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 0 }
    }
    # planId gate
    if ([string]::IsNullOrEmpty($Options.PlanId)) {
        Add-Check $extra 'apply.planGate' 'FAIL' 'PLAN_ID_REQUIRED: -PlanId is mandatory for APPLY; run -Action plan and pass its planId'
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('PLAN_ID_REQUIRED')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if (-not [string]::Equals([string]$Options.PlanId, [string]$planResult.planId, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Check $extra 'apply.planGate' 'FAIL' ("PLAN_STALE: state changed since PLAN; re-run PLAN. provided='$($Options.PlanId)' current='$($planResult.planId)'")
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('PLAN_STALE')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    Add-Check $extra 'apply.planGate' 'PASS' ("planId verified: " + $planResult.planId)
    # backup root safety
    if (-not [string]::IsNullOrEmpty($Options.BackupRoot)) {
        $br = $null
        try { $br = Get-NormalizedFullPath $Options.BackupRoot } catch { $br = $null }
        if ($null -eq $br -or -not (Test-PathUnder $br $ctx.installRoot)) {
            Add-Check $extra 'apply.preconditions' 'FAIL' "BACKUP_ROOT_OUTSIDE_INSTALL_ROOT: '$($Options.BackupRoot)' must be under the install root"
            Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('BACKUP_ROOT_OUTSIDE_INSTALL_ROOT')
            return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
        }
    }
    # dsh in-use gate
    if ($null -ne $ctx.dshPolicy -and $ctx.dshPolicy.refused) {
        Add-Check $extra 'apply.preconditions' 'FAIL' ('DSH_IN_USE: ' + $ctx.dshPolicy.message)
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('DSH_IN_USE')
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    if (-not $Options.Yes) {
        $confirmed = Confirm-ApplyOrRollbackPrompt $Options
        if (-not $confirmed) {
            Add-Check $extra 'apply.preconditions' 'FAIL' 'APPLY_CANCELLED: not confirmed (pass -Yes for non-interactive use)'
            Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @('APPLY_CANCELLED')
            return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
        }
    }
    $result = Invoke-ApplyTransaction -Ctx $ctx -PlanResult $planResult -Options $Options -FaultModel $faultResult.model
    if ($null -ne $result -and -not [string]::IsNullOrEmpty($result.preflightError)) {
        Add-Check $extra 'apply.preconditions' 'FAIL' $result.preflightError
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome 'REFUSED' -Refused $true -Errors @($result.preflightError)
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
    }
    $txn = $result.txn
    $doc.transaction = $txn
    if ($result.success) {
        Add-Check $extra 'backup.verified' 'PASS' 'all backup files verified against pre-apply bytes (operation=add records have no backup by design)'
        Add-Check $extra 'staging.verified' 'PASS' 'all staged target files verified against target hashes'
        Add-Check $extra 'apply.payloadWrites' 'PASS' ("applied " + [int]$result.appliedFileCount + " payload file(s), including " + [int]$planResult.plan.addedFileCount + " new file(s), in normative order (manifest.json and VERSION last)")
        $dirCount = 0
        foreach ($d in @($txn.newDirectories)) { if ($null -ne $d -and [bool]$d['created'] -and -not [bool]$d['removed']) { $dirCount++ } }
        if ($dirCount -gt 0) { Add-Check $extra 'apply.newDirectories' 'PASS' ("created $dirCount target director(ies) recorded in the transaction for exact rollback cleanup") }
        Add-Check $extra 'apply.envUpdates' 'PASS' 'environment files updated declaratively and verified'
        Add-Check $extra 'apply.verify' 'PASS' 'full target-state verification PASS (FILE_UPGRADE_COMPLETE)'
        Add-Check $extra 'apply.commit' 'PASS' 'transaction phase COMMITTED'
        Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 0 -Outcome 'APPLIED'
        return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 0 }
    }
    # failure
    if ([bool]$txn.backupVerified) { Add-Check $extra 'backup.verified' 'PASS' 'backup completed and verified before any payload write' }
    else { Add-Check $extra 'backup.verified' 'FAIL' 'backup phase did not complete' }
    if ([bool]$txn.stagingVerified) { Add-Check $extra 'staging.verified' 'PASS' 'staging completed and verified before any payload write' }
    else { Add-Check $extra 'staging.verified' 'NOT TESTED' 'staging phase did not complete' }
    Add-Check $extra 'apply.failure' 'FAIL' ("APPLY failed and was handled transactionally: " + [string]$result.error)
    $outcome = 'APPLY_FAILED_MANUAL'
    if ([string]$txn.phase -eq 'FAILED_RESTORED' -and [bool]$txn.restoreVerified) { $outcome = 'APPLY_FAILED_RESTORED' }
    Set-ActionOutcome -Doc $doc -Checks (Merge-CheckLists $ctx.checks $extra) -ExitCode 2 -Outcome $outcome -Refused $false -Errors @([string]$result.error)
    return [pscustomobject]@{ doc = (Complete-ActionDocument $doc); exitCode = 2 }
}


function Test-OptionsShape {
    param($Options)
    $errors = New-Object System.Collections.ArrayList
    $action = ''
    if ($null -ne $Options) { $action = [string]$Options.Action }
    $validActions = @('check', 'plan', 'apply', 'verify', 'status', 'rollback')
    if ($validActions -notcontains $action) {
        [void]$errors.Add("INVALID_ACTION: -Action must be one of check/plan/apply/verify/status/rollback (got '$action')")
    }
    if ($null -eq $Options -or [string]::IsNullOrEmpty($Options.InstallRoot)) {
        [void]$errors.Add('INVALID_ARGUMENT: -InstallRoot is mandatory')
    }
    return $errors.ToArray()
}

function Invoke-UpgraderAction {
    param($Options)
    $action = ([string]$Options.Action).ToLowerInvariant()
    switch ($action) {
        'check' { return (Invoke-CheckAction $Options) }
        'plan' { return (Invoke-PlanAction $Options) }
        'apply' { return (Invoke-ApplyAction $Options) }
        'verify' { return (Invoke-VerifyAction $Options) }
        'status' { return (Invoke-StatusAction $Options) }
        'rollback' { return (Invoke-RollbackAction $Options) }
        default { throw "unsupported action '$action'" }
    }
}

#endregion

# -------------------------------------------------------------------------------------
# v2 helpers: JSON value scan, created-directory bookkeeping and new-file (add) support.
# -------------------------------------------------------------------------------------

function Get-JsonStringValues {
    # Recursively collects every string leaf of a JSON object/array (used for the acyclic
    # hash rule: upgrade-data must not embed its own hash or the SHA256SUMS.txt hash).
    param($Value)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Value) { return $out.ToArray() }
    if ($Value -is [string]) { [void]$out.Add([string]$Value); return $out.ToArray() }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            foreach ($v in @(Get-JsonStringValues $Value[$k])) { [void]$out.Add([string]$v) }
        }
        return $out.ToArray()
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) {
            foreach ($v in @(Get-JsonStringValues $p.Value)) { [void]$out.Add([string]$v) }
        }
        return $out.ToArray()
    }
    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            foreach ($v in @(Get-JsonStringValues $item)) { [void]$out.Add([string]$v) }
        }
        return $out.ToArray()
    }
    return $out.ToArray()
}

function Get-CreatedDirectoryPlan {
    # Directories that an APPLY would have to create for the given target file paths
    # (parents of operation="add" files), outermost first, manifest-style relative paths.
    # Read-only: only probes existence.
    param([string]$InstallRoot, [string[]]$FilePaths)
    $out = New-Object System.Collections.ArrayList
    $root = Get-NormalizedFullPath $InstallRoot
    $seen = @{}
    foreach ($rel in @($FilePaths)) {
        $fs = ConvertTo-FsPath ([string]$rel)
        $parentRel = [System.IO.Path]::GetDirectoryName($fs)
        if ([string]::IsNullOrEmpty($parentRel) -or $parentRel -eq '.') { continue }
        $parts = $parentRel.Split('\')
        $cur = ''
        foreach ($part in $parts) {
            if ([string]::IsNullOrEmpty($part)) { continue }
            if ($cur.Length -eq 0) { $cur = $part } else { $cur = $cur + '\' + $part }
            $full = Join-Path $root $cur
            if (Test-DirExists $full) { continue }
            if (Test-FileExists $full) { continue }
            $key = (ConvertTo-ManifestPath $cur).ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [void]$out.Add((ConvertTo-ManifestPath $cur)) }
        }
    }
    return $out.ToArray()
}

function Ensure-TargetDirectories {
    # Creates the missing parent directories of one target file inside the install root.
    # Safety: path must resolve under the install root, must not be a file or reparse
    # point; each creation is recorded in the transaction (newDirectories, created=true)
    # and persisted BEFORE the file write (crash-safe bookkeeping).
    param($Txn, [string]$TxnDir, [string]$InstallRoot, [string]$RelativeFilePath)
    $root = Get-NormalizedFullPath $InstallRoot
    $fs = ConvertTo-FsPath ([string]$RelativeFilePath)
    $parentRel = [System.IO.Path]::GetDirectoryName($fs)
    $created = New-Object System.Collections.ArrayList
    $failures = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($parentRel) -or $parentRel -eq '.') {
        return [pscustomobject]@{ created = $created.ToArray(); failures = $failures.ToArray() }
    }
    $parts = $parentRel.Split('\')
    $cur = ''
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        if ($cur.Length -eq 0) { $cur = $part } else { $cur = $cur + '\' + $part }
        $rel = ConvertTo-ManifestPath $cur
        $full = Join-Path $root $cur
        if (Test-DirExists $full) {
            if (Test-ReparsePoint $full) { [void]$failures.Add("reparse point in target directory path: $rel"); break }
            continue
        }
        if (Test-FileExists $full) { [void]$failures.Add("target directory path exists as a file: $rel"); break }
        try {
            if (-not (Test-PathUnder $full $root)) { [void]$failures.Add("target directory escapes the install root: $rel"); break }
        } catch { [void]$failures.Add("invalid target directory path: $rel"); break }
        try {
            [void][System.IO.Directory]::CreateDirectory((Get-IoPath $full))
        } catch { [void]$failures.Add("could not create target directory '$rel': $($_.Exception.Message)"); break }
        [void]$created.Add($rel)
        $foundRecord = $false
        foreach ($d in @($Txn.newDirectories)) {
            if ([string]::IsNullOrEmpty([string]$d['path'])) { continue }
            if ([string]$d['path'] -ieq $rel) { $d['created'] = $true; $foundRecord = $true; break }
        }
        if (-not $foundRecord) {
            $list = New-Object System.Collections.ArrayList
            foreach ($d in @($Txn.newDirectories)) { [void]$list.Add($d) }
            [void]$list.Add([ordered]@{ path = $rel; created = $true; removed = $false })
            $Txn.newDirectories = $list.ToArray()
        }
        if (-not [string]::IsNullOrEmpty($TxnDir)) { Save-TransactionRecord -Txn $Txn -TxnDir $TxnDir }
    }
    return [pscustomobject]@{ created = $created.ToArray(); failures = $failures.ToArray() }
}

function Remove-CreatedDirectories {
    # Deletes directories recorded as created by this transaction, deepest first, ONLY when
    # they are empty ([System.IO.Directory]::Delete($p,$false)); never recursive, never a
    # directory that existed before the transaction, never a reparse point.
    param($Txn, [string]$InstallRoot)
    $root = Get-NormalizedFullPath $InstallRoot
    $failures = New-Object System.Collections.ArrayList
    $removed = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    foreach ($d in @($Txn.newDirectories)) {
        if ($null -eq $d) { continue }
        $rel = [string]$d['path']
        if ([string]::IsNullOrEmpty($rel)) { continue }
        $wasCreated = $false
        if ($null -ne $d['created']) { $wasCreated = [bool]$d['created'] }
        if ($null -ne $d['removed'] -and [bool]$d['removed']) { continue }
        if (-not $wasCreated) { continue }
        [void]$dirs.Add($rel)
    }
    # insertion sort: deeper paths first, then ordinal descending (deterministic)
    $arr = $dirs.ToArray()
    for ($i = 1; $i -lt $arr.Length; $i++) {
        $key = [string]$arr[$i]
        $keyDepth = ($key -split '/').Count
        $j = $i - 1
        while ($j -ge 0) {
            $cur = [string]$arr[$j]
            $curDepth = ($cur -split '/').Count
            $move = $false
            if ($curDepth -lt $keyDepth) { $move = $true }
            elseif ($curDepth -eq $keyDepth -and [string]::CompareOrdinal($cur, $key) -lt 0) { $move = $true }
            if (-not $move) { break }
            $arr[$j + 1] = $cur
            $j--
        }
        $arr[$j + 1] = $key
    }
    foreach ($rel in $arr) {
        $full = Join-Path $root (ConvertTo-FsPath ([string]$rel))
        try {
            if (-not (Test-PathUnder $full $root)) { [void]$failures.Add("created directory escapes the install root: $rel"); continue }
            if (Test-ReparsePoint $full) { [void]$failures.Add("created directory became a reparse point (left in place): $rel"); continue }
            if (-not (Test-DirExists $full)) { continue }
            if (Test-DirHasEntries $full) { [void]$failures.Add("created directory is not empty (left in place): $rel"); continue }
            [System.IO.Directory]::Delete((Get-IoPath $full), $false)
            [void]$removed.Add([string]$rel)
            foreach ($d in @($Txn.newDirectories)) {
                if ([string]$d['path'] -ieq [string]$rel) { $d['removed'] = $true }
            }
        } catch { [void]$failures.Add("could not remove created directory '$rel': $($_.Exception.Message)") }
    }
    return [pscustomobject]@{ removed = $removed.ToArray(); failures = $failures.ToArray() }
}

#region ============================== final helpers ==================================

function Get-DefaultPackageRoot {
    param([string]$ScriptDirectory)
    $dir = Get-NormalizedFullPath $ScriptDirectory
    return (Get-NormalizedFullPath (Split-Path $dir -Parent))
}

#endregion

# @@EOF@@
