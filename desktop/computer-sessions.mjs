import { readdir, stat, realpath } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import { join, resolve, dirname } from 'node:path';

const idPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
let cached;
let pending;
const textOf = (content) => typeof content === 'string' ? content : Array.isArray(content) ? content.filter((p) => p.type === 'text').map((p) => p.text).join('\n') : '';

async function inspect(file, targetId, info) {
  const stream = createReadStream(file, { encoding: 'utf8' });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  let header, name, firstMessage = '', messageCount = 0;
  try {
    for await (const line of lines) {
      let row; try { row = JSON.parse(line); } catch { continue; }
      if (!header) {
        if (row.type !== 'session' || !idPattern.test(row.id) || typeof row.cwd !== 'string' ||
          (targetId !== undefined && row.id !== targetId)) return;
        header = row;
      }
      if (row.type === 'session_info' && typeof row.name === 'string') name = row.name;
      if (row.type === 'message') {
        if (targetId !== undefined) return { id: header.id, cwd: header.cwd };
        messageCount++;
        if (!firstMessage && row.message?.role === 'user') firstMessage = textOf(row.message.content).slice(0, 100);
      }
    }
    if (!header || !messageCount) return;
    return { id: header.id, cwd: header.cwd, name: (name || firstMessage || '未命名会话').slice(0, 100),
      modified: info.mtime.toISOString(), messageCount, active: false };
  } finally { lines.close(); stream.destroy(); }
}

function sessionRoot() {
  const configuredRoot = resolve(process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi', 'agent'), 'sessions');
  return realpath(configuredRoot).catch((e) => { if (e.code === 'ENOENT') return undefined; throw e; });
}

async function sessionFiles(root, matches) {
  const files = [];
  const projects = await readdir(root, { withFileTypes: true }).catch((e) => { if (e.code === 'ENOENT') return []; throw e; });
  for (const entry of projects) {
    if (!entry.isDirectory()) continue;
    const directory = join(root, entry.name);
    for (const file of await readdir(directory, { withFileTypes: true }).catch(() => [])) {
      if (!file.isFile() || !matches(file.name)) continue;
      const path = join(directory, file.name);
      if (dirname(await realpath(path).catch(() => '')) === directory) files.push(path);
    }
  }
  return files;
}

// Match the same filename forms that Desktop accepts when restoring an ID.
export async function findComputerSession(id) {
  if (!idPattern.test(id)) return;
  const root = await sessionRoot();
  if (!root) return;
  const filename = `${id}.jsonl`;
  const files = await sessionFiles(root, (name) => name === filename || name.endsWith(`_${filename}`));
  for (const file of files) {
    const row = await inspect(file, id).catch(() => undefined);
    if (row) return row;
  }
}

// Read Pi's native store, including projects that have no open Desktop tab.
export async function computerSessions() {
  const root = await sessionRoot();
  if (!root) return [];
  if (cached?.root === root && Date.now() - cached.time < 5000) return cached.rows;
  if (pending?.root === root) return pending.promise;
  const promise = (async () => {
    const files = await sessionFiles(root, (name) => name.endsWith('.jsonl'));
    const entries = new Map();
    const rows = [];
    const previous = cached?.root === root ? cached.entries : undefined;
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(8, files.length) }, async () => {
      while (next < files.length) {
        const file = files[next++];
        const info = await stat(file).catch(() => undefined);
        if (!info) continue;
        const prior = previous?.get(file);
        const row = prior?.mtime === info.mtimeMs && prior?.size === info.size && prior?.ino === info.ino
          ? prior.row : await inspect(file, undefined, info).catch(() => undefined);
        entries.set(file, { mtime: info.mtimeMs, size: info.size, ino: info.ino, row });
        if (row) rows.push(row);
      }
    }));
    rows.sort((a, b) => b.modified.localeCompare(a.modified));
    cached = { root, time: Date.now(), rows, entries };
    return rows;
  })();
  pending = { root, promise };
  try { return await promise; } finally { if (pending?.promise === promise) pending = undefined; }
}
