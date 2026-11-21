import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager, type ExtensionAPI, type ExtensionCommandContext, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ipcDirectory, localRequest, workerSocket } from "./local-ipc.mjs";
import { pairingRuntime } from "./pairing-runtime.mjs";
import { localLanAddress } from "./lan-tls.mjs";
import { maxPromptBody, validPromptImage, validPromptImageBuffer, stageAttachment, stagedAttachment, safeAttachmentName,
  maxImageBytes, maxFileBytes, maxImagesPerPrompt, maxFilesPerPrompt } from "./attachments.mjs";

const host = "127.0.0.1";
const maxBody = 16 * 1024;
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

function toolResultText(result: unknown): string {
  const content = (result as { content?: unknown })?.content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => {
    if (part?.type === "text" && typeof part.text === "string") return part.text;
    if (part?.type === "image") return "［图片输出］";
    return "";
  }).join("\n");
}

function toolDetails(activity: ToolActivity) {
  const args = activity.args as { command?: unknown; path?: unknown } | undefined;
  const command = activity.summary.name === "bash" && typeof args?.command === "string" ? args.command : undefined;
  const input = command ?? (args === undefined ? "" : JSON.stringify(args, null, 2) ?? "");
  const output = toolResultText(activity.result);
  const limit = 64 * 1024;
  return {
    input: input.slice(0, limit), output: output.slice(0, limit),
    command: command !== undefined, truncated: input.length > limit || output.length > limit,
    state: activity.summary.state,
    path: typeof args?.path === "string" && args.path.length <= 2048 ? args.path : undefined,
  };
}

const toolDetail = (args: unknown): string => {
  if (!args || typeof args !== "object") return "";
  const record = args as Record<string, unknown>;
  for (const key of ["command", "path", "file", "pattern", "query", "url", "prompt", "description", "name"]) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) return value.replace(/\s+/g, " ").trim().slice(0, 120);
  }
  try { return JSON.stringify(record).slice(0, 120); } catch { return ""; }
};

function reply(response: ServerResponse, status: number, value: object) {
  response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  response.end(JSON.stringify(value));
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
type PromptAttachment = { token: string; kind: "image" | "file" };

function promptAttachments(value: unknown): PromptAttachment[] | undefined {
  if (value === undefined) return [];
  if (!Array.isArray(value)) return undefined;
  const items: PromptAttachment[] = [];
  for (const entry of value) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry) || typeof entry.token !== "string" ||
      !/^[a-f0-9]{16}$/.test(entry.token) || (entry.kind !== "image" && entry.kind !== "file")) return undefined;
    if (!items.some((item) => item.kind === entry.kind && item.token === entry.token))
      items.push({ token: entry.token, kind: entry.kind });
  }
  if (items.filter((item) => item.kind === "image").length > maxImagesPerPrompt) return undefined;
  if (items.filter((item) => item.kind === "file").length > maxFilesPerPrompt) return undefined;
  return items;
}

function createProbe() {
  let runtime: { pi: ExtensionAPI; ctx: ExtensionContext } | undefined;
  let command: ExtensionCommandContext | undefined;
  let directory: string | undefined;
  let ticket: Buffer | undefined;
  let code: Buffer | undefined;
  let attempts = 0;
  let token: Buffer | undefined;
  let expiry: NodeJS.Timeout | undefined;
  let dispatchTimer: NodeJS.Timeout | undefined;
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
  const requests = new Map<string, string>();
  const streams = new Set<ServerResponse>();
  const streamTargets = new Map<ServerResponse, { id: string; cwd: string }>();
  const status = () => {
    const ctx = runtime?.ctx;
    return ctx && { id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd, name: ctx.sessionManager.getSessionName(),
      idle: ctx.isIdle() && !dispatchTimer, runId: ctx.isIdle() ? undefined : runId, queued: ctx.hasPendingMessages(),
      acceptsImage: ctx.model?.input.includes("image") === true,
      model: ctx.model && modelRow(ctx.model), thinkingLevel: ctx.thinkingLevel };
  };
  const emit = (type: string, data: object) => {
    const current = status();
    const frame = `data: ${JSON.stringify({ type, sessionId: current?.id, ...data })}\n\n`;
    for (const stream of streams) {
      const target = streamTargets.get(stream);
      if ((target && (current?.id !== target.id || current.cwd !== target.cwd)) || !stream.write(frame)) stream.destroy();
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
      if (privateSocket && !["GET /session", "GET /chat", "GET /history", "GET /tool-detail", "GET /sessions", "GET /models", "GET /commands", "GET /events", "POST /prompt", "POST /upload", "POST /abort", "POST /receipt", "POST /model", "POST /rename"].includes(route)) {
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
        if (streams.size >= 4) return fail(429, "too_many_streams");
        request.socket.setTimeout(0);
        response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", "Connection": "keep-alive" });
        response.write(`data: ${JSON.stringify({ type: "ready", session: status() })}\n\n`);
        streams.add(response);
        if (target) streamTargets.set(response, target);
        startPing();
        response.on("close", () => {
          streams.delete(response);
          streamTargets.delete(response);
          if (!streams.size) stopPing();
        });
        return;
      }
      if (!runtime || switching) return fail(409, "session_unavailable");
      if (route === "GET /session") return reply(response, 200, { session: status() });
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
        const commands = active.pi.getCommands().map((command) => ({
          name: command.name,
          description: typeof command.description === "string" ? command.description.slice(0, 300) : undefined,
          source: command.source,
          invoke: `/${command.name}`,
        }));
        return reply(response, 200, { session: status(), commands });
      }
      if (route === "GET /chat" || route === "GET /history" || route === "GET /tool-detail") {
        const parameters = new URL(request.url ?? "/", "http://pi-go").searchParams;
        if (route !== "GET /chat" && parameters.get("id") !== status()?.id) return fail(409, "session_changed");
        const branch = active.ctx.sessionManager.getBranch();
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
        if (route === "GET /tool-detail") {
          const id = parameters.get("tool") ?? "";
          const messageId = parameters.get("message");
          const saved = messageId ? toolsByMessage.get(messageId)?.find(({ summary }) => summary.id === id) : latestById.get(id);
          const live = !messageId || (saved && latestById.get(id) === saved) ? toolLog.get(id) : undefined;
          const activity = saved?.result !== undefined ? saved : live ?? saved;
          if (!activity) return fail(404, "tool_not_found");
          return reply(response, 200, { toolDetail: toolDetails(activity) });
        }
        const messages = branch.flatMap((entry) => {
          if (entry.type !== "message") return [];
          const { role, content } = entry.message;
          if (role !== "user" && role !== "assistant") return [];
          const parts = Array.isArray(content) ? content : [];
          const text = typeof content === "string" ? content : parts.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n");
          const thinking = role === "assistant" ? parts.flatMap((part) => part.type === "thinking" && typeof part.thinking === "string" ? [part.thinking] : []).join("\n") : "";
          const durationMs = role === "assistant" ? (entry.message as { durationMs?: number }).durationMs : undefined;
          const imageCount = parts.filter((part) => part.type === "image").length;
          const tools = toolsByMessage.get(entry.id)?.map((activity) => {
            const { summary } = activity;
            const live = latestById.get(summary.id) === activity ? toolLog.get(summary.id)?.summary : undefined;
            return summary.state === "unknown" && live ? live : summary;
          });
          return text || imageCount || thinking || tools?.length ? [{ id: entry.id, role, text: text.slice(0, 8000), imageCount, tools,
            thinking: thinking ? thinking.slice(0, 16000) : undefined,
            thinkingMs: thinking ? durationMs : undefined }] : [];
        });
        const before = parameters.get("before");
        const end = before ? messages.findIndex((message) => message.id === before) : messages.length;
        if (end < 0) return fail(409, "history_changed");
        const limit = route === "GET /history" ? Math.min(60, Math.max(1, Math.floor(Number(parameters.get("limit")) || 60))) : 60;
        const start = Math.max(0, end - limit);
        return reply(response, 200, { session: status(), messages: messages.slice(start, end),
          historyCursor: start > 0 ? messages[start].id : undefined, liveText, liveSeq, liveThinking, liveThinkSeq,
          tools: Array.from(toolLog.values(), ({ summary }) => summary), promptError });
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
        const rows = (await catalog()).slice(0, 250).map(({ id, name, firstMessage, modified, messageCount, cwd }) =>
          ({ id, name: name || firstMessage?.slice(0, 100), modified, messageCount, cwd }));
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
      if (route === "POST /rename") {
        const input = await body(request);
        if (runtime !== active || switching || input.id !== status()?.id) return fail(409, "session_changed");
        if (typeof input.name !== "string" || !input.name.trim() || input.name.length > 200 ||
          input.name.trim() !== input.name || /[\r\n\0]/.test(input.name)) return fail(400, "invalid_name");
        active.pi.setSessionName(input.name);
        if (status()?.name !== input.name) return fail(409, "rename_failed");
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
          ? active.pi.getCommands().find((row) => row.name === commandName) : undefined;
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
          text = `${text}\n\n[Pi Go 附件] 手机上传了 ${stagedFiles.length} 个文件：\n${lines.join("\n")}`;
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
          setTimeout(() => {
            const current = status();
            if (current) emit("queue/status", { runId: current.runId, queued: current.queued });
          }, 250).unref();
          return reply(response, 202, { dispatched: true, requestId: input.requestId });
        }
        activePrompt = input.requestId;
        promptError = undefined;
        dispatchTimer = setTimeout(() => {
          clearDispatch();
          promptError = "unconfirmed";
          activePrompt = undefined;
          emit("prompt/unconfirmed", { requestId: input.requestId });
        }, 5000).unref();
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
  server.maxConnections = 12;
  worker.maxConnections = 12;
  server.setTimeout(30_000, (socket) => socket.destroy());
  worker.setTimeout(6000, (socket) => socket.destroy());

  return {
    bind(pi: ExtensionAPI, ctx: ExtensionContext) {
      runtime = { pi, ctx };
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
      runtime = undefined;
      runId = undefined;
      command = undefined;
      worker.close();
      worker.closeAllConnections();
    },
    agentStarted() {
      clearDispatch();
      runId = randomBytes(16).toString("hex");
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
      runId = undefined;
      liveText = "";
      liveSeq = 0;
      liveThinking = "";
      liveThinkSeq = 0;
      toolLog.clear();
      activePrompt = undefined;
      emit("session/status", { idle: true, aborted, queued: status()?.queued ?? false });
    },
    final(reason: string) {
      if (activePrompt && reason === "error") promptError = "model_error";
      liveText = "";
      liveThinking = "";
      liveSeq += 1;
      liveThinkSeq += 1;
      emit("message/final", { reason, seq: liveSeq, thinkingSeq: liveThinkSeq });
    },
    emit,
    changed() {
      emit("session/changed", { session: status() });
    },
    isShared() { return worker.listening; },
    async share(ctx: ExtensionContext) {
      if ("switchSession" in ctx) command = ctx as ExtensionCommandContext;
      if (worker.listening) return;
      const socket = workerSocket();
      await new Promise<void>((resolve, reject) => {
        worker.once("error", reject);
        worker.listen(socket, () => { worker.off("error", reject); resolve(); });
      });
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
      clearDispatch();
      stopPing();
      removeTicket();
      server.close();
      server.closeAllConnections();
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
  let closePairingUI: (() => void) | undefined;
  pi.on("session_start", (_event, ctx) => {
    processState[key]?.bind(pi, ctx);
    closePairingUI?.();
    closePairingUI = pairingRuntime(() => ({ id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd,
      name: ctx.sessionManager.getSessionName(), model: ctx.model && modelRow(ctx.model),
      shared: processState[key]?.isShared() === true }), async () => {
      const probe = processState[key] ?? createProbe();
      processState[key] = probe;
      probe.bind(pi, ctx);
      await probe.share(ctx);
    }, stop);
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
  pi.on("message_end", (event) => {
    if (event.message.role === "assistant") processState[key]?.final(event.message.stopReason);
  });
  pi.on("model_select", () => processState[key]?.changed());
  pi.on("thinking_level_select", () => processState[key]?.changed());
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
  const share = async (ctx: ExtensionCommandContext) => {
    const probe = processState[key] ?? createProbe();
    processState[key] = probe;
    probe.bind(pi, ctx);
    await probe.share(ctx);
  };
  pi.registerCommand("pi-go-share", {
    description: "Share this native session with the local Pi Go bridge",
    handler: async (_args, ctx) => {
      try { await share(ctx); ctx.ui.notify("Pi Go session shared", "info"); }
      catch { ctx.ui.notify("Pi Go could not share this session", "error"); }
    },
  });
  for (const action of ["grant", "revoke-project"] as const) {
    pi.registerCommand(action === "grant" ? "pi-go-project" : "pi-go-project-stop", {
      description: action === "grant" ? "Allow Pi Go to reopen this project even with no shared tabs" : "Remove Pi Go access to this project when no tabs are shared",
      handler: async (args, ctx) => {
        const port = args.trim() ? Number(args.trim()) : 18977;
        if (!Number.isInteger(port) || port < 1024 || port > 65535) return ctx.ui.notify("Pi Go port must be 1024–65535", "warning");
        try {
          const result = await localRequest(join(ipcDirectory(), `bridge-${port}.sock`), "POST", `/${action}`, { cwd: ctx.cwd });
          if (result.status !== 200) throw new Error(result.data.error);
          ctx.ui.notify(action === "grant" ? "Pi Go project reopening enabled" : "Pi Go project reopening revoked", "info");
        } catch {
          ctx.ui.notify("Pi Go project authorization failed; check the bridge and Desktop workspace trust", "error");
        }
      },
    });
  }
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
  pi.registerCommand("pi-go-lan", {
    description: "Share this session through HTTPS on an explicit private LAN address",
    handler: async (args, ctx) => {
      const [host, value = "18981", ...extra] = args.trim().split(/\s+/);
      const port = Number(value);
      if (extra.length || !localLanAddress(host) || !Number.isInteger(port) || port < 1024 || port > 65535) {
        return ctx.ui.notify("Usage: /pi-go-lan <this Mac's private IPv4> [port]", "warning");
      }
      try {
        await share(ctx);
        const admin = join(ipcDirectory(), `bridge-${port}.sock`);
        const requestTicket = () => localRequest(admin, "POST", "/ticket-lan", { host });
        let result;
        try { result = await requestTicket(); }
        catch (error) {
          if (!["ENOENT", "ECONNREFUSED"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
          const file = fileURLToPath(new URL("./broker.mjs", import.meta.url));
          const child = spawn(process.execPath, [file, String(port), host], { detached: true, stdio: "ignore" });
          child.on("error", () => {});
          child.unref();
          for (let attempt = 0; attempt < 40 && !result; attempt += 1) {
            await new Promise((resolve) => setTimeout(resolve, 100));
            try { result = await requestTicket(); }
            catch (cause) { if (!["ENOENT", "ECONNREFUSED"].includes((cause as NodeJS.ErrnoException).code ?? "")) throw cause; }
          }
        }
        if (result?.status !== 200 || typeof result.data.file !== "string") throw new Error("bridge_unavailable");
        ctx.ui.notify(`Pi Go ticket file: ${result.data.file}`, "info");
      } catch { ctx.ui.notify("Pi Go could not start or pair the HTTPS LAN bridge", "error"); }
    },
  });
  pi.registerCommand("pi-go-revoke-device", {
    description: "Revoke the paired device and any unused pairing ticket without stopping the bridge",
    handler: async (args, ctx) => {
      const port = args.trim() ? Number(args.trim()) : 18977;
      if (!Number.isInteger(port) || port < 1024 || port > 65535) return;
      try {
        const result = await localRequest(join(ipcDirectory(), `bridge-${port}.sock`), "POST", "/revoke-device");
        if (result.status !== 200) throw new Error("revoke_failed");
        ctx.ui.notify("Pi Go device revoked", "info");
      } catch { ctx.ui.notify("Pi Go bridge is not running", "warning"); }
    },
  });
  pi.registerCommand("pi-go-bridge-stop", {
    description: "Stop the shared bridge and keep the paired device for restart",
    handler: async (args, ctx) => {
      const port = args.trim() ? Number(args.trim()) : 18977;
      if (!Number.isInteger(port) || port < 1024 || port > 65535) return;
      try {
        const result = await localRequest(join(ipcDirectory(), `bridge-${port}.sock`), "POST", "/stop");
        if (result.status === 200) ctx.ui.notify("Pi Go shared bridge stopped", "info");
      } catch { ctx.ui.notify("Pi Go shared bridge is not running", "warning"); }
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
