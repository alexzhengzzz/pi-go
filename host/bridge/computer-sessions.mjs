import { readdir, stat, realpath } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { sessionTitlePreview } from './message-view.mjs';
import { codexComputerSessions, findCodexSession } from '../agents/codex/catalog.mjs';
import { agyComputerSessions, findAgySession } from '../agents/agy/catalog.mjs';

const idPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const cache = new Map();
const pending = new Map();
const piFileIndex = new Map();

async function inspect(file, targetId, info, cwd, resolvedPaths) {
  const stream = createReadStream(file, { encoding: 'utf8' });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  let header, name, firstTitle, messageCount = 0;
  try {
    for await (const line of lines) {
      let row; try { row = JSON.parse(line); } catch { continue; }
      if (!header) {
        if (row.type !== 'session' || !idPattern.test(row.id) || typeof row.cwd !== 'string' ||
          (targetId !== undefined && row.id !== targetId)) return;
        if (cwd) {
          if (!resolvedPaths.has(row.cwd)) resolvedPaths.set(row.cwd, realpath(row.cwd).catch(() => undefined));
          if (await resolvedPaths.get(row.cwd) !== cwd) return;
        }
        header = row;
      }
      if (row.type === 'session_info' && typeof row.name === 'string') name = row.name.trim();
      if (row.type === 'message') {
        if (targetId !== undefined) return { id: header.id, cwd: header.cwd };
        messageCount++;
        if (firstTitle === undefined && row.message?.role === 'user') firstTitle = sessionTitlePreview(row.message.content) ?? '';
      }
    }
    if (!header || !messageCount) return;
    return { agent: 'pi', id: header.id, cwd: header.cwd, name: name || firstTitle || '未命名会话',
      modified: info.mtime.toISOString(), messageCount, active: false };
  } finally { lines.close(); stream.destroy(); }
}

function sessionRoot() {
  const configuredRoot = resolve(process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi', 'agent'), 'sessions');
  return realpath(configuredRoot).catch((e) => { if (e.code === 'ENOENT') return undefined; throw e; });
}

async function sessionFiles(root, matches, cwd) {
  const files = [];
  const projects = await readdir(root, { withFileTypes: true }).catch((e) => { if (e.code === 'ENOENT') return []; throw e; });
  for (const entry of projects) {
    if (!entry.isDirectory()) continue;
    // Pi encodes the cwd in its native directory name. Also support older,
    // custom directories by checking their session headers.
    if (cwd && entry.name.startsWith('--') && entry.name.endsWith('--') &&
        entry.name !== `--${cwd.replace(/^[/\\]/, '').replace(/[/\\:]/g, '-')}--`) continue;
    const directory = join(root, entry.name);
    for (const file of await readdir(directory, { withFileTypes: true }).catch(() => [])) {
      if (!file.isFile() || !matches(file.name)) continue;
      const path = join(directory, file.name);
      if (dirname(await realpath(path).catch(() => '')) === directory) files.push(path);
    }
  }
  return files;
}

// Match the supported native session filename forms when restoring an ID.
export async function findComputerSession(id, agent) {
  if (!idPattern.test(id)) return;
  if (!agent || agent === 'pi') {
    const indexedFile = piFileIndex.get(id);
    if (indexedFile) {
      const row = await inspect(indexedFile, id).catch(() => undefined);
      if (row) return { ...row, agent: 'pi' };
      piFileIndex.delete(id);
    }
    const root = await sessionRoot();
    if (root) {
      const filename = `${id}.jsonl`;
      const files = await sessionFiles(root, (name) => name === filename || name.endsWith(`_${filename}`));
      for (const file of files) {
        const row = await inspect(file, id).catch(() => undefined);
        if (row) {
          piFileIndex.set(id, file);
          return { ...row, agent: 'pi' };
        }
      }
    }
  }
  if (!agent || agent === 'codex') {
    const codex = await findCodexSession(undefined, id);
    if (codex) return codex;
  }
  if (!agent || agent === 'agy') {
    const agy = await findAgySession(undefined, id);
    if (agy) return agy;
  }
}

// Read Pi's, Codex's, and agy's native stores, including projects without an active session.
export async function computerSessions(revision, cwd, refresh = false) {
  const [piRows, codexRows, agyRows] = await Promise.all([
    piComputerSessions(revision, cwd, refresh),
    codexComputerSessions(revision, cwd, refresh).catch(() => []),
    agyComputerSessions(revision, cwd, refresh).catch(() => []),
  ]);
  const combined = [...piRows, ...codexRows, ...agyRows];
  combined.sort((a, b) => (b.modified ?? '').localeCompare(a.modified ?? ''));
  return combined;
}

async function piComputerSessions(revision, cwd, refresh) {
  const root = await sessionRoot();
  if (!root) return [];
  const key = cwd ?? '';
  const cached = cache.get(key);
  const inflight = pending.get(key);
  if (!refresh && cached?.root === root && cached.revision === revision && Date.now() - cached.time < 5000) return cached.rows;
  if (inflight?.root === root && inflight.revision === revision && (!refresh || inflight.refresh)) return inflight.promise;
  const promise = (async () => {
    const files = await sessionFiles(root, (name) => name.endsWith('.jsonl'), cwd);
    const entries = new Map();
    const rows = [];
    const resolvedPaths = new Map();
    const previous = cached?.root === root ? cached.entries : undefined;
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(8, files.length) }, async () => {
      while (next < files.length) {
        const file = files[next++];
        const info = await stat(file).catch(() => undefined);
        if (!info) continue;
        const prior = previous?.get(file);
        const row = prior?.mtime === info.mtimeMs && prior?.size === info.size && prior?.ino === info.ino
          ? prior.row : await inspect(file, undefined, info, cwd, resolvedPaths).catch(() => undefined);
        entries.set(file, { mtime: info.mtimeMs, size: info.size, ino: info.ino, row });
        if (row) {
          rows.push(row);
          piFileIndex.set(row.id, file);
        }
      }
    }));
    rows.sort((a, b) => b.modified.localeCompare(a.modified));
    if (pending.get(key)?.promise === promise) {
      cache.delete(key);
      cache.set(key, { root, revision, time: Date.now(), rows, entries });
      if (cache.size > 8) cache.delete(cache.keys().next().value);
    }
    return rows;
  })();
  pending.set(key, { root, revision, refresh, promise });
  try { return await promise; } finally { if (pending.get(key)?.promise === promise) pending.delete(key); }
}
