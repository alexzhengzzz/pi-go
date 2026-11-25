// Session history scanning for the Pi Go daemon.
//
// Scan the native Pi session store (PI_CODING_AGENT_DIR/sessions) and filter rows by
// the header's project cwd. Filename forms follow computer-sessions.mjs:
// "<id>.jsonl" and "<slug>_<id>.jsonl" are both accepted when restoring an ID.
import { createReadStream } from 'node:fs';
import { readdir, realpath, stat } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { sessionTitlePreview } from '../bridge/message-view.mjs';

const idPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const maxSessions = 250;
const cacheMs = 5000;

export function sessionsRoot() {
  return resolve(process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi', 'agent'), 'sessions');
}

async function inspect(file, targetId) {
  const stream = createReadStream(file, { encoding: 'utf8' });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  let header;
  let name;
  let firstTitle;
  let messageCount = 0;
  try {
    for await (const line of lines) {
      let row;
      try { row = JSON.parse(line); } catch { continue; }
      if (!header) {
        if (row.type !== 'session' || !idPattern.test(row.id) || typeof row.cwd !== 'string' ||
          (targetId !== undefined && row.id !== targetId)) return;
        header = row;
      }
      if (row.type === 'session_info' && typeof row.name === 'string') name = row.name.trim();
      if (row.type === 'message') {
        if (targetId !== undefined) return { id: header.id, cwd: header.cwd, path: file };
        messageCount += 1;
        if (firstTitle === undefined && row.message?.role === 'user') firstTitle = sessionTitlePreview(row.message.content) ?? '';
      }
    }
    if (!header || !messageCount) return;
    const info = await stat(file);
    return { id: header.id, cwd: header.cwd, path: file,
      name: name || firstTitle || '未命名会话',
      modified: new Date(info.mtimeMs).toISOString() };
  } finally { lines.close(); stream.destroy(); }
}

async function sessionFiles(root, matches) {
  const files = [];
  const projects = await readdir(root, { withFileTypes: true }).catch((error) => {
    if (error.code === 'ENOENT') return [];
    throw error;
  });
  for (const entry of projects) {
    if (!entry.isDirectory()) continue;
    const directory = join(root, entry.name);
    for (const file of await readdir(directory, { withFileTypes: true }).catch(() => [])) {
      if (!file.isFile() || !matches(file.name)) continue;
      const path = join(directory, file.name);
      // A symlinked session file must still live inside the store itself.
      if (dirname(await realpath(path).catch(() => '')) === directory) files.push(path);
    }
  }
  return files;
}

let cache;
let generation = 0;
const piFileIndex = new Map();

export function invalidateSessionCatalog() {
  cache = undefined;
  piFileIndex.clear();
  generation += 1;
}

// List the session history of one project directory (realpath-matched).
export async function listSessions(cwd, refresh = false) {
  const root = await realpath(sessionsRoot()).catch((error) => {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  });
  if (!root) return [];
  if (!refresh && cache?.root === root && Date.now() - cache.time < cacheMs) {
    return cache.rows.filter((row) => row.cwd === cwd);
  }
  const scanGeneration = generation;
  const files = await sessionFiles(root, (name) => name.endsWith('.jsonl'));
  const rows = [];
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(8, files.length) }, async () => {
    while (next < files.length) {
      const file = files[next++];
      const row = await inspect(file).catch(() => undefined);
      if (!row) continue;
      const resolved = await realpath(row.cwd).catch(() => undefined);
      if (resolved) {
        rows.push({ ...row, cwd: resolved });
        piFileIndex.set(row.id, file);
      }
    }
  }));
  rows.sort((left, right) => right.modified.localeCompare(left.modified));
  if (scanGeneration === generation) cache = { root, time: Date.now(), rows };
  return rows.filter((row) => row.cwd === cwd).slice(0, maxSessions);
}

// Resolve one session ID to its file, requiring exactly one match inside the
// given project.
export async function findSession(cwd, id) {
  if (!idPattern.test(id)) return undefined;
  const root = await realpath(sessionsRoot()).catch((error) => {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  });
  if (!root) return undefined;
  const indexed = piFileIndex.get(id);
  if (indexed && indexed.startsWith(`${root}/`)) {
    const resolvedFile = await realpath(indexed).catch(() => undefined);
    if (resolvedFile === indexed) {
      const row = await inspect(indexed, id).catch(() => undefined);
      if (row) {
        const resolved = await realpath(row.cwd).catch(() => undefined);
        if (resolved === cwd) return row;
      }
    }
    piFileIndex.delete(id);
  }
  const filename = `${id}.jsonl`;
  const files = await sessionFiles(root, (name) => name === filename || name.endsWith(`_${filename}`));
  if (files.length !== 1) return undefined;
  const row = await inspect(files[0], id).catch(() => undefined);
  if (!row) return undefined;
  const resolved = await realpath(row.cwd).catch(() => undefined);
  if (resolved !== cwd) return undefined;
  piFileIndex.set(id, files[0]);
  return row;
}
