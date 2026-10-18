#!/usr/bin/env node
// Static package validation for the CNKI Research Portable distribution.
//
//   node tests/test_static_package.mjs [--json] [--write-report <path>]
//
// Covers acceptance group A (package static test):
//   A1  every file in manifest.json exists with the recorded size and SHA-256
//   A2  manifest.json agrees with bundle/cnki-research/package.json
//   A3  no development-machine absolute path anywhere in the payload
//   A4  no personal credential or authentication state in the payload
//   A5  source, dependency pin and licence files are present
//   A6  the bundle installation entry point is well formed
//   A7  cordis.patch.yml parses in the DSH entry-list dialect and its !!js
//       expressions resolve correctly for a simulated installation layout,
//       including a root path containing spaces and non-ASCII characters
//
// Exit codes: 0 all checks passed, 1 at least one check failed.

import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(here, '..');
const argv = process.argv.slice(2);
const asJson = argv.includes('--json');
const reportIndex = argv.indexOf('--write-report');
const reportPath = reportIndex >= 0 ? argv[reportIndex + 1] : null;

const results = [];
function record(id, status, detail) {
  results.push({ id, status, detail });
}
function pass(id, detail) { record(id, 'PASS', detail); }
function fail(id, detail) { record(id, 'FAIL', detail); }
function warn(id, detail) { record(id, 'WARN', detail); }
function notTested(id, detail) { record(id, 'NOT TESTED', detail); }

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));

// ---------------------------------------------------------------------------
// A1 - integrity
// ---------------------------------------------------------------------------
const manifest = readJson(join(packageRoot, 'manifest.json'));
let integrityFailures = [];
for (const entry of manifest.files) {
  const full = join(packageRoot, entry.path);
  if (!existsSync(full)) { integrityFailures.push(`missing: ${entry.path}`); continue; }
  const bytes = statSync(full).size;
  if (bytes !== entry.bytes) integrityFailures.push(`size: ${entry.path} (${bytes} != ${entry.bytes})`);
  const hash = createHash('sha256').update(readFileSync(full)).digest('hex');
  if (hash !== entry.sha256) integrityFailures.push(`sha256: ${entry.path}`);
}
if (integrityFailures.length === 0) pass('A1.integrity', `${manifest.files.length} payload file(s) match size and SHA-256`);
else fail('A1.integrity', integrityFailures.slice(0, 5).join('; '));

// ---------------------------------------------------------------------------
// A2 - manifest vs bundle identity
// ---------------------------------------------------------------------------
const bundlePkg = readJson(join(packageRoot, 'bundle/cnki-research/package.json'));
const versionFile = readFileSync(join(packageRoot, 'VERSION'), 'utf8').trim();
const identityProblems = [];
if (bundlePkg.name !== manifest.bundle.name) identityProblems.push(`bundle name ${bundlePkg.name} != ${manifest.bundle.name}`);
if (bundlePkg.version !== manifest.bundle.version) identityProblems.push(`bundle version ${bundlePkg.version} != ${manifest.bundle.version}`);
if (versionFile !== manifest.distribution.version) identityProblems.push(`VERSION ${versionFile} != distribution.version ${manifest.distribution.version}`);
if (bundlePkg.dsh?.bundle?.patch !== './cordis.patch.yml') identityProblems.push('package.json dsh.bundle.patch is not ./cordis.patch.yml');
const patchFile = join(packageRoot, dirname(manifest.bundle.patch), 'cordis.patch.yml');
if (!existsSync(patchFile)) identityProblems.push(`declared patch file is missing: ${manifest.bundle.patch}`);
if (identityProblems.length === 0) pass('A2.identity', `${bundlePkg.name}@${bundlePkg.version}, distribution ${manifest.distribution.version}, patch declaration matches`);
else fail('A2.identity', identityProblems.join('; '));

// ---------------------------------------------------------------------------
// A3 - no development-machine absolute paths
// ---------------------------------------------------------------------------
// Detection targets. A published repository must never embed a real developer
// account name or a real institution name, so both are supplied as configurable
// markers that default to deliberately fictional placeholders. A maintainer who
// also wants to guard their own environment exports the real values locally
// instead of committing them:
//   CNKI_ACCOUNT_MARKER=<name>   CNKI_INSTITUTION_MARKERS=<name1,name2>
// The guard below still runs the marker patterns against every shipped file, so
// the detection capability is unchanged; only the literals are not baked in.
const ACCOUNT_MARKER = process.env.CNKI_ACCOUNT_MARKER || 'ExampleUser';
const INSTITUTION_MARKERS = (process.env.CNKI_INSTITUTION_MARKERS || 'ExampleUniversity,示例大学')
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean);
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Precise patterns: bare drive roots such as 'C:\' are legitimate search roots,
// so only concrete development locations and the account marker are rejected.
const DEV_PATTERNS = [
  { re: /F:[\\/]DSH/gi, label: 'F:\\DSH development tree' },
  { re: /F:[\\/]cnki-mcp/gi, label: 'F:\\cnki-mcp upstream tree' },
  { re: /D:[\\/]DeepSeekHarness/gi, label: 'D:\\DeepSeekHarness installation path' },
  { re: /[A-Za-z]:[\\/](?:Users|用户)[\\/][^\\/\s"']+/g, label: 'absolute user profile path' },
  { re: new RegExp(escapeRegExp(ACCOUNT_MARKER), 'g'), label: 'developer account name' },
  { re: /cnki-mcp Mode/g, label: 'development workspace folder name' },
  { re: /\.dsh-cnki-profile/g, label: 'development browser profile path' },
];
// These files necessarily quote development-machine locations, and each is a
// deliberate, disclosed part of the release rather than user-facing material:
//   docs/provenance/**             provenance record: where the frozen baseline and
//                                  the vendored upstream came from, with hashes
//   tests/test_static_package.mjs  this detector must name the patterns it detects
// The development-state record and the release reports are not published in this
// repository; the entries below are retained so the exemption list stays correct
// if a maintainer restores them locally. Every exempted file is additionally
// content-scanned by A3.exemptIsClean below, so the exemption cannot be used to
// hide credential material or an account name.
const PATH_SCAN_EXEMPT = [
  /^docs\/provenance\//,
  /^tests\/test_static_package\.mjs$/,
  /^PROJECT_STATE\.md$/,
  /^PORTABLE_(?:BUILD|TEST|SECURITY|RELEASE)_REPORT\.md$/,
];
const pathHits = [];
for (const entry of manifest.files) {
  if (PATH_SCAN_EXEMPT.some((re) => re.test(entry.path))) continue;
  const full = join(packageRoot, entry.path);
  const bytes = readFileSync(full);
  if (bytes.includes(0)) continue; // binary (the vendored ESM bundle is text, but be safe)
  const text = bytes.toString('utf8');
  for (const { re, label } of DEV_PATTERNS) {
    re.lastIndex = 0;
    const match = re.exec(text);
    if (match) {
      const line = text.slice(0, match.index).split('\n').length;
      pathHits.push(`${entry.path}:${line} (${label})`);
    }
  }
}
if (pathHits.length === 0) pass('A3.noDevPaths', `no development-machine path in ${manifest.files.length} payload file(s)`);
else fail('A3.noDevPaths', pathHits.slice(0, 8).join('; '));

// The bundle patch must also contain no absolute path at all.
const patchText = readFileSync(patchFile, 'utf8');
const absoluteInPatch = patchText.match(/[A-Za-z]:[\\/]/g);
if (!absoluteInPatch) pass('A3.patchNoAbsolutePath', 'cordis.patch.yml contains no drive-letter path');
else fail('A3.patchNoAbsolutePath', `cordis.patch.yml contains ${absoluteInPatch.length} drive-letter path(s)`);

// Institution neutrality: the portable bundle must not prescribe an institution.
const bundleCorpus = [
  patchText,
  readFileSync(join(packageRoot, 'bundle/cnki-research/README.md'), 'utf8'),
  readFileSync(join(packageRoot, 'bundle/cnki-research/skills/cnki-literature-search/SKILL.md'), 'utf8'),
  readFileSync(join(packageRoot, 'bundle/cnki-research/launcher/cnki_research_launcher.py'), 'utf8'),
].join('\n');
const institutionHits = [];
for (const name of INSTITUTION_MARKERS) {
  if (bundleCorpus.includes(name)) institutionHits.push(name);
}
if (institutionHits.length === 0) pass('A3.institutionNeutral', 'the bundle prescribes no institution');
else fail('A3.institutionNeutral', `bundle references ${institutionHits.join(', ')}`);

// The path-scan exemption above must not become a place to hide PII. Every
// exempted file is re-checked for the developer's account name and for live
// credential material; an institution appearing in a provenance/documentation
// record is expected (it records where the baseline came from) and is therefore
// reported as WARN rather than FAIL.
const exemptProblems = [];
let exemptInstitutionMentions = 0;
const ACCOUNT_NAME_RE = new RegExp(escapeRegExp(ACCOUNT_MARKER));
// This detector file necessarily contains the marker it searches for, so the
// account-name probe cannot be applied to it; it IS still scanned for private-key,
// cookie-jar and JWT material below. The marker is a fictional placeholder
// (or a value supplied by the maintainer's own environment), never a committed
// real account name, so this skip conceals nothing.
const DETECTOR_PATH = 'tests/test_static_package.mjs';
for (const entry of manifest.files) {
  if (!PATH_SCAN_EXEMPT.some((re) => re.test(entry.path))) continue;
  const text = readFileSync(join(packageRoot, entry.path), 'utf8');
  if (entry.path !== DETECTOR_PATH && ACCOUNT_NAME_RE.test(text)) exemptProblems.push(`${entry.path}: developer account name`);
  if (/BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY/.test(text)) exemptProblems.push(`${entry.path}: private key material`);
  if (/"domain"\s*:\s*"\.?cnki\.net"/i.test(text)) exemptProblems.push(`${entry.path}: CNKI cookie jar`);
  if (/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\./.test(text)) exemptProblems.push(`${entry.path}: JWT-like token`);
  for (const name of INSTITUTION_MARKERS) {
    if (entry.path !== DETECTOR_PATH && text.includes(name)) exemptInstitutionMentions += 1;
  }
}
if (exemptProblems.length > 0) {
  fail('A3.exemptIsClean', exemptProblems.slice(0, 6).join('; '));
} else if (exemptInstitutionMentions > 0) {
  warn('A3.exemptIsClean',
    `exempted provenance/state files hold no credential material and no account name, but name an institution `
    + `(${exemptInstitutionMentions} mention(s)); they are developer documentation, not user-facing material`);
} else {
  pass('A3.exemptIsClean', 'path-scan-exempt files carry no credential material, account name or institution');
}

// ---------------------------------------------------------------------------
// A4 - no credentials or authentication state
// ---------------------------------------------------------------------------
const CREDENTIAL_NAME = /^(cookies|storage_state)\.json$|\.(pem|key|pfx|p12|jks)$|^(\.credentials\.yaml|credentials\.json)$/i;
const CREDENTIAL_CONTENT = [
  { re: /"domain"\s*:\s*"\.?cnki\.net"/i, label: 'CNKI cookie jar' },
  { re: /BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY/, label: 'private key' },
  { re: /"cookies"\s*:\s*\[\s*\{/i, label: 'serialized cookie list' },
  { re: /sk-[A-Za-z0-9]{20,}/, label: 'API key literal' },
];
const credentialHits = [];
for (const entry of manifest.files) {
  if (CREDENTIAL_NAME.test(entry.path.split('/').pop())) credentialHits.push(`filename: ${entry.path}`);
  const full = join(packageRoot, entry.path);
  const bytes = readFileSync(full);
  if (bytes.includes(0)) continue;
  const text = bytes.toString('utf8');
  for (const { re, label } of CREDENTIAL_CONTENT) {
    if (re.test(text)) credentialHits.push(`${entry.path} (${label})`);
  }
}
if (credentialHits.length === 0) pass('A4.noCredentials', 'no credential, cookie or key material in the payload');
else fail('A4.noCredentials', credentialHits.slice(0, 8).join('; '));

// Runtime artefacts that must never ship.
const FORBIDDEN_DIRS = ['_scratch', 'dist/_staging', '.venv', 'node_modules', '_portable', '__pycache__'];
const forbiddenHits = manifest.files.filter((entry) =>
  FORBIDDEN_DIRS.some((dir) => entry.path === dir || entry.path.startsWith(dir + '/'))
  || entry.path.endsWith('.log') || entry.path.endsWith('.pyc'));
if (forbiddenHits.length === 0) pass('A4.noRuntimeArtefacts', 'no .venv, node_modules, cache, __pycache__, .pyc or test log in the payload');
else fail('A4.noRuntimeArtefacts', forbiddenHits.slice(0, 8).map((e) => e.path).join('; '));

// ---------------------------------------------------------------------------
// A5 - source, licence, dependency pins
// ---------------------------------------------------------------------------
const requiredFiles = [
  'LICENSE',
  'THIRD-PARTY-NOTICES.md',
  'upstream/cnki-mcp/LICENSE',
  'upstream/cnki-mcp/pyproject.toml',
  'upstream/cnki-mcp/uv.lock',
  'upstream/cnki-mcp/src/cnki_mcp/__init__.py',
  'tools/vendor/js-yaml/LICENSE',
  'docs/provenance/v1.0-bundle.sha256.json',
  'docs/provenance/upstream-src.sha256.json',
];
const missing = requiredFiles.filter((rel) => !existsSync(join(packageRoot, rel)));
if (missing.length === 0) pass('A5.sources', `licences, upstream source and lockfile present (${requiredFiles.length} required files)`);
else fail('A5.sources', `missing: ${missing.join(', ')}`);

const gpl = readFileSync(join(packageRoot, 'LICENSE'), 'utf8');
if (/GNU GENERAL PUBLIC LICENSE/.test(gpl) && /Version 3/.test(gpl)) pass('A5.gpl', 'LICENSE holds the GNU GPL v3 text');
else fail('A5.gpl', 'LICENSE is not the GPL v3 text');

const upstreamLicense = readFileSync(join(packageRoot, 'upstream/cnki-mcp/LICENSE'), 'utf8');
if (/GNU GENERAL PUBLIC LICENSE/.test(upstreamLicense)) pass('A5.upstreamLicense', 'the vendored upstream carries its GPL licence');
else fail('A5.upstreamLicense', 'the vendored upstream licence is missing or unexpected');

const notices = readFileSync(join(packageRoot, 'THIRD-PARTY-NOTICES.md'), 'utf8');
const noticeProblems = [];
if (!/cnki-mcp/.test(notices)) noticeProblems.push('cnki-mcp not credited');
if (!/GPL/.test(notices)) noticeProblems.push('no GPL statement');
if (!/js-yaml/.test(notices)) noticeProblems.push('js-yaml not credited');
if (noticeProblems.length === 0) pass('A5.thirdPartyNotices', 'third-party notices name the upstream project, its licence and the vendored test dependency');
else fail('A5.thirdPartyNotices', noticeProblems.join('; '));

const lock = readFileSync(join(packageRoot, 'upstream/cnki-mcp/uv.lock'), 'utf8');
const lockProblems = [];
if (!/name = "cnki-mcp"/.test(lock)) lockProblems.push('cnki-mcp is not in uv.lock');
if (!/name = "playwright"/.test(lock)) lockProblems.push('playwright is not in uv.lock');
if (!/name = "mcp"/.test(lock)) lockProblems.push('mcp is not in uv.lock');
if (lockProblems.length === 0) pass('A5.dependencyPins', 'uv.lock pins cnki-mcp, mcp and playwright');
else fail('A5.dependencyPins', lockProblems.join('; '));

// ---------------------------------------------------------------------------
// A6 - installation entry point
// ---------------------------------------------------------------------------
const entryProblems = [];
if (manifest.install.entryPoint !== 'tools/portable.ps1') entryProblems.push('manifest install.entryPoint is not tools/portable.ps1');
if (!existsSync(join(packageRoot, manifest.install.entryPoint))) entryProblems.push('install entry point file is missing');
if (!existsSync(join(packageRoot, 'tools/lib/PortableCommon.ps1'))) entryProblems.push('tools/lib/PortableCommon.ps1 is missing');
if (!existsSync(join(packageRoot, 'tools/probe_mcp_stdio.py'))) entryProblems.push('tools/probe_mcp_stdio.py is missing');
if (!existsSync(join(packageRoot, 'INSTALL_PROMPT.md'))) entryProblems.push('INSTALL_PROMPT.md is missing');
if (!existsSync(join(packageRoot, 'START_HERE.md'))) entryProblems.push('START_HERE.md is missing');
const installer = readFileSync(join(packageRoot, 'tools/portable.ps1'), 'utf8');
for (const action of ['check', 'install', 'uninstall', 'rollback', 'diagnose']) {
  if (!installer.includes(`'${action}'`)) entryProblems.push(`portable.ps1 does not declare the '${action}' action`);
}
if (/Remove-Item[^\n]*-Recurse/.test(installer)) {
  // Recursive removal is legitimate for the venv directory, but it must be guarded
  // by a reparse-point check, which Remove-LinkSafely enforces.
  if (!installer.includes('Remove-LinkSafely')) entryProblems.push('recursive removal without a junction guard');
}
if (entryProblems.length === 0) pass('A6.entryPoint', 'installer actions, layout files and prompts are present and consistent');
else fail('A6.entryPoint', entryProblems.join('; '));

// ---------------------------------------------------------------------------
// A7 - the DSH entry-list dialect: parse + evaluate against a simulated layout
// ---------------------------------------------------------------------------
const yamlModule = await import(pathToFileURL(join(packageRoot, 'tools/vendor/js-yaml/js-yaml.mjs')).href);
const yaml = yamlModule.default ?? yamlModule;

const JsExpr = new yaml.Type('tag:yaml.org,2002:js', {
  kind: 'scalar',
  resolve: (data) => typeof data === 'string',
  construct: (data) => ({ __jsExpr: data }),
});
const entryListSchema = yaml.JSON_SCHEMA.extend(JsExpr);

// Mirror of @deepseek-ai/cordis-plugin-loader `interpolate` + `evaluate`.
const evaluate = new Function('ctx', 'expr', 'with (ctx) { return eval(expr) }');
function interpolate(ctx, value) {
  if (value instanceof Object && '__jsExpr' in value) return evaluate(ctx, value.__jsExpr);
  if (!value || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map((item) => interpolate(ctx, item));
  return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, interpolate(ctx, v)]));
}

let patch;
try {
  patch = yaml.load(patchText, { schema: entryListSchema });
  if (!Array.isArray(patch) || patch.length === 0 || !patch[0].insert) throw new Error('the patch is not a non-empty insert list');
  pass('A7.dialect', 'cordis.patch.yml parses with the DSH entry-list YAML dialect');
} catch (error) {
  fail('A7.dialect', String(error && error.message ? error.message : error));
}

if (patch) {
  const presetRow = patch[0].insert.find((row) => row.id === 'preset-cnki-research');
  const structural = [];
  if (!presetRow) structural.push('no preset-cnki-research row');
  else {
    if (presetRow.name !== '@deepseek-ai/dsh-agent-preset') structural.push('the preset row does not mount @deepseek-ai/dsh-agent-preset');
    if (presetRow.config?.id !== manifest.bundle.presetId) structural.push(`preset id ${presetRow.config?.id} != ${manifest.bundle.presetId}`);
    if (presetRow.config?.order !== manifest.bundle.order) structural.push(`preset order ${presetRow.config?.order} != ${manifest.bundle.order}`);
    const rows = presetRow.config?.plugins ?? [];
    const mcpRow = rows.find((row) => row.id === 'cnki-mcp');
    if (!mcpRow) structural.push('no cnki-mcp row');
    else {
      if (mcpRow.name !== '@deepseek-ai/dsh-mcp-client') structural.push('the MCP row does not mount @deepseek-ai/dsh-mcp-client');
      if (mcpRow.config?.serverName !== 'cnki') structural.push(`serverName ${mcpRow.config?.serverName} != cnki`);
      if (mcpRow.config?.transport !== 'stdio') structural.push(`transport ${mcpRow.config?.transport} != stdio`);
      if (mcpRow.config?.reconnect?.enabled !== true) structural.push('the reconnect policy is not enabled');
    }
    if (!rows.some((row) => row.id === 'skill-filesystem')) structural.push('no skill-filesystem row');
    if (!rows.some((row) => row.id === 'tool-skill')) structural.push('no tool-skill row');
    // v1.1's three runtime tools must not appear.
    for (const forbidden of ['cnki-runtime', 'cnki-runtime-tools', 'tool-cnki-runtime']) {
      if (rows.some((row) => String(row.id).includes(forbidden))) structural.push(`v1.1 runtime row present: ${forbidden}`);
    }
  }
  if (structural.length === 0) pass('A7.structure', 'preset id/order, MCP row, skill rows and the absence of v1.1 runtime rows all check out');
  else fail('A7.structure', structural.join('; '));

  // CNKI-021-001 regression: persona text may only reference prompt variables that
  // DSH registers. DSH 0.2.1-rc.2 removed the implicit `cwd` variable (0.2.0-rc.2
  // registered provider/model/cwd); a dangling {{cwd}} throws during prompt assembly
  // before the first model request, so the whole session cannot start.
  const personaRow = presetRow?.config?.plugins?.find((row) => row.id === 'persona');
  const personaText = JSON.stringify(personaRow?.config ?? {});
  const registeredPromptVariables = new Set(['provider', 'model']);
  const referenced = [...personaText.matchAll(/\{\{([a-z][a-z0-9_]*)\}\}/g)].map((match) => match[1]);
  const unregistered = referenced.filter((name) => !registeredPromptVariables.has(name));
  if (unregistered.length === 0) {
    const used = [...new Set(referenced)].sort().join(', ') || '(none)';
    pass('A7.promptVariables', `persona references only DSH-registered prompt variables: ${used}`);
  } else {
    fail('A7.promptVariables', `persona references prompt variable(s) not registered by DSH 0.2.1-rc.2: ${[...new Set(unregistered)].join(', ')}`);
  }
}

// Evaluation against a simulated installation whose root contains a space and CJK.
if (patch) {
  const sandbox = mkdtempSync(join(tmpdir(), 'cnki-portable-'));
  const simRoot = join(sandbox, '安装 目录');
  const simBundle = join(simRoot, 'bundle', 'cnki-research');
  const simVenv = join(simRoot, '.venv', 'Scripts');
  const { mkdirSync } = await import('node:fs');
  mkdirSync(join(simBundle, 'node_modules'), { recursive: true });
  mkdirSync(join(simVenv), { recursive: true });
  writeFileSync(join(simBundle, 'package.json'), JSON.stringify({ name: '@local/dsh-cnki-research', version: '1.0.0' }));
  const fakePython = join(simVenv, 'python.exe');
  writeFileSync(fakePython, '');
  const nodeModules = join(simRoot, 'node_modules');
  mkdirSync(join(nodeModules, '@local'), { recursive: true });
  writeFileSync(join(nodeModules, '@local', 'dsh-cnki-research'), '');  // placeholder, real check uses baseUrl

  // baseUrl points at the profile directory, where the bundle name is linked.
  const profileDir = join(sandbox, 'profiles', 'desktop');
  const linkParent = join(profileDir, 'node_modules', '@local');
  mkdirSync(linkParent, { recursive: true });
  // Simulate the pnpm link by copying the bundle manifest into the resolution path.
  writeFileSync(join(linkParent, 'dsh-cnki-research'), '');
  rmSync(join(linkParent, 'dsh-cnki-research'));
  const { symlinkSync } = await import('node:fs');
  try {
    symlinkSync(simBundle, join(linkParent, 'dsh-cnki-research'), 'junction');
  } catch (error) {
    warn('A7.simulatedLayout', `could not create the simulated junction: ${error.message}`);
  }

  const baseUrl = pathToFileURL(profileDir + '\\').href;
  const ctx = { baseUrl, process, URL };
  try {
    const resolved = interpolate(ctx, patch[0].insert.find((row) => row.id === 'preset-cnki-research').config.plugins);
    const skillRow = resolved.find((row) => row.id === 'skill-filesystem');
    const mcpRow = resolved.find((row) => row.id === 'cnki-mcp');
    const evalProblems = [];
    const expectedSkills = join(simBundle, 'skills');
    const expectedLauncher = join(simBundle, 'launcher', 'cnki_research_launcher.py');
    if (skillRow.config.customSkillDirs[0] !== expectedSkills) {
      evalProblems.push(`skills dir resolved to ${skillRow.config.customSkillDirs[0]} instead of ${expectedSkills}`);
    }
    if (mcpRow.config.args[0] !== expectedLauncher) {
      evalProblems.push(`launcher resolved to ${mcpRow.config.args[0]} instead of ${expectedLauncher}`);
    }
    if (mcpRow.config.command !== fakePython) {
      evalProblems.push(`interpreter resolved to ${mcpRow.config.command} instead of ${fakePython}`);
    }
    if (mcpRow.config.cwd !== simBundle) {
      evalProblems.push(`cwd resolved to ${mcpRow.config.cwd} instead of ${simBundle}`);
    }
    if (evalProblems.length === 0) pass('A7.pathResolution', `all !!js values resolve correctly under "${simRoot}" (spaces + CJK)`);
    else fail('A7.pathResolution', evalProblems.join('; '));
  } catch (error) {
    fail('A7.pathResolution', `evaluation threw: ${error && error.message ? error.message : error}`);
  }

  // The expressions must never throw, even when nothing resolves.
  try {
    const ctx2 = { baseUrl: 'file:///nonexistent/dir/', process, URL };
    const resolved2 = interpolate(ctx2, patch[0].insert[0].config.plugins);
    const mcpRow2 = resolved2.find((row) => row.id === 'cnki-mcp');
    const skillRow2 = resolved2.find((row) => row.id === 'skill-filesystem');
    const problems2 = [];
    if (typeof mcpRow2.config.command !== 'string' || mcpRow2.config.command.length === 0) problems2.push('command is not a non-empty string');
    if (!Array.isArray(mcpRow2.config.args) || typeof mcpRow2.config.args[0] !== 'string') problems2.push('args[0] is not a string');
    if (typeof skillRow2.config.customSkillDirs[0] !== 'string') problems2.push('customSkillDirs[0] is not a string');
    if (problems2.length === 0) pass('A7.totalFallback', 'with nothing resolvable every expression still yields a usable string instead of throwing');
    else fail('A7.totalFallback', problems2.join('; '));
  } catch (error) {
    fail('A7.totalFallback', `an expression threw on the empty layout: ${error && error.message ? error.message : error}`);
  }
  rmSync(sandbox, { recursive: true, force: true });
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------
const summary = {
  pass: results.filter((r) => r.status === 'PASS').length,
  warn: results.filter((r) => r.status === 'WARN').length,
  fail: results.filter((r) => r.status === 'FAIL').length,
  notTested: results.filter((r) => r.status === 'NOT TESTED').length,
};
const report = {
  suite: 'static-package',
  packageRoot,
  distribution: manifest.distribution.version,
  bundle: `${manifest.bundle.name}@${manifest.bundle.version}`,
  summary,
  checks: results,
};

if (reportPath) writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
if (asJson) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log('CNKI Research Portable - static package test');
  console.log(`  package root : ${packageRoot}`);
  console.log(`  distribution : ${report.distribution}  (${report.bundle})`);
  console.log('');
  for (const r of results) console.log(`  [${r.status.padEnd(10)}] ${r.id}: ${r.detail}`);
  console.log('');
  console.log(`  ${summary.pass} passed, ${summary.warn} warning(s), ${summary.fail} failure(s), ${summary.notTested} not tested`);
  console.log(summary.fail === 0 ? '  VERDICT: static package validation PASSED' : '  VERDICT: static package validation FAILED');
}
process.exit(summary.fail === 0 ? 0 : 1);
