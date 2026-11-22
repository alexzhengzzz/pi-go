// CLI coexistence test — the "Mac keeps a pi session running, the phone joins
// the same session without stopping it" scenario.
//
// The resident CLI is simulated with a real `pi --mode rpc` process (same
// engine, same extension loading as TUI). The phone pairs through the bridge
// the CLI extension starts (/pi-go-bridge), then POST /open must SELECT the
// live worker instead of spawning a second engine process: both sides share
// one engine, and a phone prompt while the CLI is streaming is queued by the
// engine's native steering instead of racing on the session file.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { realpath } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { join } from 'node:path';
import { createServer } from 'node:net';
import { promisify } from 'node:util';
import { localRequest } from '../desktop/local-ipc.mjs';

const project = new URL('../', import.meta.url).pathname;
const provider = new URL('./offline-provider.ts', import.meta.url).pathname;
const pi = process.env.PI_BIN || 'pi';
const runtimeArgs = ['--offline', '--no-tools', '--no-mcp', '--no-approve', '--no-skills', '--no-context-files',
  '--provider', 'pi-go-test', '--model', 'fixture'];

const workerCount = async (ipc) => (await readdir(ipc)).filter((name) => /^w-/.test(name)).length;

test('phone joins the resident CLI session: one engine, two clients, steering works', { timeout: 180000 }, async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-cli-coexist-'));
  const agent = join(root, 'agent'), ipc = join(root, 'ipc'), work = join(root, 'project');
  await Promise.all([agent, ipc, work].map((path) => mkdir(path, { mode: 0o700 })));
  const env = { ...process.env, PI_CODING_AGENT_DIR: agent, PIGO_IPC_DIR: ipc, PI_OFFLINE: '1' };
  await promisify(execFile)(pi, ['install', project], { cwd: work, env });
  let settings = {};
  for (let attempt = 0; attempt < 30; attempt++) {
    try { settings = JSON.parse(await readFile(join(agent, 'settings.json'), 'utf8')); break; }
    catch { await new Promise((resolve) => setTimeout(resolve, 100)); }
  }
  settings.extensions = [provider];
  await writeFile(join(agent, 'settings.json'), JSON.stringify(settings));

  // The "resident CLI": a real pi engine process the user keeps open.
  const cli = spawn(pi, ['--mode', 'rpc', ...runtimeArgs], { cwd: work, env });
  const events = [];
  let cliStderr = '';
  createInterface({ input: cli.stdout }).on('line', (line) => { try { events.push(JSON.parse(line)); } catch {} });
  cli.stderr.setEncoding('utf8').on('data', (data) => { cliStderr = (cliStderr + data).slice(-4000); });
  const rpc = async (type, data = {}) => {
    const id = `cli-${Date.now()}-${Math.random()}`;
    cli.stdin.write(JSON.stringify({ type, id, ...data }) + '\n');
    for (let i = 0; i < 400; i++) {
      const response = events.find((event) => event.type === 'response' && event.id === id);
      if (response) return response;
      await new Promise((resolve) => setTimeout(resolve, 30));
    }
    throw new Error(`CLI rpc failed: ${cliStderr}`);
  };
  const cliWait = async (predicate) => {
    for (let i = 0; i < 600; i++) {
      const found = events.find(predicate);
      if (found) return found;
      if (cli.exitCode !== null) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`CLI event missing: ${cliStderr}\n${JSON.stringify(events.slice(-6))}`);
  };
  context.after(async () => {
    try { cli.kill('SIGTERM'); } catch {}
    // Stop the bridge the CLI extension spawned, or it leaks the port.
    await localRequest(join(ipc, `bridge-${port}.sock`), 'POST', '/stop').catch(() => {});
    await new Promise((resolve) => setTimeout(resolve, 300));
    await rm(root, { recursive: true, force: true });
  });

  const seeded = await rpc('prompt', { message: 'Seeded from the CLI side' });
  assert.equal(seeded.success, true);
  const state = await rpc('get_state');
  const sessionId = state.data.sessionId;

  // The user starts the bridge from the CLI: share + broker + pairing ticket.
  const reservation = createServer().listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await promisify(reservation.close.bind(reservation))();
  await rpc('prompt', { message: `/pi-go-bridge ${port}` });
  const notification = await cliWait((event) => event.type === 'extension_ui_request' &&
    event.method === 'notify' && event.message?.startsWith('Pi Go ticket file: '));
  const ticketFile = notification.message.slice('Pi Go ticket file: '.length);
  const pairing = JSON.parse(await readFile(ticketFile, 'utf8'));

  const phone = async (path, value) => {
    const response = await fetch(pairing.url + path, { method: value ? 'POST' : 'GET', signal: AbortSignal.timeout(15000),
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: value ? JSON.stringify(value) : undefined });
    return { status: response.status, data: await response.json() };
  };
  const paired = await fetch(pairing.url + '/pair', { method: 'POST', signal: AbortSignal.timeout(8000),
    headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ticket: pairing.code }) });
  const { token } = await paired.json();

  const directory = await phone('/sessions');
  const listed = directory.data.sessions.find((row) => row.id === sessionId);
  assert.ok(listed, 'the CLI session must appear in the phone directory');
  assert.equal(listed.active, true, 'the resident CLI session shows as active');

  // Opening the live session selects the existing worker: no second engine.
  const opened = await phone('/open', { id: sessionId });
  assert.equal(opened.status, 200, JSON.stringify(opened));
  assert.equal(opened.data.session.id, sessionId);
  assert.equal(await workerCount(ipc), 1, 'no extra engine process may be spawned');

  const chat = await phone('/chat');
  assert.equal(chat.data.session.id, sessionId);
  assert.equal(chat.data.messages.some((message) => message.text === 'Seeded from the CLI side'), true);

  // Dual-client concurrency: CLI is streaming a long answer; the phone steers.
  cli.stdin.write(JSON.stringify({ type: 'prompt', id: 'cli-long', message: 'Pi Go fixture: long answer' }) + '\n');
  await cliWait((event) => event.type === 'agent_start');
  let streaming;
  for (let i = 0; i < 100; i++) {
    const probe = await phone('/chat');
    if (probe.data.session.runId) { streaming = probe.data; break; }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.ok(streaming?.session.runId, 'the CLI run must be visible to the phone as streaming');

  const steered = await phone('/prompt', { id: sessionId, text: 'Phone steers while the CLI streams',
    requestId: 'phone-steer-1', mode: 'steer', runId: streaming.session.runId });
  assert.equal(steered.status, 202, JSON.stringify(steered));

  await cliWait((event) => event.type === 'agent_settled');
  assert.equal(await workerCount(ipc), 1, 'still exactly one engine process');

  // Both sides see one shared history: the phone's steering message entered
  // the same engine session the CLI holds.
  const messages = (await rpc('get_messages')).data.messages;
  assert.equal(messages.some((message) => message.role === 'user' &&
    JSON.stringify(message.content).includes('Phone steers while the CLI streams')), true);
  const finalChat = await phone('/chat');
  assert.equal(finalChat.data.messages.some((message) => message.text === 'Phone steers while the CLI streams'), true);
  assert.equal(finalChat.data.messages.some((message) => message.text === 'Seeded from the CLI side'), true);
});
