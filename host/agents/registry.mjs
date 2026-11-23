// Agent registry and detection for Pi Go daemon.
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { codexHome } from './codex/catalog.mjs';

const run = promisify(execFile);
const knownAgents = ['pi', 'codex'];
let cachedStatus = [
  { id: 'pi', label: 'Pi', installed: true },
  { id: 'codex', label: 'Codex', installed: true },
];
let cachedAt = 0;
let detecting;

export function normalizeAgent(value) {
  if (value === undefined || value === null || value === '') return 'pi';
  if (typeof value === 'string' && knownAgents.includes(value)) return value;
  return undefined;
}

export function currentAgents() {
  if (Date.now() - cachedAt > 30000 && !detecting) {
    detecting = detectAgents(true).finally(() => { detecting = undefined; });
  }
  return cachedStatus;
}

export async function detectAgents(force = false) {
  if (!force && cachedAt > 0 && Date.now() - cachedAt < 30000) return cachedStatus;
  const piBin = process.env.PIGO_PI_BIN || 'pi';
  const codexBin = process.env.PIGO_CODEX_BIN || 'codex';
  const [piVersion, codexVersion] = await Promise.all([
    run(piBin, ['--version'], { timeout: 3000 }).then(({ stdout }) => stdout.trim().split('\n')[0]).catch(() => undefined),
    run(codexBin, ['--version'], { timeout: 3000 }).then(({ stdout }) => stdout.trim().split('\n')[0]).catch(() => undefined),
  ]);
  const codexAuthed = Boolean(process.env.OPENAI_API_KEY) || existsSync(join(codexHome(), 'auth.json')) || existsSync(join(codexHome(), 'config.toml'));
  cachedStatus = [
    { id: 'pi', label: 'Pi', installed: Boolean(piVersion), version: piVersion, authed: true },
    { id: 'codex', label: 'Codex', installed: Boolean(codexVersion), version: codexVersion, authed: codexAuthed },
  ];
  cachedAt = Date.now();
  return cachedStatus;
}
