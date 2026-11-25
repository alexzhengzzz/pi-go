// Persistent list of Pi Go workspaces. Closing a workspace removes its
// registration and stops its managed Pi runtimes while preserving its files.
import { createHash, randomBytes } from 'node:crypto';
import { closeSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

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

  save(state) {
    const next = `${this.file}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
    const fd = openSync(next, 'wx', 0o600);
    try {
      writeFileSync(fd, JSON.stringify(state, null, 2));
      fsyncSync(fd);
      closeSync(fd);
      renameSync(next, this.file);
      this.state = state;
    } catch (error) {
      try { closeSync(fd); } catch {}
      try { unlinkSync(next); } catch {}
      throw error;
    }
  }

  list() { return this.state.workspaces.map((row) => ({ ...row })); }

  // Returns the workspace, or null when the path (or its realpath twin) is
  // already registered — callers map that onto workspace_exists / untrusted.
  create(name, path) {
    const resolved = resolve(path);
    if (this.state.workspaces.some((row) => resolve(row.path) === resolved)) return null;
    const row = { id: workspaceId(resolved), name, path: resolved, createdAt: new Date().toISOString() };
    this.save({ workspaces: [...this.state.workspaces, row] });
    return { ...row };
  }

  rename(id, name) {
    const row = this.state.workspaces.find((workspace) => workspace.id === id);
    if (!row) return undefined;
    const updated = { ...row, name };
    this.save({ workspaces: this.state.workspaces.map((workspace) => workspace === row ? updated : workspace) });
    return updated;
  }

  remove(path) {
    const resolved = resolve(path);
    const workspaces = this.state.workspaces.filter((row) => resolve(row.path) !== resolved);
    if (workspaces.length === this.state.workspaces.length) return false;
    this.save({ workspaces });
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
