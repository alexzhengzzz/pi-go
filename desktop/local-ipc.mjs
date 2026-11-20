import { randomBytes } from 'node:crypto';
import { lstatSync, mkdirSync, readdirSync, unlinkSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

export function ipcDirectory() {
  const uid = process.getuid();
  const directory = resolve(process.env.PIGO_IPC_DIR ?? join(tmpdir(), `pigo-${uid}`));
  try { mkdirSync(directory, { mode: 0o700 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  const info = lstatSync(directory);
  if (!info.isDirectory() || info.uid !== uid || (info.mode & 0o077) !== 0) throw new Error('unsafe_ipc_directory');
  return directory;
}

export function workerSocket() {
  const path = join(ipcDirectory(), `w-${process.pid}-${randomBytes(4).toString('hex')}.sock`);
  if (Buffer.byteLength(path) > 100) throw new Error('ipc_path_too_long');
  return path;
}

export function workers() {
  const directory = ipcDirectory();
  return readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isSocket() && /^w-\d+-[0-9a-f]{8}\.sock$/.test(entry.name))
    .slice(0, 32).map((entry) => join(directory, entry.name));
}

export function pairingRuntimes() {
  const directory = ipcDirectory();
  return readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isSocket() && /^gui-\d+-[0-9a-f]{8}\.sock$/.test(entry.name))
    .map((entry) => join(directory, entry.name));
}

export async function desktopHosts() {
  const directory = ipcDirectory();
  const candidates = readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isSocket() && /^host-\d+\.sock$/.test(entry.name)).slice(0, 8);
  const available = await Promise.all(candidates.map(async (entry) => {
    const socket = join(directory, entry.name);
    try {
      const result = await localRequest(socket, 'GET', '/health', undefined, 700);
      return result.status === 200 && result.data.protocol === 'pi-go-desktop-host/1' ? socket : undefined;
    } catch (error) {
      if (error.code === 'ECONNREFUSED') {
        try { unlinkSync(socket); } catch {}
      }
      return undefined;
    }
  }));
  return available.filter(Boolean);
}

export function localUpload(socketPath, path, bytes, timeout = 15000) {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, path, method: 'POST', agent: false, signal: AbortSignal.timeout(timeout),
      headers: { 'Content-Type': 'application/octet-stream', 'Content-Length': bytes.length },
    }, (res) => {
      const chunks = [];
      let size = 0;
      res.on('data', (chunk) => {
        size += chunk.length;
        if (size > 2 * 1024 * 1024) res.destroy(new Error('oversized_worker_response'));
        else chunks.push(chunk);
      });
      res.on('error', reject);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, data: JSON.parse(Buffer.concat(chunks).toString('utf8')) }); }
        catch (error) { reject(error); }
      });
    });
    req.on('error', reject);
    req.end(bytes);
  });
}

export function localRequest(socketPath, method, path, value, timeout = 4000) {
  const body = value === undefined ? undefined : JSON.stringify(value);
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, path, method, agent: false, signal: AbortSignal.timeout(timeout),
      headers: body === undefined ? {} : { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      const chunks = [];
      let size = 0;
      res.on('data', (chunk) => {
        size += chunk.length;
        if (size > 2 * 1024 * 1024) res.destroy(new Error('oversized_worker_response'));
        else chunks.push(chunk);
      });
      res.on('error', reject);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, data: JSON.parse(Buffer.concat(chunks).toString('utf8')) }); }
        catch (error) { reject(error); }
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}
