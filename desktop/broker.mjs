import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { lstatSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { createServer, request as ipcRequest } from 'node:http';
import { createServer as createSecureServer } from 'node:https';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { desktopHosts, ipcDirectory, localRequest, localUpload, workers, pairingRuntimes } from './local-ipc.mjs';
import { newLanIdentity, newPublicIdentity, privateIPv4, publicAddress } from './lan-tls.mjs';
import { startDiscovery } from './lan-discovery.mjs';
import { listFiles, previewFile, saveFile, openWorkspaceDownload, findWorkspaceFileByName } from './workspace-files.mjs';
import { SessionMetadata, stateDirectory } from './session-metadata.mjs';
import { computerSessions } from './computer-sessions.mjs';
import { maxFileBytes, maxImageBytes, maxPromptBody, safeAttachmentName } from './attachments.mjs';

const remote = process.argv[3] === '--remote';
const lan = !remote && Boolean(process.argv[3]);
const transport = remote ? 'remote' : lan ? 'lan' : 'usb';
const host = lan ? process.argv[3] : '127.0.0.1';
const port = Number(process.argv[2] ?? '18977');
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('invalid_port');
const address = remote ? publicAddress(process.argv[4], Number(process.argv[5])) : `${host}:${port}`;
const ticketRoute = remote ? '/ticket-remote' : lan ? '/ticket-lan' : '/ticket';
const metadata = new SessionMetadata(remote ? 18981 : port);
const pairingFile = join(stateDirectory(), `pairing-${transport}-${port}.json`);
const pairingProfile = resolve(process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi', 'agent'));
const saved = loadPairing();
const tls = remote ? newPublicIdentity(process.argv[4], saved?.identity) : lan ? newLanIdentity(host, saved?.identity) : undefined;
const sameIdentity = !tls || tls.cert === saved?.identity?.cert;
const adminPath = join(ipcDirectory(), `bridge-${port}.sock`);
const digest = (text) => createHash('sha256').update(text).digest();
const matches = (text, expected) => typeof text === 'string' && expected !== undefined && timingSafeEqual(digest(text), expected);
const reply = (response, status, value) => {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
};
const error = (response, status, code) => reply(response, status, { error: code });
const options = { requestTimeout: 5000, headersTimeout: 5000, connectionsCheckingInterval: 1000 };
// Phone uploads can carry one 8 MiB file, so the public listener gets a longer
// request budget; header/keepalive limits and maxConnections still apply.
const publicOptions = { ...options, requestTimeout: 60000, ...(remote ? { maxHeaderSize: 8192, keepAliveTimeout: 2500 } : {}) };
let bearer = sameIdentity && saved?.bearer ? Buffer.from(saved.bearer, 'hex') : undefined;
let lastSeen;
let computerAccess = remote || (saved?.computerAccess ?? false);
let pairing;
let selected;
let chosen = false;
let ticketTimer;
let closing = false;
let handoffPending = false;
let stopDiscovery;
let selectionVersion = 0;
const grants = new Map();
const streams = new Set();
let remoteRequests = 0;
let remoteBudget = 40;
let remoteBudgetAt = performance.now();

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function acceptRemoteRequest(response) {
  const now = performance.now();
  remoteBudget = Math.min(40, remoteBudget + (now - remoteBudgetAt) * 0.012);
  remoteBudgetAt = now;
  if (remoteBudget < 1 || remoteRequests >= 10) {
    response.setHeader('Retry-After', '1');
    error(response, 429, 'too_many_requests');
    return false;
  }
  remoteBudget -= 1;
  remoteRequests += 1;
  response.once('close', () => { remoteRequests -= 1; });
  return true;
}

function workerPath(path, session) {
  if (!remote) return path;
  const url = new URL(path, 'http://pi-go');
  url.searchParams.set('_pigoSession', session.id);
  url.searchParams.set('_pigoCwd', session.cwd);
  return url.pathname + url.search;
}

function loadPairing() {
  let info;
  try { info = lstatSync(pairingFile); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (!info.isFile() || info.uid !== process.getuid() || (info.mode & 0o077) || info.size > 8192) {
    throw new Error('unsafe_pairing_state');
  }
  const value = JSON.parse(readFileSync(pairingFile, 'utf8'));
  if (value?.version !== 1 || typeof value.computerAccess !== 'boolean' || typeof value.profile !== 'string' ||
    (value.bearer !== undefined && (typeof value.bearer !== 'string' || !/^[a-f0-9]{64}$/.test(value.bearer))) ||
    ((lan || remote) && (typeof value.identity?.cert !== 'string' || typeof value.identity?.key !== 'string'))) {
    throw new Error('invalid_pairing_state');
  }
  if (value.host === host && value.profile === pairingProfile && (!remote || value.address === address)) return value;
}

function savePairing(nextBearer) {
  const identity = tls && { cert: tls.cert, key: tls.key };
  const state = { version: 1, host, profile: pairingProfile, computerAccess, bearer: nextBearer?.toString('hex'), identity };
  if (remote) Object.assign(state, { address });
  const temporary = pairingFile + '.' + randomBytes(8).toString('hex');
  try {
    writeFileSync(temporary, JSON.stringify(state), { mode: 0o600, flag: 'wx' });
    renameSync(temporary, pairingFile);
  } finally { try { unlinkSync(temporary); } catch {} }
}

async function pumpEvents(client, authorization) {
  try {
    while (!client.closed && matches(authorization, bearer)) {
      const live = await workerList();
      if (client.closed || !matches(authorization, bearer)) break;
      const current = selectionFor(live);
      if (!current) {
        client.session = undefined;
        if (!client.response.write(`data: ${JSON.stringify({ type: 'bridge/status', state: selected ? 'session_closed' : 'no_session_selected' })}\n\n`)) client.response.destroy();
        await pause(400);
        continue;
      }
      client.session = current.session.id;
      const version = selectionVersion;
      let finish;
      const done = new Promise((resolve) => { finish = resolve; });
      const tick = setInterval(() => {
        if (client.closed || !matches(authorization, bearer) || version !== selectionVersion) client.upstream?.destroy();
        else if (!client.response.write(': keepalive\n\n')) client.response.destroy();
      }, 4000);
      const path = workerPath('/events', current.session);
      const upstream = ipcRequest({ socketPath: current.socket, path, method: 'GET', agent: false }, (res) => {
        if (res.statusCode !== 200) { res.resume(); finish(); return; }
        res.setEncoding('utf8');
        res.on('data', (chunk) => { if (!client.response.write(chunk)) client.response.destroy(); });
        res.on('end', finish);
        res.on('error', finish);
      });
      upstream.on('error', finish);
      upstream.end();
      client.upstream = upstream;
      await done;
      clearInterval(tick);
      client.upstream = undefined;
      upstream.destroy();
      if (!client.closed) await pause(300);
    }
  } catch {} finally {
    try { client.response.end(); } catch {}
  }
}

function clearTicket() {
  const directory = pairing?.directory;
  pairing = undefined;
  clearTimeout(ticketTimer);
  if (directory) {
    try { rmSync(directory, { recursive: true, force: true }); } catch { /* The ticket is already invalid. */ }
  }
}

function issueTicket() {
  clearTicket();
  const directory = mkdtempSync(join(tmpdir(), 'pigo-bridge-'));
  const ticket = randomBytes(32).toString('hex');
  const code = tls ? undefined : String(randomInt(100_000_000)).padStart(8, '0');
  const file = join(directory, 'pair.json');
  pairing = { directory, ticket: digest(ticket), code: code && digest(code), attempts: 0, expiresAt: Date.now() + 120000 };
  const url = `${tls ? 'https' : 'http'}://${address}`;
  const config = tls ? { bundle: Buffer.from(JSON.stringify({ url, ticket, ca: tls.cert, pin: tls.pin,
    ...(remote ? { transport } : {}) })).toString('base64url') } : { url, ticket, code };
  writeFileSync(file, JSON.stringify(config), { mode: 0o600, flag: 'wx' });
  ticketTimer = setTimeout(clearTicket, 120000).unref();
  return file;
}

async function body(request, limit = 16384) {
  if (request.headers['content-type'] !== 'application/json') throw new Error('invalid_content_type');
  if (Number(request.headers['content-length']) > limit) throw new Error('oversized_body');
  const chunks = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new Error('oversized_body');
    chunks.push(chunk);
  }
  const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_body');
  return value;
}

async function rawBody(request, limit) {
  if (request.headers['content-type'] !== 'application/octet-stream') throw new Error('invalid_content_type');
  if (Number(request.headers['content-length']) > limit) throw new Error('oversized_body');
  const chunks = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new Error('oversized_body');
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks);
  if (bytes.length < 1 || bytes.length > limit) throw new Error('oversized_body');
  return bytes;
}

async function workerList() {
  if (computerAccess && bearer) await Promise.all(pairingRuntimes().map(async (socket) => {
    try {
      const { status, data } = await localRequest(socket, 'GET', '/session', undefined, 700);
      if (status === 200 && data.session?.id && !data.session.shared) {
        await localRequest(socket, 'POST', '/share', { id: data.session.id }, 1000);
      }
    } catch {}
  }));
  const states = await Promise.all(workers().map(async (socket) => {
    try {
      const { status, data } = await localRequest(socket, 'GET', '/session');
      if (status === 200 && typeof data.session?.id === 'string' && typeof data.session?.cwd === 'string') {
        return { socket, session: data.session };
      }
    } catch (cause) {
      if (cause.code === 'ECONNREFUSED') {
        try { unlinkSync(socket); } catch {}
      }
    }
    return undefined;
  }));
  return states.filter(Boolean);
}

function select(worker) {
  metadata.visit(worker.session);
  chosen = true;
  selected = { socket: worker.socket, id: worker.session.id, cwd: worker.session.cwd };
  selectionVersion += 1;
  for (const client of streams) if (client.session !== selected.id) client.upstream?.destroy();
}

function selectionFor(live) {
  if (!chosen && live.length === 1) select(live[0]);
  return selected && live.find(({ socket, session }) => socket === selected.socket && session.id === selected.id && session.cwd === selected.cwd);
}

async function catalog(live, hostSocket, granted = []) {
  const counts = new Map();
  for (const { session } of live) counts.set(session.id, (counts.get(session.id) ?? 0) + 1);
  const rows = new Map(live.map(({ session }) => [session.id, {
    ...session, active: true, occupied: counts.get(session.id) > 1,
  }]));
  const projects = new Map(live.map((worker) => [worker.session.cwd, worker]));
  await Promise.all([...projects].map(async ([cwd, { socket, session }]) => {
    let cursor = 0;
    for (let page = 0; page < 3; page += 1) {
      const path = workerPath(`/sessions?limit=100&cursor=${cursor}`, session);
      const result = await localRequest(socket, 'GET', path).catch(() => undefined);
      if (result?.status !== 200 || result.data.current?.cwd !== cwd || !Array.isArray(result.data.sessions)) return;
      for (const record of result.data.sessions) {
        const prior = rows.get(record.id);
        if (!prior) rows.set(record.id, { ...record, cwd, active: false });
        else if (prior.cwd === cwd && prior.active) rows.set(record.id, { ...record, ...prior, name: prior.name || record.name });
      }
      const next = result.data.nextCursor;
      if (!Number.isInteger(next) || next <= cursor) break;
      cursor = next;
    }
  }));
  // In computer-wide mode the native store supplies history without asking
  // Desktop to register or trust a workspace during a read-only listing.
  if (hostSocket && !computerAccess) await Promise.all(granted.filter((cwd) => !projects.has(cwd)).map(async (cwd) => {
    const result = await localRequest(hostSocket, 'POST', '/catalog', { cwd }).catch(() => undefined);
    if (!grants.has(cwd) || result?.status !== 200 || !Array.isArray(result.data.sessions)) return;
    for (const record of result.data.sessions) {
      if (!rows.has(record.id)) rows.set(record.id, { ...record, cwd, active: false });
    }
  }));
  if (computerAccess) {
    for (const record of await computerSessions()) {
      if (!rows.has(record.id)) rows.set(record.id, record);
    }
  }
  return [...rows.values()].sort((left, right) => Number(right.active) - Number(left.active) || (right.modified ?? '').localeCompare(left.modified ?? '')).slice(0, computerAccess ? undefined : 250);
}

async function hostContext() {
  const hosts = await desktopHosts();
  if (hosts.length !== 1) return { ambiguous: hosts.length > 1, granted: [] };
  const socket = hosts[0];
  const result = await localRequest(socket, 'GET', '/health', undefined, 700).catch(() => undefined);
  const profile = result?.data.profile;
  let granted = [...grants].filter(([, owner]) => owner === profile).map(([cwd]) => cwd);
  if (computerAccess) {
    const projects = await localRequest(socket, 'POST', '/projects', {}).catch(() => undefined);
    if (projects?.status === 200 && Array.isArray(projects.data.projects)) granted = [...new Set([...granted, ...projects.data.projects])];
  }
  return { socket, profile, granted };
}

async function nativeHandoff(request, response, route, cwd, id, context, hasLiveProject) {
  if (handoffPending) return error(response, 409, 'desktop_busy');
  handoffPending = true;
  try {
    if (context.ambiguous) return error(response, 409, 'desktop_host_ambiguous');
    if (!context.socket) return error(response, 409, 'desktop_handoff_required');
    if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
    if (!computerAccess && !hasLiveProject && grants.get(cwd) !== context.profile) {
      return error(response, 403, 'desktop_workspace_unshared');
    }
    const result = await localRequest(context.socket, 'POST', route, { cwd, id }, 12000).catch(() => undefined);
    if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
    if (!result) return error(response, 409, 'desktop_handoff_unconfirmed');
    if (result.status !== 200) return error(response, result.status, result.data.error ?? 'desktop_handoff_failed');
    if (typeof result.data.id !== 'string' || (id !== undefined && result.data.id !== id)) return error(response, 409, 'session_changed');
    const expected = realpathSync(cwd);
    const available = (await workerList()).filter(({ session }) => {
      try { return session.id === result.data.id && realpathSync(session.cwd) === expected; }
      catch { return false; }
    });
    if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
    if (available.length !== 1) return error(response, 409, available.length ? 'session_occupied' : 'desktop_share_failed');
    select(available[0]);
    return reply(response, 200, { session: available[0].session });
  } finally { handoffPending = false; }
}

const publicHandler = async (request, response) => {
  try {
    const authenticated = matches(request.headers.authorization, bearer);
    if (remote && !authenticated) response.setHeader('Connection', 'close');
    if (request.headers.host !== address || request.headers.origin !== undefined ||
      (lan && !privateIPv4(request.socket.remoteAddress))) return error(response, 403, 'invalid_source');
    const path = (request.url ?? '').split('?')[0];
    const route = `${request.method} ${path}`;
    if (!remote && route === 'GET /health') return reply(response, 200, { protocol: 'pi-go-bridge/1' });
    if (route === 'POST /pair') {
      if (remote && (!pairing || pairing.expiresAt <= Date.now())) return error(response, 401, 'invalid_ticket');
      const input = await body(request, remote ? 1024 : undefined);
      if (remote && pairing?.expiresAt <= Date.now()) clearTicket();
      if (!matches(input.ticket, pairing?.ticket) && !matches(input.ticket, pairing?.code)) {
        if (!remote && pairing && ++pairing.attempts >= 5) clearTicket();
        return error(response, 401, 'invalid_ticket');
      }
      const token = randomBytes(32).toString('hex');
      const nextBearer = digest(`Bearer ${token}`);
      try { savePairing(nextBearer); }
      catch { return error(response, 500, 'pairing_state_unavailable'); }
      clearTicket();
      bearer = nextBearer;
      lastSeen = Date.now();
      selected = undefined;
      chosen = false;
      selectionVersion += 1;
      for (const client of streams) remote ? client.response.destroy() : client.upstream?.destroy();
      return reply(response, 200, { token });
    }
    if (!authenticated) return error(response, 401, 'unpaired');
    if (remote && !acceptRemoteRequest(response)) return;
    lastSeen = Date.now();
    if (route === 'GET /health') return reply(response, 200, { protocol: 'pi-go-bridge/1' });
    if (!['GET /session', 'GET /chat', 'GET /history', 'GET /tool-detail', 'GET /sessions', 'GET /sessions/status', 'GET /models', 'GET /events', 'GET /files/download', 'POST /open', 'POST /new', 'POST /prompt', 'POST /upload', 'POST /abort', 'POST /answer', 'POST /receipt', 'POST /model', 'POST /rename', 'POST /session-meta', 'POST /close-workspace', 'POST /files/list', 'POST /files/read', 'POST /files/save'].includes(route)) return error(response, 404, 'not_found');
    if (route === 'GET /events') {
      if (streams.size >= 4) return error(response, 429, 'too_many_streams');
      request.socket.setTimeout(0);
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', 'Connection': 'keep-alive' });
      const client = { response, closed: false, session: undefined, upstream: undefined };
      streams.add(client);
      response.on('close', () => { client.closed = true; streams.delete(client); client.upstream?.destroy(); });
      void pumpEvents(client, request.headers.authorization);
      return;
    }
    if (route === 'GET /files/download') {
      // The phone pulls files the agent produced ("send me this file"), so the
      // response is raw bytes instead of the JSON every other route replies with.
      const parameters = new URL(request.url ?? '/', 'http://pi-go').searchParams;
      const cwd = parameters.get('cwd') ?? '';
      const path = parameters.get('path') ?? '';
      const live = await workerList();
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      const context = await hostContext();
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      if (typeof cwd !== 'string' || (!live.some(({ session }) => session.cwd === cwd) && !context.granted.includes(cwd))) return error(response, 403, 'desktop_workspace_unshared');
      try {
        let file;
        try { file = openWorkspaceDownload(cwd, path); }
        catch (cause) {
          if (cause.code !== 'ENOENT' || path.includes('/') || parameters.get('lookup') !== 'name') throw cause;
          const match = await findWorkspaceFileByName(cwd, path);
          if (response.destroyed) return;
          if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
          file = openWorkspaceDownload(cwd, match);
        }
        const { size, stream } = file;
        response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Cache-Control': 'no-store', 'Content-Length': size });
        if (!stream) return response.end();
        await pipeline(stream, response);
        return;
      } catch (cause) {
        if (response.headersSent || response.destroyed) return response.destroy();
        const code = cause.code === 'ENOENT' ? 'file_not_found' : cause.code === 'EACCES' || cause.code === 'EPERM' || cause.code === 'ELOOP' ? 'path_forbidden' : cause.message;
        const status = { invalid_path: 400, path_forbidden: 403, file_not_found: 404, file_too_large: 413, not_file: 400,
          ambiguous_file_name: 409, file_lookup_limit: 422 }[code];
        if (status) return error(response, status, code);
        throw cause;
      }
    }
    if (route === 'POST /upload') {
      if (request.headers['content-type'] !== 'application/octet-stream') return error(response, 400, 'invalid_content_type');
      const parameters = new URL(request.url ?? '/', 'http://pi-go').searchParams;
      const kind = parameters.get('kind');
      const name = safeAttachmentName(parameters.get('name') ?? '');
      if ((kind !== 'image' && kind !== 'file') || !name) return error(response, 400, 'invalid_attachment');
      const live = await workerList();
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      const current = selectionFor(live);
      if (!current) return error(response, 409, 'session_unavailable');
      if (live.filter(({ session }) => session.id === current.session.id).length !== 1) return error(response, 409, 'session_occupied');
      const bytes = await rawBody(request, kind === 'image' ? maxImageBytes : maxFileBytes);
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      const result = await localUpload(current.socket, workerPath(request.url ?? '/upload', current.session), bytes).catch(() => undefined);
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      if (!result) return error(response, 409, 'session_unavailable');
      return reply(response, result.status, result.data);
    }
    const input = request.method === 'POST' ? await body(request, route === 'POST /prompt' ? maxPromptBody :
      route === 'POST /files/save' ? 512 * 1024 : undefined) : undefined;
    const live = await workerList();
    if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
    const current = selectionFor(live);
    if (path.startsWith('/files/')) {
      const context = await hostContext();
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      if (typeof input.cwd !== 'string' || (!live.some(({ session }) => session.cwd === input.cwd) && !context.granted.includes(input.cwd))) return error(response, 403, 'desktop_workspace_unshared');
      try {
        const result = path === '/files/list' ? listFiles(input.cwd, input.path, input.cursor) :
          path === '/files/read' ? previewFile(input.cwd, input.path) : saveFile(input.cwd, input.path, input.text, input.version);
        return reply(response, 200, result);
      } catch (cause) {
        const code = cause.code === 'ENOENT' ? 'file_not_found' : cause.code === 'EACCES' || cause.code === 'EPERM' || cause.code === 'ELOOP' ? 'path_forbidden' : cause.message;
        const status = { invalid_path: 400, invalid_file: 400, path_forbidden: 403, file_not_found: 404,
          file_conflict: 409, file_too_large: 413, not_text_file: 415, not_directory: 400 }[code];
        if (status) return error(response, status, code);
        throw cause;
      }
    }
    if (route === 'POST /session-meta') {
      if (typeof input.id !== 'string' || typeof input.cwd !== 'string' || !Number.isSafeInteger(input.revision) || input.revision < 0 ||
        (input.pinned !== undefined && typeof input.pinned !== 'boolean') ||
        (input.archived !== undefined && typeof input.archived !== 'boolean') ||
        (input.pinned === undefined && input.archived === undefined)) return error(response, 400, 'invalid_metadata');
      const context = await hostContext();
      const row = (await catalog(live, context.socket, context.granted)).find((row) => row.id === input.id && row.cwd === input.cwd);
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      if (!row) return error(response, 404, 'session_not_found');
      const patch = {};
      if (input.pinned !== undefined) patch.pinned = input.pinned;
      if (input.archived !== undefined) patch.archived = input.archived;
      try { return reply(response, 200, { metadata: metadata.update(row, patch, input.revision) }); }
      catch (cause) { if (cause.message === 'metadata_conflict') return error(response, 409, 'metadata_conflict'); throw cause; }
    }
    if (route === 'GET /sessions/status') {
      const running = [];
      const seen = new Set();
      for (const { session, socket } of live) {
        if ((session.idle === false || session.queued === true) && !seen.has(session.id)) {
          seen.add(session.id);
          running.push({ id: session.id, name: session.name, cwd: session.cwd,
            state: session.idle === false ? 'streaming' : 'queued',
            pid: Number(/(?:^|\/)w-(\d+)-/.exec(socket)?.[1]) });
        }
      }
      const hosts = await desktopHosts();
      if (hosts.length === 1 && running.length) {
        await Promise.all(running.map(async (row) => {
          const pending = await localRequest(hosts[0], 'POST', '/pending', { id: row.id, pid: row.pid }, 700).catch(() => undefined);
          if (pending?.status === 200 && pending.data.interaction) row.state = 'waiting';
        }));
      }
      for (const row of running) delete row.pid;
      return reply(response, 200, { runningSessionIds: [...seen], runningSessions: running });
    }
    if (route === 'GET /sessions') {
      const parameters = new URL(request.url ?? '/', 'http://pi-go').searchParams;
      const query = (parameters.get('query') ?? '').trim().toLowerCase().slice(0, 100);
      const cursor = Number(parameters.get('cursor') ?? '0');
      const limit = Math.min(Math.max(Math.floor(Number(parameters.get('limit') ?? '50') || 50), 1), 100);
      const context = await hostContext();
      const merged = await catalog(live, context.socket, context.granted);
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      const view = parameters.get('view') ?? 'all';
      if (!['all', 'archived', 'pinned', 'recent'].includes(view)) return error(response, 400, 'invalid_view');
      const decorated = merged.map((row) => ({ ...row, ...metadata.get(row) }));
      const visible = decorated.filter((row) => view === 'archived' ? row.archived :
        !row.archived && (view === 'pinned' ? row.pinned : view === 'recent' ? !!row.lastVisited : true));
      visible.sort((left, right) => view === 'recent' ? (right.lastVisited ?? '').localeCompare(left.lastVisited ?? '') :
        Number(right.pinned) - Number(left.pinned));
      const filtered = query ? visible.filter((row) =>
        `${row.name ?? ''} ${row.id} ${row.cwd ?? ''}`.toLowerCase().includes(query)) : visible;
      const start = Number.isInteger(cursor) && cursor >= 0 ? Math.min(cursor, filtered.length) : 0;
      return reply(response, 200, { current: current?.session, sessions: filtered.slice(start, start + limit),
        total: filtered.length, nextCursor: start + limit < filtered.length ? start + limit : undefined,
        desktopHandoff: Boolean(context.socket),
        projects: [...new Set([...live.map(({ session }) => session.cwd), ...context.granted])].sort() });
    }
    if (route === 'POST /open') {
      if (handoffPending) return error(response, 409, 'desktop_busy');
      if (typeof input.id !== 'string') return error(response, 400, 'invalid_session');
      const targets = live.filter(({ session }) => session.id === input.id);
      if (targets.length === 0) {
        const context = await hostContext();
        const row = (await catalog(live, context.socket, context.granted)).find(({ id }) => id === input.id);
        if (!row) return error(response, 409, 'desktop_handoff_required');
        return await nativeHandoff(request, response, '/open', row.cwd, row.id, context, live.some(({ session }) => session.cwd === row.cwd));
      }
      if (targets.length !== 1) return error(response, 409, 'session_occupied');
      select(targets[0]);
      return reply(response, 200, { session: targets[0].session });
    }
    if (route === 'POST /new') {
      const context = await hostContext();
      if (typeof input.cwd !== 'string' || (!live.some(({ session }) => session.cwd === input.cwd) && !context.granted.includes(input.cwd))) return error(response, 403, 'desktop_workspace_unshared');
      return await nativeHandoff(request, response, '/new', input.cwd, undefined, context, live.some(({ session }) => session.cwd === input.cwd));
    }
    if (route === 'POST /close-workspace') {
      // Closing mirrors Desktop's own "remove workspace": the folder leaves the
      // Desktop sidebar (files stay), so the next refresh no longer lists it.
      if (typeof input.cwd !== 'string') return error(response, 400, 'invalid_target');
      const context = await hostContext();
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      if (!context.socket) return error(response, 409, 'desktop_handoff_required');
      if (!live.some(({ session }) => session.cwd === input.cwd) && !context.granted.includes(input.cwd)) {
        return error(response, 403, 'desktop_workspace_unshared');
      }
      const result = await localRequest(context.socket, 'POST', '/close-workspace', { cwd: input.cwd }, 12000).catch(() => undefined);
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      if (!result) return error(response, 409, 'desktop_handoff_unconfirmed');
      if (result.status !== 200) return error(response, result.status, result.data?.error ?? 'desktop_close_failed');
      try { grants.delete(realpathSync(input.cwd)); } catch {}
      if (selected) {
        let hosted = selected.cwd === input.cwd;
        if (!hosted) {
          try { hosted = realpathSync(selected.cwd) === realpathSync(input.cwd); } catch {}
        }
        if (hosted) { selected = undefined; chosen = false; selectionVersion += 1; }
      }
      return reply(response, 200, { closed: true });
    }
    if (!current) {
      if (route === 'GET /chat' || route === 'GET /session') return reply(response, 200, { messages: [], state: selected ? 'session_closed' : live.length ? 'no_session_selected' : 'no_shared_sessions' });
      return error(response, 409, 'session_unavailable');
    }
    if (route === 'GET /session') return reply(response, 200, { session: current.session });
    if (input && (input.id !== current.session.id || live.filter(({ session }) => session.id === input.id).length !== 1)) return error(response, 409, 'session_changed');
    const identity = { id: current.session.id, pid: Number(/(?:^|\/)w-(\d+)-/.exec(current.socket)?.[1]) };
    if (route === 'POST /answer') {
      const hosts = await desktopHosts();
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      if (hosts.length !== 1) return error(response, 409, 'interaction_unavailable');
      const answer = await localRequest(hosts[0], 'POST', '/answer', { ...identity, pendingId: input.pendingId, answer: input.answer }).catch(() => undefined);
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
      return reply(response, answer?.status ?? 409, answer?.data ?? { error: 'interaction_unavailable' });
    }
    const result = await localRequest(current.socket, request.method, workerPath(request.url, current.session), input).catch(() => undefined);
    if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
    if (!result) return error(response, 409, 'session_unavailable');
    if ((route === 'GET /chat' || (remote && route === 'GET /models')) && result.status === 200 &&
        (result.data.session?.id !== current.session.id || (remote && result.data.session?.cwd !== current.session.cwd))) {
      return error(response, 409, 'session_changed');
    }
    if (route === 'GET /chat' && result.status === 200) {
      const hosts = await desktopHosts();
      if (hosts.length === 1) {
        const pending = await localRequest(hosts[0], 'POST', '/pending', identity, 700).catch(() => undefined);
        if (pending?.status === 200) result.data.interaction = pending.data.interaction;
      }
      if (!matches(request.headers.authorization, bearer)) return error(response, 401, 'unpaired');
    }
    return reply(response, result.status, result.data);
  } catch (cause) {
    if (!response.headersSent) {
      if (cause.message === 'oversized_body') {
        response.setHeader('Connection', 'close');
        request.resume();
        return error(response, 413, 'payload_too_large');
      }
      error(response, 400, 'request_failed');
    } else response.destroy();
  }
};
const publicServer = tls ? createSecureServer({ ...publicOptions, minVersion: 'TLSv1.2', key: tls.key, cert: tls.cert,
  handshakeTimeout: 5000 }, publicHandler) : createServer(publicOptions, publicHandler);
publicServer.maxConnections = 16;
publicServer.setTimeout(18000, (socket) => socket.destroy());

const admin = createServer(options, async (request, response) => {
  if (request.headers.origin !== undefined) return error(response, 403, 'invalid_source');
  if (request.method === 'GET' && request.url === '/status') return reply(response, 200, {
    protocol: 'pi-go-pairing/1', computerAccess, transport, host, port,
    ...(remote ? { address } : {}),
    paired: Boolean(bearer), lastSeen: bearer ? lastSeen : undefined, expiresAt: pairing?.expiresAt,
  });
  if (request.method !== 'POST') return error(response, 404, 'not_found');
  try {
    if (request.url === '/computer-access' && !remote) { computerAccess = true; return reply(response, 200, { enabled: true }); }
    if (['/ticket', '/ticket-lan', '/ticket-remote'].includes(request.url)) {
      if (request.url !== ticketRoute) return error(response, 409, 'wrong_transport');
      if (lan) {
        const input = await body(request);
        if (input.host !== host) return error(response, 409, 'wrong_address');
      }
      return reply(response, 200, { file: issueTicket() });
    }
    if (request.url === '/revoke-device') {
      savePairing(undefined);
      clearTicket();
      bearer = undefined;
      selected = undefined;
      chosen = false;
      selectionVersion += 1;
      for (const client of streams) remote ? client.response.destroy() : client.upstream?.destroy();
      return reply(response, 200, { revoked: true });
    }
    if (!remote && (request.url === '/grant' || request.url === '/revoke-project')) {
      const input = await body(request);
      if (typeof input.cwd !== 'string') return error(response, 400, 'invalid_target');
      const cwd = realpathSync(input.cwd);
      if (request.url === '/revoke-project') {
        grants.delete(cwd);
        return reply(response, 200, { revoked: true });
      }
      const context = await hostContext();
      if (!context.socket || !/^[a-f0-9]{64}$/.test(context.profile ?? '')) return error(response, 409, 'desktop_handoff_required');
      const result = await localRequest(context.socket, 'POST', '/authorize', { cwd });
      if (result.status !== 200 || result.data.cwd !== cwd || result.data.profile !== context.profile) return error(response, 403, 'desktop_workspace_untrusted');
      if (grants.size >= 8 && !grants.has(cwd)) return error(response, 409, 'too_many_projects');
      grants.set(cwd, context.profile);
      return reply(response, 200, { granted: true });
    }
    if (request.url === '/stop') {
      response.once('finish', stop);
      reply(response, 200, { stopped: true });
      return;
    }
    return error(response, 404, 'not_found');
  } catch { return error(response, 500, 'admin_failure'); }
});

function stop() {
  if (closing) return;
  closing = true;
  clearTicket();
  bearer = undefined;
  stopDiscovery?.();
  for (const client of streams) { client.closed = true; client.upstream?.destroy(); try { client.response.destroy(); } catch {} }
  streams.clear();
  publicServer.close();
  publicServer.closeAllConnections();
  admin.close();
  admin.closeAllConnections();
}

function listen(server, ...args) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(...args, () => { server.off('error', reject); resolve(); });
  });
}

process.once('SIGINT', stop);
process.once('SIGTERM', stop);
await listen(publicServer, port, host);
try {
  try {
    const previous = lstatSync(adminPath);
    if (!previous.isSocket() || previous.uid !== process.getuid()) throw new Error('unsafe_admin_socket');
    try {
      await localRequest(adminPath, 'GET', '/health', undefined, 700);
      throw new Error('bridge_port_already_managed');
    } catch (cause) {
      if (cause.code !== 'ECONNREFUSED') throw cause;
    }
    const current = lstatSync(adminPath);
    if (current.dev !== previous.dev || current.ino !== previous.ino) throw new Error('admin_socket_changed');
    unlinkSync(adminPath);
  } catch (cause) { if (cause.code !== 'ENOENT') throw cause; }
  await listen(admin, adminPath);
  if (remote && !sameIdentity) savePairing(undefined);
  if (lan) stopDiscovery = startDiscovery(host, port);
} catch (cause) {
  stop();
  throw cause;
}
