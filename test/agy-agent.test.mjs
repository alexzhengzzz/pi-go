// End-to-end integration test for Antigravity CLI (`agy acp`) support in Pi Go:
//   - native SQLite conversation_summaries.db history scanning in AGY_HOME
//   - daemon host /health.agents, /catalog, /open, /new with agent: 'agy'
//   - broker /sessions listing agy history with agent: 'agy'
//   - phone-side flow through broker: open agy history, start new agy session,
//     streaming thinking, tool execution, message delta, model & thinking level
//     switching, slash commands, approval interaction over worker /pending + /answer,
//     and rename.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { agyComputerSessions } from '../host/agents/agy/catalog.mjs';
import { localRequest } from '../host/bridge/local-ipc.mjs';

const project = new URL('../', import.meta.url).pathname;
const fakeAgy = new URL('./fake-agy.mjs', import.meta.url).pathname;

async function reservePort() {
  const server = createServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function seedAgySession(agyHome, cwd, id, title, userPrompt) {
  await mkdir(join(agyHome, 'conversations'), { recursive: true, mode: 0o700 });
  const dbPath = join(agyHome, 'conversation_summaries.db');
  const db = new DatabaseSync(dbPath);
  try {
    db.exec(`
      CREATE TABLE IF NOT EXISTS conversation_summaries (
        conversation_id text PRIMARY KEY,
        title text NOT NULL DEFAULT "",
        preview text NOT NULL DEFAULT "",
        step_count integer NOT NULL DEFAULT 0,
        last_modified_time datetime NOT NULL,
        workspace_uris text NOT NULL,
        status text NOT NULL DEFAULT "",
        source text NOT NULL DEFAULT "",
        project_id text NOT NULL DEFAULT "",
        agent_name text NOT NULL DEFAULT "",
        parent_conversation_id text NOT NULL DEFAULT "",
        nesting_depth integer NOT NULL DEFAULT 0,
        battle_id text NOT NULL DEFAULT "",
        winning_conversation_id text NOT NULL DEFAULT "",
        not_fully_idle numeric NOT NULL DEFAULT false,
        killed numeric NOT NULL DEFAULT false,
        last_user_input_time datetime NOT NULL,
        last_user_input_step_index integer NOT NULL DEFAULT -1,
        app_data_dir text NOT NULL DEFAULT ""
      );
    `);
    const now = '2026-11-24T00:00:02.000Z';
    const stmt = db.prepare(`
      INSERT OR REPLACE INTO conversation_summaries (
        conversation_id, title, preview, step_count, last_modified_time,
        workspace_uris, last_user_input_time, app_data_dir
      ) VALUES (?, ?, ?, 4, ?, ?, ?, 'antigravity-cli')
    `);
    stmt.run(id, title || '', userPrompt, now, JSON.stringify([`file://${cwd}`]), now);
  } finally {
    db.close();
  }
  const convFile = join(agyHome, 'conversations', `${id}.db`);
  await writeFile(convFile, JSON.stringify({ id, cwd, title, preview: userPrompt }));
  return convFile;
}

test('Antigravity CLI (agy acp) sessions work end-to-end through daemon and broker', { timeout: 60000 }, async (context) => {
  await chmod(fakeAgy, 0o755);
  const root = await realpath(await mkdtemp('/private/tmp/pigo-agy-'));
  const agentDir = join(root, 'pi-agent');
  const agyDir = join(root, 'agy-home');
  const ipc = join(root, 'ipc');
  const workspace = join(root, 'workspace');
  await Promise.all([agentDir, agyDir, ipc, workspace].map((p) => mkdir(p, { recursive: true, mode: 0o700 })));
  await writeFile(join(agyDir, 'jetski_state.pbtxt'), 'authed: true\n');

  const seededId = '8634ece0-499e-4fde-bcdb-40036b7b2213';
  await seedAgySession(agyDir, workspace, seededId, '已有 AGY 会话', '第一轮 agy 提问');

  const env = {
    ...process.env,
    HOME: root,
    PI_CODING_AGENT_DIR: agentDir,
    AGY_HOME: agyDir,
    PIGO_IPC_DIR: ipc,
    PIGO_AGY_BIN: fakeAgy,
    PIGO_CODEX_BIN: join(root, 'missing-codex'),
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
  assert.equal(health.data.agents.some((a) => a.id === 'agy'), true);
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

  // 1. /sessions lists the native agy session with agent: 'agy'.
  const list1 = await get('/sessions');
  assert.equal(list1.status, 200);
  const agyRow = list1.data.sessions.find((s) => s.id === seededId);
  assert.ok(agyRow, 'expected seeded agy session in /sessions');
  assert.equal(agyRow.agent, 'agy');
  assert.equal(agyRow.name, '已有 AGY 会话');
  assert.equal(agyRow.cwd, workspace);

  // 2. Open the existing agy session via POST /open.
  const opened = await post('/open', { id: seededId, agent: 'agy', history: true });
  assert.equal(opened.status, 200, JSON.stringify(opened));
  assert.equal(opened.data.session.id, seededId);
  assert.equal(opened.data.session.agent, 'agy');
  assert.equal(opened.data.session.permission, 'bypass');
  assert.equal(opened.data.messages.length, 2);
  assert.equal(opened.data.messages[0].text, '第一轮 agy 提问');
  assert.equal(opened.data.messages[1].text, '第一轮 agy 回答');

  const workspaceSessions = '/sessions?scope=workspace&cwd=' + encodeURIComponent(workspace);
  const activeList = await get(workspaceSessions);
  assert.equal(activeList.status, 200);
  assert.equal(activeList.data.sessions.find(({ id }) => id === seededId)?.active, true);
  const annotations = join(agyDir, 'annotations');
  await mkdir(annotations);
  const annotation = join(annotations, `${seededId}.pbtxt`);
  await writeFile(annotation, 'title:"已有 AGY 会话" archived:true archival_status_timestamp:{seconds:1795478400}');
  for (const query of ['', '&refresh=1']) {
    const sidebar = await get(workspaceSessions + query);
    assert.equal(sidebar.status, 200);
    assert.ok(!sidebar.data.sessions.some(({ id }) => id === seededId));
    const archive = await get('/sessions?scope=filtered&view=archived' + query);
    assert.equal(archive.status, 200);
    assert.equal(archive.data.sessions.find(({ id }) => id === seededId)?.archived, true);
  }
  await writeFile(annotation, 'title:"Contains archived:true" archived:false');
  const restored = await get(workspaceSessions + '&refresh=1');
  assert.equal(restored.data.sessions.find(({ id }) => id === seededId)?.active, true);

  // 3. Send a prompt and wait for completion + tool execution + thinking.
  const sent = await post('/prompt', {
    id: seededId,
    requestId: 'req-agy-1',
    text: '你好 Antigravity',
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
  assert.equal(lastMsg.text, 'AGY 回复: 你好 Antigravity');
  assert.equal(lastMsg.thinking, '思考并调用工具检查工作区');
  assert.equal(lastMsg.tools?.length, 1);
  assert.equal(lastMsg.tools[0].name, 'bash');
  assert.equal(lastMsg.tools[0].state, 'ok');

  // Tool detail endpoint works for the ACP tool_call item.
  const detail = await get(`/tool-detail?id=${seededId}&tool=${encodeURIComponent(lastMsg.tools[0].id)}&message=${encodeURIComponent(lastMsg.id)}`);
  assert.equal(detail.status, 200);
  assert.equal(detail.data.toolDetail.command, true);
  assert.equal(detail.data.toolDetail.input, 'git status --short');
  assert.match(detail.data.toolDetail.output, /package\.json/);

  // 4. Models and commands.
  const models = await get('/models');
  assert.equal(models.status, 200);
  assert.equal(models.data.models.some((m) => m.id === 'gemini-4-argon'), true);
  const switched = await post('/model', { id: seededId, provider: 'google', modelId: 'gemini-4-argon', thinkingLevel: 'medium' });
  assert.equal(switched.status, 200);
  assert.equal(switched.data.current.id, 'gemini-4-argon');
  assert.equal(switched.data.current.thinkingLevel, 'medium');

  const commands = await get('/commands');
  assert.equal(commands.status, 200);
  assert.equal(commands.data.commands.some((c) => c.name === 'plan'), true);

  // 5. Rename.
  const renamed = await post('/rename', { id: seededId, name: '改名后的 AGY 会话' });
  assert.equal(renamed.status, 200);
  assert.equal(renamed.data.session.name, '改名后的 AGY 会话');

  let agents;
  for (let i = 0; i < 40; i += 1) {
    agents = (await get('/sessions?scope=workspaces')).data.agents;
    if (agents?.some(({ id, installed }) => id === 'codex' && installed === false)) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(agents?.find(({ id }) => id === 'agy')?.installed, true);
  assert.equal(agents?.find(({ id }) => id === 'codex')?.installed, false);
  assert.deepEqual(await post('/new', { cwd: workspace, agent: 'codex' }), {
    status: 409, data: { error: 'desktop_agent_unavailable' },
  });

  // 6. Create a brand new agy session via POST /new with agent: 'agy'.
  const created = await post('/new', { cwd: workspace, agent: 'agy' });
  assert.equal(created.status, 200, JSON.stringify(created));
  const newId = created.data.session.id;
  assert.equal(created.data.session.agent, 'agy');

  // 7. Approval request roundtrip via worker /pending and broker /answer.
  const approvalPrompt = await post('/prompt', {
    id: newId,
    requestId: 'req-agy-approval-1',
    text: '请清理 dist 目录 [approval]',
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
  assert.equal(pendingChat.messages.at(-1).text, '操作已被用户拒绝。');
});

test('a refreshed agy workspace stays fresh when a global catalog is cached', async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-agy-refresh-'));
  const oldHome = process.env.AGY_HOME;
  process.env.AGY_HOME = root;
  context.after(async () => {
    if (oldHome === undefined) delete process.env.AGY_HOME;
    else process.env.AGY_HOME = oldHome;
    await rm(root, { recursive: true, force: true });
  });
  const initialId = '8634ece0-499e-4fde-bcdb-40036b7b2213';
  await seedAgySession(root, root, initialId, '已有会话', '已有提问');
  assert.deepEqual((await agyComputerSessions(1)).map(({ id }) => id), [initialId]);

  const desktopId = '8634ece0-499e-4fde-bcdb-40036b7b2299';
  await seedAgySession(root, root, desktopId, '电脑端新会话', '电脑端提问');
  for (const refresh of [true, false]) {
    const rows = await agyComputerSessions(1, root, refresh);
    assert.ok(rows.some(({ id }) => id === desktopId));
  }
});
