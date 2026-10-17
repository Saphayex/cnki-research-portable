#!/usr/bin/env node
// Build RELEASE_MANIFEST.json: the identity of a released build plus a SHA-256 for
// every deliverable file and for the release archive itself.
//
//   node tools/build_release_manifest.mjs
//
// Why this is separate from manifest.json
// ---------------------------------------
// `manifest.json` is the *payload* manifest: it lists the files that ship inside the
// bundle and is verified at install time. `RELEASE_MANIFEST.json` is the *release*
// manifest: it describes the build as a whole -- the archive, its hash, and the reports
// that accompany it. It therefore also covers the reports, which are not payload.
//
// Deterministic: files are sorted and JSON is emitted with 2-space indentation.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(here, '..');

function sha256(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}

const readJson = (p) => JSON.parse(readFileSync(join(packageRoot, p), 'utf8'));
const payload = readJson('manifest.json');
const version = readFileSync(join(packageRoot, 'VERSION'), 'utf8').trim();

// --- the release archive ----------------------------------------------------
const distDir = join(packageRoot, 'dist');
const zipName = `CNKI-Research-Portable-${version}.zip`;
const zipPath = join(distDir, zipName);
let archive = null;
if (existsSync(zipPath)) {
  const bytes = statSync(zipPath).size;
  const hash = sha256(zipPath);
  let sidecarMatches = null;
  const sidecar = `${zipPath}.sha256`;
  if (existsSync(sidecar)) {
    const recorded = readFileSync(sidecar, 'utf8').trim().split(/\s+/)[0].toLowerCase();
    sidecarMatches = recorded === hash;
  }
  archive = {
    name: zipName,
    path: `dist/${zipName}`,
    bytes,
    sha256: hash,
    sidecar: existsSync(sidecar) ? `dist/${zipName}.sha256` : null,
    sidecarMatches,
  };
}

// --- deliverable reports ----------------------------------------------------
const REPORT_FILES = [
  'PORTABLE_RELEASE_REPORT.md',
  'PORTABLE_BUILD_REPORT.md',
  'PORTABLE_TEST_REPORT.md',
  'PORTABLE_SECURITY_REPORT.md',
  'PROJECT_STATE.md',
  'TEST_RESULTS.md',
  'CHANGELOG.md',
  'START_HERE.md',
  'INSTALL_PROMPT.md',
  'README.md',
  'manifest.json',
];
const reports = REPORT_FILES
  .filter((p) => existsSync(join(packageRoot, p)))
  .sort()
  .map((p) => ({ path: p, bytes: statSync(join(packageRoot, p)).size, sha256: sha256(join(packageRoot, p)) }));

// --- test evidence ----------------------------------------------------------
const evidenceRoot = join(packageRoot, 'docs', 'test-evidence');
let evidence = null;
if (existsSync(evidenceRoot)) {
  const runs = readdirSync(evidenceRoot, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .sort();
  if (runs.length > 0) {
    const latest = runs[runs.length - 1];
    const latestDir = join(evidenceRoot, latest);
    const files = readdirSync(latestDir, { withFileTypes: true });
    const summaryPath = join(latestDir, 'summary.json');
    let summary = null;
    if (existsSync(summaryPath)) {
      try { summary = JSON.parse(readFileSync(summaryPath, 'utf8')).summary ?? null; } catch { summary = null; }
    }
    evidence = {
      latestRun: latest,
      path: `docs/test-evidence/${latest}`,
      fileCount: files.length,
      summary,
    };
  }
}

const release = {
  schemaVersion: 1,
  distribution: payload.distribution,
  bundle: payload.bundle,
  release: {
    grade: 'RELEASE-CANDIDATE',
    gradeMeaning:
      'Main functionality and every test that can run safely on the build host pass. Real installation on an independent target machine, a real model request and a real institution search are still outstanding.',
    generatedBy: 'tools/build_release_manifest.mjs',
  },
  platform: payload.distribution.platform,
  sourceBaseline: {
    description: payload.baseline.description,
    files: payload.baseline.files,
  },
  dependencies: payload.dependencies,
  compatibility: payload.compatibility,
  payload: {
    manifest: 'manifest.json',
    fileCount: payload.files.length,
    totalBytes: payload.files.reduce((sum, f) => sum + f.bytes, 0),
  },
  archive,
  reports,
  testEvidence: evidence,
  verification: {
    verifyCommands: [
      'node tools/build_manifest.mjs --check',
      'powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_all.ps1',
      'powershell -NoProfile -ExecutionPolicy Bypass -File tools/portable.ps1 -Action check',
      'powershell -NoProfile -ExecutionPolicy Bypass -File tools/package_release.ps1',
      'powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify_release_zip.ps1',
    ],
    archiveCheckedAfterExtraction: true,
    productionEnvironmentChanged: false,
  },
};

writeFileSync(join(packageRoot, 'RELEASE_MANIFEST.json'), JSON.stringify(release, null, 2) + '\n');
console.log(
  `wrote RELEASE_MANIFEST.json: distribution ${version}, grade ${release.release.grade}, ` +
  `${release.payload.fileCount} payload file(s), archive ${archive ? archive.sha256.slice(0, 16) + '...' : '<not built yet>'}`,
);
