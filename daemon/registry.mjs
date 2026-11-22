// Workspace registry for the Pi Go daemon — the replacement for the patched
// Desktop's WorkspaceManager persistence. Keeps a small JSON list of the
// projects the phone may open, create sessions in, or close. Files on disk are
// never touched by removal: closing a workspace only deregisters it and stops
// its Pi runtimes, exactly like Desktop's "remove workspace".
import { createHash } from 'node:crypto';
import { lstatSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const workspaceId = (path) => createHash('sha256').update(path).digest('hex').slice(0, 16);

function load(file) {
  let value;
  try { value = JSON.parse(readFileSync(file, 'utf8')); } catch { return { workspaces: [] }; }
  if (!value || !Array.isArray(value.workspaces)) return { workspaces: [] };
  return { workspaces: value.workspaces.filter((row) =>
    typeof row?.id === 'string' && typeof row?.name === 'string' && typeof row?.path === 'string') };
}

export class WorkspaceRegistry {
  constructor(file) {
    this.file = resolve(file);
    mkdirSync(dirname(this.file), { recursive: true, mode: 0o700 });
    const info = lstatSync(dirname(this.file));
    if (info.uid !== process.getuid() || (info.mode & 0o077)) throw new Error('unsafe_registry_directory');
    this.state = load(this.file);
  }

  save() {
    const next = `${this.file}.${process.pid}.tmp`;
    writeFileSync(next, JSON.stringify(this.state, null, 2), { mode: 0o600 });
    renameSync(next, this.file);
  }

  list() { return this.state.workspaces.map((row) => ({ ...row })); }

  // Returns the workspace, or null when the path (or its realpath twin) is
  // already registered — callers map that onto workspace_exists / untrusted.
  create(name, path) {
    const resolved = resolve(path);
    if (this.state.workspaces.some((row) => resolve(row.path) === resolved)) return null;
    const row = { id: workspaceId(resolved), name, path: resolved, createdAt: new Date().toISOString() };
    this.state.workspaces.push(row);
    this.save();
    return { ...row };
  }

  remove(path) {
    const resolved = resolve(path);
    const before = this.state.workspaces.length;
    this.state.workspaces = this.state.workspaces.filter((row) => resolve(row.path) !== resolved);
    if (this.state.workspaces.length === before) return false;
    this.save();
    return true;
  }

  // Workspaces whose stored path matches the given realpath (symlinks resolve).
  async findByRealpath(cwd) {
    if (!cwd) return [];
    const { realpath } = await import('node:fs/promises');
    return (await Promise.all(this.state.workspaces.map(async (row) => {
      const path = await realpath(row.path).catch(() => undefined);
      return path === cwd ? { ...row } : undefined;
    }))).filter(Boolean);
  }
}
