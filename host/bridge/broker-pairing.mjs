// Pairing state persistence and one-time ticket lifecycle for broker.mjs.
import { randomBytes, randomInt } from 'node:crypto';
import { closeSync, fsyncSync, lstatSync, mkdtempSync, openSync, readFileSync, renameSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { digest } from './broker-http.mjs';

export function loadPairingState({ pairingFile, host, pairingProfile, address, lan, remote }) {
  let info;
  try { info = lstatSync(pairingFile); }
  catch (cause) { if (cause.code === 'ENOENT') return; throw cause; }
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

export function savePairingState({ pairingFile, host, pairingProfile, address, remote, tls, computerAccess, nextBearer }) {
  const identity = tls && { cert: tls.cert, key: tls.key };
  const state = { version: 1, host, profile: pairingProfile, computerAccess, bearer: nextBearer?.toString('hex'), identity };
  if (remote) Object.assign(state, { address });
  const temporary = pairingFile + '.' + randomBytes(8).toString('hex');
  const fd = openSync(temporary, 'wx', 0o600);
  try {
    writeFileSync(fd, JSON.stringify(state));
    fsyncSync(fd);
    closeSync(fd);
    renameSync(temporary, pairingFile);
  } catch (cause) {
    try { closeSync(fd); } catch {}
    try { unlinkSync(temporary); } catch {}
    throw cause;
  }
}

export function createTicketManager({ tls, address, remote, transport }) {
  let pairing;
  let ticketTimer;

  function clear() {
    const directory = pairing?.directory;
    pairing = undefined;
    clearTimeout(ticketTimer);
    if (directory) {
      try { rmSync(directory, { recursive: true, force: true }); } catch { /* The ticket is already invalid. */ }
    }
  }

  function issue() {
    clear();
    const directory = mkdtempSync(join(tmpdir(), 'pigo-bridge-'));
    const ticket = randomBytes(32).toString('hex');
    const code = tls ? undefined : String(randomInt(100_000_000)).padStart(8, '0');
    const file = join(directory, 'pair.json');
    pairing = { directory, ticket: digest(ticket), code: code && digest(code), attempts: 0, expiresAt: Date.now() + 120000 };
    const url = `${tls ? 'https' : 'http'}://${address}`;
    const config = tls ? { bundle: Buffer.from(JSON.stringify({ url, ticket, ca: tls.cert, pin: tls.pin,
      ...(remote ? { transport } : {}) })).toString('base64url') } : { url, ticket, code };
    writeFileSync(file, JSON.stringify(config), { mode: 0o600, flag: 'wx' });
    ticketTimer = setTimeout(clear, 120000).unref();
    return file;
  }

  return {
    get current() { return pairing; },
    issue,
    clear,
  };
}
