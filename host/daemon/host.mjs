// Local IPC for Pi Go session handoff, workspace registration, and RPC interactions.
// The daemon publishes host capabilities beside its socket for the broker.
// Keep the existing protocol and error codes for installed brokers and clients.
import { execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { lstat, mkdir, realpath, rmdir, stat } from 'node:fs/promises';
import { promisify } from 'node:util';
import { ipcDirectory, localRequest, pairingRuntimes, workers } from '../bridge/local-ipc.mjs';
import { registerSocket } from '../bridge/socket-registry.mjs';
import { computerSessions, invalidateComputerSessions } from '../bridge/computer-sessions.mjs';
import { currentAgents, invalidateAllAgentCatalogs, listAgentProviders, normalizeAgent } from '../agents/registry.mjs';

const sessionIdPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const timingEnabled = process.env.PIGO_TIMING === '1';
const logTiming = (label, startMs, extra = '') => {
  if (!timingEnabled) return;
  process.stderr.write(`[pigo-timing] daemon.${label}: ${(performance.now() - startMs).toFixed(1)}ms${extra ? ` ${extra}` : ''}\n`);
};
const mutatingRoutes = new Set(['/open', '/new', '/authorize', '/create-workspace', '/close-workspace', '/rename-workspace', '/remove-workspace', '/delete-session', '/schedules/update']);
const routes = new Set(['/open', '/new', '/catalog', '/projects', '/authorize', '/pending', '/answer',
  '/create-workspace', '/close-workspace', '/rename-workspace', '/remove-workspace', '/delete-session', '/workspaces', '/workspace-library', '/session-deleted',
  '/schedules/sync', '/schedules/update']);
const bodyLimit = 8192;

export function daemonProfile() {
  const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi', 'agent');
  return createHash('sha256').update(JSON.stringify(['pi-go-daemon', resolve(agentDir), process.getuid()])).digest('hex');
}

async function ensureSpaceParent(path) {
  try { await mkdir(path, { mode: 0o700 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  if (!(await lstat(path)).isDirectory()) throw new Error('invalid_space_parent');
}

const run = promisify(execFile);

function workspaceName(input) {
  if (typeof input !== 'string' || /[\x00-\x1f\x7f/\\]/.test(input)) return undefined;
  const name = input.trim();
  return name && name.length <= 80 && name !== '.' && name !== '..' ? name : undefined;
}

async function liveSessions() {
  const sockets = [...pairingRuntimes(), ...workers()];
  const results = await Promise.all(sockets.map(async (socket) => {
    const result = await localRequest(socket, 'GET', '/session', undefined, 700).catch(() => undefined);
    const session = result?.data?.session;
    if (result?.status === 200 && typeof session?.id === 'string' && typeof session.cwd === 'string') {
      return { ...session, pid: Number(/^(?:gui|w)-(\d+)-/.exec(basename(socket))?.[1]) };
    }
  }));
  return results.filter(Boolean);
}

async function externalPiRunning(knownPids) {
  const { stdout } = await run('/bin/ps', ['-axww', '-o', 'uid=,pid=,command='], { timeout: 2000 });
  return stdout.split('\n').some((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
    if (!match || Number(match[1]) !== process.getuid() || knownPids.has(Number(match[2]))) return false;
    // Pi without the extension has no IPC socket, and may hold history in memory.
    const command = match[3];
    return /^(?:\S*\/)?pi(?:-rpc)?(?:\s|$)/.test(command) ||
      /^(?:\S*\/)?(?:node|bun)\s/.test(command) &&
      /(?:^|[\s/])pi(?:\s|$)|\/pi-coding-agent\/(?:dist|src)\//.test(command);
  });
}

async function trashSession(path) {
  const script = `ObjC.import("Foundation");
    function run(args) {
      const url = $.NSURL.fileURLWithPath(args[0]);
      if (!$.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError(url, null, Ref())) {
        throw Error("trash_failed");
      }
    }`;
  await run('/usr/bin/osascript', ['-l', 'JavaScript', '-e', script, path], { timeout: 8000 });
}

export function createDaemonHost({ registry, runtimes, schedules, profile = daemonProfile(), trash = trashSession, hasExternalPi = externalPiRunning }) {
  let revision = randomUUID();
  const deletedSessions = new Map();
  let busy = false;
  let quitting = false;
  const server = createServer({ requestTimeout: 3000, headersTimeout: 3000 }, (request, response) => {
    handle(request, response).catch(() => {
      if (!response.headersSent) reply(response, 409, { error: 'desktop_handoff_failed' });
      else response.destroy();
    });
  });

  const health = () => ({
    protocol: 'pi-go-desktop-host/1', profile, canCreateWorkspace: true, workspaceLibrary: true, workspacePages: true,
    schedules: schedules?.closing === false, agents: currentAgents(),
  });
  const registration = registerSocket(server, health);

  const reply = (response, status, data) => {
    response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify(data));
  };

  async function readInput(request) {
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
      length += chunk.length;
      if (length > (request.url === '/schedules/sync' ? 256 * 1024 : bodyLimit)) throw new Error('invalid_target');
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  }

  // Add an existing directory only on explicit authorization.
  async function ensureRegistered(cwd, registered, wants) {
    if (!wants || registered.length > 0 || !cwd) return registered;
    if (!(await stat(cwd).catch(() => undefined))?.isDirectory()) return registered;
    const workspace = registry.create(basename(cwd), cwd);
    if (workspace) revision = randomUUID();
    return workspace ? [workspace] : registered;
  }

  async function shareRuntime(runtime) {
    const shared = await runtime.sendCommand('prompt', { message: '/pi-go-share desktop-host' });
    return shared !== undefined;
  }

  // Shared tail of /open and /new: bring a live or freshly spawned runtime to
  // readiness, share it into the extension bridge, and report the session id.
  async function handoff(cwd, expectedId, sessionPath, agent = 'pi', sessionMeta = undefined) {
    const t0 = performance.now();
    const existing = expectedId === undefined
      ? undefined
      : runtimes.list().find((runtime) => (runtime.agent ?? 'pi') === agent && runtime.cwd === cwd && runtime.sessionId === expectedId);
    const runtime = existing ?? runtimes.start(cwd, agent === 'pi' ? sessionPath : expectedId, false, agent, {
      sessionPath,
      appDataDir: sessionMeta?.appDataDir,
      sessionName: sessionMeta?.name,
    });
    let state;
    const tReady = performance.now();
    try { state = await runtime.awaitReady(expectedId); }
    catch (error) {
      if (!existing) runtime.kill();
      throw new Error(error.message.startsWith('runtime_not_ready') ? 'desktop_session_not_ready' : 'desktop_busy');
    }
    logTiming(`handoff.awaitReady(${agent})`, tReady, existing ? 'reused' : 'spawned');
    if (expectedId !== undefined && state.sessionId !== expectedId) {
      if (!existing) runtime.kill();
      throw new Error('desktop_session_not_ready');
    }
    if (agent === 'pi') {
      const tShare = performance.now();
      try {
        if (!(await shareRuntime(runtime))) throw new Error('desktop_share_failed');
      } catch {
        if (!existing) runtime.kill();
        throw new Error('desktop_share_failed');
      }
      logTiming('handoff.shareRuntime(pi)', tShare);
    }
    logTiming(`handoff.total(${agent})`, t0);
    return { id: state.sessionId, socket: state.socketPath };
  }

  async function handle(request, response) {
    if (request.method === 'GET' && request.url === '/health') {
      return reply(response, 200, health());
    }
    if (request.method !== 'POST' || !routes.has(request.url) || request.headers.origin !== undefined) {
      return reply(response, 404, { error: 'not_found' });
    }
    const mutating = mutatingRoutes.has(request.url);
    if (quitting || (mutating && busy)) return reply(response, 409, { error: 'desktop_busy' });
    if (mutating) busy = true;
    try {
      const input = await readInput(request);
      if (request.url === '/schedules/sync') {
        if (!schedules || schedules.closing) return reply(response, 404, { error: 'schedules_unsupported' });
        const paths = Array.isArray(input.paths) ? input.paths.filter((p) => typeof p === 'string') : [];
        const knownRuns = Array.isArray(input.knownRuns) ? input.knownRuns.filter((id) => typeof id === 'string') : [];
        return reply(response, 200, schedules.snapshot(paths, input.includeJobs === true, knownRuns));
      }
      if (request.url === '/schedules/update') {
        if (!schedules || schedules.closing) return reply(response, 404, { error: 'schedules_unsupported' });
        const [status, data] = schedules.update(input);
        return reply(response, status, data);
      }
      if (request.url === '/pending' || request.url === '/answer') {
        const runtime = runtimes.find(input.pid, input.id);
        if (!runtime) return reply(response, 409, { error: 'session_changed' });
        if (request.url === '/answer') {
          if (typeof input.pendingId !== 'string' || !runtime.respondFromPiGo(input.pendingId, input.answer)) {
            return reply(response, 409, { error: 'interaction_unavailable' });
          }
          return reply(response, 200, { answered: true });
        }
        const interaction = runtime.pendingInteraction();
        return reply(response, 200, interaction ? { interaction } : {});
      }
      if (request.url === '/projects') {
        const projects = await Promise.all(registry.list()
          .map((workspace) => realpath(workspace.path).catch(() => undefined)));
        return reply(response, 200, { projects: [...new Set(projects.filter((path) => path !== undefined))] });
      }
      if (request.url === '/workspaces' || request.url === '/workspace-library') {
        const currentRevision = revision;
        const registered = await Promise.all(registry.list().map(async (workspace) => ({
          ...workspace, cwd: await realpath(workspace.path).catch(() => undefined),
        })));
        if (request.url === '/workspaces') {
          return reply(response, 200, { workspaces: registered, revision: currentRevision });
        }
        const scope = input.scope;
        if (scope !== undefined && !['workspaces', 'workspace'].includes(scope)) {
          return reply(response, 400, { error: 'invalid_scope' });
        }
        if (scope === 'workspaces') {
          return reply(response, 200, { workspaces: registered.map(({ id, name, cwd, path }) =>
            ({ id, name, cwd: cwd ?? path, registered: true, sessions: [] })) });
        }
        const workspace = scope === 'workspace' ? registered.find(({ cwd, path }) => (cwd ?? path) === input.cwd) : undefined;
        if (scope === 'workspace' && !workspace) return reply(response, 404, { error: 'desktop_workspace_not_registered' });
        const [history, live] = await Promise.all([
          workspace && !workspace.cwd ? [] : computerSessions(currentRevision, workspace?.cwd),
          liveSessions(),
        ]);
        const groups = new Map(registered.map(({ id, name, cwd, path }) => {
          const location = cwd ?? path;
          return [location, { id, name, cwd: location, registered: true, sessions: [] }];
        }));
        const locations = new Map();
        const canonicalPath = (cwd) => {
          if (!locations.has(cwd)) locations.set(cwd, realpath(cwd).catch(() => cwd));
          return locations.get(cwd);
        };
        const historyById = new Map();
        for (const row of history) {
          const cwd = await canonicalPath(row.cwd);
          const agent = row.agent ?? 'pi';
          historyById.set(JSON.stringify([cwd, agent, row.id]), { ...row, agent, cwd });
        }
        for (const row of live) {
          const cwd = await canonicalPath(row.cwd);
          const agent = row.agent ?? 'pi';
          const key = JSON.stringify([cwd, agent, row.id]);
          const prior = historyById.get(key);
          historyById.set(key, { ...prior, id: row.id, agent, cwd, name: row.name ?? prior?.name, active: true });
        }
        for (const { id, agent, name, modified, cwd, active } of historyById.values()) {
          if (!groups.has(cwd)) groups.set(cwd, { name: basename(cwd) || cwd, cwd, registered: false, sessions: [] });
          groups.get(cwd).sessions.push({ id, agent, name, modified, active });
        }
        const workspaces = [...groups.values()].sort((a, b) =>
          Number(b.registered) - Number(a.registered) || a.name.localeCompare(b.name));
        for (const group of workspaces) {
          group.sessions.sort((a, b) => Number(b.active) - Number(a.active) ||
            (b.modified ?? '').localeCompare(a.modified ?? '') || a.id.localeCompare(b.id));
        }
        if (workspace) {
          const rows = groups.get(input.cwd).sessions.map((row) => ({ ...row, cwd: input.cwd }));
          const cursor = Number(input.cursor);
          const start = Number.isSafeInteger(cursor) && cursor >= 0 ? cursor : 0;
          return reply(response, 200, { history: rows.slice(start, start + 20),
            nextCursor: start + 20 < rows.length ? start + 20 : undefined });
        }
        return reply(response, 200, { workspaces });
      }
      if (request.url === '/rename-workspace') {
        const name = workspaceName(input.name);
        if (!name) return reply(response, 400, { error: 'invalid_workspace_name' });
        if (!registry.rename(input.id, name)) return reply(response, 404, { error: 'desktop_workspace_not_registered' });
        revision = randomUUID();
        return reply(response, 200, { updated: true });
      }
      if (request.url === '/session-deleted') {
        if (typeof input.cwd !== 'string' || typeof input.id !== 'string') {
          return reply(response, 400, { error: 'invalid_target' });
        }
        const cwd = await realpath(input.cwd).catch(() => undefined);
        const deleted = cwd !== undefined && deletedSessions.get(input.id) === cwd &&
          (await Promise.all(listAgentProviders().map((provider) => provider.findSession(cwd, input.id)))).every((found) => !found);
        return reply(response, 200, { deleted });
      }
      if (request.url === '/delete-session') {
        if (typeof input.cwd !== 'string' || typeof input.id !== 'string' || !sessionIdPattern.test(input.id)) {
          return reply(response, 400, { error: 'invalid_target' });
        }
        const cwd = await realpath(input.cwd).catch(() => undefined);
        const requestedAgent = input.agent !== undefined ? normalizeAgent(input.agent) : undefined;
        if (input.agent !== undefined && !requestedAgent) return reply(response, 400, { error: 'invalid_target' });
        let session;
        if (cwd) {
          for (const provider of listAgentProviders(requestedAgent)) {
            const found = await provider.findSession(cwd, input.id);
            if (found) { session = found; break; }
          }
        }
        if (!session) return reply(response, 404, { error: 'desktop_session_not_found' });
        const before = await lstat(session.path);
        const managed = runtimes.list();
        const live = await liveSessions();
        const knownPids = new Set([...managed, ...live].map(({ pid }) => pid));
        if (managed.some((runtime) => runtime.sessionId === input.id || runtime.sessionPath === session.path ||
          (runtime.cwd === cwd && !runtime.sessionId)) ||
          live.some(({ id }) => id === input.id) || (session.agent === 'pi' && await hasExternalPi(knownPids))) {
          return reply(response, 409, { error: 'session_occupied' });
        }
        const after = await lstat(session.path);
        if (!after.isFile() || before.dev !== after.dev || before.ino !== after.ino ||
          before.mtimeMs !== after.mtimeMs || before.size !== after.size) {
          return reply(response, 409, { error: 'session_changed' });
        }
        try { await trash(session.path); }
        catch { return reply(response, 500, { error: 'desktop_trash_failed' }); }
        deletedSessions.delete(input.id);
        deletedSessions.set(input.id, cwd);
        if (deletedSessions.size > 128) deletedSessions.delete(deletedSessions.keys().next().value);
        invalidateAllAgentCatalogs();
        invalidateComputerSessions();
        revision = randomUUID();
        return reply(response, 200, { deleted: true });
      }
      if (request.url === '/create-workspace') {
        const name = workspaceName(input.name);
        if (!name) return reply(response, 400, { error: 'invalid_workspace_name' });
        const home = await realpath(homedir()).catch(() => undefined);
        if (!home) return reply(response, 500, { error: 'desktop_create_workspace_failed' });
        const container = join(home, 'Pi Go');
        const parent = join(container, 'Spaces');
        const cwd = join(parent, name);
        try {
          await ensureSpaceParent(container);
          await ensureSpaceParent(parent);
          if (registry.list().some((workspace) => resolve(workspace.path) === cwd)) {
            return reply(response, 409, { error: 'workspace_exists' });
          }
          try { await mkdir(cwd, { mode: 0o700 }); }
          catch (error) {
            if (error.code === 'EEXIST') return reply(response, 409, { error: 'workspace_exists' });
            throw error;
          }
          const registeredPath = await realpath(cwd);
          try { registry.create(name, registeredPath); }
          catch (error) {
            if (!registry.list().some((workspace) => resolve(workspace.path) === registeredPath)) {
              await rmdir(cwd).catch(() => undefined);
            }
            throw error;
          }
        } catch {
          return reply(response, 500, { error: 'desktop_create_workspace_failed' });
        }
        revision = randomUUID();
        return reply(response, 200, { cwd: await realpath(cwd) });
      }
      if (request.url === '/close-workspace' || request.url === '/remove-workspace') {
        const byId = request.url === '/remove-workspace';
        const target = byId ? input.id : input.cwd;
        if (typeof target !== 'string') return reply(response, 400, { error: 'invalid_target' });
        const workspace = byId ? registry.list().find(({ id }) => id === target) : undefined;
        const cwd = !byId || workspace ? await realpath(workspace?.path ?? target).catch(() => undefined) : undefined;
        const registered = byId ? (workspace ? [workspace] : []) : await registry.findByRealpath(cwd);
        if (registered.length === 0) return reply(response, 404, { error: 'desktop_workspace_not_registered' });
        if (registered.length > 1) return reply(response, 409, { error: 'desktop_workspace_ambiguous' });
        if (schedules && !schedules.closing) schedules.pauseWorkspace(cwd ?? registered[0].path);
        await runtimes.killFor(cwd ?? registered[0].path);
        registry.remove(registered[0].path);
        revision = randomUUID();
        return reply(response, 200, { closed: true, cwd: cwd ?? registered[0].path });
      }
      const opening = request.url === '/open';
      const requestedAgent = input.agent !== undefined ? normalizeAgent(input.agent) : undefined;
      if (typeof input.cwd !== 'string' || (input.agent !== undefined && !requestedAgent) ||
        (opening && (typeof input.id !== 'string' || !sessionIdPattern.test(input.id)))) {
        return reply(response, 400, { error: 'invalid_target' });
      }
      const cwd = await realpath(input.cwd).catch(() => undefined);
      let registered = await registry.findByRealpath(cwd);
      let session;
      if (opening && cwd) {
        const tFind = performance.now();
        for (const provider of listAgentProviders(requestedAgent)) {
          const found = await provider.findSession(cwd, input.id);
          if (found) { session = found; break; }
        }
        logTiming('open.findSession', tFind, `agent=${session?.agent ?? 'none'}`);
      }
      registered = await ensureRegistered(cwd, registered, request.url === '/authorize');
      const transient = Boolean(session) || request.url === '/new';
      if (!cwd || (registered.length === 0 && !transient) || registered.length > 1) {
        return reply(response, 403, { error: 'desktop_workspace_untrusted' });
      }
      if (opening && !session) return reply(response, 404, { error: 'desktop_session_not_found' });
      if (request.url === '/catalog') {
        const refresh = input.refresh === true;
        if (input.scoped === true) {
          const sessions = (await computerSessions(revision, cwd, refresh))
            .map(({ id, agent, name, modified }) => ({ id, agent, name, modified }));
          return reply(response, 200, { sessions });
        }
        const lists = await Promise.all(listAgentProviders().map((provider) => provider.listSessions(cwd, refresh)));
        const sessions = lists.flat().sort((a, b) => (b.modified ?? '').localeCompare(a.modified ?? ''));
        return reply(response, 200, { sessions });
      }
      if (request.url === '/authorize') return reply(response, 200, { cwd, profile });
      const targetAgent = opening ? (session.agent ?? 'pi') : (requestedAgent ?? 'pi');
      const { id: sessionId, socket } = await handoff(cwd, opening ? input.id : undefined, session?.path, targetAgent, session);
      return reply(response, 200, { id: sessionId, agent: targetAgent, ...(socket ? { socket } : {}) });
    } catch (error) {
      const known = ['desktop_busy', 'desktop_session_not_ready', 'desktop_share_failed'];
      const code = known.includes(String(error?.message)) ? error.message : 'desktop_handoff_failed';
      return reply(response, 409, { error: code });
    } finally {
      if (mutating) busy = false;
    }
  }

  const shutdown = () => {
    quitting = true;
    registration.withdraw();
    server.close();
    server.closeAllConnections();
  };

  server.maxConnections = 4;
  server.setTimeout(15000, (socket) => socket.destroy());
  server.on('error', () => {});
  return { server, shutdown, path: join(ipcDirectory(), `host-${process.pid}.sock`) };
}
