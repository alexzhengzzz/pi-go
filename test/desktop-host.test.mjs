import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn, execFile } from 'node:child_process';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { mkdtemp, mkdir, readFile, writeFile, rm, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { localRequest } from '../desktop/local-ipc.mjs';

const checkout = process.env.PIGO_DESKTOP_CHECKOUT;
const packagedApp = process.env.PIGO_DESKTOP_APP;
const project = fileURLToPath(new URL('../', import.meta.url));
test('real Desktop automatically trusts restored projects for subsequent authorization and new sessions', { skip: !checkout && !packagedApp, timeout: 45000 }, async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-native-switch-'));
  const agent = join(root, 'agent'), profile = join(root, 'profile'), ipc = join(root, 'ipc');
  const first = join(root, 'project-a'), second = join(root, 'project-b');
  await Promise.all([agent, profile, ipc, first, second].map((p) => mkdir(p, { mode: 0o700 })));
  const env = { ...process.env, PI_CODING_AGENT_DIR: agent, PI_DESKTOP_USER_DATA_DIR: profile, PIGO_IPC_DIR: ipc, PIGO_DESKTOP_HOST: '1', PI_OFFLINE: '1' };
  const pi = process.env.PI_BIN || 'pi';
  await promisify(execFile)(pi, ['install', project], { cwd: first, env });
  const settingsPath = join(agent, 'settings.json');
  const settings = JSON.parse(await readFile(settingsPath, 'utf8'));
  settings.extensions = [join(project, 'test/offline-provider.ts')];
  settings.defaultProvider = 'pi-go-test'; settings.defaultModel = 'fixture';
  await writeFile(settingsPath, JSON.stringify(settings));
  await writeFile(join(profile, 'settings.json'), JSON.stringify({ defaultProvider: 'pi-go-test', defaultModel: 'fixture', permissionMode: 'ask-commands', suggestNextSteps: false, resumeLastSession: false }));
  const children = [];
  context.after(async () => {
    for (const child of children) { if (child.exitCode === null) child.kill('SIGTERM'); }
    await new Promise((resolve) => setTimeout(resolve, 300));
    await rm(root, { recursive: true, force: true });
  });
  async function seed(cwd, text) {
    const child = spawn(pi, ['--offline', '--mode', 'rpc', '--no-mcp', '--no-tools', '--no-skills', '--no-context-files', '--provider', 'pi-go-test', '--model', 'fixture'], { cwd, env });
    children.push(child);
    const events = []; let failure = '';
    child.stderr.on('data', (data) => { failure += data; });
    createInterface({ input: child.stdout }).on('line', (line) => { try { events.push(JSON.parse(line)); } catch {} });
    const wait = async (predicate) => {
      for (let i = 0; i < 150; i++) { const found = events.find(predicate); if (found) return found; if (child.exitCode !== null) break; await new Promise((r) => setTimeout(r, 30)); }
      throw new Error('Seed runtime failed: ' + failure);
    };
    child.stdin.write(JSON.stringify({ type: 'prompt', id: 'prompt', message: text }) + '\n');
    await wait((e) => e.type === 'agent_settled');
    child.stdin.write(JSON.stringify({ type: 'get_state', id: 'state' }) + '\n');
    const state = (await wait((e) => e.type === 'response' && e.id === 'state')).data;
    const exited = once(child, 'exit'); child.stdin.end(); await exited;
    return state;
  }
  const a = await seed(first, 'History from project A');
  const b = await seed(second, 'History from project B');
  if (packagedApp) delete env.PIGO_DESKTOP_HOST;
  const executable = packagedApp ? join(packagedApp, 'Contents/MacOS/Pi Desktop') : join(checkout, 'node_modules/electron/dist/Electron.app/Contents/MacOS/Electron');
  const electron = spawn(executable, [...(packagedApp ? [] : [checkout]), '--user-data-dir=' + profile], { cwd: checkout || project, env, stdio: ['ignore', 'ignore', 'pipe'] });
  children.push(electron); let logs = '';
  electron.stderr.on('data', (data) => { logs = (logs + data).slice(-6000); });
  const socket = join(ipc, `host-${electron.pid}.sock`);
  let health;
  for (let i = 0; i < 100; i++) {
    health = await localRequest(socket, 'GET', '/health', undefined, 500).catch(() => undefined);
    if (health?.status === 200) break;
    if (electron.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.equal(health?.status, 200, logs);
  assert.equal((await localRequest(socket, 'POST', '/open', { cwd: first, id: b.sessionId })).status, 403);
  const reservation = createServer().listen(0, '127.0.0.1'); await once(reservation, 'listening');
  const port = reservation.address().port; await promisify(reservation.close.bind(reservation))();
  const broker = spawn(process.execPath, [join(project, 'desktop/broker.mjs'), String(port)], { env, stdio: 'ignore' });
  children.push(broker);
  const admin = join(ipc, `bridge-${port}.sock`);
  let ticket;
  for (let i = 0; i < 60 && !ticket; i++) {
    const enabled = await localRequest(admin, 'POST', '/computer-access').catch(() => undefined);
    if (enabled?.status === 200) ticket = await localRequest(admin, 'POST', '/ticket');
    else await new Promise((r) => setTimeout(r, 50));
  }
  assert.equal(ticket?.status, 200);
  const pairing = JSON.parse(await readFile(ticket.data.file, 'utf8'));
  const paired = await fetch(pairing.url + '/pair', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ticket: pairing.code }) });
  const { token } = await paired.json();
  const phone = async (path, value) => {
    const response = await fetch(pairing.url + path, { method: value ? 'POST' : 'GET', signal: AbortSignal.timeout(16000),
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: value ? JSON.stringify(value) : undefined });
    return { status: response.status, data: await response.json() };
  };
  const directory = await phone('/sessions');
  assert.equal(directory.data.sessions.some((s) => s.id === a.sessionId), true);
  assert.equal(directory.data.sessions.some((s) => s.id === b.sessionId), true);
  for (const [state, text] of [[a, 'History from project A'], [b, 'History from project B'], [a, 'History from project A']]) {
    const result = await phone('/open', { id: state.sessionId });
    assert.equal(result.status, 200, JSON.stringify(result));
    const chat = await phone('/chat');
    assert.equal(chat.data.session.id, state.sessionId);
    assert.equal(chat.data.messages.some((m) => m.text === text), true);
  }
  await localRequest(admin, 'POST', '/stop');
  const openedA = await localRequest(socket, 'POST', '/open', { cwd: first, id: a.sessionId }, 15000);
  assert.equal(openedA.status, 200, JSON.stringify(openedA));
  assert.equal(openedA.data.id, a.sessionId);
  const openedB = await localRequest(socket, 'POST', '/open', { cwd: second, id: b.sessionId }, 15000);
  assert.equal(openedB.status, 200, JSON.stringify(openedB));
  assert.equal(openedB.data.id, b.sessionId);
  const { readdir } = await import('node:fs/promises');
  const workers = (await readdir(ipc)).filter((name) => /^w-/.test(name));
  const chats = await Promise.all(workers.map((name) => localRequest(join(ipc, name), 'GET', '/chat')));
  assert.equal(chats.find((r) => r.data.session?.id === a.sessionId)?.data.messages.some((m) => m.text === 'History from project A'), true);
  assert.equal(chats.find((r) => r.data.session?.id === b.sessionId)?.data.messages.some((m) => m.text === 'History from project B'), true);
  assert.equal((await localRequest(socket, 'POST', '/open', { cwd: first, id: b.sessionId })).status, 404);
  const trust = await readFile(join(profile, 'trusted-workspaces.json'), 'utf8').catch(() => '[]');
  assert.deepEqual(new Set(JSON.parse(trust)), new Set([first, second]));
  assert.equal((await localRequest(socket, 'POST', '/authorize', { cwd: first })).status, 200);
  const projects = await localRequest(socket, 'POST', '/projects', {});
  assert.deepEqual(new Set(projects.data.projects), new Set([first, second]));
  const created = await localRequest(socket, 'POST', '/new', { cwd: second }, 15000);
  assert.equal(created.status, 200, JSON.stringify(created));
  assert.notEqual(created.data.id, b.sessionId);
  const fresh = join(root, 'fresh-project');
  await mkdir(fresh);
  assert.equal((await localRequest(socket, 'POST', '/authorize', { cwd: fresh })).status, 200);
  const trusted = JSON.parse(await readFile(join(profile, 'trusted-workspaces.json'), 'utf8'));
  assert.ok(trusted.includes(fresh));
  const freshSession = await localRequest(socket, 'POST', '/new', { cwd: fresh }, 15000);
  assert.equal(freshSession.status, 200, JSON.stringify(freshSession));
  assert.equal((await localRequest(socket, 'POST', '/authorize', { cwd: join(root, 'missing') })).status, 403);
});
