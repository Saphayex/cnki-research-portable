#!/usr/bin/env node
// Model-facing tool JSON Schema validation for CNKI Research Portable.
//
//   node tests/test_tool_schema.mjs --tools-json <dump.json> [--json] [--write-report <path>]
//                                   [--out-provider <path>] [--expect-tools 8]
//
// WHY VALIDATING THE MCP `inputSchema` IS VALIDATING THE MODEL SCHEMA
// ------------------------------------------------------------------
// For provider `deepseek-account` / `model: deepseek-flash`, DSH performs NO
// transformation between an MCP `tools/list` `inputSchema` and the provider
// payload. The chain is:
//
//   dsh-mcp-client/lib/index.js:137   inputSchema: tool.inputSchema
//   dsh-mcp-client/lib/index.js:185   parameters: inputSchema     (alias, not a copy)
//   dsh-tools/lib/index.js:3043-3048  schemaOf allowlist, detachParameters=false
//   dsh-system-prompt/lib/index.js:327  one structuredClone
//   dsh-llm-deepseek/lib/index.js:1712-1717
//                                     provider entry { name, description, input_schema }
//
// `assertSupportedJsonSchema` guards only each tool's OUTPUT schema, inside a
// swallowing try/catch (dsh-mcp-client/lib/index.js:162-171); it is not on the
// MCP parameter-schema path. The wire format is the Anthropic Messages API
// (`https://api.deepseek.com/anthropic/messages`), not OpenAI chat-completions.
//
// So this test reconstructs the exact provider payload from the live dump and
// validates it, and it also reports the risk shapes that the provider has been
// observed to reject with INVALID_REQUEST (400 / invalid_request_error).
//
// Exit codes: 0 pass, 1 validation failure, 2 bad input.

import { readFileSync, writeFileSync } from 'node:fs';

const argv = process.argv.slice(2);
function argValue(flag, fallback = null) {
  const index = argv.indexOf(flag);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : fallback;
}
const toolsJsonPath = argValue('--tools-json');
const asJson = argv.includes('--json');
const reportPath = argValue('--write-report');
const providerPath = argValue('--out-provider');
// An independently captured tools/list payload, used by the C4 pass-through proof.
const observedPath = argValue('--observed');
// Marks a dump of the unmodified upstream schemas (launcher --no-sanitize-schema).
const verbatimUpstream = argv.includes('--verbatim-upstream');
const expectTools = Number(argValue('--expect-tools', '8'));

if (!toolsJsonPath) {
  console.error('usage: node tests/test_tool_schema.mjs --tools-json <dump.json>');
  process.exit(2);
}

let dump;
try {
  dump = JSON.parse(readFileSync(toolsJsonPath, 'utf8'));
} catch (error) {
  console.error(`cannot read the tools dump ${toolsJsonPath}: ${error.message}`);
  process.exit(2);
}
const tools = Array.isArray(dump) ? dump : dump.tools;
if (!Array.isArray(tools)) {
  console.error('the dump does not hold a tools array');
  process.exit(2);
}

const results = [];
const record = (id, status, detail) => results.push({ id, status, detail });

const EXPECTED_TOOLS = [
  'easy-search', 'advanced-search', 'get-info-from-url', 'get-info-by-detail',
  'list-journal', 'search-issn', 'login', 'logout',
];

// Keywords the Anthropic Messages API is documented/observed to reject outright.
const FORBIDDEN_KEYWORDS = ['$schema', '$id', '$ref', '$defs', 'definitions', 'nullable', 'strict'];
// Keywords DSH's own schema guard rejects; harmless on the MCP path, reported as risk.
const RISK_KEYWORDS = ['anyOf', 'oneOf', 'allOf', 'format', 'pattern'];

function pointerWalk(node, pointer, visit) {
  visit(node, pointer);
  if (Array.isArray(node)) {
    node.forEach((item, index) => pointerWalk(item, `${pointer}/${index}`, visit));
  } else if (node && typeof node === 'object') {
    for (const [key, value] of Object.entries(node)) pointerWalk(value, `${pointer}/${key}`, visit);
  }
}

// ---------------------------------------------------------------------------
// 1. provider payload reconstruction
// ---------------------------------------------------------------------------
const provider = tools.map((tool) => ({
  name: `mcp__cnki__${tool.name}`,
  description: tool.description ?? '',
  input_schema: tool.inputSchema,
}));
if (providerPath) writeFileSync(providerPath, JSON.stringify({ tools: provider }, null, 2) + '\n');

// ---------------------------------------------------------------------------
// 2. catalog assertions
// ---------------------------------------------------------------------------
const names = tools.map((t) => t.name);
const catalogProblems = [];
if (names.length !== expectTools) catalogProblems.push(`expected ${expectTools} tools, got ${names.length}`);
for (const expected of EXPECTED_TOOLS) if (!names.includes(expected)) catalogProblems.push(`missing tool ${expected}`);
if (new Set(names).size !== names.length) catalogProblems.push('duplicate tool names');
for (const tool of tools) {
  if (!tool.description || tool.description.trim().length === 0) catalogProblems.push(`${tool.name}: empty description`);
  const publicName = `mcp__cnki__${tool.name}`;
  if (publicName.length > 64) catalogProblems.push(`${publicName} exceeds the 64-character public name limit`);
  if (!/^[A-Za-z0-9_-]+$/.test(publicName)) catalogProblems.push(`${publicName} has characters DSH would rewrite`);
}
record('C1.catalog', catalogProblems.length === 0 ? 'PASS' : 'FAIL',
  catalogProblems.length === 0
    ? `${names.length} tools, unique names, non-empty descriptions, all public names legal`
    : catalogProblems.join('; '));

// ---------------------------------------------------------------------------
// 3. per-schema structure
// ---------------------------------------------------------------------------
const structureProblems = [];
const schemaRisks = [];
// `--verbatim-upstream` marks a run whose schemas are the UNMODIFIED upstream
// Pydantic output (`--no-sanitize-schema`). Such a run exists to document the
// hazard the launcher's sanitizer removes, so the nullable-union defects it
// necessarily contains are recorded as WARN, not as a failure of this release.
// The shipped default path must still be completely clean.
const upstreamHazardShapes = [];
for (const tool of tools) {
  const schema = tool.inputSchema;
  const where = `mcp__cnki__${tool.name}`;
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    structureProblems.push(`${where}: inputSchema is not an object`);
    continue;
  }
  if (schema.type !== 'object') structureProblems.push(`${where}: type is ${JSON.stringify(schema.type)}, the provider requires "object"`);
  if (schema.properties !== undefined && (typeof schema.properties !== 'object' || schema.properties === null || Array.isArray(schema.properties))) {
    structureProblems.push(`${where}: properties is not an object`);
  }
  if (schema.required !== undefined) {
    if (!Array.isArray(schema.required) || schema.required.some((k) => typeof k !== 'string')) {
      structureProblems.push(`${where}: required is not a list of strings`);
    } else if (schema.properties && typeof schema.properties === 'object') {
      // A missing required key is always a real defect: it means the schema lost a
      // parameter, whatever mode produced it.
      for (const key of schema.required) {
        if (!(key in schema.properties)) structureProblems.push(`${where}: required key "${key}" is not declared in properties`);
      }
    }
  }
  pointerWalk(schema, where, (node, pointer) => {
    if (!node || typeof node !== 'object' || Array.isArray(node)) return;
    for (const keyword of FORBIDDEN_KEYWORDS) {
      if (keyword in node) structureProblems.push(`${pointer}: carries "${keyword}", which the provider rejects`);
    }
    for (const keyword of RISK_KEYWORDS) {
      if (keyword in node) schemaRisks.push(`${pointer}: "${keyword}" is a known INVALID_REQUEST risk under verbatim forwarding`);
    }
    if ('default' in node && node.default === null && node.type !== 'null' && !('anyOf' in node)) {
      structureProblems.push(`${pointer}: default is null on a non-nullable schema`);
    }
    if (node.type === 'null') {
      if (verbatimUpstream) upstreamHazardShapes.push(`${pointer}: bare "null" type (upstream Pydantic nullable union)`);
      else structureProblems.push(`${pointer}: a bare "null" type is not a valid provider schema`);
    }
  });
}
record('C2.structure', structureProblems.length === 0 ? 'PASS' : 'FAIL',
  structureProblems.length === 0
    ? 'every tool advertises type:"object" with consistent properties/required'
    : structureProblems.slice(0, 8).join('; '));
if (verbatimUpstream) {
  record('C2b.upstreamHazard', upstreamHazardShapes.length > 0 ? 'WARN' : 'PASS',
    upstreamHazardShapes.length > 0
      ? `${upstreamHazardShapes.length} nullable-union shape(s) in the verbatim upstream schemas; `
        + 'this is exactly what the default sanitizer removes and why it is on by default'
      : 'the verbatim upstream schemas happen to contain no bare "null" type');
}

// ---------------------------------------------------------------------------
// 4. risk shapes
// ---------------------------------------------------------------------------
if (schemaRisks.length === 0) {
  record('C3.riskShapes', 'PASS', 'no nullable union, format, pattern or allOf/oneOf/anyOf keyword in any schema');
} else {
  record('C3.riskShapes', 'WARN',
    `${schemaRisks.length} schema shape(s) are forwarded verbatim: ` + schemaRisks.slice(0, 6).join('; ')
    + ' | mitigation available: run the launcher with --sanitize-schema '
    + `(or set "sanitizeSchema": true in portable.runtime.json)`);
}

// ---------------------------------------------------------------------------
// 5. verbatim-pass-through proof
// ---------------------------------------------------------------------------
// `provider` is rebuilt from `tools` in this same file, so comparing the two can
// never fail. The claim that DSH forwards the MCP schema without transformation
// is only testable against a tools/list payload captured independently of this
// test (launcher `--tools-json`, or the stdio probe's report). When such a
// capture is supplied the comparison is real; otherwise it is NOT TESTED rather
// than a vacuous PASS.
const observedProblems = [];
let observedStatus = 'NOT TESTED';
let observedDetail = 'no independent tools/list capture supplied; pass --observed <path> (launcher --tools-json output) to test it';
if (observedPath) {
  try {
    const observed = JSON.parse(readFileSync(observedPath, 'utf8'));
    const observedTools = Array.isArray(observed) ? observed : observed.tools;
    if (!Array.isArray(observedTools)) {
      observedStatus = 'FAIL';
      observedDetail = `${observedPath} has no "tools" array`;
    } else {
      const byName = new Map(observedTools.map((t) => [t.name, t]));
      for (const tool of tools) {
        const seen = byName.get(tool.name);
        if (!seen) { observedProblems.push(`${tool.name}: absent from the capture`); continue; }
        if (JSON.stringify(seen.inputSchema) !== JSON.stringify(tool.inputSchema)) {
          observedProblems.push(`${tool.name}: captured inputSchema differs from the catalog`);
        }
      }
      if (observedTools.length !== tools.length) {
        observedProblems.push(`capture has ${observedTools.length} tools, catalog has ${tools.length}`);
      }
      observedStatus = observedProblems.length === 0 ? 'PASS' : 'FAIL';
      observedDetail = observedProblems.length === 0
        ? `${observedTools.length} captured inputSchema(s) are byte-identical to the MCP catalog (no transformation)`
        : observedProblems.slice(0, 6).join('; ');
    }
  } catch (exc) {
    observedStatus = 'FAIL';
    observedDetail = `could not read ${observedPath}: ${exc.message}`;
  }
}
record('C4.verbatim', observedStatus, observedDetail);

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------
const summary = {
  pass: results.filter((r) => r.status === 'PASS').length,
  warn: results.filter((r) => r.status === 'WARN').length,
  fail: results.filter((r) => r.status === 'FAIL').length,
  notTested: results.filter((r) => r.status === 'NOT TESTED').length,
};
const report = {
  suite: 'tool-schema',
  source: toolsJsonPath,
  provider: 'deepseek-account / deepseek-flash (Anthropic Messages API: https://api.deepseek.com/anthropic/messages)',
  toolCount: tools.length,
  summary,
  checks: results,
  risks: schemaRisks,
};
if (reportPath) writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
if (asJson) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log('CNKI Research Portable - model-facing tool schema test');
  console.log(`  dump       : ${toolsJsonPath}`);
  console.log(`  tools      : ${tools.length}`);
  console.log(`  provider   : ${report.provider}`);
  console.log('');
  for (const r of results) console.log(`  [${r.status.padEnd(10)}] ${r.id}: ${r.detail}`);
  console.log('');
  console.log(`  ${summary.pass} passed, ${summary.warn} warning(s), ${summary.fail} failure(s)`);
  console.log(summary.fail === 0 ? '  VERDICT: the model-facing tool schemas are VALID' : '  VERDICT: tool schema validation FAILED');
}
process.exit(summary.fail === 0 ? 0 : 1);
