import { randomBytes } from "node:crypto";
import { EventEmitter } from "node:events";
import { realpathSync } from "node:fs";
import { dirname } from "node:path";
import { SessionManager, type ExtensionAPI, type ExtensionCommandContext, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { createWorkerServer } from "../worker-core.mjs";
import { generatedSessionTitle, imageParts, messageText,
  sessionPromptText, sessionTitlePreview, toolDetail } from "../../bridge/message-view.mjs";

const thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
type ModelLike = { provider: string; id: string; name: string; input?: string[]; reasoning: boolean; thinkingLevelMap?: Record<string, string | null> };
const levelsOf = (model: ModelLike | undefined) =>
  !model?.reasoning ? ["off"] : thinkingLevels.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
export const modelRow = (model: ModelLike) =>
  ({ provider: model.provider, id: model.id, name: model.name || model.id, levels: levelsOf(model), reasoning: model.reasoning === true, image: model.input?.includes("image") === true });

type ToolActivity = {
  summary: { id: string; name: string; detail: string; state: "unknown" | "ok" | "fail" };
  args: unknown;
  result?: unknown;
};
type Runtime = { pi: ExtensionAPI; ctx: ExtensionContext };
type PromptContentPart = { type: "text"; text: string } | { type: "image"; mimeType: string; data: string };
const regenerateCommand = "pi-go-regenerate";
const hasReplyContent = (content: readonly { type: string; text?: string }[]) =>
  content.some((part) => part.type === "image" || (part.type === "text" && !!part.text));
const fail = (status: number, error: string) => ({ status, error });

async function catalog(active: Runtime) {
  let folder: string;
  try { folder = realpathSync(active.ctx.sessionManager.getSessionDir()); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return []; throw error; }
  const cwd = realpathSync(active.ctx.cwd);
  const rows = await SessionManager.list(cwd, folder);
  return rows.filter((row) => {
    try { return realpathSync(row.cwd) === cwd && dirname(realpathSync(row.path)) === folder; }
    catch { return false; }
  });
}

// Walk the active branch from its leaf so a recent page does not normalize older turns.
function* historyEntries(manager: ExtensionContext["sessionManager"]) {
  const results = new Map<string, { content: unknown; isError: boolean }>();
  for (let entry = manager.getLeafEntry(); entry; entry = entry.parentId ? manager.getEntry(entry.parentId) : undefined) {
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (message.role === "toolResult") {
      if (!results.has(message.toolCallId)) results.set(message.toolCallId, message);
      continue;
    }
    if (message.role !== "user" && message.role !== "assistant") continue;
    const tools: ToolActivity[] = [];
    if (message.role === "assistant") {
      for (let index = message.content.length - 1; index >= 0; index -= 1) {
        const part = message.content[index];
        if (part.type !== "toolCall") continue;
        const result = results.get(part.id);
        results.delete(part.id);
        tools.push({
          summary: { id: part.id, name: part.name, detail: toolDetail(part.arguments),
            state: result ? (result.isError ? "fail" : "ok") : "unknown" },
          args: part.arguments,
          result,
        });
      }
      tools.reverse();
    }
    const thinking = message.role === "assistant" ? message.content.flatMap((part) =>
      part.type === "thinking" && typeof part.thinking === "string" ? [part.thinking] : []).join("\n") : "";
    yield {
      id: entry.id, role: message.role, text: messageText(message.content), images: imageParts(message.content),
      tools, thinking, thinkingMs: (message as { durationMs?: number }).durationMs,
    };
  }
}

export function createPiWorker() {
  let runtime: Runtime | undefined;
  let firstUserSeen = false;
  let titlePreview: string | undefined;
  let titleRequest: AbortController | undefined;
  let historyDirectory: string | undefined;
  let command: ExtensionCommandContext | undefined;
  let dispatchTimer: NodeJS.Timeout | undefined;
  let regenerate: { nonce: string; run: (ctx: ExtensionCommandContext) => Promise<void> } | undefined;
  let switching = false;
  const events = new EventEmitter();

  const clearDispatch = () => {
    clearTimeout(dispatchTimer);
    dispatchTimer = undefined;
  };
  const trackDispatch = (requestId?: string, onUnconfirmed?: () => Promise<void>) => {
    const timer = setTimeout(async () => {
      if (onUnconfirmed) {
        try { await onUnconfirmed(); } catch { /* The previous reply is still in the session tree. */ }
        if (dispatchTimer !== timer) return;
      }
      clearDispatch();
      regenerate = undefined;
      events.emit("prompt_unconfirmed", requestId);
    }, 5000).unref();
    dispatchTimer = timer;
    core.publish();
    return timer;
  };

  const driver = {
    agent: "pi",
    interactions: "host",
    nativeQueue: true,
    validateModelBeforeBusy: true,
    stageInlineImage: false,
    dispatchAfterReply: (command?: { source?: string }) => command?.source === "extension",
    on: events.on.bind(events),
    state() {
      const ctx = runtime?.ctx;
      if (!ctx || switching) return undefined;
      return { id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd, name: ctx.sessionManager.getSessionName() || titlePreview,
        idle: ctx.isIdle() && !dispatchTimer, queued: ctx.hasPendingMessages(),
        acceptsImage: ctx.model?.input.includes("image") === true,
        model: ctx.model && modelRow(ctx.model), thinkingLevel: ctx.thinkingLevel };
    },
    isStreaming: () => runtime?.ctx.isIdle() === false,
    get historyDirectory() { return historyDirectory; },
    historyLeaf: () => runtime?.ctx.sessionManager.getLeafId() ?? null,
    historyEntries: () => runtime ? historyEntries(runtime.ctx.sessionManager) : [],
    entries: () => Array.from(driver.historyEntries()).reverse(),
    runMessageIds(leaf: string | null) {
      const ids = new Set<string>();
      const manager = runtime?.ctx.sessionManager;
      let remaining = 500;
      for (let entry = manager?.getLeafEntry(); entry && entry.id !== leaf && remaining-- > 0;
        entry = entry.parentId ? manager?.getEntry(entry.parentId) : undefined) ids.add(entry.id);
      return ids;
    },
    async listProjectSessions() {
      const active = runtime!;
      return (await catalog(active)).map(({ id, name, firstMessage, modified, messageCount, cwd }) =>
        ({ id, name: name || (firstMessage === "(no messages)" ? undefined : sessionTitlePreview(firstMessage)),
          modified, messageCount, cwd }));
    },
    listModels() {
      const { ctx } = runtime!;
      const scoped = ctx.scopedModels;
      const source = scoped.length ? scoped.map((entry) => entry.model) : ctx.modelRegistry.getAvailable();
      const seen = new Set<string>();
      const models = source.filter((model) => {
        const key = `${model.provider}/${model.id}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      }).map(modelRow);
      const current = ctx.model;
      return { scoped: scoped.length > 0, models,
        current: current && { ...modelRow(current), thinkingLevel: ctx.thinkingLevel } };
    },
    listCommands() {
      return runtime!.pi.getCommands().filter((command) => command.name !== regenerateCommand).map((command) => ({
        name: command.name,
        description: typeof command.description === "string" ? command.description.slice(0, 300) : undefined,
        source: command.source,
        invoke: `/${command.name}`,
      }));
    },
    async open(id: unknown) {
      if (process.env.PIGO_ALLOW_RPC_SWITCH !== "1") return fail(409, "desktop_handoff_required");
      const active = runtime!;
      const rows = await catalog(active);
      if (runtime !== active || switching || dispatchTimer || !command || !active.ctx.isIdle() || active.ctx.hasPendingMessages()) {
        return fail(409, "not_ready_to_open");
      }
      const matches = rows.filter((row) => row.id === id);
      if (matches.length !== 1) return fail(404, "session_not_found");
      if (status()?.id === id) return {};
      switching = true;
      try {
        const result = await command.switchSession(matches[0].path, { withSession: (ctx) => { command = ctx; } });
        if (result.cancelled) return fail(409, "open_cancelled");
        if (runtime?.ctx.sessionManager.getSessionId() !== id) return fail(409, "runtime_not_rebound");
        return {};
      } finally {
        switching = false;
        events.emit("changed");
      }
    },
    async setModel(input: { provider?: unknown; modelId?: unknown; thinkingLevel?: Parameters<ExtensionAPI["setThinkingLevel"]>[0] }) {
      const active = runtime!;
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
      const current = active.ctx.model;
      return { current: current && { ...modelRow(current), thinkingLevel: active.ctx.thinkingLevel, levels: levelsOf(current) } };
    },
    fork: (id: string) => branchReply(id, true),
    regenerate: (id: string) => branchReply(id, false),
    rename(name: string) {
      const { pi, ctx } = runtime!;
      pi.setSessionName(name);
      if (ctx.sessionManager.getSessionName() !== name) return false;
      titleRequest?.abort();
      return true;
    },
    abort: () => runtime?.ctx.abort(),
    prompt(payload: { text: string; images: { bytes: Buffer }[]; mode: "send" | "steer" | "followUp";
      command?: { source: string }; requestId: string }) {
      const deliverAs = payload.mode === "send" ? undefined : payload.mode;
      const parts: PromptContentPart[] = [{ type: "text", text: payload.text }];
      for (const { bytes } of payload.images) parts.push({ type: "image", mimeType: "image/jpeg", data: bytes.toString("base64") });
      const waitForStart = !deliverAs && !driver.dispatchAfterReply(payload.command);
      if (waitForStart) trackDispatch(payload.requestId);
      try {
        runtime!.pi.sendUserMessage(parts.length > 1 ? parts : payload.text, {
          expandPromptTemplates: payload.command !== undefined, deliverAs,
        });
      } catch (error) {
        if (waitForStart) { clearDispatch(); core.publish(); }
        throw error;
      }
    },
  };
  const core = createWorkerServer(driver);
  const { worker, status } = core;

  async function branchReply(messageId: string, fork: boolean) {
    const active = runtime!;
    const manager = active.ctx.sessionManager;
    const branch = manager.getBranch();
    const index = branch.findIndex((entry) => entry.id === messageId);
    const answer = branch[index];
    if (answer?.type !== "message" || answer.message.role !== "assistant" ||
        !hasReplyContent(answer.message.content)) {
      return fail(404, "message_not_found");
    }
    if (fork) {
      const source = manager.getSessionFile();
      if (!source) return fail(409, "session_not_persisted");
      // Operate on a separate manager so the original Pi runtime stays on its current session.
      const copy = SessionManager.open(source, manager.getSessionDir(), active.ctx.cwd);
      copy.createBranchedSession(answer.id);
      const name = status()?.name || "会话";
      copy.appendSessionInfo(`${name.slice(0, 190)}（分支）`);
      return { id: copy.getSessionId() };
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
        core.publish();
      }
      return fail(409, "regenerate_failed");
    }
    return {};
  }

  return {
    bind(pi: ExtensionAPI, ctx: ExtensionContext) {
      if (runtime?.ctx.sessionManager === ctx.sessionManager &&
          runtime.ctx.sessionManager.getSessionId() === ctx.sessionManager.getSessionId()) return;
      titleRequest?.abort();
      clearDispatch();
      runtime = { pi, ctx };
      const firstUser = ctx.sessionManager.getEntries().find((entry) => entry.type === "message" && entry.message.role === "user");
      firstUserSeen = firstUser !== undefined;
      titlePreview = firstUser?.type === "message" && firstUser.message.role === "user"
        ? sessionTitlePreview(firstUser.message.content) : undefined;
      try { historyDirectory = realpathSync(ctx.sessionManager.getSessionDir()); }
      catch { historyDirectory = undefined; }
      core.resetSession({ notify: !switching });
    },
    unbind() {
      clearDispatch();
      regenerate = undefined;
      titleRequest?.abort();
      runtime = undefined;
      command = undefined;
      core.resetSession({ notify: false });
      core.unlisten();
    },
    agentStarted() {
      clearDispatch();
      events.emit("turn_start");
    },
    delta: (text: string) => events.emit("delta", text),
    thinking: (text: string) => events.emit("thinking", text),
    toolStart: (id: string, name: string, args: unknown) => events.emit("tool_start", { id, name, args }),
    toolEnd: (id: string, failed: boolean, ms: number | undefined, result: unknown) =>
      events.emit("tool_end", { id, failed, ms, result }),
    settled: (aborted: boolean) => events.emit("turn_end", { aborted }),
    final: (reason: string) => events.emit("message_final", reason),
    async firstUserMessage(content: unknown, ctx: ExtensionContext) {
      const active = runtime;
      if (firstUserSeen || !active || active.ctx.sessionManager.getSessionId() !== ctx.sessionManager.getSessionId()) return;
      firstUserSeen = true;
      titlePreview = sessionTitlePreview(content);
      if (ctx.sessionManager.getSessionName() || !titlePreview) return;
      events.emit("changed");
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
          events.emit("changed");
        }
      } catch {
        // The preview already supplies a title when this optional request fails.
      } finally {
        if (titleRequest === request) titleRequest = undefined;
      }
    },
    changed: () => events.emit("changed"),
    cancelTitleRequest: () => titleRequest?.abort(),
    isShared: () => worker.listening,
    handle: core.handle,
    async share(ctx: ExtensionContext) {
      if ("switchSession" in ctx) command = ctx as ExtensionCommandContext;
      await core.listen();
    },
    setCommandContext(ctx: ExtensionCommandContext) { command = ctx; },
    stop() {
      titleRequest?.abort();
      clearDispatch();
      regenerate = undefined;
      void core.stop();
    },
  };
}
