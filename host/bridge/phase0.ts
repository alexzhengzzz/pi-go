import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { type ExtensionAPI, type ExtensionCommandContext, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { ipcDirectory, localRequest } from "./local-ipc.mjs";
import { pairingRuntime } from "./pairing-runtime.mjs";
import { readJsonBody } from "../agents/worker-core.mjs";
import { createPiWorker, modelRow } from "../agents/pi/driver.ts";
import { reply } from "./message-view.mjs";
import { captureMainDisplay } from "./screen-capture.mjs";

const host = "127.0.0.1";
const digest = (value: string) => createHash("sha256").update(value).digest();
const same = (value: unknown, expected: Buffer | undefined) =>
  typeof value === "string" && expected !== undefined && timingSafeEqual(digest(value), expected);
function createProbe() {
  const piWorker = createPiWorker();
  let directory: string | undefined;
  let ticket: Buffer | undefined;
  let code: Buffer | undefined;
  let attempts = 0;
  let token: Buffer | undefined;
  let expiry: NodeJS.Timeout | undefined;

  const removeTicket = () => {
    ticket = undefined;
    code = undefined;
    clearTimeout(expiry);
    if (directory) rmSync(directory, { recursive: true, force: true });
    directory = undefined;
  };
  const options = { requestTimeout: 5000, headersTimeout: 5000, connectionsCheckingInterval: 1000 };
  const server = createServer(options, async (request: IncomingMessage, response: ServerResponse) => {
    const address = server.address();
    if (request.headers.origin !== undefined || !address || typeof address === "string" ||
        request.headers.host !== `${host}:${address.port}`) return reply(response, 403, { error: "invalid_source" });
    if (request.method === "POST" && (request.url ?? "").split("?")[0] === "/pair") {
      try {
        const input = await readJsonBody(request);
        if (!same(input.ticket, ticket) && !same(input.ticket, code)) {
          if (ticket && ++attempts >= 5) removeTicket();
          return reply(response, 401, { error: "invalid_ticket" });
        }
        removeTicket();
        const secret = randomBytes(32).toString("hex");
        token = digest(`Bearer ${secret}`);
        return reply(response, 200, { token: secret });
      } catch (error) {
        if (error instanceof Error && error.message === "oversized_body") {
          response.setHeader("Connection", "close");
          request.resume();
          return reply(response, 413, { error: "payload_too_large" });
        }
        return reply(response, 400, { error: "request_failed" });
      }
    }
    if (!same(request.headers.authorization, token)) return reply(response, 401, { error: "unpaired" });
    return piWorker.handle(request, response, { local: true });
  });
  server.maxConnections = 12;
  server.setTimeout(30_000, (socket) => socket.destroy());

  return {
    ...piWorker,
    async start(ctx: ExtensionCommandContext, port: number) {
      piWorker.setCommandContext(ctx);
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
      removeTicket();
      server.close();
      server.closeAllConnections();
      piWorker.stop();
    },
  };
}

const key = Symbol.for("pi-go.phase0.probe");
const processState = globalThis as typeof globalThis & Record<symbol, ReturnType<typeof createProbe> | undefined>;

export default function (pi: ExtensionAPI) {
  if (process.platform === "darwin") {
    pi.registerTool({
      name: "computer_screenshot",
      label: "Computer Screenshot",
      description: "Capture one JPEG of the connected Mac's main display using Pi Go.app. Use only when the user explicitly asks to capture or inspect the current desktop.",
      promptSnippet: "Take a screenshot of the Mac's main display on explicit request",
      parameters: Type.Object({}, { additionalProperties: false }),
      async execute(_toolCallId, _params, signal, _onUpdate, ctx) {
        const image = await captureMainDisplay(pi, signal);
        const text = ctx.model?.input.includes("image") ? "已截取 Mac 主显示器。" :
          "已截取 Mac 主显示器。当前模型无法分析图片，可以在 Pi Go 的工具详情中查看。";
        return { content: [{ type: "text", text }, image], details: {} };
      },
    });
  }
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
