#!/usr/bin/env node

import http from 'node:http';
import { access, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SLUG_PATTERN = /^[A-Za-z0-9._-]+$/;
const BRANCH_PATTERN = /^[A-Za-z0-9._/-]+$/;
const CONNECTOR_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 ._+&()/-]{0,79}$/;
const BUILT_IN_CONNECTORS = new Map([
  ['linear', 'Linear'],
  ['slack', 'Slack'],
  ['gmail', 'Gmail'],
  ['google drive', 'Google Drive'],
  ['github', 'GitHub'],
]);
const MAX_BODY_BYTES = 256 * 1024;

function fail(message) {
  process.stderr.write(`blitzos wizard: ${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if ((flag !== '--scan' && flag !== '--out') || !value || values[flag]) {
      fail('usage: node wizard-server.mjs --scan <scan.json> --out <selection.json>');
    }
    values[flag] = value;
  }
  if (argv.length !== 4 || !values['--scan'] || !values['--out']) {
    fail('usage: node wizard-server.mjs --scan <scan.json> --out <selection.json>');
  }
  return { scanPath: resolve(values['--scan']), outPath: resolve(values['--out']) };
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function exactKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.includes(key));
}

function send(response, status, body, contentType) {
  response.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
  });
  response.end(body);
}

function sendJson(response, status, value) {
  send(response, status, `${JSON.stringify(value)}\n`, 'application/json; charset=utf-8');
}

function sendText(response, status, body, contentType = 'text/plain; charset=utf-8') {
  send(response, status, body, contentType);
}

async function readJsonBody(request) {
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new Error('request body is too large');
    chunks.push(chunk);
  }
  if (chunks.length === 0) throw new Error('request body is empty');
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new Error('request body is not valid JSON');
  }
}

async function isDirectory(path) {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}

function validBranch(value) {
  return typeof value === 'string'
    && value.length <= 255
    && BRANCH_PATTERN.test(value)
    && !value.startsWith('-')
    && !value.includes('..')
    && !value.includes('//')
    && !value.endsWith('/');
}

function knownBranches(repo) {
  return new Set([
    repo.branch_current,
    repo.branch_default,
    ...(Array.isArray(repo.branches_recent) ? repo.branches_recent : []),
  ].filter((branch) => typeof branch === 'string' && branch.length > 0));
}

function connectorName(value) {
  if (typeof value !== 'string') throw new Error('connector names must be strings');
  const trimmed = value.trim();
  if (!CONNECTOR_PATTERN.test(trimmed)) {
    throw new Error('invalid connector name; use 1–80 ordinary characters');
  }
  return BUILT_IN_CONNECTORS.get(trimmed.toLowerCase()) || trimmed;
}

async function validateSelection(selection, scan) {
  if (!isRecord(selection) || !exactKeys(selection, ['slug', 'repos', 'connectors'])) {
    throw new Error('selection must contain only slug, repos, and connectors');
  }
  if (typeof selection.slug !== 'string' || !SLUG_PATTERN.test(selection.slug)) {
    throw new Error('slug must match [A-Za-z0-9._-]+');
  }
  if (!Array.isArray(selection.repos) || selection.repos.length === 0) {
    throw new Error('select at least one repository');
  }
  if (selection.repos.length > 100) throw new Error('select at most 100 repositories');
  if (!Array.isArray(selection.connectors) || selection.connectors.length > 25) {
    throw new Error('connectors must be an array with at most 25 names');
  }

  const scanRepos = new Map(scan.repos.map((repo) => [repo.id, repo]));
  const selectedIds = new Set();
  const repos = [];
  for (const choice of selection.repos) {
    if (!isRecord(choice) || !exactKeys(choice, ['id', 'branch'])
      || typeof choice.id !== 'string' || !validBranch(choice.branch)) {
      throw new Error('each repository selection requires a scanned id and valid branch');
    }
    if (selectedIds.has(choice.id)) throw new Error('repository selections must be unique');
    selectedIds.add(choice.id);

    const scanned = scanRepos.get(choice.id);
    if (!scanned) throw new Error(`repository was not found in the scan: ${choice.id}`);
    if (!choice.id.startsWith('github.com/') || typeof scanned.origin !== 'string'
      || scanned.origin.length === 0) {
      throw new Error(`repository is not connectable through GitHub: ${scanned.name}`);
    }
    if (scanned.local_path !== null && !(await isDirectory(scanned.local_path))) {
      throw new Error(`local repository path is no longer available: ${scanned.name}`);
    }

    repos.push({
      name: scanned.name_with_owner || scanned.name,
      origin: scanned.origin,
      local_path: scanned.local_path || '',
      branch: choice.branch,
      branch_unverified: !knownBranches(scanned).has(choice.branch),
    });
  }

  const connectors = [];
  const connectorKeys = new Set();
  for (const rawConnector of selection.connectors) {
    const connector = connectorName(rawConnector);
    const key = connector.toLowerCase();
    if (connectorKeys.has(key)) continue;
    connectorKeys.add(key);
    connectors.push(connector);
  }

  return { slug: selection.slug, repos, connectors };
}

async function writeAtomically(path, value) {
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    await rename(temporary, path);
  } catch (error) {
    await unlink(temporary).catch(() => {});
    throw error;
  }
}

function validScanRepo(repo) {
  return isRecord(repo)
    && typeof repo.id === 'string'
    && typeof repo.source === 'string'
    && typeof repo.name === 'string'
    && (repo.name_with_owner === null || typeof repo.name_with_owner === 'string')
    && (repo.local_path === null || typeof repo.local_path === 'string')
    && typeof repo.origin === 'string'
    && Array.isArray(repo.branches_recent)
    && Array.isArray(repo.env_var_names);
}

const { scanPath, outPath } = parseArgs(process.argv.slice(2));
const wizardPath = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'wizard.html');
let scanText;
let wizardHtml;
let scan;

try {
  await access(outPath).then(
    () => { throw new Error(`output already exists: ${outPath}`); },
    () => {},
  );
  [scanText, wizardHtml] = await Promise.all([
    readFile(scanPath, 'utf8'),
    readFile(wizardPath, 'utf8'),
  ]);
  scan = JSON.parse(scanText);
  if (!isRecord(scan) || scan.schema_version !== 1 || !Array.isArray(scan.repos)
    || !scan.repos.every(validScanRepo)) {
    throw new Error('scan file does not match the expected schema');
  }
  if (new Set(scan.repos.map((repo) => repo.id)).size !== scan.repos.length) {
    throw new Error('scan file contains duplicate repository ids');
  }
} catch (error) {
  fail(error.message);
}

let submitted = false;
const server = http.createServer(async (request, response) => {
  const url = new URL(request.url || '/', 'http://127.0.0.1');

  if (request.method === 'GET' && url.pathname === '/') {
    sendText(response, 200, wizardHtml, 'text/html; charset=utf-8');
    return;
  }
  if (request.method === 'GET' && url.pathname === '/scan.json') {
    sendText(response, 200, scanText, 'application/json; charset=utf-8');
    return;
  }
  if (request.method === 'GET' && url.pathname === '/health') {
    sendText(response, 200, 'ok\n');
    return;
  }
  if (request.method === 'POST' && url.pathname === '/submit') {
    if (submitted) {
      sendJson(response, 400, { ok: false, error: 'selection has already been submitted' });
      return;
    }
    try {
      const selection = await readJsonBody(request);
      const validated = await validateSelection(selection, scan);
      await writeAtomically(outPath, validated);
      submitted = true;
      sendJson(response, 200, { ok: true });
      setTimeout(() => {
        server.close();
        server.closeIdleConnections?.();
      }, 500);
    } catch (error) {
      sendJson(response, 400, { ok: false, error: error.message });
    }
    return;
  }

  sendJson(response, 404, { ok: false, error: 'not found' });
});

server.on('error', (error) => fail(error.message));
server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  process.stdout.write(`WIZARD_URL=http://127.0.0.1:${address.port}/\n`);
});
