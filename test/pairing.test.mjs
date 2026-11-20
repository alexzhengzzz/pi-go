import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn, execFile } from 'node:child_process';
import { mkdtemp, mkdir, rm, writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir, networkInterfaces } from 'node:os';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { request as plainRequest } from 'node:http';
import { randomUUID } from 'node:crypto';
import { request as secureRequest } from 'node:https';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { localRequest } from '../desktop/local-ipc.mjs';
import { localLanAddress } from '../desktop/lan-tls.mjs';
const project = fileURLToPath(new URL('../', import.meta.url));
const helper = fileURLToPath(new URL('../desktop/pairing-control.mjs', import.meta.url));

function gui(input, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [helper], { env: { ...process.env, ...env } });
    let output = '', error = '';
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.on('data', (chunk) => { error += chunk; });
    child.once('error', reject);
    child.once('exit', () => { try { const r = JSON.parse(output); if (!r.ok) reject(new Error(r.error)); else resolve(r.data); } catch (e) { reject(new Error(error || e.message)); } });
    child.stdin.end(JSON.stringify(input));
  });
}

function tlsRequest(config, path, input, token) {
  return new Promise((resolve, reject) => {
    const req = secureRequest(config.url + path, { method: input ? 'POST' : 'GET', ca: config.ca, rejectUnauthorized: true,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) } }, (res) => {
      let data = ''; res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => { try { resolve({ status: res.statusCode, data: JSON.parse(data) }); } catch (e) { reject(e); } });
    });
    req.on('error', reject); req.end(input ? JSON.stringify(input) : undefined);
  });
}

test('desktop GUI discovers unshared real Pi sessions and shares only the selected session', { timeout: 20000 }, async (context) => {
  const root = await mkdtemp(join(tmpdir(), 'pigo-gui-'));
  const agent = join(root, 'agent'), cwd = join(root, 'project'), ipc = join(root, 'ipc');
  await Promise.all([agent, cwd].map((p) => mkdir(p)));
  const env = { ...process.env, PI_CODING_AGENT_DIR: agent, PIGO_IPC_DIR: ipc, PI_OFFLINE: '1' };
  const pi = process.env.PI_BIN || 'pi';
  await promisify(execFile)(pi, ['install', project], { env, cwd });
  const runtime = spawn(pi, ['--offline', '--mode', 'rpc', '--no-mcp', '--no-tools', '--no-skills', '--no-context-files', '-e', join(project, 'test/offline-provider.ts'), '--provider', 'pi-go-test', '--model', 'fixture'], { env, cwd });
  const exited = once(runtime, 'exit');
  runtime.stdout.resume(); runtime.stderr.resume();
  context.after(async () => { runtime.stdin.end(); const timer = setTimeout(() => runtime.kill(), 1000); await exited; clearTimeout(timer); await rm(root, { recursive: true, force: true }); });
  let state;
  for (let i = 0; i < 60; i++) {
    state = await gui({ action: 'refresh' }, env);
    if (state.sessions.length) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(state.sessions.length, 1);
  const session = state.sessions[0];
  assert.equal(session.shared, false);
  assert.equal(session.model.provider, 'pi-go-test');
  await assert.rejects(gui({ action: 'share', socket: session.socket, id: 'stale-id' }, env), /会话已关闭或已切换/);
  assert.equal((await localRequest(session.socket, 'POST', '/share', { id: 'stale-id' })).status, 409);
  await gui({ action: 'share', socket: session.socket, id: session.id }, env);
  assert.equal((await gui({ action: 'refresh' }, env)).sessions[0].shared, true);
  await gui({ action: 'unshare', socket: session.socket, id: session.id }, env);
  assert.equal((await gui({ action: 'refresh' }, env)).sessions[0].shared, false);
  if (host) {
    const reservation = createServer(); reservation.listen(0, host); await once(reservation, 'listening');
    const port = reservation.address().port; await promisify(reservation.close.bind(reservation))();
    context.after(() => gui({ action: 'stop', mode: 'lan', port }, env).catch(() => {}));
    const pair = await gui({ action: 'pair', mode: 'lan', port, host }, env);
    const config = JSON.parse(Buffer.from(pair.bundle, 'base64url').toString());
    const { data: { token } } = await tlsRequest(config, '/pair', { ticket: config.ticket });
    const list = await tlsRequest(config, '/sessions', undefined, token);
    assert.equal(list.status, 200);
    assert.equal(list.data.sessions.find((s) => s.id === session.id).active, true);
    assert.equal((await gui({ action: 'refresh' }, env)).sessions[0].shared, true);
    await gui({ action: 'stop', mode: 'lan', port }, env);
  }
});

const host = Object.values(networkInterfaces()).flat().find((e) => e && localLanAddress(e.address))?.address;

function usbPair(port, ticket) {
  return new Promise((resolve, reject) => {
    const req = plainRequest(`http://127.0.0.1:${port}/pair`, { method: 'POST', headers: { 'content-type': 'application/json' } }, (res) => {
      let data = ''; res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => { try { resolve({ status: res.statusCode, data: JSON.parse(data) }); } catch (e) { reject(e); } });
    });
    req.on('error', reject); req.end(JSON.stringify({ ticket }));
  });
}
const fakeHdc = `#!/bin/sh
command="$*"
echo "$command" >> "$HDC_LOG"
case "$command" in
  "list targets -v") printf '%s\n' "$HDC_TARGETS"; exit 0 ;;
  *" fport ls") printf '%s\n' "$HDC_FORWARD"; exit 0 ;;
  *" rport tcp:"*) echo "rport OK"; exit 0 ;;
  *" aa start "*)
    if [ -n "$HDC_FAIL_START" ]; then echo "Error: ability start failed" >&2; fi
    echo "start ability successfully"; exit 0 ;;
esac
echo "unexpected: $command" >&2
exit 1
`;

test('desktop GUI USB pairing hands the one-time ticket to the phone over hdc', { timeout: 30000 }, async (context) => {
  const root = await mkdtemp(join(tmpdir(), 'pigo-gui-usb-'));
  const probe = createServer();
  probe.listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const port = probe.address().port;
  await promisify(probe.close.bind(probe))();
  const usb = 'FAKESERIAL0123456789';
  const connected = `${usb}\tUSB\tConnected\tlocalhost\thdc`;
  const network = '127.0.0.1:5555 TCP Connected localhost hdc';
  const env = { PIGO_IPC_DIR: join(root, 'ipc'), PI_CODING_AGENT_DIR: join(root, 'agent'), HDC_BIN: join(root, 'hdc'), HDC_LOG: join(root, 'hdc.log'),
    HDC_TARGETS: `${network}\n${connected}` };
  const input = { mode: 'usb', port };
  await mkdir(join(root, 'agent'));
  await writeFile(env.HDC_BIN, fakeHdc, { mode: 0o755 });
  context.after(async () => { await gui({ ...input, action: 'stop' }, env).catch(() => {}); await rm(root, { recursive: true, force: true }); });
  for (const targets of ['[Empty]', network, `${usb} USB Unauthorized localhost hdc`, `${connected}\nOTHER USB Connected localhost hdc`]) {
    assert.equal((await gui({ ...input, action: 'usb-target' }, { ...env, HDC_TARGETS: targets })).usbTarget, undefined);
  }
  await assert.rejects(gui({ ...input, action: 'pair' }, { ...env, HDC_TARGETS: network }), /未发现手机/);
  const { usbTarget } = await gui({ ...input, action: 'usb-target' }, env);
  assert.equal(usbTarget, usb);
  await assert.rejects(gui({ ...input, action: 'pair', target: usbTarget }, { ...env, HDC_TARGETS: 'OTHER USB Connected localhost hdc' }), /USB 手机已更换/);
  const endpoint = `tcp:${port}`;
  const pair = await gui({ ...input, action: 'pair', target: usbTarget }, { ...env, HDC_FORWARD: `OTHER ${endpoint} ${endpoint} [Reverse]\n${usb} ${endpoint} ${endpoint} [Forward]` });
  assert.equal(pair.bridge.running, true);
  assert.equal(pair.bridge.transport, 'usb');
  assert.equal(pair.bridge.computerAccess, true);
  assert.equal(pair.usbTarget, usb);
  assert.match(pair.code, /^\d{8}$/);
  assert.equal(pair.warning, undefined);
  const log = await readFile(env.HDC_LOG, 'utf8');
  assert.ok(log.includes(`-t ${usb} rport ${endpoint} ${endpoint}`));
  assert.ok(log.includes(`--ps address http://127.0.0.1:${port}`));
  const delivered = [...log.matchAll(/--ps ticket ([a-f0-9]{64})/g)].map((m) => m[1]).pop();
  assert.ok(delivered, 'aa start must carry the one-time ticket');
  assert.notEqual(delivered, pair.code);
  // Simulate the phone consuming the delivered ticket, exactly as the Harmony
  // client would after being launched with --ps ticket.
  const phone = await usbPair(port, delivered);
  assert.equal(phone.status, 200);
  assert.match(phone.data.token, /^[a-f0-9]{64}$/);
  assert.equal((await usbPair(port, delivered)).status, 401);
  const failed = await gui({ ...input, action: 'pair' }, { ...env, HDC_FAIL_START: '1', HDC_FORWARD: `${usb} ${endpoint} ${endpoint} [Reverse]` });
  assert.match(failed.code, /^\d{8}$/);
  assert.match(failed.warning, /无法自动打开手机 Pi Go/);
  assert.equal((await usbPair(port, delivered)).status, 401);
  const finalLog = await readFile(env.HDC_LOG, 'utf8');
  assert.equal(finalLog.split('\n').filter((line) => line.includes(' rport ')).length, 1);
  const latest = [...finalLog.matchAll(/--ps ticket ([a-f0-9]{64})/g)].map((m) => m[1]).pop();
  assert.notEqual(latest, delivered);
  const manual = await usbPair(port, failed.code);
  assert.equal(manual.status, 200);
  assert.equal((await usbPair(port, latest)).status, 401);
  assert.equal((await gui({ ...input, action: 'refresh' }, env)).bridge.paired, true);
  await gui({ ...input, action: 'stop' }, env);
  assert.equal((await gui({ ...input, action: 'refresh' }, env)).bridge.running, false);
});
test('desktop GUI starts LAN pairing, exposes no ticket over HTTP, and revokes the device', { skip: !host, timeout: 15000 }, async (context) => {
  const root = await mkdtemp(join(tmpdir(), 'pigo-gui-lan-'));
  const env = { PIGO_IPC_DIR: join(root, 'ipc'), PI_CODING_AGENT_DIR: join(root, 'agent') };
  const sessionRoot = join(root, 'agent', 'sessions');
  await Promise.all(['project-a', 'project-b'].map((p) => mkdir(join(sessionRoot, p), { recursive: true })));
  await Promise.all(Array.from({ length: 270 }, async (_, i) => {
    const id = randomUUID(), projectName = i % 2 ? 'project-a' : 'project-b';
    await writeFile(join(sessionRoot, projectName, id + '.jsonl'), [
      { type: 'session', id, cwd: join(root, projectName) },
      { type: 'message', message: { role: 'user', content: [{ type: 'text', text: 'Historical ' + i }] } },
      { type: 'session_info', name: 'History ' + i },
    ].map(JSON.stringify).join('\n') + '\n');
  }));
  const reservation = createServer(); reservation.listen(0, host); await once(reservation, 'listening');
  const port = reservation.address().port; await promisify(reservation.close.bind(reservation))();
  context.after(async () => { await gui({ action: 'stop', mode: 'lan', port }, env).catch(() => {}); await rm(root, { recursive: true, force: true }); });
  const pair = await gui({ action: 'pair', mode: 'lan', port, host }, env);
  assert.equal(pair.bridge.running, true);
  assert.equal(pair.bridge.paired, false);
  assert.equal(pair.bridge.computerAccess, true);
  assert.ok(pair.bridge.expiresAt > Date.now());
  const config = JSON.parse(Buffer.from(pair.bundle, 'base64url').toString());
  assert.equal(config.url, `https://${host}:${port}`);
  const paired = await promisify(execFile)(process.execPath, ['--input-type=module', '-e', `
    import https from 'node:https';
    const c = JSON.parse(Buffer.from(process.argv[1], 'base64url').toString());
    const request = (path, input, token) => new Promise((resolve, reject) => {
      const req = https.request(c.url + path, {method: input ? 'POST' : 'GET', ca:c.ca,
        headers: {'content-type':'application/json', ...(token ? {authorization:'Bearer ' + token} : {})}}, res => {
          let text = ''; res.on('data', b => text += b); res.on('end', () => resolve({status:res.statusCode, data:JSON.parse(text)}));
        });
      req.on('error', reject); req.end(input ? JSON.stringify(input) : undefined);
    });
    const paired = await request('/pair', {ticket:c.ticket});
    const chat = await request('/chat', undefined, paired.data.token);
    const first = await request('/sessions?limit=100', undefined, paired.data.token);
    const last = await request('/sessions?limit=100&cursor=200', undefined, paired.data.token);
    const search = await request('/sessions?query=History%20269', undefined, paired.data.token);
    console.log(JSON.stringify({token:paired.data.token, chat, first, last, search}));
  `, pair.bundle]);
  assert.equal(typeof JSON.parse(paired.stdout).token, 'string');
  assert.equal(JSON.parse(paired.stdout).chat.status, 200);
  assert.equal(JSON.parse(paired.stdout).chat.data.state, 'no_shared_sessions');
  const result = JSON.parse(paired.stdout);
  assert.equal(result.first.data.total, 270);
  assert.equal(result.first.data.sessions.length, 100);
  assert.equal(result.last.data.sessions.length, 70);
  assert.equal(result.last.data.nextCursor, undefined);
  assert.equal(result.search.data.total, 1);
  assert.equal(result.search.data.sessions[0].name, 'History 269');
  assert.equal(new Set(result.first.data.sessions.map((s) => s.cwd)).size, 2);
  const status = (await gui({ action: 'refresh', mode: 'lan', port }, env)).bridge;
  assert.equal(status.paired, true);
  assert.equal(status.expiresAt, undefined);
  assert.equal(JSON.stringify(status).includes(config.ticket), false);
  await gui({ action: 'revoke', mode: 'lan', port }, env);
  assert.equal((await gui({ action: 'refresh', mode: 'lan', port }, env)).bridge.paired, false);
  await gui({ action: 'stop', mode: 'lan', port }, env);
  assert.equal((await gui({ action: 'refresh', mode: 'lan', port }, env)).bridge.running, false);
});
