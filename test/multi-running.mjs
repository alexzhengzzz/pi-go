// The bridge must report every concurrently running session, not just the selected chat.
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { localRequest } from "../desktop/local-ipc.mjs";

const project = new URL("../", import.meta.url).pathname;

function fakeWorker(context, ipc, { id, cwd, idle, queued = false, name }) {
  const path = join(ipc, `w-${process.pid}-${Math.random().toString(16).slice(2, 10)}.sock`);
  const server = createServer(async (req, res) => {
    const reply = (status, data) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(data)); };
    if (req.method === "GET" && req.url === "/session") {
      return reply(200, { session: { id, cwd, name, idle, queued, runId: idle ? undefined : "r",
        acceptsImage: true, model: { provider: "pi-go-test", id: "fixture", name: "Fixture" } } });
    }
    if (req.method === "GET" && req.url === "/chat") {
      return reply(200, { session: { id, cwd, name, idle, queued, runId: idle ? undefined : "r",
        acceptsImage: true, model: { provider: "pi-go-test", id: "fixture", name: "Fixture" } },
        messages: [], liveText: idle ? "" : "streaming", historyCursor: undefined });
    }
    reply(404, { error: "not_found" });
  });
  const ready = new Promise((resolve) => server.listen(path, () => resolve(path)));
  context.after(async () => { await new Promise((resolve) => server.close(resolve)); });
  return ready;
}

// A Pi Desktop host that reports one pending interaction for a chosen session.
function fakeHost(context, ipc, pendingFor) {
  const path = join(ipc, `host-${process.pid}.sock`);
  const server = createServer(async (req, res) => {
    const reply = (status, data) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(data)); };
    if (req.method === "GET" && req.url === "/health") return reply(200, { protocol: "pi-go-desktop-host/1", profile: "test" });
    if (req.method === "POST" && req.url === "/pending") {
      let body = "";
      for await (const chunk of req) body += chunk;
      const input = JSON.parse(body);
      if (input.pid !== process.pid) return reply(409, { error: "session_changed" });
      const interaction = pendingFor[input.id];
      return reply(200, interaction ? { interaction } : {});
    }
    reply(404, { error: "not_found" });
  });
  const ready = new Promise((resolve) => server.listen(path, () => resolve(path)));
  context.after(async () => { await new Promise((resolve) => server.close(resolve)); });
  return ready;
}

test("sessions/status reports every running session with names, independent of the selected chat", { timeout: 30000 }, async (context) => {
  const ipc = await mkdtemp(join(tmpdir(), "pigo-multi-"));
  context.after(async () => { await rm(ipc, { force: true, recursive: true }); });
  const reservation = createServer().listen(0, "127.0.0.1");
  await once(reservation, "listening");
  const { port } = reservation.address();
  await new Promise((resolve) => reservation.close(resolve));

  const a = await fakeWorker(context, ipc, { id: "aaaaaaa1-0000-4000-8000-00000000000a", cwd: "/proj/a", idle: false, name: "Deploy site" });
  const b = await fakeWorker(context, ipc, { id: "bbbbbbb2-0000-4000-8000-00000000000b", cwd: "/proj/b", idle: false, name: "Refactor tests" });
  const c = await fakeWorker(context, ipc, { id: "ccccccc3-0000-4000-8000-00000000000c", cwd: "/proj/c", idle: true, queued: true, name: "Queued task" });
  const host = await fakeHost(context, ipc, {
    "aaaaaaa1-0000-4000-8000-00000000000a": { id: "ask-1", method: "select", title: "选择方案", options: ["A", "B"] },
  });

  const bridge = spawn(process.execPath, [join(project, "desktop/broker.mjs"), String(port)], { env: { ...process.env, PIGO_IPC_DIR: ipc } });
  context.after(async () => {
    await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/stop").catch(() => bridge.kill());
    await once(bridge, "exit").catch(() => {});
  });
  const admin = join(ipc, `bridge-${port}.sock`);
  let issued;
  for (let attempt = 0; attempt < 60 && !issued; attempt++) {
    issued = await localRequest(admin, "POST", "/ticket").catch(() => undefined);
    if (!issued) await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(issued?.status, 200);
  const config = JSON.parse(await readFile(issued.data.file, "utf8"));
  const paired = await fetch(`${config.url}/pair`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ticket: config.ticket }) });
  const { token } = await paired.json();
  const headers = { authorization: `Bearer ${token}` };
  const get = async (route) => (await fetch(`${config.url}${route}`, { headers })).json();

  // The phone keeps chatting on A while B also runs: both must be reported, with names for the header capsules.
  const opened = await fetch(`${config.url}/open`, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ id: "aaaaaaa1-0000-4000-8000-00000000000a" }) });
  assert.equal(opened.status, 200);
  const status = await get("/sessions/status");
  assert.deepEqual(new Set(status.runningSessionIds), new Set(["aaaaaaa1-0000-4000-8000-00000000000a", "bbbbbbb2-0000-4000-8000-00000000000b", "ccccccc3-0000-4000-8000-00000000000c"]));
  const byId = new Map(status.runningSessions.map((row) => [row.id, row]));
  // A streams with a pending interaction -> waiting; B streams untouched; C only queues messages.
  assert.equal(byId.get("aaaaaaa1-0000-4000-8000-00000000000a")?.state, "waiting");
  assert.equal(byId.get("bbbbbbb2-0000-4000-8000-00000000000b")?.state, "streaming");
  assert.equal(byId.get("ccccccc3-0000-4000-8000-00000000000c")?.state, "queued");
  for (const row of status.runningSessions) assert.equal("pid" in row, false, "internal pid must not leak");
  assert.equal(byId.get("aaaaaaa1-0000-4000-8000-00000000000a")?.name, "Deploy site");
  assert.equal(byId.get("bbbbbbb2-0000-4000-8000-00000000000b")?.name, "Refactor tests");
  assert.equal(byId.get("bbbbbbb2-0000-4000-8000-00000000000b")?.cwd, "/proj/b");
  // The list marks every active worker, and queued sessions count as running too.
  const list = await get("/sessions");
  assert.deepEqual(new Set(list.sessions.filter((row) => row.active).map((row) => row.id)),
    new Set(["aaaaaaa1-0000-4000-8000-00000000000a", "bbbbbbb2-0000-4000-8000-00000000000b", "ccccccc3-0000-4000-8000-00000000000c"]));
  const chat = await get("/chat");
  assert.equal(chat.session.id, "aaaaaaa1-0000-4000-8000-00000000000a");
  assert.equal(chat.session.idle, false);
});
