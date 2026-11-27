// End-to-end integration test for Codex CLI support in Pi Go:
//   - native rollout history scanning in CODEX_HOME/sessions
//   - daemon host /health.agents, /catalog, /open, /new with agent: 'codex'
//   - broker /sessions listing mixed Pi + Codex history with agent field
//   - phone-side flow through broker: open Codex history, start new Codex
//     session, streaming SSE events (thinking, tool execution, message delta,
//     final), model & effort switching, skill commands, steer, interrupt,
//     approval interaction over worker /pending + /answer, rename, and fork.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { chmod, mkdir, mkdtemp, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { codexComputerSessions } from '../host/agents/codex/catalog.mjs';
import { localRequest } from '../host/bridge/local-ipc.mjs';

const project = new URL('../', import.meta.url).pathname;
const fakeCodex = new URL('./fake-codex.mjs', import.meta.url).pathname;

async function reservePort() {
  const server = createServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function seedCodexRollout(codexHome, cwd, id, title, userPrompt, assistantReply) {
  const dir = join(codexHome, 'sessions', '2026', '11', '24');
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const file = join(dir, `rollout-2026-11-24T00-00-00-${id}.jsonl`);
  const lines = [
    {
      timestamp: '2026-11-24T00:00:00.000Z',
      ordinal: 0,
      type: 'session_meta',
      payload: { id, session_id: id, cwd },
    },
    {
      timestamp: '2026-11-24T00:00:01.000Z',
      type: 'event_msg',
      payload: { type: 'user_message', id: `u-${id}`, message: userPrompt },
    },
    {
      timestamp: '2026-11-24T00:00:02.000Z',
      type: 'response_item',
      payload: {
        type: 'message',
        id: `a-${id}`,
        role: 'assistant',
        content: [{ type: 'output_text', text: assistantReply }],
      },
    },
  ];
  await writeFile(file, `${lines.map((l) => JSON.stringify(l)).join('\n')}\n`);
  if (title) {
    await writeFile(
      join(codexHome, 'session_index.jsonl'),
      `${JSON.stringify({ id, thread_name: title, updated_at: '2026-11-24T00:00:03.000Z' })}\n`,
      { flag: 'a' },
    );
  }
  return file;
}

test('Codex CLI sessions work end-to-end through daemon and broker', { timeout: 60000 }, async (context) => {
  await chmod(fakeCodex, 0o755);
  const root = await realpath(await mkdtemp('/private/tmp/pigo-codex-'));
  const agentDir = join(root, 'pi-agent');
  const codexDir = join(root, 'codex-home');
  const ipc = join(root, 'ipc');
  const workspace = join(root, 'workspace');
  await Promise.all([agentDir, codexDir, ipc, workspace].map((p) => mkdir(p, { recursive: true, mode: 0o700 })));
  await writeFile(join(codexDir, 'auth.json'), '{}');

  const seededId = '01a206c9-eef1-7d53-ba63-ed447ac58d7f';
  const lockedId = '01a206c9-eef1-7d53-ba63-ed447ac58d88';
  const seededRollout = await seedCodexRollout(codexDir, workspace, seededId, '已有 Codex 会话', '第一轮提问', '第一轮回答');
  await seedCodexRollout(codexDir, workspace, lockedId, '桌面锁定 Codex 会话', '桌面提问', '桌面回答');

  const env = {
    ...process.env,
    HOME: root,
    PI_CODING_AGENT_DIR: agentDir,
    CODEX_HOME: codexDir,
    PIGO_IPC_DIR: ipc,
    PIGO_CODEX_BIN: fakeCodex,
    FAKE_CODEX_LOCKED_ID: lockedId,
  };

  const children = [];
  context.after(async () => {
    for (const child of children) {
      if (child.exitCode === null) child.kill('SIGTERM');
    }
    await new Promise((r) => setTimeout(r, 300));
    await rm(root, { recursive: true, force: true });
  });

  const daemon = spawn(process.execPath, [join(project, 'host/daemon/daemon.mjs')], {
    env,
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  children.push(daemon);
  let daemonErr = '';
  daemon.stderr.setEncoding('utf8').on('data', (d) => { daemonErr = (daemonErr + d).slice(-4000); });

  const hostSocket = join(ipc, `host-${daemon.pid}.sock`);
  let health;
  for (let i = 0; i < 60; i += 1) {
    health = await localRequest(hostSocket, 'GET', '/health', undefined, 500).catch(() => undefined);
    if (health?.status === 200) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.equal(health?.status, 200, daemonErr);
  assert.equal(Array.isArray(health.data.agents), true);
  assert.equal(health.data.agents.some((a) => a.id === 'codex'), true);
  const authorized = await localRequest(hostSocket, 'POST', '/authorize', { cwd: workspace });
  assert.equal(authorized.status, 200, JSON.stringify(authorized));

  const port = await reservePort();
  const broker = spawn(process.execPath, [join(project, 'host/bridge/broker.mjs'), String(port)], {
    env,
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  children.push(broker);
  const admin = join(ipc, `bridge-${port}.sock`);
  let ticket;
  for (let i = 0; i < 60 && !ticket; i += 1) {
    ticket = await localRequest(admin, 'POST', '/ticket').catch(() => undefined);
    if (!ticket) await new Promise((r) => setTimeout(r, 50));
  }
  assert.equal(ticket?.status, 200);
  await localRequest(admin, 'POST', '/computer-access');

  const pairConfig = JSON.parse(await readFile(ticket.data.file, 'utf8'));
  const pairRes = await fetch(`${pairConfig.url}/pair`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ticket: pairConfig.ticket }),
  });
  const { token } = await pairRes.json();
  const headers = { authorization: `Bearer ${token}` };
  const get = async (path) => {
    const res = await fetch(`${pairConfig.url}${path}`, { headers });
    return { status: res.status, data: await res.json() };
  };
  const post = async (path, body) => {
    const res = await fetch(`${pairConfig.url}${path}`, {
      method: 'POST',
      headers: { ...headers, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    return { status: res.status, data: await res.json() };
  };

  // 1. /sessions lists the native Codex rollout with agent: 'codex'.
  const list1 = await get('/sessions');
  assert.equal(list1.status, 200);
  const codexRow = list1.data.sessions.find((s) => s.id === seededId);
  assert.ok(codexRow, 'expected seeded Codex session in /sessions');
  assert.equal(codexRow.agent, 'codex');
  assert.equal(codexRow.name, '已有 Codex 会话');
  assert.equal(codexRow.cwd, workspace);

  // 2. Open the existing Codex session via POST /open.
  const opened = await post('/open', { id: seededId, history: true });
  assert.equal(opened.status, 200, JSON.stringify(opened));
  assert.equal(opened.data.session.id, seededId);
  assert.equal(opened.data.session.agent, 'codex');
  assert.equal(opened.data.session.permission, 'bypass');
  assert.equal(opened.data.messages.length, 2);
  assert.equal(opened.data.messages[0].text, '第一轮提问');
  assert.equal(opened.data.messages[1].text, '第一轮回答');

  const workspaceSessions = '/sessions?scope=workspace&cwd=' + encodeURIComponent(workspace);
  const activeList = await get(workspaceSessions);
  assert.equal(activeList.status, 200, JSON.stringify(activeList));
  assert.equal(activeList.data.sessions.find(({ id }) => id === seededId)?.active, true);
  const archiveDir = join(codexDir, 'archived_sessions');
  await mkdir(archiveDir);
  const archivedRollout = join(archiveDir, basename(seededRollout));
  await rename(seededRollout, archivedRollout);
  for (const query of ['', '&refresh=1']) {
    const archivedList = await get(workspaceSessions + query);
    assert.equal(archivedList.status, 200);
    assert.ok(archivedList.data.sessions.some(({ id }) => id === lockedId));
    assert.ok(!archivedList.data.sessions.some(({ id }) => id === seededId),
      'a live worker must not keep a Codex-archived thread in the sidebar');
  }
  await rename(archivedRollout, seededRollout);
  const restoredList = await get(workspaceSessions);
  assert.equal(restoredList.data.sessions.find(({ id }) => id === seededId)?.active, true);

  // 3. Send a prompt and wait for completion + tool execution + thinking.
  const sent = await post('/prompt', {
    id: seededId,
    requestId: 'req-codex-1',
    text: '你好 Codex',
    mode: 'send',
  });
  assert.equal(sent.status, 202);

  let chat;
  for (let i = 0; i < 60; i += 1) {
    chat = (await get('/chat')).data;
    if (chat.session?.idle && chat.messages?.length >= 4) break;
    await new Promise((r) => setTimeout(r, 80));
  }
  assert.equal(chat.session.idle, true);
  const lastMsg = chat.messages.at(-1);
  assert.equal(lastMsg.role, 'assistant');
  assert.equal(lastMsg.text, 'Codex 回复: 你好 Codex');
  assert.equal(lastMsg.thinking, '分析请求并执行任务');
  assert.equal(lastMsg.tools?.length, 1);
  assert.equal(lastMsg.tools[0].name, 'bash');
  assert.equal(lastMsg.tools[0].state, 'ok');

  // Tool detail endpoint works for the Codex commandExecution item.
  const detail = await get(`/tool-detail?id=${seededId}&tool=${encodeURIComponent(lastMsg.tools[0].id)}&message=${encodeURIComponent(lastMsg.id)}`);
  assert.equal(detail.status, 200);
  assert.equal(detail.data.toolDetail.command, true);
  assert.equal(detail.data.toolDetail.input, 'git status --short');
  assert.match(detail.data.toolDetail.output, /README\.md/);

  // 4. Models and commands (skills).
  const models = await get('/models');
  assert.equal(models.status, 200);
  assert.equal(models.data.models.some((m) => m.id === 'o3-pro'), true);
  const switched = await post('/model', { id: seededId, provider: 'openai', modelId: 'o3-pro', thinkingLevel: 'high' });
  assert.equal(switched.status, 200);
  assert.equal(switched.data.current.id, 'o3-pro');
  assert.equal(switched.data.current.thinkingLevel, 'high');

  const commands = await get('/commands');
  assert.equal(commands.status, 200);
  assert.equal(commands.data.commands.some((c) => c.name === 'skill:review'), true);

  // 5. Rename and Fork.
  const renamed = await post('/rename', { id: seededId, name: '改名后的 Codex 会话' });
  assert.equal(renamed.status, 200);
  assert.equal(renamed.data.session.name, '改名后的 Codex 会话');

  const forked = await post('/fork', { id: seededId, messageId: lastMsg.id, history: true });
  assert.equal(forked.status, 200, JSON.stringify(forked));
  assert.notEqual(forked.data.session.id, seededId);
  assert.equal(forked.data.session.agent, 'codex');
  assert.match(forked.data.session.name, /（分支）$/);

  // 6. Create a brand new Codex session via POST /new with agent: 'codex'.
  const created = await post('/new', { cwd: workspace, agent: 'codex' });
  assert.equal(created.status, 200, JSON.stringify(created));
  const newId = created.data.session.id;
  assert.equal(created.data.session.agent, 'codex');

  // 7. Approval request roundtrip via worker /pending and broker /answer.
  const approvalPrompt = await post('/prompt', {
    id: newId,
    requestId: 'req-approval-1',
    text: '请清理构建目录 [approval]',
    mode: 'send',
  });
  assert.equal(approvalPrompt.status, 202);

  let pendingChat;
  for (let i = 0; i < 60; i += 1) {
    pendingChat = (await get('/chat')).data;
    if (pendingChat.interaction) break;
    await new Promise((r) => setTimeout(r, 60));
  }
  assert.ok(pendingChat?.interaction, 'expected pending approval interaction');
  assert.equal(pendingChat.interaction.method, 'select');
  assert.equal(pendingChat.interaction.kind, 'approval');

  const answered = await post('/answer', {
    id: newId,
    pendingId: pendingChat.interaction.id,
    answer: '拒绝',
  });
  assert.equal(answered.status, 200);

  for (let i = 0; i < 60; i += 1) {
    pendingChat = (await get('/chat')).data;
    if (pendingChat.session?.idle && pendingChat.messages?.length >= 2) break;
    await new Promise((r) => setTimeout(r, 60));
  }
  assert.equal(pendingChat.messages.at(-1).text, '命令已被用户拒绝。');

  // 8. A desktop-locked Codex thread opens in read-only mode, reports session_occupied on prompt,
  // and supports one-tap fork-and-continue without messageId.
  const openedLocked = await post('/open', { id: lockedId, history: true });
  assert.equal(openedLocked.status, 200, JSON.stringify(openedLocked));
  assert.equal(openedLocked.data.session.id, lockedId);
  assert.equal(openedLocked.data.messages.length, 2);

  const lockedPrompt = await post('/prompt', {
    id: lockedId,
    requestId: 'req-locked-1',
    text: '尝试写入桌面锁定会话',
    mode: 'send',
  });
  assert.equal(lockedPrompt.status, 409);
  assert.equal(lockedPrompt.data.error, 'session_occupied');

  const autoForked = await post('/fork', { id: lockedId, history: true });
  assert.equal(autoForked.status, 200, JSON.stringify(autoForked));
  assert.notEqual(autoForked.data.session.id, lockedId);
  assert.equal(autoForked.data.session.agent, 'codex');
  assert.match(autoForked.data.session.name, /（分支）$/);

  const schedule = await post('/schedules/update', {
    cwd: workspace, operation: 'create', agent: 'codex', kind: 'interval', interval: 60, catchUp: 0,
    name: 'Report', prompt: 'Long scheduled report',
  });
  assert.equal(schedule.status, 200, JSON.stringify(schedule));
  const manual = await post('/schedules/update', {
    cwd: workspace, operation: 'run', id: schedule.data.job.id,
    scheduleVersion: schedule.data.job.version, requestId: 'long-report',
  });
  assert.equal(manual.status, 200, JSON.stringify(manual));
  const runId = manual.data.run.id;
  let snapshot;
  let report;
  for (let i = 0; i < 60; i += 1) {
    snapshot = (await post('/schedules/sync', {})).data;
    report = snapshot.runs.find(({ id }) => id === runId);
    if (report) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(report?.status, 'succeeded', JSON.stringify(report));
  assert.equal(report.summary.length, 500);
  assert.equal(report.hasFullResult, true);
  const resultInput = { cwd: workspace, id: runId, source: snapshot.source };
  const firstPage = await post('/schedules/result', resultInput);
  assert.equal(firstPage.status, 200);
  assert.ok(firstPage.data.nextTextOffset);
  const lastPage = await post('/schedules/result', { ...resultInput, offset: firstPage.data.nextTextOffset });
  assert.equal(lastPage.status, 200);
  assert.equal(lastPage.data.nextTextOffset, undefined);
  assert.ok(firstPage.data.text + lastPage.data.text ===
    '# Report\n\n' + '一行 Markdown 内容。\n'.repeat(8500) + '\n**End of report**\n');
});

test('a refreshed Codex workspace stays fresh when a global catalog is cached', async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-codex-refresh-'));
  const oldHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = root;
  context.after(async () => {
    if (oldHome === undefined) delete process.env.CODEX_HOME;
    else process.env.CODEX_HOME = oldHome;
    await rm(root, { recursive: true, force: true });
  });
  const initialId = '01a206c9-eef1-7d53-ba63-ed447ac58d7f';
  await seedCodexRollout(root, root, initialId, '', '已有会话', '已有回答');
  assert.deepEqual((await codexComputerSessions(1)).map(({ id }) => id), [initialId]);

  const desktopId = '01a206c9-eef1-7d53-ba63-ed447ac58d80';
  await seedCodexRollout(root, root, desktopId, '', '电脑端新会话', '电脑端回答');
  for (const refresh of [true, false]) {
    const rows = await codexComputerSessions(1, root, refresh);
    assert.ok(rows.some(({ id }) => id === desktopId));
  }
});
