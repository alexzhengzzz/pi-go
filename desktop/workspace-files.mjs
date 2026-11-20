import { constants, closeSync, createReadStream, fchmodSync, fstatSync, fsyncSync, lstatSync, openSync, readFileSync, readdirSync, realpathSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { opendir } from 'node:fs/promises';
import { createHash, randomBytes } from 'node:crypto';
import { dirname, isAbsolute, join, relative, sep } from 'node:path';

export const maxTextBytes = 64 * 1024;
export const maxDownloadBytes = 64 * 1024 * 1024;
const maxLookupEntries = 20000;
const excludedLookupDirectories = new Set(['.git', 'node_modules', 'oh_modules']);
const fail = (code) => { throw new Error(code); };
const within = (root, path) => path === root || (!relative(root, path).startsWith(`..${sep}`) && relative(root, path) !== '..' && !isAbsolute(relative(root, path)));
const version = (bytes) => createHash('sha256').update(bytes).digest('hex');

function target(cwd, path) {
  if (typeof path !== 'string' || path.length > 2048 || path.includes('\0') || path.includes('\\') || isAbsolute(path) ||
    path.split('/').some((part) => part === '..' || part === '.')) fail('invalid_path');
  const root = realpathSync(cwd);
  let current = root;
  for (const part of path.split('/').filter(Boolean)) {
    current = join(current, part);
    if (lstatSync(current).isSymbolicLink()) fail('path_forbidden');
  }
  const resolved = realpathSync(current);
  if (!within(root, resolved)) fail('path_forbidden');
  return { root, path: resolved };
}

function readText(cwd, path) {
  const resolved = target(cwd, path);
  const fd = openSync(resolved.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = fstatSync(fd);
    if (!info.isFile()) fail('not_text_file');
    if (info.size > maxTextBytes) fail('file_too_large');
    const bytes = readFileSync(fd);
    if (bytes.length > maxTextBytes) fail('file_too_large');
    let text;
    try { text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); }
    catch { fail('not_text_file'); }
    if (text.includes('\0')) fail('not_text_file');
    return { text, version: version(bytes), mode: info.mode & 0o777, resolved, info };
  } finally { closeSync(fd); }
}

export function listFiles(cwd, path = '', cursor = 0) {
  const resolved = target(cwd, path);
  if (!lstatSync(resolved.path).isDirectory()) fail('not_directory');
  const entries = readdirSync(resolved.path, { withFileTypes: true }).map((entry) => ({
    name: entry.name, path: path ? `${path}/${entry.name}` : entry.name,
    kind: entry.isSymbolicLink() ? 'blocked' : entry.isDirectory() ? 'directory' : entry.isFile() ? 'file' : 'blocked',
  })).sort((a, b) => Number(b.kind === 'directory') - Number(a.kind === 'directory') || a.name.localeCompare(b.name));
  const start = Number.isSafeInteger(cursor) && cursor >= 0 ? Math.min(cursor, entries.length) : 0;
  return { path, entries: entries.slice(start, start + 100), total: entries.length,
    nextCursor: start + 100 < entries.length ? start + 100 : undefined };
}

export function previewFile(cwd, path) {
  const file = readText(cwd, path);
  return { path, text: file.text, version: file.version };
}

export async function findWorkspaceFileByName(cwd, name) {
  const root = realpathSync(cwd);
  const pending = [''];
  let visited = 0;
  let match;
  while (pending.length) {
    const path = pending.pop();
    const directory = await opendir(target(root, path).path);
    for await (const entry of directory) {
      if (++visited > maxLookupEntries) fail('file_lookup_limit');
      const relativePath = path ? `${path}/${entry.name}` : entry.name;
      if (entry.isDirectory() && !excludedLookupDirectories.has(entry.name)) pending.push(relativePath);
      if (!entry.isFile() || entry.name !== name) continue;
      if (match !== undefined) fail('ambiguous_file_name');
      match = relativePath;
    }
  }
  if (match === undefined) fail('file_not_found');
  return match;
}

export function openWorkspaceDownload(cwd, path) {
  const resolved = target(cwd, path);
  let fd = openSync(resolved.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = fstatSync(fd);
    if (!info.isFile()) fail('not_file');
    if (info.size > maxDownloadBytes) fail('file_too_large');
    if (info.size === 0) return { size: 0 };
    const stream = createReadStream(resolved.path, { fd, start: 0, end: info.size - 1 });
    fd = undefined; // The stream owns the descriptor from this point.
    return { size: info.size, stream };
  } finally { if (fd !== undefined) closeSync(fd); }
}

export function saveFile(cwd, path, text, expected) {
  if (typeof text !== 'string' || text.includes('\0') || typeof expected !== 'string' || !/^[a-f0-9]{64}$/.test(expected)) fail('invalid_file');
  const bytes = Buffer.from(text, 'utf8');
  if (bytes.length > maxTextBytes) fail('file_too_large');
  const previous = readText(cwd, path);
  if (previous.version !== expected) fail('file_conflict');
  if (previous.info.nlink !== 1 || previous.info.uid !== process.getuid()) fail('path_forbidden');
  const temporary = join(dirname(previous.resolved.path), `.pigo-${randomBytes(16).toString('hex')}.tmp`);
  let fd;
  try {
    fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, previous.mode);
    fchmodSync(fd, previous.mode);
    writeFileSync(fd, bytes);
    fsyncSync(fd);
    closeSync(fd); fd = undefined;
    const current = readText(cwd, path);
    if (current.version !== expected || current.info.ino !== previous.info.ino || current.info.dev !== previous.info.dev) fail('file_conflict');
    if (target(cwd, path).path !== previous.resolved.path) fail('path_forbidden');
    renameSync(temporary, previous.resolved.path);
    return { path, text, version: version(bytes) };
  } finally {
    if (fd !== undefined) closeSync(fd);
    try { unlinkSync(temporary); } catch {}
  }
}
