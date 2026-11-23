#!/usr/bin/env node
// Offline fake `codex app-server` binary for integration testing.
//
// Speaks the Codex app-server JSON-RPC 2.0 protocol over stdio and persists
// rollout files in CODEX_HOME/sessions/YYYY/MM/DD/rollout-<id>.jsonl so
// catalog scanning, resume, fork, rename, turn streaming, tool execution,
// steer, interrupt, and approval requests work deterministically offline.
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const codexHome = resolve(process.env.CODEX_HOME
  || (process.env.PI_CODING_AGENT_DIR ? join(resolve(process.env.PI_CODING_AGENT_DIR), 'codex') : join(homedir(), '.codex')));

if (process.argv.includes('--version')) {
  process.stdout.write('codex-cli 0.171.0-fake\n');
  process.exit(0);
}

const threads = new Map();
const pendingServerReqs = new Map();
let srvSeq = 9000;

function write(msg) {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
}

function notify(method, params) {
  write({ method, params });
}

function serverRequest(method, params) {
  const id = ++srvSeq;
  return new Promise((resolvePromise) => {
    pendingServerReqs.set(id, resolvePromise);
    write({ id, method, params });
  });
}

function rolloutPathFor(id) {
  const dayDir = join(codexHome, 'sessions', '2026', '11', '24');
  mkdirSync(dayDir, { recursive: true, mode: 0o700 });
  return join(dayDir, `rollout-2026-11-24T00-00-00-${id}.jsonl`);
}

function findExistingRollout(id) {
  const root = join(codexHome, 'sessions');
  if (!existsSync(root)) return undefined;
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile() && entry.name.endsWith(`${id}.jsonl`)) return full;
    }
  }
  return undefined;
}

function loadThreadFromDisk(id, fallbackCwd) {
  const file = findExistingRollout(id);
  if (!file) return undefined;
  const lines = readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const meta = lines.find((l) => l.type === 'session_meta')?.payload ?? {};
  let name = meta.name ?? null;
  const turns = [];
  let currentTurn = null;
  for (const row of lines) {
    if (row.type === 'event_msg' && row.payload?.type === 'thread_name_updated') {
      name = row.payload.name;
    } else if (row.type === 'event_msg' && row.payload?.type === 'user_message') {
      currentTurn = {
        id: row.payload.turn_id || randomUUID(),
        rootTurnId: null,
        status: 'completed',
        error: null,
        startedAt: Date.now(),
        completedAt: Date.now(),
        durationMs: 25,
        itemsView: 'full',
        items: [{
          type: 'userMessage',
          id: row.payload.id || randomUUID(),
          clientId: null,
          content: [{ type: 'text', text: row.payload.message, text_elements: [] }],
        }],
      };
      turns.push(currentTurn);
    } else if (row.type === 'response_item' && row.payload?.type === 'message' && row.payload.role === 'assistant') {
      const text = (row.payload.content ?? []).map((p) => p.text ?? '').join('');
      if (!currentTurn) {
        currentTurn = {
          id: randomUUID(),
          rootTurnId: null,
          status: 'completed',
          error: null,
          startedAt: Date.now(),
          completedAt: Date.now(),
          durationMs: 25,
          itemsView: 'full',
          items: [],
        };
        turns.push(currentTurn);
      }
      if (row.payload.thinking) {
        currentTurn.items.push({
          type: 'reasoning',
          id: `rs_${randomUUID()}`,
          summary: [row.payload.thinking],
          content: [],
          startedAtMs: Date.now() - 20,
          completedAtMs: Date.now() - 5,
        });
      }
      if (Array.isArray(row.payload.tools)) {
        for (const t of row.payload.tools) currentTurn.items.push(t);
      }
      currentTurn.items.push({
        type: 'agentMessage',
        id: row.payload.id || `msg_${randomUUID()}`,
        text,
        phase: 'final_answer',
        moderation: null,
        memoryCitation: null,
        delivery: null,
        questions: null,
      });
    }
  }
  const thread = {
    id,
    sessionId: id,
    cwd: meta.cwd || fallbackCwd || process.cwd(),
    name,
    preview: turns[0]?.items?.[0]?.content?.[0]?.text || '',
    ephemeral: false,
    modelProvider: 'openai',
    model: 'gpt-6.2-sol',
    reasoningEffort: 'medium',
    createdAt: Math.floor(Date.now() / 1000),
    updatedAt: Math.floor(Date.now() / 1000),
    status: { type: 'idle' },
    path: file,
    turns,
  };
  threads.set(id, thread);
  return thread;
}

function persistMeta(thread) {
  mkdirSync(dirname(thread.path), { recursive: true, mode: 0o700 });
  if (!existsSync(thread.path)) {
    appendFileSync(thread.path, `${JSON.stringify({
      timestamp: new Date().toISOString(),
      ordinal: 0,
      type: 'session_meta',
      payload: { id: thread.id, session_id: thread.id, cwd: thread.cwd, name: thread.name },
    })}\n`);
  }
}

function persistTurn(thread, userItem, assistantItem, thinkingText, toolItems = []) {
  persistMeta(thread);
  const userText = (userItem.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
  appendFileSync(thread.path, `${JSON.stringify({
    timestamp: new Date().toISOString(),
    type: 'event_msg',
    payload: { type: 'user_message', id: userItem.id, message: userText },
  })}\n`);
  appendFileSync(thread.path, `${JSON.stringify({
    timestamp: new Date().toISOString(),
    type: 'response_item',
    payload: {
      type: 'message',
      id: assistantItem.id,
      role: 'assistant',
      thinking: thinkingText,
      tools: toolItems,
      content: [{ type: 'output_text', text: assistantItem.text }],
    },
  })}\n`);
}

function persistName(thread) {
  persistMeta(thread);
  appendFileSync(thread.path, `${JSON.stringify({
    timestamp: new Date().toISOString(),
    type: 'event_msg',
    payload: { type: 'thread_name_updated', name: thread.name },
  })}\n`);
  const indexFile = join(codexHome, 'session_index.jsonl');
  mkdirSync(dirname(indexFile), { recursive: true, mode: 0o700 });
  appendFileSync(indexFile, `${JSON.stringify({
    id: thread.id,
    thread_name: thread.name,
    updated_at: new Date().toISOString(),
  })}\n`);
}

async function handleRequest(id, method, params = {}) {
  if (method === 'initialize') {
    return { userAgent: 'codex-fake/0.171.0', codexHome, platformFamily: 'unix', platformOs: 'macos' };
  }
  if (method === 'model/list') {
    return {
      data: [
        {
          id: 'gpt-6.2-sol',
          model: 'gpt-6.2-sol',
          displayName: 'GPT-6.2-Sol',
          description: 'Fast model for coding',
          hidden: false,
          isDefault: true,
          defaultReasoningEffort: 'medium',
          supportedReasoningEfforts: [
            { reasoningEffort: 'low', description: 'Low' },
            { reasoningEffort: 'medium', description: 'Medium' },
            { reasoningEffort: 'high', description: 'High' },
          ],
          inputModalities: ['text', 'image'],
        },
        {
          id: 'o3-pro',
          model: 'o3-pro',
          displayName: 'o3-pro',
          description: 'Deep reasoning model',
          hidden: false,
          isDefault: false,
          defaultReasoningEffort: 'high',
          supportedReasoningEfforts: [
            { reasoningEffort: 'medium', description: 'Medium' },
            { reasoningEffort: 'high', description: 'High' },
            { reasoningEffort: 'xhigh', description: 'Extra high' },
          ],
          inputModalities: ['text', 'image'],
        },
      ],
      nextCursor: null,
    };
  }
  if (method === 'skills/list') {
    return {
      data: [{
        cwd: params.cwds?.[0] || process.cwd(),
        skills: [{
          name: 'review',
          description: 'Review workspace changes',
          enabled: true,
          path: '/fake/skills/review/SKILL.md',
        }],
      }],
    };
  }
  if (method === 'thread/start') {
    const threadId = `01a20999-0000-7000-8000-${randomUUID().slice(-12)}`;
    const thread = {
      id: threadId,
      sessionId: threadId,
      cwd: params.cwd || process.cwd(),
      name: null,
      preview: '',
      ephemeral: Boolean(params.ephemeral),
      modelProvider: 'openai',
      model: params.model || 'gpt-6.2-sol',
      reasoningEffort: 'medium',
      createdAt: Math.floor(Date.now() / 1000),
      updatedAt: Math.floor(Date.now() / 1000),
      status: { type: 'idle' },
      path: rolloutPathFor(threadId),
      turns: [],
    };
    threads.set(threadId, thread);
    persistMeta(thread);
    return {
      thread,
      model: thread.model,
      modelProvider: 'openai',
      cwd: thread.cwd,
      approvalPolicy: params.approvalPolicy || 'never',
      sandbox: { type: params.sandbox || 'danger-full-access' },
      reasoningEffort: 'medium',
    };
  }
  if (method === 'thread/read') {
    const thread = threads.get(params.threadId) || loadThreadFromDisk(params.threadId);
    if (!thread) throw Object.assign(new Error('thread_not_found'), { code: -32600 });
    return {
      thread,
      model: thread.model,
      modelProvider: 'openai',
      cwd: thread.cwd,
      reasoningEffort: thread.reasoningEffort || 'medium',
    };
  }
  if (method === 'thread/resume') {
    if (process.env.FAKE_CODEX_LOCKED_ID === params.threadId) {
      throw Object.assign(new Error(`thread ${params.threadId} already has an active writer`), { code: -32600 });
    }
    const thread = threads.get(params.threadId) || loadThreadFromDisk(params.threadId, params.cwd);
    if (!thread) throw Object.assign(new Error('thread_not_found'), { code: -32600 });
    return {
      thread,
      model: thread.model,
      modelProvider: 'openai',
      cwd: thread.cwd,
      approvalPolicy: params.approvalPolicy || 'never',
      sandbox: { type: params.sandbox || 'danger-full-access' },
      reasoningEffort: thread.reasoningEffort || 'medium',
    };
  }
  if (method === 'thread/turns/list') {
    const thread = threads.get(params.threadId) || loadThreadFromDisk(params.threadId);
    if (!thread) return { data: [], nextCursor: null, backwardsCursor: null };
    const list = [...thread.turns];
    if (params.sortDirection === 'desc') list.reverse();
    return { data: list, nextCursor: null, backwardsCursor: null };
  }
  if (method === 'thread/name/set') {
    const thread = threads.get(params.threadId) || loadThreadFromDisk(params.threadId);
    if (!thread) throw Object.assign(new Error('thread_not_found'), { code: -32600 });
    thread.name = params.name;
    persistName(thread);
    notify('thread/name/updated', { threadId: thread.id, name: thread.name });
    return {};
  }
  if (method === 'thread/fork') {
    const source = threads.get(params.threadId) || loadThreadFromDisk(params.threadId, params.cwd);
    if (!source) throw Object.assign(new Error('thread_not_found'), { code: -32600 });
    const forkId = `01a20999-f000-7000-8000-${randomUUID().slice(-12)}`;
    const cutIndex = params.lastTurnId ? source.turns.findIndex((t) => t.id === params.lastTurnId) : -1;
    const copiedTurns = cutIndex >= 0 ? source.turns.slice(0, cutIndex + 1) : [...source.turns];
    const forked = {
      ...source,
      id: forkId,
      sessionId: forkId,
      path: rolloutPathFor(forkId),
      turns: JSON.parse(JSON.stringify(copiedTurns)),
    };
    threads.set(forkId, forked);
    persistMeta(forked);
    for (const t of forked.turns) {
      const u = t.items.find((i) => i.type === 'userMessage');
      const a = t.items.find((i) => i.type === 'agentMessage');
      if (u && a) persistTurn(forked, u, a);
    }
    return { thread: forked, model: forked.model, modelProvider: 'openai', cwd: forked.cwd };
  }
  if (method === 'turn/start') {
    const thread = threads.get(params.threadId) || loadThreadFromDisk(params.threadId, params.cwd);
    if (!thread) throw Object.assign(new Error('thread_not_found'), { code: -32600 });
    if (params.model) thread.model = params.model;
    if (params.effort) thread.reasoningEffort = params.effort;
    const turnId = `turn-${randomUUID()}`;
    const userItem = {
      type: 'userMessage',
      id: `user-${randomUUID()}`,
      clientId: null,
      content: params.input || [],
    };
    const promptText = (params.input || []).filter((p) => p.type === 'text').map((p) => p.text).join('\n');
    const hasSkill = (params.input || []).some((p) => p.type === 'skill');
    const hasImage = (params.input || []).some((p) => p.type === 'localImage');
    const turn = {
      id: turnId,
      rootTurnId: turnId,
      status: 'inProgress',
      error: null,
      startedAt: Math.floor(Date.now() / 1000),
      completedAt: null,
      durationMs: 30,
      itemsView: 'full',
      items: [userItem],
      steeredTexts: [],
      interrupted: false,
    };
    thread.activeTurn = turn;
    setImmediate(async () => {
      notify('turn/started', { threadId: thread.id, turn: { ...turn, items: [] } });
      if (promptText.includes('[approval]')) {
        const decision = await serverRequest('item/commandExecution/requestApproval', {
          threadId: thread.id,
          turnId,
          itemId: `cmd-${randomUUID()}`,
          command: 'rm -rf ./build',
          cwd: thread.cwd,
          reason: 'Clean build output',
        });
        if (decision?.decision === 'decline') {
          const msgItem = {
            type: 'agentMessage',
            id: `msg-${randomUUID()}`,
            text: '命令已被用户拒绝。',
            phase: 'final_answer',
          };
          turn.items.push(msgItem);
          turn.status = 'completed';
          thread.turns.push(turn);
          thread.activeTurn = undefined;
          persistTurn(thread, userItem, msgItem);
          notify('item/agentMessage/delta', { threadId: thread.id, turnId, itemId: msgItem.id, delta: msgItem.text });
          notify('item/completed', { threadId: thread.id, turnId, item: msgItem });
          notify('turn/completed', { threadId: thread.id, turn });
          return;
        }
      }

      if (promptText.includes('[slow]')) {
        for (let i = 0; i < 40; i += 1) {
          await new Promise((r) => setTimeout(r, 50));
          if (turn.interrupted) {
            turn.status = 'interrupted';
            thread.activeTurn = undefined;
            notify('turn/completed', { threadId: thread.id, turn });
            return;
          }
          if (turn.steeredTexts.length) break;
        }
      }

      const thinkingText = '分析请求并执行任务';
      notify('item/reasoning/summaryTextDelta', { threadId: thread.id, turnId, itemId: `rs-${turnId}`, delta: thinkingText });
      turn.items.push({
        type: 'reasoning',
        id: `rs-${turnId}`,
        summary: [thinkingText],
        content: [],
        startedAtMs: Date.now() - 25,
        completedAtMs: Date.now() - 5,
      });

      const cmdItem = {
        type: 'commandExecution',
        id: `cmd-${turnId}`,
        command: 'git status --short',
        cwd: thread.cwd,
        status: 'inProgress',
        aggregatedOutput: 'M README.md\n',
        exitCode: 0,
        durationMs: 12,
      };
      notify('item/started', { threadId: thread.id, turnId, item: cmdItem });
      cmdItem.status = 'completed';
      turn.items.push(cmdItem);
      notify('item/completed', { threadId: thread.id, turnId, item: cmdItem });

      const steeredSuffix = turn.steeredTexts.length ? ` [steered: ${turn.steeredTexts.join(', ')}]` : '';
      const skillPrefix = hasSkill ? '[skill:review] ' : '';
      const imagePrefix = hasImage ? '[image] ' : '';
      const replyText = `Codex 回复: ${skillPrefix}${imagePrefix}${promptText}${steeredSuffix}`;
      const msgItem = {
        type: 'agentMessage',
        id: `msg-${randomUUID()}`,
        text: replyText,
        phase: 'final_answer',
      };
      notify('item/agentMessage/delta', { threadId: thread.id, turnId, itemId: msgItem.id, delta: replyText });
      turn.items.push(msgItem);
      notify('item/completed', { threadId: thread.id, turnId, item: msgItem });

      turn.status = 'completed';
      thread.turns.push(turn);
      thread.activeTurn = undefined;
      persistTurn(thread, userItem, msgItem, thinkingText, [cmdItem]);
      notify('turn/completed', { threadId: thread.id, turn });
    });
    return { turn: { id: turnId, rootTurnId: turnId, items: [], itemsView: 'notLoaded', status: 'inProgress', error: null } };
  }
  if (method === 'turn/steer') {
    const thread = threads.get(params.threadId);
    const turn = thread?.activeTurn;
    if (!turn || turn.id !== params.expectedTurnId) {
      throw Object.assign(new Error('no_active_turn'), { code: -32600 });
    }
    const text = (params.input || []).filter((p) => p.type === 'text').map((p) => p.text).join('\n');
    turn.steeredTexts.push(text);
    return { turnId: turn.id };
  }
  if (method === 'turn/interrupt') {
    const thread = threads.get(params.threadId);
    if (thread?.activeTurn) thread.activeTurn.interrupted = true;
    return {};
  }
  return {};
}

createInterface({ input: process.stdin, crlfDelay: Infinity }).on('line', async (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.id !== undefined && msg.method === undefined) {
    const pending = pendingServerReqs.get(msg.id);
    if (pending) {
      pendingServerReqs.delete(msg.id);
      pending(msg.result);
    }
    return;
  }
  if (msg.id !== undefined && typeof msg.method === 'string') {
    try {
      const result = await handleRequest(msg.id, msg.method, msg.params);
      write({ id: msg.id, result });
    } catch (error) {
      write({ id: msg.id, error: { code: error.code ?? -32603, message: error.message } });
    }
  }
});
