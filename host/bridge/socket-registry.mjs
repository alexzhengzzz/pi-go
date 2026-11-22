import { randomBytes } from 'node:crypto';
import { lstatSync, readFileSync, readdirSync, renameSync, unlinkSync, watch, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { ipcDirectory, localRequest } from './local-ipc.mjs';

const suffix = '.registration.json';
const registrationPath = (socket) => join(dirname(socket), '.' + basename(socket) + suffix);
const leaseMs = 15000;
const renewalMs = 5000;
const sweepMs = 1000;
const maxRegistrationBytes = 64 * 1024;
const socketName = /^(w|host|gui)-(\d+)(?:-([0-9a-f]{8}))?\.sock$/;

function socketKind(name) {
  const match = socketName.exec(name);
  if (match && (match[1] === 'host') === !match[3]) return match[1];
}

function socketStat(socket) {
  try {
    const info = lstatSync(socket);
    if (info.isSocket() && info.uid === process.getuid()) return info;
  } catch {}
}

const sameSocket = (a, b) => a && b && a.dev === b.dev && a.ino === b.ino;

function remove(path) {
  try { unlinkSync(path); } catch {}
}

// Publish only on state changes or lease renewal. Existing peers can continue
// to use the socket directly and don't need to understand the registration.
export function registerSocket(server, snapshot) {
  let file, socket, timer, last, writtenAt;
  function publish() {
    if (!file) return;
    let temporary;
    try {
      const data = JSON.stringify({ version: 1, dev: socket.dev, ino: socket.ino, data: snapshot() });
      if (Buffer.byteLength(data) > maxRegistrationBytes) throw new Error('registration_too_large');
      if (data === last && Date.now() - writtenAt < renewalMs) return;
      temporary = `${file}.${randomBytes(6).toString('hex')}`;
      writeFileSync(temporary, data, { flag: 'wx', mode: 0o600 });
      renameSync(temporary, file);
      last = data;
      writtenAt = Date.now();
    } catch {
      remove(file);
      last = undefined;
    } finally {
      if (temporary) remove(temporary);
    }
  }
  function withdraw() {
    clearInterval(timer);
    if (file) remove(file);
    file = undefined;
    last = undefined;
  }
  server.on('listening', () => {
    const path = server.address();
    socket = typeof path === 'string' && socketStat(path);
    if (!socket) return;
    file = registrationPath(path);
    publish();
    timer = setInterval(publish, sweepMs).unref();
  });
  server.on('close', withdraw);
  return { publish, withdraw };
}

function readRegistration(socket, identity) {
  try {
    const file = registrationPath(socket);
    const info = lstatSync(file);
    if (!info.isFile() || info.uid !== process.getuid() || (info.mode & 0o077) ||
        info.size > maxRegistrationBytes || Date.now() - info.mtimeMs > leaseMs) return;
    const raw = readFileSync(file, 'utf8');
    if (Buffer.byteLength(raw) > maxRegistrationBytes) return;
    const record = JSON.parse(raw);
    if (record?.version === 1 && sameSocket(record, identity)) return record.data;
  } catch {}
}

function liveProcess(socket) {
  const pid = Number(socketName.exec(basename(socket))?.[2]);
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (cause) { return cause.code === 'EPERM'; }
}

export function createSocketRegistry({ shouldShare = () => false } = {}) {
  const directory = ipcDirectory();
  const entries = new Map();
  const listeners = new Set();
  let stopped = false;
  let watcher, timer;
  const signal = () => { for (const listener of listeners) listener(); };

  function accept(entry, data) {
    if (entry.kind === 'host') {
      entry.data = data?.protocol === 'pi-go-desktop-host/1' ? data : undefined;
    } else {
      const session = data?.session;
      entry.data = typeof session?.id === 'string' && typeof session.cwd === 'string' ? data : undefined;
    }
    signal();
  }

  async function share(entry) {
    const session = entry.data?.session;
    if (!shouldShare() || !session || session.shared || entry.sharing || Date.now() < entry.retryShareAt) return;
    entry.sharing = true;
    try {
      const result = await localRequest(entry.socket, 'POST', '/share', { id: session.id }, 1000);
      if (!stopped && entries.get(entry.socket) === entry && entry.data?.session?.id === session.id && result.status === 200) {
        accept(entry, result.data);
      }
    } catch {}
    finally {
      entry.sharing = false;
      entry.retryShareAt = Date.now() + sweepMs;
    }
  }

  function forget(socket) {
    if (entries.delete(socket)) signal();
  }

  async function refresh(socket, kind, identity) {
    let entry = entries.get(socket);
    if (!sameSocket(entry?.identity, identity)) {
      entry = { socket, kind, identity, probe: undefined, retryShareAt: 0, registered: false };
      entries.set(socket, entry);
      signal();
    }

    const registered = readRegistration(socket, identity);
    if (registered !== undefined && liveProcess(socket)) {
      entry.registered = true;
      accept(entry, registered);
    } else {
      if (entry.registered) {
        // A vanished or expired registration cannot grant access while the
        // background probe establishes whether the process is still serving.
        entry.registered = false;
        accept(entry, undefined);
      }
      if (entry.probe) return entry.probe;
      if (kind === 'gui' && !shouldShare()) return;
      entry.probe = (async () => {
        try {
          const result = await localRequest(socket, 'GET', kind === 'host' ? '/health' : '/session', undefined, 700);
          if (!stopped && entries.get(socket) === entry && !entry.registered) {
            accept(entry, result.status === 200 ? result.data : undefined);
          }
        } catch (cause) {
          if (stopped || entries.get(socket) !== entry || entry.registered) return;
          accept(entry, undefined);
          if (cause.code === 'ECONNREFUSED' && sameSocket(identity, socketStat(socket))) {
            remove(socket);
            remove(registrationPath(socket));
            forget(socket);
          }
        } finally { entry.probe = undefined; }
      })();
      await entry.probe;
    }
    if (kind === 'gui' && !stopped && entries.get(socket) === entry) void share(entry);
  }

  function sweep() {
    if (stopped) return Promise.resolve();
    let candidates;
    try { candidates = readdirSync(ipcDirectory(), { withFileTypes: true }); }
    catch {
      for (const socket of entries.keys()) forget(socket);
      return Promise.resolve();
    }
    const found = new Set();
    const jobs = [];
    const limits = { w: 32, host: 8, gui: 64 };
    for (const candidate of candidates) {
      const kind = candidate.isSocket() && socketKind(candidate.name);
      if (!kind || limits[kind]-- <= 0) continue;
      const socket = join(directory, candidate.name);
      const identity = socketStat(socket);
      if (!identity) continue;
      found.add(socket);
      jobs.push(refresh(socket, kind, identity));
    }
    for (const socket of entries.keys()) if (!found.has(socket)) forget(socket);
    return Promise.all(jobs);
  }

  function watchDirectory() {
    if (watcher || stopped) return;
    try {
      watcher = watch(directory, { persistent: false }, (_event, name) => {
        if (!name) { void sweep(); return; }
        const nameOnDisk = name.startsWith('.') && name.endsWith(suffix) ? name.slice(1, -suffix.length) : name;
        if (!socketKind(nameOnDisk)) return;
        const socket = join(directory, nameOnDisk);
        const entry = entries.get(socket);
        const identity = socketStat(socket);
        if (!identity) forget(socket);
        else if (entry) void refresh(socket, entry.kind, identity);
        else void sweep();
      });
      watcher.on('error', () => { watcher.close(); watcher = undefined; });
    } catch {}
  }

  function workers() {
    return [...entries.values()].filter(({ kind, data }) => kind === 'w' && data).map(({ socket, data }) => ({
      socket, session: data.session, historyDirectory: typeof data.historyDirectory === 'string' ? data.historyDirectory : undefined,
    }));
  }

  function waitForWorker(predicate, timeout) {
    return new Promise((resolve) => {
      const finish = () => { clearTimeout(deadline); listeners.delete(check); resolve(); };
      const check = () => { if (stopped || workers().some(predicate)) finish(); };
      const deadline = setTimeout(finish, timeout);
      listeners.add(check);
      check();
    });
  }

  return {
    start() {
      watchDirectory();
      timer = setInterval(() => { watchDirectory(); void sweep(); }, sweepMs).unref();
      return sweep();
    },
    stop() {
      stopped = true;
      watcher?.close();
      clearInterval(timer);
      entries.clear();
      signal();
    },
    workers,
    hosts: () => [...entries.values()].filter(({ kind, data }) => kind === 'host' && data)
      .map(({ socket, data }) => ({ socket, health: data })),
    enableSharing() {
      for (const entry of entries.values()) if (entry.kind === 'gui' && entry.data) void share(entry);
    },
    waitForWorker,
    forget,
  };
}
