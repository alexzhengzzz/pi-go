// Run against a dedicated, unpaired LAN bridge. Pairing a new device on a
// production bridge replaces its existing credential.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { request } from 'node:https';
import { join } from 'node:path';
import { setTimeout as pause } from 'node:timers/promises';
import { ipcDirectory, localRequest } from '../bridge/local-ipc.mjs';

const port = Number(process.env.PIGO_LIVE_PORT);
assert.ok(Number.isInteger(port) && port >= 1024 && port <= 65535,
  'Set PIGO_LIVE_PORT to a dedicated LAN bridge port.');
const admin = join(ipcDirectory(), `bridge-${port}.sock`);
const status = await localRequest(admin, 'GET', '/status');
assert.equal(status.data.transport, 'lan', 'The smoke test requires a LAN bridge.');
assert.equal(status.data.paired, false, 'Use an unpaired bridge to preserve existing credentials.');
const enabled = await localRequest(admin, 'POST', '/computer-access');
assert.equal(enabled.status, 200, 'Enable access on the dedicated test bridge.');
const ticket = await localRequest(admin, 'POST', '/ticket-lan', { host: status.data.host });
assert.equal(ticket.status, 200, 'Issue a fresh test ticket.');
const { bundle } = JSON.parse(readFileSync(ticket.data.file, 'utf8'));
const { url, ticket: code, ca } = JSON.parse(Buffer.from(bundle, 'base64url').toString('utf8'));

function call(path, input, bearer) {
  return new Promise((resolve, reject) => {
    const req = request(new URL(path, url), {
      method: input ? 'POST' : 'GET', ca, rejectUnauthorized: true,
      headers: { 'content-type': 'application/json', ...(bearer ? { authorization: `Bearer ${bearer}` } : {}) },
      signal: AbortSignal.timeout(16_000),
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('error', reject);
      res.on('end', () => {
        try {
          const data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          resolve({ status: res.statusCode, data });
        } catch (error) { reject(error); }
      });
    });
    req.on('error', reject);
    req.end(input ? JSON.stringify(input) : undefined);
  });
}

const paired = await call('/pair', { ticket: code });
assert.equal(paired.status, 200, 'Pair over TLS.');
const phone = (path, input) => call(path, input, paired.data.token);
const name = 'pigo-daemon-test';
const created = await phone('/create-workspace', { name });
assert.ok(created.status === 200 || (created.status === 409 && created.data.error === 'workspace_exists'),
  `Create test workspace: HTTP ${created.status} ${created.data.error ?? ''}`);
const cwd = created.data.cwd ?? join(homedir(), 'Pi Go', 'Spaces', name);
const fresh = await phone('/new', { cwd });
assert.equal(fresh.status, 200, `Create session: ${fresh.data.error ?? ''}`);
const { id } = fresh.data.session;
const prompt = await phone('/prompt', { id, text: 'Reply with exactly PIGO_LIVE_OK', requestId: 'live-smoke-1' });
assert.equal(prompt.status, 202, `Send prompt: ${prompt.data.error ?? ''}`);

let replied = false;
for (let attempt = 0; attempt < 120 && !replied; attempt += 1) {
  const chat = await phone('/chat');
  assert.equal(chat.status, 200);
  assert.equal(chat.data.session?.id, id);
  replied = chat.data.session.idle && chat.data.messages.some((message) => message.text?.trim() === 'PIGO_LIVE_OK');
  if (!replied) await pause(500);
}
assert.ok(replied, 'The real model must answer in the selected session.');
assert.equal((await phone('/open', { id })).data.session?.id, id, 'Reopen the same session.');
assert.ok((await phone('/chat')).data.messages.some((message) => message.text?.trim() === 'PIGO_LIVE_OK'),
  'The reopened session must retain its reply.');
const renamed = await phone('/rename', { id, name: 'live smoke session' });
assert.equal(renamed.status, 200, `Rename session: ${renamed.data.error ?? ''}`);
assert.equal(renamed.data.session?.name, 'live smoke session');
console.log('LAN pairing, workspace access, new session, model reply, reopen and rename passed.');
