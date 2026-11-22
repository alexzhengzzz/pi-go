// Pi Go daemon host — a drop-in replacement for the `pi-go-desktop-host/1`
// service that the patched Pi Desktop exposed from its Electron main process.
//
// The broker discovers this server through the shared IPC directory
// (`host-<pid>.sock`, verified via GET /health) exactly as it discovered the
// Desktop host, so broker, extension and phone keep working unmodified.
// Route semantics, status codes and error strings follow the Desktop host
// (desktop/pi-go-host.ts): /open, /new, /catalog, /projects, /authorize,
// /pending, /answer, /create-workspace, /close-workspace.
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { existsSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { lstat, mkdir, realpath, rmdir, stat } from 'node:fs/promises';
import { ipcDirectory } from '../desktop/local-ipc.mjs';
import { listSessions, findSession } from './catalog.mjs';

const sessionIdPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const mutatingRoutes = new Set(['/open', '/new', '/create-workspace', '/close-workspace']);
const routes = new Set(['/open', '/new', '/catalog', '/projects', '/authorize', '/pending', '/answer',
  '/create-workspace', '/close-workspace']);
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

export function createDaemonHost({ registry, runtimes, profile = daemonProfile() }) {
  let busy = false;
  let quitting = false;
  const server = createServer({ requestTimeout: 3000, headersTimeout: 3000 }, (request, response) => {
    handle(request, response).catch(() => {
      if (!response.headersSent) reply(response, 409, { error: 'desktop_handoff_failed' });
      else response.destroy();
    });
  });

  const reply = (response, status, data) => {
    response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify(data));
  };

  async function readInput(request) {
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
      length += chunk.length;
      if (length > bodyLimit) throw new Error('invalid_target');
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  }

  // Register a workspace when Pi Go is entitled to: opening a native history
  // file, an explicit /authorize, or /new — the Desktop host's rule.
  async function ensureRegistered(cwd, registered, wants) {
    if (!wants || registered.length > 0 || !cwd) return registered;
    if (!(await stat(cwd).catch(() => undefined))?.isDirectory()) return registered;
    const workspace = registry.create(basename(cwd), cwd);
    return workspace ? [workspace] : registered;
  }

  async function shareRuntime(runtime) {
    const shared = await runtime.sendCommand('prompt', { message: '/pi-go-share desktop-host' });
    return shared !== undefined;
  }

  // Shared tail of /open and /new: bring a live or freshly spawned runtime to
  // readiness, share it into the extension bridge, and report the session id.
  async function handoff(cwd, expectedId, sessionPath) {
    const existing = expectedId === undefined
      ? undefined
      : runtimes.list().find((runtime) => runtime.cwd === cwd && runtime.sessionId === expectedId);
    const runtime = existing ?? runtimes.start(cwd, sessionPath);
    let state;
    try { state = await runtime.awaitReady(expectedId); }
    catch (error) {
      if (!existing) runtime.kill();
      throw new Error(error.message.startsWith('runtime_not_ready') ? 'desktop_session_not_ready' : 'desktop_busy');
    }
    if (expectedId !== undefined && state.sessionId !== expectedId) {
      if (!existing) runtime.kill();
      throw new Error('desktop_session_not_ready');
    }
    try {
      if (!(await shareRuntime(runtime))) throw new Error('desktop_share_failed');
    } catch {
      if (!existing) runtime.kill();
      throw new Error('desktop_share_failed');
    }
    return state.sessionId;
  }

  async function handle(request, response) {
    if (request.method === 'GET' && request.url === '/health') {
      return reply(response, 200, { protocol: 'pi-go-desktop-host/1', profile, canCreateWorkspace: true });
    }
    if (request.method !== 'POST' || !routes.has(request.url) || request.headers.origin !== undefined) {
      return reply(response, 404, { error: 'not_found' });
    }
    const mutating = mutatingRoutes.has(request.url);
    if (quitting || (mutating && busy)) return reply(response, 409, { error: 'desktop_busy' });
    if (mutating) busy = true;
    try {
      const input = await readInput(request);
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
      if (request.url === '/create-workspace') {
        const rawName = typeof input.name === 'string' ? input.name : '';
        const name = rawName.trim();
        if (!name || name.length > 80 || name === '.' || name === '..' || /[\x00-\x1f\x7f/\\]/.test(rawName)) {
          return reply(response, 400, { error: 'invalid_workspace_name' });
        }
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
        return reply(response, 200, { cwd: await realpath(cwd) });
      }
      if (request.url === '/close-workspace') {
        if (typeof input.cwd !== 'string') return reply(response, 400, { error: 'invalid_target' });
        const cwd = await realpath(input.cwd).catch(() => undefined);
        const registered = await registry.findByRealpath(cwd);
        if (!cwd || registered.length === 0) return reply(response, 404, { error: 'desktop_workspace_not_registered' });
        if (registered.length > 1) return reply(response, 409, { error: 'desktop_workspace_ambiguous' });
        await runtimes.killFor(cwd);
        registry.remove(cwd);
        return reply(response, 200, { closed: true, cwd });
      }
      const opening = request.url === '/open';
      if (typeof input.cwd !== 'string' || (opening && (typeof input.id !== 'string' || !sessionIdPattern.test(input.id)))) {
        return reply(response, 400, { error: 'invalid_target' });
      }
      const cwd = await realpath(input.cwd).catch(() => undefined);
      let registered = await registry.findByRealpath(cwd);
      const session = opening && cwd ? await findSession(cwd, input.id) : undefined;
      const wantsRegistration = Boolean(session) || request.url === '/authorize' || request.url === '/new';
      registered = await ensureRegistered(cwd, registered, wantsRegistration);
      if (!cwd || registered.length === 0 || registered.length > 1) {
        return reply(response, 403, { error: 'desktop_workspace_untrusted' });
      }
      if (opening && !session) return reply(response, 404, { error: 'desktop_session_not_found' });
      if (request.url === '/catalog') {
        const sessions = (await listSessions(cwd)).map(({ id, name, modified }) => ({ id, name, modified }));
        return reply(response, 200, { sessions });
      }
      if (request.url === '/authorize') return reply(response, 200, { cwd, profile });
      const sessionId = await handoff(cwd, opening ? input.id : undefined, session?.path);
      return reply(response, 200, { id: sessionId });
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
    server.close();
    server.closeAllConnections();
  };

  server.maxConnections = 4;
  server.setTimeout(15000, (socket) => socket.destroy());
  server.on('error', () => {});
  return { server, shutdown, path: join(ipcDirectory(), `host-${process.pid}.sock`) };
}
