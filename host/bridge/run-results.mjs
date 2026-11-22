import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { previewFile } from './workspace-files.mjs';
import { stateDirectory } from './session-metadata.mjs';

const fileLimit = 1200;
const textBudget = 8 * 1024 * 1024;
const patchLimit = 24 * 1024;
const recentLimit = 120;
const ignored = new Set(['.git', '.pi-go', 'node_modules', 'oh_modules', '.DS_Store']);
const artifactPattern = /\.(png|jpe?g|webp|gif|svg|pdf|md|html|csv|xlsx?|docx?|pptx?|zip|log)$/i;

function allowable(path) {
  return path.length <= 1024 && !/[\u0000-\u001f\u007f\\]/.test(path) &&
    path.split('/').every((part) => part && part !== '..' && part !== '.' && !ignored.has(part));
}

export function referencedArtifacts(cwd, references) {
  const root = realpathSync(cwd);
  const found = new Set();
  for (const reference of references) {
    if (typeof reference !== 'string' || reference.length > 2048 || /^[a-z]+:\/\//i.test(reference)) continue;
    const path = relative(root, isAbsolute(reference) ? reference : resolve(root, reference));
    if (!allowable(path) || !artifactPattern.test(path)) continue;
    try {
      const local = join(root, path);
      const info = lstatSync(local);
      if (info.isFile() && realpathSync(local) === local) found.add(path);
      if (found.size >= 12) break;
    } catch {}
  }
  return [...found];
}

function treePaths(cwd) {
  const paths = [];
  const queue = [''];
  let visited = 0;
  while (queue.length && visited <= fileLimit) {
    const dir = queue.shift();
    for (const entry of readdirSync(join(cwd, dir), { withFileTypes: true })) {
      const path = dir ? `${dir}/${entry.name}` : entry.name;
      if (!allowable(path)) continue;
      if (++visited > fileLimit) return { paths, partial: true };
      if (entry.isDirectory()) queue.push(path);
      if (entry.isFile()) paths.push(path);
    }
  }
  return { paths, partial: false };
}

function workspacePaths(cwd) {
  try {
    const output = execFileSync('git', ['--no-optional-locks', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '.'],
      { cwd, encoding: 'utf8', timeout: 1500, maxBuffer: 512 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
    const paths = [...new Set(output.split('\0').filter(allowable))];
    return { paths: paths.slice(0, fileLimit), partial: paths.length > fileLimit };
  } catch (error) {
    if (error.status === 128) return treePaths(cwd);
    return { paths: [], partial: true };
  }
}

export function captureWorkspace(cwd) {
  const { paths, partial } = workspacePaths(cwd);
  let remaining = textBudget;
  const files = new Map();
  for (const path of paths) {
    try {
      const info = lstatSync(join(cwd, path));
      if (!info.isFile()) continue;
      const signature = [info.ino, info.size, info.mtimeMs, info.ctimeMs, info.mode].join(':');
      let text;
      if (info.size <= remaining && info.size <= 64 * 1024) {
        remaining -= info.size;
        try { text = previewFile(cwd, path).text; } catch {}
      }
      files.set(path, { signature, text, mode: info.mode });
    } catch {}
  }
  return { files, partial };
}

function makePatch(directory, before, after) {
  const left = join(directory, 'before');
  const right = join(directory, 'after');
  if (before) writeFileSync(left, before.text, { mode: 0o600 });
  if (after) writeFileSync(right, after.text, { mode: 0o600 });
  try {
    execFileSync('git', ['--no-pager', 'diff', '--no-index', '--no-ext-diff', '--no-textconv', '--no-color',
      '--no-renames', '--', before ? left : '/dev/null', after ? right : '/dev/null'],
    { cwd: directory, encoding: 'utf8', timeout: 1000, maxBuffer: patchLimit, stdio: ['ignore', 'pipe', 'ignore'] });
  } catch (error) {
    if (error.status !== 1 || typeof error.stdout !== 'string') return;
    const start = error.stdout.indexOf('\n@@ ');
    if (start >= 0) return error.stdout.slice(start + 1);
  }
}

export function describeChanges(cwd, before) {
  if (!before) return { files: [], partial: true, patches: {} };
  const after = captureWorkspace(cwd);
  const files = [];
  const patches = {};
  const paths = new Set([...before.files.keys(), ...after.files.keys()]);
  let partial = before.partial || after.partial;
  let directory;
  try {
    for (const path of paths) {
      const old = before.files.get(path);
      const next = after.files.get(path);
      if ((!old && before.partial) || (!next && after.partial)) continue;
      if (old && next && (old.text !== undefined && next.text !== undefined
        ? old.text === next.text && old.mode === next.mode : old.signature === next.signature)) continue;
      if (files.length >= 30) { partial = true; break; }
      let patch;
      if (Object.keys(patches).length < 12 &&
          (!old || old.text !== undefined) && (!next || next.text !== undefined)) {
        directory ??= mkdtempSync(join(tmpdir(), 'pigo-diff-'));
        patch = makePatch(directory, old, next);
        if (patch) Object.defineProperty(patches, path, { value: patch, enumerable: true });
      }
      files.push({ path, change: !old ? 'added' : next ? 'modified' : 'deleted',
        diff: Boolean(patch), artifact: Boolean(next && artifactPattern.test(path)) });
    }
  } finally {
    if (directory) rmSync(directory, { recursive: true, force: true });
  }
  return { files, patches, partial };
}

function storeDirectory() {
  const directory = join(stateDirectory(), 'run-results');
  mkdirSync(directory, { mode: 0o700, recursive: true });
  const info = lstatSync(directory);
  if (!info.isDirectory() || info.uid !== process.getuid() || (info.mode & 0o077)) throw new Error('unsafe_run_directory');
  return directory;
}

function readRecord(path, limit) {
  try {
    const info = lstatSync(path);
    if (info.isFile() && info.uid === process.getuid() && !(info.mode & 0o077) && info.size <= limit) {
      return JSON.parse(readFileSync(path, 'utf8'));
    }
  } catch {}
}

function writeRecord(path, value) {
  const temp = `${path}.${randomBytes(6).toString('hex')}.tmp`;
  try {
    writeFileSync(temp, JSON.stringify(value), { flag: 'wx', mode: 0o600 });
    renameSync(temp, path);
  } finally {
    try { unlinkSync(temp); } catch {}
  }
}

function key(profile, id) {
  return createHash('sha256').update(JSON.stringify([profile, id])).digest('hex');
}

function records(directory) {
  return readdirSync(directory).filter((name) => /^\d{13}-[a-f0-9]{64}\.json$/.test(name)).sort().reverse();
}

export function saveRunResult(profile, event, patches = {}) {
  const directory = storeDirectory();
  const stem = `${String(event.finishedAt).padStart(13, '0')}-${key(profile, event.id)}`;
  if (Object.keys(patches).length) writeRecord(join(directory, stem + '.patches'), patches);
  writeRecord(join(directory, stem + '.json'), { profile, ...event });
  for (const name of records(directory).slice(recentLimit)) {
    for (const path of [name, name.replace(/\.json$/, '.patches')]) {
      try { unlinkSync(join(directory, path)); } catch {}
    }
  }
}

export function readRuns(profile) {
  try {
    const directory = storeDirectory();
    return records(directory).slice(0, recentLimit).flatMap((name) => {
      const record = readRecord(join(directory, name), 96 * 1024);
      if (!record || record.profile !== profile) return [];
      const { profile: _profile, ...event } = record;
      return [event];
    });
  } catch { return []; }
}

export function readRunPatch(profile, event, path) {
  const stem = `${String(event.finishedAt).padStart(13, '0')}-${key(profile, event.id)}`;
  const patches = readRecord(join(storeDirectory(), stem + '.patches'), 600 * 1024);
  return patches && Object.hasOwn(patches, path) && typeof patches[path] === 'string' ? patches[path] : undefined;
}
