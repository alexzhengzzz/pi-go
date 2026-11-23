// Codex CLI session history scanning for Pi Go.
//
// Reads Codex's native rollout JSONL files from CODEX_HOME/sessions
// (default ~/.codex/sessions/YYYY/MM/DD/rollout-...-<uuid>.jsonl) and optional
// thread names from CODEX_HOME/session_index.jsonl.
//
// Every returned row carries `agent: 'codex'`.
import { createReadStream } from 'node:fs';
import { readdir, readFile, realpath, stat, unlink } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { sessionTitlePreview } from '../../bridge/message-view.mjs';

const idPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const maxSessions = 250;
const cacheMs = 5000;

export function codexHome() {
  if (process.env.CODEX_HOME) return resolve(process.env.CODEX_HOME);
  if (process.env.PI_CODING_AGENT_DIR) return join(resolve(process.env.PI_CODING_AGENT_DIR), 'codex');
  return resolve(join(homedir(), '.codex'));
}

export function codexSessionsRoot() {
  return join(codexHome(), 'sessions');
}

export async function archivedCodexSessionIds() {
  const entries = await readdir(join(codexHome(), 'archived_sessions'), { withFileTypes: true }).catch((error) => {
    if (error.code === 'ENOENT') return [];
    throw error;
  });
  const ids = new Set();
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.startsWith('rollout-') || !entry.name.endsWith('.jsonl')) continue;
    const stem = entry.name.slice(0, -'.jsonl'.length);
    const id = stem.slice(-36);
    if (idPattern.test(id)) ids.add(id.toLowerCase());
  }
  return ids;
}

async function threadNameIndex(home) {
  const names = new Map();
  const raw = await readFile(join(home, 'session_index.jsonl'), 'utf8').catch(() => '');
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    try {
      const row = JSON.parse(line);
      if (typeof row?.id === 'string' && typeof row.thread_name === 'string' && row.thread_name.trim()) {
        names.set(row.id, row.thread_name.trim());
      }
    } catch {}
  }
  return names;
}

function userTextFromItem(payload) {
  if (!payload || typeof payload !== 'object') return undefined;
  if (payload.type === 'user_message' && typeof payload.message === 'string') return payload.message;
  if (payload.type === 'message' && payload.role === 'user' && Array.isArray(payload.content)) {
    const texts = payload.content
      .filter((part) => (part?.type === 'input_text' || part?.type === 'text') && typeof part.text === 'string')
      .map((part) => part.text);
    if (texts.length) return texts.join('\n');
  }
  return undefined;
}

function cleanPreviewText(raw) {
  if (typeof raw !== 'string') return '';
  const marker = '## My request:\n';
  const index = raw.lastIndexOf(marker);
  const body = index >= 0 ? raw.slice(index + marker.length) : raw;
  if (body.startsWith('<environment_context>') || body.startsWith('# AGENTS.md instructions')) return '';
  return body.trim();
}

async function inspectRollout(file, targetId, info, indexNames, workspace, locations) {
  const stream = createReadStream(file, { encoding: 'utf8' });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  let meta;
  let threadName;
  let firstTitle;
  let messageCount = 0;
  try {
    for await (const line of lines) {
      if (!line) continue;
      let row;
      try { row = JSON.parse(line); } catch { continue; }
      if (!meta) {
        if (row.type !== 'session_meta' || !row.payload || typeof row.payload !== 'object') return;
        const id = row.payload.id ?? row.payload.session_id;
        const cwd = row.payload.cwd;
        if (!idPattern.test(id) || typeof cwd !== 'string' || (targetId !== undefined && id !== targetId)) return;
        if (row.payload.ephemeral === true) return;
        if (workspace) {
          if (!locations.has(cwd)) locations.set(cwd, realpath(cwd).catch(() => undefined));
          if (await locations.get(cwd) !== workspace) return;
        }
        meta = { id, cwd };
        if (typeof row.payload.name === 'string' && row.payload.name.trim()) threadName = row.payload.name.trim();
        if (targetId !== undefined) return { agent: 'codex', id: meta.id, cwd: meta.cwd, path: file };
        continue;
      }
      if (row.type === 'event_msg' && row.payload?.type === 'thread_name_updated' && typeof row.payload.name === 'string') {
        threadName = row.payload.name.trim();
      }
      if (row.type === 'event_msg' && row.payload?.type === 'user_message') {
        messageCount += 1;
        if (firstTitle === undefined) {
          const text = cleanPreviewText(userTextFromItem(row.payload));
          if (text) firstTitle = sessionTitlePreview(text) ?? '';
        }
      } else if (row.type === 'response_item' && row.payload?.type === 'message') {
        const role = row.payload.role;
        if (role === 'user' || role === 'assistant') {
          if (role === 'assistant') messageCount += 1;
          else if (firstTitle === undefined) {
            const text = cleanPreviewText(userTextFromItem(row.payload));
            if (text) {
              firstTitle = sessionTitlePreview(text) ?? '';
              if (messageCount === 0) messageCount = 1;
            }
          }
        }
      }
    }
    if (!meta) return;
    const indexed = indexNames?.get(meta.id);
    const name = threadName || indexed || firstTitle;
    if (!name && messageCount === 0) return;
    const statInfo = info ?? await stat(file);
    return {
      agent: 'codex',
      id: meta.id,
      cwd: meta.cwd,
      path: file,
      name: name || '未命名会话',
      modified: new Date(statInfo.mtimeMs).toISOString(),
      messageCount: Math.max(1, messageCount),
      active: false,
    };
  } finally {
    lines.close();
    stream.destroy();
  }
}

async function rolloutFiles(root, matches) {
  const files = [];
  const stack = [root];
  while (stack.length > 0 && files.length < 2000) {
    const dir = stack.pop();
    const entries = await readdir(dir, { withFileTypes: true }).catch((error) => {
      if (error.code === 'ENOENT') return [];
      throw error;
    });
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
      } else if (entry.isFile() && matches(entry.name)) {
        if (dirname(await realpath(full).catch(() => '')) === dir) files.push(full);
      }
    }
  }
  return files;
}

const cache = new Map();
const pending = new Map();
let generation = 0;

export function invalidateCodexCatalog() {
  cache.clear();
  pending.clear();
  generation += 1;
}

export async function codexComputerSessions(revision, workspace, refresh = false) {
  const home = await realpath(codexHome()).catch(() => undefined);
  const root = home && await realpath(join(home, 'sessions')).catch((error) => {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  });
  if (!root) return [];
  const key = workspace ?? '';
  const global = cache.get('');
  const hit = cache.get(key);
  if (!refresh && workspace && global?.root === root && global.revision === revision && Date.now() - global.time < cacheMs &&
    !(hit?.root === root && hit.revision === revision && hit.time >= global.time)) {
    return global.rows.filter((row) => row.cwd === workspace);
  }
  const inflight = pending.get(key);
  if (!refresh && hit?.root === root && hit.revision === revision && Date.now() - hit.time < cacheMs) {
    return hit.rows;
  }
  if (inflight?.root === root && inflight.revision === revision && (!refresh || inflight.refresh)) return inflight.promise;
  const previous = hit?.root === root ? hit.entries : undefined;
  const scanGeneration = generation;
  const promise = (async () => {
    const [files, indexNames] = await Promise.all([
      rolloutFiles(root, (name) => name.endsWith('.jsonl')),
      threadNameIndex(home),
    ]);
    const entries = new Map();
    const rows = [];
    const locations = new Map();
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(8, files.length) }, async () => {
      while (next < files.length) {
        const file = files[next++];
        const info = await stat(file).catch(() => undefined);
        if (!info) continue;
        const prior = previous?.get(file);
        let row;
        if (prior && prior.mtime === info.mtimeMs && prior.size === info.size && prior.ino === info.ino) {
          row = prior.row;
          if (row && indexNames.has(row.id) && row.name === '未命名会话') {
            row = { ...row, name: indexNames.get(row.id) };
          }
        } else {
          row = await inspectRollout(file, undefined, info, indexNames, workspace, locations).catch(() => undefined);
          if (row) {
            const resolved = await realpath(row.cwd).catch(() => row.cwd);
            row = { ...row, cwd: resolved };
          }
        }
        entries.set(file, { mtime: info.mtimeMs, size: info.size, ino: info.ino, row });
        if (row) rows.push(row);
      }
    }));
    rows.sort((a, b) => b.modified.localeCompare(a.modified));
    if (scanGeneration === generation && pending.get(key)?.promise === promise) {
      cache.delete(key);
      cache.set(key, { root, revision, time: Date.now(), rows, entries });
      if (cache.size > 8) cache.delete(cache.keys().next().value);
    }
    return rows;
  })();
  pending.set(key, { root, revision, refresh, promise });
  try { return await promise; } finally { if (pending.get(key)?.promise === promise) pending.delete(key); }
}

export async function listCodexSessions(cwd, refresh = false) {
  const target = await realpath(cwd).catch(() => undefined);
  if (!target) return [];
  return (await codexComputerSessions(undefined, target, refresh)).slice(0, maxSessions);
}

export async function findCodexSession(cwd, id) {
  if (!idPattern.test(id)) return undefined;
  const root = await realpath(codexSessionsRoot()).catch((error) => {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  });
  if (!root) return undefined;
  const suffix = `${id}.jsonl`;
  const files = await rolloutFiles(root, (name) => name === suffix || name.endsWith(`-${suffix}`) || name.endsWith(`_${suffix}`));
  for (const file of files) {
    const row = await inspectRollout(file, id).catch(() => undefined);
    if (!row) continue;
    const resolved = await realpath(row.cwd).catch(() => undefined);
    if (!cwd || resolved === cwd) return { ...row, cwd: resolved ?? row.cwd };
  }
  return undefined;
}
