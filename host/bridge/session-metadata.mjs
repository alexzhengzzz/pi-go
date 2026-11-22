import { createHash, randomBytes } from 'node:crypto';
import { lstatSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

export function stateDirectory(directory = process.env.PIGO_STATE_DIR ??
    (process.env.PIGO_IPC_DIR ? join(process.env.PIGO_IPC_DIR, 'state') : join(homedir(), '.pi-go'))) {
  const root = resolve(directory);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const info = lstatSync(root);
  if (!info.isDirectory() || info.uid !== process.getuid() || (info.mode & 0o077)) throw new Error('unsafe_state_directory');
  return root;
}

// This is presentation metadata only. Pi retains ownership of session JSONL files.
export class SessionMetadata {
  constructor(port, directory) {
    this.directory = join(stateDirectory(directory), `sessions-${port}`);
    mkdirSync(this.directory, { mode: 0o700, recursive: true });
    const directoryInfo = lstatSync(this.directory);
    if (!directoryInfo.isDirectory() || directoryInfo.uid !== process.getuid() || (directoryInfo.mode & 0o077)) throw new Error('unsafe_state_directory');
  }
  file(row) {
    return join(this.directory, createHash('sha256').update(JSON.stringify([row.cwd, row.id])).digest('hex') + '.json');
  }
  get(row) {
    const file = this.file(row);
    try {
      const info = lstatSync(file);
      if (!info.isFile() || info.uid !== process.getuid() || (info.mode & 0o077) || info.size > 2048) throw new Error('invalid_metadata');
      const value = JSON.parse(readFileSync(file, 'utf8'));
      if (value.version !== 1 || !Number.isSafeInteger(value.revision) || value.revision < 1 ||
        typeof value.pinned !== 'boolean' || typeof value.archived !== 'boolean' ||
        (value.lastVisited !== undefined && !Number.isFinite(Date.parse(value.lastVisited)))) throw new Error('invalid_metadata');
      return value;
    } catch (error) {
      if (error.code === 'ENOENT') return { version: 1, revision: 0, pinned: false, archived: false };
      throw error;
    }
  }
  update(row, patch, revision) {
    const file = this.file(row);
    const lock = file + '.lock';
    const temporary = file + '.' + randomBytes(8).toString('hex');
    try { writeFileSync(lock, String(process.pid), { flag: 'wx', mode: 0o600 }); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      this.removeAbandonedLock(lock);
      throw new Error('metadata_conflict');
    }
    try {
      const previous = this.get(row);
      if (revision !== undefined && previous.revision !== revision) throw new Error('metadata_conflict');
      const next = { ...previous, ...patch, version: 1, revision: previous.revision + 1 };
      writeFileSync(temporary, JSON.stringify(next), { mode: 0o600, flag: 'wx' });
      renameSync(temporary, file);
      return next;
    } finally {
      try { unlinkSync(temporary); } catch {}
      unlinkSync(lock);
    }
  }
  removeAbandonedLock(lock) {
    try {
      const previous = lstatSync(lock);
      if (Date.now() - previous.mtimeMs < 30000) return;
      const owner = Number(readFileSync(lock, 'utf8'));
      if (Number.isInteger(owner) && owner > 0) {
        try { process.kill(owner, 0); return; }
        catch (error) { if (error.code !== 'ESRCH') return; }
      }
      const current = lstatSync(lock);
      if (current.ino === previous.ino && current.dev === previous.dev) unlinkSync(lock);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  visit(row) {
    try { this.update(row, { lastVisited: new Date().toISOString() }); }
    catch (error) { if (error.message !== 'metadata_conflict') throw error; }
  }
}
