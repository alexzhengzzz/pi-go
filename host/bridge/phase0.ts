import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager, type ExtensionAPI, type ExtensionCommandContext, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ipcDirectory, localRequest, workerSocket } from "./local-ipc.mjs";
import { registerSocket } from "./socket-registry.mjs";
import { pairingRuntime } from "./pairing-runtime.mjs";
import { maxPromptBody, validPromptImage, validPromptImageBuffer, stageAttachment, stagedAttachment, safeAttachmentName,
  promptAttachments, maxImageBytes, maxFileBytes } from "./attachments.mjs";
import { generatedSessionTitle, imageParts, messageText, messageTextSlice, reply, replyImage, sessionAttachmentMarker,
  sessionPromptText, sessionTitlePreview, toolDetail, toolDetails, toolResultText } from "./message-view.mjs";

import { captureWorkspace, describeChanges, referencedArtifacts, saveRunResult } from "./run-results.mjs";

const profile = resolve(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"));
const host = "127.0.0.1";
const maxBody = 16 * 1024;
const messagePreviewLength = 8000;
const messageTextPageLength = 128 * 1024;
const digest = (value: string) => createHash("sha256").update(value).digest();
const same = (value: unknown, expected: Buffer | undefined) =>
  typeof value === "string" && expected !== undefined && timingSafeEqual(digest(value), expected);
const thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
type ModelLike = { provider: string; id: string; name: string; input?: string[]; reasoning: boolean; thinkingLevelMap?: Record<string, string | null> };
const levelsOf = (model: ModelLike | undefined) =>
  !model?.reasoning ? ["off"] : thinkingLevels.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
const modelRow = (model: ModelLike) =>
  ({ provider: model.provider, id: model.id, name: model.name || model.id, levels: levelsOf(model), reasoning: model.reasoning === true, image: model.input?.includes("image") === true });

type LiveToolStatus = { id: string; name: string; detail: string; state: "unknown" | "run" | "ok" | "fail"; ms?: number };
type ToolActivity = { summary: LiveToolStatus; args: unknown; result?: unknown };

function historyPage(manager: ExtensionContext["sessionManager"], liveTools: ReadonlyMap<string, ToolActivity>,
  before: string | null, limit: number) {
  const results = new Map<string, "ok" | "fail">();
  const seenLiveCalls = new Set<string>();
  const messages = [];
  let historyCursor: string | undefined;
  let waitingForCursor = Boolean(before);
  for (let entry = manager.getLeafEntry(); entry; entry = entry.parentId ? manager.getEntry(entry.parentId) : undefined) {
    const atCursor = waitingForCursor && entry.id === before;
    const include = !waitingForCursor || atCursor;
    if (entry.type !== "message") continue;
    const { role, content } = entry.message;
    if (role === "toolResult") {
      const { toolCallId, isError } = entry.message;
      if (!results.has(toolCallId)) results.set(toolCallId, isError ? "fail" : "ok");
      continue;
    }
    if (role !== "user" && role !== "assistant") continue;
    const tools: LiveToolStatus[] = [];
    const parts = Array.isArray(content) ? content : [];
    if (role === "assistant") {
      // A result belongs to the preceding call with that ID. Later calls can own the live status.
      for (let index = content.length - 1; index >= 0; index -= 1) {
        const part = content[index];
        if (part.type !== "toolCall") continue;
        const state = results.get(part.id);
        results.delete(part.id);
        const live = liveTools.get(part.id);
        if (include) {
          tools.push(!state && live && !seenLiveCalls.has(part.id) ? live.summary :
            { id: part.id, name: part.name, detail: toolDetail(part.arguments), state: state ?? "unknown" });
        }
        if (live) seenLiveCalls.add(part.id);
      }
    }
    if (!include) continue;
    const text = messageText(content);
    const thinking = role === "assistant" ? content.flatMap((part) =>
      part.type === "thinking" && typeof part.thinking === "string" ? [part.thinking] : []).join("\n") : "";
    const imageCount = parts.filter((part) => part.type === "image").length;
    if (!text && !imageCount && !thinking && !tools.length) {
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
    const durationMs = role === "assistant" ? (entry.message as { durationMs?: number }).durationMs : undefined;
    messages.push({
      id: entry.id, role, text: messageTextSlice(text, 0, messagePreviewLength), imageCount,
      tools: tools.length ? tools.reverse() : undefined,
      textTruncated: role === "assistant" && text.length > messagePreviewLength ? true : undefined,
      thinking: thinking ? thinking.slice(0, 16000) : undefined,
      thinkingMs: thinking ? durationMs : undefined,
    });
  }
  if (waitingForCursor) return undefined;
  return { messages: messages.reverse(), historyCursor };
}

async function body(request: IncomingMessage, limit = maxBody) {
  if (request.headers["content-type"] !== "application/json") throw new Error();
  if (Number(request.headers["content-length"]) > limit) throw new Error("oversized_body");
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new Error("oversized_body");
    chunks.push(chunk);
  }
  const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (value === undefined || Array.isArray(value) || typeof value !== "object") throw new Error();
  return value;
}

async function rawBody(request: IncomingMessage, limit: number): Promise<Buffer> {
  if (Number(request.headers["content-length"]) > limit) throw new Error("oversized_body");
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new Error("oversized_body");
    chunks.push(Buffer.from(chunk));
  }
  const bytes = Buffer.concat(chunks);
  if (bytes.length < 1 || bytes.length > limit) throw new Error("oversized_body");
  return bytes;
}

type PromptContentPart = { type: "text"; text: string } | { type: "image"; mimeType: string; data: string };
const regenerateCommand = "pi-go-regenerate";
const hasReplyContent = (content: readonly { type: string; text?: string }[]) =>
  content.some((part) => part.type === "image" || (part.type === "text" && !!part.text));

function createProbe() {
  let runtime: { pi: ExtensionAPI; ctx: ExtensionContext } | undefined;
  let firstUserSeen = false;
  let titlePreview: string | undefined;
  let titleRequest: AbortController | undefined;
  let historyDirectory: string | undefined;
  let command: ExtensionCommandContext | undefined;
  let directory: string | undefined;
  let ticket: Buffer | undefined;
  let code: Buffer | undefined;
  let attempts = 0;
  let token: Buffer | undefined;
  let expiry: NodeJS.Timeout | undefined;
  let dispatchTimer: NodeJS.Timeout | undefined;
  let regenerate: { nonce: string; run: (ctx: ExtensionCommandContext) => Promise<void> } | undefined;
  let switching = false;
  let liveText = "";
  let liveSeq = 0;
  let liveThinking = "";
  let liveThinkSeq = 0;
  const toolLog = new Map<string, ToolActivity>();
  let pingTimer: NodeJS.Timeout | undefined;
  let activePrompt: string | undefined;
  let promptError: string | undefined;
  let runId: string | undefined;
  let baseline: ReturnType<typeof captureWorkspace> | undefined;
  let lastStopReason: string | undefined;
  let baselineLeaf: string | null = null;
  const scheduled = process.env.PIGO_SCHEDULED_RESULTS === "1";
  let streamId = "";
  let syncSeq = 0;
  const requests = new Map<string, string>();
  const streams = new Set<ServerResponse>();
  const sequencedStreams = new Set<ServerResponse>();
  const streamTargets = new Map<ServerResponse, { id: string; cwd: string }>();
  const status = () => {
    const ctx = runtime?.ctx;
    return ctx && { id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd, name: ctx.sessionManager.getSessionName() || titlePreview,
      idle: ctx.isIdle() && !dispatchTimer, runId: ctx.isIdle() ? undefined : runId, queued: ctx.hasPendingMessages(),
      acceptsImage: ctx.model?.input.includes("image") === true,
      model: ctx.model && modelRow(ctx.model), thinkingLevel: ctx.thinkingLevel };
  };
  const cursor = (eventRunId = runId) => ({
    sessionId: runtime?.ctx.sessionManager.getSessionId(), streamId, runId: eventRunId ?? null, seq: syncSeq,
  });
  const historyLeaf = () => runtime?.ctx.sessionManager.getLeafId() ?? null;
  const emit = (type: string, data: object, eventRunId = runId) => {
    syncSeq += 1;
    const current = status();
    if (["session/status", "session/changed", "queue/status", "prompt/unconfirmed"].includes(type)) registration.publish();
    const event = { type, sessionId: current?.id, ...data };
    const legacy = `data: ${JSON.stringify(event)}\n\n`;
    const update = { ...event, cursor: cursor(eventRunId) } as typeof event & {
      cursor: ReturnType<typeof cursor>; seq?: number; thinkingSeq?: number; runId?: string;
    };
    delete update.seq;
    delete update.thinkingSeq;
    delete update.runId;
    const sequenced = sequencedStreams.size ? `data: ${JSON.stringify(update)}\n\n` : legacy;
    for (const stream of streams) {
      const target = streamTargets.get(stream);
      if ((target && (current?.id !== target.id || current.cwd !== target.cwd)) || !stream.write(sequencedStreams.has(stream) ? sequenced : legacy)) stream.destroy();
    }
  };
  const stopPing = () => {
    if (pingTimer) { clearInterval(pingTimer); pingTimer = undefined; }
  };
  const startPing = () => {
    if (pingTimer) return;
    pingTimer = setInterval(() => {
      for (const stream of streams) if (!stream.write(": ping\n\n")) stream.destroy();
    }, 4000);
    pingTimer.unref();
  };
  const clearDispatch = () => {
    clearTimeout(dispatchTimer);
    dispatchTimer = undefined;
  };
  const trackDispatch = (requestId?: string, onUnconfirmed?: () => Promise<void>) => {
    activePrompt = requestId;
    promptError = undefined;
    const timer = setTimeout(async () => {
      if (onUnconfirmed) {
        try { await onUnconfirmed(); } catch { /* The previous reply is still in the session tree. */ }
        if (dispatchTimer !== timer) return;
      }
      clearDispatch();
      regenerate = undefined;
      promptError = "unconfirmed";
      activePrompt = undefined;
      emit("prompt/unconfirmed", { requestId });
    }, 5000).unref();
    dispatchTimer = timer;
    registration.publish();
    return timer;
  };
  const removeTicket = () => {
    ticket = undefined;
    code = undefined;
    clearTimeout(expiry);
    if (directory) rmSync(directory, { recursive: true, force: true });
    directory = undefined;
  };
  const options = { requestTimeout: 5000, headersTimeout: 5000, connectionsCheckingInterval: 1000 };
  const handle = (privateSocket: boolean) => async (request: IncomingMessage, response: ServerResponse) => {
    const fail = (code: number, error: string) => reply(response, code, { error });
    try {
      const address = server.address();
      if (request.headers.origin !== undefined || (!privateSocket && (!address || typeof address === "string" || request.headers.host !== `${host}:${address.port}`))) {
        return fail(403, "invalid_source");
      }
      const path = (request.url ?? "").split("?")[0];
      const route = `${request.method} ${path}`;
      if (privateSocket && !["GET /session", "GET /session/snapshot", "GET /chat", "GET /history", "GET /tool-detail", "GET /message-image", "GET /message-text", "GET /sessions", "GET /models", "GET /commands", "GET /events", "POST /prompt", "POST /upload", "POST /abort", "POST /receipt", "POST /model", "POST /rename", "POST /fork", "POST /regenerate"].includes(route)) {
        return fail(404, "not_found");
      }
      if (route === "POST /pair") {
        const input = await body(request);
        if (!same(input.ticket, ticket) && !same(input.ticket, code)) {
          if (ticket && ++attempts >= 5) removeTicket();
          return fail(401, "invalid_ticket");
        }
        removeTicket();
        const secret = randomBytes(32).toString("hex");
        token = digest(`Bearer ${secret}`);
        return reply(response, 200, { token: secret });
      }
      if (!privateSocket && !same(request.headers.authorization, token)) return fail(401, "unpaired");
      const targetParams = privateSocket && request.url?.includes('_pigoSession=') ?
        new URL(request.url, 'http://pi-go').searchParams : undefined;
      const targetId = targetParams?.get('_pigoSession');
      const targetCwd = targetParams?.get('_pigoCwd');
      const target = targetId && targetCwd ? { id: targetId, cwd: targetCwd } : undefined;
      if (targetParams) {
        const current = status();
        if (!target || switching || current?.id !== target.id || current.cwd !== target.cwd) return fail(409, "session_changed");
      }
      if (route === "GET /events") {
        const sequenced = new URL(request.url ?? "/", "http://pi-go").searchParams.get("sync") === "2";
        if (sequenced && (!runtime || switching)) return fail(409, "session_unavailable");
        if (streams.size >= 4) return fail(429, "too_many_streams");
        request.socket.setTimeout(0);
        response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", "Connection": "keep-alive" });
        response.write(`data: ${JSON.stringify({ type: "ready", session: status(), cursor: sequenced ? cursor() : undefined })}\n\n`);
        streams.add(response);
        if (sequenced) sequencedStreams.add(response);
        if (target) streamTargets.set(response, target);
        startPing();
        response.on("close", () => {
          streams.delete(response);
          sequencedStreams.delete(response);
          streamTargets.delete(response);
          if (!streams.size) stopPing();
        });
        return;
      }
      if (!runtime || switching) return fail(409, "session_unavailable");
      if (route === "GET /session") {
        return reply(response, 200, { session: status(), historyDirectory: privateSocket ? historyDirectory : undefined });
      }
      const snapshot = route === "GET /session/snapshot";
      const snapshotHistory = snapshot && new URL(request.url ?? "/", "http://pi-go").searchParams.get("history") === "1";
      const snapshotData = () => ({ session: { ...status(), runId: runId ?? null }, cursor: cursor(), historyLeaf: historyLeaf(),
        liveText, liveThinking, tools: Array.from(toolLog.values(), ({ summary }) => summary), promptError });
      if (snapshot && !snapshotHistory) return reply(response, 200, snapshotData());
      const active = runtime;
      if (route === "GET /models") {
        const scoped = active.ctx.scopedModels;
        const source = scoped.length ? scoped.map((entry) => entry.model) : active.ctx.modelRegistry.getAvailable();
        const seen = new Set<string>();
        const models = source.filter((model) => {
          const key = `${model.provider}/${model.id}`;
          if (seen.has(key)) return false;
          seen.add(key);
          return true;
        }).map(modelRow);
        const current = active.ctx.model;
        return reply(response, 200, {
          session: status(), scoped: scoped.length > 0,
          models,
          current: current && { ...modelRow(current), thinkingLevel: active.ctx.thinkingLevel, levels: levelsOf(current) },
        });
      }
      if (route === "GET /commands") {
        const commands = active.pi.getCommands().filter((command) => command.name !== regenerateCommand).map((command) => ({
          name: command.name,
          description: typeof command.description === "string" ? command.description.slice(0, 300) : undefined,
          source: command.source,
          invoke: `/${command.name}`,
        }));
        return reply(response, 200, { session: status(), commands });
      }
      if (route === "GET /message-text") {
        const parameters = new URL(request.url ?? "/", "http://pi-go").searchParams;
        if (parameters.get("id") !== status()?.id) return fail(409, "session_changed");
        const messageId = parameters.get("message");
        const entry = active.ctx.sessionManager.getBranch().find((entry) => entry.id === messageId);
        if (entry?.type !== "message" || entry.message.role !== "assistant") return fail(404, "message_not_found");
        const rawOffset = parameters.get("offset") ?? "0";
        const offset = Number(rawOffset);
        const text = messageText(entry.message.content);
        if (!/^\d+$/.test(rawOffset) || !Number.isSafeInteger(offset) || offset > text.length ||
          (offset && /[\uDC00-\uDFFF]/.test(text.charAt(offset)))) return fail(400, "invalid_text_offset");
        const chunk = messageTextSlice(text, offset, messageTextPageLength);
        const end = offset + chunk.length;
        return reply(response, 200, { text: chunk, nextTextOffset: end < text.length ? end : undefined });
      }
      if (snapshotHistory || route === "GET /chat" || route === "GET /history" || route === "GET /tool-detail" || route === "GET /message-image") {
        const parameters = new URL(request.url ?? "/", "http://pi-go").searchParams;
        if (!snapshotHistory && route !== "GET /chat" && parameters.get("id") !== status()?.id) return fail(409, "session_changed");
        if (snapshotHistory || route === "GET /chat" || route === "GET /history") {
          const limit = route === "GET /history" ? Math.min(60, Math.max(1, Math.floor(Number(parameters.get("limit")) || 60))) : 60;
          const history = historyPage(active.ctx.sessionManager, toolLog, parameters.get("before"), limit);
          if (!history) return fail(409, "history_changed");
          const page = { session: status(), ...history };
          if (snapshotHistory) return reply(response, 200, { ...page, ...snapshotData() });
          if (route === "GET /history" && parameters.get("sync") === "2") {
            return reply(response, 200, { ...page, historyLeaf: historyLeaf(), cursor: cursor() });
          }
          return reply(response, 200, { ...page, liveText, liveSeq, liveThinking, liveThinkSeq,
            tools: Array.from(toolLog.values(), ({ summary }) => summary), promptError });
        }
        const branch = active.ctx.sessionManager.getBranch();
        const imageIndex = parameters.get("index");
        const toolId = parameters.get("tool");
        if (route === "GET /message-image") {
          if (!imageIndex || !/^\d{1,6}$/.test(imageIndex)) return fail(400, "invalid_image_index");
          if (!toolId) {
            const entry = branch.find((entry) => entry.id === parameters.get("message"));
            if (entry?.type !== "message" || !["user", "assistant"].includes(entry.message.role)) return fail(404, "image_not_found");
            return replyImage(response, entry.message.content, Number(imageIndex));
          }
        }
        const toolsByMessage = new Map<string, ToolActivity[]>();
        const latestById = new Map<string, ToolActivity>();
        for (const entry of branch) {
          if (entry.type !== "message") continue;
          const message = entry.message;
          if (message.role === "assistant") {
            const calls: ToolActivity[] = [];
            for (const part of message.content) {
              if (part.type !== "toolCall") continue;
              const activity: ToolActivity = {
                summary: { id: part.id, name: part.name, detail: toolDetail(part.arguments), state: "unknown" },
                args: part.arguments,
              };
              calls.push(activity);
              latestById.set(part.id, activity);
            }
            if (calls.length) toolsByMessage.set(entry.id, calls);
          } else if (message.role === "toolResult") {
            const activity = latestById.get(message.toolCallId);
            if (activity) {
              activity.summary.state = message.isError ? "fail" : "ok";
              activity.result = message;
            }
          }
        }
        const id = parameters.get("tool") ?? "";
        const messageId = parameters.get("message");
        const saved = messageId ? toolsByMessage.get(messageId)?.find(({ summary }) => summary.id === id) : latestById.get(id);
        const live = !messageId || (saved && latestById.get(id) === saved) ? toolLog.get(id) : undefined;
        const activity = saved?.result !== undefined ? saved : live ?? saved;
        if (!activity) return fail(404, "tool_not_found");
        if (route === "GET /message-image") {
          return replyImage(response, (activity.result as { content?: unknown })?.content, Number(imageIndex));
        }
        return reply(response, 200, { toolDetail: toolDetails(activity, parameters.get("images") === "1") });
      }
      const catalog = async () => {
        let folder: string;
        try { folder = realpathSync(active.ctx.sessionManager.getSessionDir()); }
        catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return []; throw error; }
        const cwd = realpathSync(active.ctx.cwd);
        const rows = await SessionManager.list(cwd, folder);
        return rows.filter((row) => {
          try { return realpathSync(row.cwd) === cwd && dirname(realpathSync(row.path)) === folder; }
          catch { return false; }
        });
      };
      if (route === "GET /sessions") {
        const parameters = new URL(request.url ?? "/", "http://pi-go").searchParams;
        const query = (parameters.get("query") ?? "").trim().toLowerCase().slice(0, 100);
        const cursor = Number(parameters.get("cursor") ?? "0");
        const limit = Math.min(Math.max(Math.floor(Number(parameters.get("limit") ?? "50") || 50), 1), 100);
        const history = await catalog();
        const current = status();
        const rows = history.slice(0, 250).map(({ id, name, firstMessage, modified, messageCount, cwd }) =>
          ({ id, name: (id === current?.id ? current.name : name) ||
            (firstMessage === "(no messages)" ? undefined : sessionTitlePreview(firstMessage)), modified, messageCount, cwd }));
        const filtered = query ? rows.filter((row) =>
          `${row.name ?? ""} ${row.id} ${row.cwd ?? ""}`.toLowerCase().includes(query)) : rows;
        const start = Number.isInteger(cursor) && cursor >= 0 ? Math.min(cursor, filtered.length) : 0;
        const sessions = filtered.slice(start, start + limit);
        return reply(response, 200, { current: status(), sessions, total: filtered.length,
          nextCursor: start + limit < filtered.length ? start + limit : undefined });
      }
      if (route === "POST /open") {
        if (process.env.PIGO_ALLOW_RPC_SWITCH !== "1") return fail(409, "desktop_handoff_required");
        const input = await body(request);
        const rows = await catalog();
        if (runtime !== active || switching || dispatchTimer || !command || !active.ctx.isIdle() || active.ctx.hasPendingMessages()) {
          return fail(409, "not_ready_to_open");
        }
        const matches = rows.filter((row) => row.id === input.id);
        if (matches.length !== 1) return fail(404, "session_not_found");
        if (status()?.id === input.id) return reply(response, 200, { session: status() });
        switching = true;
        try {
          const result = await command.switchSession(matches[0].path, { withSession: (ctx) => { command = ctx; } });
          if (result.cancelled) return fail(409, "open_cancelled");
          if (status()?.id !== input.id) return fail(409, "runtime_not_rebound");
          return reply(response, 200, { session: status() });
        } finally { switching = false; }
      }
      if (route === "POST /model") {
        const input = await body(request);
        if (runtime !== active || switching || input.id !== status()?.id) return fail(409, "session_changed");
        const scoped = active.ctx.scopedModels;
        const allowed = new Map((scoped.length ? scoped.map((entry) => entry.model) : active.ctx.modelRegistry.getAvailable())
          .map((model) => [`${model.provider}/${model.id}`, model]));
        const target = typeof input.provider === "string" && typeof input.modelId === "string"
          ? allowed.get(`${input.provider}/${input.modelId}`) : undefined;
        if (!target) return fail(404, "model_not_found");
        if (input.thinkingLevel !== undefined &&
          !(thinkingLevels as readonly string[]).includes(input.thinkingLevel)) return fail(400, "invalid_thinking_level");
        if (dispatchTimer || !active.ctx.isIdle() || active.ctx.hasPendingMessages()) return fail(409, "session_busy");
        if (!(await active.pi.setModel(target)) || active.ctx.model !== target) return fail(409, "model_not_applied");
        if (input.thinkingLevel !== undefined) active.pi.setThinkingLevel(input.thinkingLevel);
        emit("session/changed", { session: status() });
        const current = active.ctx.model;
        return reply(response, 200, { session: status(),
          current: current && { ...modelRow(current), thinkingLevel: active.ctx.thinkingLevel, levels: levelsOf(current) } });
      }
      if ((privateSocket && route === "POST /fork") || route === "POST /regenerate") {
        const input = await body(request);
        const manager = active.ctx.sessionManager;
        if (runtime !== active || switching || input.id !== status()?.id) return fail(409, "session_changed");
        if (dispatchTimer || !active.ctx.isIdle() || active.ctx.hasPendingMessages()) return fail(409, "session_busy");
        const branch = manager.getBranch();
        const index = branch.findIndex((entry) => entry.id === input.messageId);
        const answer = branch[index];
        if (answer?.type !== "message" || answer.message.role !== "assistant" ||
            !hasReplyContent(answer.message.content)) {
          return fail(404, "message_not_found");
        }
        if (route === "POST /fork") {
          const source = manager.getSessionFile();
          if (!source) return fail(409, "session_not_persisted");
          // Operate on a separate manager so the original Pi runtime stays on its current session.
          const copy = SessionManager.open(source, manager.getSessionDir(), active.ctx.cwd);
          copy.createBranchedSession(answer.id);
          const name = status()?.name || "会话";
          copy.appendSessionInfo(`${name.slice(0, 190)}（分支）`);
          return reply(response, 200, { id: copy.getSessionId() });
        }
        const prompt = branch.slice(0, index).findLast((entry) => entry.type === "message" && entry.message.role === "user");
        if (prompt?.type !== "message" || prompt.message.role !== "user" ||
            branch.slice(index + 1).some((entry) => entry.type === "message" &&
              (entry.message.role === "user" || (entry.message.role === "assistant" &&
                hasReplyContent(entry.message.content))))) {
          return fail(409, "reply_not_latest");
        }
        if (!active.ctx.model) return fail(409, "model_not_found");
        if (Array.isArray(prompt.message.content) && prompt.message.content.some((part) => part.type === "image") &&
            !active.ctx.model.input.includes("image")) return fail(409, "image_not_supported");
        const content = prompt.message.content;
        const leaf = manager.getLeafId();
        const nonce = randomBytes(16).toString("hex");
        let restoreReply: (() => Promise<void>) | undefined;
        // Pi exposes tree navigation through its extension command context.
        active.pi.registerCommand(regenerateCommand, {
          description: "Pi Go bridge reply regeneration",
          handler: async (arg, ctx) => {
            const pending = regenerate;
            if (!pending || pending.nonce !== arg) return;
            regenerate = undefined;
            await pending.run(ctx);
          },
        });
        const outcome = new Promise<boolean>((resolve) => {
          const timeout = setTimeout(() => resolve(false), 3000).unref();
          regenerate = { nonce, run: async (ctx) => {
            clearTimeout(timeout);
            try {
              if (runtime !== active || manager.getLeafId() !== leaf ||
                  !ctx.isIdle() || ctx.hasPendingMessages()) return resolve(false);
              const result = await ctx.navigateTree(prompt.id);
              if (result.cancelled) return resolve(false);
              const rewoundLeaf = manager.getLeafId();
              restoreReply = async () => {
                if (runtime === active && leaf && ctx.isIdle() && !ctx.hasPendingMessages() &&
                    manager.getLeafId() === rewoundLeaf) await ctx.navigateTree(leaf);
              };
              if (dispatchTimer !== timer) {
                await restoreReply();
                return resolve(false);
              }
              active.pi.sendUserMessage(content, { expandPromptTemplates: false });
              resolve(true);
            } catch { resolve(false); }
          } };
        });
        const timer = trackDispatch(undefined, async () => { await restoreReply?.(); });
        active.pi.sendUserMessage(`/${regenerateCommand} ${nonce}`, { expandPromptTemplates: true });
        if (!(await outcome)) {
          if (dispatchTimer === timer) {
            regenerate = undefined;
            clearDispatch();
            registration.publish();
          }
          return fail(409, "regenerate_failed");
        }
        return reply(response, 202, { dispatched: true });
      }
      if (route === "POST /rename") {
        const input = await body(request);
        if (runtime !== active || switching || input.id !== status()?.id) return fail(409, "session_changed");
        if (typeof input.name !== "string" || !input.name.trim() || input.name.length > 200 ||
          input.name.trim() !== input.name || /[\r\n\0]/.test(input.name)) return fail(400, "invalid_name");
        active.pi.setSessionName(input.name);
        if (active.ctx.sessionManager.getSessionName() !== input.name) return fail(409, "rename_failed");
        titleRequest?.abort();
        emit("session/changed", { session: status() });
        return reply(response, 200, { session: status() });
      }
      if (route === "POST /upload") {
        if (request.headers["content-type"] !== "application/octet-stream") return fail(400, "invalid_content_type");
        const parameters = new URL(request.url ?? "/", "http://pi-go").searchParams;
        const kind = parameters.get("kind");
        const name = safeAttachmentName(parameters.get("name") ?? "");
        if ((kind !== "image" && kind !== "file") || !name) return fail(400, "invalid_attachment");
        const bytes = await rawBody(request, kind === "image" ? maxImageBytes : maxFileBytes);
        if (runtime !== active || switching) return fail(409, "session_changed");
        if (kind === "image" && !validPromptImageBuffer(bytes)) return fail(400, "invalid_image");
        try {
          const staged = stageAttachment(active.ctx.cwd, name, bytes);
          return reply(response, 200, { attachment: { token: staged.token, kind, name: staged.name, size: staged.size, path: staged.path } });
        } catch {
          return fail(400, "invalid_attachment");
        }
      }
      if (route === "POST /prompt" || route === "POST /abort" || route === "POST /receipt") {
        const input = await body(request, route === "POST /prompt" ? maxPromptBody : maxBody);
        if (runtime !== active || switching || input.id !== status()?.id) return fail(409, "session_changed");
        if (route === "POST /abort") {
          active.ctx.abort();
          return reply(response, 202, { dispatched: true });
        }
        if (typeof input.requestId !== "string" || !/^[\w-]{1,80}$/.test(input.requestId)) return fail(400, "invalid_request_id");
        if (route === "POST /receipt") {
          return reply(response, 200, { dispatched: requests.get(input.requestId) === input.id, requestId: input.requestId });
        }
        const mode = input.mode ?? "send";
        const hasImage = input.image !== undefined;
        const attachments = promptAttachments(input.attachments);
        if (attachments === undefined) return fail(400, "invalid_attachment");
        const imageCount = attachments.filter((item) => item.kind === "image").length + (hasImage ? 1 : 0);
        const fileCount = attachments.filter((item) => item.kind === "file").length;
        if (typeof input.text !== "string" || (!input.text.trim() && imageCount === 0 && fileCount === 0) ||
          Buffer.byteLength(input.text) > 12000 ||
          (mode !== "send" && mode !== "steer" && mode !== "followUp")) return fail(400, "invalid_prompt");
        const commandText = input.text.trimStart().startsWith("/") ? input.text.trimStart() : undefined;
        const commandName = commandText !== undefined ? (commandText.slice(1).split(/\s/, 1)[0] ?? "") : undefined;
        const command = commandName !== undefined && commandName !== "" && /^[\w:.-]{1,80}$/.test(commandName)
          ? active.pi.getCommands().find((row) => row.name === commandName && row.name !== regenerateCommand) : undefined;
        if (commandName !== undefined && commandName !== "" && !command) return fail(400, "unknown_command");
        if (command && (imageCount > 0 || fileCount > 0)) return fail(400, "command_attachments");
        if (commandName !== undefined && commandName === "") return fail(400, "invalid_prompt");
        if (hasImage && (typeof input.image !== "string" || !validPromptImage(input.image))) return fail(400, "invalid_image");
        if (imageCount > 0 && active.ctx.model?.input.includes("image") !== true) return fail(409, "image_not_supported");
        if (requests.has(input.requestId)) return fail(409, "duplicate_request");
        const idle = active.ctx.isIdle();
        // steer/followUp 允许在已有排队消息时继续追加（Pi 原生支持多条排队，逐轮送达）；
        // 只有 send（新开一轮）才要求队列清空且空闲。
        if (dispatchTimer || (mode === "send" && (active.ctx.hasPendingMessages() || !idle))) return fail(409, "session_busy");
        if (mode !== "send" && (idle || !runId || input.runId !== runId)) return fail(409, "session_not_streaming");
        if (requests.size >= 1024) return fail(429, "probe_request_limit");
        const deliverAs = mode === "send" ? undefined : mode;
        const stagedImages: { name: string; path: string }[] = [];
        const stagedFiles: { name: string; path: string }[] = [];
        for (const item of attachments) {
          const staged = stagedAttachment(active.ctx.cwd, item.token);
          if (!staged) return fail(409, "unknown_attachment");
          (item.kind === "image" ? stagedImages : stagedFiles).push({ name: staged.name, path: staged.path });
        }
        const imageData: Buffer[] = [];
        if (hasImage) imageData.push(Buffer.from(input.image, "base64"));
        for (const staged of stagedImages) {
          const bytes = readFileSync(staged.path);
          if (!validPromptImageBuffer(bytes)) return fail(400, "invalid_image");
          imageData.push(bytes);
        }
        let text = command !== undefined ? (commandText ?? input.text) : input.text;
        if (stagedFiles.length) {
          const lines = stagedFiles.map((file) => `- ${file.name}：${file.path}`);
          text = `${text}${sessionAttachmentMarker}${stagedFiles.length} 个文件：\n${lines.join("\n")}`;
        }
        const parts: PromptContentPart[] = [{ type: "text", text }];
        for (const bytes of imageData) parts.push({ type: "image", mimeType: "image/jpeg", data: bytes.toString("base64") });
        const content: string | PromptContentPart[] = parts.length > 1 ? parts : text;
        requests.set(input.requestId, input.id);
        if (command?.source === "extension") {
          // 扩展命令可能立即关闭 probe（如 /pi-go-stop）：先回包并等响应 flush，再派发，避免连接被一起销毁。
          let sent = false;
          const dispatch = () => {
            if (sent) return;
            sent = true;
            active.pi.sendUserMessage(text, { expandPromptTemplates: true, deliverAs });
          };
          response.once("finish", dispatch);
          setTimeout(dispatch, 250).unref();
          return reply(response, 202, { dispatched: true, requestId: input.requestId, handled: true });
        }
        active.pi.sendUserMessage(content, { expandPromptTemplates: command !== undefined, deliverAs });
        if (deliverAs) {
          // 排队状态即时广播（旧版手机端会忽略这个新帧类型）：先乐观上报 queued，
          // 再短暂延迟后用真实状态校准；权威状态仍由 /chat 轮询兜底。
          const liveRunId = status()?.runId ?? runId;
          emit("queue/status", { runId: liveRunId, queued: true });
          const binding = streamId;
          setTimeout(() => {
            const current = status();
            if (current && binding === streamId && liveRunId === runId) {
              emit("queue/status", { runId: current.runId, queued: current.queued });
            }
          }, 250).unref();
          return reply(response, 202, { dispatched: true, requestId: input.requestId });
        }
        trackDispatch(input.requestId);
        return reply(response, 202, { dispatched: true, requestId: input.requestId });
      }
      return fail(404, "not_found");
    } catch (cause) {
      if (!response.headersSent) {
        if (cause instanceof Error && cause.message === "oversized_body") {
          response.setHeader("Connection", "close");
          request.resume();
          return fail(413, "payload_too_large");
        }
        fail(400, "request_failed");
      }
      else response.destroy();
    }
  };
  const server = createServer(options, handle(false));
  const worker = createServer(options, handle(true));
  const registration = registerSocket(worker, () => ({ session: status(), historyDirectory }));
  let sharing: Promise<void> | undefined;
  server.maxConnections = 12;
  worker.maxConnections = 12;
  server.setTimeout(30_000, (socket) => socket.destroy());
  worker.setTimeout(6000, (socket) => socket.destroy());

  return {
    bind(pi: ExtensionAPI, ctx: ExtensionContext) {
      for (const stream of sequencedStreams) stream.destroy();
      titleRequest?.abort();
      runtime = { pi, ctx };
      const firstUser = ctx.sessionManager.getEntries().find((entry) => entry.type === "message" && entry.message.role === "user");
      firstUserSeen = firstUser !== undefined;
      titlePreview = firstUser?.type === "message" && firstUser.message.role === "user"
        ? sessionTitlePreview(firstUser.message.content) : undefined;
      try {
        historyDirectory = realpathSync(ctx.sessionManager.getSessionDir());
      } catch { historyDirectory = undefined; }
      streamId = randomBytes(16).toString("hex");
      syncSeq = 0;
      baseline = undefined;
      lastStopReason = undefined;
      baselineLeaf = null;
      runId = ctx.isIdle() ? undefined : randomBytes(16).toString("hex");
      liveText = "";
      liveSeq = 0;
      liveThinking = "";
      liveThinkSeq = 0;
      toolLog.clear();
      activePrompt = undefined;
      promptError = undefined;
      emit("session/changed", { session: status() });
    },
    unbind() {
      clearDispatch();
      regenerate = undefined;
      titleRequest?.abort();
      runtime = undefined;
      runId = undefined;
      command = undefined;
      registration.withdraw();
      worker.close();
      worker.closeAllConnections();
    },
    agentStarted() {
      clearDispatch();
      runId = randomBytes(16).toString("hex");
      baseline = undefined;
      lastStopReason = undefined;
      baselineLeaf = historyLeaf();
      if ((worker.listening || scheduled) && runtime) {
        try { baseline = captureWorkspace(runtime.ctx.cwd); } catch { /* The run can continue without a diff. */ }
      }
      liveText = "";
      liveSeq = 0;
      liveThinking = "";
      liveThinkSeq = 0;
      toolLog.clear();
      // 运行一开始就把 runId/queued 推给手机，引导按钮无需等 /chat 轮询。
      emit("session/status", { idle: false, runId, queued: status()?.queued ?? false });
    },
    delta(text: string) {
      liveText = (liveText + text).slice(-16000);
      liveSeq += 1;
      emit("message/delta", { text, seq: liveSeq });
    },
    thinking(text: string) {
      liveThinking = (liveThinking + text).slice(-16000);
      liveThinkSeq += 1;
      emit("message/thinking", { text, seq: liveThinkSeq });
    },
    toolStart(id: string, name: string, args: unknown) {
      const entry: LiveToolStatus = { id, name, detail: toolDetail(args), state: "run" };
      toolLog.set(id, { summary: entry, args });
      emit("tool/start", { tool: entry });
    },
    toolEnd(id: string, failed: boolean, ms: number | undefined, result: unknown) {
      const activity = toolLog.get(id);
      if (!activity) return;
      activity.summary = { ...activity.summary, state: failed ? "fail" : "ok", ms };
      activity.result = result;
      emit("tool/end", { tool: activity.summary });
    },
    settled(aborted: boolean) {
      const settledRunId = runId;
      const current = status();
      if (settledRunId && (worker.listening || scheduled) && runtime && current) {
        try {
          const manager = runtime.ctx.sessionManager;
          const recent = historyPage(manager, toolLog, null, 60);
          const messages = [];
          const rows = new Map(recent?.messages.map((row) => [row.id, row]));
          let remaining = 500;
          for (let entry = manager.getLeafEntry(); entry && entry.id !== baselineLeaf && remaining-- > 0;
            entry = entry.parentId ? manager.getEntry(entry.parentId) : undefined) {
            const message = rows.get(entry.id);
            if (message) messages.push(message);
          }
          messages.reverse();
          const anchor = [...messages].reverse().find((message) =>
            message.role === "assistant" && (message.text || message.imageCount)) ?? messages.at(-1);
          const screenshots = Array.from(toolLog.values()).flatMap(({ summary, result }) => {
            if (!imageParts((result as { content?: unknown })?.content).length) return [];
            const message = messages.find((item) => item.tools?.some(({ id }) => id === summary.id));
            return message ? [{ toolId: summary.id, messageId: message.id }] : [];
          }).slice(0, 6);
          const checks = Array.from(toolLog.values()).flatMap(({ summary, args }) => {
            const command = (args as { command?: unknown })?.command;
            if (summary.name !== "bash" || typeof command !== "string" ||
              !/(^|[\s/])(tests?|pytest|vitest|jest|ctest|mocha|xctest|xcodebuild|check|lint|typecheck|build)([\s:;]|$)/i.test(command)) return [];
            return [{ id: summary.id, command: command.slice(0, 240), state: summary.state, ms: summary.ms }];
          }).slice(0, 8);
          const finishedAt = Date.now();
          let changes: ReturnType<typeof describeChanges>;
          try { changes = describeChanges(current.cwd, baseline); }
          catch { changes = { files: [], patches: {}, partial: true }; }
          const { files, patches, partial } = changes;
          const resultText: string = anchor?.role === "assistant" ? anchor.text : "";
          const references = [...resultText.matchAll(/`([^`\r\n]{1,1024})`|\]\(([^)\r\n]{1,1024})\)/g)]
            .map((match) => match[1] ?? match[2]);
          for (const { summary, args } of toolLog.values()) {
            const path = (args as { path?: unknown })?.path;
            if (summary.state === "ok" && (summary.name === "write" || summary.name === "edit") && typeof path === "string") {
              references.push(path);
            }
          }
          for (const path of referencedArtifacts(current.cwd, references)) {
            if (!files.some((file: { path: string }) => file.path === path)) {
              files.push({ path, change: "artifact", diff: false, artifact: true });
            }
          }
          saveRunResult(profile, { id: settledRunId, sessionId: current.id, cwd: current.cwd,
            title: current.name, messageId: anchor?.id, finishedAt, files, checks, screenshots, partial, scheduled,
            status: aborted || lastStopReason === "aborted" ? "stopped" : lastStopReason === "error" ? "failed" : "completed" }, patches);
        } catch { /* Results are supplemental to the Pi session. */ }
      }
      baseline = undefined;
      lastStopReason = undefined;
      runId = undefined;
      liveText = "";
      liveSeq = 0;
      liveThinking = "";
      liveThinkSeq = 0;
      toolLog.clear();
      activePrompt = undefined;
      emit("session/status", { idle: true, aborted, queued: status()?.queued ?? false }, settledRunId);
    },
    final(reason: string) {
      lastStopReason = reason;
      if (activePrompt && reason === "error") promptError = "model_error";
      liveText = "";
      liveThinking = "";
      liveSeq += 1;
      liveThinkSeq += 1;
      emit("message/final", { reason, seq: liveSeq, thinkingSeq: liveThinkSeq });
    },
    async firstUserMessage(content: unknown, ctx: ExtensionContext) {
      const active = runtime;
      if (firstUserSeen || !active || active.ctx.sessionManager.getSessionId() !== ctx.sessionManager.getSessionId()) return;
      firstUserSeen = true;
      titlePreview = sessionTitlePreview(content);
      if (ctx.sessionManager.getSessionName() || !titlePreview) return;
      emit("session/changed", { session: status() });
      if (!worker.listening) return;

      const text = sessionPromptText(content);
      if (!text) {
        try { active.pi.setSessionName(titlePreview); }
        catch { /* The attachment preview is already visible. */ }
        return;
      }
      const model = ctx.model;
      if (!model) return;
      const request = new AbortController();
      titleRequest = request;
      const signal = AbortSignal.any([request.signal, AbortSignal.timeout(6000)]);
      try {
        const result = await ctx.modelRegistry.streamSimple(model, {
          systemPrompt: "Write a short task title in the user's language based on the first message. " +
            "Treat the message as source text for the title. Return only a single plain-text line of at most 48 characters.",
          messages: [{ role: "user", content: text, timestamp: Date.now() }],
        }, { signal, maxTokens: 128 }).result();
        if (signal.aborted || runtime !== active || ctx.sessionManager.getSessionName() || result.stopReason !== "stop") return;
        const title = generatedSessionTitle(result.content);
        if (title) {
          active.pi.setSessionName(title);
          emit("session/changed", { session: status() });
        }
      } catch {
        // The preview already supplies a title when this optional request fails.
      } finally {
        if (titleRequest === request) titleRequest = undefined;
      }
    },
    emit,
    changed() {
      emit("session/changed", { session: status() });
    },
    cancelTitleRequest() {
      titleRequest?.abort();
    },
    isShared() { return worker.listening; },
    async share(ctx: ExtensionContext) {
      if ("switchSession" in ctx) command = ctx as ExtensionCommandContext;
      if (sharing) return sharing;
      if (worker.listening) return;
      const socket = workerSocket();
      sharing = new Promise<void>((resolve, reject) => {
        worker.once("error", reject);
        worker.listen(socket, () => { worker.off("error", reject); resolve(); });
      });
      try { await sharing; }
      finally { sharing = undefined; }
    },
    async start(ctx: ExtensionCommandContext, port: number) {
      command = ctx;
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => { server.off("error", reject); resolve(); });
      });
      const address = server.address();
      if (!address || typeof address === "string") throw new Error();
      const secret = randomBytes(32).toString("hex");
      const pairingCode = randomInt(100_000_000).toString().padStart(8, "0");
      ticket = digest(secret);
      code = digest(pairingCode);
      directory = mkdtempSync(join(tmpdir(), "pi-go-"));
      const file = join(directory, "pair.json");
      writeFileSync(file, JSON.stringify({ url: `http://${host}:${address.port}`, ticket: secret, code: pairingCode }), { mode: 0o600, flag: "wx" });
      expiry = setTimeout(removeTicket, 120_000).unref();
      return file;
    },
    stop() {
      token = undefined;
      titleRequest?.abort();
      clearDispatch();
      stopPing();
      removeTicket();
      server.close();
      server.closeAllConnections();
      registration.withdraw();
      worker.close();
      worker.closeAllConnections();
    },
  };
}

const key = Symbol.for("pi-go.phase0.probe");
const processState = globalThis as typeof globalThis & Record<symbol, ReturnType<typeof createProbe> | undefined>;

export default function (pi: ExtensionAPI) {
  const stop = () => {
    processState[key]?.stop();
    delete processState[key];
  };
  const share = async (ctx: ExtensionContext) => {
    const probe = processState[key] ?? createProbe();
    processState[key] = probe;
    probe.bind(pi, ctx);
    await probe.share(ctx);
  };
  // Installed daemons still use this exact RPC message to attach their new sessions.
  // Handle it without adding a slash command to Pi's menus.
  pi.on("input", async (event, ctx) => {
    if (event.source !== "rpc" || event.text !== "/pi-go-share desktop-host" || event.images?.length) return;
    try { await share(ctx); }
    catch { ctx.ui.notify("Pi Go could not share this session", "error"); }
    return { action: "handled" };
  });
  let closePairingUI: (() => void) | undefined;
  pi.on("session_start", (_event, ctx) => {
    processState[key]?.bind(pi, ctx);
    closePairingUI?.();
    closePairingUI = pairingRuntime(() => ({ id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd,
      name: ctx.sessionManager.getSessionName(), model: ctx.model && modelRow(ctx.model),
      shared: processState[key]?.isShared() === true }), () => share(ctx), stop);
  });
  pi.on("session_shutdown", (event) => {
    closePairingUI?.();
    closePairingUI = undefined;
    if (event.reason === "quit" || event.reason === "reload" || !event.reason) stop();
    else processState[key]?.unbind();
  });
  pi.on("agent_start", () => processState[key]?.agentStarted());
  pi.on("agent_settled", (event) => processState[key]?.settled(event.aborted));
  pi.on("message_update", (event) => {
    const update = event.assistantMessageEvent;
    if (update.type === "text_delta") processState[key]?.delta(update.delta);
    else if (update.type === "thinking_delta") processState[key]?.thinking(update.delta);
  });
  pi.on("tool_execution_start", (event) => {
    if (!event.parentToolCallId) processState[key]?.toolStart(event.toolCallId, event.toolName, event.args);
  });
  pi.on("tool_execution_end", (event) => {
    if (!event.parentToolCallId) processState[key]?.toolEnd(event.toolCallId, event.isError, event.durationMs, event.result);
  });
  pi.on("message_end", (event, ctx) => {
    if (event.message.role === "user") void processState[key]?.firstUserMessage(event.message.content, ctx);
    if (event.message.role === "assistant") processState[key]?.final(event.message.stopReason);
  });
  pi.on("session_info_changed", () => processState[key]?.cancelTitleRequest());
  pi.on("model_select", () => processState[key]?.changed());
  pi.on("thinking_level_select", () => processState[key]?.changed());
  if (process.env.PIGO_TEST_COMMANDS !== "1") return;

  pi.registerCommand("pi-go", {
    description: "Enable the local Pi Go phase-0 probe (disposable sessions only)",
    handler: async (args, ctx) => {
      const value = args.trim();
      const port = value ? Number(value) : 0;
      if (!Number.isInteger(port) || port < 0 || port > 65535 || (port !== 0 && port < 1024)) {
        return ctx.ui.notify("Pi Go port must be 1024–65535", "warning");
      }
      stop();
      const probe = createProbe();
      processState[key] = probe;
      probe.bind(pi, ctx);
      try { ctx.ui.notify(`Pi Go ticket file: ${await probe.start(ctx, port)}`, "info"); }
      catch { stop(); ctx.ui.notify("Pi Go probe could not start", "error"); }
    },
  });
  pi.registerCommand("pi-go-stop", {
    description: "Close the local probe and revoke its credential",
    handler: async (_args, ctx) => { stop(); ctx.ui.notify("Pi Go probe stopped", "info"); },
  });
  pi.registerCommand("pi-go-share", {
    description: "Share this native session with the local Pi Go bridge",
    handler: async (_args, ctx) => {
      try { await share(ctx); ctx.ui.notify("Pi Go session shared", "info"); }
      catch { ctx.ui.notify("Pi Go could not share this session", "error"); }
    },
  });
  pi.registerCommand("pi-go-project", {
    description: "Allow Pi Go to reopen this project without a shared session",
    handler: async (args, ctx) => {
      const port = args.trim() ? Number(args.trim()) : 18977;
      if (!Number.isInteger(port) || port < 1024 || port > 65535) return ctx.ui.notify("Pi Go port must be 1024–65535", "warning");
      try {
        const result = await localRequest(join(ipcDirectory(), `bridge-${port}.sock`), "POST", "/grant", { cwd: ctx.cwd });
        if (result.status !== 200) throw new Error(result.data.error);
        ctx.ui.notify("Pi Go project reopening enabled", "info");
      } catch {
        ctx.ui.notify("Pi Go project authorization failed; check that the bridge and Pi Go daemon are running", "error");
      }
    },
  });
  pi.registerCommand("pi-go-bridge", {
    description: "Share this session and start or pair the shared Pi Go bridge",
    handler: async (args, ctx) => {
      const port = args.trim() ? Number(args.trim()) : 18977;
      if (!Number.isInteger(port) || port < 1024 || port > 65535) return ctx.ui.notify("Pi Go port must be 1024–65535", "warning");
      try {
        await share(ctx);
        const admin = join(ipcDirectory(), `bridge-${port}.sock`);
        let result;
        try { result = await localRequest(admin, "POST", "/ticket"); }
        catch (error) {
          if (!["ENOENT", "ECONNREFUSED"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
          const file = fileURLToPath(new URL("./broker.mjs", import.meta.url));
          const child = spawn(process.execPath, [file, String(port)], { detached: true, stdio: "ignore" });
          child.on("error", () => {});
          child.unref();
          for (let attempt = 0; attempt < 30 && !result; attempt += 1) {
            await new Promise((resolve) => setTimeout(resolve, 100));
            try { result = await localRequest(admin, "POST", "/ticket"); }
            catch (error) { if (!["ENOENT", "ECONNREFUSED"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error; }
          }
        }
        if (result?.status !== 200 || typeof result.data.file !== "string") throw new Error("bridge_unavailable");
        ctx.ui.notify(`Pi Go ticket file: ${result.data.file}`, "info");
      } catch { ctx.ui.notify("Pi Go could not start or pair the shared bridge", "error"); }
    },
  });
  pi.registerCommand("pi-go-check-ui", {
    description: "Check whether the host can display an extension confirmation",
    handler: async (_args, ctx) => {
      const accepted = await ctx.ui.confirm("Pi Go UI check", "Can you see this confirmation?", { timeout: 15_000 });
      ctx.ui.notify(accepted ? "Pi Go UI confirmed" : "Pi Go UI declined or timed out", "info");
    },
  });
}
