import { createHash, randomBytes } from 'node:crypto';
import { lstatSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

// This is presentation metadata only. Pi retains ownership of session JSONL files.
export class SessionMetadata {
  constructor(port, directory = process.env.PIGO_STATE_DIR ??
      (process.env.PIGO_IPC_DIR ? join(process.env.PIGO_IPC_DIR, 'state') : join(homedir(), '.pi-go'))) {
    const root = resolve(directory);
    mkdirSync(root, { recursive: true, mode: 0o700 });
    const info = lstatSync(root);
    if (!info.isDirectory() || info.uid !== process.getuid() || (info.mode & 0o077)) throw new Error('unsafe_state_directory');
    this.directory = join(root, `sessions-${port}`);
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
    const previous = this.get(row);
    if (revision !== undefined && previous.revision !== revision) throw new Error('metadata_conflict');
    const next = { ...previous, ...patch, version: 1, revision: previous.revision + 1 };
    const temporary = this.file(row) + '.' + randomBytes(8).toString('hex');
    try {
      writeFileSync(temporary, JSON.stringify(next), { mode: 0o600, flag: 'wx' });
      renameSync(temporary, this.file(row));
    } finally { try { unlinkSync(temporary); } catch {} }
    return next;
  }
  visit(row) { return this.update(row, { lastVisited: new Date().toISOString() }); }
}
