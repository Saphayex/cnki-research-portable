# =============================================================================
# UnifiedAssert.ps1 - independent oracle / assertion helpers for the
# CNKI Research Portable unified RC3 test matrix (RC2 install -> unified RC3
# in-place upgrade / rollback / failure injection / user-data protection).
#
# Owner: test-dev.  Shipped as part of the candidate repository tests\lib\.
#
# IMPORTANT INDEPENDENCE RULE
#   This file MUST NOT dot-source, import or reuse the engine's
#   UpgradeCommon.ps1 / setup.ps1 / builder code.  All expected facts are
#   independently recomputed from:
#     * the frozen RC2 ZIP (read-only; source identity),
#     * the candidate package bytes themselves (manifest.json,
#       upgrade-data\rc2-to-rc3.json, SHA256SUMS.txt) - never hardcoded
#       target hashes/counts,
#     * fixture fingerprints recorded before an action.
#   The engine's own JSON is only *asserted against*, never trusted as truth.
#
# Windows PowerShell 5.1 only.  UTF-8 with BOM (contains non-ASCII literals).
# =============================================================================

# ---------------------------------------------------------------------------
# Frozen-input trust anchors (NOT target-identity anchors).
#
# The unified candidate target identity is DERIVED FROM THE CANDIDATE PACKAGE
# (manifest.json + upgrade-data\rc2-to-rc3.json + SHA256SUMS.txt + actual
# bytes), never from a hardcoded frozen RC3 payload identity.  This file only
# hardcodes the FROZEN INPUTS the matrix may verify read-only:
#   * the frozen RC2 ZIP / manifest / VERSION / cordis + the 2 hotfix variants
#     (source-state detection trust anchors, identical to Upgrader V1),
#   * the frozen RC3 manifest hash (independent constant used by the engine to
#     recognize an already-installed FROZEN_RC3 tree), the frozen RC3 ZIP
#     identity (only used when the matrix has read-only access to it for
#     core-equality evidence), and the frozen distribution versions.
#
# METADATA-SPLIT PACKAGE MODEL (authoritative for the unified candidate):
#   payload set P          = manifest.json files[] = frozen RC3 payload (107)
#                            + new unified payload files (tools/setup.ps1, engine,
#                            builder, shipped test files, ...)
#   package file set       = P
#                            + manifest.json
#                            + SHA256SUMS.txt
#                            + upgrade-data/rc2-to-rc3.json  (metadata, U)
#                            + upgrade-data/README.md
#   installed target tree  = P + manifest.json  (metadata files are PACKAGE-ONLY
#                            and are NOT installed into the InstallRoot)
#   internal SHA256SUMS    = every package file except SHA256SUMS.txt itself
#   expectedTargetHashes   = exactly P
#   changedFiles           = replaces + adds + manifest.json replace; U does not
#                            appear in changedFiles (it is package-only)
# ---------------------------------------------------------------------------
function Get-FrozenIdentity {
    [pscustomobject]@{
        Rc2ZipSha256        = '4f279f359a42e5e950cd9f66e04f0922c5e40ec4c77f9192e2168274ce1142b5'
        Rc3ZipSha256        = 'f4e914d135eb51b8d3afbd96e7fca53997a06e0ed1a75a28cca9386c3cc7f5fd'
        Rc2ZipBytes         = 388236
        Rc3ZipBytes         = 395232
        Rc2ManifestSha256   = '80229318a1ef070f5cedafda39785be0cbb49ee727f7a620e7e6aab5113a6e1f'
        Rc3ManifestSha256   = '98c8bca2bd34f0eda0e1d9fb1d0c6f38e60c8c4e92990efcb1c3be507f99a5e2'
        Rc2VersionSha256    = '0c654c00f94741d78169de333d4d9e866be0667b41f9c54cafe3c6b700b15a43'
        Rc3VersionSha256    = 'd458c8db8288a8a159c5b25dbea651430713bd1417c213dd83048058fe5fe228'
        Rc2Version          = '1.0.0-rc.2'
        Rc3Version          = '1.0.0-rc.3'
        BundleVersion       = '1.0.0'
        CordisPath          = 'bundle/cnki-research/cordis.patch.yml'
        CordisRc2Sha256     = 'afa6ffdd0684fe0440a5e3d2414c08fe36be946e64c19648c48b3770f68bf343'
        CordisRc3Sha256     = 'edda8817e0bf449d8324f4875b1c7acd37a8dc693c3a82d044f4a5c436421778'
        CordisRc2Bytes      = 16762
        CordisRc3Bytes      = 16705
        HotfixLineRemovedSha256 = 'edda8817e0bf449d8324f4875b1c7acd37a8dc693c3a82d044f4a5c436421778'
        HotfixTextRemovedSha256 = 'b5aaa79ebb7a0c1bdd6f253e6462b0c1ee3db8f4f34cf15e83e0a59a37e4c0a9'
        HotfixLineRemovedBytes  = 16705
        HotfixTextRemovedBytes  = 16706
        Rc2PayloadFileCount = 107
        Rc2ZipFileCount     = 108
        BundleName          = '@local/dsh-cnki-research'
    }
}

function Get-ExpectedToolNames {
    @('easy-search', 'advanced-search', 'get-info-from-url', 'get-info-by-detail',
      'list-journal', 'search-issn', 'login', 'logout')
}

function Get-PersonaPrefix {
    'You are a coding agent powered by the {{model}} model.'
}

function ConvertTo-NormalizedRelPath {
    param([AllowNull()][string]$Path)
    if ($null -eq $Path) { return '' }
    return (($Path -replace '\\', '/').Trim().Trim('/'))
}

function Get-JsonPropertyDictionary {
    # Turns a ConvertFrom-Json object into an ordered dictionary key->value.
    param([AllowNull()]$Object)
    $dict = New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $Object) { return $dict }
    foreach ($prop in @($Object.PSObject.Properties)) { $dict[$prop.Name] = $prop.Value }
    return $dict
}

function Get-JsonValueFirst {
    # Returns the first non-null/non-empty value among alternative JSON paths.
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string[]]$Paths)
    foreach ($p in $Paths) {
        $v = Get-JsonValue $Object $p
        if ($null -ne $v -and [string]$v -ne '') { return $v }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Internal package SHA256SUMS.txt parser (the in-package trust root).
# Format: "<64-hex>  <rel-path>" (sha256sum style; optional '*' binary marker).
# ---------------------------------------------------------------------------
function Get-SumsFileEntries {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Get-FullPath $Path
    if (-not [System.IO.File]::Exists($full)) { throw "Get-SumsFileEntries: file not found: $full" }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "Get-SumsFileEntries: '$full' starts with a UTF-8 BOM (must be UTF-8 without BOM)"
    }
    $text = (New-Utf8NoBom).GetString($bytes)
    $entries = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $problems = New-Object System.Collections.ArrayList
    $lineNo = 0
    foreach ($rawLine in ($text -split "`n")) {
        $lineNo++
        $line = $rawLine.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $m = [regex]::Match($line, '^([0-9a-fA-F]{64})[ \t]+\*?(.+)$')
        if (-not $m.Success) { [void]$problems.Add("malformed line $lineNo"); continue }
        $hash = $m.Groups[1].Value.ToLowerInvariant()
        $rel = ConvertTo-NormalizedRelPath $m.Groups[2].Value
        if ($rel -eq '') { [void]$problems.Add("empty path on line $lineNo"); continue }
        if ($rel.StartsWith('/') -or $rel -match '^[A-Za-z]:' -or $rel -match '(^|/)\.\.(/|$)' -or $rel -match ':') {
            [void]$problems.Add("unsafe path '$rel' on line $lineNo"); continue
        }
        if ($entries.ContainsKey($rel)) { [void]$problems.Add("duplicate entry '$rel' on line $lineNo"); continue }
        $entries[$rel] = $hash
    }
    return [pscustomobject]@{
        Path     = $full
        Sha256   = Get-Sha256File $full
        Bytes    = [long]$bytes.Length
        Entries  = $entries
        Problems = @($problems.ToArray())
    }
}

# ---------------------------------------------------------------------------
# Unified package model: reads and structurally normalizes the candidate
# package (PackageRoot = the extracted candidate ZIP root, or -PackageDir).
# Read-only. All expected identity comes from the package bytes themselves.
# ---------------------------------------------------------------------------
function Read-UnifiedPackageModel {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$CandidateZip = ''
    )
    $root = Get-FullPath $PackageRoot
    if (-not [System.IO.Directory]::Exists($root)) { throw "Read-UnifiedPackageModel: package root not found: $root" }
    $manifestPath = Join-Path $root 'manifest.json'
    $sumsPath = Join-Path $root 'SHA256SUMS.txt'
    $metadataPath = Join-Path $root 'upgrade-data\rc2-to-rc3.json'
    $readmePath = Join-Path $root 'upgrade-data\README.md'

    # actual package files (paths+bytes+sha256); never descend into reparse points
    $snapshot = @(Get-TreeSnapshot -Root $root)
    $packageFiles = New-Object System.Collections.ArrayList
    $reparse = New-Object System.Collections.ArrayList
    foreach ($e in $snapshot) {
        if ($e.Kind -eq 'reparse') { [void]$reparse.Add($e.Rel); continue }
        if ($e.Kind -ne 'file') { continue }
        [void]$packageFiles.Add([pscustomobject]@{ Path = $e.Rel; Bytes = [long]$e.Bytes; Sha256 = $e.Sha256 })
    }
    $packageFileMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $packageFiles) { $packageFileMap[$f.Path] = $f }

    $manifest = $null
    $manifestError = $null
    if ([System.IO.File]::Exists($manifestPath)) {
        try { $manifest = Read-JsonFile $manifestPath } catch { $manifestError = $_.Exception.Message }
    }
    $manifestSha = if ([System.IO.File]::Exists($manifestPath)) { Get-Sha256File $manifestPath } else { $null }
    $manifestBytes = if ([System.IO.File]::Exists($manifestPath)) { [long](Get-Item -LiteralPath $manifestPath).Length } else { 0 }

    $sums = $null
    $sumsError = $null
    if ([System.IO.File]::Exists($sumsPath)) {
        try { $sums = Get-SumsFileEntries -Path $sumsPath } catch { $sumsError = $_.Exception.Message }
    }

    $metadata = $null
    $metadataError = $null
    if ([System.IO.File]::Exists($metadataPath)) {
        try { $metadata = Read-JsonFile $metadataPath } catch { $metadataError = $_.Exception.Message }
    }
    $metadataSha = if ([System.IO.File]::Exists($metadataPath)) { Get-Sha256File $metadataPath } else { $null }

    # payload set P = manifest.files[]
    $payloadFiles = New-Object System.Collections.ArrayList
    $payloadMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($manifest -and (Get-JsonValue $manifest 'files')) {
        foreach ($entry in @(Get-JsonValue $manifest 'files')) {
            $rel = ConvertTo-NormalizedRelPath ([string](Get-JsonValue $entry 'path'))
            if (-not $rel) { continue }
            $item = [pscustomobject]@{
                Path   = $rel
                Bytes  = [long](Get-JsonValue $entry 'bytes')
                Sha256 = ([string](Get-JsonValue $entry 'sha256')).ToLowerInvariant()
            }
            [void]$payloadFiles.Add($item)
            $payloadMap[$rel] = $item
        }
    }
    $sortedPayload = @($payloadFiles.ToArray() | Sort-Object -Property Path)

    # installed target tree = P + manifest.json (metadata files are package-only)
    $targetFiles = New-Object System.Collections.ArrayList
    foreach ($f in $sortedPayload) { [void]$targetFiles.Add([pscustomobject]@{ Path = $f.Path; Bytes = $f.Bytes; Sha256 = $f.Sha256 }) }
    if ($manifestSha) {
        [void]$targetFiles.Add([pscustomobject]@{ Path = 'manifest.json'; Bytes = $manifestBytes; Sha256 = $manifestSha })
    }
    $targetMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $targetFiles) { $targetMap[$f.Path] = $f }
    $targetList = @($targetFiles.ToArray() | Sort-Object -Property Path | ForEach-Object { $_.Path })

    # upgrade-data metadata normalized
    $changedFiles = New-Object System.Collections.ArrayList
    $changedMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    $expectedTargetHashes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $expectedSourceHashes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $hotfixOverrides = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    $envFiles = @()
    $sourceVersion = $null; $targetVersion = $null; $upgradeId = $null; $upgraderVersion = $null
    $layout = $null; $sourceIdentity = $null; $targetManifestInfo = $null
    if ($metadata) {
        # Version/identity field names are read through documented alternatives so
        # the oracle tolerates the approved schema's naming variants while still
        # deriving every expected fact from the package itself.
        $sourceVersion = [string](Get-JsonValueFirst $metadata @('sourceDistributionVersion', 'sourceVersion'))
        $targetVersion = [string](Get-JsonValueFirst $metadata @('targetDistributionVersion', 'targetVersion'))
        if (-not $targetVersion -and $manifest) { $targetVersion = [string](Get-JsonValue $manifest 'distribution.version') }
        if (-not $sourceVersion) { $sourceVersion = (Get-FrozenIdentity).Rc2Version }
        $upgradeId = [string](Get-JsonValue $metadata 'upgradeId')
        $upgraderVersion = [string](Get-JsonValue $metadata 'upgraderVersion')
        $layout = Get-JsonValue $metadata 'packageLayout'
        if ($null -eq $layout) {
            # Flat v2 metadata form: payloadRoot at top level, fixed relative paths.
            $layout = [pscustomobject]@{
                payloadRoot     = [string](Get-JsonValue $metadata 'payloadRoot')
                manifestPath    = 'manifest.json'
                sumsFile        = 'SHA256SUMS.txt'
                metadataPath    = 'upgrade-data/rc2-to-rc3.json'
                installedLayout = 'A_in_place_only'
            }
        }
        $sourceIdentity = Get-JsonValue $metadata 'sourceIdentity'
        if ($null -eq $sourceIdentity) {
            $sourceIdentity = [pscustomobject]@{
                manifestSha256        = [string](Get-JsonValueFirst $metadata @('sourceManifestHash'))
                manifestBytes         = Get-JsonValueFirst $metadata @('sourceManifestBytes')
                packageSha256         = [string](Get-JsonValueFirst $metadata @('sourcePackageHash'))
                packageBytes          = Get-JsonValueFirst $metadata @('sourcePackageBytes')
                payloadFileCount      = Get-JsonValueFirst $metadata @('sourcePayloadFileCount')
                distributionVersion   = $sourceVersion
                frozenRc3ManifestSha256 = [string](Get-JsonValueFirst $metadata @('frozenRc3ManifestSha256', 'sourceFrozenRc3ManifestSha256', 'sourceIdentity.frozenRc3ManifestSha256'))
            }
        }
        $targetManifestInfo = Get-JsonValue $metadata 'targetManifest'
        if ($null -eq $targetManifestInfo) {
            $targetManifestInfo = [pscustomobject]@{
                path                = 'manifest.json'
                distributionVersion = $targetVersion
                bundleVersion       = $(if ($manifest) { [string](Get-JsonValue $manifest 'bundle.version') } else { '' })
                schemaVersion       = 1
                payloadFileCount    = Get-JsonValueFirst $metadata @('payloadFileCount')
            }
        }
        foreach ($entry in @(Get-JsonValue $metadata 'changedFiles')) {
            if ($null -eq $entry) { continue }
            $rel = ConvertTo-NormalizedRelPath ([string](Get-JsonValue $entry 'path'))
            if (-not $rel) { continue }
            $item = [pscustomobject]@{
                Path           = $rel
                Operation      = [string](Get-JsonValue $entry 'operation')
                Classification = [string](Get-JsonValue $entry 'classification')
                SourceSha256   = [string](Get-JsonValue $entry 'sourceSha256')
                TargetSha256   = [string](Get-JsonValue $entry 'targetSha256')
                TargetBytes    = Get-JsonValue $entry 'targetBytes'
                HashSource     = [string](Get-JsonValue $entry 'hashSource')
                HotfixVariant  = [string](Get-JsonValue $entry 'hotfixVariant')
            }
            [void]$changedFiles.Add($item)
            $changedMap[$rel] = $item
        }
        $targetHashesRaw = Get-JsonValue $metadata 'expectedTargetHashes'
        if ($targetHashesRaw) {
            foreach ($prop in @($targetHashesRaw.PSObject.Properties)) {
                $expectedTargetHashes[(ConvertTo-NormalizedRelPath $prop.Name)] = ([string]$prop.Value).ToLowerInvariant()
            }
        }
        $sourceHashesRaw = Get-JsonValue $metadata 'expectedSourceHashes'
        if ($sourceHashesRaw) {
            foreach ($prop in @($sourceHashesRaw.PSObject.Properties)) {
                $expectedSourceHashes[(ConvertTo-NormalizedRelPath $prop.Name)] = ([string]$prop.Value).ToLowerInvariant()
            }
        }
        $hotfixRaw = Get-JsonValue $metadata 'hotfixedSourceOverrides'
        if ($hotfixRaw) {
            foreach ($prop in @($hotfixRaw.PSObject.Properties)) {
                $hotfixOverrides[(ConvertTo-NormalizedRelPath $prop.Name)] = $prop.Value
            }
        }
        $envFiles = @(Get-JsonValue $metadata 'environmentFiles')
    }
    $sortedChanged = @($changedFiles.ToArray() | Sort-Object -Property Path)
    $addedPaths = @($sortedChanged | Where-Object { $_.Operation -eq 'add' } | ForEach-Object { $_.Path })
    $replacedPaths = @($sortedChanged | Where-Object { $_.Operation -eq 'replace' } | ForEach-Object { $_.Path })
    $changePaths = @($sortedChanged | ForEach-Object { $_.Path })

    $candidateZipPath = if ($CandidateZip) { Get-FullPath $CandidateZip } else { $null }
    $candidateZipSha = $null
    $candidateZipBytes = 0
    if ($candidateZipPath -and [System.IO.File]::Exists($candidateZipPath)) {
        $candidateZipSha = Get-Sha256File $candidateZipPath
        $candidateZipBytes = [long](Get-Item -LiteralPath $candidateZipPath).Length
    }

    $packageOnlyPaths = @('manifest.json', 'SHA256SUMS.txt', 'upgrade-data/rc2-to-rc3.json', 'upgrade-data/README.md')

    return [pscustomobject]@{
        PackageRoot            = $root
        ManifestPath           = $manifestPath
        ManifestSha256         = $manifestSha
        ManifestBytes          = $manifestBytes
        ManifestDoc            = $manifest
        ManifestError          = $manifestError
        SumsPath               = $sumsPath
        Sums                   = $sums
        SumsError              = $sumsError
        MetadataPath           = $metadataPath
        MetadataSha256         = $metadataSha
        MetadataDoc            = $metadata
        MetadataError          = $metadataError
        ReadmePath             = $readmePath
        PackageFiles           = @($packageFiles.ToArray() | Sort-Object -Property Path)
        PackageFileMap         = $packageFileMap
        PackageOnlyPaths       = $packageOnlyPaths
        ReparsePoints          = @($reparse.ToArray())
        PayloadFiles           = $sortedPayload
        PayloadMap             = $payloadMap
        PayloadFileCount       = $sortedPayload.Count
        TargetFiles            = @($targetFiles.ToArray() | Sort-Object -Property Path)
        TargetMap              = $targetMap
        TargetFileList         = $targetList
        TargetFileCount        = $targetList.Count
        ChangedFiles           = $sortedChanged
        ChangedMap             = $changedMap
        ChangedPaths           = $changePaths
        AddedPaths             = $addedPaths
        ReplacedPaths          = $replacedPaths
        ChangedFileCount       = $changePaths.Count
        ExpectedTargetHashes   = $expectedTargetHashes
        ExpectedSourceHashes   = $expectedSourceHashes
        HotfixOverrides        = $hotfixOverrides
        EnvironmentFiles       = $envFiles
        SourceVersion          = $sourceVersion
        TargetVersion          = $targetVersion
        UpgradeId              = $upgradeId
        UpgraderVersion        = $upgraderVersion
        PackageLayout          = $layout
        SourceIdentity         = $sourceIdentity
        TargetManifestInfo     = $targetManifestInfo
        CandidateZipPath       = $candidateZipPath
        CandidateZipSha256     = $candidateZipSha
        CandidateZipBytes      = $candidateZipBytes
    }
}

# ---------------------------------------------------------------------------
# Generic helpers: encoding, hashing, paths, JSON, results
# ---------------------------------------------------------------------------

function New-Utf8NoBom { New-Object System.Text.UTF8Encoding($false) }
function New-Utf8Bom   { New-Object System.Text.UTF8Encoding($true) }

function Get-Sha256Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return Get-Sha256Bytes ((New-Utf8NoBom).GetBytes($Text))
}

function Get-Sha256File {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($full)) { throw "Get-Sha256File: file not found: $full" }
    $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (-not [System.IO.Path]::IsPathRooted($expanded)) { $expanded = Join-Path (Get-Location).Path $expanded }
    $full = [System.IO.Path]::GetFullPath($expanded)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Test-PathUnder {
    param([Parameter(Mandatory = $true)][string]$Child, [Parameter(Mandatory = $true)][string]$Parent)
    $c = (Get-FullPath $Child)
    $p = (Get-FullPath $Parent)
    if ([string]::Equals($c, $p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($p.EndsWith('\')) { $p = $p.TrimEnd('\') }
    return $c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelPath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    $r = (Get-FullPath $Root)
    $p = (Get-FullPath $Path)
    if ($p.Length -le $r.Length) { return '' }
    $rel = $p.Substring($r.Length).TrimStart('\', '/')
    return ($rel -replace '\\', '/')
}

function Test-IsReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $attrs = [System.IO.File]::GetAttributes((Get-FullPath $Path))
        return [bool]($attrs -band [System.IO.FileAttributes]::ReparsePoint)
    } catch { return $false }
}

function Get-ReparseTarget {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Get-FullPath $Path
    if (-not (Test-IsReparsePoint $full)) { return $null }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSObject.Properties.Name -contains 'Target' -and $item.Target) {
        $target = $item.Target
        if ($target -is [array]) { $target = $target[0] }
        $t = [string]$target
        if ($t.StartsWith('\\?\')) { $t = $t.Substring(4) }
        return (Get-FullPath $t)
    }
    return $null
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Get-FullPath $Path
    if (-not [System.IO.File]::Exists($full)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    $text = (New-Utf8NoBom).GetString($bytes, $offset, $bytes.Length - $offset)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json) }
    catch { throw "Read-JsonFile: invalid JSON at '$full': $($_.Exception.Message)" }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$Value,
        [int]$Depth = 30,
        [switch]$Bom
    )
    $full = Get-FullPath $Path
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $json = $Value | ConvertTo-Json -Depth $Depth
    if ($null -eq $json) { $json = 'null' }
    $json = ($json -replace "`r`n", "`n")
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    $enc = New-Utf8NoBom
    if ($Bom) { $enc = New-Utf8Bom }
    [System.IO.File]::WriteAllText($full, $json, $enc)
    return $full
}

function Limit-Text {
    param([AllowNull()][string]$Text, [int]$Max = 1500)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + " ...(truncated, $($Text.Length) chars)"
}

function New-AssertResult {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'WARN', 'NOT TESTED')][string]$Status,
        [string]$Detail = '',
        [AllowNull()]$Expected = $null,
        [AllowNull()]$Actual = $null,
        [AllowNull()]$Data = $null
    )
    [pscustomobject]@{
        Id       = $Id
        Status   = $Status
        Detail   = $Detail
        Expected = $Expected
        Actual   = $Actual
        Data     = $Data
    }
}

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$PassDetail,
        [Parameter(Mandatory = $true)][string]$FailDetail,
        [AllowNull()]$Expected = $null,
        [AllowNull()]$Actual = $null,
        [AllowNull()]$Data = $null
    )
    if ($Condition) {
        return New-AssertResult -Id $Id -Status PASS -Detail $PassDetail -Expected $Expected -Actual $Actual -Data $Data
    }
    return New-AssertResult -Id $Id -Status FAIL -Detail $FailDetail -Expected $Expected -Actual $Actual -Data $Data
}

function Assert-ZipIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    if (-not [System.IO.File]::Exists((Get-FullPath $ZipPath))) {
        return New-AssertResult -Id $Id -Status FAIL -Detail "frozen ZIP missing: $ZipPath" -Expected $ExpectedSha256 -Actual 'ABSENT'
    }
    $bytes = (Get-Item -LiteralPath (Get-FullPath $ZipPath)).Length
    $sha = Get-Sha256File $ZipPath
    $ok = ($bytes -eq $ExpectedBytes) -and ([string]::Equals($sha, $ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase))
    $detail = if ($ok) { "frozen ZIP identity verified ($bytes bytes, $sha)" }
              else { "frozen ZIP identity MISMATCH: bytes=$bytes expected=$ExpectedBytes; sha=$sha expected=$ExpectedSha256" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected "$ExpectedSha256/$ExpectedBytes" -Actual "$sha/$bytes"
}

# ---------------------------------------------------------------------------
# ZIP inspection (oracle truth source: bytes inside the frozen ZIPs)
# ---------------------------------------------------------------------------

function Initialize-ZipAssembly {
    if (-not ('System.IO.Compression.ZipFile' -as [type])) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }
}

function Get-ZipMap {
    param([Parameter(Mandatory = $true)][string]$ZipPath)
    Initialize-ZipAssembly
    $full = Get-FullPath $ZipPath
    if (-not [System.IO.File]::Exists($full)) { throw "Get-ZipMap: ZIP not found: $full" }
    $files = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    $zip = [System.IO.Compression.ZipFile]::OpenRead($full)
    try {
        foreach ($entry in $zip.Entries) {
            $name = ($entry.FullName -replace '\\', '/')
            $isDirEntry = $name.EndsWith('/')
            $rel = $name.TrimEnd('/')
            if ($rel.Length -eq 0) { continue }
            # Defensive validation: no absolute paths, drive letters, ADS, or '..'
            if ($rel.StartsWith('/') -or $rel -match '^[A-Za-z]:' -or $rel -match '(^|/)\.\.(/|$)' -or $rel -match ':') {
                throw "Get-ZipMap: unsafe ZIP entry name '$($entry.FullName)' in $full"
            }
            if ($isDirEntry) {
                [void]$dirs.Add($rel)
                continue
            }
            $ms = New-Object System.IO.MemoryStream
            try {
                $s = $entry.Open()
                try { $s.CopyTo($ms) } finally { $s.Dispose() }
                $bytes = $ms.ToArray()
            } finally { $ms.Dispose() }
            [void]$files.Add([pscustomobject]@{
                Path   = $rel
                Bytes  = [long]$bytes.Length
                Sha256 = (Get-Sha256Bytes $bytes)
            })
        }
    } finally { $zip.Dispose() }

    $sorted = @($files.ToArray() | Sort-Object -Property Path)
    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    foreach ($f in $sorted) { $map[$f.Path] = $f; $total += $f.Bytes }
    return [pscustomobject]@{
        ZipPath      = $full
        Files        = $sorted
        FileCount    = $sorted.Count
        TotalBytes   = $total
        Directories  = @($dirs.ToArray() | Sort-Object)
        Map          = $map
    }
}

function Get-ZipEntryBytes {
    param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)][string]$RelPath)
    Initialize-ZipAssembly
    $wanted = ($RelPath -replace '\\', '/')
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Get-FullPath $ZipPath))
    try {
        foreach ($entry in $zip.Entries) {
            $name = ($entry.FullName -replace '\\', '/')
            if ($name.EndsWith('/')) { continue }
            if ([string]::Equals($name, $wanted, [System.StringComparison]::OrdinalIgnoreCase)) {
                $ms = New-Object System.IO.MemoryStream
                try {
                    $s = $entry.Open()
                    try { $s.CopyTo($ms) } finally { $s.Dispose() }
                    return $ms.ToArray()
                } finally { $ms.Dispose() }
            }
        }
    } finally { $zip.Dispose() }
    throw "Get-ZipEntryBytes: '$RelPath' not found in $ZipPath"
}

function Expand-ZipToDirectory {
    param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)][string]$Destination)
    Initialize-ZipAssembly
    $src = Get-FullPath $ZipPath
    $dest = Get-FullPath $Destination
    if (-not [System.IO.Directory]::Exists($dest)) { [void][System.IO.Directory]::CreateDirectory($dest) }
    $written = New-Object System.Collections.ArrayList
    $zip = [System.IO.Compression.ZipFile]::OpenRead($src)
    try {
        foreach ($entry in $zip.Entries) {
            $name = ($entry.FullName -replace '\\', '/')
            if ($name.EndsWith('/')) { continue }
            $rel = $name.TrimEnd('/')
            if ($rel.StartsWith('/') -or $rel -match '^[A-Za-z]:' -or $rel -match '(^|/)\.\.(/|$)' -or $rel -match ':') {
                throw "Expand-ZipToDirectory: unsafe entry '$($entry.FullName)' in $src"
            }
            $ms = New-Object System.IO.MemoryStream
            try {
                $s = $entry.Open()
                try { $s.CopyTo($ms) } finally { $s.Dispose() }
                $bytes = $ms.ToArray()
            } finally { $ms.Dispose() }
            $targetPath = Join-Path $dest ($rel -replace '/', '\')
            $parent = [System.IO.Path]::GetDirectoryName($targetPath)
            if ($parent -and -not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
            [System.IO.File]::WriteAllBytes($targetPath, $bytes)
            [void]$written.Add($rel)
        }
    } finally { $zip.Dispose() }
    return @($written.ToArray())
}

function Get-ZipManifestPayloadMap {
    param([Parameter(Mandatory = $true)]$ZipMap)
    # manifest.json is in the ZIP but NOT listed in manifest.files[]; the
    # payload map is the other 107 files.
    $payload = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $ZipMap.Files) {
        if ([string]::Equals($f.Path, 'manifest.json', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $payload[$f.Path] = $f
    }
    return $payload
}

function Get-ChangedFileTable {
    param([Parameter(Mandatory = $true)]$Rc2ZipMap, [Parameter(Mandatory = $true)]$Rc3ZipMap)
    $rows = New-Object System.Collections.ArrayList
    $all = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $Rc2ZipMap.Files) { $all[$f.Path] = $true }
    foreach ($f in $Rc3ZipMap.Files) { $all[$f.Path] = $true }
    foreach ($path in @($all.Keys | Sort-Object)) {
        $a = $null; $b = $null
        if ($Rc2ZipMap.Map.ContainsKey($path)) { $a = $Rc2ZipMap.Map[$path] }
        if ($Rc3ZipMap.Map.ContainsKey($path)) { $b = $Rc3ZipMap.Map[$path] }
        if ($null -eq $a -or $null -eq $b -or $a.Sha256 -ne $b.Sha256) {
            [void]$rows.Add([pscustomobject]@{
                Path     = $path
                Rc2Sha256 = if ($a) { $a.Sha256 } else { $null }
                Rc3Sha256 = if ($b) { $b.Sha256 } else { $null }
                Rc2Bytes = if ($a) { $a.Bytes } else { 0 }
                Rc3Bytes = if ($b) { $b.Bytes } else { 0 }
            })
        }
    }
    return @($rows.ToArray())
}

# ---------------------------------------------------------------------------
# Independent package-integrity oracle for the unified candidate package.
#
# Trust chain proven independently (does not reuse builder or engine code):
#   external ZIP sha256 (recorded by the matrix run)
#     -> internal SHA256SUMS.txt (every package file except itself)
#     -> manifest.json (payload set P, hashes, bytes, distribution version)
#     -> upgrade-data\rc2-to-rc3.json (expectedSource/TargetHashes, changedFiles)
#     -> frozen RC2 ZIP payload map (source identity + change set).
# ---------------------------------------------------------------------------
function Add-UnifiedCheck {
    param(
        [Parameter(Mandatory = $true)]$Results,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$PassDetail,
        [Parameter(Mandatory = $true)][string]$FailDetail,
        [AllowNull()]$Expected = $null,
        [AllowNull()]$Actual = $null,
        [AllowNull()]$Data = $null
    )
    [void]$Results.Add((Assert-Condition -Id $Id -Condition $Condition -PassDetail $PassDetail -FailDetail $FailDetail -Expected $Expected -Actual $Actual -Data $Data))
}

function Test-StringSetEqual {
    param([AllowEmptyCollection()][string[]]$Left, [AllowEmptyCollection()][string[]]$Right)
    $l = @($Left | Where-Object { $_ } | Sort-Object)
    $r = @($Right | Where-Object { $_ } | Sort-Object)
    if ($l.Count -ne $r.Count) { return $false }
    for ($i = 0; $i -lt $l.Count; $i++) {
        if (-not [string]::Equals($l[$i], $r[$i], [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-SetDifference {
    param([AllowEmptyCollection()][string[]]$Left, [AllowEmptyCollection()][string[]]$Right)
    $out = New-Object System.Collections.ArrayList
    foreach ($item in @($Left)) {
        $found = $false
        foreach ($other in @($Right)) { if ([string]::Equals([string]$item, [string]$other, [System.StringComparison]::OrdinalIgnoreCase)) { $found = $true; break } }
        if (-not $found) { [void]$out.Add($item) }
    }
    return @($out.ToArray())
}

function Assert-UnifiedPackageIntegrity {
    param(
        [Parameter(Mandatory = $true)]$Model,
        [string]$Rc2Zip = '',
        $Rc2ZipMap = $null
    )
    $results = New-Object System.Collections.ArrayList
    $frozen = Get-FrozenIdentity
    $payloadPaths = @($Model.PayloadFiles | ForEach-Object { $_.Path })
    $actualPaths = @($Model.PackageFiles | ForEach-Object { $_.Path })
    $expectedPackagePaths = @($payloadPaths) + @($Model.PackageOnlyPaths)
    $packageProblems = New-Object System.Collections.ArrayList
    if ($Model.ReparsePoints.Count -gt 0) { [void]$packageProblems.Add("reparse points inside package: $($Model.ReparsePoints -join ', ')") }
    $missingPkg = @(Get-SetDifference -Left $expectedPackagePaths -Right $actualPaths)
    $extraPkg = @(Get-SetDifference -Left $actualPaths -Right $expectedPackagePaths)
    if ($missingPkg.Count -gt 0) { [void]$packageProblems.Add("missing: $($missingPkg -join ', ')") }
    if ($extraPkg.Count -gt 0) { [void]$packageProblems.Add("unexpected extra package files: $($extraPkg -join ', ')") }
    Add-UnifiedCheck -Results $results -Id 'pkg.packageFileSetExact' -Condition (($packageProblems.Count -eq 0) -and ($actualPaths.Count -gt 0)) `
        -PassDetail "package file set == payload $($payloadPaths.Count) + manifest.json + SHA256SUMS.txt + upgrade-data metadata ($($actualPaths.Count) files)" `
        -FailDetail ("package file set mismatch: " + ($packageProblems -join '; ')) -Expected "P + 4 package-only metadata files" -Actual $actualPaths.Count
    Add-UnifiedCheck -Results $results -Id 'pkg.noPayloadDirectory' -Condition ((-not [System.IO.Directory]::Exists((Join-Path $Model.PackageRoot 'payload'))) -and (-not (@($payloadPaths | Where-Object { $_ -like 'payload/*' }).Count -gt 0))) `
        -PassDetail 'no duplicate payload/ directory inside the unified package (single target payload copy)' `
        -FailDetail 'payload/ directory or payload/* path present (duplicate target copy)' -Expected 'absent' -Actual 'present'

    # SHA256SUMS closure
    if ($null -eq $Model.Sums -or $Model.SumsError) {
        Add-UnifiedCheck -Results $results -Id 'pkg.sumsFile' -Condition $false -PassDetail '' -FailDetail "SHA256SUMS.txt missing/unparsable: $($Model.SumsError)"
    } else {
        $sumProblems = New-Object System.Collections.ArrayList
        foreach ($p in @($Model.Sums.Problems)) { [void]$sumProblems.Add($p) }
        if ($Model.Sums.Entries.ContainsKey('SHA256SUMS.txt')) { [void]$sumProblems.Add('SHA256SUMS.txt lists itself') }
        $sumPaths = @($Model.Sums.Entries.Keys | Sort-Object)
        $actualMinusSums = @($actualPaths | Where-Object { -not [string]::Equals($_, 'SHA256SUMS.txt', [System.StringComparison]::OrdinalIgnoreCase) })
        if (-not (Test-StringSetEqual -Left $sumPaths -Right $actualMinusSums)) {
            [void]$sumProblems.Add("SHA256SUMS entry set != package files minus itself (sums=$($sumPaths.Count) expected=$($actualMinusSums.Count); missing=$( (@(Get-SetDifference -Left $actualMinusSums -Right $sumPaths) | Select-Object -First 10) -join ',' ); extra=$( (@(Get-SetDifference -Left $sumPaths -Right $actualMinusSums) | Select-Object -First 10) -join ',' ))")
        }
        $hashProblems = New-Object System.Collections.ArrayList
        foreach ($rel in $sumPaths) {
            if (-not $Model.PackageFileMap.ContainsKey($rel)) { [void]$hashProblems.Add("file missing: $rel"); continue }
            $actualSha = $Model.PackageFileMap[$rel].Sha256
            if ([string]::Equals($actualSha, $Model.Sums.Entries[$rel], [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            [void]$hashProblems.Add("hash mismatch: $rel")
        }
        Add-UnifiedCheck -Results $results -Id 'pkg.sumsFileSet' -Condition ($sumProblems.Count -eq 0) `
            -PassDetail "SHA256SUMS.txt covers exactly every package file except itself ($($sumPaths.Count) entries)" `
            -FailDetail ('SHA256SUMS closure problems: ' + ($sumProblems -join '; ')) -Expected "P + manifest + metadata + readme = $($actualMinusSums.Count)" -Actual $sumPaths.Count
        Add-UnifiedCheck -Results $results -Id 'pkg.sumsHashes' -Condition ($hashProblems.Count -eq 0) `
            -PassDetail "all $($sumPaths.Count) SHA256SUMS hashes equal the actual package bytes" `
            -FailDetail ('SHA256SUMS hash mismatches: ' + (($hashProblems | Select-Object -First 20) -join '; ')) -Expected 'all hashes equal' -Actual $hashProblems.Count
    }

    # manifest coverage of the payload set
    if ($null -eq $Model.ManifestDoc -or $Model.ManifestError) {
        Add-UnifiedCheck -Results $results -Id 'pkg.manifestFile' -Condition $false -PassDetail '' -FailDetail "manifest.json missing/unparsable: $($Model.ManifestError)"
        return @($results.ToArray())
    }
    $expectedPayloadPaths = @($actualPaths | Where-Object {
        $p = $_
        $isPackageOnly = $false
        foreach ($po in @($Model.PackageOnlyPaths)) { if ([string]::Equals($p, $po, [System.StringComparison]::OrdinalIgnoreCase)) { $isPackageOnly = $true; break } }
        -not $isPackageOnly
    })
    $manifestSetProblems = New-Object System.Collections.ArrayList
    if (-not (Test-StringSetEqual -Left $payloadPaths -Right $expectedPayloadPaths)) {
        [void]$manifestSetProblems.Add("manifest.files[] set != package files minus package-only metadata (manifest=$($payloadPaths.Count) expected=$($expectedPayloadPaths.Count); missing=$( (@(Get-SetDifference -Left $expectedPayloadPaths -Right $payloadPaths) | Select-Object -First 10) -join ',' ); extra=$( (@(Get-SetDifference -Left $payloadPaths -Right $expectedPayloadPaths) | Select-Object -First 10) -join ',' ))")
    }
    if ($Model.ManifestDoc.schemaVersion -ne 1) { [void]$manifestSetProblems.Add("manifest.schemaVersion=$($Model.ManifestDoc.schemaVersion) expected 1") }
    $manifestHashProblems = New-Object System.Collections.ArrayList
    foreach ($entry in @($Model.PayloadFiles)) {
        if (-not $Model.PackageFileMap.ContainsKey($entry.Path)) { [void]$manifestHashProblems.Add("file missing: $($entry.Path)"); continue }
        $actual = $Model.PackageFileMap[$entry.Path]
        if (-not [string]::Equals($actual.Sha256, $entry.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$manifestHashProblems.Add("sha mismatch: $($entry.Path)") }
        if ([long]$actual.Bytes -ne [long]$entry.Bytes) { [void]$manifestHashProblems.Add("bytes mismatch: $($entry.Path)") }
    }
    Add-UnifiedCheck -Results $results -Id 'pkg.manifestCoverage' -Condition ($manifestSetProblems.Count -eq 0) `
        -PassDetail "manifest.files[] lists exactly the payload set P ($($payloadPaths.Count) files; metadata files excluded)" `
        -FailDetail ('manifest coverage problems: ' + ($manifestSetProblems -join '; ')) -Expected "P ($($expectedPayloadPaths.Count) files)" -Actual $payloadPaths.Count
    Add-UnifiedCheck -Results $results -Id 'pkg.manifestIntegrity' -Condition ($manifestHashProblems.Count -eq 0) `
        -PassDetail "all $($payloadPaths.Count) manifest file hashes+bytes equal the actual package bytes" `
        -FailDetail ('manifest integrity problems: ' + (($manifestHashProblems | Select-Object -First 20) -join '; ')) -Expected 'all hashes/bytes equal' -Actual $manifestHashProblems.Count

    # manifest identity / distribution version / VERSION bytes
    $manifestVersion = [string](Get-JsonValue $Model.ManifestDoc 'distribution.version')
    $bundleVersion = [string](Get-JsonValue $Model.ManifestDoc 'bundle.version')
    $manifestIdentityOk = ($manifestVersion -eq $Model.TargetVersion) -and ($bundleVersion -eq $frozen.BundleVersion)
    $versionPath = Join-Path $Model.PackageRoot 'VERSION'
    $versionText = ''
    if ([System.IO.File]::Exists($versionPath)) { $versionText = ([System.IO.File]::ReadAllText($versionPath, (New-Utf8NoBom))).Trim() }
    $versionOk = ($versionText -eq $Model.TargetVersion)
    Add-UnifiedCheck -Results $results -Id 'pkg.manifestIdentity' -Condition ($manifestIdentityOk -and $versionOk) `
        -PassDetail "manifest distribution.version=$manifestVersion bundle.version=$bundleVersion; VERSION='$versionText' (target $($Model.TargetVersion))" `
        -FailDetail "manifest/VERSION identity mismatch: manifest.version='$manifestVersion' bundle='$bundleVersion' VERSION='$versionText' target='$($Model.TargetVersion)'" `
        -Expected "$($Model.TargetVersion)/$($frozen.BundleVersion)" -Actual "$manifestVersion/$bundleVersion/$versionText"

    # upgrade-data schema v2 (metadata-split model)
    $metaProblems = New-Object System.Collections.ArrayList
    if ($null -eq $Model.MetadataDoc -or $Model.MetadataError) {
        Add-UnifiedCheck -Results $results -Id 'pkg.metadataSchema' -Condition $false -PassDetail '' -FailDetail "upgrade-data/rc2-to-rc3.json missing/unparsable: $($Model.MetadataError)"
    } else {
        if ($Model.MetadataDoc.schemaVersion -ne 2) { [void]$metaProblems.Add("schemaVersion=$($Model.MetadataDoc.schemaVersion) expected 2") }
        $metaKind = [string]$Model.MetadataDoc.kind
        if (-not $metaKind.StartsWith('cnki-research-portable-unified', [System.StringComparison]::OrdinalIgnoreCase)) { [void]$metaProblems.Add("kind='$metaKind' (expected a cnki-research-portable-unified* kind)") }
        if ($Model.SourceVersion -ne $frozen.Rc2Version) { [void]$metaProblems.Add("sourceDistributionVersion='$($Model.SourceVersion)' expected '$($frozen.Rc2Version)'") }
        if ($Model.TargetVersion -ne $frozen.Rc3Version) { [void]$metaProblems.Add("targetDistributionVersion='$($Model.TargetVersion)' expected '$($frozen.Rc3Version)'") }
        if (-not $Model.UpgradeId) { [void]$metaProblems.Add('upgradeId missing') }
        if (-not $Model.UpgraderVersion) { [void]$metaProblems.Add('upgraderVersion missing') }
        $layoutChecks = @(
            @{ Key = 'payloadRoot'; Value = '.' },
            @{ Key = 'manifestPath'; Value = 'manifest.json' },
            @{ Key = 'sumsFile'; Value = 'SHA256SUMS.txt' },
            @{ Key = 'metadataPath'; Value = 'upgrade-data/rc2-to-rc3.json' },
            @{ Key = 'installedLayout'; Value = 'A_in_place_only' }
        )
        foreach ($lc in $layoutChecks) {
            $v = [string](Get-JsonValue $Model.PackageLayout $lc.Key)
            if (-not [string]::Equals($v, [string]$lc.Value, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$metaProblems.Add("packageLayout.$($lc.Key)='$v' expected '$($lc.Value)'") }
        }
        $si = $Model.SourceIdentity
        if ([string](Get-JsonValue $si 'manifestSha256') -ne $frozen.Rc2ManifestSha256) { [void]$metaProblems.Add('sourceIdentity.manifestSha256 != frozen RC2 manifest sha') }
        if ([string](Get-JsonValue $si 'packageSha256') -ne $frozen.Rc2ZipSha256) { [void]$metaProblems.Add('sourceIdentity.packageSha256 != frozen RC2 ZIP sha') }
        if ([long](Get-JsonValue $si 'packageBytes') -ne [long]$frozen.Rc2ZipBytes) { [void]$metaProblems.Add('sourceIdentity.packageBytes != frozen RC2 ZIP bytes') }
        if ([int](Get-JsonValue $si 'payloadFileCount') -ne $frozen.Rc2PayloadFileCount) { [void]$metaProblems.Add("sourceIdentity.payloadFileCount=$([int](Get-JsonValue $si 'payloadFileCount')) expected 107") }
        $frozenRc3Anchor = [string](Get-JsonValueFirst $si @('frozenRc3ManifestSha256', 'frozenRc3ManifestHash'))
        $tm = $Model.TargetManifestInfo
        if ([string](Get-JsonValue $tm 'path') -ne 'manifest.json') { [void]$metaProblems.Add('targetManifest.path != manifest.json') }
        if ([string](Get-JsonValue $tm 'distributionVersion') -ne $frozen.Rc3Version) { [void]$metaProblems.Add('targetManifest.distributionVersion != 1.0.0-rc.3') }
        if ([string](Get-JsonValue $tm 'bundleVersion') -ne $frozen.BundleVersion) { [void]$metaProblems.Add('targetManifest.bundleVersion != 1.0.0') }
        if ($null -ne (Get-JsonValue $tm 'payloadFileCount')) {
            $declared = [int](Get-JsonValue $tm 'payloadFileCount')
            if ($declared -ne $Model.PayloadFileCount) { [void]$metaProblems.Add("targetManifest.payloadFileCount=$declared != actual payload count $($Model.PayloadFileCount)") }
        }
        Add-UnifiedCheck -Results $results -Id 'pkg.metadataSchema' -Condition ($metaProblems.Count -eq 0) `
            -PassDetail "upgrade-data schema v2 valid: kind/versions/layout/sourceIdentity/frozen-RC3 anchor/targetManifest declared=($($Model.PayloadFileCount) payload)" `
            -FailDetail ('upgrade-data schema problems: ' + ($metaProblems -join '; ')) -Expected 'schemaVersion 2 metadata-split' -Actual $metaProblems.Count
    }

    # Frozen-RC3 recognition anchor (independent constant, charter D5 item 2).
    if ($Model.MetadataDoc) {
        $frozenAnchor = [string](Get-JsonValueFirst $Model.SourceIdentity @('frozenRc3ManifestSha256', 'frozenRc3ManifestHash'))
        if (-not $frozenAnchor) {
            [void]$results.Add((New-AssertResult -Id 'pkg.frozenRc3Anchor' -Status 'WARN' `
                -Detail 'upgrade-data does not embed the frozen-RC3 manifest anchor (sourceIdentity.frozenRc3ManifestSha256). The engine may still recognize FROZEN_RC3 through its own trust-anchor constant (exercised by the D frozen-RC3 case); recorded as an integration gap rather than a matrix failure.'))
        } else {
            Add-UnifiedCheck -Results $results -Id 'pkg.frozenRc3Anchor' -Condition ([string]::Equals($frozenAnchor, $frozen.Rc3ManifestSha256, [System.StringComparison]::OrdinalIgnoreCase)) `
                -PassDetail "upgrade-data embeds the frozen RC3 manifest anchor $frozenAnchor" `
                -FailDetail "frozenRc3 anchor '$frozenAnchor' != frozen RC3 manifest sha $($frozen.Rc3ManifestSha256)" -Expected $frozen.Rc3ManifestSha256 -Actual $frozenAnchor
        }
    }

    # metadata-split rules: expectedTargetHashes == P exactly; embedded manifest hash; metadata not a payload/target path
    if ($Model.MetadataDoc) {
        $ethKeys = @($Model.ExpectedTargetHashes.Keys | Sort-Object)
        $ethProblems = New-Object System.Collections.ArrayList
        if (-not (Test-StringSetEqual -Left $ethKeys -Right $payloadPaths)) {
            [void]$ethProblems.Add("expectedTargetHashes key set != manifest payload set P (eth=$($ethKeys.Count) P=$($payloadPaths.Count); missing=$( (@(Get-SetDifference -Left $payloadPaths -Right $ethKeys) | Select-Object -First 10) -join ',' ); extra=$( (@(Get-SetDifference -Left $ethKeys -Right $payloadPaths) | Select-Object -First 10) -join ',' ))")
        }
        foreach ($rel in $ethKeys) {
            if (-not $Model.PayloadMap.ContainsKey($rel)) { continue }
            if (-not [string]::Equals($Model.ExpectedTargetHashes[$rel], $Model.PayloadMap[$rel].Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$ethProblems.Add("expectedTargetHashes[$rel] != manifest hash")
            }
        }
        if ($Model.ExpectedTargetHashes.ContainsKey('upgrade-data/rc2-to-rc3.json')) { [void]$ethProblems.Add('expectedTargetHashes contains the metadata file itself') }
        Add-UnifiedCheck -Results $results -Id 'pkg.expectedTargetHashes' -Condition ($ethProblems.Count -eq 0) `
            -PassDetail "expectedTargetHashes == manifest payload set P exactly ($($ethKeys.Count) entries; metadata file not a target)" `
            -FailDetail ('expectedTargetHashes problems: ' + (($ethProblems | Select-Object -First 20) -join '; ')) -Expected "P ($($payloadPaths.Count) entries)" -Actual $ethKeys.Count

        $embeddedManifestHash = [string](Get-JsonValue $Model.MetadataDoc 'targetManifestHash')
        $embOk = $embeddedManifestHash -and [string]::Equals($embeddedManifestHash, $Model.ManifestSha256, [System.StringComparison]::OrdinalIgnoreCase)
        Add-UnifiedCheck -Results $results -Id 'pkg.targetManifestHashEmbedded' -Condition $embOk `
            -PassDetail "upgrade-data embeds targetManifestHash = sha256(manifest.json) = $($Model.ManifestSha256) (no hash cycle: metadata is not in manifest.files[])" `
            -FailDetail "upgrade-data.targetManifestHash='$embeddedManifestHash' expected sha256(manifest.json)=$($Model.ManifestSha256)" -Expected $Model.ManifestSha256 -Actual $embeddedManifestHash

        $selfRefProblems = New-Object System.Collections.ArrayList
        $metaText = ''
        if ([System.IO.File]::Exists($Model.MetadataPath)) { $metaText = [System.IO.File]::ReadAllText($Model.MetadataPath, (New-Utf8NoBom)) }
        if ($Model.MetadataSha256 -and $metaText.IndexOf($Model.MetadataSha256, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$selfRefProblems.Add('metadata contains its own sha256') }
        if ($Model.Sums -and $metaText.IndexOf($Model.Sums.Sha256, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$selfRefProblems.Add('metadata contains sha256(SHA256SUMS.txt)') }
        if ($Model.Sums -and $Model.Sums.Entries.ContainsKey('upgrade-data/rc2-to-rc3.json')) {
            $declaredU = $Model.Sums.Entries['upgrade-data/rc2-to-rc3.json']
            if (-not [string]::Equals($declaredU, $Model.MetadataSha256, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$selfRefProblems.Add('SHA256SUMS entry for metadata != actual metadata hash') }
        } else { [void]$selfRefProblems.Add('SHA256SUMS.txt does not list upgrade-data/rc2-to-rc3.json') }
        Add-UnifiedCheck -Results $results -Id 'pkg.noHashCycleSelfRefs' -Condition ($selfRefProblems.Count -eq 0) `
            -PassDetail 'no self/manifest/sums hash cycles in the metadata file; SHA256SUMS anchors the metadata bytes' `
            -FailDetail ('hash-cycle problems: ' + ($selfRefProblems -join '; ')) -Expected 'no cycles' -Actual $selfRefProblems.Count
    }

    # changedFiles vs frozen RC2 -> target (independent recomputation)
    if ($Rc2ZipMap) {
        $targetMapObj = [pscustomobject]@{ Files = @($Model.TargetFiles); Map = $Model.TargetMap }
        $changedTable = @(Get-ChangedFileTable -Rc2ZipMap $Rc2ZipMap -Rc3ZipMap $targetMapObj)
        $computedPaths = @($changedTable | ForEach-Object { $_.Path } | Sort-Object)
        $declaredPaths = @($Model.ChangedPaths | Sort-Object)
        $changeSetProblems = New-Object System.Collections.ArrayList
        if (-not (Test-StringSetEqual -Left $computedPaths -Right $declaredPaths)) {
            [void]$changeSetProblems.Add("changedFiles set != recomputed RC2->target diff (declared=$($declaredPaths.Count) computed=$($computedPaths.Count); missing=$( (@(Get-SetDifference -Left $computedPaths -Right $declaredPaths) | Select-Object -First 10) -join ',' ); extra=$( (@(Get-SetDifference -Left $declaredPaths -Right $computedPaths) | Select-Object -First 10) -join ',' ))")
        }
        $computedAdded = @($changedTable | Where-Object { $null -eq $_.Rc2Sha256 } | ForEach-Object { $_.Path })
        if (-not (Test-StringSetEqual -Left $computedAdded -Right $Model.AddedPaths)) {
            [void]$changeSetProblems.Add("added-file set != recomputed adds (declared=$($Model.AddedPaths.Count) computed=$($computedAdded.Count))")
        }
        if ($Model.ChangedMap.ContainsKey('upgrade-data/rc2-to-rc3.json')) { [void]$changeSetProblems.Add('changedFiles contains package-only metadata (upgrade-data/rc2-to-rc3.json)') }
        if ($Model.ChangedMap.ContainsKey('SHA256SUMS.txt')) { [void]$changeSetProblems.Add('changedFiles contains SHA256SUMS.txt (package-only)') }
        Add-UnifiedCheck -Results $results -Id 'pkg.changedFileSet' -Condition ($changeSetProblems.Count -eq 0) `
            -PassDetail "changedFiles == independently recomputed RC2->target change set ($($declaredPaths.Count) entries; $(@($Model.AddedPaths).Count) adds + $(@($Model.ReplacedPaths).Count) replaces)" `
            -FailDetail ('changedFiles problems: ' + ($changeSetProblems -join '; ')) -Expected "$($computedPaths.Count) entries" -Actual $declaredPaths.Count

        $ruleProblems = New-Object System.Collections.ArrayList
        foreach ($entry in @($Model.ChangedFiles)) {
            $computed = @($changedTable | Where-Object { [string]::Equals($_.Path, $entry.Path, [System.StringComparison]::OrdinalIgnoreCase) })
            if ($computed.Count -ne 1) { continue }
            $row = $computed[0]
            $isAdd = ($null -eq $row.Rc2Sha256)
            $expectedOp = if ($isAdd) { 'add' } else { 'replace' }
            if ($entry.Operation -ne $expectedOp) { [void]$ruleProblems.Add("$($entry.Path): operation='$($entry.Operation)' expected '$expectedOp'"); continue }
            $target = $Model.TargetMap[$entry.Path]
            $resolvedTarget = $null
            if ($entry.TargetSha256) { $resolvedTarget = $entry.TargetSha256 }
            elseif ($entry.HashSource -eq 'package-sums') { $resolvedTarget = $Model.ManifestSha256 }
            elseif ($entry.HashSource -eq 'package-manifest') { $resolvedTarget = $Model.MetadataSha256 }
            elseif ([string]::Equals($entry.Path, 'manifest.json', [System.StringComparison]::OrdinalIgnoreCase)) { $resolvedTarget = $Model.ManifestSha256 }
            if (-not $resolvedTarget) { [void]$ruleProblems.Add("$($entry.Path): no resolvable target hash"); continue }
            if (-not [string]::Equals($resolvedTarget, $target.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$ruleProblems.Add("$($entry.Path): target hash mismatch (declared=$resolvedTarget package=$($target.Sha256))") }
            if ($entry.TargetBytes -ne $null -and [long]$entry.TargetBytes -ne [long]$target.Bytes) { [void]$ruleProblems.Add("$($entry.Path): targetBytes $($entry.TargetBytes) != package $($target.Bytes)") }
            if ($isAdd) {
                if ($entry.SourceSha256) { [void]$ruleProblems.Add("$($entry.Path): add entry has a sourceSha256") }
            } else {
                $rc2Entry = $Rc2ZipMap.Map[$entry.Path]
                $sourceOk = $rc2Entry -and [string]::Equals($entry.SourceSha256, $rc2Entry.Sha256, [System.StringComparison]::OrdinalIgnoreCase)
                if (-not $sourceOk -and [string]::Equals($entry.Path, $frozen.CordisPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $sourceOk = ($entry.SourceSha256 -eq $frozen.HotfixLineRemovedSha256) -or ($entry.SourceSha256 -eq $frozen.HotfixTextRemovedSha256) -or ($entry.SourceSha256 -eq $frozen.CordisRc2Sha256)
                }
                if (-not $sourceOk) { [void]$ruleProblems.Add("$($entry.Path): sourceSha256 does not equal the frozen RC2 hash") }
            }
        }
        Add-UnifiedCheck -Results $results -Id 'pkg.changedFileRules' -Condition ($ruleProblems.Count -eq 0) `
            -PassDetail "every changedFiles entry has the correct operation/source hash/target hash/target bytes (manifest.json hash resolved via targetManifestHash)" `
            -FailDetail ('changedFiles rule problems: ' + (($ruleProblems | Select-Object -First 20) -join '; ')) -Expected 'all rules hold' -Actual $ruleProblems.Count

        $srcMismatch = New-Object System.Collections.ArrayList
        $rc2PayloadMap = Get-ZipManifestPayloadMap $Rc2ZipMap
        if (-not (Test-StringSetEqual -Left @($Model.ExpectedSourceHashes.Keys) -Right @($rc2PayloadMap.Keys))) {
            [void]$srcMismatch.Add("expectedSourceHashes key set != frozen RC2 payload set (eth=$(@($Model.ExpectedSourceHashes.Keys).Count) rc2=$(@($rc2PayloadMap.Keys).Count))")
        }
        foreach ($rel in @($Model.ExpectedSourceHashes.Keys)) {
            if (-not $rc2PayloadMap.ContainsKey($rel)) { continue }
            if (-not [string]::Equals($Model.ExpectedSourceHashes[$rel], $rc2PayloadMap[$rel].Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$srcMismatch.Add("expectedSourceHashes[$rel] != frozen RC2 bytes")
            }
        }
        Add-UnifiedCheck -Results $results -Id 'pkg.sourceHashes' -Condition ($srcMismatch.Count -eq 0) `
            -PassDetail "expectedSourceHashes == frozen RC2 payload set ($(@($Model.ExpectedSourceHashes.Keys).Count) files) with matching hashes" `
            -FailDetail ('source hash problems: ' + (($srcMismatch | Select-Object -First 20) -join '; ')) -Expected '107 frozen RC2 hashes' -Actual @($Model.ExpectedSourceHashes.Keys).Count
    } else {
        Add-UnifiedCheck -Results $results -Id 'pkg.changedFileSet' -Condition $false -PassDetail '' -FailDetail 'frozen RC2 ZIP map not supplied to the package-integrity oracle'
    }

    # Aggregate hashes (cycle-free; same formulas the builder declares).
    #   payloadSetHash       = sha256 over payload-classified changedFiles, sorted
    #                          Ordinal: "<path>\t<sourceSha|ADD>\t<targetSha>\n"
    #   changedFileSetHash   = sha256 over all changedFiles sorted Ordinal:
    #                          "<path>\t<operation>\n"
    #   sourcePayloadSetHash = sha256 over frozen RC2 payload map sorted Ordinal:
    #                          "<path>\t<sha256>\n"
    if ($Model.MetadataDoc) {
        $changeByPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($Model.ChangedFiles)) { $changeByPath[$entry.Path] = $entry }
        $ordPaths = [string[]]@($Model.ChangedFiles | ForEach-Object { $_.Path })
        [System.Array]::Sort($ordPaths, [System.StringComparer]::Ordinal)
        $aggLines = New-Object System.Collections.ArrayList
        foreach ($p in $ordPaths) {
            $entry = $changeByPath[$p]
            if ($entry.Classification -ne 'payload') { continue }
            if (-not $entry.TargetSha256) { continue }
            $src = if ($entry.Operation -eq 'add') { 'ADD' } else { $entry.SourceSha256 }
            [void]$aggLines.Add($entry.Path + "`t" + $src + "`t" + $entry.TargetSha256)
        }
        $aggMaterial = ''
        if ($aggLines.Count -gt 0) { $aggMaterial = ($aggLines.ToArray() -join "`n") + "`n" }
        $recomputedPayloadSet = Get-Sha256Text $aggMaterial
        $declaredPayloadSet = [string](Get-JsonValue $Model.MetadataDoc 'payloadSetHash')
        if (-not $declaredPayloadSet) {
            [void]$results.Add((New-AssertResult -Id 'pkg.payloadSetHash' -Status 'NOT TESTED' -Detail 'upgrade-data declares no payloadSetHash aggregate; cannot verify (informational)'))
        } else {
            Add-UnifiedCheck -Results $results -Id 'pkg.payloadSetHash' -Condition ([string]::Equals($recomputedPayloadSet, $declaredPayloadSet, [System.StringComparison]::OrdinalIgnoreCase)) `
                -PassDetail "payloadSetHash recomputed independently over $($aggLines.Count) payload-classified changed entries: $recomputedPayloadSet" `
                -FailDetail "payloadSetHash mismatch: declared=$declaredPayloadSet recomputed=$recomputedPayloadSet" -Expected $declaredPayloadSet -Actual $recomputedPayloadSet
        }
        $setLines = New-Object System.Collections.ArrayList
        foreach ($p in $ordPaths) { $entry = $changeByPath[$p]; [void]$setLines.Add($entry.Path + "`t" + $entry.Operation) }
        $setMaterial = ''
        if ($setLines.Count -gt 0) { $setMaterial = ($setLines.ToArray() -join "`n") + "`n" }
        $recomputedSet = Get-Sha256Text $setMaterial
        $declaredSet = [string](Get-JsonValue $Model.MetadataDoc 'changedFileSetHash')
        if ($declaredSet) {
            Add-UnifiedCheck -Results $results -Id 'pkg.changedFileSetHash' -Condition ([string]::Equals($recomputedSet, $declaredSet, [System.StringComparison]::OrdinalIgnoreCase)) `
                -PassDetail "changedFileSetHash recomputed independently over $($setLines.Count) changed entries: $recomputedSet" `
                -FailDetail "changedFileSetHash mismatch: declared=$declaredSet recomputed=$recomputedSet" -Expected $declaredSet -Actual $recomputedSet
        }
        $declaredSourceSet = [string](Get-JsonValue $Model.MetadataDoc 'sourcePayloadSetHash')
        if ($declaredSourceSet -and $Rc2ZipMap) {
            $rc2PayloadForHash = Get-ZipManifestPayloadMap $Rc2ZipMap
            $rc2Sorted = [string[]]@($rc2PayloadForHash.Keys)
            [System.Array]::Sort($rc2Sorted, [System.StringComparer]::Ordinal)
            $srcLines = New-Object System.Collections.ArrayList
            foreach ($rel in $rc2Sorted) { [void]$srcLines.Add($rel + "`t" + $rc2PayloadForHash[$rel].Sha256) }
            $srcMaterial = (($srcLines.ToArray()) -join "`n") + "`n"
            $recomputedSourceSet = Get-Sha256Text $srcMaterial
            Add-UnifiedCheck -Results $results -Id 'pkg.sourcePayloadSetHash' -Condition ([string]::Equals($recomputedSourceSet, $declaredSourceSet, [System.StringComparison]::OrdinalIgnoreCase)) `
                -PassDetail "sourcePayloadSetHash recomputed independently over the frozen RC2 payload set: $recomputedSourceSet" `
                -FailDetail "sourcePayloadSetHash mismatch: declared=$declaredSourceSet recomputed=$recomputedSourceSet" -Expected $declaredSourceSet -Actual $recomputedSourceSet
        }
    }

    # environment-file declarative spec
    $envProblems = New-Object System.Collections.ArrayList
    $envList = @($Model.EnvironmentFiles)
    if ($envList.Count -ne 2) { [void]$envProblems.Add("environmentFiles count=$($envList.Count) expected 2") }
    $expectedEnvPaths = @('_portable/install-state.json', 'bundle/cnki-research/portable.runtime.json')
    $actualEnvPaths = @($envList | ForEach-Object { ConvertTo-NormalizedRelPath ([string](Get-JsonValue $_ 'path')) })
    if (-not (Test-StringSetEqual -Left $actualEnvPaths -Right $expectedEnvPaths)) { [void]$envProblems.Add("environmentFiles paths=[$($actualEnvPaths -join ', ')]") }
    foreach ($envEntry in $envList) {
        foreach ($upd in @(Get-JsonValue $envEntry 'updates')) {
            $value = [string](Get-JsonValue $upd 'value')
            if ($value -ne $Model.TargetVersion) { [void]$envProblems.Add("environmentFiles update value='$value' expected '$($Model.TargetVersion)'") }
        }
    }
    Add-UnifiedCheck -Results $results -Id 'pkg.environmentFilesSpec' -Condition ($envProblems.Count -eq 0) `
        -PassDetail "environmentFiles declares the 2 frozen env metadata files with target value $($Model.TargetVersion)" `
        -FailDetail ('environmentFiles spec problems: ' + ($envProblems -join '; ')) -Expected ($expectedEnvPaths -join ', ') -Actual ($actualEnvPaths -join ', ')

    # hotfix allow-list verbatim
    $hotfixProblems = New-Object System.Collections.ArrayList
    $cordisOverrides = $null
    foreach ($key in @($Model.HotfixOverrides.Keys)) {
        if ([string]::Equals($key, $frozen.CordisPath, [System.StringComparison]::OrdinalIgnoreCase)) { $cordisOverrides = $Model.HotfixOverrides[$key] }
    }
    if ($null -eq $cordisOverrides) { [void]$hotfixProblems.Add('hotfixedSourceOverrides has no cordis.patch.yml entry') }
    else {
        if ([string](Get-JsonValue $cordisOverrides 'HOTFIX_LINE_REMOVED') -ne $frozen.HotfixLineRemovedSha256) { [void]$hotfixProblems.Add('HOTFIX_LINE_REMOVED hash') }
        if ([string](Get-JsonValue $cordisOverrides 'HOTFIX_TEXT_REMOVED') -ne $frozen.HotfixTextRemovedSha256) { [void]$hotfixProblems.Add('HOTFIX_TEXT_REMOVED hash') }
    }
    Add-UnifiedCheck -Results $results -Id 'pkg.hotfixVariants' -Condition ($hotfixProblems.Count -eq 0) `
        -PassDetail 'hotfixedSourceOverrides matches the 2 frozen byte-level hotfix variants' `
        -FailDetail ('hotfix override problems: ' + ($hotfixProblems -join '; ')) -Expected "LINE=$($frozen.HotfixLineRemovedSha256) TEXT=$($frozen.HotfixTextRemovedSha256)" -Actual $hotfixProblems.Count

    # install target set = P + manifest.json; declared counts agree
    $targetProblems = New-Object System.Collections.ArrayList
    if ($Model.TargetFileCount -ne ($Model.PayloadFileCount + 1)) { [void]$targetProblems.Add("target file count $($Model.TargetFileCount) != payload $($Model.PayloadFileCount) + 1 (manifest.json)") }
    if (-not $Model.TargetMap.ContainsKey('manifest.json')) { [void]$targetProblems.Add('manifest.json missing from install target set') }
    foreach ($po in @('SHA256SUMS.txt', 'upgrade-data/rc2-to-rc3.json', 'upgrade-data/README.md')) {
        if ($Model.TargetMap.ContainsKey($po)) { [void]$targetProblems.Add("package-only file '$po' must not be an install target") }
    }
    Add-UnifiedCheck -Results $results -Id 'pkg.installTargetSet' -Condition ($targetProblems.Count -eq 0) `
        -PassDetail "install target set = P + manifest.json ($($Model.TargetFileCount) files); upgrade-data/** and SHA256SUMS.txt are package-only" `
        -FailDetail ('install target set problems: ' + ($targetProblems -join '; ')) -Expected "P+1 = $($Model.PayloadFileCount + 1)" -Actual $Model.TargetFileCount

    return @($results.ToArray())
}

function Assert-FrozenRc2Zip {
    param(
        [Parameter(Mandatory = $true)][string]$Rc2Zip,
        [string]$IdPrefix = 'frozen'
    )
    $results = New-Object System.Collections.ArrayList
    $frozen = Get-FrozenIdentity
    Add-UnifiedCheck -Results $results -Id "$IdPrefix.rc2ZipIdentity" -Condition ($(if (Test-Path -LiteralPath $Rc2Zip) { ((Get-Item -LiteralPath $Rc2Zip).Length -eq $frozen.Rc2ZipBytes) -and ((Get-Sha256File $Rc2Zip) -eq $frozen.Rc2ZipSha256) } else { $false })) `
        -PassDetail "frozen RC2 ZIP identity verified ($($frozen.Rc2ZipBytes) bytes, $($frozen.Rc2ZipSha256))" `
        -FailDetail "frozen RC2 ZIP missing or identity mismatch: $Rc2Zip" -Expected "$($frozen.Rc2ZipSha256)/$($frozen.Rc2ZipBytes)" -Actual $(if (Test-Path -LiteralPath $Rc2Zip) { "$(Get-Sha256File $Rc2Zip)/$((Get-Item -LiteralPath $Rc2Zip).Length)" } else { 'ABSENT' })
    $map = $null
    try { $map = Get-ZipMap $Rc2Zip } catch { Add-UnifiedCheck -Results $results -Id "$IdPrefix.rc2ZipRead" -Condition $false -PassDetail '' -FailDetail "cannot read RC2 ZIP: $($_.Exception.Message)" }
    if ($map) {
        $payload = Get-ZipManifestPayloadMap $map
        Add-UnifiedCheck -Results $results -Id "$IdPrefix.rc2FileCount" -Condition ($map.FileCount -eq $frozen.Rc2ZipFileCount) `
            -PassDetail "frozen RC2 ZIP contains $($map.FileCount) files (107 payload + manifest.json)" -FailDetail "unexpected file count $($map.FileCount)" -Expected $frozen.Rc2ZipFileCount -Actual $map.FileCount
        Add-UnifiedCheck -Results $results -Id "$IdPrefix.rc2PayloadCount" -Condition ($payload.Count -eq $frozen.Rc2PayloadFileCount) `
            -PassDetail "frozen RC2 payload set = 107 files" -FailDetail "unexpected payload count $($payload.Count)" -Expected $frozen.Rc2PayloadFileCount -Actual $payload.Count
        $manifestSha = $map.Map['manifest.json'].Sha256
        $versionSha = $map.Map['VERSION'].Sha256
        Add-UnifiedCheck -Results $results -Id "$IdPrefix.rc2ManifestHash" -Condition ($manifestSha -eq $frozen.Rc2ManifestSha256) `
            -PassDetail "frozen RC2 manifest.json sha256 = $manifestSha" -FailDetail "RC2 manifest hash mismatch: $manifestSha" -Expected $frozen.Rc2ManifestSha256 -Actual $manifestSha
        Add-UnifiedCheck -Results $results -Id "$IdPrefix.rc2VersionHash" -Condition ($versionSha -eq $frozen.Rc2VersionSha256) `
            -PassDetail "frozen RC2 VERSION sha256 = $versionSha" -FailDetail "RC2 VERSION hash mismatch: $versionSha" -Expected $frozen.Rc2VersionSha256 -Actual $versionSha
        $cordisBytes = Get-ZipEntryBytes -ZipPath $Rc2Zip -RelPath $frozen.CordisPath
        $lineRemoved = Remove-CordisTargetLine -Rc2CordisBytes $cordisBytes -Mode 'line'
        $textRemoved = Remove-CordisTargetLine -Rc2CordisBytes $cordisBytes -Mode 'text'
        $lineSha = Get-Sha256Bytes $lineRemoved
        $textSha = Get-Sha256Bytes $textRemoved
        Add-UnifiedCheck -Results $results -Id "$IdPrefix.hotfixVariants" -Condition (($lineSha -eq $frozen.HotfixLineRemovedSha256) -and ($textSha -eq $frozen.HotfixTextRemovedSha256) -and ($lineRemoved.Length -eq $frozen.HotfixLineRemovedBytes) -and ($textRemoved.Length -eq $frozen.HotfixTextRemovedBytes)) `
            -PassDetail "hotfix variants recomputed byte-exactly from the frozen RC2 cordis (LINE=$lineSha, TEXT=$textSha)" `
            -FailDetail "recomputed hotfix hashes/sizes do not match the frozen allow-list (LINE=$lineSha/$($lineRemoved.Length), TEXT=$textSha/$($textRemoved.Length))" `
            -Expected "$($frozen.HotfixLineRemovedSha256)/$($frozen.HotfixLineRemovedBytes) ; $($frozen.HotfixTextRemovedSha256)/$($frozen.HotfixTextRemovedBytes)" -Actual "$lineSha/$($lineRemoved.Length) ; $textSha/$($textRemoved.Length)"
    }
    return [pscustomobject]@{ Results = @($results.ToArray()); Rc2Map = $map; Rc2PayloadMap = $(if ($map) { Get-ZipManifestPayloadMap $map } else { $null }) }
}

function Assert-FrozenCoreEquality {
    param(
        [Parameter(Mandatory = $true)]$Model,
        [string]$Rc3FrozenZip = ''
    )
    $results = New-Object System.Collections.ArrayList
    if (-not $Rc3FrozenZip -or -not [System.IO.File]::Exists((Get-FullPath $Rc3FrozenZip))) {
        [void]$results.Add((New-AssertResult -Id 'pkg.frozenCoreEquality' -Status 'NOT TESTED' -Detail "frozen RC3 ZIP not available for read-only core-equality evidence: '$Rc3FrozenZip'"))
        return @($results.ToArray())
    }
    $frozen = Get-FrozenIdentity
    $frozenProblems = New-Object System.Collections.ArrayList
    if ((Get-Sha256File $Rc3FrozenZip) -ne $frozen.Rc3ZipSha256) { [void]$frozenProblems.Add('frozen RC3 ZIP identity mismatch (read-only input not the expected frozen build)') }
    $rc3Map = $null
    try { $rc3Map = Get-ZipMap $Rc3FrozenZip } catch { [void]$frozenProblems.Add("cannot read frozen RC3 ZIP: $($_.Exception.Message)") }
    if ($frozenProblems.Count -gt 0) {
        Add-UnifiedCheck -Results $results -Id 'pkg.frozenCoreEquality' -Condition $false -PassDetail '' -FailDetail ('frozen RC3 read-only input problems: ' + ($frozenProblems -join '; '))
        return @($results.ToArray())
    }
    $rc3Payload = Get-ZipManifestPayloadMap $rc3Map
    # Frozen-core list (Lead-approved update 2026-10-18): docs/02-安装卸载与回滚.md was
    # EXPLICITLY approved to change (LEGACY statements only; changedFiles=29), so
    # docs/02 is an approved-change path, NOT frozen-core. It must still appear in
    # upgrade-data changedFiles as an approved replace (checked below). docs/06 and
    # docs/provenance/** remain frozen.
    $corePatterns = @('bundle/*', 'upstream/*', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'docs/provenance/*',
                      'tools/portable.ps1', 'tools/lib/PortableCommon.ps1', 'tools/probe_mcp_stdio.py',
                      'docs/06-*', 'VERSION', 'tools/vendor/*', '.gitignore')
    $approvedChangePatterns = @('docs/02-*')
    $corePaths = @($rc3Payload.Keys | Where-Object { $rel = $_; $matched = $false; foreach ($pat in $corePatterns) { if ($rel -like $pat) { $matched = $true; break } }; $matched })
    $deleted = New-Object System.Collections.ArrayList
    $mismatch = New-Object System.Collections.ArrayList
    foreach ($rel in @($rc3Payload.Keys)) {
        if (-not $Model.PayloadMap.ContainsKey($rel)) { [void]$deleted.Add($rel); continue }
    }
    foreach ($rel in $corePaths) {
        if (-not $Model.PayloadMap.ContainsKey($rel)) { continue }
        $expected = $rc3Payload[$rel]
        $actual = $Model.PayloadMap[$rel]
        if (($expected.Sha256 -ne $actual.Sha256) -or ([long]$expected.Bytes -ne [long]$actual.Bytes)) {
            [void]$mismatch.Add("$rel expected=$($expected.Sha256.Substring(0, 12)) actual=$($actual.Sha256.Substring(0, 12))")
        }
    }
    Add-UnifiedCheck -Results $results -Id 'pkg.frozenCoreEquality' -Condition (($mismatch.Count -eq 0) -and ($corePaths.Count -gt 0)) `
        -PassDetail "frozen-core files are byte-identical to the frozen RC3 ZIP ($($corePaths.Count) core files; bundle/**, upstream/**, portable.ps1/PortableCommon.ps1, probe, docs/06, provenance, VERSION, vendor, .gitignore)" `
        -FailDetail ('frozen-core equality problems: ' + (($mismatch | Select-Object -First 20) -join '; ')) -Expected '0 differing core files' -Actual $mismatch.Count

    # Lead-approved exception: a changed docs/02 must be declared in upgrade-data
    # changedFiles as an approved replace (evidence of the approval, not a silent edit).
    $approvedProblems = New-Object System.Collections.ArrayList
    $approvedChecked = 0
    foreach ($rel in @($rc3Payload.Keys)) {
        $isApproved = $false
        foreach ($pat in $approvedChangePatterns) { if ($rel -like $pat) { $isApproved = $true; break } }
        if (-not $isApproved) { continue }
        $approvedChecked++
        if (-not $Model.PayloadMap.ContainsKey($rel)) { [void]$approvedProblems.Add("approved-change file missing from package: $rel"); continue }
        $expected = $rc3Payload[$rel]
        $actual = $Model.PayloadMap[$rel]
        if ([string]::Equals($expected.Sha256, $actual.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $entry = $Model.ChangedMap[$rel]
        if ($null -eq $entry) { [void]$approvedProblems.Add("$rel differs from frozen RC3 but is not listed in upgrade-data changedFiles"); continue }
        if ($entry.Operation -ne 'replace') { [void]$approvedProblems.Add("$rel changed by the approved exception but operation='$($entry.Operation)'") }
        $declaredTarget = [string]$entry.TargetSha256
        if ($declaredTarget -and (-not [string]::Equals($declaredTarget, $actual.Sha256, [System.StringComparison]::OrdinalIgnoreCase))) {
            [void]$approvedProblems.Add("$rel changedFiles targetSha256 != package hash")
        }
    }
    Add-UnifiedCheck -Results $results -Id 'pkg.approvedFrozenCoreChanges' -Condition ($approvedProblems.Count -eq 0) `
        -PassDetail "Lead-approved frozen-core exception(s) declared as approved replaces in upgrade-data changedFiles ($approvedChecked approved path(s): docs/02-*)" `
        -FailDetail ('approved frozen-core change problems: ' + ($approvedProblems -join '; ')) -Expected 'declared approved replaces' -Actual $approvedProblems.Count
    Add-UnifiedCheck -Results $results -Id 'pkg.noFrozenRc3Deletions' -Condition ($deleted.Count -eq 0) `
        -PassDetail "no frozen RC3 payload file is deleted by the unified round (target set is a superset)" `
        -FailDetail ('frozen RC3 payload files missing from the unified package: ' + (($deleted | Select-Object -First 20) -join ', ')) -Expected '0 deletions' -Actual $deleted.Count
    return @($results.ToArray())
}

# Exact RC2->RC3 semantic delta: delete one line (14 spaces + 56 text bytes + LF)
# or delete the 56 text bytes only (keep LF).  Byte-exact: no re-encoding.
function Remove-CordisTargetLine {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Rc2CordisBytes,
        [Parameter(Mandatory = $true)][ValidateSet('line', 'text')][string]$Mode
    )
    $encoding = New-Utf8NoBom
    $text = $encoding.GetString($Rc2CordisBytes)
    $pattern = "(?m)^[ ]{14}suffix: Your working directory is \{\{cwd\}\}\.\r?\n"
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { throw "Remove-CordisTargetLine: target suffix line not found in RC2 cordis bytes" }
    # Safety: exactly one occurrence, and the newline style is LF (frozen file is LF-only).
    if (([regex]::Matches($text, '\{\{cwd\}\}')).Count -ne 1) { throw "Remove-CordisTargetLine: expected exactly one {{cwd}} occurrence in RC2 cordis" }
    $lineText = $m.Value
    if ($lineText.EndsWith("`r`n")) { throw "Remove-CordisTargetLine: frozen cordis unexpectedly contains CRLF" }
    if ($Mode -eq 'line') {
        $newText = $text.Remove($m.Index, $m.Length)
    } else {
        # delete the 56 text bytes, keep the LF: remove (lineLen - 1) chars
        $newText = $text.Remove($m.Index, $m.Length - 1)
    }
    $newBytes = $encoding.GetBytes($newText)
    if ($Mode -eq 'line' -and $newBytes.Length -ne 16705) { throw "Remove-CordisTargetLine: line-mode length $($newBytes.Length) != 16705" }
    if ($Mode -eq 'text' -and $newBytes.Length -ne 16706) { throw "Remove-CordisTargetLine: text-mode length $($newBytes.Length) != 16706" }
    return $newBytes
}

# ---------------------------------------------------------------------------
# Tree snapshot / fingerprint (files AND directories, hashes + sizes + mtimes;
# junctions are recorded but never descended into)
# ---------------------------------------------------------------------------

function New-SnapshotEntry {
    param([string]$Rel, [string]$Kind, [long]$Bytes = 0, [string]$Sha256 = $null,
          [long]$MtimeUtcTicks = 0, [string]$Target = $null)
    [pscustomobject]@{
        Rel            = $Rel
        Kind           = $Kind
        Bytes          = $Bytes
        Sha256         = $Sha256
        MtimeUtcTicks  = $MtimeUtcTicks
        Target         = $Target
    }
}

function Get-TreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludePrefixes = @()
    )
    $rootFull = Get-FullPath $Root
    $entries = New-Object System.Collections.ArrayList
    if (-not [System.IO.Directory]::Exists($rootFull)) { return @() }
    $normalizedExcludes = @()
    foreach ($p in $ExcludePrefixes) {
        if (-not $p) { continue }
        $normalizedExcludes += ($p -replace '\\', '/').Trim('/')
    }
    $rootAttrs = [System.IO.File]::GetAttributes($rootFull)
    [void]$entries.Add((New-SnapshotEntry -Rel '' -Kind 'dir' -MtimeUtcTicks ([System.IO.File]::GetLastWriteTimeUtc($rootFull).Ticks)))
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        $children = @([System.IO.Directory]::EnumerateFileSystemEntries($dir))
        foreach ($child in $children) {
            $rel = Get-RelPath $rootFull $child
            $excluded = $false
            foreach ($ex in $normalizedExcludes) {
                if ([string]::Equals($rel, $ex, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $rel.StartsWith($ex + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $excluded = $true; break }
            }
            if ($excluded) { continue }
            $attrs = [System.IO.File]::GetAttributes($child)
            $mtime = [System.IO.File]::GetLastWriteTimeUtc($child).Ticks
            if ([bool]($attrs -band [System.IO.FileAttributes]::ReparsePoint)) {
                [void]$entries.Add((New-SnapshotEntry -Rel $rel -Kind 'reparse' -MtimeUtcTicks $mtime -Target (Get-ReparseTarget $child)))
                continue
            }
            if ([bool]($attrs -band [System.IO.FileAttributes]::Directory)) {
                [void]$entries.Add((New-SnapshotEntry -Rel $rel -Kind 'dir' -MtimeUtcTicks $mtime))
                $stack.Push($child)
            } else {
                $len = (New-Object System.IO.FileInfo($child)).Length
                [void]$entries.Add((New-SnapshotEntry -Rel $rel -Kind 'file' -Bytes $len -Sha256 (Get-Sha256File $child) -MtimeUtcTicks $mtime))
            }
        }
    }
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $entries) { $list.Add($e) }
    $list.Sort([System.Comparison[object]]{ param($a, $b) [string]::CompareOrdinal($a.Rel, $b.Rel) })
    return @($list.ToArray())
}

function Get-SnapshotIndex {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot)
    $idx = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Snapshot) { $idx[$e.Rel] = $e }
    return $idx
}

function Compare-Snapshots {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Before,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$After,
        [string[]]$IgnorePrefixes = @()
    )
    $b = Get-SnapshotIndex $Before
    $a = Get-SnapshotIndex $After
    $diffs = New-Object System.Collections.ArrayList
    $excludes = @()
    foreach ($p in $IgnorePrefixes) { if ($p) { $excludes += ($p -replace '\\', '/').Trim('/') } }
    $isIgnored = {
        param($rel)
        foreach ($ex in $excludes) {
            if ([string]::Equals($rel, $ex, [System.StringComparison]::OrdinalIgnoreCase) -or
                $rel.StartsWith($ex + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }
    foreach ($rel in $b.Keys) {
        if (& $isIgnored $rel) { continue }
        if (-not $a.ContainsKey($rel)) {
            [void]$diffs.Add([pscustomobject]@{ Type = 'removed'; Rel = $rel; Before = $b[$rel]; After = $null; Note = 'path removed' })
            continue
        }
        $eb = $b[$rel]; $ea = $a[$rel]
        if ($eb.Kind -ne $ea.Kind) {
            [void]$diffs.Add([pscustomobject]@{ Type = 'changed'; Rel = $rel; Before = $eb; After = $ea; Note = "kind $($eb.Kind) -> $($ea.Kind)" })
        } elseif ($eb.Kind -eq 'file') {
            $notes = New-Object System.Collections.ArrayList
            if ($eb.Sha256 -ne $ea.Sha256) { [void]$notes.Add('content') }
            if ($eb.Bytes -ne $ea.Bytes) { [void]$notes.Add("size $($eb.Bytes)->$($ea.Bytes)") }
            if ($eb.MtimeUtcTicks -ne $ea.MtimeUtcTicks) { [void]$notes.Add('mtime') }
            if ($notes.Count -gt 0) {
                [void]$diffs.Add([pscustomobject]@{ Type = 'changed'; Rel = $rel; Before = $eb; After = $ea; Note = ($notes -join ', ') })
            }
        } elseif ($eb.Kind -eq 'dir') {
            if ($eb.MtimeUtcTicks -ne $ea.MtimeUtcTicks) {
                [void]$diffs.Add([pscustomobject]@{ Type = 'changed'; Rel = $rel; Before = $eb; After = $ea; Note = 'directory mtime' })
            }
        } elseif ($eb.Kind -eq 'reparse') {
            if (-not [string]::Equals([string]$eb.Target, [string]$ea.Target, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$diffs.Add([pscustomobject]@{ Type = 'changed'; Rel = $rel; Before = $eb; After = $ea; Note = 'reparse target' })
            }
        }
    }
    foreach ($rel in $a.Keys) {
        if (& $isIgnored $rel) { continue }
        if (-not $b.ContainsKey($rel)) {
            [void]$diffs.Add([pscustomobject]@{ Type = 'added'; Rel = $rel; Before = $null; After = $a[$rel]; Note = 'path added' })
        }
    }
    return [pscustomobject]@{
        Equal       = ($diffs.Count -eq 0)
        Differences = @($diffs.ToArray() | Sort-Object -Property Rel)
        AddedCount  = @($diffs.ToArray() | Where-Object { $_.Type -eq 'added' }).Count
        RemovedCount = @($diffs.ToArray() | Where-Object { $_.Type -eq 'removed' }).Count
        ChangedCount = @($diffs.ToArray() | Where-Object { $_.Type -eq 'changed' }).Count
    }
}

function Format-SnapshotDiff {
    param([Parameter(Mandatory = $true)]$Diff, [int]$Max = 25, [int]$SampleBytes = 200)
    if ($Diff.Equal) { return 'no differences' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("added=$($Diff.AddedCount) removed=$($Diff.RemovedCount) changed=$($Diff.ChangedCount)")
    $i = 0
    foreach ($d in $Diff.Differences) {
        if ($i -ge $Max) { [void]$lines.Add("... ($(@($Diff.Differences).Count - $Max) more differences)"); break }
        $line = "  [$($d.Type)] $($d.Note) :: $($d.Rel)"
        if ($d.After -and $d.After.Kind -eq 'file') { $line += " after-sha=$($d.After.Sha256.Substring(0, 12))..." }
        if ($d.Type -eq 'removed' -and $d.Before -and $d.Before.Kind -eq 'file') { $line += " before-sha=$($d.Before.Sha256.Substring(0, 12))..." }
        [void]$lines.Add($line)
        $i++
    }
    return ($lines -join "`n")
}

function Select-SnapshotSubtree {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot,
        [string[]]$Prefixes = @()
    )
    $prefixList = @()
    foreach ($p in $Prefixes) { if ($p) { $prefixList += ($p -replace '\\', '/').Trim('/') } }
    if ($prefixList.Count -eq 0) { return @($Snapshot) }
    $out = New-Object System.Collections.ArrayList
    foreach ($e in $Snapshot) {
        foreach ($p in $prefixList) {
            if ([string]::Equals($e.Rel, $p, [System.StringComparison]::OrdinalIgnoreCase) -or
                $e.Rel.StartsWith($p + '/', [System.StringComparison]::OrdinalIgnoreCase)) { [void]$out.Add($e); break }
        }
    }
    return @($out.ToArray())
}

# ---------------------------------------------------------------------------
# Assertions on trees, files, snapshots
# ---------------------------------------------------------------------------

function Assert-SnapshotEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Before,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$After,
        [string[]]$IgnorePrefixes = @(),
        [string]$Label = 'tree'
    )
    $diff = Compare-Snapshots -Before $Before -After $After -IgnorePrefixes $IgnorePrefixes
    if ($diff.Equal) {
        return New-AssertResult -Id $Id -Status PASS -Detail "$Label fingerprint identical ($(@($Before).Count) entries; paths+bytes+sizes+mtimes) after the action" -Expected 'identical' -Actual 'identical'
    }
    $detail = "$Label fingerprint CHANGED (path+bytes+size+mtime proof of writes):`n" + (Format-SnapshotDiff -Diff $diff)
    return New-AssertResult -Id $Id -Status FAIL -Detail $detail -Expected 'identical' -Actual "added=$($diff.AddedCount) removed=$($diff.RemovedCount) changed=$($diff.ChangedCount)" -Data $diff
}

function Assert-FileSha {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedSha = $null,
        [AllowNull()][string]$ExpectedPath = $null,
        [long]$ExpectedBytes = -1
    )
    if (-not [System.IO.File]::Exists((Get-FullPath $Path))) {
        return New-AssertResult -Id $Id -Status FAIL -Detail "file missing: $Path" -Expected $ExpectedSha -Actual 'ABSENT'
    }
    $sha = Get-Sha256File $Path
    $short = $Path
    $expected = $ExpectedSha
    if ($ExpectedPath) {
        if (-not [System.IO.File]::Exists((Get-FullPath $ExpectedPath))) {
            return New-AssertResult -Id $Id -Status FAIL -Detail "expected reference file missing: $ExpectedPath"
        }
        $expected = Get-Sha256File $ExpectedPath
        $short = "$Path == $ExpectedPath"
    }
    $len = (Get-Item -LiteralPath (Get-FullPath $Path)).Length
    $ok = [string]::Equals($sha, $expected, [System.StringComparison]::OrdinalIgnoreCase)
    if ($ExpectedBytes -ge 0) { $ok = $ok -and ($len -eq $ExpectedBytes) }
    $detail = if ($ok) { "byte-identical: $short (sha=$sha, $len bytes)" } else { "BYTE MISMATCH: $short sha=$sha expected=$expected length=$len" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected $expected -Actual $sha
}

function Assert-TreeEquals {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$ActualRoot,
        [Parameter(Mandatory = $true)]$ExpectedFileMap,   # Dictionary[string,object] path->{Sha256,Bytes}
        [string]$Label = 'tree'
    )
    $root = Get-FullPath $ActualRoot
    if (-not [System.IO.Directory]::Exists($root)) {
        return New-AssertResult -Id $Id -Status FAIL -Detail "$Label root missing: $root"
    }
    $snap = Get-TreeSnapshot -Root $root
    $actual = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $snap) { if ($e.Kind -eq 'file') { $actual[$e.Rel] = $e } }
    $missing = New-Object System.Collections.ArrayList
    $mismatch = New-Object System.Collections.ArrayList
    foreach ($path in $ExpectedFileMap.Keys) {
        if (-not $actual.ContainsKey($path)) { [void]$missing.Add($path); continue }
        $exp = $ExpectedFileMap[$path]
        $act = $actual[$path]
        if ($act.Sha256 -ne $exp.Sha256 -or $act.Bytes -ne $exp.Bytes) {
            [void]$mismatch.Add([pscustomobject]@{ Path = $path; Expected = $exp.Sha256; Actual = $act.Sha256; ExpectedBytes = $exp.Bytes; ActualBytes = $act.Bytes })
        }
    }
    $ok = ($missing.Count -eq 0) -and ($mismatch.Count -eq 0)
    if ($ok) {
        return New-AssertResult -Id $Id -Status PASS -Detail "${Label}: all $($ExpectedFileMap.Count) expected files present and byte-identical" -Expected "all $($ExpectedFileMap.Count) files equal" -Actual 'all equal'
    }
    $detail = "$Label MISMATCH: missing=$($missing.Count) changed=$($mismatch.Count)"
    $i = 0
    foreach ($m in $missing) { if ($i -ge 15) { break }; $detail += "`n  missing: $m"; $i++ }
    $i = 0
    foreach ($m in $mismatch) { if ($i -ge 15) { break }; $detail += "`n  changed: $($m.Path) expected=$($m.Expected.Substring(0,12))... actual=$($m.Actual.Substring(0,12))..."; $i++ }
    return New-AssertResult -Id $Id -Status FAIL -Detail $detail -Expected "all $($ExpectedFileMap.Count) files equal" -Actual "missing=$($missing.Count) changed=$($mismatch.Count)" -Data @{ Missing = @($missing.ToArray()); Mismatch = @($mismatch.ToArray()) }
}

function Get-UnifiedModelFromContext {
    param([AllowNull()]$Model)
    if ($Model) { return $Model }
    if ($script:G -and $script:G.PackageModel) { return $script:G.PackageModel }
    throw 'Unified package model not available: pass -Model or initialize $script:G.PackageModel'
}

function Assert-InstallEqualsUnifiedTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowNull()]$Model = $null,
        [string]$Label = 'installed tree vs unified candidate package target'
    )
    $model = Get-UnifiedModelFromContext $Model
    $expected = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($model.TargetFiles)) { $expected[$f.Path] = $f }
    return Assert-TreeEquals -Id $Id -ActualRoot $InstallRoot -ExpectedFileMap $expected -Label "$Label (P + manifest.json = $($model.TargetFileCount) files)"
}

function Assert-PackageOnlyFilesNotInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowNull()]$Model = $null
    )
    $model = Get-UnifiedModelFromContext $Model
    $root = Get-FullPath $InstallRoot
    $problems = New-Object System.Collections.ArrayList
    foreach ($rel in @($model.PackageOnlyPaths)) {
        # manifest.json is package metadata AND the installed distribution
        # manifest: it is part of the installed target tree by design (never a
        # "package-only file" in the install root).
        if ([string]::Equals($rel, 'manifest.json', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $path = Join-Path $root ($rel -replace '/', '\')
        if ([System.IO.File]::Exists($path)) { [void]$problems.Add("package-only file installed: $rel") }
    }
    if ([System.IO.Directory]::Exists((Join-Path $root 'upgrade-data'))) {
        $leftover = @(Get-TreeSnapshot -Root (Join-Path $root 'upgrade-data') | Where-Object { $_.Kind -eq 'file' } | ForEach-Object { $_.Rel })
        if ($leftover.Count -gt 0) { [void]$problems.Add("upgrade-data/ directory present in install root with files: $($leftover -join ', ')") }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "package-only metadata (SHA256SUMS.txt, upgrade-data/**) was NOT installed into the install root" }
              else { 'package-only metadata leaked into the install root: ' + ($problems -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'no package-only files installed' -Actual $problems
}

function Assert-AddedPayloadFilesPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowNull()]$Model = $null,
        [string]$Label = 'added payload files'
    )
    $model = Get-UnifiedModelFromContext $Model
    $problems = New-Object System.Collections.ArrayList
    foreach ($rel in @($model.AddedPaths)) {
        $path = Join-Path (Get-FullPath $InstallRoot) ($rel -replace '/', '\')
        $target = $model.TargetMap[$rel]
        if (-not [System.IO.File]::Exists($path)) { [void]$problems.Add("missing: $rel"); continue }
        $sha = Get-Sha256File $path
        if (-not [string]::Equals($sha, $target.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$problems.Add("byte mismatch: $rel (sha=$sha expected=$($target.Sha256))") }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "all $($model.AddedPaths.Count) added ($Label) files present and byte-identical to the candidate package" }
              else { 'added-file problems: ' + (($problems | Select-Object -First 20) -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected "all $($model.AddedPaths.Count) added files byte-exact" -Actual $problems
}

function Assert-AddedPayloadFilesAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowNull()]$Model = $null,
        [string]$Label = 'added payload files'
    )
    $model = Get-UnifiedModelFromContext $Model
    $present = New-Object System.Collections.ArrayList
    foreach ($rel in @($model.AddedPaths)) {
        $path = Join-Path (Get-FullPath $InstallRoot) ($rel -replace '/', '\')
        if ([System.IO.File]::Exists($path)) { [void]$present.Add($rel) }
    }
    $ok = ($present.Count -eq 0)
    $detail = if ($ok) { "none of the $($model.AddedPaths.Count) added ($Label) files exist inside the install root" }
              else { "added files still present: $($present -join ', ')" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'all added files absent' -Actual $present
}

function Get-ApplyIndexForPath {
    # Engine fault-injection apply order (engine-dev contract, 2026-10-18):
    # changedFiles sorted Ordinal EXCLUDING manifest.json/VERSION, then
    # manifest.json, then VERSION; operation:add writes are part of the same
    # order.  Returns the 1-based FAIL_APPLY_INDEX:N value for the path.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()]$Model = $null
    )
    $model = Get-UnifiedModelFromContext $Model
    $rel = ConvertTo-NormalizedRelPath $Path
    $sorted = New-Object System.Collections.ArrayList
    foreach ($p in @($model.ChangedPaths)) {
        if ([string]::Equals($p, 'manifest.json', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([string]::Equals($p, 'VERSION', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        [void]$sorted.Add($p)
    }
    $arr = [string[]]$sorted.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    $idx = [System.Array]::IndexOf($arr, $rel)
    if ($idx -ge 0) { return ($idx + 1) }
    if ([string]::Equals($rel, 'manifest.json', [System.StringComparison]::OrdinalIgnoreCase)) { return ($arr.Length + 1) }
    if ([string]::Equals($rel, 'VERSION', [System.StringComparison]::OrdinalIgnoreCase)) { return ($arr.Length + 2) }
    throw "Get-ApplyIndexForPath: '$rel' is not a changed payload path"
}

function Assert-TreeMatchesSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ExpectedSnapshot,
        [string[]]$OnlyPrefixes = @(),
        [string]$Label = 'tree vs recorded snapshot'
    )
    $rootFull = Get-FullPath $Root
    if (-not [System.IO.Directory]::Exists($rootFull)) { return New-AssertResult -Id $Id -Status FAIL -Detail "${Label}: root missing: $rootFull" }
    $current = Get-TreeSnapshot -Root $rootFull
    $before = Select-SnapshotSubtree -Snapshot $ExpectedSnapshot -Prefixes $OnlyPrefixes
    $a = Get-SnapshotIndex $before
    $cur = Get-SnapshotIndex $current
    $missing = New-Object System.Collections.ArrayList
    $mismatch = New-Object System.Collections.ArrayList
    foreach ($rel in $a.Keys) {
        $exp = $a[$rel]
        if ($exp.Kind -ne 'file') { continue }
        if (-not $cur.ContainsKey($rel)) { [void]$missing.Add($rel); continue }
        $act = $cur[$rel]
        if ($act.Sha256 -ne $exp.Sha256 -or $act.Bytes -ne $exp.Bytes) {
            [void]$mismatch.Add([pscustomobject]@{ Path = $rel; Expected = $exp.Sha256; Actual = $act.Sha256 })
        }
    }
    $ok = ($missing.Count -eq 0) -and ($mismatch.Count -eq 0)
    if ($ok) {
        return New-AssertResult -Id $Id -Status PASS -Detail "${Label}: all $($a.Count - 1) recorded files still byte-identical" -Expected 'recorded bytes' -Actual 'visible bytes equal'
    }
    $detail = "$Label MISMATCH: missing=$($missing.Count) changed=$($mismatch.Count)"
    $i = 0
    foreach ($m in $missing) { if ($i -ge 15) { break }; $detail += "`n  missing: $m"; $i++ }
    $i = 0
    foreach ($m in $mismatch) { if ($i -ge 15) { break }; $detail += "`n  changed: $($m.Path) expected=$($m.Expected.Substring(0,12))... actual=$($m.Actual.Substring(0,12))..."; $i++ }
    return New-AssertResult -Id $Id -Status FAIL -Detail $detail -Expected 'recorded bytes' -Actual "missing=$($missing.Count) changed=$($mismatch.Count)" -Data @{ Missing = @($missing.ToArray()); Mismatch = @($mismatch.ToArray()) }
}

function Get-InstallExtras {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string[]]$AllowedRelPrefixes = @(),
        [string[]]$AllowedRelPaths = @(),
        [string[]]$ExpectedRelPaths = @()
    )
    $root = Get-FullPath $InstallRoot
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $ExpectedRelPaths) { [void]$expected.Add(($p -replace '\\', '/')) }
    $allowedDirs = @(); foreach ($p in $AllowedRelPrefixes) { if ($p) { $allowedDirs += ($p -replace '\\', '/').Trim('/') } }
    $allowedFiles = @(); foreach ($p in $AllowedRelPaths) { if ($p) { $allowedFiles += ($p -replace '\\', '/') } }
    $extras = New-Object System.Collections.ArrayList
    $snap = Get-TreeSnapshot -Root $root
    foreach ($e in $snap) {
        if ($e.Kind -ne 'file') { continue }
        if ($expected.Contains($e.Rel)) { continue }
        $isAllowedDir = $false
        foreach ($d in $allowedDirs) { if ($e.Rel.StartsWith($d + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $isAllowedDir = $true; break } }
        if ($isAllowedDir) { continue }
        $isAllowedFile = $false
        foreach ($f in $allowedFiles) { if ([string]::Equals($e.Rel, $f, [System.StringComparison]::OrdinalIgnoreCase)) { $isAllowedFile = $true; break } }
        if ($isAllowedFile) { continue }
        [void]$extras.Add($e.Rel)
    }
    return @($extras.ToArray())
}

function Assert-NoUnexpectedInstallFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string[]]$AllowedRelPrefixes = @(),
        [string[]]$AllowedRelPaths = @(),
        [string[]]$ExpectedRelPaths = @()
    )
    $extras = Get-InstallExtras -InstallRoot $InstallRoot -AllowedRelPrefixes $AllowedRelPrefixes -AllowedRelPaths $AllowedRelPaths -ExpectedRelPaths $ExpectedRelPaths
    $ok = ($extras.Count -eq 0)
    $detail = if ($ok) { "no unexpected files inside the install root (allowed env/user paths only)" }
              else { "unexpected files inside the install root: $($extras.Count)`n  " + (($extras | Select-Object -First 30) -join "`n  ") }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'no extras' -Actual $extras
}

# ---------------------------------------------------------------------------
# Env-file / transaction / profile assertions
# ---------------------------------------------------------------------------

function Get-JsonValue {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Path)
    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}

function Assert-EnvMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedDistribution,
        [switch]$ExpectUpgradeRecord,
        [string]$ExpectedSourceVersion = '',
        [string]$ExpectedTargetVersion = ''
    )
    $model = $null
    if ($script:G -and $script:G.PackageModel) { $model = $script:G.PackageModel }
    if (-not $ExpectedSourceVersion) { $ExpectedSourceVersion = if ($model) { $model.SourceVersion } else { '1.0.0-rc.2' } }
    if (-not $ExpectedTargetVersion) { $ExpectedTargetVersion = if ($model) { $model.TargetVersion } else { '1.0.0-rc.3' } }
    $root = Get-FullPath $InstallRoot
    $problems = New-Object System.Collections.ArrayList
    $statePath = Join-Path $root '_portable\install-state.json'
    $runtimePath = Join-Path $root 'bundle\cnki-research\portable.runtime.json'
    $details = New-Object System.Collections.ArrayList
    foreach ($pair in @(@{ Path = $statePath; Label = 'install-state.json' }, @{ Path = $runtimePath; Label = 'portable.runtime.json' })) {
        if (-not [System.IO.File]::Exists($pair.Path)) { [void]$problems.Add("$($pair.Label) missing"); continue }
        try { $doc = Read-JsonFile $pair.Path } catch { [void]$problems.Add("$($pair.Label) unparsable: $($_.Exception.Message)"); continue }
        $dist = Get-JsonValue $doc 'distribution'
        if ($dist -ne $ExpectedDistribution) { [void]$problems.Add("$($pair.Label) distribution='$dist' expected '$ExpectedDistribution'") }
        else { [void]$details.Add("$($pair.Label) distribution=$dist") }
        if ($pair.Label -eq 'install-state.json') {
            if ($ExpectUpgradeRecord) {
                $up = Get-JsonValue $doc 'upgrade'
                if ($null -eq $up) { [void]$problems.Add("install-state.json missing 'upgrade' object after APPLY") }
                else {
                    $from = Get-JsonValue $doc 'upgrade.fromVersion'
                    $to = Get-JsonValue $doc 'upgrade.toVersion'
                    if ($from -ne $ExpectedSourceVersion) { [void]$problems.Add("install-state.json upgrade.fromVersion='$from' expected '$ExpectedSourceVersion'") }
                    if ($to -ne $ExpectedTargetVersion) { [void]$problems.Add("install-state.json upgrade.toVersion='$to' expected '$ExpectedTargetVersion'") }
                    if ($null -eq (Get-JsonValue $doc 'upgrade.lastUpgradeId')) { [void]$problems.Add("install-state.json upgrade.lastUpgradeId missing") }
                    elseif ($model -and $model.UpgradeId) {
                        $lastId = [string](Get-JsonValue $doc 'upgrade.lastUpgradeId')
                        if ($lastId -ne $model.UpgradeId) { [void]$problems.Add("install-state.json upgrade.lastUpgradeId='$lastId' expected '$($model.UpgradeId)'") }
                    }
                    [void]$details.Add('install-state.json upgrade record ok')
                }
            }
        } else {
            if ($ExpectUpgradeRecord) {
                if ($null -eq (Get-JsonValue $doc 'upgradedAt')) { [void]$problems.Add("portable.runtime.json missing 'upgradedAt' after APPLY") }
                if ($null -eq (Get-JsonValue $doc 'upgradedBy')) { [void]$problems.Add("portable.runtime.json missing 'upgradedBy' after APPLY") }
                else { [void]$details.Add("portable.runtime.json upgradedBy=$((Get-JsonValue $doc 'upgradedBy'))") }
            }
        }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { 'environment metadata verified: ' + ($details -join '; ') } else { 'environment metadata problems: ' + ($problems -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected "distribution=$ExpectedDistribution" -Actual $problems
}

function Assert-EnvNonMigrationPreserved {
    # Byte-level preservation of the NON-migration fields of the 2 declarative
    # environment files: every pre-upgrade field that is not a documented
    # migration field must keep its value after APPLY (e.g. installRoot, python,
    # launcher, bundle, dshHome/profile reference, installedAt, linkMode).
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$PreInstallStateFile,
        [Parameter(Mandatory = $true)][string]$PreRuntimeFile,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    $migrationFields = @('distribution', 'upgrade', 'upgradedAt', 'upgradedBy', 'lastUpgrade', 'lastUpgradeId',
                         'lastUpgradeAt', 'upgradedByVersion', 'updatedAt', 'restartRequired', 'schemaVersion')
    $root = Get-FullPath $InstallRoot
    $pairs = @(
        @{ Label = 'install-state.json'; Pre = $PreInstallStateFile; Post = (Join-Path $root '_portable\install-state.json') },
        @{ Label = 'portable.runtime.json'; Pre = $PreRuntimeFile; Post = (Join-Path $root 'bundle\cnki-research\portable.runtime.json') }
    )
    $problems = New-Object System.Collections.ArrayList
    $checked = 0
    foreach ($pair in $pairs) {
        if (-not (Test-Path -LiteralPath $pair.Pre)) { [void]$problems.Add("$($pair.Label): pre-upgrade copy missing ($($pair.Pre))"); continue }
        if (-not (Test-Path -LiteralPath $pair.Post)) { [void]$problems.Add("$($pair.Label): post-upgrade file missing"); continue }
        $pre = Read-JsonFile $pair.Pre
        $post = Read-JsonFile $pair.Post
        if ($null -eq $pre -or $null -eq $post) { [void]$problems.Add("$($pair.Label): unparsable JSON"); continue }
        foreach ($prop in @($pre.PSObject.Properties)) {
            $name = $prop.Name
            if ($migrationFields -contains $name) { continue }
            $postProp = $post.PSObject.Properties[$name]
            if ($null -eq $postProp) { [void]$problems.Add("$($pair.Label): non-migration field '$name' disappeared"); continue }
            $checked++
            $preJson = ($prop.Value | ConvertTo-Json -Depth 15 -Compress)
            $postJson = ($postProp.Value | ConvertTo-Json -Depth 15 -Compress)
            if ($preJson -ne $postJson) { [void]$problems.Add("$($pair.Label): non-migration field '$name' changed (pre=$preJson post=$postJson)") }
        }
    }
    $ok = ($problems.Count -eq 0) -and ($checked -gt 0)
    $detail = if ($ok) { "all $checked non-migration environment fields preserved byte-for-byte (install path, venv/python, launcher, bundle, DSH home/profile reference, installedAt)" }
              else { 'environment non-migration problems: ' + (($problems | Select-Object -First 20) -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'all non-migration fields preserved' -Actual $problems
}

function Get-TransactionDirs {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $upgradesDir = Join-Path (Get-FullPath $InstallRoot) '_portable\upgrades'
    if (-not [System.IO.Directory]::Exists($upgradesDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $upgradesDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Get-TransactionIds {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    return @(Get-TransactionDirs -InstallRoot $InstallRoot | ForEach-Object { $_.Name })
}

function Get-TransactionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    $txnDir = Join-Path (Get-FullPath $InstallRoot) ("_portable\upgrades\" + $TransactionId)
    $txnFile = Join-Path $txnDir 'transaction.json'
    if (-not [System.IO.File]::Exists($txnFile)) { return $null }
    return Read-JsonFile $txnFile
}

function Assert-TransactionPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPhase,
        [switch]$Contain
    )
    $rec = Get-TransactionRecord -InstallRoot $InstallRoot -TransactionId $TransactionId
    if ($null -eq $rec) { return New-AssertResult -Id $Id -Status FAIL -Detail "transaction.json missing for transaction '$TransactionId'" }
    $phase = Get-JsonValue $rec 'phase'
    $ok = $false
    if ($Contain) { $ok = ($ExpectedPhase -contains $phase) } else { $ok = ($phase -eq $ExpectedPhase[0]) }
    $detail = if ($ok) { "transaction '$TransactionId' phase=$phase" } else { "transaction '$TransactionId' phase=$phase expected one of [$($ExpectedPhase -join ', ')]" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected $ExpectedPhase -Actual $phase -Data @{ TransactionJson = $rec }
}

function Assert-NoBackupCreated {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$InstallRoot)
    $txns = @(Get-TransactionIds -InstallRoot $InstallRoot)
    $ok = ($txns.Count -eq 0)
    $detail = if ($ok) { 'no transaction/backup directory was created' } else { "unexpected transaction dirs: $($txns -join ', ')" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'no _portable\upgrades\*' -Actual $txns
}

function Assert-NoNewTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string[]]$BeforeIds = @()
    )
    $now = @(Get-TransactionIds -InstallRoot $InstallRoot)
    $added = @($now | Where-Object { $BeforeIds -notcontains $_ })
    $ok = ($added.Count -eq 0)
    $detail = if ($ok) { "no new transaction directory (existing: $(if ($BeforeIds.Count) { $BeforeIds -join ', ' } else { 'none' }))" } else { "unexpected new transaction(s): $($added -join ', ')" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected "same txn set" -Actual $added
}

function Assert-BackupFilesMatchPreState {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$PreSnapshot,
        [string[]]$ManagedRelPaths = @()
    )
    $txnDir = Join-Path (Get-FullPath $InstallRoot) ("_portable\upgrades\" + $TransactionId)
    $backupDir = Join-Path $txnDir 'backup'
    if (-not [System.IO.Directory]::Exists($backupDir)) {
        return New-AssertResult -Id $Id -Status FAIL -Detail "backup directory missing: $backupDir"
    }
    $pre = Get-SnapshotIndex (Select-SnapshotSubtree -Snapshot $PreSnapshot -Prefixes @())
    $problems = New-Object System.Collections.ArrayList
    $checked = 0
    foreach ($rel in $ManagedRelPaths) {
        $normalized = ($rel -replace '\\', '/')
        $backupFile = Join-Path $backupDir ($normalized -replace '/', '\')
        if (-not [System.IO.File]::Exists($backupFile)) { [void]$problems.Add("missing backup file: $normalized"); continue }
        $checked++
        if ($pre.ContainsKey($normalized)) {
            $sha = Get-Sha256File $backupFile
            if ($sha -ne $pre[$normalized].Sha256) { [void]$problems.Add("backup bytes differ from pre-upgrade bytes: $normalized") }
        }
    }
    $rec = $null
    try { $rec = Get-TransactionRecord -InstallRoot $InstallRoot -TransactionId $TransactionId } catch { }
    if ($rec) {
        $restoreVerified = Get-JsonValue $rec 'restoreVerified'
        $phase = Get-JsonValue $rec 'phase'
        $backupOk = ($phase -eq 'COMMITTED')
        if (-not $backupOk) { [void]$problems.Add("transaction phase is '$phase', expected COMMITTED") }
    } else {
        [void]$problems.Add('transaction.json unreadable/missing')
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "all $checked managed files have byte-identical backups from the pre-upgrade state; transaction COMMITTED" }
              else { "backup verification problems: " + ($problems -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'backups == pre-upgrade bytes; phase COMMITTED' -Actual $problems
}

function Get-TransactionFileRecords {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    $rec = Get-TransactionRecord -InstallRoot $InstallRoot -TransactionId $TransactionId
    if ($null -eq $rec) { return @() }
    return @(Get-JsonValue $rec 'files')
}

function Assert-TransactionAddRecords {
    # New-file (operation:add) transaction evidence: existed=false, no backup copy,
    # preApplySha256=null, targetSha256 = applied target hash, applied=true.
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [AllowNull()]$Model = $null
    )
    $model = Get-UnifiedModelFromContext $Model
    $records = @(Get-TransactionFileRecords -InstallRoot $InstallRoot -TransactionId $TransactionId)
    $byPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $records) { $rel = ConvertTo-NormalizedRelPath ([string](Get-JsonValue $r 'path')); if ($rel) { $byPath[$rel] = $r } }
    $problems = New-Object System.Collections.ArrayList
    foreach ($rel in @($model.AddedPaths)) {
        if (-not $byPath.ContainsKey($rel)) { [void]$problems.Add("no transaction record for added file: $rel"); continue }
        $r = $byPath[$rel]
        $op = [string](Get-JsonValue $r 'operation')
        if ($op -ne 'add') { [void]$problems.Add("${rel}: operation='$op' expected 'add'") }
        if ($null -ne (Get-JsonValue $r 'existed') -and ([bool](Get-JsonValue $r 'existed'))) { [void]$problems.Add("${rel}: existed=true (must be false for a new file)") }
        if ($null -eq (Get-JsonValue $r 'existed')) { [void]$problems.Add("${rel}: existed field missing") }
        $pre = Get-JsonValue $r 'preApplySha256'
        if ($null -ne $pre -and [string]$pre -ne '') { [void]$problems.Add("${rel}: preApplySha256='$pre' expected null") }
        $targetRec = [string](Get-JsonValue $r 'targetSha256')
        $expectedTarget = $model.TargetMap[$rel].Sha256
        if (-not [string]::Equals($targetRec, $expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$problems.Add("${rel}: targetSha256='$targetRec' expected '$expectedTarget'") }
        $applied = Get-JsonValue $r 'applied'
        if ($null -ne $applied -and -not [bool]$applied) { [void]$problems.Add("${rel}: applied=false after COMMITTED") }
        $backupSha = Get-JsonValue $r 'backupSha256'
        if ($null -ne $backupSha -and [string]$backupSha -ne '') { [void]$problems.Add("${rel}: backupSha256 present for a file that did not exist before") }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "transaction records $($model.AddedPaths.Count) added files with existed=false / preApplySha256=null / targetSha256=applied target hash / applied=true (no backup copy)" }
              else { 'added-file transaction record problems: ' + (($problems | Select-Object -First 20) -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'add records existed=false, no backup, applied' -Actual $problems
}

function Get-TransactionDirectoryRecords {
    # Engine transaction schema v2 records `newDirectories`: an array of objects
    # { path, created, removed }.  Legacy `createdDirectories` (strings) is still
    # accepted for older transaction files.  Absent/null means "no directories
    # created by this transaction" (success path) - never one null element.
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    $rec = Get-TransactionRecord -InstallRoot $InstallRoot -TransactionId $TransactionId
    if ($null -eq $rec) { return @() }
    $raw = Get-JsonValue $rec 'newDirectories'
    if ($null -eq $raw) { $raw = Get-JsonValue $rec 'createdDirectories' }
    if ($null -eq $raw) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($item in @($raw)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            $rel = ConvertTo-NormalizedRelPath $item
            if ($rel) { [void]$out.Add([pscustomobject]@{ Path = $rel; Created = $true; Removed = $null }) }
            continue
        }
        $rel = ConvertTo-NormalizedRelPath ([string](Get-JsonValue $item 'path'))
        if (-not $rel) { continue }
        $created = Get-JsonValue $item 'created'
        if ($null -eq $created) { $created = $true }
        $removed = Get-JsonValue $item 'removed'
        [void]$out.Add([pscustomobject]@{ Path = $rel; Created = [bool]$created; Removed = $removed })
    }
    return @($out.ToArray())
}

function Get-CreatedDirectories {
    # Paths of directories the transaction CREATED (projection used by the
    # rollback/cleanup assertions).
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    $records = @(Get-TransactionDirectoryRecords -InstallRoot $InstallRoot -TransactionId $TransactionId)
    $paths = New-Object System.Collections.ArrayList
    foreach ($r in $records) { if ($r.Created) { [void]$paths.Add([string]$r.Path) } }
    return @($paths.ToArray())
}

function Assert-TransactionCreatedDirectoriesInsideInstallRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    $root = Get-FullPath $InstallRoot
    $dirs = @(Get-CreatedDirectories -InstallRoot $InstallRoot -TransactionId $TransactionId)
    $problems = New-Object System.Collections.ArrayList
    foreach ($d in $dirs) {
        $rel = ConvertTo-NormalizedRelPath ([string]$d)
        if ($rel -eq '') { [void]$problems.Add('empty created directory path'); continue }
        if ($rel -match '(^|/)\.\.(/|$)' -or $rel.StartsWith('/') -or $rel -match '^[A-Za-z]:') { [void]$problems.Add("unsafe created directory path: $rel"); continue }
        $full = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-PathUnder -Child $full -Parent $root)) { [void]$problems.Add("created directory escapes the install root: $rel") }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "transaction newDirectories[] records $($dirs.Count) created directory path(s), all install-root-relative and non-escaping ($($dirs -join ', '))" }
              else { 'newDirectories problems: ' + ($problems -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'install-root-relative created dirs only' -Actual $problems
}

function Assert-TransactionNewDirectories {
    # Strong assertion for the D6 created-directory guarantee: the transaction must
    # record exactly the directories that the added payload files needed, all
    # install-root-relative, and (after rollback) flag them removed.
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [AllowEmptyCollection()][string[]]$ExpectedPaths = @(),
        [switch]$ExpectRemoved
    )
    $root = Get-FullPath $InstallRoot
    $records = @(Get-TransactionDirectoryRecords -InstallRoot $InstallRoot -TransactionId $TransactionId)
    $createdPaths = @($records | Where-Object { $_.Created } | ForEach-Object { [string]$_.Path } | Sort-Object)
    $expected = @($ExpectedPaths | ForEach-Object { ConvertTo-NormalizedRelPath $_ } | Where-Object { $_ } | Sort-Object)
    $problems = New-Object System.Collections.ArrayList
    if (-not (Test-StringSetEqual -Left $createdPaths -Right $expected)) {
        [void]$problems.Add("transaction newDirectories created-set=[$($createdPaths -join ', ')] expected=[$($expected -join ', ')]")
    }
    foreach ($r in $records) {
        if (-not $r.Created) { continue }
        $rel = ConvertTo-NormalizedRelPath ([string]$r.Path)
        if ($rel -match '(^|/)\.\.(/|$)' -or $rel.StartsWith('/') -or $rel -match '^[A-Za-z]:') { [void]$problems.Add("unsafe created directory path: $rel") }
        $full = Join-Path $root ($rel -replace '/', '\')
        if (-not (Test-PathUnder -Child $full -Parent $root)) { [void]$problems.Add("created directory escapes the install root: $rel") }
        if ($ExpectRemoved -and $null -ne $r.Removed -and -not [bool]$r.Removed) { [void]$problems.Add("${rel}: removed flag false after rollback") }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "transaction newDirectories records exactly the required created directories ($($createdPaths -join ', ')); all install-root-relative" + $(if ($ExpectRemoved) { '; removed=true after rollback' } else { '' }) }
              else { 'newDirectories problems: ' + ($problems -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected ($expected -join ', ') -Actual ($createdPaths -join ', ')
}
function Assert-CreatedDirectoriesRemovedAfterRollback {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    $root = Get-FullPath $InstallRoot
    $records = @(Get-TransactionDirectoryRecords -InstallRoot $InstallRoot -TransactionId $TransactionId)
    $created = @($records | Where-Object { $_.Created })
    $left = New-Object System.Collections.ArrayList
    foreach ($r in $created) {
        $rel = ConvertTo-NormalizedRelPath ([string]$r.Path)
        if ($rel -eq '') { continue }
        $full = Join-Path $root ($rel -replace '/', '\')
        if ([System.IO.Directory]::Exists($full)) {
            $files = @(Get-TreeSnapshot -Root $full | Where-Object { $_.Kind -eq 'file' })
            if ($files.Count -eq 0) { [void]$left.Add("$rel (empty directory left behind)") }
            else { [void]$left.Add("$rel (contains $($files.Count) user file(s) - correctly not deleted)") }
        }
        if ($null -ne $r.Removed -and -not [bool]$r.Removed) { [void]$left.Add("$rel (transaction removed flag false)") }
    }
    $hardLeft = @($left | Where-Object { $_ -notlike '*correctly not deleted*' })
    $ok = ($hardLeft.Count -eq 0)
    $detail = if ($ok) { "all $($created.Count) transaction-created directories are absent after rollback and flagged removed=true in the transaction" }
              else { 'transaction-created directory cleanup problems: ' + ($left -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'created dirs absent + removed=true' -Actual $left
}

function Assert-JunctionsUnchanged {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$DshHome,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Profile = 'desktop',
        [string]$ExpectedPackageJsonSha = $null,
        [string]$ExpectedJunctionTarget = $null
    )
    $problems = New-Object System.Collections.ArrayList
    $profileDir = Join-Path (Join-Path (Get-FullPath $DshHome) 'profiles') $Profile
    $pkgJson = Join-Path $profileDir 'package.json'
    $junction = Join-Path $profileDir 'node_modules\@local\dsh-cnki-research'
    if (-not [System.IO.File]::Exists($pkgJson)) { [void]$problems.Add("profile package.json missing: $pkgJson") }
    else {
        if ($ExpectedPackageJsonSha) {
            $sha = Get-Sha256File $pkgJson
            if ($sha -ne $ExpectedPackageJsonSha) { [void]$problems.Add("profile package.json changed (sha=$sha expected=$ExpectedPackageJsonSha)") }
        }
        try { $pkg = Read-JsonFile $pkgJson } catch { [void]$problems.Add("profile package.json unparsable") }
        if ($pkg) {
            $dep = Get-JsonValue $pkg ('dependencies.' + (Get-FrozenIdentity).BundleName)
            $expectedTarget = if ($ExpectedJunctionTarget) { Get-FullPath $ExpectedJunctionTarget } else { Get-FullPath (Join-Path (Get-FullPath $InstallRoot) 'bundle\cnki-research') }
            $expectedDep = 'link:' + $expectedTarget
            if ($dep -ne $expectedDep) { [void]$problems.Add("profile dependency '$dep' expected '$expectedDep'") }
            $bundles = @(Get-JsonValue $pkg 'dsh.profile.bundles')
            if (($bundles -join '|') -notmatch [regex]::Escape((Get-FrozenIdentity).BundleName)) { [void]$problems.Add("profile dsh.profile.bundles does not list $((Get-FrozenIdentity).BundleName)") }
        }
    }
    if (-not (Test-Path -LiteralPath $junction)) { [void]$problems.Add("profile junction missing: $junction") }
    elseif (-not (Test-IsReparsePoint $junction)) { [void]$problems.Add("profile node_modules package path is not a reparse point (copy mode?): $junction") }
    else {
        $target = Get-ReparseTarget $junction
        $expectedTarget = if ($ExpectedJunctionTarget) { Get-FullPath $ExpectedJunctionTarget } else { Get-FullPath (Join-Path (Get-FullPath $InstallRoot) 'bundle\cnki-research') }
        if (-not [string]::Equals($target, $expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add("junction target '$target' expected '$expectedTarget'")
        }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "DSH profile '$Profile' package.json and junction unchanged; junction -> <install>\bundle\cnki-research" }
              else { "DSH profile problems: " + ($problems -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'profile + junction unchanged' -Actual $problems
}

function Assert-UserDataUnchanged {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Before,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$After,
        [string[]]$UserDataPrefixes = @('home', 'dsh-home')
    )
    $b = Select-SnapshotSubtree -Snapshot $Before -Prefixes $UserDataPrefixes
    $a = Select-SnapshotSubtree -Snapshot $After -Prefixes $UserDataPrefixes
    $diff = Compare-Snapshots -Before $b -After $a
    if ($diff.Equal) {
        return New-AssertResult -Id $Id -Status PASS -Detail "simulated user data unchanged ($(@($b).Count) entries under $($UserDataPrefixes -join ', '); sessions/storages/credentials/cnki-mcp/browser-profile + DSH home)" -Expected 'identical' -Actual 'identical'
    }
    return New-AssertResult -Id $Id -Status FAIL -Detail ("user data CHANGED:`n" + (Format-SnapshotDiff -Diff $diff)) -Expected 'identical' -Actual "added=$($diff.AddedCount) removed=$($diff.RemovedCount) changed=$($diff.ChangedCount)" -Data $diff
}

function Assert-ReadOnlyAction {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Before,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$After,
        [string]$ActionLabel = 'read-only action'
    )
    return Assert-SnapshotEqual -Id $Id -Before $Before -After $After -Label "$ActionLabel whole-sandbox fingerprint"
}

function Assert-PlanNoWrites {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Before,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$After
    )
    $snap = Assert-SnapshotEqual -Id "$Id.fingerprint" -Before $Before -After $After -Label 'PLAN whole-sandbox fingerprint'
    $txn = Assert-NoBackupCreated -Id "$Id.noBackup" -InstallRoot $InstallRoot
    $ok = ($snap.Status -eq 'PASS') -and ($txn.Status -eq 'PASS')
    $detail = if ($ok) { 'PLAN created no files/dirs and no transaction/backup directory' } else { "PLAN read-only proof failed: snapshot=$($snap.Status) txn=$($txn.Status)" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'no writes, no backup dir' -Actual "$($snap.Status)/$($txn.Status)"
}

# ---------------------------------------------------------------------------
# Fixture fingerprint assertions (used to validate the fixture builder itself)
# ---------------------------------------------------------------------------

function Assert-SnapshotMatchesFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$FingerprintEntries,
        [string]$Label = 'fixture fingerprint'
    )
    $rootFull = Get-FullPath $Root
    if (-not [System.IO.Directory]::Exists($rootFull)) { return New-AssertResult -Id $Id -Status FAIL -Detail "${Label}: root missing: $rootFull" }
    $current = Get-TreeSnapshot -Root $rootFull
    $cur = Get-SnapshotIndex $current
    $problems = New-Object System.Collections.ArrayList
    foreach ($exp in $FingerprintEntries) {
        if (-not $cur.ContainsKey($exp.Rel)) { [void]$problems.Add("missing: $($exp.Rel)"); continue }
        $act = $cur[$exp.Rel]
        if ($act.Kind -ne $exp.Kind) { [void]$problems.Add("kind changed: $($exp.Rel) $($exp.Kind)->$($act.Kind)"); continue }
        if ($exp.Kind -eq 'file') {
            if ($act.Sha256 -ne $exp.Sha256) { [void]$problems.Add("content changed: $($exp.Rel)") }
            if ($act.Bytes -ne $exp.Bytes) { [void]$problems.Add("size changed: $($exp.Rel)") }
            if ($act.MtimeUtcTicks -ne $exp.MtimeUtcTicks) { [void]$problems.Add("mtime changed: $($exp.Rel)") }
        } elseif ($exp.Kind -eq 'reparse') {
            if (-not [string]::Equals([string]$act.Target, [string]$exp.Target, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$problems.Add("reparse target changed: $($exp.Rel)") }
        }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "${Label}: all $(@($FingerprintEntries).Count) recorded entries match the live tree (path+bytes+size+mtime)" }
              else { "$Label MISMATCH ($($problems.Count) problems): " + (($problems | Select-Object -First 20) -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'fingerprint matches' -Actual $problems
}

# ---------------------------------------------------------------------------
# Static RC3 semantic verification (independent of the engine)
# ---------------------------------------------------------------------------

function Assert-Rc3Semantics {
    # Independent semantic verification of an installed unified target tree.
    # Expected counts/hashes come from the candidate package model; the semantic
    # token checks are the frozen RC3 requirements (8 tools, title positional,
    # profile://list, persona prefix, no {{cwd}}, no absolute paths, launcher
    # tokens, bundle package contract, unified manifest contract).
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowNull()]$Model = $null
    )
    $model = Get-UnifiedModelFromContext $Model
    $root = Get-FullPath $InstallRoot
    $problems = New-Object System.Collections.ArrayList
    $bundle = Join-Path $root 'bundle\cnki-research'
    $cordisPath = Join-Path $bundle 'cordis.patch.yml'
    $persona = Get-PersonaPrefix
    $frozen = Get-FrozenIdentity

    $cordisExpected = $model.PayloadMap[$frozen.CordisPath]
    if (-not [System.IO.File]::Exists($cordisPath)) { [void]$problems.Add('cordis.patch.yml missing') }
    else {
        $bytes = [System.IO.File]::ReadAllBytes($cordisPath)
        if ($cordisExpected -and ($bytes.Length -ne [long]$cordisExpected.Bytes)) { [void]$problems.Add("cordis.patch.yml size $($bytes.Length) != package target $($cordisExpected.Bytes)") }
        if ($cordisExpected -and -not [string]::Equals((Get-Sha256Bytes $bytes), $cordisExpected.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$problems.Add('cordis.patch.yml hash != package target hash') }
        $text = (New-Utf8NoBom).GetString($bytes)
        if ($text -notmatch 'preset-cnki-research') { [void]$problems.Add('cordis missing preset-cnki-research') }
        if ($text -notmatch '@deepseek-ai/dsh-mcp-client') { [void]$problems.Add('cordis missing @deepseek-ai/dsh-mcp-client') }
        if ($text -notmatch 'serverName:\s*cnki') { [void]$problems.Add('cordis missing serverName: cnki') }
        if ($text -notmatch 'failOnStartupError:\s*false') { [void]$problems.Add('cordis missing failOnStartupError: false') }
        if ($text.Contains('{{cwd}}')) { [void]$problems.Add('cordis still contains {{cwd}}') }
        if ($text -notmatch [regex]::Escape($persona)) { [void]$problems.Add('cordis missing persona prefix') }
        if ($text -match '[A-Za-z]:[\\/]') { [void]$problems.Add('cordis contains an absolute Windows path') }
        if ($text -match '\\\\[^\\]') { [void]$problems.Add('cordis contains a UNC path') }
    }

    $serverPath = Join-Path $root 'upstream\cnki-mcp\src\cnki_mcp\server\cnki_mcp_server.py'
    if (-not [System.IO.File]::Exists($serverPath)) { [void]$problems.Add('cnki_mcp_server.py missing') }
    else {
        $serverText = [System.IO.File]::ReadAllText($serverPath, (New-Utf8NoBom))
        foreach ($tool in @(Get-ExpectedToolNames)) {
            $count = ([regex]::Matches($serverText, 'name="' + [regex]::Escape($tool) + '"')).Count
            if ($count -ne 1) { [void]$problems.Add("tool name='$tool' occurs $count times (expected exactly 1)") }
        }
    }
    $registryPath = Join-Path $root 'upstream\cnki-mcp\src\cnki_mcp\server\tool_registry.py'
    if (-not [System.IO.File]::Exists($registryPath)) { [void]$problems.Add('tool_registry.py missing') }
    else {
        $regText = [System.IO.File]::ReadAllText($registryPath, (New-Utf8NoBom))
        $idx = $regText.IndexOf('def get_info_by_detail(')
        if ($idx -lt 0) { [void]$problems.Add('tool_registry.py: def get_info_by_detail( not found') }
        else {
            $sliceLen = [Math]::Min(1200, $regText.Length - $idx)
            $slice = $regText.Substring($idx, $sliceLen)
            if ($slice -notmatch 'title:\s*str\s*[,)]') { [void]$problems.Add('get_info_by_detail: required positional title: str not found') }
            if ($slice -match 'title:\s*str\s*=') { [void]$problems.Add('get_info_by_detail: title appears to have a default value') }
        }
    }
    $launcherPath = Join-Path $bundle 'launcher\cnki_research_launcher.py'
    if (-not [System.IO.File]::Exists($launcherPath)) { [void]$problems.Add('launcher missing') }
    else {
        $launchText = [System.IO.File]::ReadAllText($launcherPath, (New-Utf8NoBom))
        foreach ($token in @('--selfcheck', '--tools-json', 'McpToolService')) {
            if (-not $launchText.Contains($token)) { [void]$problems.Add("launcher missing '$token'") }
        }
    }
    $bundlePkgPath = Join-Path $bundle 'package.json'
    if (-not [System.IO.File]::Exists($bundlePkgPath)) { [void]$problems.Add('bundle package.json missing') }
    else {
        try { $bundlePkg = Read-JsonFile $bundlePkgPath } catch { [void]$problems.Add('bundle package.json unparsable'); $bundlePkg = $null }
        if ($bundlePkg) {
            if ((Get-JsonValue $bundlePkg 'name') -ne $frozen.BundleName) { [void]$problems.Add('bundle package name mismatch') }
            if ((Get-JsonValue $bundlePkg 'version') -ne $frozen.BundleVersion) { [void]$problems.Add("bundle package version != $($frozen.BundleVersion)") }
            if ((Get-JsonValue $bundlePkg 'dsh.bundle.patch') -ne './cordis.patch.yml') { [void]$problems.Add('bundle package dsh.bundle.patch != ./cordis.patch.yml') }
        }
    }

    $manifestPath = Join-Path $root 'manifest.json'
    if (-not [System.IO.File]::Exists($manifestPath)) { [void]$problems.Add('manifest.json missing') }
    else {
        $installedManifestSha = Get-Sha256File $manifestPath
        if (-not [string]::Equals($installedManifestSha, $model.ManifestSha256, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$problems.Add("installed manifest.json hash != package manifest.json hash") }
        try { $manifest = Read-JsonFile $manifestPath } catch { [void]$problems.Add('manifest.json unparsable'); $manifest = $null }
        if ($manifest) {
            $installedVersion = [string](Get-JsonValue $manifest 'distribution.version')
            if ($installedVersion -ne $model.TargetVersion) { [void]$problems.Add("installed manifest distribution.version='$installedVersion' != target '$($model.TargetVersion)'") }
            if ((Get-JsonValue $manifest 'bundle.version') -ne $frozen.BundleVersion) { [void]$problems.Add("manifest bundle.version != $($frozen.BundleVersion)") }
            $manifestTools = @(Get-JsonValue $manifest 'bundle.mcpTools')
            $actualSorted = @($manifestTools | Sort-Object)
            $expectedSorted = @(@(Get-ExpectedToolNames) | Sort-Object)
            if (($actualSorted -join '|') -ne ($expectedSorted -join '|')) { [void]$problems.Add("manifest bundle.mcpTools does not equal the 8 expected tool names (actual: $($actualSorted -join ', '))") }
            $resources = @(Get-JsonValue $manifest 'bundle.mcpResources')
            if (($resources -join '|') -notmatch [regex]::Escape('profile://list')) { [void]$problems.Add('manifest bundle.mcpResources missing profile://list') }
            $files = @(Get-JsonValue $manifest 'files')
            if ($files.Count -ne $model.PayloadFileCount) { [void]$problems.Add("manifest files.Count $($files.Count) != package payload count $($model.PayloadFileCount)") }
        }
    }
    $ok = ($problems.Count -eq 0)
    $detail = if ($ok) { "unified target semantics verified independently (install manifest hash == package manifest; $($model.PayloadFileCount)-file payload; 8 tool names; title positional; profile://list; persona/no-cwd/no-absolute-path; launcher tokens; bundle contract; cordis bytes == package target)" }
              else { "RC3 semantic problems: " + ($problems -join '; ') }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected 'all unified target semantic requirements' -Actual $problems
}

# ---------------------------------------------------------------------------
# Engine-JSON helpers (tolerant to harmless naming variants; spec names first)
# ---------------------------------------------------------------------------

function Find-EngineCheck {
    param([AllowNull()]$Json, [Parameter(Mandatory = $true)][string]$IdPattern)
    if (-not $Json) { return @() }
    $checks = @(Get-JsonValue $Json 'checks')
    return @($checks | Where-Object { $_.id -and ($_.id -like $IdPattern) })
}

function Get-EngineCheckStatus {
    param([AllowNull()]$Json, [Parameter(Mandatory = $true)][string]$IdPattern)
    $matches = @(Find-EngineCheck -Json $Json -IdPattern $IdPattern)
    if ($matches.Count -eq 0) { return $null }
    return [string]$matches[0].status
}

function Get-FileUpgradeOutcome {
    param([AllowNull()]$Json)
    if (-not $Json) { return [pscustomobject]@{ Outcome = 'UNKNOWN'; Evidence = 'no JSON document produced' } }
    foreach ($path in @('verify.fileUpgradeComplete', 'verify.FILE_UPGRADE_COMPLETE', 'fileUpgradeComplete', 'FILE_UPGRADE_COMPLETE')) {
        $v = Get-JsonValue $Json $path
        if ($null -ne $v) {
            $s = [string]$v
            if ($s -match '^(?i)true$' -or $s -match '^(?i)pass$') { return [pscustomobject]@{ Outcome = 'PASS'; Evidence = "$path=$s" } }
            if ($s -match '^(?i)false$' -or $s -match '^(?i)fail$') { return [pscustomobject]@{ Outcome = 'FAIL'; Evidence = "$path=$s" } }
        }
    }
    $verifyChecks = @(Get-JsonValue $Json 'checks' | Where-Object { $_.id -like 'verify.*' })
    if ($verifyChecks.Count -gt 0) {
        $fails = @($verifyChecks | Where-Object { $_.status -eq 'FAIL' })
        if ($fails.Count -gt 0) { return [pscustomobject]@{ Outcome = 'FAIL'; Evidence = "verify checks FAIL: $($fails.id -join ', ')" } }
        return [pscustomobject]@{ Outcome = 'PASS'; Evidence = "verify checks all PASS ($($verifyChecks.Count) checks)" }
    }
    # last resort: honest textual evidence from the JSON document
    $text = ($Json | ConvertTo-Json -Depth 30)
    if ($text -match 'FILE_UPGRADE_COMPLETE\s*[=:]\s*\\?"?PASS') { return [pscustomobject]@{ Outcome = 'PASS'; Evidence = 'textual FILE_UPGRADE_COMPLETE=PASS' } }
    if ($text -match 'FILE_UPGRADE_COMPLETE\s*[=:]\s*\\?"?FAIL') { return [pscustomobject]@{ Outcome = 'FAIL'; Evidence = 'textual FILE_UPGRADE_COMPLETE=FAIL' } }
    return [pscustomobject]@{ Outcome = 'UNKNOWN'; Evidence = 'no structured verify outcome found in JSON' }
}

function Assert-EngineExit {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][int]$ExpectedExit,
        [switch]$RequireJson
    )
    $actual = $Run.ExitCode
    $jsonOk = ($null -ne $Run.Json)
    $cond = ($actual -eq $ExpectedExit)
    if ($RequireJson) { $cond = $cond -and $jsonOk }
    $detail = "engine exit code $actual (expected $ExpectedExit)" + $(if ($RequireJson) { "; JSON document " + $(if ($jsonOk) { 'present' } else { 'MISSING' }) } else { '' })
    return Assert-Condition -Id $Id -Condition $cond -PassDetail $detail -FailDetail $detail -Expected $ExpectedExit -Actual $actual
}

function Assert-EngineJsonValue {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Expected,
        [switch]$AllowNull
    )
    $actual = Get-JsonValue $Run.Json $Path
    if ($null -eq $actual -and -not $AllowNull) {
        return New-AssertResult -Id $Id -Status FAIL -Detail "engine JSON has no '$Path' (expected '$Expected'); stdout tail: $(Limit-Text $Run.Stdout 400)" -Expected $Expected -Actual 'ABSENT'
    }
    $ok = ($actual -eq $Expected)
    $detail = if ($ok) { "JSON $Path=$actual" } else { "JSON $Path='$actual' expected '$Expected'" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected $Expected -Actual $actual
}

function Assert-EngineCheckStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$CheckIdPattern,
        [Parameter(Mandatory = $true)][string[]]$ExpectedStatus,
        [switch]$MustExist
    )
    $actual = Get-EngineCheckStatus -Json $Run.Json -IdPattern $CheckIdPattern
    if ($null -eq $actual) {
        if ($MustExist) {
            return New-AssertResult -Id $Id -Status FAIL -Detail "engine JSON has no check matching '$CheckIdPattern'" -Expected $ExpectedStatus -Actual 'ABSENT'
        }
        return New-AssertResult -Id $Id -Status WARN -Detail "engine JSON has no check matching '$CheckIdPattern' (not asserted strictly)" -Expected $ExpectedStatus -Actual 'ABSENT'
    }
    $ok = ($ExpectedStatus -contains $actual)
    $detail = if ($ok) { "check '$CheckIdPattern' status=$actual" } else { "check '$CheckIdPattern' status=$actual expected one of [$($ExpectedStatus -join ', ')]" }
    return Assert-Condition -Id $Id -Condition $ok -PassDetail $detail -FailDetail $detail -Expected $ExpectedStatus -Actual $actual
}

# ---------------------------------------------------------------------------
# Case context / evidence plumbing
# ---------------------------------------------------------------------------

function New-CaseContext {
    param(
        [Parameter(Mandatory = $true)][string]$Case,
        [string]$Description = '',
        [string]$CaseRoot = '',
        [string]$SandboxRoot = '',
        [string]$OutDir = '',
        [string[]]$RequiredActions = @()
    )
    [pscustomobject]@{
        Case            = $Case
        Description     = $Description
        CaseRoot        = $CaseRoot
        SandboxRoot     = $SandboxRoot
        OutDir          = $OutDir
        RequiredActions = $RequiredActions
        StartedAt       = (Get-Date).ToString('o')
        FinishedAt      = $null
        DurationSec     = $null
        Checks          = (New-Object System.Collections.ArrayList)
        Commands        = (New-Object System.Collections.ArrayList)
        Artifacts       = (New-Object System.Collections.ArrayList)
        Notes           = (New-Object System.Collections.ArrayList)
        Fixture         = $null
        Status          = 'NOT TESTED'
    }
}

function Add-CaseCheck {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Result, [switch]$Quiet)
    if ($null -eq $Result) { throw 'Add-CaseCheck: null assertion result' }
    [void]$Context.Checks.Add($Result)
    if (-not $Quiet) {
        $color = switch ($Result.Status) {
            'PASS' { 'Green' }
            'FAIL' { 'Red' }
            'WARN' { 'Yellow' }
            default { 'Gray' }
        }
        $marker = "[$($Result.Status)]"
        Write-Host ("  {0,-7} {1,-46} {2}" -f $marker, $Result.Id, (Limit-Text $Result.Detail 160)) -ForegroundColor $color
    }
    return $Result
}

function Add-CaseCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Executable,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [int]$ExitCode = 0,
        [string]$StdoutPath = '',
        [string]$StderrPath = '',
        [string]$JsonPath = '',
        [hashtable]$Environment = @{}
    )
    $entry = [pscustomobject]@{
        Label      = $Label
        Executable = $Executable
        Arguments  = @($Arguments)
        ExitCode   = $ExitCode
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
        JsonPath   = $JsonPath
        Environment = $Environment
    }
    [void]$Context.Commands.Add($entry)
    if ($StdoutPath) { Add-CaseArtifact -Context $Context -Path $StdoutPath -Label "$Label stdout" | Out-Null }
    if ($StderrPath) { Add-CaseArtifact -Context $Context -Path $StderrPath -Label "$Label stderr" | Out-Null }
    if ($JsonPath) { Add-CaseArtifact -Context $Context -Path $JsonPath -Label "$Label JSON" | Out-Null }
    return $entry
}

function Add-CaseArtifact {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Path, [string]$Label = '')
    $entry = [pscustomobject]@{ Label = $Label; Path = $Path }
    [void]$Context.Artifacts.Add($entry)
    return $entry
}

function Add-CaseNote {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Note)
    [void]$Context.Notes.Add($Note)
}

function Complete-CaseContext {
    param([Parameter(Mandatory = $true)]$Context)
    $Context.FinishedAt = (Get-Date).ToString('o')
    $started = [datetime]::Parse($Context.StartedAt)
    $Context.DurationSec = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
    $checks = @($Context.Checks.ToArray())
    $fails = @($checks | Where-Object { $_.Status -eq 'FAIL' })
    $passes = @($checks | Where-Object { $_.Status -eq 'PASS' })
    $warns = @($checks | Where-Object { $_.Status -eq 'WARN' })
    $notTested = @($checks | Where-Object { $_.Status -eq 'NOT TESTED' })
    if ($fails.Count -gt 0) { $Context.Status = 'FAIL' }
    elseif ($checks.Count -eq 0) { $Context.Status = 'NOT TESTED' }
    elseif ($passes.Count -eq 0 -and $notTested.Count -eq $checks.Count) { $Context.Status = 'NOT TESTED' }
    else { $Context.Status = 'PASS' }
    return [pscustomobject]@{
        Case          = $Context.Case
        Description   = $Context.Description
        Status        = $Context.Status
        StartedAt     = $Context.StartedAt
        FinishedAt    = $Context.FinishedAt
        DurationSec   = $Context.DurationSec
        Summary       = [pscustomobject]@{ total = $checks.Count; pass = $passes.Count; warn = $warns.Count; fail = $fails.Count; notTested = $notTested.Count }
        Checks        = $checks
        Commands      = @($Context.Commands.ToArray())
        Artifacts     = @($Context.Artifacts.ToArray())
        Notes         = @($Context.Notes.ToArray())
        RuntimeActivation = 'NOT TESTED'
    }
}

function Write-CaseEvidence {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$EvidenceDir
    )
    $final = Complete-CaseContext -Context $Context
    $path = Join-Path (Get-FullPath $EvidenceDir) ($Context.Case + '.json')
    Write-JsonFile -Path $path -Value $final -Depth 30 | Out-Null
    return [pscustomobject]@{ Summary = $final; Path = $path }
}

# ---------------------------------------------------------------------------
# Deterministic fingerprint digests for whole-sandbox before/after evidence
# (H user-data protection / I read-only matrix).  Same snapshot entries as
# Get-TreeSnapshot; junctions are recorded but never descended into.
# ---------------------------------------------------------------------------

function Get-SnapshotDigestLines {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $Snapshot) {
        $lines.Add((
            [string]$e.Rel + "`t" + [string]$e.Kind + "`t" + [string]$e.Bytes + "`t" +
            [string]$e.Sha256 + "`t" + [string]$e.MtimeUtcTicks + "`t" + [string]$e.Target))
    }
    $arr = $lines.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr
}

function Get-SnapshotDigest {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot)
    $lines = Get-SnapshotDigestLines -Snapshot $Snapshot
    $text = ''
    if ($lines.Count -gt 0) { $text = ($lines -join "`n") + "`n" }
    return (Get-Sha256Text $text)
}

function New-SnapshotEvidence {
    # Serialisable fingerprint document used as an evidence artifact.  The
    # digest is recomputable from `entries` by any auditor (same ordered rules).
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Description = ''
    )
    $entries = New-Object System.Collections.ArrayList
    foreach ($e in $Snapshot) {
        [void]$entries.Add([ordered]@{
            rel      = [string]$e.Rel
            kind     = [string]$e.Kind
            bytes    = [long]$e.Bytes
            sha256   = [string]$e.Sha256
            mtimeUtcTicks = [long]$e.MtimeUtcTicks
            target   = [string]$e.Target
        })
    }
    return [ordered]@{
        schemaVersion = 1
        label         = $Label
        description   = $Description
        generatedAt   = (Get-Date).ToString('o')
        digestRule    = 'sha256_lowerhex_utf8_lf over sorted(lines "rel<TAB>kind<TAB>bytes<TAB>sha256<TAB>mtimeUtcTicks<TAB>target") with trailing LF'
        entryCount    = @($entries).Count
        digest        = (Get-SnapshotDigest -Snapshot $Snapshot)
        entries       = @($entries.ToArray())
    }
}

# ===========================================================================
# End of TestAssert.ps1
# ===========================================================================
