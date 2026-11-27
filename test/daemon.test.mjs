// Pi Go daemon integration test — runs the real `pi --mode rpc` engine with
// the offline fixture provider, the Pi Go extension, and an interaction
// fixture, then drives the daemon host socket exactly like the broker does.
// The phone-side flow is additionally exercised end-to-end through broker.mjs.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { appendFile, mkdtemp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { realpath } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { localRequest } from '../host/bridge/local-ipc.mjs';

const project = new URL('../', import.meta.url).pathname;
const provider = new URL('./offline-provider.ts', import.meta.url).pathname;
const interactions = new URL('./interaction-fixture.ts', import.meta.url).pathname;
const pi = process.env.PI_BIN || 'pi';
const runtimeArgs = ['--offline', '--no-tools', '--no-mcp', '--no-approve', '--no-skills', '--no-context-files',
  '--provider', 'pi-go-test', '--model', 'fixture'];

const pidOf = (socket) => Number(/(?:^|\/)w-(\d+)-/.exec(socket)?.[1]);

async function seedSession(agentDir, cwd, env, text) {
  const child = spawn(pi, ['--mode', 'rpc', ...runtimeArgs], { cwd, env });
  const events = [];
  let failure = '';
  child.stderr.setEncoding('utf8').on('data', (data) => { failure += data; });
  createInterface({ input: child.stdout }).on('line', (line) => { try { events.push(JSON.parse(line)); } catch {} });
  const wait = async (predicate) => {
    for (let i = 0; i < 300; i++) {
      const found = events.find(predicate);
      if (found) return found;
      if (child.exitCode !== null) break;
      await new Promise((resolve) => setTimeout(resolve, 30));
    }
    throw new Error('Seed runtime failed: ' + failure);
  };
  child.stdin.write(JSON.stringify({ type: 'prompt', id: 'seed', message: text }) + '\n');
  await wait((event) => event.type === 'agent_settled');
  child.stdin.write(JSON.stringify({ type: 'get_state', id: 'state' }) + '\n');
  const state = (await wait((event) => event.type === 'response' && event.id === 'state')).data;
  const exited = once(child, 'exit');
  child.stdin.end();
  await exited;
  return state;
}

test('daemon host serves native open, new, interactions and close', { timeout: 300000 }, async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-daemon-'));
  const agent = join(root, 'agent'), ipc = join(root, 'ipc');
  const first = join(root, 'project-a'), second = join(root, 'project-b');
  await Promise.all([agent, ipc, first, second].map((path) => mkdir(path, { mode: 0o700 })));
  const titleLog = join(root, 'title-requests.jsonl');
  const env = { ...process.env, PI_CODING_AGENT_DIR: agent, PIGO_IPC_DIR: ipc, PI_OFFLINE: '1', PIGO_TITLE_FIXTURE_LOG: titleLog };
  await promisify(execFile)(pi, ['install', project], { cwd: first, env });
  let settings = {};
  for (let attempt = 0; attempt < 30; attempt++) {
    try { settings = JSON.parse(await readFile(join(agent, 'settings.json'), 'utf8')); break; }
    catch { await new Promise((resolve) => setTimeout(resolve, 100)); }
  }
  assert.equal(Array.isArray(settings.packages), true, 'pi install must register the Pi Go package');
  settings.extensions = [provider, interactions];
  await writeFile(join(agent, 'settings.json'), JSON.stringify(settings));

  const a = await seedSession(agent, first, env, 'History from project A');
  const b = await seedSession(agent, second, env, 'History from project B');
  const entries = (await readFile(b.sessionFile, 'utf8')).trimEnd().split('\n').map((line) => JSON.parse(line));
  let parentId = entries.at(-1).id;
  const timestamp = new Date().toISOString();
  const extraHistory = Array.from({ length: 64 }, (_, index) => {
    const id = (0x12300000 + index).toString(16);
    const entry = { type: 'message', id, parentId, timestamp, message: {
      role: 'user', content: [{ type: 'text', text: `Project B message ${index + 1}` }], timestamp: Date.now(),
    } };
    parentId = id;
    return JSON.stringify(entry);
  });
  await appendFile(b.sessionFile, extraHistory.join('\n') + '\n');

  const children = [];
  context.after(async () => {
    for (const child of children) { if (child.exitCode === null) child.kill('SIGTERM'); }
    await new Promise((resolve) => setTimeout(resolve, 500));
    await rm(root, { recursive: true, force: true });
  });

  const daemon = spawn(process.execPath, [join(project, 'host/daemon/daemon.mjs')], {
    env: { ...env, HOME: root, PIGO_PI_ARGS: JSON.stringify(runtimeArgs) }, stdio: ['ignore', 'ignore', 'pipe'] });
  children.push(daemon);
  let logs = '';
  daemon.stderr.setEncoding('utf8').on('data', (data) => { logs = (logs + data).slice(-6000); });

  const hostSocket = join(ipc, `host-${daemon.pid}.sock`);
  let health;
  for (let i = 0; i < 100; i++) {
    health = await localRequest(hostSocket, 'GET', '/health', undefined, 500).catch(() => undefined);
    if (health?.status === 200) break;
    if (daemon.exitCode !== null) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(health?.status, 200, logs);
  assert.equal(health.data.protocol, 'pi-go-desktop-host/1');
  const profile = health.data.profile;
  assert.match(profile, /^[0-9a-f]{64}$/);

  // Opening a foreign session in an unregistered project is refused first.
  assert.equal((await localRequest(hostSocket, 'POST', '/open', { cwd: first, id: b.sessionId })).status, 403);
  const opened = await localRequest(hostSocket, 'POST', '/open', { cwd: first, id: a.sessionId }, 20000);
  assert.equal(opened.status, 200, JSON.stringify(opened));
  assert.equal(opened.data.id, a.sessionId);
  assert.deepEqual((await localRequest(hostSocket, 'POST', '/workspaces', {})).data.workspaces, []);
  assert.equal((await localRequest(hostSocket, 'POST', '/authorize', { cwd: first })).status, 200);

  const workerSockets = async () => (await readdir(ipc)).filter((name) => /^w-/.test(name)).map((name) => join(ipc, name));
  let firstWorker;
  for (let i = 0; i < 60 && !firstWorker; i++) {
    const chats = await Promise.all((await workerSockets()).map(async (socket) =>
      ({ socket, result: await localRequest(socket, 'GET', '/chat', undefined, 4000).catch(() => undefined) })));
    firstWorker = chats.find(({ result }) => result?.status === 200 && result.data.session?.id === a.sessionId)?.socket;
    if (!firstWorker) await new Promise((resolve) => setTimeout(resolve, 200));
  }
  assert.ok(firstWorker, 'the shared worker socket must appear after host /open');
  const firstChat = await localRequest(firstWorker, 'GET', '/chat');
  assert.equal(firstChat.data.session.id, a.sessionId);
  assert.equal(firstChat.data.messages.some((message) => message.text === 'History from project A'), true);
  const runtimePid = pidOf(firstWorker);

  // Unknown history in a registered project is a 404, not a trust failure.
  assert.equal((await localRequest(hostSocket, 'POST', '/open', { cwd: first, id: '00000000-0000-4000-8000-000000000000' })).status, 404);

  assert.equal((await localRequest(hostSocket, 'POST', '/authorize', { cwd: second })).status, 200);
  const created = await localRequest(hostSocket, 'POST', '/new', { cwd: second }, 20000);
  assert.equal(created.status, 200, JSON.stringify(created));
  assert.equal(typeof created.data.id, 'string');
  assert.notEqual(created.data.id, b.sessionId);
  let secondWorker;
  for (let i = 0; i < 60 && !secondWorker; i++) {
    const chats = await Promise.all((await workerSockets()).map(async (socket) =>
      ({ socket, result: await localRequest(socket, 'GET', '/chat', undefined, 4000).catch(() => undefined) })));
    secondWorker = chats.find(({ result }) => result?.status === 200 && result.data.session?.id === created.data.id)?.socket;
    if (!secondWorker) await new Promise((resolve) => setTimeout(resolve, 200));
  }
  assert.ok(secondWorker, 'the new session must be shared with a worker socket');

  const catalog = await localRequest(hostSocket, 'POST', '/catalog', { cwd: first });
  assert.equal(catalog.status, 200);
  assert.equal(catalog.data.sessions.some((row) => row.id === a.sessionId), true);
  assert.equal(catalog.data.sessions.some((row) => row.id === b.sessionId), false);
  const projects = await localRequest(hostSocket, 'POST', '/projects', {});
  assert.deepEqual(new Set(projects.data.projects), new Set([first, second]));

  // Extension UI requests flow from the RPC event stream to /pending, and
  // answers return through extension_ui_response — the phone interaction path.
  const prompt = (worker, session, text, requestId) =>
    localRequest(worker, 'POST', '/prompt', { id: session, requestId, text }, 8000);
  const waitIdle = async (worker) => {
    for (let i = 0; i < 150; i++) {
      const result = await localRequest(worker, 'GET', '/session', undefined, 2000).catch(() => undefined);
      if (result?.status === 200 && result.data.session?.idle && !result.data.session.queued) return;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error('runtime never became idle');
  };
  const pendingFor = async () => {
    for (let i = 0; i < 100; i++) {
      const result = await localRequest(hostSocket, 'POST', '/pending', { id: a.sessionId, pid: runtimePid }, 700)
        .catch(() => undefined);
      if (result?.status === 200 && result.data.interaction) return result.data.interaction;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error('no interaction surfaced on /pending');
  };

  await waitIdle(firstWorker);
  const uiPrompt = await prompt(firstWorker, a.sessionId, 'Pi Go fixture: ask for confirmation', 'ui-confirm');
  assert.equal(uiPrompt.status, 202);
  const confirm = await pendingFor();
  assert.equal(confirm.method, 'confirm');
  assert.equal(confirm.title, 'Pi Go interaction fixture');
  // Wrong answer types are rejected and the interaction stays pending.
  assert.equal((await localRequest(hostSocket, 'POST', '/answer',
    { id: a.sessionId, pid: runtimePid, pendingId: confirm.id, answer: 'yes' })).status, 409);
  assert.equal((await localRequest(hostSocket, 'POST', '/answer',
    { id: a.sessionId, pid: runtimePid, pendingId: confirm.id, answer: true })).status, 200);

  await waitIdle(firstWorker);
  assert.equal((await prompt(firstWorker, a.sessionId, 'Pi Go fixture: ask for text', 'ui-text')).status, 202);
  const input = await pendingFor();
  assert.equal(input.method, 'input');
  assert.equal((await localRequest(hostSocket, 'POST', '/answer',
    { id: a.sessionId, pid: runtimePid, pendingId: input.id, answer: 'multi\nline' })).status, 409);
  assert.equal((await localRequest(hostSocket, 'POST', '/answer',
    { id: a.sessionId, pid: runtimePid, pendingId: input.id, answer: 'fixture answer' })).status, 200);
  const editor = await pendingFor();
  assert.equal(editor.method, 'editor');
  assert.deepEqual(editor.prefill, '  first line\nsecond line\n');
  assert.equal((await localRequest(hostSocket, 'POST', '/answer',
    { id: a.sessionId, pid: runtimePid, pendingId: editor.id, answer: '  first line\nsecond line\n' })).status, 200);
  for (let i = 0; i < 50; i++) {
    try {
      const result = JSON.parse((await readFile(join(first, 'pi-go-fixture-result.jsonl'), 'utf8')).trim());
      assert.equal(result.inputMatches, true);
      assert.equal(result.editorMatches, true);
      break;
    } catch { await new Promise((resolve) => setTimeout(resolve, 100)); }
  }
  assert.deepEqual(JSON.parse((await readFile(join(first, 'pi-go-fixture-result.jsonl'), 'utf8')).trim()),
    { inputMatches: true, editorMatches: true });

  // Pending queries for dead or foreign runtimes are refused.
  assert.equal((await localRequest(hostSocket, 'POST', '/pending', { id: a.sessionId, pid: 999999 })).status, 409);

  // Closing a workspace stops its runtimes, deregisters it, keeps the files.
  assert.equal((await stat(second)).isDirectory(), true);
  const closed = await localRequest(hostSocket, 'POST', '/close-workspace', { cwd: second }, 20000);
  assert.equal(closed.status, 200, JSON.stringify(closed));
  assert.deepEqual(closed.data, { closed: true, cwd: second });
  await new Promise((resolve) => setTimeout(resolve, 500));
  const afterClose = await localRequest(hostSocket, 'POST', '/projects', {});
  assert.deepEqual(new Set(afterClose.data.projects), new Set([first]));
  assert.equal((await localRequest(hostSocket, 'POST', '/close-workspace', { cwd: second })).status, 404);
  assert.equal((await stat(second)).isDirectory(), true);
  // The first runtime keeps serving its workspace after another was closed.
  assert.equal((await localRequest(firstWorker, 'GET', '/chat', undefined, 4000).catch(() => undefined))?.status, 200);

  // Phone end-to-end: pair, list, open, chat, and manage a workspace through the broker.
  const reservation = (await import('node:net')).createServer().listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await promisify(reservation.close.bind(reservation))();
  const broker = spawn(process.execPath, [join(project, 'host/bridge/broker.mjs'), String(port)], { env, stdio: 'ignore' });
  children.push(broker);
  const admin = join(ipc, `bridge-${port}.sock`);
  let ticket;
  for (let i = 0; i < 60 && !ticket; i++) {
    const enabled = await localRequest(admin, 'POST', '/computer-access').catch(() => undefined);
    if (enabled?.status === 200) ticket = await localRequest(admin, 'POST', '/ticket');
    else await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(ticket?.status, 200, 'broker must start and accept computer access');
  const pairing = JSON.parse(await readFile(ticket.data.file, 'utf8'));
  const paired = await fetch(pairing.url + '/pair', { method: 'POST', signal: AbortSignal.timeout(8000),
    headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ticket: pairing.code }) });
  const { token } = await paired.json();
  const phone = async (path, value) => {
    const response = await fetch(pairing.url + path, { method: value ? 'POST' : 'GET', signal: AbortSignal.timeout(20000),
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: value ? JSON.stringify(value) : undefined });
    return { status: response.status, data: await response.json() };
  };
  const directory = await phone('/sessions');
  assert.equal(directory.data.sessions.some((row) => row.id === a.sessionId), true);
  const openedByPhone = await phone('/open', { id: a.sessionId });
  assert.equal(openedByPhone.status, 200, JSON.stringify(openedByPhone));
  const phoneChat = await phone('/chat');
  assert.equal(phoneChat.data.session.id, a.sessionId);
  assert.equal(phoneChat.data.messages.some((message) => message.text === 'History from project A'), true);

  const firstReply = phoneChat.data.messages.at(-1);
  await waitIdle(firstWorker);
  const regenerated = await phone('/regenerate', { id: a.sessionId, messageId: firstReply.id });
  assert.equal(regenerated.status, 202, JSON.stringify(regenerated));
  await waitIdle(firstWorker);
  const regeneratedChat = (await phone('/chat')).data;
  assert.equal(regeneratedChat.session.id, a.sessionId);
  assert.deepEqual(regeneratedChat.messages.map(({ role }) => role), ['user', 'assistant']);
  assert.equal(regeneratedChat.messages[0].text, 'History from project A');
  const nextReply = regeneratedChat.messages.at(-1);
  assert.notEqual(nextReply.id, firstReply.id);
  assert.equal((await phone('/fork', { id: a.sessionId, messageId: firstReply.id })).status, 404);

  assert.equal((await phone('/prompt', { id: a.sessionId, requestId: 'after-fork-point', text: 'A later message' })).status, 202);
  await waitIdle(firstWorker);
  assert.equal((await phone('/regenerate', { id: a.sessionId, messageId: nextReply.id })).data.error, 'reply_not_latest');
  const branched = await phone('/fork', { id: a.sessionId, messageId: nextReply.id, history: true });
  assert.equal(branched.status, 200, JSON.stringify(branched));
  assert.notEqual(branched.data.session.id, a.sessionId);
  assert.equal(branched.data.session.cwd, first);
  assert.deepEqual(branched.data.messages.map(({ id }) => id), regeneratedChat.messages.map(({ id }) => id));
  assert.equal((await phone('/session')).data.session.id, branched.data.session.id);
  assert.equal((await phone('/open', { id: a.sessionId })).status, 200);
  assert.ok((await phone('/chat')).data.messages.some(({ text }) => text === 'A later message'));

  await waitIdle(firstWorker);
  await writeFile(join(first, 'existing.txt'), 'unchanged pre-existing edit\n');
  await writeFile(join(first, 'example.txt'), 'old content\n');
  const runPrompt = await phone('/prompt', { id: a.sessionId, requestId: 'result-test', text: 'Pi Go fixture: long Markdown' });
  assert.equal(runPrompt.status, 202);
  let liveRunId;
  for (let i = 0; i < 20 && !liveRunId; i++) {
    liveRunId = (await phone('/session/snapshot')).data.session?.runId;
    if (!liveRunId) await new Promise((resolve) => setTimeout(resolve, 30));
  }
  assert.ok(liveRunId);
  await writeFile(join(first, 'example.txt'), 'new content\n');
  await writeFile(join(first, 'report.md'), '# Run report\n');

  let results;
  for (let i = 0; i < 80; i++) {
    results = await phone(`/runs/results?session=${a.sessionId}`);
    if (results.data.runEvents?.some(({ id }) => id === liveRunId)) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(results.status, 200);
  const reviewed = results.data.runEvents.find(({ id }) => id === liveRunId);
  assert.equal(reviewed?.status, 'completed');
  assert.ok((await phone('/chat')).data.messages.some(({ id }) => id === reviewed.messageId));
  assert.equal(reviewed.files.some(({ path }) => path === 'existing.txt'), false);
  assert.ok(reviewed.files.some(({ path, artifact }) => path === 'report.md' && artifact));
  const reviewedPath = `/runs/diff?session=${a.sessionId}&run=${reviewed.id}&path=example.txt`;
  assert.equal((await fetch(`${pairing.url}${reviewedPath}`)).status, 401);
  const patch = await phone(reviewedPath);
  assert.match(patch.data.text, /-old content\n\+new content/);
  assert.equal((await phone(reviewedPath.replace(a.sessionId, b.sessionId))).status, 404);
  const inboxResult = (await phone('/runs/inbox')).data.runEvents.find(({ id }) => id === reviewed.id);
  assert.equal(inboxResult.hasFullResult, true);
  assert.match(inboxResult.summary, /^# 长回复/);
  assert.equal(inboxResult.summary.length, 500);
  const resultPath = `/runs/text?session=${a.sessionId}&run=${reviewed.id}`;
  assert.equal((await fetch(`${pairing.url}${resultPath}`)).status, 401);
  assert.equal((await phone(resultPath.replace(a.sessionId, b.sessionId))).status, 404);
  const firstPage = await phone(resultPath);
  assert.equal(firstPage.status, 200);
  assert.equal(firstPage.data.nextTextOffset, firstPage.data.text.length);
  const lastPage = await phone(`${resultPath}&offset=${firstPage.data.nextTextOffset}`);
  assert.equal(lastPage.status, 200);
  assert.equal(lastPage.data.nextTextOffset, undefined);
  assert.equal(firstPage.data.text + lastPage.data.text, '# 长回复\n\n```txt\n' + 'a'.repeat(131057) + '🚀\n```\n\n最后一段');

  await waitIdle(firstWorker);
  assert.equal((await prompt(firstWorker, a.sessionId, 'Pi Go fixture: ask for confirmation', 'inbox-pending')).status, 202);
  const waiting = await pendingFor();
  const inbox = await phone('/runs/inbox');
  const pendingRow = inbox.data.runEvents.find(({ pendingId }) => pendingId === waiting.id);
  assert.equal(pendingRow?.status, 'waiting');
  assert.ok(pendingRow.finishedAt > 0);
  assert.equal((await phone('/answer', { id: a.sessionId, pendingId: waiting.id, answer: true })).status, 200);
  assert.equal((await phone('/runs/inbox')).data.runEvents.some(({ id }) => id === pendingRow.id), false);

  // Both restored history and an already-running session can return a first page on open.
  for (const [id, text] of [[b.sessionId, 'Project B message 64'], [a.sessionId, 'History from project A']]) {
    const opened = await phone('/open', { id, history: true });
    assert.equal(opened.status, 200, JSON.stringify(opened));
    assert.equal(opened.data.session.id, id);
    assert.equal(opened.data.cursor?.sessionId, id);
    assert.ok(opened.data.messages.some((message) => message.text === text));
    const snapshot = await phone('/session/snapshot');
    assert.equal(opened.data.cursor.streamId, snapshot.data.cursor.streamId);
    assert.equal(opened.data.historyLeaf, snapshot.data.historyLeaf);
    if (id === b.sessionId) {
      assert.equal(opened.data.messages.length, 60);
      assert.equal(opened.data.messages[0].text, 'Project B message 5');
      assert.equal(opened.data.historyCursor, opened.data.messages[0].id);
      const earlier = await phone(`/history?id=${id}&before=${opened.data.historyCursor}&sync=2`);
      assert.equal(earlier.status, 200, JSON.stringify(earlier));
      assert.equal(earlier.data.messages.at(-1).text, 'Project B message 4');
      assert.ok(earlier.data.messages.some(({ text }) => text === 'History from project B'));
      assert.equal(earlier.data.historyCursor, undefined);
    }
  }

  const scheduledAt = Date.now() + 2200;
  assert.equal((await phone('/schedules/update', {
    cwd: root, operation: 'create', kind: 'once', name: 'Unshared schedule', prompt: 'Summarize', at: scheduledAt, catchUp: 0
  })).status, 403);
  const scheduled = await phone('/schedules/update', {
    cwd: first, operation: 'create', kind: 'once', name: 'Daily digest', prompt: 'Summarize the workspace',
    at: scheduledAt, catchUp: 0
  });
  assert.equal(scheduled.status, 200, JSON.stringify(scheduled));
  let scheduleSnapshot;
  for (let i = 0; i < 80; i++) {
    scheduleSnapshot = (await phone('/schedules/sync', { includeJobs: true })).data;
    if (scheduleSnapshot.runs?.length) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const [scheduledRun] = scheduleSnapshot.runs;
  assert.equal(scheduledRun.status, 'succeeded', JSON.stringify(scheduledRun));
  assert.equal(scheduledRun.summary, 'fixture delta');
  assert.equal(scheduledRun.hasFullResult, true);
  const resultInput = { cwd: first, id: scheduledRun.id, source: scheduleSnapshot.source };
  const scheduledResult = await phone('/schedules/result', resultInput);
  assert.equal(scheduledResult.status, 200);
  assert.equal(scheduledResult.data.text, 'fixture delta');
  assert.equal((await phone('/schedules/result', { ...resultInput, cwd: root })).status, 403);
  assert.equal(scheduleSnapshot.jobs[0].nextAt, null);
  assert.equal(scheduleSnapshot.watching, true);
  assert.equal((await phone('/schedules/sync', { knownRuns: [scheduledRun.id] })).data.watching, false);
  assert.equal((await phone('/chat')).data.session.id, a.sessionId);
  const scheduledChat = await phone('/open', { id: scheduledRun.sessionId, history: true });
  assert.equal(scheduledChat.status, 200, JSON.stringify(scheduledChat));
  assert.ok(scheduledChat.data.messages.some(({ text }) => text === 'Summarize the workspace'));
  const scheduledResults = await phone(`/runs/results?session=${scheduledRun.sessionId}`);
  assert.equal(scheduledResults.data.runEvents[0]?.scheduled, true);
  assert.equal((await phone('/runs/inbox')).data.runEvents.some(({ sessionId }) => sessionId === scheduledRun.sessionId), false);

  assert.equal((await phone('/schedules/update', {
    cwd: root, operation: 'delete-run', id: scheduledRun.id
  })).status, 403);
  const deletedRun = await phone('/schedules/update', {
    cwd: first, operation: 'delete-run', id: scheduledRun.id
  });
  assert.equal(deletedRun.status, 200, JSON.stringify(deletedRun));
  assert.deepEqual(deletedRun.data, { deleted: true });
  assert.deepEqual((await phone('/schedules/sync', { includeJobs: false })).data.runs, []);

  const newChat = await phone('/new', { cwd: first, agent: 'pi' });
  assert.equal(newChat.status, 200, JSON.stringify(newChat));
  assert.equal(newChat.data.session.agent ?? 'pi', 'pi');
  const { id: titledId } = newChat.data.session;
  const promptText = '排查手机切到后台后收不到消息';
  assert.equal((await phone('/prompt', { id: titledId, requestId: 'title-first', text: promptText })).status, 202);
  let titledChat;
  for (let i = 0; i < 60; i++) {
    titledChat = (await phone('/chat')).data;
    if (titledChat.session.idle && titledChat.messages.length === 2) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(titledChat.session.id, titledId);
  assert.equal(titledChat.session.name, `标题 ${promptText}`);
  assert.deepEqual(titledChat.messages.map(({ role, text }) => [role, text]), [['user', promptText], ['assistant', 'fixture delta']]);
  assert.deepEqual((await readFile(titleLog, 'utf8')).trim().split('\n').map(JSON.parse),
    [{ text: promptText, messages: 1, tools: 0, model: 'fixture' }]);
  const afterTitle = (await phone('/sessions')).data.sessions;
  assert.equal(afterTitle.find(({ id }) => id === titledId)?.name, `标题 ${promptText}`);
  assert.deepEqual(new Set(afterTitle.map(({ id }) => id)),
    new Set([...directory.data.sessions.map(({ id }) => id), branched.data.session.id, scheduledRun.sessionId, titledId]));
  await phone('/open', { id: a.sessionId });
  const reopened = await phone('/open', { id: titledId, history: true });
  assert.equal(reopened.data.session.name, `标题 ${promptText}`);

  const space = { name: '测试 空间' };
  const spacePath = join(root, 'Pi Go', 'Spaces', space.name);
  assert.deepEqual(await phone('/create-workspace', { name: '../outside' }),
    { status: 400, data: { error: 'invalid_workspace_name' } });
  assert.deepEqual(await phone('/create-workspace', space), { status: 200, data: { cwd: spacePath } });
  assert.deepEqual(await phone('/create-workspace', space),
    { status: 409, data: { error: 'workspace_exists' } });
  assert.ok((await phone('/sessions')).data.projects.includes(spacePath));
  assert.deepEqual(await phone('/close-workspace', { cwd: spacePath }), { status: 200, data: { closed: true } });
  assert.ok(!(await phone('/sessions')).data.projects.includes(spacePath));
  assert.ok((await stat(spacePath)).isDirectory());
  await localRequest(admin, 'POST', '/stop').catch(() => {});

  // The daemon refuses to co-exist with another live host socket.
  const duplicate = spawn(process.execPath, [join(project, 'host/daemon/daemon.mjs')], {
    env: { ...env, PIGO_PI_ARGS: JSON.stringify(runtimeArgs) }, stdio: ['ignore', 'ignore', 'pipe'] });
  children.push(duplicate);
  const duplicateExit = await once(duplicate, 'exit');
  assert.notEqual(duplicateExit[0], 0, 'second daemon must exit');

  daemon.kill('SIGTERM');
  await once(daemon, 'exit');
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal((await readdir(ipc)).includes(`host-${daemon.pid}.sock`), false, 'host socket removed on shutdown');
});
