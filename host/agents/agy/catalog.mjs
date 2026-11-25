// Antigravity CLI (`agy`) session history scanning for Pi Go.
//
// Reads agy's native conversation catalog from:
//   - `~/.gemini/antigravity-cli/conversation_summaries.db` (SQLite index)
//   - `~/.gemini/antigravity-cli/conversations/<uuid>.db` (per-conversation DB)
//   - `~/.gemini/antigravity-cli/annotations/<uuid>.pbtxt` (archive status)
//   - `~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl`
//     (optional JSONL transcript / fallback metadata file)
//
// Every returned row carries `agent: 'agy'`.
import { existsSync, realpathSync } from 'node:fs';
import { readdir, readFile, realpath, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { sessionTitlePreview } from '../../bridge/message-view.mjs';

const idPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const maxSessions = 250;
const cacheMs = 5000;

export function agyGeminiDir() {
  if (process.env.PIGO_AGY_GEMINI_DIR) return resolve(process.env.PIGO_AGY_GEMINI_DIR);
  return resolve(join(homedir(), '.gemini'));
}

export function agyAppDataName() {
  return process.env.PIGO_AGY_APP_DATA_DIR || 'antigravity-cli';
}

export function agyHomes() {
  if (process.env.AGY_HOME) {
    return [{ dir: resolve(process.env.AGY_HOME), appDataDir: agyAppDataName() }];
  }
  if (process.env.PI_CODING_AGENT_DIR) {
    return [{ dir: join(resolve(process.env.PI_CODING_AGENT_DIR), 'agy'), appDataDir: agyAppDataName() }];
  }
  const gemini = agyGeminiDir();
  if (process.env.PIGO_AGY_APP_DATA_DIR) {
    const custom = process.env.PIGO_AGY_APP_DATA_DIR;
    return [{ dir: join(gemini, custom), appDataDir: custom }];
  }
  return [
    { dir: join(gemini, 'antigravity'), appDataDir: 'antigravity' },
    { dir: join(gemini, 'antigravity-cli'), appDataDir: 'antigravity-cli' },
  ];
}

export function agyHome() {
  return agyHomes()[0].dir;
}

function annotationIsArchived(annotation) {
  // AGY may put the entire protobuf text message on one line.
  const tokens = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|#[^\r\n]*|[{}<>]|\barchived\s*:\s*(true|false)\b/g;
  let depth = 0;
  for (const [token, archived] of annotation.matchAll(tokens)) {
    if (token === '{' || token === '<') depth++;
    else if (token === '}' || token === '>') depth--;
    else if (depth === 0 && archived !== undefined) return archived === 'true';
  }
  return false;
}

export async function archivedAgySessionIds(ids) {
  const candidates = new Set(ids.filter((id) => idPattern.test(id)));
  const archived = new Set();
  if (!candidates.size) return archived;
  await Promise.all(agyHomes().map(async ({ dir }) => {
    const annotations = join(dir, 'annotations');
    const entries = await readdir(annotations, { withFileTypes: true }).catch(() => []);
    await Promise.all(entries.map(async (entry) => {
      if (!entry.isFile() || !entry.name.endsWith('.pbtxt')) return;
      const id = entry.name.slice(0, -'.pbtxt'.length);
      if (!candidates.has(id)) return;
      const annotation = await readFile(join(annotations, entry.name), 'utf8').catch(() => '');
      if (annotationIsArchived(annotation)) archived.add(id);
    }));
  }));
  return archived;
}

export function agyConversationsRoot() {
  for (const { dir } of agyHomes()) {
    const conv = join(dir, 'conversations');
    if (existsSync(conv)) return conv;
  }
  return join(agyHome(), 'conversations');
}

export function agyAuthed() {
  if (process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY) return true;
  const gemini = agyGeminiDir();
  if (existsSync(join(gemini, 'oauth_creds.json')) || existsSync(join(gemini, 'google_accounts.json'))) {
    return true;
  }
  for (const { dir } of agyHomes()) {
    if (existsSync(join(dir, 'auth.json'))
      || existsSync(join(dir, 'jetski_state.pbtxt'))
      || existsSync(join(dir, 'antigravity_state.pbtxt'))) {
      return true;
    }
  }
  return false;
}

function cleanAgyPreview(raw) {
  if (typeof raw !== 'string') return '';
  const match = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/i.exec(raw);
  const body = (match ? match[1] : raw).trim();
  return body;
}

function parseWorkspaceUris(raw) {
  if (typeof raw !== 'string' || !raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const out = [];
    for (const item of parsed) {
      if (typeof item !== 'string' || !item) continue;
      if (item.startsWith('file://')) {
        try {
          out.push(decodeURIComponent(new URL(item).pathname));
        } catch {}
      } else if (item.startsWith('/')) {
        out.push(item);
      }
    }
    return out;
  } catch {
    return [];
  }
}

function toIsoDate(raw, fallbackMs) {
  if (typeof raw === 'string' && raw.trim()) {
    const normalized = raw.includes('T') ? raw.trim() : raw.trim().replace(' ', 'T');
    const time = Date.parse(normalized);
    if (!Number.isNaN(time)) return new Date(time).toISOString();
  }
  return new Date(fallbackMs || Date.now()).toISOString();
}

function querySummariesDb(dbPath, appName) {
  if (!existsSync(dbPath)) return [];
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const stmt = db.prepare(`
      SELECT conversation_id, title, preview, step_count, last_modified_time,
             workspace_uris, parent_conversation_id, nesting_depth, app_data_dir
      FROM conversation_summaries
      ORDER BY last_modified_time DESC
      LIMIT 500
    `);
    const rows = stmt.all();
    return rows.filter((row) => {
      if (!row || typeof row.conversation_id !== 'string' || !idPattern.test(row.conversation_id)) return false;
      if (row.parent_conversation_id || Number(row.nesting_depth) > 0) return false;
      if (row.app_data_dir && appName && row.app_data_dir !== appName) return false;
      return true;
    });
  } catch {
    return [];
  } finally {
    try { db?.close(); } catch {}
  }
}

function querySummaryById(dbPath, id, appName) {
  if (!existsSync(dbPath)) return undefined;
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const stmt = db.prepare(`
      SELECT conversation_id, title, preview, step_count, last_modified_time,
             workspace_uris, parent_conversation_id, nesting_depth, app_data_dir
      FROM conversation_summaries
      WHERE conversation_id = ?
      LIMIT 1
    `);
    const row = stmt.get(id);
    if (!row || typeof row.conversation_id !== 'string' || !idPattern.test(row.conversation_id)) return undefined;
    if (row.parent_conversation_id || Number(row.nesting_depth) > 0) return undefined;
    if (row.app_data_dir && appName && row.app_data_dir !== appName) return undefined;
    return row;
  } catch {
    return undefined;
  } finally {
    try { db?.close(); } catch {}
  }
}

async function inspectSidecarSession(home, id, filePath, info, workspace, locations) {
  let meta;
  const metaFile = join(home, 'conversations', `${id}.json`);
  const rawMeta = await readFile(metaFile, 'utf8').catch(() => '');
  if (rawMeta) {
    try { meta = JSON.parse(rawMeta); } catch {}
  }
  if (!meta) {
    const rawFile = await readFile(filePath, 'utf8').catch(() => '');
    const firstLine = rawFile.split('\n')[0] ?? '';
    if (firstLine.startsWith('{')) {
      try { meta = JSON.parse(firstLine); } catch {}
    }
  }
  const cwd = typeof meta?.cwd === 'string' ? meta.cwd : undefined;
  if (!cwd) return undefined;
  if (!locations.has(cwd)) locations.set(cwd, realpath(cwd).catch(() => cwd));
  const resolvedCwd = await locations.get(cwd);
  if (workspace && resolvedCwd !== workspace) return undefined;
  const title = (typeof meta?.title === 'string' && meta.title.trim())
    || (typeof meta?.name === 'string' && meta.name.trim())
    || (typeof meta?.preview === 'string' && sessionTitlePreview(cleanAgyPreview(meta.preview)))
    || '未命名会话';
  const statInfo = info ?? await stat(filePath).catch(() => undefined);
  return {
    agent: 'agy',
    id,
    cwd: resolvedCwd,
    path: filePath,
    appDataDir: meta?.appDataDir,
    name: title,
    modified: toIsoDate(meta?.updatedAt || meta?.modified, statInfo?.mtimeMs),
    messageCount: Math.max(1, Number(meta?.messageCount ?? meta?.stepCount ?? 1) || 1),
    active: false,
  };
}

const cache = new Map();
const pending = new Map();
let generation = 0;

export function invalidateAgyCatalog() {
  cache.clear();
  pending.clear();
  generation += 1;
}

export async function agyComputerSessions(revision, workspace, refresh = false) {
  const homes = [];
  for (const item of agyHomes()) {
    const resolved = await realpath(item.dir).catch(() => undefined);
    if (resolved) homes.push({ dir: resolved, appDataDir: item.appDataDir });
  }
  if (!homes.length) return [];
  const homesKey = homes.map((h) => h.dir).join(':');
  const key = workspace ?? '';
  const global = cache.get('');
  const hit = cache.get(key);
  if (!refresh && workspace && global?.homesKey === homesKey && global.revision === revision && Date.now() - global.time < cacheMs &&
    !(hit?.homesKey === homesKey && hit.revision === revision && hit.time >= global.time)) {
    return global.rows.filter((row) => row.cwd === workspace);
  }
  const inflight = pending.get(key);
  if (!refresh && hit?.homesKey === homesKey && hit.revision === revision && Date.now() - hit.time < cacheMs) {
    return hit.rows;
  }
  if (inflight?.homesKey === homesKey && inflight.revision === revision && (!refresh || inflight.refresh)) return inflight.promise;

  const scanGeneration = generation;
  const promise = (async () => {
    const locations = new Map();
    const resolveCwd = (cwd) => {
      if (!locations.has(cwd)) locations.set(cwd, realpath(cwd).catch(() => cwd));
      return locations.get(cwd);
    };

    const byId = new Map();
    for (const { dir: home, appDataDir } of homes) {
      const convDir = join(home, 'conversations');
      const dbPath = join(home, 'conversation_summaries.db');
      const summaryRows = querySummariesDb(dbPath, appDataDir);

      for (const row of summaryRows) {
        const id = row.conversation_id;
        if (byId.has(id)) continue;
        const uris = parseWorkspaceUris(row.workspace_uris);
        if (!uris.length) continue;
        const cwds = await Promise.all(uris.map((u) => resolveCwd(u)));
        const matchedCwd = workspace ? cwds.find((c) => c === workspace) : cwds[0];
        if (!matchedCwd) continue;
        const convFile = join(convDir, `${id}.db`);
        const fileStat = await stat(convFile).catch(() => undefined);
        if (!fileStat) continue;
        const rawTitle = typeof row.title === 'string' ? row.title.trim() : '';
        const rawPreview = cleanAgyPreview(row.preview);
        const previewTitle = rawPreview ? sessionTitlePreview(rawPreview) : undefined;
        const name = rawTitle || previewTitle || '未命名会话';
        const stepCount = Number(row.step_count) || 0;
        if (!rawTitle && !previewTitle && stepCount <= 0) continue;
        byId.set(id, {
          agent: 'agy',
          id,
          cwd: matchedCwd,
          path: convFile,
          appDataDir: row.app_data_dir || appDataDir,
          name,
          modified: toIsoDate(row.last_modified_time, fileStat.mtimeMs),
          messageCount: Math.max(1, stepCount),
          active: false,
        });
      }

      const entries = await readdir(convDir, { withFileTypes: true }).catch(() => []);
      for (const entry of entries) {
        if (!entry.isFile() || !entry.name.endsWith('.db')) continue;
        const id = entry.name.slice(0, -3);
        if (!idPattern.test(id) || byId.has(id)) continue;
        const full = join(convDir, entry.name);
        const sidecar = await inspectSidecarSession(home, id, full, undefined, workspace, locations).catch(() => undefined);
        if (sidecar) byId.set(id, { ...sidecar, appDataDir: sidecar.appDataDir || appDataDir });
      }
    }

    const rows = [...byId.values()].sort((a, b) => b.modified.localeCompare(a.modified));
    if (scanGeneration === generation && pending.get(key)?.promise === promise) {
      cache.delete(key);
      cache.set(key, { homesKey, revision, time: Date.now(), rows });
      if (cache.size > 8) cache.delete(cache.keys().next().value);
    }
    return rows;
  })();

  pending.set(key, { homesKey, revision, refresh, promise });
  try { return await promise; } finally { if (pending.get(key)?.promise === promise) pending.delete(key); }
}

export async function listAgySessions(cwd, refresh = false) {
  const target = await realpath(cwd).catch(() => undefined);
  if (!target) return [];
  return (await agyComputerSessions(undefined, target, refresh)).slice(0, maxSessions);
}

export async function findAgySession(cwd, id) {
  if (!idPattern.test(id)) return undefined;
  const target = cwd ? await realpath(cwd).catch(() => cwd) : undefined;
  const homes = [];
  for (const item of agyHomes()) {
    const resolved = await realpath(item.dir).catch(() => undefined);
    if (resolved) homes.push({ dir: resolved, appDataDir: item.appDataDir });
  }
  if (!homes.length) return undefined;

  const homesKey = homes.map((h) => h.dir).join(':');
  for (const key of [target ?? '', '']) {
    const hit = cache.get(key);
    if (hit?.homesKey === homesKey && Date.now() - hit.time < cacheMs) {
      const cached = hit.rows.find((row) => row.id === id && (!target || row.cwd === target));
      if (cached) {
        const exists = await stat(cached.path).catch(() => undefined);
        if (exists) return cached;
      }
    }
  }

  const locations = new Map();
  const resolveCwd = (dir) => {
    if (!locations.has(dir)) locations.set(dir, realpath(dir).catch(() => dir));
    return locations.get(dir);
  };
  for (const { dir: home, appDataDir } of homes) {
    const convDir = join(home, 'conversations');
    const convFile = join(convDir, `${id}.db`);
    const fileStat = await stat(convFile).catch(() => undefined);
    if (!fileStat) continue;

    const row = querySummaryById(join(home, 'conversation_summaries.db'), id, appDataDir);
    if (row) {
      const uris = parseWorkspaceUris(row.workspace_uris);
      if (uris.length) {
        const cwds = await Promise.all(uris.map((u) => resolveCwd(u)));
        const matchedCwd = target ? cwds.find((c) => c === target) : cwds[0];
        if (matchedCwd) {
          const rawTitle = typeof row.title === 'string' ? row.title.trim() : '';
          const rawPreview = cleanAgyPreview(row.preview);
          const previewTitle = rawPreview ? sessionTitlePreview(rawPreview) : undefined;
          const stepCount = Number(row.step_count) || 0;
          if (rawTitle || previewTitle || stepCount > 0) {
            return {
              agent: 'agy',
              id,
              cwd: matchedCwd,
              path: convFile,
              appDataDir: row.app_data_dir || appDataDir,
              name: rawTitle || previewTitle || '未命名会话',
              modified: toIsoDate(row.last_modified_time, fileStat.mtimeMs),
              messageCount: Math.max(1, stepCount),
              active: false,
            };
          }
        }
      }
    }

    const sidecar = await inspectSidecarSession(home, id, convFile, fileStat, target, locations).catch(() => undefined);
    if (sidecar) return { ...sidecar, appDataDir: sidecar.appDataDir || appDataDir };
  }
  return undefined;
}

export function readAgyTranscriptEntries(sessionId) {
  for (const { dir } of agyHomes()) {
    const transcriptPath = join(dir, 'brain', sessionId, '.system_generated', 'logs', 'transcript.jsonl');
    if (existsSync(transcriptPath)) {
      try { return realpathSync(transcriptPath); } catch {}
    }
  }
  return undefined;
}
