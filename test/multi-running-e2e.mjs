// Two real Pi sessions running at once — what does the bridge report?
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, mkdir, rm, readFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { createInterface } from "node:readline";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";
import { localRequest } from "../host/bridge/local-ipc.mjs";

const project = new URL("../", import.meta.url).pathname;
const provider = new URL("./offline-provider.ts", import.meta.url).pathname;
const pi = process.env.PI_BIN ?? "pi";

function start(agentDir, cwd, env = {}) {
  const child = spawn(pi, ["--offline", "--mode", "rpc", "--no-tools",
    "--no-mcp", "--no-approve", "--no-skills", "--no-context-files", "-e", provider,
    "--provider", "pi-go-test", "--model", "fixture"], { cwd, env: { ...process.env, ...env, PI_CODING_AGENT_DIR: agentDir, PIGO_TEST_COMMANDS: "1" } });
  const exit = once(child, "exit");
  const messages = [];
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  createInterface({ input: child.stdout }).on("line", (line) => messages.push(JSON.parse(line)));
  let sequence = 0;
  const wait = async (predicate, since = 0) => {
    for (let attempt = 0; attempt < 400; attempt++) {
      const found = messages.slice(since).find(predicate);
      if (found) return found;
      if (child.exitCode !== null) break;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`missing event: ${stderr}\n${JSON.stringify(messages.slice(-8))}`);
  };
  const rpc = async (type, data = {}) => {
    const id = `t${++sequence}`;
    child.stdin.write(`${JSON.stringify({ type, id, ...data })}\n`);
    const response = await wait((event) => event.type === "response" && event.id === id);
    assert.equal(response.success, true, JSON.stringify(response));
    return response.data;
  };
  return { exit, child, rpc, wait, messages };
}

test("two sessions running concurrently both appear in /sessions/status", { timeout: 90000 }, async (context) => {
  const agent = await mkdtemp(join(tmpdir(), "pigo-agent-"));
  const first = join(agent, "one");
  const second = join(agent, "two");
  const ipc = await mkdtemp(join(tmpdir(), "pigo-ipc-"));
  const port = 18979;
  await mkdir(first); await mkdir(second);
  const env = { PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PIGO_IPC_DIR: ipc, PIGO_ALLOW_RPC_SWITCH: "0" };
  await promisify(execFile)(pi, ["install", project], { cwd: first, env: { ...process.env, ...env } });
  const runtimeA = start(agent, first, env);
  const runtimeB = start(agent, second, env);
  context.after(async () => {
    await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/stop").catch(() => {});
    for (const runtime of [runtimeA, runtimeB]) { try { runtime.child.kill(); } catch {} }
    await Promise.allSettled([runtimeA.exit, runtimeB.exit]);
    await rm(agent, { force: true, recursive: true });
    await rm(ipc, { force: true, recursive: true });
  });
  // Prime each runtime with one settled turn so a session exists, then a fresh disposable session for A.
  await runtimeA.rpc("prompt", { message: "seed A" });
  await runtimeA.wait((event) => event.type === "agent_settled");
  const stateA = await runtimeA.rpc("get_state");
  const stateB0 = await runtimeB.rpc("get_state");
  // Start the shared bridge from A, share B.
  const sinceA = runtimeA.messages.length;
  await runtimeA.rpc("prompt", { message: `/pi-go-bridge ${port}` });
  await runtimeA.wait((event) => event.method === "notify" && event.message.startsWith("Pi Go ticket file: "), sinceA);
  const sinceB = runtimeB.messages.length;
  await runtimeB.rpc("prompt", { message: "/pi-go-share" });
  await runtimeB.wait((event) => event.method === "notify" && event.message === "Pi Go session shared", sinceB);
  const stateB = await runtimeB.rpc("get_state");
  // Bridge must be reachable first.
  let adminOk = false;
  for (let attempt = 0; attempt < 60 && !adminOk; attempt++) {
    adminOk = (await localRequest(join(ipc, `bridge-${port}.sock`), "GET", "/status").catch(() => undefined))?.status === 200;
    if (!adminOk) await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(adminOk, true, "bridge admin socket never came up");
  const ticket = await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/ticket");
  assert.equal(ticket.status, 200);
  const config = JSON.parse(await readFile(ticket.data.file, "utf8"));
  const pair = await fetch(`${config.url}/pair`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ticket: config.ticket }) });
  const { token } = await pair.json();
  const headers = { authorization: `Bearer ${token}` };
  const get = async (route) => (await fetch(`${config.url}${route}`, { headers })).json();

  // Start a long (22s) run in B from the desktop side.
  const runB = runtimeB.rpc("prompt", { message: "Pi Go fixture: long answer" });
  await runtimeB.wait((event) => event.type === "message_update");

  // Open A on the phone and start a long run there too, while B keeps running.
  const opened = await fetch(`${config.url}/open`, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ id: stateA.sessionId }) });
  assert.equal(opened.status, 200, await opened.text());
  const prompted = await fetch(`${config.url}/prompt`, { method: "POST", headers: { ...headers, "content-type": "application/json" },
    body: JSON.stringify({ id: stateA.sessionId, requestId: "multi-1", text: "Pi Go fixture: long answer" }) });
  assert.equal(prompted.status, 202, await prompted.text());

  // Both streams are now live at the same time.
  const status = await get("/sessions/status");
  console.log("A =", stateA.sessionId, "B =", stateB.sessionId);
  console.log("runningSessionIds while both run:", status.runningSessionIds);
  const bothRunning = (status.runningSessionIds ?? []).includes(stateA.sessionId) && (status.runningSessionIds ?? []).includes(stateB.sessionId);
  const named = new Map((status.runningSessions ?? []).map((row) => [row.id, row]));
  console.log("runningSessions names:", (status.runningSessions ?? []).map((row) => `${row.id.slice(0, 8)}:${row.name}`).join(", "));
  assert.equal(named.get(stateA.sessionId)?.cwd, realpathSync(first), "running rows carry the workspace for header capsules");
  assert.equal(named.get(stateB.sessionId)?.cwd, realpathSync(second));
  console.log(bothRunning ? "PASS: both sessions reported running" : `FAIL: expected 2, got ${JSON.stringify(status.runningSessionIds)}`);

  // Also confirm the session list marks both rows active & the chat is on A while B streams.
  const chat = await get("/chat");
  console.log("chat current =", chat.session?.id, "idle =", chat.session?.idle);

  // Abort both to finish quickly.
  await fetch(`${config.url}/abort`, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ id: stateA.sessionId }) });
  await runtimeB.rpc("abort");
  await Promise.allSettled([runB]);
  assert.equal(bothRunning, true, "bridge must report every running session, not just one");
});
