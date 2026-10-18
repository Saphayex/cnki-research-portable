#!/usr/bin/env node
// Internal package-closure verification for the unified RC3 candidate.
//
//   node tests/test_unified_package.mjs [--package-root <dir>] [--json]
//        [--write-report <path>] [--expect-payload-count <n>] [--self-test]
//
// WHY THIS EXISTS
// ---------------
// The unified package has a deliberately acyclic, three-layer hash graph
// (UNIFIED_CHARTER D2/D4, metadata-split model):
//
//   SHA256SUMS.txt (S, package-only trust root: every package file except itself)
//        |-- manifest.json (M)                <-- lists ONLY distribution payload P (115)
//        |-- upgrade-data/rc2-to-rc3.json (U) <-- embeds sha256(M) = targetManifestHash
//        |-- upgrade-data/README.md
//        '-- payload files P                 <-- M.files[] hashes == U.expectedTargetHashes
//
// `build_manifest.mjs --check` only proves M <-> working tree. This test re-derives the
// whole graph from the shipped bytes, independently of builder code, and additionally
// enforces the package shape rules (no payload/ dir, no internal material, metadata never
// listed as payload, no development paths/credentials).
//
// Checks: C1 layout, C2 manifest identity, C3 S closure, C4 S hashes, C5 M closure,
// C6 U identity, C7 U counts, C8 U<->M binding, C9 changedFiles shape, C10 frozen RC2
// anchors + hotfix overrides, C11 payload set hashes, C12 metadata-never-installed,
// C13 internal material/leftovers/credentials, C14 dev-machine paths.
//
// Exit codes: 0 all PASS (WARN allowed), 1 at least one FAIL, 2 harness error.
// --self-test builds a synthetic package in the OS temp dir (positive + negative control)
// and needs no real candidate.

import { createHash } from 'node:crypto';
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
function argValue(flag, fallback = null) {
  const index = argv.indexOf(flag);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : fallback;
}
const asJson = argv.includes('--json');
const selfTest = argv.includes('--self-test');
const reportPath = argValue('--write-report');
const packageRoot = resolve(argValue('--package-root', resolve(here, '..')));
const expectPayloadCountRaw = argValue('--expect-payload-count');
const expectPayloadCount = expectPayloadCountRaw === null ? null : Number(expectPayloadCountRaw);

// Frozen DESIGN constants (UNIFIED_CHARTER D3/D4). Build-derived counts are cross-checked
// against the package instead of blindly trusted; --expect-payload-count can pin P.
const FROZEN = {
  rc2ManifestSha: '80229318a1ef070f5cedafda39785be0cbb49ee727f7a620e7e6aab5113a6e1f',
  rc2PackageSha: '4f279f359a42e5e950cd9f66e04f0922c5e40ec4c77f9192e2168274ce1142b5',
  rc2PackageBytes: 388236,
  rc2SourcePayloadCount: 107,
  cordisPath: 'bundle/cnki-research/cordis.patch.yml',
  cordisRc2Sha: 'afa6ffdd0684fe0440a5e3d2414c08fe36be946e64c19648c48b3770f68bf343',
  hotfixLine: 'edda8817e0bf449d8324f4875b1c7acd37a8dc693c3a82d044f4a5c436421778',
  hotfixText: 'b5aaa79ebb7a0c1bdd6f253e6462b0c1ee3db8f4f34cf15e83e0a59a37e4c0a9',
  sourceVersion: '1.0.0-rc.2',
  targetVersion: '1.0.0-rc.3',
  bundleVersion: '1.0.0',
  upgradeData: 'upgrade-data/rc2-to-rc3.json',
  upgradeReadme: 'upgrade-data/README.md',
  manifest: 'manifest.json',
  sums: 'SHA256SUMS.txt',
  upgradeId: 'cnki-portable-1.0.0-rc.2-to-1.0.0-rc.3-unified',
  kind: 'cnki-research-portable-unified-upgrade',
  distributionId: 'cnki-research-portable-unified-1.0.0-rc.3',
  addedPayload: [
    'tools/setup.ps1',
    'tools/lib/UpgradeCommon.ps1',
    'tools/build_unified_release.ps1',
    'tests/Test-UnifiedMatrix.ps1',
    'tests/lib/UnifiedFixtures.ps1',
    'tests/lib/UnifiedAssert.ps1',
    'tests/Test-UnifiedVerification.ps1',
    'tests/test_unified_package.mjs',
  ],
  frozenChangedPayloadCount: 15,
  minExtraEdits: 0,
  maxExtraEdits: 5,
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
let results = [];
function record(id, status, detail) { results.push({ id, status, detail }); }
const pass = (id, detail) => record(id, 'PASS', detail);
const fail = (id, detail) => record(id, 'FAIL', detail);
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const sha256File = (p) => sha256(readFileSync(p));
const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));
const toPosix = (p) => p.split(sep).join('/');

const SKIP_DIRS = new Set(['.git', 'dist', '_scratch', '_portable', 'test-evidence', 'node_modules', '.venv', '__pycache__']);
function walkFiles(root) {
  const out = [];
  const visit = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name)) continue;
        visit(join(dir, entry.name));
      } else if (entry.isFile()) {
        out.push(toPosix(relative(root, join(dir, entry.name))));
      }
    }
  };
  visit(root);
  return out.sort();
}
function parseSums(text) {
  const entries = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    // Accepted dialects (V1-compatible, authoritative for the unified package):
    //   <sha256>  *<path>   (two spaces + asterisk; Upgrader V1 internal format)
    //   <sha256>  <path>    (two spaces)
    //   <sha256> <path>     (single space)
    //   <sha256> *<path>    (single space + asterisk)
    const m = /^([0-9a-f]{64})\s+\*?(\S.*)$/.exec(line);
    if (!m) return { error: `bad SHA256SUMS line: ${line.slice(0, 120)}`, entries };
    entries.push({ sha: m[1], path: m[2].trim().replace(/\\/g, '/') });
  }
  return { entries };
}
function listDirSorted(p) { return existsSync(p) ? readdirSync(p).sort() : []; }

// Development-machine detector. Regex literals below do not match their own source text
// (they need a real drive path with a separator), except the workspace-name string which
// is assembled from fragments so the shipped detector stays clean under the RC3 A3 scan.
const DEV_MARKERS = [
  { re: /F:[\\/]DSH/i, label: 'development drive path' },
  { re: /F:[\\/]cnki-mcp/i, label: 'development upstream path' },
  { re: new RegExp(['cnki', '-', 'mcp', ' ', 'Mode'].join(''), 'i'), label: 'development workspace name' },
  { re: /[A-Za-z]:[\\/](?:Users|用户)[\\/][^\\/\s"']+/i, label: 'absolute user-profile path' },
  { re: /D:[\\/]DeepSeekHarness/i, label: 'development tool install path' },
  { re: new RegExp(['\\.', 'dsh', '-', 'cnki', '-', 'profile'].join(''), 'i'), label: 'development browser-profile path' },
];
const CRED_MARKERS = [
  { re: /BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY/, label: 'private key material' },
  { re: new RegExp(['"domain"\\s*:\\s*"', '\\.?cnki', '\\.net"'].join(''), 'i'), label: 'CNKI cookie jar' },
  { re: /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\./, label: 'JWT-like token' },
  { re: new RegExp(['sk', '-[A-Za-z0-9]{20,}'].join('')), label: 'API-key literal' },
];
const DEV_PATH_EXEMPT = [
  /^docs\/provenance\//,
  /^tests\/test_static_package\.mjs$/,
  /^tests\/test_unified_package\.mjs$/,
  /^PROJECT_STATE\.md$/,
  /^PORTABLE_(?:BUILD|TEST|SECURITY|RELEASE)_REPORT\.md$/,
];

// ---------------------------------------------------------------------------
// validator
// ---------------------------------------------------------------------------
function verifyPackage(rootDir, opts = {}) {
  results = [];
  const rootResolved = resolve(rootDir);
  const expectAdded = opts.addedPayload || FROZEN.addedPayload;
  const expectedPayloadCount = opts.expectPayloadCount ?? null;
  const synthetic = opts.synthetic === true;
  const sourceCount = opts.sourcePayloadCount ?? FROZEN.rc2SourcePayloadCount;
  const enforceReplaceRange = opts.enforceReplaceRange !== false;

  const manifestPath = join(rootResolved, FROZEN.manifest);
  const sumsPath = join(rootResolved, FROZEN.sums);
  const upgradePath = join(rootResolved, FROZEN.upgradeData);
  const upgradeReadmePath = join(rootResolved, FROZEN.upgradeReadme);

  // C1 layout
  {
    const problems = [];
    for (const [rel, label] of [[FROZEN.manifest, 'manifest.json'], [FROZEN.sums, 'SHA256SUMS.txt'],
      [FROZEN.upgradeData, 'upgrade-data/rc2-to-rc3.json'], [FROZEN.upgradeReadme, 'upgrade-data/README.md']]) {
      if (!existsSync(join(rootResolved, rel.split('/').join(sep)))) problems.push(`${label} missing`);
    }
    if (existsSync(join(rootResolved, 'payload'))) problems.push('forbidden payload/ directory present');
    const upgradeEntries = listDirSorted(dirname(upgradePath));
    if (upgradeEntries.join('|') !== 'README.md|rc2-to-rc3.json') problems.push(`upgrade-data/ must contain exactly README.md + rc2-to-rc3.json; found [${upgradeEntries.join(', ')}]`);
    if (!synthetic && !existsSync(join(rootResolved, 'VERSION'))) problems.push('VERSION missing');
    if (problems.length) fail('C1.layout', problems.join('; '));
    else pass('C1.layout', 'package root is the distribution tree: manifest + SHA256SUMS + exactly 2 upgrade-data files; no payload/ dir');
  }
  if (!existsSync(manifestPath) || !existsSync(sumsPath) || !existsSync(upgradePath)) return;

  const sumsBytes = readFileSync(sumsPath);
  const manifestBytes = readFileSync(manifestPath);
  const manifest = readJson(manifestPath);
  const upgrade = readJson(upgradePath);
  const actualFiles = walkFiles(rootResolved);
  const payloadFiles = Array.isArray(manifest.files) ? manifest.files : [];
  const payloadByPath = new Map(payloadFiles.map((f) => [f.path, f]));
  const payloadCount = payloadFiles.length;

  // C2 manifest identity
  {
    const problems = [];
    if (manifest.schemaVersion !== 1) problems.push(`manifest.schemaVersion=${manifest.schemaVersion} expected 1`);
    if (manifest.distribution?.version !== FROZEN.targetVersion) problems.push(`distribution.version=${manifest.distribution?.version} expected ${FROZEN.targetVersion}`);
    if (manifest.bundle?.version !== undefined && manifest.bundle.version !== FROZEN.bundleVersion) problems.push(`bundle.version=${manifest.bundle.version} expected ${FROZEN.bundleVersion}`);
    if (manifest.install?.entryPoint !== 'tools/portable.ps1') problems.push('install.entryPoint must stay tools/portable.ps1');
    if (manifest.install?.setupEntryPoint !== 'tools/setup.ps1') problems.push('install.setupEntryPoint must be tools/setup.ps1');
    if (!manifest.upgrade || typeof manifest.upgrade !== 'object') problems.push('manifest.upgrade block missing');
    else {
      if (manifest.upgrade.data !== FROZEN.upgradeData) problems.push(`manifest.upgrade.data=${manifest.upgrade.data}`);
      if (manifest.upgrade.schemaVersion !== 2) problems.push(`manifest.upgrade.schemaVersion=${manifest.upgrade.schemaVersion} expected 2`);
      if (manifest.upgrade.upgradeId !== FROZEN.upgradeId) problems.push(`manifest.upgrade.upgradeId=${manifest.upgrade.upgradeId}`);
      if (manifest.upgrade.sourceVersion !== FROZEN.sourceVersion) problems.push(`manifest.upgrade.sourceVersion=${manifest.upgrade.sourceVersion}`);
      if (manifest.upgrade.targetVersion !== FROZEN.targetVersion) problems.push(`manifest.upgrade.targetVersion=${manifest.upgrade.targetVersion}`);
    }
    if (!Array.isArray(manifest.files) || manifest.files.length === 0) problems.push('manifest.files[] missing/empty');
    if (problems.length) fail('C2.manifestIdentity', problems.join('; '));
    else pass('C2.manifestIdentity', `manifest schemaVersion=1, distribution ${FROZEN.targetVersion}, entryPoint portable.ps1 + setupEntryPoint setup.ps1, upgrade block schema 2`);
  }

  // C3 S closure
  const sums = parseSums(sumsBytes.toString('utf8'));
  {
    const problems = [];
    if (sums.error) problems.push(sums.error);
    const text = sumsBytes.toString('utf8');
    if (text.charCodeAt(0) === 0xFEFF) problems.push('SHA256SUMS.txt has a UTF-8 BOM');
    if (text.includes('\r')) problems.push('SHA256SUMS.txt contains CR (must be LF only)');
    const paths = sums.entries.map((e) => e.path);
    if (new Set(paths).size !== paths.length) problems.push('duplicate paths in SHA256SUMS.txt');
    const expectedSet = actualFiles.filter((p) => p !== FROZEN.sums);
    const listed = new Set(paths);
    const missing = expectedSet.filter((p) => !listed.has(p));
    const unlisted = paths.filter((p) => !expectedSet.includes(p));
    if (missing.length) problems.push(`not listed in S: ${missing.slice(0, 8).join(', ')}${missing.length > 8 ? ` (+${missing.length - 8})` : ''}`);
    if (unlisted.length) problems.push(`S lists absent files: ${unlisted.slice(0, 8).join(', ')}${unlisted.length > 8 ? ` (+${unlisted.length - 8})` : ''}`);
    const sorted = [...paths].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    if (paths.join('|') !== sorted.join('|')) problems.push('SHA256SUMS.txt is not sorted by ordinal path');
    if (problems.length) fail('C3.sumsFileSet', problems.join('; '));
    else pass('C3.sumsFileSet', `S lists every package file except itself (${paths.length} entries), sorted/LF/no-BOM`);
  }

  // C4 S hashes
  {
    const bad = [];
    for (const entry of sums.entries) {
      const full = join(rootResolved, entry.path.split('/').join(sep));
      if (!existsSync(full) || !statSync(full).isFile()) { bad.push(`missing ${entry.path}`); continue; }
      if (sha256File(full) !== entry.sha) bad.push(`hash ${entry.path}`);
    }
    if (bad.length) fail('C4.sumsHashes', `${bad.length} mismatching S entries: ${bad.slice(0, 8).join('; ')}`);
    else pass('C4.sumsHashes', `all ${sums.entries.length} SHA256SUMS hashes match the bytes on disk`);
  }

  // C5 M closure
  {
    const problems = [];
    const paths = payloadFiles.map((f) => String(f.path || ''));
    if (new Set(paths).size !== paths.length) problems.push('duplicate paths in manifest.files[]');
    const metadataListed = paths.filter((p) => p === FROZEN.manifest || p === FROZEN.sums || p.startsWith('upgrade-data/'));
    if (metadataListed.length) problems.push(`metadata wrongly listed in manifest.files[]: ${metadataListed.join(', ')}`);
    const bad = [];
    for (const f of payloadFiles) {
      if (!f || typeof f.path !== 'string') { bad.push('entry without path'); continue; }
      const full = join(rootResolved, f.path.split('/').join(sep));
      if (!existsSync(full) || !statSync(full).isFile()) { bad.push(`missing ${f.path}`); continue; }
      const bytes = statSync(full).size;
      if (f.bytes !== bytes) bad.push(`size ${f.path} (${bytes} != ${f.bytes})`);
      if (sha256File(full) !== f.sha256) bad.push(`sha256 ${f.path}`);
    }
    const allow = new Set([...paths, FROZEN.manifest, FROZEN.sums, FROZEN.upgradeData, FROZEN.upgradeReadme]);
    const extras = actualFiles.filter((p) => !allow.has(p));
    if (extras.length) problems.push(`unexpected package files: ${extras.slice(0, 8).join(', ')}`);
    if (bad.length) problems.push(`${bad.length} payload problem(s): ${bad.slice(0, 8).join('; ')}`);
    const expectedCount = expectedPayloadCount ?? upgrade.payloadFileCount;
    if (expectedCount !== payloadCount) problems.push(`payload count ${payloadCount} != expected ${expectedCount}`);
    if (problems.length) fail('C5.manifestFiles', problems.join('; '));
    else pass('C5.manifestFiles', `manifest.files[] lists exactly ${payloadCount} payload files (files exist, sizes+hashes match); no metadata listed`);
  }

  // C6 U identity
  {
    const problems = [];
    if (upgrade.schemaVersion !== 2) problems.push(`schemaVersion=${upgrade.schemaVersion} expected 2`);
    if (upgrade.kind !== FROZEN.kind) problems.push(`kind=${upgrade.kind}`);
    if (upgrade.upgradeId !== FROZEN.upgradeId) problems.push(`upgradeId=${upgrade.upgradeId}`);
    if (!/^\d+\.\d+\.\d+$/.test(String(upgrade.upgraderVersion))) problems.push(`upgraderVersion=${upgrade.upgraderVersion} not semver`);
    if (upgrade.distributionId !== FROZEN.distributionId) problems.push(`distributionId=${upgrade.distributionId}`);
    if (upgrade.payloadRoot !== '.') problems.push(`payloadRoot=${upgrade.payloadRoot} expected "."`);
    if (upgrade.sourceDistributionVersion !== FROZEN.sourceVersion) problems.push(`sourceDistributionVersion=${upgrade.sourceDistributionVersion}`);
    if (upgrade.targetDistributionVersion !== FROZEN.targetVersion) problems.push(`targetDistributionVersion=${upgrade.targetDistributionVersion}`);
    if (upgrade.distributionManifestSchemaVersion !== 1) problems.push(`distributionManifestSchemaVersion=${upgrade.distributionManifestSchemaVersion}`);
    if (!Array.isArray(upgrade.allowedSourceStates) || upgrade.allowedSourceStates.join('|') !== 'RC2_CLEAN|RC2_HOTFIXED') problems.push(`allowedSourceStates=${JSON.stringify(upgrade.allowedSourceStates)}`);
    if (!synthetic) {
      if (upgrade.sourceManifestHash !== FROZEN.rc2ManifestSha) problems.push('sourceManifestHash != frozen RC2 manifest sha');
      if (upgrade.sourcePackageHash !== FROZEN.rc2PackageSha) problems.push('sourcePackageHash != frozen RC2 zip sha');
      if (upgrade.sourcePackageBytes !== FROZEN.rc2PackageBytes) problems.push(`sourcePackageBytes=${upgrade.sourcePackageBytes} != ${FROZEN.rc2PackageBytes}`);
    }
    if (problems.length) fail('C6.upgradeIdentity', problems.join('; '));
    else pass('C6.upgradeIdentity', 'U schemaVersion 2 (kind/upgradeId/distributionId/payloadRoot). rc2 anchors embedded, allowed states RC2_CLEAN|RC2_HOTFIXED');
  }

  // C7 U counts
  {
    const problems = [];
    if (upgrade.payloadFileCount !== payloadCount) problems.push(`payloadFileCount=${upgrade.payloadFileCount} != M.files ${payloadCount}`);
    if (upgrade.sourcePayloadFileCount !== sourceCount) problems.push(`sourcePayloadFileCount=${upgrade.sourcePayloadFileCount} != ${sourceCount}`);
    const expectedTarget = upgrade.expectedTargetHashes && typeof upgrade.expectedTargetHashes === 'object' ? Object.keys(upgrade.expectedTargetHashes) : null;
    if (!expectedTarget) problems.push('expectedTargetHashes missing');
    else if (expectedTarget.length !== payloadCount) problems.push(`expectedTargetHashes=${expectedTarget.length} != payload ${payloadCount}`);
    const expectedSource = upgrade.expectedSourceHashes && typeof upgrade.expectedSourceHashes === 'object' ? Object.keys(upgrade.expectedSourceHashes) : null;
    if (!expectedSource) problems.push('expectedSourceHashes missing');
    else if (expectedSource.length !== sourceCount) problems.push(`expectedSourceHashes=${expectedSource.length} != ${sourceCount}`);
    const changed = Array.isArray(upgrade.changedFiles) ? upgrade.changedFiles : null;
    if (!changed) problems.push('changedFiles missing');
    else {
      if (upgrade.changedFileCount !== changed.length) problems.push(`changedFileCount=${upgrade.changedFileCount} != changedFiles.length ${changed.length}`);
      const addCount = changed.filter((c) => c.operation === 'add').length;
      if (upgrade.addedFileCount !== addCount) problems.push(`addedFileCount=${upgrade.addedFileCount} != ${addCount}`);
      if (upgrade.removedFileCount !== 0) problems.push(`removedFileCount=${upgrade.removedFileCount} expected 0`);
    }
    if (problems.length) fail('C7.upgradeCounts', problems.join('; '));
    else pass('C7.upgradeCounts', `U self-consistent: payload=${payloadCount}, source=${sourceCount}, changed=${upgrade.changedFileCount}, added=${upgrade.addedFileCount}, removed=0`);
  }

  // C8 U <-> M binding
  {
    const problems = [];
    const expectedTarget = upgrade.expectedTargetHashes || {};
    for (const [path, sha] of Object.entries(expectedTarget)) {
      const entry = payloadByPath.get(path);
      if (!entry) { problems.push(`expectedTargetHashes non-payload path: ${path}`); continue; }
      if (entry.sha256 !== sha) problems.push(`target hash mismatch: ${path}`);
    }
    const missing = payloadFiles.map((f) => f.path).filter((p) => !(p in expectedTarget));
    if (missing.length) problems.push(`payload paths missing from expectedTargetHashes: ${missing.slice(0, 8).join(', ')}`);
    const manifestSha = sha256(manifestBytes);
    if (upgrade.targetManifestHash !== manifestSha) problems.push(`targetManifestHash != sha256(manifest.json) (${manifestSha})`);
    if (problems.length) fail('C8.targetManifestBinding', problems.join('; '));
    else pass('C8.targetManifestBinding', `expectedTargetHashes == manifest.files[] for all ${payloadCount} paths; targetManifestHash == sha256(manifest.json)`);
  }

  // C9 changedFiles
  {
    const problems = [];
    const changed = Array.isArray(upgrade.changedFiles) ? upgrade.changedFiles : [];
    for (const op of new Set(changed.map((c) => c.operation))) if (op !== 'replace' && op !== 'add') problems.push(`unexpected operation ${op}`);
    const adds = changed.filter((c) => c.operation === 'add').map((c) => c.path).sort();
    const expectedAdds = [...expectAdded].sort();
    if (adds.join('|') !== expectedAdds.join('|')) problems.push(`add set mismatch [${adds.join(', ')}] != frozen [${expectedAdds.join(', ')}]`);
    for (const c of changed) {
      if (c.path === FROZEN.manifest) {
        if (c.operation !== 'replace') problems.push('manifest.json entry operation must be replace');
        if (c.classification !== 'distribution-metadata') problems.push(`manifest.json classification=${c.classification}`);
        if (c.targetSha256 !== sha256(manifestBytes)) problems.push('manifest.json targetSha256 != sha256(manifest.json)');
        if (c.targetBytes !== manifestBytes.length) problems.push('manifest.json targetBytes mismatch');
        if (!synthetic && c.sourceSha256 !== FROZEN.rc2ManifestSha) problems.push('manifest.json sourceSha256 != frozen RC2 manifest sha');
        continue;
      }
      const target = payloadByPath.get(c.path);
      if (c.operation === 'add') {
        if (c.sourceSha256 !== null && c.sourceSha256 !== undefined) problems.push(`add ${c.path} must have sourceSha256=null`);
        if (!target) problems.push(`add ${c.path} not in manifest.files[]`);
        if (c.classification !== 'payload') problems.push(`add ${c.path} classification=${c.classification}`);
      } else {
        if (!target) problems.push(`replace ${c.path} not in manifest.files[]`);
        else if (target.sha256 !== c.targetSha256) problems.push(`replace ${c.path} targetSha256 != manifest`);
        if (!/^[0-9a-f]{64}$/.test(String(c.sourceSha256))) problems.push(`replace ${c.path} sourceSha256 invalid`);
      }
      if (!c.targetSha256) problems.push(`changed ${c.path} has no targetSha256`);
      if ('hashSource' in c) problems.push(`changed ${c.path} carries forbidden hashSource`);
      if (!Number.isInteger(c.targetBytes) || c.targetBytes <= 0) problems.push(`changed ${c.path} targetBytes invalid`);
      if (c.path === FROZEN.upgradeData || c.path === FROZEN.sums) problems.push(`changedFiles must not reference ${c.path}`);
    }
    const replaces = changed.filter((c) => c.operation === 'replace').length;
    const extraEdits = replaces - (FROZEN.frozenChangedPayloadCount + 1); // 15 frozen payload replaces + manifest
    if (enforceReplaceRange) {
      if (extraEdits < FROZEN.minExtraEdits || extraEdits > FROZEN.maxExtraEdits) {
        problems.push(`replace count ${replaces} => m=${extraEdits} outside allowed 0..5 (changedFileCount 24+m)`);
      }
    }
    if (problems.length) fail('C9.changedFiles', problems.slice(0, 10).join('; '));
    else pass('C9.changedFiles', `${changed.length} changed files (${replaces} replaces, ${adds.length} adds; m=${extraEdits} extra edits beyond the 15 frozen RC2->RC3 replaces + manifest); ops/classifications/paths/hashes consistent; manifest.json replace binds sha256(M)`);
  }

  // C10 frozen RC2 anchors
  if (!synthetic) {
    const problems = [];
    const source = upgrade.expectedSourceHashes || {};
    if (source[FROZEN.cordisPath] !== FROZEN.cordisRc2Sha) problems.push('expectedSourceHashes[cordis] != frozen RC2 cordis sha');
    const addPaths = new Set((upgrade.changedFiles || []).filter((c) => c.operation === 'add').map((c) => c.path));
    const overlap = Object.keys(source).filter((p) => addPaths.has(p));
    if (overlap.length) problems.push(`added files present in expectedSourceHashes: ${overlap.join(', ')}`);
    const hot = (upgrade.hotfixedSourceOverrides || {})[FROZEN.cordisPath] || {};
    if (hot.HOTFIX_LINE_REMOVED !== FROZEN.hotfixLine) problems.push('HOTFIX_LINE_REMOVED override mismatch');
    if (hot.HOTFIX_TEXT_REMOVED !== FROZEN.hotfixText) problems.push('HOTFIX_TEXT_REMOVED override mismatch');
    if (problems.length) fail('C10.frozenRc2', problems.join('; '));
    else pass('C10.frozenRc2', 'expectedSourceHashes holds the 107 frozen RC2 anchors (cordis + both hotfix overrides verbatim); adds absent from source map');
  }

  // C11 payload set hashes
  {
    const problems = [];
    const changed = Array.isArray(upgrade.changedFiles) ? upgrade.changedFiles : [];
    const payloadChanged = changed.filter((c) => c.classification === 'payload');
    const lines = payloadChanged
      .map((c) => `${c.path}\t${c.operation === 'add' ? 'ADD' : c.sourceSha256}\t${c.targetSha256}\n`)
      .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const computed = sha256(Buffer.from(lines.join(''), 'utf8'));
    if (upgrade.payloadSetHash !== computed) problems.push(`payloadSetHash mismatch (recomputed ${computed})`);
    const source = upgrade.expectedSourceHashes || {};
    const srcLines = Object.keys(source).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)).map((p) => `${p}\t${source[p]}\n`);
    const computedSource = sha256(Buffer.from(srcLines.join(''), 'utf8'));
    if (upgrade.sourcePayloadSetHash !== computedSource) problems.push(`sourcePayloadSetHash mismatch (recomputed ${computedSource})`);
    if (problems.length) fail('C11.payloadSetHashes', problems.join('; '));
    else pass('C11.payloadSetHashes', 'payloadSetHash and sourcePayloadSetHash recompute from declared material and match');
  }

  // C12 metadata never installed
  {
    const problems = [];
    const listed = payloadFiles.map((f) => f.path);
    for (const forbidden of [FROZEN.upgradeData, FROZEN.upgradeReadme, FROZEN.sums, FROZEN.manifest]) {
      if (listed.includes(forbidden)) problems.push(`${forbidden} must not be in manifest.files[]`);
    }
    for (const p of listed) if (p.startsWith('upgrade-data/')) problems.push(`upgrade-data path in manifest.files[]: ${p}`);
    if (problems.length) fail('C12.notInstalled', problems.join('; '));
    else pass('C12.notInstalled', 'payload P excludes manifest.json, SHA256SUMS.txt, upgrade-data/**: installed target state is P + manifest.json only');
  }

  // C13 internal material / leftovers / credentials
  {
    const problems = [];
    const all = [...actualFiles];
    const forbiddenDir = (p) => ['_AUDIT/', '_SPEC/', '_evidence/', '_build/', '_verify/', 'sandbox/', 'payload/', 'dist/', '.git/', 'node_modules/', '.venv/', '_portable/', 'test-evidence/', '__pycache__/'].some((d) => p.startsWith(d));
    const forbiddenFile = (p) => /^UNIFIED_.*\.md$/.test(p) || p === 'RELEASE_MANIFEST.json' || /\.(log|pyc)$/.test(p)
      || /(^|\/)(cookies|storage_state)\.json$/.test(p) || /\.credentials\.yaml$/.test(p);
    const bad = all.filter((p) => forbiddenDir(p) || forbiddenFile(p));
    if (bad.length) problems.push(`internal/development material present: ${bad.slice(0, 8).join(', ')}`);
    for (const p of all) {
      if (/\.(png|jpg|jpeg|gif|webp|ico|zip|whl|exe|dll|woff2?)$/i.test(p)) continue;
      const full = join(rootResolved, p.split('/').join(sep));
      if (!existsSync(full)) continue;
      const bytes = readFileSync(full);
      if (bytes.includes(0)) continue;
      const text = bytes.toString('utf8');
      for (const { re, label } of CRED_MARKERS) if (re.test(text)) problems.push(`${p}: ${label}`);
    }
    if (problems.length) fail('C13.noInternalMaterial', problems.slice(0, 8).join('; '));
    else pass('C13.noInternalMaterial', 'no internal material, logs, pyc, venv, cookies/credentials/tokens in the package tree');
  }

  // C14 dev paths
  {
    const hits = [];
    for (const p of actualFiles) {
      if (DEV_PATH_EXEMPT.some((re) => re.test(p))) continue;
      const full = join(rootResolved, p.split('/').join(sep));
      let bytes;
      try { bytes = readFileSync(full); } catch { continue; }
      if (bytes.includes(0)) continue;
      const text = bytes.toString('utf8');
      for (const { re, label } of DEV_MARKERS) if (re.test(text)) hits.push(`${p}: ${label}`);
    }
    if (hits.length) fail('C14.noDevPaths', hits.slice(0, 8).join('; '));
    else pass('C14.noDevPaths', `no development-machine absolute/workspace paths in ${actualFiles.length} package files`);
  }
  return results;
}

// ---------------------------------------------------------------------------
// synthetic self-test (positive + negative control)
// ---------------------------------------------------------------------------
function buildSyntheticPackage() {
  const root = mkdtempSync(join(tmpdir(), 'unified-pkg-selftest-'));
  const w = (rel, text) => { const full = join(root, rel.split('/').join(sep)); mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, text); };
  const wj = (rel, obj) => w(rel, JSON.stringify(obj, null, 2) + '\n');
  const sourceHashes = { 'readme.md': sha256(Buffer.from('readme rc2\n')), 'version.md': sha256(Buffer.from('version rc2\n')) };
  const payload = [
    { path: 'readme.md', content: 'readme unified\n' },
    { path: 'version.md', content: 'version unified\n' },
    { path: 'tools/setup.ps1', content: 'write-host setup\n' },
    { path: 'tests/test_unified_package.mjs', content: 'export {};\n' },
  ];
  const added = ['tools/setup.ps1', 'tests/test_unified_package.mjs'];
  const files = payload.map((f) => {
    w(f.path, f.content);
    return { path: f.path, bytes: Buffer.byteLength(f.content), sha256: sha256(Buffer.from(f.content)) };
  });
  const manifest = {
    schemaVersion: 1,
    distribution: { version: '1.0.0-rc.3' },
    bundle: { version: '1.0.0' },
    install: { entryPoint: 'tools/portable.ps1', setupEntryPoint: 'tools/setup.ps1' },
    upgrade: { schemaVersion: 2, data: FROZEN.upgradeData, upgradeId: FROZEN.upgradeId, sourceVersion: '1.0.0-rc.2', targetVersion: '1.0.0-rc.3' },
    files,
  };
  wj('manifest.json', manifest);
  const manifestSha = sha256File(join(root, 'manifest.json'));
  const changed = [
    { path: 'readme.md', operation: 'replace', classification: 'payload', sourceSha256: sourceHashes['readme.md'], targetSha256: files[0].sha256, targetBytes: files[0].bytes },
    { path: 'version.md', operation: 'replace', classification: 'payload', sourceSha256: sourceHashes['version.md'], targetSha256: files[1].sha256, targetBytes: files[1].bytes },
    { path: 'tools/setup.ps1', operation: 'add', classification: 'payload', sourceSha256: null, targetSha256: files[2].sha256, targetBytes: files[2].bytes },
    { path: 'tests/test_unified_package.mjs', operation: 'add', classification: 'payload', sourceSha256: null, targetSha256: files[3].sha256, targetBytes: files[3].bytes },
    { path: 'manifest.json', operation: 'replace', classification: 'distribution-metadata', sourceSha256: FROZEN.rc2ManifestSha, targetSha256: manifestSha, targetBytes: statSync(join(root, 'manifest.json')).size },
  ];
  const payloadChanged = changed.filter((c) => c.classification === 'payload');
  const payloadSetHash = sha256(Buffer.from(payloadChanged.map((c) => `${c.path}\t${c.operation === 'add' ? 'ADD' : c.sourceSha256}\t${c.targetSha256}\n`).sort().join(''), 'utf8'));
  const sourcePayloadSetHash = sha256(Buffer.from(Object.keys(sourceHashes).sort().map((p) => `${p}\t${sourceHashes[p]}\n`).join(''), 'utf8'));
  const upgrade = {
    schemaVersion: 2, kind: FROZEN.kind, upgradeId: FROZEN.upgradeId, upgraderVersion: '2.0.0',
    distributionId: FROZEN.distributionId, createdUtc: '2026-10-18T00:00:00Z', payloadRoot: '.',
    sourceManifestHash: FROZEN.rc2ManifestSha, targetManifestHash: manifestSha,
    sourcePackageHash: FROZEN.rc2PackageSha, sourcePackageBytes: FROZEN.rc2PackageBytes,
    targetPackageHash: null, sourcePayloadFileCount: 2, payloadFileCount: files.length,
    changedFileCount: changed.length, addedFileCount: 2, removedFileCount: 0,
    distributionManifestSchemaVersion: 1, allowedSourceStates: ['RC2_CLEAN', 'RC2_HOTFIXED'],
    sourceDistributionVersion: '1.0.0-rc.2', targetDistributionVersion: '1.0.0-rc.3',
    expectedSourceHashes: sourceHashes,
    expectedTargetHashes: Object.fromEntries(files.map((f) => [f.path, f.sha256])),
    changedFiles: changed, hotfixedSourceOverrides: {}, environmentFiles: [], preservedDirectories: [],
    rollbackMetadata: {}, minimumRequirements: {}, validation: {},
    payloadSetHash, sourcePayloadSetHash,
  };
  wj(FROZEN.upgradeData, upgrade);
  w(FROZEN.upgradeReadme, '# upgrade data\n');
  const sumFiles = [...payload.map((p) => p.path), FROZEN.manifest, FROZEN.upgradeData, FROZEN.upgradeReadme].sort();
  w(FROZEN.sums, sumFiles.map((p) => `${sha256File(join(root, p.split('/').join(sep)))} *${p}`).join('\n') + '\n');
  return { root, added };
}

function summarize(checks) {
  return {
    total: checks.length,
    pass: checks.filter((c) => c.status === 'PASS').length,
    warn: checks.filter((c) => c.status === 'WARN').length,
    fail: checks.filter((c) => c.status === 'FAIL').length,
  };
}

function runSelfTest() {
  const synthetic = buildSyntheticPackage();
  try {
    const positive = verifyPackage(synthetic.root, {
      addedPayload: synthetic.added, expectPayloadCount: 4, synthetic: true,
      sourcePayloadCount: 2, enforceReplaceRange: false,
    });
    const positiveFails = positive.filter((c) => c.status === 'FAIL');
    // Negative control: corrupt one declared hash and require the validator to notice.
    const upgradePath = join(synthetic.root, FROZEN.upgradeData.split('/').join(sep));
    const good = readFileSync(upgradePath, 'utf8');
    const corrupted = good.replace(/"payloadSetHash": "[0-9a-f]{64}"/, '"payloadSetHash": "' + '0'.repeat(64) + '"');
    writeFileSync(upgradePath, corrupted);
    const negative = verifyPackage(synthetic.root, {
      addedPayload: synthetic.added, expectPayloadCount: 4, synthetic: true,
      sourcePayloadCount: 2, enforceReplaceRange: false,
    });
    writeFileSync(upgradePath, good);
    const negativeFails = negative.filter((c) => c.status === 'FAIL');
    const positiveOk = positiveFails.length === 0;
    const negativeOk = negativeFails.some((c) => c.id === 'C11.payloadSetHashes');
    const checks = [
      { id: 'SELF.positiveControl', status: positiveOk ? 'PASS' : 'FAIL', detail: positiveOk ? `synthetic package accepted (${positive.length} checks)` : `positive control failed: ${positiveFails.map((f) => f.id).join(', ')}` },
      { id: 'SELF.negativeControl', status: negativeOk ? 'PASS' : 'FAIL', detail: negativeOk ? `corrupted payloadSetHash detected (${negativeFails.map((f) => f.id).join(', ')})` : 'negative control was NOT detected' },
    ];
    return { checks, ok: positiveOk && negativeOk };
  } finally {
    try { rmSync(synthetic.root, { recursive: true, force: true }); } catch { /* ignore */ }
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
let exitCode = 1;
try {
  if (selfTest) {
    const st = runSelfTest();
    const summary = { suite: 'unified-package-closure', mode: 'self-test', summary: summarize(st.checks), checks: st.checks };
    if (asJson) console.log(JSON.stringify(summary, null, 2));
    else for (const c of st.checks) console.log(`[${c.status.padEnd(4)}] ${c.id}: ${c.detail}`);
    exitCode = st.ok ? 0 : 1;
  } else {
    verifyPackage(packageRoot, { expectPayloadCount });
    const summary = { suite: 'unified-package-closure', packageRoot, summary: summarize(results), checks: results };
    if (reportPath) {
      const target = resolve(reportPath);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, JSON.stringify(summary, null, 2) + '\n');
    }
    if (asJson) console.log(JSON.stringify(summary, null, 2));
    else {
      console.log('CNKI Research Portable - unified package internal closure');
      console.log(`  package root: ${packageRoot}`);
      for (const r of results) console.log(`  [${r.status.padEnd(4)}] ${r.id}: ${r.detail}`);
      console.log(`  ${summary.summary.pass} passed, ${summary.summary.warn} warning(s), ${summary.summary.fail} failure(s)`);
    }
    exitCode = summary.summary.fail === 0 ? 0 : 1;
  }
} catch (error) {
  const detail = error && error.message ? error.message : String(error);
  if (asJson) console.log(JSON.stringify({ suite: 'unified-package-closure', checks: [{ id: 'HARNESS', status: 'FAIL', detail }] }, null, 2));
  else console.error(`HARNESS: ${detail}`);
  exitCode = 2;
}
process.exit(exitCode);
