// Agent registry and detection for Pi Go daemon.
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { findSession as findPiSession, invalidateSessionCatalog, listSessions as listPiSessions } from '../daemon/catalog.mjs';
import { archivedCodexSessionIds, codexHome, findCodexSession, invalidateCodexCatalog, listCodexSessions } from './codex/catalog.mjs';
import { agyAuthed, archivedAgySessionIds, findAgySession, invalidateAgyCatalog, listAgySessions } from './agy/catalog.mjs';

const run = promisify(execFile);

export const agentProviders = [
  {
    id: 'pi',
    label: 'Pi',
    findSession: async (cwd, id) => {
      const found = await findPiSession(cwd, id);
      return found ? { ...found, agent: 'pi' } : undefined;
    },
    listSessions: async (cwd, refresh = false) => (await listPiSessions(cwd, refresh))
      .map(({ id, name, modified }) => ({ agent: 'pi', id, name, modified })),
    invalidateCatalog: () => invalidateSessionCatalog(),
    archivedSessionIds: async () => new Set(),
    archiveBehavior: 'none',
  },
  {
    id: 'codex',
    label: 'Codex',
    findSession: (cwd, id) => findCodexSession(cwd, id),
    listSessions: async (cwd, refresh = false) => (await listCodexSessions(cwd, refresh).catch(() => []))
      .map(({ id, name, modified }) => ({ agent: 'codex', id, name, modified })),
    invalidateCatalog: () => invalidateCodexCatalog(),
    archivedSessionIds: () => archivedCodexSessionIds().catch(() => new Set()),
    archiveBehavior: 'drop',
  },
  {
    id: 'agy',
    label: 'Antigravity',
    findSession: (cwd, id) => findAgySession(cwd, id),
    listSessions: async (cwd, refresh = false) => (await listAgySessions(cwd, refresh).catch(() => []))
      .map(({ id, name, modified }) => ({ agent: 'agy', id, name, modified })),
    invalidateCatalog: () => invalidateAgyCatalog(),
    archivedSessionIds: (ids) => archivedAgySessionIds(ids).catch(() => new Set()),
    archiveBehavior: 'mark',
  },
];

const providerById = new Map(agentProviders.map((provider) => [provider.id, provider]));
const knownAgents = agentProviders.map((provider) => provider.id);

export function getAgentProvider(id) {
  return providerById.get(normalizeAgent(id));
}

export function listAgentProviders(requestedAgent) {
  if (!requestedAgent) return agentProviders;
  const provider = providerById.get(requestedAgent);
  return provider ? [provider] : [];
}

export function invalidateAllAgentCatalogs() {
  for (const provider of agentProviders) provider.invalidateCatalog();
}

let cachedStatus = agentProviders.map(({ id, label }) => ({ id, label }));
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
  const agyBin = process.env.PIGO_AGY_BIN || 'agy';
  const [piVersion, codexVersion, agyVersion] = await Promise.all([
    run(piBin, ['--version'], { timeout: 3000 }).then(({ stdout }) => stdout.trim().split('\n')[0]).catch(() => undefined),
    run(codexBin, ['--version'], { timeout: 3000 }).then(({ stdout }) => stdout.trim().split('\n')[0]).catch(() => undefined),
    run(agyBin, ['--version'], { timeout: 3000 }).then(({ stdout }) => stdout.trim().split('\n')[0]).catch(() => undefined),
  ]);
  const codexAuthed = Boolean(process.env.OPENAI_API_KEY) || existsSync(join(codexHome(), 'auth.json')) || existsSync(join(codexHome(), 'config.toml'));
  cachedStatus = [
    { id: 'pi', label: 'Pi', installed: Boolean(piVersion), version: piVersion, authed: true },
    { id: 'codex', label: 'Codex', installed: Boolean(codexVersion), version: codexVersion, authed: codexAuthed },
    { id: 'agy', label: 'Antigravity', installed: Boolean(agyVersion), version: agyVersion, authed: agyAuthed() },
  ];
  cachedAt = Date.now();
  return cachedStatus;
}
