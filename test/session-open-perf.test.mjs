import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';
import { mkdir, mkdtemp, realpath, rm, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createWorkerServer } from '../host/agents/worker-core.mjs';
import { localRequest } from '../host/bridge/local-ipc.mjs';
import { findCodexSession, invalidateCodexCatalog } from '../host/agents/codex/catalog.mjs';
import { findAgySession, invalidateAgyCatalog } from '../host/agents/agy/catalog.mjs';
import { findSession, invalidateSessionCatalog } from '../host/daemon/catalog.mjs';
import { readColdSnapshot } from '../host/bridge/session-snapshot.mjs';

test('worker-core lazily reads path-backed images on GET /message-image', async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-lazy-img-'));
  const ipc = join(root, 'ipc');
  await mkdir(ipc, { recursive: true, mode: 0o700 });
  const prevIpc = process.env.PIGO_IPC_DIR;
  process.env.PIGO_IPC_DIR = ipc;

  const imgPath = join(root, 'sample.jpg');
  const rawBytes = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]);
  await writeFile(imgPath, rawBytes);

  const driver = Object.assign(new EventEmitter(), {
    agent: 'codex',
    capabilities: {},
    state: () => ({ id: '01a206c9-eef1-7d53-ba63-ed447ac58d01', cwd: root, idle: true }),
    historyLeaf: () => 'm1',
    entries: async () => ([
      {
        id: 'm1',
        role: 'user',
        text: 'look at this',
        images: [
          { mimeType: 'image/jpeg', path: imgPath },
          { mimeType: 'image/jpeg', path: join(root, 'missing.jpg') },
        ],
        imageCount: 2,
      },
    ]),
  });

  const server = createWorkerServer(driver, { profile: root });
  context.after(async () => {
    await server.stop();
    if (prevIpc === undefined) delete process.env.PIGO_IPC_DIR;
    else process.env.PIGO_IPC_DIR = prevIpc;
    await rm(root, { recursive: true, force: true });
  });

  const socket = await server.listen();
  const snap = await localRequest(socket, 'GET', '/session/snapshot?history=1');
  assert.equal(snap.status, 200);
  assert.equal(snap.data.messages.length, 1);
  assert.equal(snap.data.messages[0].imageCount, 2);

  const img0 = await localRequest(socket, 'GET', '/message-image?id=01a206c9-eef1-7d53-ba63-ed447ac58d01&message=m1&index=0');
  assert.equal(img0.status, 200);
  assert.equal(img0.data.image.mimeType, 'image/jpeg');
  assert.equal(img0.data.image.data, rawBytes.toString('base64'));

  const img1 = await localRequest(socket, 'GET', '/message-image?id=01a206c9-eef1-7d53-ba63-ed447ac58d01&message=m1&index=1');
  assert.equal(img1.status, 404);
});

test('findCodexSession and findSession use file index and recover when indexed file is deleted', async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-index-'));
  const codexHome = join(root, 'codex');
  const piAgent = join(root, 'pi-agent');
  const workspace = join(root, 'workspace');
  const codexDir = join(codexHome, 'sessions', '2026', '11', '26');
  const piDir = join(piAgent, 'sessions', 'proj');
  await Promise.all([codexDir, piDir, workspace].map((p) => mkdir(p, { recursive: true, mode: 0o700 })));

  const prevCodex = process.env.CODEX_HOME;
  const prevPi = process.env.PI_CODING_AGENT_DIR;
  process.env.CODEX_HOME = codexHome;
  process.env.PI_CODING_AGENT_DIR = piAgent;
  invalidateCodexCatalog();
  invalidateSessionCatalog();

  context.after(async () => {
    if (prevCodex === undefined) delete process.env.CODEX_HOME;
    else process.env.CODEX_HOME = prevCodex;
    if (prevPi === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = prevPi;
    invalidateCodexCatalog();
    invalidateSessionCatalog();
    await rm(root, { recursive: true, force: true });
  });

  const codexId = '01a206c9-eef1-7d53-ba63-ed447ac58d11';
  const codexFile = join(codexDir, `rollout-2026-11-26T00-00-00-${codexId}.jsonl`);
  await writeFile(codexFile, `${JSON.stringify({
    type: 'session_meta',
    payload: { id: codexId, cwd: workspace },
  })}\n`);

  const firstCodex = await findCodexSession(workspace, codexId);
  assert.equal(firstCodex?.id, codexId);
  assert.equal(firstCodex?.path, codexFile);
  // Second call hits codexFileIndex.
  const secondCodex = await findCodexSession(workspace, codexId);
  assert.equal(secondCodex?.path, codexFile);
  // Deleting the file invalidates stale index cleanly.
  await unlink(codexFile);
  assert.equal(await findCodexSession(workspace, codexId), undefined);

  const piId = '01a206c9-eef1-7d53-ba63-ed447ac58d22';
  const piFile = join(piDir, `${piId}.jsonl`);
  await writeFile(piFile, [
    JSON.stringify({ type: 'session', id: piId, cwd: workspace }),
    JSON.stringify({ type: 'message', message: { role: 'user', content: 'hi' } }),
  ].join('\n') + '\n');

  const firstPi = await findSession(workspace, piId);
  assert.equal(firstPi?.id, piId);
  assert.equal(firstPi?.path, piFile);
  const secondPi = await findSession(workspace, piId);
  assert.equal(secondPi?.path, piFile);
  await unlink(piFile);
  assert.equal(await findSession(workspace, piId), undefined);
});

test('findAgySession resolves directly by primary key and filters by workspace', async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-agy-pk-'));
  const agyHome = join(root, 'agy');
  const wsA = join(root, 'ws-a');
  const wsB = join(root, 'ws-b');
  await Promise.all([join(agyHome, 'conversations'), wsA, wsB].map((p) => mkdir(p, { recursive: true, mode: 0o700 })));

  const prevAgy = process.env.AGY_HOME;
  process.env.AGY_HOME = agyHome;
  invalidateAgyCatalog();

  context.after(async () => {
    if (prevAgy === undefined) delete process.env.AGY_HOME;
    else process.env.AGY_HOME = prevAgy;
    invalidateAgyCatalog();
    await rm(root, { recursive: true, force: true });
  });

  const id = '8634ece0-499e-4fde-bcdb-40036b7b2299';
  const db = new DatabaseSync(join(agyHome, 'conversation_summaries.db'));
  try {
    db.exec(`
      CREATE TABLE conversation_summaries (
        conversation_id text PRIMARY KEY,
        title text NOT NULL DEFAULT "",
        preview text NOT NULL DEFAULT "",
        step_count integer NOT NULL DEFAULT 0,
        last_modified_time datetime NOT NULL,
        workspace_uris text NOT NULL,
        parent_conversation_id text NOT NULL DEFAULT "",
        nesting_depth integer NOT NULL DEFAULT 0,
        app_data_dir text NOT NULL DEFAULT ""
      );
    `);
    db.prepare(`
      INSERT INTO conversation_summaries (
        conversation_id, title, preview, step_count, last_modified_time, workspace_uris, app_data_dir
      ) VALUES (?, ?, ?, 3, ?, ?, 'antigravity-cli')
    `).run(id, 'PK 查找测试', 'hello', '2026-11-26T00:00:00.000Z', JSON.stringify([`file://${wsA}`]));
  } finally {
    db.close();
  }
  await writeFile(join(agyHome, 'conversations', `${id}.db`), 'stub');

  const hit = await findAgySession(wsA, id);
  assert.equal(hit?.id, id);
  assert.equal(hit?.cwd, wsA);
  assert.equal(hit?.name, 'PK 查找测试');
  assert.equal(hit?.appDataDir, 'antigravity-cli');

  const wrongWs = await findAgySession(wsB, id);
  assert.equal(wrongWs, undefined);

  const anyWs = await findAgySession(undefined, id);
  assert.equal(anyWs?.id, id);
});

test('readColdSnapshot parses Pi, Codex, and AGY sessions directly from disk', async (context) => {
  const root = await realpath(await mkdtemp('/private/tmp/pigo-cold-snap-'));
  const agyHome = join(root, 'agy');
  const workspace = join(root, 'ws');
  await Promise.all([agyHome, workspace].map((p) => mkdir(p, { recursive: true, mode: 0o700 })));

  const prevAgy = process.env.AGY_HOME;
  process.env.AGY_HOME = agyHome;
  context.after(async () => {
    if (prevAgy === undefined) delete process.env.AGY_HOME;
    else process.env.AGY_HOME = prevAgy;
    await rm(root, { recursive: true, force: true });
  });

  // 1. Pi session file
  const piId = '01a206c9-eef1-7d53-ba63-ed447ac58d33';
  const piFile = join(root, `${piId}.jsonl`);
  await writeFile(piFile, [
    JSON.stringify({ type: 'session', id: piId, cwd: workspace }),
    JSON.stringify({ type: 'session_info', name: 'Pi 冷快照测试' }),
    JSON.stringify({ type: 'message', id: 'm1', message: { role: 'user', content: [{ type: 'text', text: 'hello pi' }] } }),
    JSON.stringify({
      type: 'message',
      id: 'm2',
      parentId: 'm1',
      message: {
        role: 'assistant',
        content: [
          { type: 'thinking', thinking: 'thinking...' },
          { type: 'toolCall', id: 'tc1', name: 'bash', arguments: { command: 'ls' } },
          { type: 'text', text: 'world pi' },
        ],
      },
    }),
    JSON.stringify({ type: 'message', id: 'm3', parentId: 'm2', message: { role: 'toolResult', toolCallId: 'tc1', isError: false, content: [] } }),
  ].join('\n') + '\n');

  const piSnap = await readColdSnapshot({ id: piId, cwd: workspace, agent: 'pi', path: piFile });
  assert.equal(piSnap?.warming, true);
  assert.equal(piSnap?.session.name, 'Pi 冷快照测试');
  assert.equal(piSnap?.cursor.streamId, `cold-${piId}`);
  assert.equal(piSnap?.messages.length, 2);
  assert.equal(piSnap?.messages[0].id, 'm1');
  assert.equal(piSnap?.messages[1].text, 'world pi');
  assert.equal(piSnap?.messages[1].thinking, 'thinking...');
  assert.equal(piSnap?.messages[1].tools?.[0]?.state, 'ok');

  // 2. Codex rollout file
  const codexId = '01a206c9-eef1-7d53-ba63-ed447ac58d44';
  const codexFile = join(root, `rollout-${codexId}.jsonl`);
  await writeFile(codexFile, [
    JSON.stringify({ type: 'session_meta', payload: { id: codexId, cwd: workspace, name: 'Codex 冷快照测试' } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'user_message', id: 'cu1', message: 'hello codex' } }),
    JSON.stringify({ type: 'response_item', payload: { type: 'message', id: 'ca1', role: 'assistant', content: [{ type: 'output_text', text: 'world codex' }] } }),
  ].join('\n') + '\n');

  const codexSnap = await readColdSnapshot({ id: codexId, cwd: workspace, agent: 'codex', path: codexFile });
  assert.equal(codexSnap?.warming, true);
  assert.equal(codexSnap?.session.name, 'Codex 冷快照测试');
  assert.equal(codexSnap?.messages.length, 2);
  assert.equal(codexSnap?.messages[0].text, 'hello codex');
  assert.equal(codexSnap?.messages[1].text, 'world codex');

  // 3. AGY transcript file
  const agyId = '8634ece0-499e-4fde-bcdb-40036b7b2288';
  const transcriptDir = join(agyHome, 'brain', agyId, '.system_generated', 'logs');
  await mkdir(transcriptDir, { recursive: true, mode: 0o700 });
  await writeFile(join(transcriptDir, 'transcript.jsonl'), [
    JSON.stringify({ type: 'USER_INPUT', step_index: 1, content: '<USER_REQUEST>hello agy</USER_REQUEST>', media: [{ uri: 'file:///tmp/x.jpg' }] }),
    JSON.stringify({ type: 'PLANNER_RESPONSE', step_index: 2, thinking: 'plan', content: 'world agy' }),
  ].join('\n') + '\n');

  const agySnap = await readColdSnapshot({ id: agyId, cwd: workspace, agent: 'agy', name: 'AGY 冷快照测试' });
  assert.equal(agySnap?.warming, true);
  assert.equal(agySnap?.session.name, 'AGY 冷快照测试');
  assert.equal(agySnap?.messages.length, 2);
  assert.equal(agySnap?.messages[0].id, 'step-1:user');
  assert.equal(agySnap?.messages[0].text, 'hello agy');
  assert.equal(agySnap?.messages[0].imageCount, 1);
  assert.equal(agySnap?.messages[1].id, 'step-2:assistant');
  assert.equal(agySnap?.messages[1].text, 'world agy');
});
