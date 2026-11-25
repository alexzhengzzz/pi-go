// Fast read-only cold-session snapshot reader for Pi, Codex, and AGY.
//
// Reads the recent transcript page directly from the agent's local session store
// so POST /session/open can return history in ~10-30ms while the real Agent
// Worker warms up asynchronously in the background.
import { readFile } from 'node:fs/promises';
import { existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { imageParts, messageText, messageTextSlice, sessionTitlePreview, toolDetail } from './message-view.mjs';
import { agyHomes } from '../agents/agy/catalog.mjs';

const messagePreviewLength = 8000;
const thinkingPreviewLength = 16000;
const maxFileBytes = 64 * 1024 * 1024;

function paginateNewestFirst(newestFirstEntries, limit = 60) {
  const messages = [];
  let historyCursor;
  for (const entry of newestFirstEntries) {
    const text = typeof entry.text === 'string' ? entry.text : '';
    const thinking = entry.role === 'assistant' && typeof entry.thinking === 'string' ? entry.thinking : '';
    const imageCount = typeof entry.imageCount === 'number' ? entry.imageCount : 0;
    const tools = Array.isArray(entry.tools) && entry.tools.length ? entry.tools : undefined;
    if (!text && !imageCount && !thinking && !tools) continue;
    if (messages.length === limit) {
      historyCursor = messages[messages.length - 1].id;
      break;
    }
    messages.push({
      id: entry.id,
      role: entry.role,
      text: messageTextSlice(text, 0, messagePreviewLength),
      imageCount: imageCount || undefined,
      tools,
      textTruncated: entry.role === 'assistant' && text.length > messagePreviewLength ? true : undefined,
      thinking: thinking ? thinking.slice(0, thinkingPreviewLength) : undefined,
      thinkingMs: thinking && typeof entry.thinkingMs === 'number' ? entry.thinkingMs : undefined,
    });
  }
  const chronological = messages.reverse();
  const historyLeaf = chronological.at(-1)?.id ?? null;
  return { messages: chronological, historyCursor, historyLeaf };
}

async function readBoundedUtf8(file) {
  if (typeof file !== 'string' || !file) return undefined;
  let info;
  try { info = statSync(file); } catch { return undefined; }
  if (!info.isFile() || info.size === 0 || info.size > maxFileBytes) return undefined;
  return await readFile(file, 'utf8').catch(() => undefined);
}

async function readPiColdSnapshot(row, limit) {
  const raw = await readBoundedUtf8(row.path);
  if (!raw) return undefined;
  const byId = new Map();
  let leaf;
  let name;
  let headerId;

  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (!entry || typeof entry !== 'object') continue;
    if (entry.type === 'session') {
      headerId = entry.id;
      continue;
    }
    if (entry.type === 'session_info' && typeof entry.name === 'string' && entry.name.trim()) {
      name = entry.name.trim();
    }
    if (typeof entry.id === 'string') {
      byId.set(entry.id, entry);
      leaf = entry;
    }
  }
  if (headerId && headerId !== row.id) return undefined;
  if (!leaf) return undefined;

  function* walkActiveBranch() {
    const results = new Map();
    const visited = new Set();
    for (let entry = leaf; entry && !visited.has(entry.id); entry = entry.parentId ? byId.get(entry.parentId) : undefined) {
      visited.add(entry.id);
      if (entry.type !== 'message' || !entry.message) continue;
      const message = entry.message;
      if (message.role === 'toolResult') {
        if (typeof message.toolCallId === 'string' && !results.has(message.toolCallId)) {
          results.set(message.toolCallId, message);
        }
        continue;
      }
      if (message.role !== 'user' && message.role !== 'assistant') continue;
      const content = Array.isArray(message.content) ? message.content : [];
      const tools = [];
      if (message.role === 'assistant') {
        for (let i = content.length - 1; i >= 0; i -= 1) {
          const part = content[i];
          if (part?.type !== 'toolCall') continue;
          const result = results.get(part.id);
          results.delete(part.id);
          tools.push({
            id: part.id,
            name: part.name,
            detail: toolDetail(part.arguments),
            state: result ? (result.isError ? 'fail' : 'ok') : 'unknown',
          });
        }
        tools.reverse();
      }
      const thinking = message.role === 'assistant'
        ? content.flatMap((part) => part?.type === 'thinking' && typeof part.thinking === 'string' ? [part.thinking] : []).join('\n')
        : '';
      yield {
        id: entry.id,
        role: message.role,
        text: messageText(message.content),
        imageCount: imageParts(message.content).length,
        tools,
        thinking,
        thinkingMs: typeof message.durationMs === 'number' ? message.durationMs : undefined,
      };
    }
  }

  const page = paginateNewestFirst(walkActiveBranch(), limit);
  const firstUser = page.messages.find((m) => m.role === 'user' && m.text);
  const resolvedName = name || row.name || (firstUser ? sessionTitlePreview(firstUser.text) : undefined);
  return { ...page, name: resolvedName };
}

function cleanCodexUserText(raw) {
  if (typeof raw !== 'string') return '';
  const marker = '## My request:\n';
  const index = raw.lastIndexOf(marker);
  const body = (index >= 0 ? raw.slice(index + marker.length) : raw).trim();
  if (body.startsWith('<environment_context>') || body.startsWith('# AGENTS.md instructions')) return '';
  return body;
}

async function readCodexColdSnapshot(row, limit) {
  const raw = await readBoundedUtf8(row.path);
  if (!raw) return undefined;
  const entries = [];
  let name;
  let currentAssistant;
  const toolsByCallId = new Map();
  let seq = 0;

  const ensureAssistant = (id) => {
    if (!currentAssistant) {
      currentAssistant = {
        id: id || `cold-codex-a-${++seq}`,
        role: 'assistant',
        text: '',
        thinking: '',
        tools: [],
      };
      entries.push(currentAssistant);
    }
    return currentAssistant;
  };

  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let record;
    try { record = JSON.parse(line); } catch { continue; }
    if (!record || typeof record !== 'object') continue;
    const payload = record.payload;
    if (!payload || typeof payload !== 'object') continue;

    if (record.type === 'session_meta') {
      if (typeof payload.name === 'string' && payload.name.trim()) name = payload.name.trim();
      continue;
    }

    if (record.type === 'event_msg') {
      if (payload.type === 'thread_name_updated' && typeof payload.name === 'string' && payload.name.trim()) {
        name = payload.name.trim();
      } else if (payload.type === 'user_message' && typeof payload.message === 'string') {
        const text = cleanCodexUserText(payload.message);
        const imageCount = Array.isArray(payload.images) ? payload.images.length : 0;
        if (text || imageCount) {
          currentAssistant = undefined;
          entries.push({
            id: payload.id || `cold-codex-u-${++seq}`,
            role: 'user',
            text,
            imageCount,
          });
        }
      } else if (payload.type === 'agent_reasoning' && typeof payload.text === 'string' && payload.text.trim()) {
        const assistant = ensureAssistant();
        assistant.thinking = assistant.thinking ? `${assistant.thinking}\n\n${payload.text.trim()}` : payload.text.trim();
      }
      continue;
    }

    if (record.type === 'response_item') {
      if (payload.type === 'message') {
        const role = payload.role;
        const content = Array.isArray(payload.content) ? payload.content : [];
        if (role === 'user') {
          const texts = content
            .filter((p) => (p?.type === 'input_text' || p?.type === 'text') && typeof p.text === 'string')
            .map((p) => cleanCodexUserText(p.text))
            .filter(Boolean);
          const imageCount = content.filter((p) => p?.type === 'input_image' || p?.type === 'image' || p?.type === 'local_image').length;
          const text = texts.join('\n');
          if (text || imageCount) {
            const last = entries.at(-1);
            // Avoid duplicating user_message already recorded via event_msg.
            if (!(last?.role === 'user' && last.text === text)) {
              currentAssistant = undefined;
              entries.push({
                id: payload.id || `cold-codex-u-${++seq}`,
                role: 'user',
                text,
                imageCount,
              });
            }
          }
        } else if (role === 'assistant') {
          const text = content
            .filter((p) => (p?.type === 'output_text' || p?.type === 'text') && typeof p.text === 'string')
            .map((p) => p.text)
            .join('\n')
            .trim();
          if (text) {
            const assistant = ensureAssistant(payload.id);
            if (payload.id) assistant.id = payload.id;
            assistant.text = assistant.text ? `${assistant.text}\n\n${text}` : text;
          }
        }
      } else if (payload.type === 'reasoning') {
        const summary = Array.isArray(payload.summary)
          ? payload.summary.map((s) => (typeof s === 'string' ? s : s?.text)).filter(Boolean)
          : [];
        const text = summary.join('\n').trim();
        if (text) {
          const assistant = ensureAssistant();
          assistant.thinking = assistant.thinking ? `${assistant.thinking}\n\n${text}` : text;
        }
      } else if (payload.type === 'function_call' || payload.type === 'custom_tool_call' || payload.type === 'local_shell_call') {
        const assistant = ensureAssistant();
        const callId = payload.call_id || payload.id || `cold-tool-${++seq}`;
        let args = payload.arguments ?? payload.input ?? payload.action;
        if (typeof args === 'string') {
          try { args = JSON.parse(args); } catch {}
        }
        const rawName = payload.name || (payload.type === 'local_shell_call' ? 'bash' : 'tool');
        const toolName = rawName === 'exec_command' || rawName === 'shell_command' || rawName === 'shell' ? 'bash' : rawName;
        const summary = {
          id: callId,
          name: toolName,
          detail: toolDetail(args) || (typeof args === 'string' ? args.slice(0, 120) : ''),
          state: 'ok',
        };
        assistant.tools.push(summary);
        toolsByCallId.set(callId, summary);
      } else if (payload.type === 'function_call_output' || payload.type === 'custom_tool_call_output') {
        const tool = payload.call_id && toolsByCallId.get(payload.call_id);
        if (tool && typeof payload.output === 'string' && /exit code:\s*[1-9]/i.test(payload.output)) {
          tool.state = 'fail';
        }
      }
    }
  }

  const filtered = entries.filter((e) => e.role === 'user' || e.text || e.thinking || e.tools?.length);
  if (!filtered.length) return undefined;
  const page = paginateNewestFirst([...filtered].reverse(), limit);
  const firstUser = filtered.find((m) => m.role === 'user' && m.text);
  const resolvedName = name || row.name || (firstUser ? sessionTitlePreview(firstUser.text) : undefined);
  return { ...page, name: resolvedName };
}

function cleanAgyUserText(raw) {
  if (typeof raw !== 'string') return '';
  const match = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/i.exec(raw);
  return (match ? match[1] : raw).trim();
}

function parseJsonArg(value) {
  if (typeof value !== 'string') return value;
  const trimmed = value.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    try { return JSON.parse(trimmed); } catch { return value; }
  }
  return value;
}

function agyToolSummary(tc, stepIndex, toolIndex, isError) {
  const rawName = String(tc.name || 'tool');
  const nameLower = rawName.toLowerCase();
  const args = {};
  if (tc.args && typeof tc.args === 'object') {
    for (const [k, v] of Object.entries(tc.args)) args[k] = parseJsonArg(v);
  }
  let name = rawName;
  let detail = '';
  if (nameLower === 'run_command' || nameLower === 'execute' || nameLower === 'bash' || nameLower === 'command') {
    name = 'bash';
    detail = String(args.toolSummary || args.CommandLine || args.command || '').replace(/\s+/g, ' ').trim().slice(0, 120);
  } else if (nameLower === 'edit_file' || nameLower === 'edit' || nameLower === 'patch') {
    name = 'edit';
    detail = String(args.Path || args.path || '').slice(0, 120);
  } else if (nameLower === 'write_file' || nameLower === 'write') {
    name = 'write';
    detail = String(args.Path || args.path || '').slice(0, 120);
  } else if (nameLower === 'read_file' || nameLower === 'read') {
    name = 'read';
    detail = String(args.Path || args.path || '').slice(0, 120);
  } else {
    detail = String(args.toolSummary || args.Path || args.path || args.CommandLine || args.command || args.query || '')
      .replace(/\s+/g, ' ').trim().slice(0, 120);
  }
  return {
    id: tc.id || `tc-${stepIndex}-${toolIndex}`,
    name,
    detail,
    state: isError ? 'fail' : 'ok',
  };
}

async function readAgyColdSnapshot(row, limit) {
  let file;
  for (const { dir } of agyHomes()) {
    const candidate = join(dir, 'brain', row.id, '.system_generated', 'logs', 'transcript.jsonl');
    if (existsSync(candidate)) { file = candidate; break; }
  }
  const raw = await readBoundedUtf8(file);
  if (!raw) return undefined;

  const entries = [];
  let currentAssistant;
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let step;
    try { step = JSON.parse(line); } catch { continue; }
    if (!step || typeof step !== 'object') continue;

    if (step.type === 'USER_INPUT') {
      currentAssistant = undefined;
      const text = cleanAgyUserText(step.content ?? '');
      const media = Array.isArray(step.media) ? step.media : [];
      if (text || media.length) {
        entries.push({
          id: `step-${step.step_index ?? entries.length}:user`,
          role: 'user',
          text,
          imageCount: media.length,
        });
      }
      continue;
    }

    if (step.type === 'PLANNER_RESPONSE') {
      if (!currentAssistant) {
        currentAssistant = {
          id: `step-${step.step_index ?? entries.length}:assistant`,
          role: 'assistant',
          text: '',
          thinking: '',
          tools: [],
        };
        entries.push(currentAssistant);
      }
      if (typeof step.thinking === 'string' && step.thinking.trim()) {
        currentAssistant.thinking = currentAssistant.thinking
          ? `${currentAssistant.thinking}\n\n${step.thinking.trim()}`
          : step.thinking.trim();
      }
      if (typeof step.content === 'string' && step.content.trim()) {
        currentAssistant.text = currentAssistant.text
          ? `${currentAssistant.text}\n\n${step.content.trim()}`
          : step.content.trim();
      }
      for (let i = 0; i < (step.tool_calls?.length ?? 0); i += 1) {
        const tc = step.tool_calls[i];
        if (!tc || typeof tc !== 'object') continue;
        if (tc.name === 'update_focus' || tc.name === 'update_steps') continue;
        currentAssistant.tools.push(agyToolSummary(tc, step.step_index, i, step.status === 'ERROR'));
      }
    }
  }

  const filtered = entries.filter((e) => e.role === 'user' || e.text || e.thinking || e.tools?.length);
  if (!filtered.length) return undefined;
  const page = paginateNewestFirst([...filtered].reverse(), limit);
  const firstUser = filtered.find((m) => m.role === 'user' && m.text);
  const resolvedName = row.name || (firstUser ? sessionTitlePreview(firstUser.text) : undefined);
  return { ...page, name: resolvedName };
}

export async function readColdSnapshot(row, { limit = 60 } = {}) {
  if (!row || typeof row.id !== 'string' || typeof row.cwd !== 'string') return undefined;
  const agent = row.agent ?? 'pi';
  let parsed;
  if (agent === 'pi') parsed = await readPiColdSnapshot(row, limit);
  else if (agent === 'codex') parsed = await readCodexColdSnapshot(row, limit);
  else if (agent === 'agy') parsed = await readAgyColdSnapshot(row, limit);
  if (!parsed || !parsed.messages.length) return undefined;

  return {
    session: {
      id: row.id,
      cwd: row.cwd,
      agent,
      name: parsed.name || row.name,
      idle: true,
      queued: false,
      acceptsImage: true,
      warming: true,
    },
    messages: parsed.messages,
    historyCursor: parsed.historyCursor,
    historyLeaf: parsed.historyLeaf,
    cursor: {
      sessionId: row.id,
      streamId: `cold-${row.id}`,
      runId: null,
      seq: 0,
    },
    liveText: '',
    liveSeq: 0,
    liveThinking: '',
    liveThinkSeq: 0,
    tools: [],
    warming: true,
  };
}
