// Shared HTTP + SSE worker core for Pi, Codex CLI and ACP agents.
//
// Listens on a `w-<pid>-<hex>.sock` Unix socket and registers itself via
// `registerSocket()`, speaking the exact private worker socket protocol that
// `host/bridge/broker.mjs` expects from each session.
//
// In addition to the standard routes (/session, /session/snapshot, /chat,
// /history, /tool-detail, /message-image, /message-text, /sessions, /models,
// /commands, /events, /prompt, /upload, /abort, /receipt, /model, /rename,
// /fork), it also serves `GET /pending` and `POST /answer` directly on the
// worker socket (`interactions: 'worker'`), and `POST /shutdown` for clean
// daemon teardown.
import { randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { workerSocket } from '../bridge/local-ipc.mjs';
import { registerSocket } from '../bridge/socket-registry.mjs';
import {
  maxPromptBody, validPromptImage, validPromptImageBuffer, stageAttachment,
  stagedAttachment, safeAttachmentName, promptAttachments, maxImageBytes, maxFileBytes,
} from '../bridge/attachments.mjs';
import {
  imageParts, messageTextSlice, reply, replyImage, sessionAttachmentMarker,
  toolDetail, toolDetails,
} from '../bridge/message-view.mjs';
import { captureWorkspace, describeChangesAsync, referencedArtifacts, saveRunResult } from '../bridge/run-results.mjs';

const maxBody = 16 * 1024;
const messagePreviewLength = 8000;
const messageTextPageLength = 128 * 1024;
const allowedRoutes = new Set([
  'GET /session', 'GET /session/snapshot', 'GET /chat', 'GET /history',
  'GET /tool-detail', 'GET /message-image', 'GET /message-text', 'GET /sessions',
  'GET /models', 'GET /commands', 'GET /events', 'GET /pending',
  'POST /prompt', 'POST /upload', 'POST /abort', 'POST /receipt', 'POST /model',
  'POST /rename', 'POST /fork', 'POST /regenerate', 'POST /answer', 'POST /shutdown',
]);

export async function readJsonBody(request, limit = maxBody) {
  if (request.headers['content-type'] !== 'application/json') throw new Error('invalid_content_type');
  if (Number(request.headers['content-length']) > limit) throw new Error('oversized_body');
  const chunks = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new Error('oversized_body');
    chunks.push(chunk);
  }
  const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error('invalid_body');
  return value;
}

async function readRawBody(request, limit) {
  if (Number(request.headers['content-length']) > limit) throw new Error('oversized_body');
  const chunks = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new Error('oversized_body');
    chunks.push(Buffer.from(chunk));
  }
  const bytes = Buffer.concat(chunks);
  if (bytes.length < 1 || bytes.length > limit) throw new Error('oversized_body');
  return bytes;
}

function* newestFirst(entries) {
  for (let i = entries.length - 1; i >= 0; i -= 1) yield entries[i];
}

function paginateEntries(entries, liveTools, before, limit, previewLength = messagePreviewLength) {
  const messages = [];
  let historyCursor;
  let waitingForCursor = Boolean(before);
  const seenCalls = new Set();
  for (const entry of entries) {
    const atCursor = waitingForCursor && entry.id === before;
    const include = !waitingForCursor || atCursor;
    const text = typeof entry.text === 'string' ? entry.text : '';
    const thinking = entry.role === 'assistant' && typeof entry.thinking === 'string' ? entry.thinking : '';
    const images = Array.isArray(entry.images) ? entry.images : [];
    const imageCount = images.length || (typeof entry.imageCount === 'number' ? entry.imageCount : 0);
    const entryTools = Array.isArray(entry.tools) ? entry.tools.map((tool) => {
      const live = liveTools.get(tool.summary.id);
      const summary = live && !tool.result && !seenCalls.has(tool.summary.id) ? live.summary : tool.summary;
      seenCalls.add(tool.summary.id);
      return summary;
    }) : [];
    if (!include) continue;
    if (!text && !imageCount && !thinking && !entryTools.length) {
      if (atCursor) return undefined;
      continue;
    }
    if (atCursor) {
      waitingForCursor = false;
      continue;
    }
    if (messages.length === limit) {
      historyCursor = messages[messages.length - 1].id;
      break;
    }
    messages.push({
      id: entry.id,
      role: entry.role,
      text: messageTextSlice(text, 0, previewLength),
      imageCount: imageCount || undefined,
      tools: entryTools.length ? entryTools : undefined,
      textTruncated: entry.role === 'assistant' && text.length > previewLength ? true : undefined,
      thinking: thinking ? thinking.slice(0, 16000) : undefined,
      thinkingMs: thinking && typeof entry.thinkingMs === 'number' ? entry.thinkingMs : undefined,
    });
  }
  if (waitingForCursor) return undefined;
  return { messages: messages.reverse(), historyCursor };
}

export function createWorkerServer(driver, {
  profile = resolve(process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi', 'agent')),
  scheduled = process.env.PIGO_SCHEDULED_RESULTS === '1',
  onShutdown,
} = {}) {
  let streamId = randomBytes(16).toString('hex');
  let syncSeq = 0;
  let liveText = '';
  let liveSeq = 0;
  let liveThinking = '';
  let liveThinkSeq = 0;
  let runId;
  let promptError;
  let activePrompt;
  let baseline;
  let baselineLeaf = null;
  let lastStopReason;
  let pingTimer;
  let closing = false;
  const followUpQueue = [];
  const toolLog = new Map();
  const requests = new Map();
  const streams = new Set();
  const sequencedStreams = new Set();
  const streamTargets = new Map();

  const status = () => {
    const base = driver.state();
    if (!base) return undefined;
    const queued = Boolean(base.queued || followUpQueue.length > 0);
    const currentRunId = !base.idle ? (runId ?? base.runId) : undefined;
    return {
      ...base,
      agent: driver.agent,
      idle: Boolean(base.idle) && !currentRunId,
      runId: currentRunId,
      queued,
      interactions: driver.interactions ?? 'worker',
      capabilities: driver.capabilities,
      permission: driver.permission,
    };
  };

  const cursor = (eventRunId = runId) => ({
    sessionId: driver.state()?.id,
    streamId,
    runId: eventRunId ?? null,
    seq: syncSeq,
  });

  const historyLeaf = () => driver.historyLeaf?.() ?? null;

  const emit = (type, data = {}, eventRunId = runId) => {
    syncSeq += 1;
    const current = status();
    if (['session/status', 'session/changed', 'queue/status', 'prompt/unconfirmed', 'interaction/requested'].includes(type)) {
      registration.publish();
    }
    const event = { type, sessionId: current?.id, ...data };
    const legacy = `data: ${JSON.stringify(event)}\n\n`;
    const update = { ...event, cursor: cursor(eventRunId) };
    delete update.seq;
    delete update.thinkingSeq;
    delete update.runId;
    const sequenced = sequencedStreams.size ? `data: ${JSON.stringify(update)}\n\n` : legacy;
    for (const stream of streams) {
      const target = streamTargets.get(stream);
      if (stream.destroyed || stream.writableEnded || stream.writableLength > 512 * 1024 ||
          (target && (current?.id !== target.id || current.cwd !== target.cwd))) {
        stream.destroy();
        continue;
      }
      stream.write(sequencedStreams.has(stream) ? sequenced : legacy);
    }
  };

  const stopPing = () => {
    if (pingTimer) { clearInterval(pingTimer); pingTimer = undefined; }
  };
  const startPing = () => {
    if (pingTimer) return;
    pingTimer = setInterval(() => {
      for (const stream of streams) {
        if (stream.destroyed || stream.writableEnded || stream.writableLength > 512 * 1024) stream.destroy();
        else stream.write(': ping\n\n');
      }
    }, 4000);
    pingTimer.unref();
  };

  function resetSession({ notify = true } = {}) {
    for (const stream of sequencedStreams) stream.destroy();
    streamId = randomBytes(16).toString('hex');
    syncSeq = 0;
    baseline = undefined;
    baselineLeaf = null;
    runId = driver.isStreaming?.() ? randomBytes(16).toString('hex') : undefined;
    lastStopReason = undefined;
    promptError = undefined;
    activePrompt = undefined;
    liveText = '';
    liveSeq = 0;
    liveThinking = '';
    liveThinkSeq = 0;
    toolLog.clear();
    requests.clear();
    followUpQueue.length = 0;
    if (notify) emit('session/changed', { session: status() });
  }

  driver.on('prompt_unconfirmed', (requestId) => {
    promptError = 'unconfirmed';
    activePrompt = undefined;
    emit('prompt/unconfirmed', { requestId });
  });

  driver.on('turn_start', (info = {}) => {
    runId = info.runId || randomBytes(16).toString('hex');
    baseline = undefined;
    lastStopReason = undefined;
    baselineLeaf = historyLeaf();
    promptError = undefined;
    const current = driver.state();
    if ((worker.listening || scheduled) && current?.cwd) {
      try { baseline = captureWorkspace(current.cwd); } catch {}
    }
    liveText = '';
    liveSeq = 0;
    liveThinking = '';
    liveThinkSeq = 0;
    toolLog.clear();
    emit('session/status', { idle: false, runId, queued: status()?.queued ?? false });
  });

  driver.on('delta', (text) => {
    if (typeof text !== 'string' || !text) return;
    liveText = (liveText + text).slice(-16000);
    liveSeq += 1;
    emit('message/delta', { text, seq: liveSeq });
  });

  driver.on('thinking', (text) => {
    if (typeof text !== 'string' || !text) return;
    liveThinking = (liveThinking + text).slice(-16000);
    liveThinkSeq += 1;
    emit('message/thinking', { text, seq: liveThinkSeq });
  });

  driver.on('tool_start', ({ id, name, args, detail }) => {
    const entry = {
      id,
      name,
      detail: typeof detail === 'string' ? detail : toolDetail(args),
      state: 'run',
    };
    toolLog.set(id, { summary: entry, args });
    emit('tool/start', { tool: entry });
  });

  driver.on('tool_end', ({ id, failed, ms, result, detail }) => {
    const activity = toolLog.get(id);
    if (!activity) return;
    activity.summary = {
      ...activity.summary,
      ...(typeof detail === 'string' && detail ? { detail } : {}),
      state: failed ? 'fail' : 'ok',
      ...(typeof ms === 'number' ? { ms } : {}),
    };
    activity.result = result;
    emit('tool/end', { tool: activity.summary });
  });

  driver.on('message_final', (reason = 'stop') => {
    lastStopReason = reason;
    if (activePrompt && reason === 'error') promptError = 'model_error';
    liveText = '';
    liveThinking = '';
    liveSeq += 1;
    liveThinkSeq += 1;
    emit('message/final', { reason, seq: liveSeq, thinkingSeq: liveThinkSeq });
  });

  driver.on('turn_end', async ({ aborted = false, reason } = {}) => {
    if (reason && !lastStopReason) {
      lastStopReason = reason;
      if (activePrompt && reason === 'error') promptError = 'model_error';
      liveText = '';
      liveThinking = '';
      liveSeq += 1;
      liveThinkSeq += 1;
      emit('message/final', { reason, seq: liveSeq, thinkingSeq: liveThinkSeq });
    }
    const settledRunId = runId;
    const current = status();
    if (settledRunId && (worker.listening || scheduled) && current) {
      try {
        const binding = streamId;
        const source = driver.historyEntries?.() ?? driver.entries();
        const entries = driver.historyEntries ? source : newestFirst(await source);
        if (binding !== streamId || settledRunId !== runId) return;
        const turnEntries = driver.agent === 'codex' ? [...entries].filter((entry) => entry.turnId === settledRunId) : entries;
        const recent = paginateEntries(turnEntries, toolLog, null, 60, Infinity);
        const ids = driver.runMessageIds?.(baselineLeaf);
        const recentMessages = recent?.messages ?? [];
        const lastUser = recentMessages.findLastIndex(({ role }) => role === 'user');
        const messages = ids ? recentMessages.filter(({ id }) => ids.has(id)) : recentMessages.slice(Math.max(0, lastUser));
        const anchor = [...messages].reverse().find((message) =>
          message.role === 'assistant' && (message.text || message.imageCount)) ?? messages.at(-1);
        const screenshots = Array.from(toolLog.values()).flatMap(({ summary, result }) => {
          if (!imageParts(result?.content).length) return [];
          const message = messages.find((item) => item.tools?.some(({ id }) => id === summary.id));
          return message ? [{ toolId: summary.id, messageId: message.id }] : [];
        }).slice(0, 6);
        const checks = Array.from(toolLog.values()).flatMap(({ summary, args }) => {
          const command = args?.command;
          if ((summary.name !== 'bash' && summary.name !== 'command') || typeof command !== 'string' ||
            !/(^|[\s/])(tests?|pytest|vitest|jest|ctest|mocha|xctest|xcodebuild|check|lint|typecheck|build)([\s:;]|$)/i.test(command)) return [];
          return [{ id: summary.id, command: command.slice(0, 240), state: summary.state, ms: summary.ms }];
        }).slice(0, 8);
        const finishedAt = Date.now();
        let changes;
        try { changes = await describeChangesAsync(current.cwd, baseline); }
        catch { changes = { files: [], patches: {}, partial: true }; }
        const { files, patches, partial } = changes;
        const resultText = anchor?.role === 'assistant' ? anchor.text : '';
        const references = [...resultText.matchAll(/`([^`\r\n]{1,1024})`|\]\(([^)\r\n]{1,1024})\)/g)]
          .map((match) => match[1] ?? match[2]);
        for (const { summary, args } of toolLog.values()) {
          const path = args?.path;
          if (summary.state === 'ok' && (summary.name === 'write' || summary.name === 'edit' || summary.name === 'patch') && typeof path === 'string') {
            references.push(path);
          }
        }
        for (const path of referencedArtifacts(current.cwd, references)) {
          if (!files.some((file) => file.path === path)) {
            files.push({ path, change: 'artifact', diff: false, artifact: true });
          }
        }
        saveRunResult(profile, {
          id: settledRunId,
          agent: driver.agent,
          sessionId: current.id,
          cwd: current.cwd,
          title: current.name,
          messageId: anchor?.id,
          finishedAt,
          files,
          checks,
          screenshots,
          partial,
          scheduled,
          status: aborted || lastStopReason === 'aborted' ? 'stopped' : lastStopReason === 'error' ? 'failed' : 'completed',
        }, patches, scheduled ? '' : resultText);
      } catch {}
    }
    baseline = undefined;
    lastStopReason = undefined;
    runId = undefined;
    liveText = '';
    liveSeq = 0;
    liveThinking = '';
    liveThinkSeq = 0;
    toolLog.clear();
    activePrompt = undefined;
    emit('session/status', { idle: true, aborted, queued: status()?.queued ?? false }, settledRunId);
    if (!aborted && followUpQueue.length > 0 && !closing) {
      const next = followUpQueue.shift();
      emit('queue/status', { runId: status()?.runId, queued: followUpQueue.length > 0 });
      try { await driver.prompt({ ...next, mode: 'send' }); }
      catch { promptError = 'model_error'; emit('session/changed', { session: status() }); }
    } else if (followUpQueue.length === 0 && !closing) {
      void driver.releaseWriterLock?.();
    }
  });

  driver.on('changed', () => {
    emit('session/changed', { session: status() });
  });

  driver.on('interaction', (interaction) => {
    emit('interaction/requested', { interaction });
  });

  const handle = async (request, response, { local = false } = {}) => {
    const fail = (code, error) => reply(response, code, { error });
    try {
      if (request.headers.origin !== undefined) return fail(403, 'invalid_source');
      const path = (request.url ?? '').split('?')[0];
      const route = `${request.method} ${path}`;
      const open = local && route === 'POST /open' && driver.open;
      if (!open && !allowedRoutes.has(route)) return fail(404, 'not_found');
      if ((status()?.interactions === 'host' || local) &&
          ['GET /pending', 'POST /answer', 'POST /shutdown'].includes(route)) return fail(404, 'not_found');
      if (local && route === 'POST /fork') return fail(404, 'not_found');
      const binding = streamId;

      const targetParams = !local && request.url?.includes('_pigoSession=')
        ? new URL(request.url, 'http://pi-go').searchParams : undefined;
      const targetId = targetParams?.get('_pigoSession');
      const targetCwd = targetParams?.get('_pigoCwd');
      const target = targetId && targetCwd ? { id: targetId, cwd: targetCwd } : undefined;
      if (targetParams) {
        const current = status();
        if (!target || current?.id !== target.id || current.cwd !== target.cwd) {
          return fail(409, 'session_changed');
        }
      }

      if (route === 'POST /shutdown') {
        reply(response, 200, { stopping: true });
        setImmediate(() => { void stopServer(); });
        return;
      }

      if (route === 'GET /events') {
        const sequenced = new URL(request.url ?? '/', 'http://pi-go').searchParams.get('sync') === '2';
        if (sequenced && !status()) return fail(409, 'session_unavailable');
        if (streams.size >= 4) return fail(429, 'too_many_streams');
        request.socket.setTimeout(0);
        response.writeHead(200, {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-store',
          'Connection': 'keep-alive',
        });
        response.write(`data: ${JSON.stringify({ type: 'ready', session: status(), cursor: sequenced ? cursor() : undefined })}\n\n`);
        streams.add(response);
        if (sequenced) sequencedStreams.add(response);
        if (target) streamTargets.set(response, target);
        startPing();
        response.on('close', () => {
          streams.delete(response);
          sequencedStreams.delete(response);
          streamTargets.delete(response);
          if (!streams.size) stopPing();
        });
        return;
      }

      const currentStatus = status();
      if (!currentStatus) return fail(409, 'session_unavailable');

      if (route === 'GET /session') {
        return reply(response, 200, { session: currentStatus, historyDirectory: local ? undefined : driver.historyDirectory });
      }

      if (route === 'GET /pending') {
        const interaction = driver.pendingInteraction?.();
        return reply(response, 200, interaction ? { interaction } : {});
      }

      if (route === 'POST /answer') {
        const input = await readJsonBody(request);
        if (typeof input.pendingId !== 'string' || !driver.respondInteraction?.(input.pendingId, input.answer)) {
          return fail(409, 'interaction_unavailable');
        }
        registration.publish();
        return reply(response, 200, { answered: true });
      }

      if (open) {
        const input = await readJsonBody(request);
        if (binding !== streamId) return fail(409, 'session_changed');
        const result = await driver.open(input.id);
        if (result?.error) return fail(result.status ?? 409, result.error);
        return reply(response, 200, { session: status() });
      }

      const snapshot = route === 'GET /session/snapshot';
      const snapshotHistory = snapshot && new URL(request.url ?? '/', 'http://pi-go').searchParams.get('history') === '1';
      const snapshotData = () => ({
        session: { ...status(), runId: runId ?? null },
        cursor: cursor(),
        historyLeaf: historyLeaf(),
        liveText,
        liveThinking,
        tools: Array.from(toolLog.values(), ({ summary }) => summary),
        promptError,
      });
      if (snapshot && !snapshotHistory) return reply(response, 200, snapshotData());

      if (route === 'GET /models') {
        const { models, current, scoped = false } = await driver.listModels();
        return reply(response, 200, { session: status(), scoped, models, current });
      }

      if (route === 'GET /commands') {
        const commands = (await driver.listCommands?.()) ?? [];
        return reply(response, 200, { session: status(), commands });
      }

      if (route === 'GET /message-text') {
        const parameters = new URL(request.url ?? '/', 'http://pi-go').searchParams;
        if (parameters.get('id') !== status()?.id) return fail(409, 'session_changed');
        const messageId = parameters.get('message');
        const source = driver.entries();
        const entries = Array.isArray(source) ? source : await source;
        if (binding !== streamId || !status()) return fail(409, 'session_changed');
        const entry = entries.find((row) => row.id === messageId);
        if (!entry || entry.role !== 'assistant') return fail(404, 'message_not_found');
        const rawOffset = parameters.get('offset') ?? '0';
        const offset = Number(rawOffset);
        const text = typeof entry.text === 'string' ? entry.text : '';
        if (!/^\d+$/.test(rawOffset) || !Number.isSafeInteger(offset) || offset > text.length ||
          (offset && /[\uDC00-\uDFFF]/.test(text.charAt(offset)))) return fail(400, 'invalid_text_offset');
        const chunk = messageTextSlice(text, offset, messageTextPageLength);
        const end = offset + chunk.length;
        return reply(response, 200, { text: chunk, nextTextOffset: end < text.length ? end : undefined });
      }

      if (snapshotHistory || route === 'GET /chat' || route === 'GET /history' || route === 'GET /tool-detail' || route === 'GET /message-image') {
        const parameters = new URL(request.url ?? '/', 'http://pi-go').searchParams;
        if (!snapshotHistory && route !== 'GET /chat' && parameters.get('id') !== status()?.id) {
          return fail(409, 'session_changed');
        }
        if (snapshotHistory || route === 'GET /chat' || route === 'GET /history') {
          const source = driver.historyEntries?.() ?? driver.entries();
          const entries = driver.historyEntries ? source : newestFirst(Array.isArray(source) ? source : await source);
          if (binding !== streamId || !status()) return fail(409, 'session_changed');
          const limit = route === 'GET /history' ? Math.min(60, Math.max(1, Math.floor(Number(parameters.get('limit')) || 60))) : 60;
          const history = paginateEntries(entries, toolLog, parameters.get('before'), limit);
          if (!history) return fail(409, 'history_changed');
          const page = { session: status(), ...history };
          if (snapshotHistory) return reply(response, 200, { ...page, ...snapshotData() });
          if (route === 'GET /history' && parameters.get('sync') === '2') {
            return reply(response, 200, { ...page, historyLeaf: historyLeaf(), cursor: cursor() });
          }
          return reply(response, 200, {
            ...page,
            liveText,
            liveSeq,
            liveThinking,
            liveThinkSeq,
            tools: Array.from(toolLog.values(), ({ summary }) => summary),
            promptError,
          });
        }
        const source = driver.entries();
        const entries = Array.isArray(source) ? source : await source;
        if (binding !== streamId || !status()) return fail(409, 'session_changed');
        const imageIndex = parameters.get('index');
        const toolId = parameters.get('tool');
        if (route === 'GET /message-image') {
          if (!imageIndex || !/^\d{1,6}$/.test(imageIndex)) return fail(400, 'invalid_image_index');
          if (!toolId) {
            const entry = entries.find((row) => row.id === parameters.get('message'));
            if (!entry || !['user', 'assistant'].includes(entry.role)) return fail(404, 'image_not_found');
            const idx = Number(imageIndex);
            const target = (entry.images ?? [])[idx];
            if (!target) return fail(404, 'image_not_found');
            let data = target.data;
            if ((!data || typeof data !== 'string') && typeof target.path === 'string') {
              try {
                const info = lstatSync(target.path);
                if (!info.isFile() || info.size > maxImageBytes) return fail(404, 'image_not_found');
                const resolved = realpathSync(target.path);
                const allowedRoots = [status()?.cwd, driver.historyDirectory, tmpdir()]
                  .filter((dir) => typeof dir === 'string' && dir)
                  .map((dir) => { try { return realpathSync(dir); } catch { return undefined; } })
                  .filter(Boolean);
                if (!allowedRoots.some((root) => resolved === root || resolved.startsWith(root + sep))) {
                  return fail(403, 'path_forbidden');
                }
                data = readFileSync(resolved).toString('base64');
              } catch { return fail(404, 'image_not_found'); }
            }
            return replyImage(response, [{ type: 'image', mimeType: target.mimeType, data }], 0);
          }
        }
        const toolsByMessage = new Map();
        const latestById = new Map();
        for (const entry of entries) {
          if (entry.role !== 'assistant' || !Array.isArray(entry.tools)) continue;
          toolsByMessage.set(entry.id, entry.tools);
          for (const activity of entry.tools) latestById.set(activity.summary.id, activity);
        }
        const id = parameters.get('tool') ?? '';
        const messageId = parameters.get('message');
        const saved = messageId ? toolsByMessage.get(messageId)?.find(({ summary }) => summary.id === id) : latestById.get(id);
        const live = !messageId || (saved && latestById.get(id) === saved) ? toolLog.get(id) : undefined;
        const activity = saved?.result !== undefined ? saved : live ?? saved;
        if (!activity) return fail(404, 'tool_not_found');
        if (route === 'GET /message-image') {
          return replyImage(response, activity.result?.content, Number(imageIndex));
        }
        return reply(response, 200, { toolDetail: toolDetails(activity, parameters.get('images') === '1') });
      }

      if (route === 'GET /sessions') {
        const parameters = new URL(request.url ?? '/', 'http://pi-go').searchParams;
        const query = (parameters.get('query') ?? '').trim().toLowerCase().slice(0, 100);
        const cursorParam = Number(parameters.get('cursor') ?? '0');
        const limit = Math.min(Math.max(Math.floor(Number(parameters.get('limit') ?? '50') || 50), 1), 100);
        const history = (await driver.listProjectSessions?.()) ?? [];
        const current = status();
        const rows = history.slice(0, 250).map((row) => ({
          ...row,
          agent: driver.agent,
          name: (row.id === current?.id ? current.name : row.name) || row.name,
        }));
        const filtered = query ? rows.filter((row) =>
          `${row.name ?? ''} ${row.id} ${row.cwd ?? ''}`.toLowerCase().includes(query)) : rows;
        const start = Number.isInteger(cursorParam) && cursorParam >= 0 ? Math.min(cursorParam, filtered.length) : 0;
        const sessions = filtered.slice(start, start + limit);
        return reply(response, 200, {
          current,
          sessions,
          total: filtered.length,
          nextCursor: start + limit < filtered.length ? start + limit : undefined,
        });
      }

      if (route === 'POST /model') {
        const input = await readJsonBody(request);
        if (binding !== streamId || input.id !== status()?.id) return fail(409, 'session_changed');
        if (!driver.validateModelBeforeBusy && (!status()?.idle || status()?.queued)) return fail(409, 'session_busy');
        const applied = await driver.setModel({
          provider: input.provider,
          modelId: input.modelId,
          thinkingLevel: input.thinkingLevel,
        });
        if (applied?.error) return fail(applied.status ?? 409, applied.error);
        emit('session/changed', { session: status() });
        return reply(response, 200, { session: status(), current: applied.current });
      }

      if (route === 'POST /fork' || route === 'POST /regenerate') {
        const input = await readJsonBody(request);
        if (binding !== streamId || input.id !== status()?.id) return fail(409, 'session_changed');
        if (!status()?.idle || status()?.queued) return fail(409, 'session_busy');
        if (route === 'POST /regenerate') {
          if (!driver.regenerate) return fail(409, 'regenerate_failed');
          const res = await driver.regenerate(input.messageId);
          if (res?.error) return fail(res.status ?? 409, res.error);
          return reply(response, 202, { dispatched: true });
        }
        if (!driver.fork) return fail(409, 'session_not_persisted');
        const res = await driver.fork(input.messageId);
        if (res?.error) return fail(res.status ?? 409, res.error);
        return reply(response, 200, { id: res.id, agent: driver.agent === 'pi' ? undefined : driver.agent });
      }

      if (route === 'POST /rename') {
        const input = await readJsonBody(request);
        if (binding !== streamId || input.id !== status()?.id) return fail(409, 'session_changed');
        if (typeof input.name !== 'string' || !input.name.trim() || input.name.length > 200 ||
          input.name.trim() !== input.name || /[\r\n\0]/.test(input.name)) return fail(400, 'invalid_name');
        const ok = await driver.rename(input.name);
        if (!ok) return fail(409, 'rename_failed');
        emit('session/changed', { session: status() });
        return reply(response, 200, { session: status() });
      }

      if (route === 'POST /upload') {
        if (request.headers['content-type'] !== 'application/octet-stream') return fail(400, 'invalid_content_type');
        const parameters = new URL(request.url ?? '/', 'http://pi-go').searchParams;
        const kind = parameters.get('kind');
        const name = safeAttachmentName(parameters.get('name') ?? '');
        if ((kind !== 'image' && kind !== 'file') || !name) return fail(400, 'invalid_attachment');
        const bytes = await readRawBody(request, kind === 'image' ? maxImageBytes : maxFileBytes);
        if (kind === 'image' && !validPromptImageBuffer(bytes)) return fail(400, 'invalid_image');
        try {
          const staged = stageAttachment(status().cwd, name, bytes);
          return reply(response, 200, {
            attachment: { token: staged.token, kind, name: staged.name, size: staged.size, path: staged.path },
          });
        } catch {
          return fail(400, 'invalid_attachment');
        }
      }

      if (route === 'POST /prompt' || route === 'POST /abort' || route === 'POST /receipt') {
        const input = await readJsonBody(request, route === 'POST /prompt' ? maxPromptBody : maxBody);
        if (binding !== streamId || input.id !== status()?.id) return fail(409, 'session_changed');
        if (route === 'POST /abort') {
          followUpQueue.length = 0;
          await driver.abort();
          return reply(response, 202, { dispatched: true });
        }
        if (typeof input.requestId !== 'string' || !/^[\w-]{1,80}$/.test(input.requestId)) {
          return fail(400, 'invalid_request_id');
        }
        if (route === 'POST /receipt') {
          return reply(response, 200, { dispatched: requests.get(input.requestId) === input.id, requestId: input.requestId });
        }
        const mode = input.mode ?? 'send';
        const hasImage = input.image !== undefined;
        const attachments = promptAttachments(input.attachments);
        if (attachments === undefined) return fail(400, 'invalid_attachment');
        const imageCount = attachments.filter((item) => item.kind === 'image').length + (hasImage ? 1 : 0);
        const fileCount = attachments.filter((item) => item.kind === 'file').length;
        if (typeof input.text !== 'string' || (!input.text.trim() && imageCount === 0 && fileCount === 0) ||
          Buffer.byteLength(input.text) > 12000 ||
          (mode !== 'send' && mode !== 'steer' && mode !== 'followUp')) return fail(400, 'invalid_prompt');

        const commandText = input.text.trimStart().startsWith('/') ? input.text.trimStart() : undefined;
        const commandName = commandText !== undefined ? (commandText.slice(1).split(/\s/, 1)[0] ?? '') : undefined;
        const commands = commandName ? ((await driver.listCommands?.()) ?? []) : [];
        if (binding !== streamId || input.id !== status()?.id) return fail(409, 'session_changed');
        const command = commandName !== undefined && commandName !== '' && /^[\w:.-]{1,80}$/.test(commandName)
          ? commands.find((row) => row.name === commandName) : undefined;
        if (commandName !== undefined && commandName !== '' && !command) return fail(400, 'unknown_command');
        if (command && (imageCount > 0 || fileCount > 0)) return fail(400, 'command_attachments');
        if (commandName !== undefined && commandName === '') return fail(400, 'invalid_prompt');
        if (hasImage && (typeof input.image !== 'string' || !validPromptImage(input.image))) return fail(400, 'invalid_image');
        if (imageCount > 0 && status()?.acceptsImage !== true) return fail(409, 'image_not_supported');
        if (requests.has(input.requestId)) return fail(409, 'duplicate_request');

        const current = status();
        const idle = current.idle;
        if (mode === 'send' && (current.queued || !idle)) return fail(409, 'session_busy');
        if (mode !== 'send' && (idle || !runId || input.runId !== runId)) return fail(409, 'session_not_streaming');
        if (requests.size >= 1024) return fail(429, 'probe_request_limit');

        const stagedImages = [];
        const stagedFiles = [];
        for (const item of attachments) {
          const staged = stagedAttachment(current.cwd, item.token);
          if (!staged) return fail(409, 'unknown_attachment');
          (item.kind === 'image' ? stagedImages : stagedFiles).push({ name: staged.name, path: staged.path });
        }
        if (hasImage) {
          const bytes = Buffer.from(input.image, 'base64');
          const staged = driver.stageInlineImage === false ? { name: 'prompt.jpg' } : stageAttachment(current.cwd, 'prompt.jpg', bytes);
          stagedImages.unshift({ ...staged, bytes });
        }
        for (const staged of stagedImages) {
          const bytes = staged.bytes ?? readFileSync(staged.path);
          if (!validPromptImageBuffer(bytes)) return fail(400, 'invalid_image');
          staged.bytes = bytes;
        }
        let text = command !== undefined ? (commandText ?? input.text) : input.text;
        if (stagedFiles.length) {
          const lines = stagedFiles.map((file) => `- ${file.name}：${file.path}`);
          text = `${text}${sessionAttachmentMarker}${stagedFiles.length} 个文件：\n${lines.join('\n')}`;
        }

        requests.set(input.requestId, input.id);
        activePrompt = input.requestId;
        promptError = undefined;

        const payload = {
          text,
          command,
          images: stagedImages,
          files: stagedFiles,
          mode,
          runId,
          requestId: input.requestId,
        };

        if (driver.dispatchAfterReply?.(command)) {
          let sent = false;
          const dispatch = () => {
            if (sent || binding !== streamId || closing) return;
            sent = true;
            driver.prompt(payload);
          };
          response.once('finish', dispatch);
          setTimeout(dispatch, 250).unref();
          return reply(response, 202, { dispatched: true, requestId: input.requestId, handled: true });
        }
        if (driver.nativeQueue) {
          try {
            driver.prompt(payload);
          } catch {
            requests.delete(input.requestId);
            activePrompt = undefined;
            return fail(409, 'session_busy');
          }
          if (mode !== 'send') {
            const queuedRun = runId;
            emit('queue/status', { runId: queuedRun, queued: true });
            setTimeout(() => {
              const current = status();
              if (current && binding === streamId && queuedRun === runId) {
                emit('queue/status', { runId: current.runId, queued: current.queued });
              }
            }, 250).unref();
          }
          return reply(response, 202, { dispatched: true, requestId: input.requestId });
        }

        if (mode === 'followUp') {
          followUpQueue.push(payload);
          emit('queue/status', { runId, queued: true });
          return reply(response, 202, { dispatched: true, requestId: input.requestId });
        }
        if (mode === 'steer') {
          if (driver.capabilities?.steer === false) {
            followUpQueue.push(payload);
            emit('queue/status', { runId, queued: true });
            return reply(response, 202, { dispatched: true, requestId: input.requestId });
          }
          await driver.prompt(payload);
          emit('queue/status', { runId, queued: followUpQueue.length > 0 });
          return reply(response, 202, { dispatched: true, requestId: input.requestId });
        }

        try {
          await driver.prompt(payload);
        } catch (error) {
          requests.delete(input.requestId);
          activePrompt = undefined;
          if (error?.message === 'session_occupied') return fail(409, 'session_occupied');
          promptError = 'model_error';
          emit('session/changed', { session: status() });
          return fail(409, 'session_busy');
        }
        return reply(response, 202, { dispatched: true, requestId: input.requestId });
      }

      return fail(404, 'not_found');
    } catch (cause) {
      if (!response.headersSent) {
        if (cause instanceof Error && cause.message === 'oversized_body') {
          response.setHeader('Connection', 'close');
          request.resume();
          return fail(413, 'payload_too_large');
        }
        fail(400, 'request_failed');
      } else {
        response.destroy();
      }
    }
  };

  const options = { requestTimeout: 10000, headersTimeout: 5000, connectionsCheckingInterval: 1000 };
  const worker = createServer(options, (request, response) => handle(request, response));
  const registration = registerSocket(worker, () => ({
    session: status(),
    historyDirectory: driver.historyDirectory,
  }));
  worker.maxConnections = 12;
  worker.setTimeout(10000, (socket) => socket.destroy());
  let socketPath;
  let listening;

  async function listen() {
    if (listening) return listening;
    if (worker.listening) return socketPath;
    socketPath = workerSocket();
    listening = new Promise((resolvePromise, reject) => {
      worker.once('error', reject);
      worker.listen(socketPath, () => { worker.off('error', reject); resolvePromise(socketPath); });
    });
    try { return await listening; }
    finally { listening = undefined; }
  }

  function unlisten() {
    registration.withdraw();
    worker.close();
    worker.closeAllConnections();
  }

  async function stopServer() {
    if (closing) return;
    closing = true;
    stopPing();
    for (const stream of streams) stream.destroy();
    unlisten();
    await driver.stop?.();
    await onShutdown?.();
  }

  return { worker, listen, unlisten, stop: stopServer, status, handle, resetSession, publish: registration.publish, get socketPath() { return socketPath; } };
}
