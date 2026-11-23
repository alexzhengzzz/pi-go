#!/usr/bin/env node
// Offline fake `agy` binary speaking ACP JSON-RPC 2.0 over stdio for integration testing.
//
// Persists sessions in `AGY_HOME/conversation_summaries.db` (SQLite) and
// `AGY_HOME/conversations/<uuid>.db` so catalog scanning, `session/load`,
// `session/new`, `session/prompt`, `session/cancel`, `session/set_config_option`,
// and `session/request_permission` work deterministically offline.
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

if (process.argv.includes('--version')) {
  process.stdout.write('1.5.15-fake\n');
  process.exit(0);
}

const agyHome = resolve(process.env.AGY_HOME
  || (process.env.PI_CODING_AGENT_DIR ? join(resolve(process.env.PI_CODING_AGENT_DIR), 'agy') : join(homedir(), '.gemini', 'antigravity-cli')));

const sessions = new Map();
const pendingServerReqs = new Map();
let srvSeq = 9000;

function write(msg) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...msg })}\n`);
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

function ensureSummariesDb() {
  mkdirSync(agyHome, { recursive: true, mode: 0o700 });
  mkdirSync(join(agyHome, 'conversations'), { recursive: true, mode: 0o700 });
  const dbPath = join(agyHome, 'conversation_summaries.db');
  const db = new DatabaseSync(dbPath);
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
  return db;
}

function persistSession(session) {
  const db = ensureSummariesDb();
  try {
    const now = new Date().toISOString();
    const uris = JSON.stringify([`file://${session.cwd}`]);
    const stmt = db.prepare(`
      INSERT INTO conversation_summaries (
        conversation_id, title, preview, step_count, last_modified_time,
        workspace_uris, last_user_input_time, app_data_dir
      ) VALUES (?, ?, ?, ?, ?, ?, ?, 'antigravity-cli')
      ON CONFLICT(conversation_id) DO UPDATE SET
        title = excluded.title,
        preview = excluded.preview,
        step_count = excluded.step_count,
        last_modified_time = excluded.last_modified_time
    `);
    stmt.run(
      session.id,
      session.title || '',
      session.preview || '',
      Math.max(1, session.turns.length * 2),
      now,
      uris,
      now,
    );
  } finally {
    try { db.close(); } catch {}
  }
  const convFile = join(agyHome, 'conversations', `${session.id}.db`);
  writeFileSync(convFile, JSON.stringify({
    id: session.id,
    cwd: session.cwd,
    title: session.title,
    preview: session.preview,
    turns: session.turns,
  }));
}

function loadSessionFromDisk(sessionId, fallbackCwd) {
  const convFile = join(agyHome, 'conversations', `${sessionId}.db`);
  if (!existsSync(convFile)) return undefined;
  let title = '';
  let preview = '';
  let cwd = fallbackCwd || process.cwd();
  let turns = [];
  const dbPath = join(agyHome, 'conversation_summaries.db');
  if (existsSync(dbPath)) {
    const db = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const row = db.prepare('SELECT title, preview, workspace_uris FROM conversation_summaries WHERE conversation_id = ?').get(sessionId);
      if (row) {
        title = row.title || '';
        preview = row.preview || '';
        try {
          const uris = JSON.parse(row.workspace_uris || '[]');
          if (uris[0]?.startsWith('file://')) cwd = decodeURIComponent(new URL(uris[0]).pathname);
        } catch {}
      }
    } finally {
      try { db.close(); } catch {}
    }
  }
  if (preview) {
    turns = [{ user: preview, assistant: '第一轮 agy 回答' }];
  }
  const session = {
    id: sessionId,
    cwd,
    title,
    preview,
    model: 'gemini-4-neon',
    thoughtLevel: 'high',
    turns,
  };
  sessions.set(sessionId, session);
  return session;
}

function sessionConfigResponse(session) {
  return {
    sessionId: session.id,
    models: {
      availableModels: [
        { modelId: 'gemini-4-neon-high', name: 'Gemini 4 Neon (High)' },
        { modelId: 'gemini-4-neon-medium', name: 'Gemini 4 Neon (Medium)' },
        { modelId: 'gemini-4-neon-low', name: 'Gemini 4 Neon (Low)' },
        { modelId: 'gemini-4-argon-high', name: 'Gemini 4 Argon (High)' },
        { modelId: 'gemini-4-argon-medium', name: 'Gemini 4 Argon (Medium)' },
        { modelId: 'claude-sonnet-5-5-high', name: 'Claude Sonnet 5.5 (High)' },
      ],
      currentModelId: `${session.model}-${session.thoughtLevel}`,
    },
    configOptions: [
      {
        id: 'model',
        name: 'Model',
        category: 'model',
        type: 'select',
        currentValue: session.model,
        options: [
          { value: 'gemini-4-neon', name: 'Gemini 4 Neon' },
          { value: 'gemini-4-argon', name: 'Gemini 4 Argon' },
          { value: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5' },
        ],
      },
      {
        id: 'thought_level',
        name: 'Thinking Level',
        category: 'thought_level',
        type: 'select',
        currentValue: session.thoughtLevel,
        options: [
          { value: 'low', name: 'Low' },
          { value: 'medium', name: 'Medium' },
          { value: 'high', name: 'High' },
        ],
      },
    ],
  };
}

function emitAvailableCommands(sessionId) {
  notify('session/update', {
    sessionId,
    update: {
      sessionUpdate: 'available_commands_update',
      availableCommands: [
        { name: 'plan', description: 'Plan carefully before executing a task.' },
        { name: 'boost', description: 'Invoke the Boost multi-agent orchestrator.' },
      ],
    },
  });
}

async function handleRequest(id, method, params = {}) {
  if (method === 'initialize') {
    return {
      protocolVersion: 1,
      agentCapabilities: {
        loadSession: true,
        promptCapabilities: { image: true, audio: false, embeddedContext: true },
        sessionCapabilities: { resume: {}, close: {}, load: {}, list: {} },
      },
      agentInfo: { name: 'Antigravity ACP Server (Fake)', version: '1.5.15' },
    };
  }
  if (method === 'session/new') {
    const sessionId = randomUUID();
    const session = {
      id: sessionId,
      cwd: params.cwd || process.cwd(),
      title: '',
      preview: '',
      model: 'gemini-4-neon',
      thoughtLevel: 'high',
      turns: [],
    };
    sessions.set(sessionId, session);
    persistSession(session);
    setImmediate(() => emitAvailableCommands(sessionId));
    return sessionConfigResponse(session);
  }
  if (method === 'session/load') {
    const session = sessions.get(params.sessionId) || loadSessionFromDisk(params.sessionId, params.cwd);
    if (!session) throw Object.assign(new Error(`Session not found: ${params.sessionId}`), { code: -32002 });
    for (const turn of session.turns) {
      notify('session/update', {
        sessionId: session.id,
        update: { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: turn.user } },
      });
      notify('session/update', {
        sessionId: session.id,
        update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: turn.assistant } },
      });
    }
    setImmediate(() => {
      emitAvailableCommands(session.id);
      if (session.title) {
        notify('session/update', {
          sessionId: session.id,
          update: { sessionUpdate: 'session_info_update', title: session.title },
        });
      }
    });
    return sessionConfigResponse(session);
  }
  if (method === 'session/set_config_option') {
    const session = sessions.get(params.sessionId) || loadSessionFromDisk(params.sessionId);
    if (!session) throw Object.assign(new Error('session_not_found'), { code: -32002 });
    if (params.configId === 'model') session.model = params.value;
    if (params.configId === 'thought_level') session.thoughtLevel = params.value;
    return { configOptions: sessionConfigResponse(session).configOptions };
  }
  if (method === 'session/prompt') {
    const session = sessions.get(params.sessionId) || loadSessionFromDisk(params.sessionId);
    if (!session) throw Object.assign(new Error('session_not_found'), { code: -32002 });
    const promptBlocks = Array.isArray(params.prompt) ? params.prompt : [];
    const promptText = promptBlocks.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
    session.cancelled = false;
    if (!session.preview) session.preview = promptText;

    if (promptText.includes('[approval]')) {
      const outcome = await serverRequest('session/request_permission', {
        sessionId: session.id,
        toolCall: {
          toolCallId: `tc-perm-${randomUUID()}`,
          title: 'rm -rf ./dist',
          kind: 'execute',
          rawInput: { CommandLine: 'rm -rf ./dist' },
        },
        options: [
          { optionId: 'allow_once', name: '允许一次', kind: 'allow_once' },
          { optionId: 'allow_always', name: '本会话允许', kind: 'allow_always' },
          { optionId: 'reject_once', name: '拒绝', kind: 'reject_once' },
        ],
      });
      if (outcome?.outcome?.optionId === 'reject_once' || outcome?.outcome?.outcome === 'cancelled') {
        const deniedText = '操作已被用户拒绝。';
        notify('session/update', {
          sessionId: session.id,
          update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: deniedText } },
        });
        session.turns.push({ user: promptText, assistant: deniedText });
        persistSession(session);
        return { stopReason: 'end_turn' };
      }
    }

    notify('session/update', {
      sessionId: session.id,
      update: { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: '思考并调用工具检查工作区' } },
    });

    const toolId = `tc-${randomUUID()}`;
    notify('session/update', {
      sessionId: session.id,
      update: {
        sessionUpdate: 'tool_call',
        toolCallId: toolId,
        title: 'git status --short',
        kind: 'execute',
        status: 'in_progress',
        rawInput: { ToolName: 'run_command', CommandLine: 'git status --short' },
      },
    });
    notify('session/update', {
      sessionId: session.id,
      update: {
        sessionUpdate: 'tool_call_update',
        toolCallId: toolId,
        status: 'completed',
        content: [{ type: 'content', content: { type: 'text', text: 'M package.json\n' } }],
      },
    });

    const replyText = `AGY 回复: ${promptText}`;
    notify('session/update', {
      sessionId: session.id,
      update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: replyText } },
    });
    session.turns.push({ user: promptText, assistant: replyText });
    persistSession(session);
    return { stopReason: 'end_turn' };
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
  if (msg.id === undefined && msg.method === 'session/cancel') {
    const session = sessions.get(msg.params?.sessionId);
    if (session) session.cancelled = true;
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
