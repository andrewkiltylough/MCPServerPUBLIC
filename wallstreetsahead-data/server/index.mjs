// WallStreetsAhead.ai data MCP server.
//
// Mirrors the WallStreetsAhead.ai ETF mover reports from an Azure file share
// into a folder on this computer, through the WallStreetsAhead.ai API gateway.
//
// One file, no dependencies: it uses only what ships with Node.js 18 or later.
// It speaks the Model Context Protocol over stdio, so stdout carries the
// protocol and nothing else may be printed there. Diagnostics go to stderr.
//
// What it contacts: the API gateway (by default
// https://api.wallstreetsahead.ai/ClaudeCodePlugin), and nothing else. Each request
// carries the user's API key in the Ocp-Apim-Subscription-Key header. The
// gateway checks the key and reads the share with its own managed identity, so
// no storage credential is ever on this machine.
//
// What it writes: report files under the local data folder, and nothing else.
// It only adds or replaces files there; it never deletes anything.

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const SERVER_NAME = 'wallstreetsahead-data';
const SERVER_VERSION = '0.3.4';
const INSTRUCTIONS =
  'Fetches the ETF mover reports from Azure Files into the local data folder. ' +
  'Call check_new_data to see what is missing, then fetch_data to download it.';

/** Protocol versions this server can speak, newest first. */
const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

const DEFAULT_API_URL = 'https://api.wallstreetsahead.ai/ClaudeCodePlugin';
/** The share and folder the reports are published to. */
const DEFAULT_SHARE = 'premind-stock';
const DEFAULT_REMOTE_ROOT = 'SignalMoves/DayByDayRunner';

/** Azure Files REST version sent with every request (OAuth to Files needs 2022-11-02 or later). */
const AZURE_FILES_VERSION = '2024-11-04';
/** Recent date folders are re-checked, because later runs add files to them. */
const OVERLAP_DAYS = 3;
const CONCURRENCY = 8;
const ATTEMPTS = 3;
const REQUEST_TIMEOUT_MS = 120_000;
const MAX_LISTED = 500;
const MAX_FAILURES_SHOWN = 20;

// ---------------------------------------------------------------- settings

/**
 * Each setting comes from an environment variable if set (the plugin sets them
 * from its user configuration), otherwise from the local settings file that the
 * Windows installer writes, otherwise from the default. The API key has no
 * default, is only ever sent to the gateway, and is never logged or returned.
 */
/**
 * Points a stored pre-rename gateway address at the current one.
 *
 * The API moved from premind-apim.azure-api.net/daybyday to
 * api.wallstreetsahead.ai/ClaudeCodePlugin, and the old path now returns 404.
 * A settings file written before that holds the dead address, and the plugin
 * stops working with no clue as to why. Keys were unaffected by the move, so
 * rewriting the one dead value repairs those installs with nothing to edit.
 *
 * daybyday-register is deliberately not matched: that path is still live.
 */
function migrateRetiredUrl(url) {
  if (!url) return url;
  const lower = url.toLowerCase();
  const retired = lower.endsWith('azure-api.net/daybyday') || lower.includes('azure-api.net/daybyday/');
  return retired ? DEFAULT_API_URL : url;
}

function loadConfig() {
  const settingsFile = settingsFilePath();
  let file = {};
  try {
    file = parseProperties(fs.readFileSync(settingsFile, 'utf8'));
  } catch {
    // an absent or unreadable settings file is treated as empty; the tools then say what is missing
  }
  const local = firstNonBlank(env('LOCAL_ROOT'), file.localRoot, defaultLocalRoot());
  return {
    apiUrl: migrateRetiredUrl(trimSlashes(firstNonBlank(env('API_URL'), file.apiUrl, DEFAULT_API_URL))),
    apiKey: firstNonBlank(env('API_KEY'), file.apiKey),
    shareName: firstNonBlank(env('SHARE_NAME'), file.shareName, DEFAULT_SHARE),
    remoteRoot: normaliseRemote(firstNonBlank(env('REMOTE_ROOT'), file.remoteRoot, DEFAULT_REMOTE_ROOT)),
    localRoot: path.resolve(expandHome(local)),
    settingsFile,
  };
}

function env(name) {
  return process.env['WALLSTREETSAHEAD_' + name];
}

function settingsFilePath() {
  const override = firstNonBlank(env('SETTINGS_FILE'));
  if (override) {
    return path.resolve(expandHome(override));
  }
  return path.join(os.homedir(), '.wallstreetsahead', 'wallstreetsahead.properties');
}

function defaultLocalRoot() {
  return process.platform === 'win32' ? 'C:\\WallStreetsAhead' : path.join(os.homedir(), 'WallStreetsAhead');
}

/** Returns a message naming what is missing, or null when gateway access is configured. */
function missingApiSettings(cfg) {
  if (!cfg.apiKey) {
    return (
      'No API key found. Set it in Claude: run /plugin, choose wallstreetsahead-data and configure it. ' +
      'Or add apiKey=... to ' + cfg.settingsFile + '. Then restart Claude.'
    );
  }
  if (!cfg.apiUrl.startsWith('https://')) {
    return 'The API URL must start with https:// so the API key is not sent in clear text.';
  }
  return null;
}

/**
 * A plugin option the user has not set can arrive as an unexpanded
 * ${user_config.x} reference or as an empty string, so both count as blank.
 */
function firstNonBlank(...values) {
  for (const v of values) {
    if (typeof v === 'string' && v.trim() !== '' && !v.trim().startsWith('${')) {
      return v.trim();
    }
  }
  return null;
}

function expandHome(p) {
  return p === '~' || p.startsWith('~/') || p.startsWith('~\\') ? path.join(os.homedir(), p.slice(1)) : p;
}

function trimSlashes(value) {
  return value == null ? null : value.replace(/\/+$/, '');
}

function normaliseRemote(p) {
  return p == null ? '' : p.trim().replace(/\\/g, '/').replace(/^\/+/, '').replace(/\/+$/, '');
}

/** Reads the Java properties format the installer writes, including its backslash escapes. */
function parseProperties(text) {
  const props = {};
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i].replace(/^\s+/, '');
    if (line === '' || line[0] === '#' || line[0] === '!') {
      continue;
    }
    // an odd number of trailing backslashes continues the value on the next line
    while (/(?:^|[^\\])(?:\\\\)*\\$/.test(line) && i + 1 < lines.length) {
      line = line.slice(0, -1) + lines[++i].replace(/^\s+/, '');
    }
    let sep = line.length;
    for (let j = 0; j < line.length; j++) {
      if (line[j] === '\\') {
        j++;
      } else if (line[j] === '=' || line[j] === ':' || /\s/.test(line[j])) {
        sep = j;
        break;
      }
    }
    const value = line.slice(sep).replace(/^\s*[=:]?\s*/, '');
    props[unescapeProperty(line.slice(0, sep))] = unescapeProperty(value);
  }
  return props;
}

function unescapeProperty(s) {
  return s.replace(/\\(u[0-9a-fA-F]{4}|[\s\S])/g, (_, c) => {
    if (c.length === 5) {
      return String.fromCharCode(parseInt(c.slice(1), 16));
    }
    return { t: '\t', n: '\n', r: '\r', f: '\f' }[c] ?? c;
  });
}

// ---------------------------------------------------------------- dates

/** Date folders are named MM-DD-YYYY, which does not sort as text, so they are always parsed. */
function parseFolderDate(name) {
  const m = /^(\d{2})-(\d{2})-(\d{4})$/.exec(name);
  if (!m) {
    return null;
  }
  const iso = `${m[3]}-${m[1]}-${m[2]}`;
  return isRealDate(iso) ? iso : null;
}

function isRealDate(iso) {
  const d = new Date(iso + 'T00:00:00Z');
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === iso;
}

function minusDays(iso, days) {
  const d = new Date(iso + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

/** Dates are kept as YYYY-MM-DD strings, which compare correctly as text. */
function inRange(date, since, until) {
  return (since == null || date >= since) && (until == null || date <= until);
}

// ---------------------------------------------------------------- gateway

class GatewayError extends Error {
  constructor(status, body) {
    super(gatewayMessage(status, body));
    this.status = status;
  }
}

/** The gateway answers 401/403/429 for key problems; say what they mean rather than echo the raw response. */
function gatewayMessage(status, body) {
  switch (status) {
    case 401:
      return 'The API key was rejected (401). Check the key set for the plugin is current, then restart Claude.';
    case 403:
      return 'The API key is not allowed to read this data (403). Email support@wallstreetsahead.ai to check the key\'s subscription.';
    case 429:
      return 'The API key\'s usage limit was reached (429). Wait and try again, or email support@wallstreetsahead.ai to raise it.';
    default: {
      const code = xmlText(body, 'Code');
      const message = (xmlText(body, 'Message') ?? '').split('\n')[0].trim();
      return `The gateway answered HTTP ${status}` + (code ? ` ${code}` : '') + (message ? `: ${message}` : '');
    }
  }
}

function remoteUrl(cfg, relativePath, query) {
  const full = [cfg.remoteRoot, relativePath].filter(Boolean).join('/');
  const segments = [cfg.shareName, ...full.split('/').filter(Boolean)].map(encodeURIComponent);
  return cfg.apiUrl + '/' + segments.join('/') + (query ? '?' + query : '');
}

/** GET through the gateway, retrying network errors and 5xx answers. */
async function gatewayGet(cfg, url) {
  for (let attempt = 1; ; attempt++) {
    let res;
    try {
      res = await fetch(url, {
        headers: { 'Ocp-Apim-Subscription-Key': cfg.apiKey, 'x-ms-version': AZURE_FILES_VERSION },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch (e) {
      if (attempt < ATTEMPTS) {
        await sleep(500 * attempt);
        continue;
      }
      throw new Error('Could not reach the gateway: ' + (e.cause?.message ?? e.message));
    }
    if (res.ok) {
      return res;
    }
    const body = await res.text().catch(() => '');
    if (res.status >= 500 && attempt < ATTEMPTS) {
      await sleep(500 * attempt);
      continue;
    }
    throw new GatewayError(res.status, body);
  }
}

/** Lists one remote folder, relative to the configured remote root. */
async function listRemoteDir(cfg, relativePath) {
  const entries = [];
  let marker = '';
  do {
    const query = 'restype=directory&comp=list' + (marker ? '&marker=' + encodeURIComponent(marker) : '');
    const xml = await (await gatewayGet(cfg, remoteUrl(cfg, relativePath, query))).text();
    for (const m of xml.matchAll(/<(File|Directory)>([\s\S]*?)<\/\1>/g)) {
      const name = xmlText(m[2], 'Name');
      if (name != null) {
        const directory = m[1] === 'Directory';
        entries.push({ name, directory, size: directory ? 0 : Number(xmlText(m[2], 'Content-Length') ?? 0) });
      }
    }
    marker = xmlText(xml, 'NextMarker') ?? '';
  } while (marker);
  return entries;
}

/** Text of the first <tag> element in a fragment of the Azure Files XML, or null. */
function xmlText(xml, tag) {
  const m = new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`).exec(xml ?? '');
  if (!m) {
    return null;
  }
  return m[1].replace(/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);/g, (_, e) => {
    if (e[0] === '#') {
      return String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
    }
    return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }[e];
  });
}

// ---------------------------------------------------------------- sync

/** Remote names are not trusted: anything that could act as a path is skipped. */
function isSafeName(name) {
  return (
    typeof name === 'string' && name.trim() !== '' && name !== '.' && name !== '..' &&
    !name.includes('/') && !name.includes('\\') && !name.includes(':')
  );
}

function matchesEtf(folder, etf) {
  if (!etf) {
    return true;
  }
  const want = etf.trim().toUpperCase();
  const have = folder.toUpperCase();
  // ETE_XLE is a misspelt folder that sits alongside the ETF_ folders
  return have === want || have === 'ETF_' + want || have === 'ETE_' + want;
}

/** The resolved path must stay inside the local data folder. */
function localPath(cfg, relativePath) {
  const resolved = path.resolve(cfg.localRoot, ...relativePath.split('/'));
  const root = cfg.localRoot.endsWith(path.sep) ? cfg.localRoot : cfg.localRoot + path.sep;
  if (!resolved.startsWith(root)) {
    throw new Error('Remote path escapes the local folder: ' + relativePath);
  }
  return resolved;
}

/** Newest date folder under a local top-level folder, or null when there is none. */
function newestLocalDate(folder) {
  let newest = null;
  try {
    for (const d of fs.readdirSync(folder, { withFileTypes: true })) {
      const date = d.isDirectory() ? parseFolderDate(d.name) : null;
      if (date && (newest == null || date > newest)) {
        newest = date;
      }
    }
  } catch {
    return null;
  }
  return newest;
}

/** An explicit 'since' wins; a full check has no lower bound; otherwise start just before the newest local folder. */
function sinceFor(cfg, topFolder, filter) {
  if (filter.since) {
    return filter.since;
  }
  if (filter.full) {
    return null;
  }
  const newest = newestLocalDate(path.join(cfg.localRoot, topFolder));
  return newest == null ? null : minusDays(newest, OVERLAP_DAYS);
}

/** Walks the share and works out which files are missing locally or differ in size. */
async function plan(cfg, filter) {
  const topFolders = [];
  let level = [];
  for (const e of await listRemoteDir(cfg, '')) {
    if (e.directory && isSafeName(e.name) && matchesEtf(e.name, filter.etf)) {
      topFolders.push(e.name);
      level.push({ path: e.name, since: sinceFor(cfg, e.name, filter), folderDate: null });
    }
  }

  const remoteFiles = [];
  while (level.length > 0) {
    const listings = await mapLimit(level, CONCURRENCY, async (dir) => {
      const dirs = [];
      const files = [];
      for (const item of await listRemoteDir(cfg, dir.path)) {
        if (!isSafeName(item.name)) {
          continue;
        }
        const p = dir.path + '/' + item.name;
        if (item.directory) {
          const date = parseFolderDate(item.name);
          if (date != null && !inRange(date, dir.since, filter.until)) {
            continue;
          }
          dirs.push({ path: p, since: dir.since, folderDate: date ?? dir.folderDate });
        } else {
          files.push({ relativePath: p, size: item.size, folderDate: dir.folderDate });
        }
      }
      return { dirs, files };
    });
    level = listings.flatMap((l) => l.dirs);
    for (const l of listings) {
      remoteFiles.push(...l.files);
    }
  }

  const toDownload = [];
  let newestRemoteDate = null;
  let alreadyCurrent = 0;
  for (const f of remoteFiles) {
    if (f.folderDate && (newestRemoteDate == null || f.folderDate > newestRemoteDate)) {
      newestRemoteDate = f.folderDate;
    }
    const stat = statOrNull(localPath(cfg, f.relativePath));
    if (stat?.isFile() && stat.size === f.size) {
      alreadyCurrent++;
    } else {
      toDownload.push(f);
    }
  }
  toDownload.sort((a, b) => (a.relativePath < b.relativePath ? -1 : a.relativePath > b.relativePath ? 1 : 0));
  return { toDownload, remoteFilesChecked: remoteFiles.length, alreadyCurrent, newestRemoteDate, topFolders };
}

/** Downloads every file in the plan. Each file goes to a temporary name and is then moved into place. */
async function download(cfg, planned) {
  let downloaded = 0;
  let bytes = 0;
  const failures = [];
  await mapLimit(planned.toDownload, CONCURRENCY, async (f) => {
    try {
      // await first: `bytes += await x` would read bytes before the wait and lose concurrent additions
      const size = await downloadOne(cfg, f);
      bytes += size;
      downloaded++;
    } catch (e) {
      failures.push(f.relativePath + ': ' + e.message);
    }
  });
  failures.sort();
  return { downloaded, bytes, failures };
}

async function downloadOne(cfg, f) {
  const target = localPath(cfg, f.relativePath);
  await fsp.mkdir(path.dirname(target), { recursive: true });
  const temp = target + '.part';
  try {
    const res = await gatewayGet(cfg, remoteUrl(cfg, f.relativePath));
    await pipeline(Readable.fromWeb(res.body), fs.createWriteStream(temp));
    const size = (await fsp.stat(temp)).size;
    if (size !== f.size) {
      throw new Error(`incomplete download: got ${size} of ${f.size} bytes`);
    }
    await fsp.rename(temp, target);
    return size;
  } catch (e) {
    await fsp.rm(temp, { force: true });
    throw e;
  }
}

// ---------------------------------------------------------------- tools

const FILTER_PROPERTIES = {
  etf: { type: 'string', description: 'Limit to one ETF, for example SPY or XLK. Omit for all ETFs.' },
  since: {
    type: 'string',
    description: 'Earliest date folder to check, as YYYY-MM-DD. Omit to start a few days before the newest local date folder.',
  },
  until: { type: 'string', description: 'Latest date folder to check, as YYYY-MM-DD. Omit for no upper limit.' },
  full: { type: 'boolean', description: 'Check every date folder back to the start. Slow; use to repair gaps.' },
};

const TOOLS = [
  {
    name: 'local_status',
    title: 'Local data status',
    description:
      'Show the local data folder: how many ETF folders it has and the newest date folder in each. Does not contact Azure.',
    properties: {},
    readOnly: true,
    openWorld: false,
    run: localStatus,
  },
  {
    name: 'check_new_data',
    title: 'Check for new data',
    description:
      'Compare Azure with the local folder and report which report files are missing or changed, without downloading anything.',
    properties: FILTER_PROPERTIES,
    readOnly: true,
    openWorld: true,
    run: checkNewData,
  },
  {
    name: 'fetch_data',
    title: 'Fetch new data',
    description:
      'Download report files that are missing or changed locally. Never deletes local files. ' +
      'By default only checks from a few days before the newest local date folder.',
    properties: FILTER_PROPERTIES,
    readOnly: false,
    openWorld: true,
    run: fetchData,
  },
  {
    name: 'list_remote',
    title: 'List remote folder',
    description: 'List the folders and files at one path in the Azure file share, relative to the configured root.',
    properties: {
      path: { type: 'string', description: 'Folder path, for example ETF_SPY or ETF_SPY/10-09-2026. Empty for the root.' },
    },
    readOnly: true,
    openWorld: true,
    run: listRemote,
  },
];

async function localStatus(cfg) {
  const out = [];
  out.push('Local folder: ' + cfg.localRoot);
  out.push('Azure share: ' + cfg.shareName + (cfg.remoteRoot ? ' / ' + cfg.remoteRoot : ''));
  out.push('API gateway: ' + cfg.apiUrl);
  out.push('API key: ' + (cfg.apiKey ? 'set' : 'not set'));
  if (!statOrNull(cfg.localRoot)?.isDirectory()) {
    out.push('The local folder does not exist yet.');
    return out.join('\n');
  }
  const lines = [];
  let newest = null;
  const folders = fs
    .readdirSync(cfg.localRoot, { withFileTypes: true })
    .filter((d) => d.isDirectory() && /^ET[FE]_.+/i.test(d.name))
    .map((d) => d.name)
    .sort();
  for (const name of folders) {
    const date = newestLocalDate(path.join(cfg.localRoot, name));
    lines.push(`  ${name}: ${date ?? 'no date folders'}`);
    if (date && (newest == null || date > newest)) {
      newest = date;
    }
  }
  out.push('ETF folders: ' + lines.length);
  out.push('Newest local date folder: ' + (newest ?? 'none'));
  return out.concat(lines).join('\n');
}

async function checkNewData(cfg, args) {
  const filter = parseFilter(args);
  requireApi(cfg);
  return describe(await plan(cfg, filter), 'to download').join('\n');
}

async function fetchData(cfg, args) {
  const filter = parseFilter(args);
  requireApi(cfg);
  const planned = await plan(cfg, filter);
  const out = describe(planned, 'selected');
  if (planned.toDownload.length > 0) {
    const result = await download(cfg, planned);
    out.push(`Downloaded: ${result.downloaded} files, ${megabytes(result.bytes)}`);
    out.push('Failed: ' + result.failures.length);
    for (const f of result.failures.slice(0, MAX_FAILURES_SHOWN)) {
      out.push('  ' + f);
    }
  }
  return out.join('\n');
}

async function listRemote(cfg, args) {
  const p = stringArg(args, 'path') ?? '';
  requireApi(cfg);
  const entries = await listRemoteDir(cfg, normaliseRemote(p));
  entries.sort((a, b) => (a.directory !== b.directory ? (a.directory ? -1 : 1) : a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const out = [`${entries.length} entries at '${p}'`];
  for (const e of entries.slice(0, MAX_LISTED)) {
    out.push(e.directory ? `  [dir]  ${e.name}` : `  [file] ${e.name}  (${e.size} bytes)`);
  }
  if (entries.length > MAX_LISTED) {
    out.push(`  ... ${entries.length - MAX_LISTED} more not shown`);
  }
  return out.join('\n');
}

function describe(planned, label) {
  const total = planned.toDownload.reduce((sum, f) => sum + f.size, 0);
  const out = [
    'Top-level folders checked: ' + planned.topFolders.length,
    'Remote files checked: ' + planned.remoteFilesChecked,
    'Already current locally: ' + planned.alreadyCurrent,
    'Newest remote date folder in range: ' + (planned.newestRemoteDate ?? 'none'),
    `Files ${label}: ${planned.toDownload.length} (${megabytes(total)})`,
  ];
  const byDate = new Map();
  for (const f of planned.toDownload) {
    if (f.folderDate) {
      byDate.set(f.folderDate, (byDate.get(f.folderDate) ?? 0) + 1);
    }
  }
  for (const date of [...byDate.keys()].sort()) {
    out.push(`  ${date}: ${byDate.get(date)} files`);
  }
  return out;
}

function requireApi(cfg) {
  const missing = missingApiSettings(cfg);
  if (missing) {
    throw new Error(missing);
  }
}

function parseFilter(args) {
  const full = args.full === true || args.full === 'true';
  return { etf: stringArg(args, 'etf'), since: dateArg(args, 'since'), until: dateArg(args, 'until'), full };
}

function stringArg(args, key) {
  const v = args[key];
  return v == null || String(v).trim() === '' ? null : String(v).trim();
}

function dateArg(args, key) {
  const v = stringArg(args, key);
  if (v == null) {
    return null;
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v) || !isRealDate(v)) {
    throw new Error(`'${key}' must be a date as YYYY-MM-DD, got: ${v}`);
  }
  return v;
}

function megabytes(bytes) {
  return (bytes / 1_048_576).toFixed(1) + ' MB';
}

// ---------------------------------------------------------------- helpers

function statOrNull(p) {
  try {
    return fs.statSync(p);
  } catch {
    return null;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Runs fn over items with at most `limit` at a time, keeping the results in order. Stops early on a failure. */
async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  let failed = false;
  const worker = async () => {
    while (!failed && next < items.length) {
      const i = next++;
      try {
        results[i] = await fn(items[i]);
      } catch (e) {
        failed = true;
        throw e;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

// ---------------------------------------------------------------- MCP over stdio

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function reply(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

function toolList() {
  return TOOLS.map((t) => ({
    name: t.name,
    title: t.title,
    description: t.description,
    inputSchema: { type: 'object', properties: t.properties },
    annotations: { title: t.title, readOnlyHint: t.readOnly, destructiveHint: false, idempotentHint: true, openWorldHint: t.openWorld },
  }));
}

/** Turns any failure into an error result the model can read, instead of breaking the connection. */
async function callTool(params) {
  const tool = TOOLS.find((t) => t.name === params?.name);
  if (!tool) {
    return { content: [{ type: 'text', text: 'Error: unknown tool ' + params?.name }], isError: true };
  }
  try {
    const args = params.arguments && typeof params.arguments === 'object' ? params.arguments : {};
    const text = await tool.run(loadConfig(), args);
    return { content: [{ type: 'text', text }] };
  } catch (e) {
    const message = (e?.message || String(e)).split('\n')[0];
    return { content: [{ type: 'text', text: 'Error: ' + message }], isError: true };
  }
}

async function handle(msg) {
  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;
  switch (method) {
    case 'initialize': {
      const asked = params?.protocolVersion;
      reply(id, {
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        instructions: INSTRUCTIONS,
      });
      return;
    }
    case 'ping':
      reply(id, {});
      return;
    case 'tools/list':
      reply(id, { tools: toolList() });
      return;
    case 'tools/call':
      reply(id, await callTool(params));
      return;
    default:
      // notifications (initialized, cancelled, ...) need no answer
      if (isRequest) {
        replyError(id, -32601, 'Method not found: ' + method);
      }
  }
}

function main() {
  const major = Number(process.versions.node.split('.')[0]);
  if (major < 18) {
    process.stderr.write(`${SERVER_NAME} needs Node.js 18 or later; this is ${process.version}.\n`);
    process.exit(1);
  }
  // requests are handled one at a time, so two fetches never write the same files at once
  let queue = Promise.resolve();
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  input.on('line', (line) => {
    if (line.trim() === '') {
      return;
    }
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      replyError(null, -32700, 'Parse error');
      return;
    }
    queue = queue
      .then(() => handle(msg))
      .catch((e) => {
        process.stderr.write(`${SERVER_NAME}: ${e?.stack ?? e}\n`);
        if (msg?.id !== undefined && msg?.id !== null) {
          replyError(msg.id, -32603, 'Internal error');
        }
      });
  });
  input.on('close', () => {
    queue.finally(() => process.exit(0));
  });
}

main();
