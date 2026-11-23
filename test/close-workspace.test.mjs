// Closing a workspace from the phone must remove it from the host's project list
// (via the host), forget the phone-side grant, and drop it from the next listing.
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, readFile, realpath, rename, stat, utimes, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { localRequest } from "../host/bridge/local-ipc.mjs";
import { createDaemonHost } from "../host/daemon/host.mjs";
import { WorkspaceRegistry } from "../host/daemon/registry.mjs";

const project = new URL("../", import.meta.url).pathname;
const profile = "a".repeat(64);

function fakeWorker(context, ipc, { id, cwd, idle, name }) {
  const path = join(ipc, `w-${process.pid}-${Math.random().toString(16).slice(2, 10)}.sock`);
  const session = { id, cwd, name, idle, queued: false,
    acceptsImage: true, model: { provider: "pi-go-test", id: "fixture", name: "Fixture" } };
  const server = createServer(async (req, res) => {
    const reply = (status, data) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(data)); };
    if (req.method === "GET" && (req.url === "/session" || req.url === "/chat")) {
      return reply(200, req.url === "/session" ? { session } : { session, messages: [], liveText: "", historyCursor: undefined });
    }
    reply(404, { error: "not_found" });
  });
  const stop = () => new Promise((resolve) => { server.closeAllConnections(); server.close(() => resolve()); });
  const ready = new Promise((resolve) => server.listen(path, () => resolve(path)));
  context.after(async () => { await stop(); });
  return { ready, close: stop };
}

// A test host that records close requests and shuts the matching fake workers down,
// mirroring how removing a workspace stops its Pi processes.
function fakeHost(context, ipc, workers, onClosed, onCreated) {
  const path = join(ipc, `host-${process.pid}.sock`);
  const closed = [];
  const server = createServer(async (req, res) => {
    const reply = (status, data) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(data)); };
    if (req.method === "GET" && req.url === "/health") return reply(200, { protocol: "pi-go-desktop-host/1", profile, canCreateWorkspace: Boolean(onCreated) });
    if (req.method !== "POST") return reply(404, { error: "not_found" });
    let body = "";
    for await (const chunk of req) body += chunk;
    const input = JSON.parse(body || "{}");
    if (req.url === "/authorize") return reply(200, { cwd: input.cwd, profile });
    if (req.url === "/catalog") return reply(200, { sessions: [] });
    if (req.url === "/projects") return reply(200, { projects: [] });
    if (req.url === "/create-workspace" && onCreated) return reply(200, onCreated(input));
    if (req.url === "/close-workspace") {
      closed.push(input.cwd);
      if (onClosed?.(input, reply)) return;
      await Promise.all(workers.filter((worker) => worker.cwd === input.cwd).map((worker) => worker.close()));
      return reply(200, { closed: true, cwd: input.cwd });
    }
    reply(404, { error: "not_found" });
  });
  const stop = () => new Promise((resolve) => { server.closeAllConnections(); server.close(() => resolve()); });
  const ready = new Promise((resolve) => server.listen(path, () => resolve(path)));
  context.after(async () => { await stop(); });
  return { ready, closed, stop };
}

async function pairBroker(context, ipc, port) {
  const bridge = spawn(process.execPath, [join(project, "host/bridge/broker.mjs"), String(port)], { env: { ...process.env, PIGO_IPC_DIR: ipc } });
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
  const post = async (route, value, useHeaders = headers) => {
    const response = await fetch(`${config.url}${route}`, { method: "POST", headers: { ...useHeaders, "content-type": "application/json" }, body: JSON.stringify(value) });
    return { status: response.status, data: await response.json() };
  };
  const get = async (route) => (await fetch(`${config.url}${route}`, { headers })).json();
  return { config, headers, post, get };
}

async function reservePort() {
  const reservation = createServer().listen(0, "127.0.0.1");
  await once(reservation, "listening");
  const { port } = reservation.address();
  await new Promise((resolve) => reservation.close(resolve));
  return port;
}

test("creating a space requires pairing, computer access and host support", { timeout: 30000 }, async (context) => {
  const ipc = await mkdtemp(join(tmpdir(), "pigo-create-"));
  context.after(async () => { await rm(ipc, { force: true, recursive: true }); });
  const port = await reservePort();
  const requests = [];
  const host = fakeHost(context, ipc, [], undefined, (input) => {
    requests.push(input);
    return { cwd: join(ipc, input.name) };
  });
  await host.ready;
  const phone = await pairBroker(context, ipc, port);
  const input = { name: "测试 空间" };

  assert.equal((await phone.post("/create-workspace", input, {})).status, 401);
  assert.equal((await phone.get("/sessions")).canCreateWorkspace, false);
  assert.deepEqual(await phone.post("/create-workspace", input), { status: 403, data: { error: "computer_access_required" } });
  assert.deepEqual(requests, []);

  assert.equal((await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/computer-access")).status, 200);
  assert.equal((await phone.get("/sessions")).canCreateWorkspace, true);
  assert.equal((await phone.post("/create-workspace", { cwd: "/other" })).status, 400);
  assert.deepEqual(await phone.post("/create-workspace", { ...input, cwd: "/other" }),
    { status: 200, data: { cwd: join(ipc, input.name) } });
  assert.deepEqual(requests, [input]);
});

test("phone closes workspaces on the host, forgets grants and stops hosting sessions", { timeout: 30000 }, async (context) => {
  const ipc = await mkdtemp(join(tmpdir(), "pigo-close-"));
  context.after(async () => { await rm(ipc, { force: true, recursive: true }); });
  const projectDir = await realpath(await mkdtemp(join(tmpdir(), "pigo-close-project-")));
  context.after(async () => { await rm(projectDir, { force: true, recursive: true }); });
  const port = await reservePort();

  const a = fakeWorker(context, ipc, { id: "aaaaaaa1-0000-4000-8000-00000000000a", cwd: "/proj/a", idle: false, name: "Deploy site" });
  const b = fakeWorker(context, ipc, { id: "bbbbbbb2-0000-4000-8000-00000000000b", cwd: "/proj/b", idle: true, name: "Idle notes" });
  const host = fakeHost(context, ipc, [
    { cwd: "/proj/a", close: () => a.close() },
    { cwd: "/proj/b", close: () => b.close() },
  ]);
  await Promise.all([a.ready, b.ready, host.ready]);

  const phone = await pairBroker(context, ipc, port);

  assert.equal((await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/computer-access")).status, 200);
  assert.equal((await phone.get("/sessions")).canCreateWorkspace, false);
  assert.equal((await phone.post("/create-workspace", { name: "new" })).data.error, "desktop_workspace_creation_unsupported");

  // Unauthenticated and malformed requests never reach the host.
  assert.equal((await phone.post("/close-workspace", { cwd: projectDir }, {})).status, 401);
  assert.deepEqual(await phone.post("/close-workspace", {}), { status: 400, data: { error: "invalid_target" } });
  assert.deepEqual(await phone.post("/close-workspace", { cwd: "/not/shared" }), { status: 403, data: { error: "desktop_workspace_unshared" } });
  assert.deepEqual(host.closed, []);

  // Authorize a granted workspace through the host, exactly like the real pairing flow.
  const grant = await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/grant", { cwd: projectDir });
  assert.equal(grant.status, 200);
  let list = await phone.get("/sessions");
  assert.deepEqual(new Set(list.projects), new Set([projectDir, "/proj/a", "/proj/b"]));

  // Closing a granted-only workspace forwards to the host and revokes the grant,
  // so the next network refresh no longer lists it.
  assert.deepEqual(await phone.post("/close-workspace", { cwd: projectDir }), { status: 200, data: { closed: true } });
  assert.deepEqual(host.closed, [projectDir]);
  list = await phone.get("/sessions");
  assert.deepEqual(new Set(list.projects), new Set(["/proj/a", "/proj/b"]));

  // Closing the workspace hosting the selected session resets the selection...
  const opened = await phone.post("/open", { id: "aaaaaaa1-0000-4000-8000-00000000000a" });
  assert.equal(opened.status, 200);
  assert.equal((await phone.get("/chat")).session.id, "aaaaaaa1-0000-4000-8000-00000000000a");
  assert.deepEqual(await phone.post("/close-workspace", { cwd: "/proj/a" }), { status: 200, data: { closed: true } });
  // ...and the stopped worker disappears from the catalog like a dead Pi process.
  assert.equal((await phone.get("/chat")).session.id, "bbbbbbb2-0000-4000-8000-00000000000b");
  list = await phone.get("/sessions");
  assert.deepEqual(list.projects, ["/proj/b"]);

  // Closing the last workspace leaves the phone with no shared sessions at all.
  assert.deepEqual(await phone.post("/close-workspace", { cwd: "/proj/b" }), { status: 200, data: { closed: true } });
  const chat = await phone.get("/chat");
  assert.equal(chat.session, undefined);
  assert.equal(chat.state, "no_shared_sessions");
  assert.deepEqual((await phone.get("/sessions")).projects, []);
  assert.deepEqual(host.closed, [projectDir, "/proj/a", "/proj/b"]);
});

test("host refusals and outages surface their own errors instead of pretending success", { timeout: 30000 }, async (context) => {
  const ipc = await mkdtemp(join(tmpdir(), "pigo-close-refusal-"));
  context.after(async () => { await rm(ipc, { force: true, recursive: true }); });
  const port = await reservePort();
  const refusals = new Map();
  const host = fakeHost(context, ipc, [], (input, reply) => {
    const refusal = refusals.get(input.cwd);
    if (!refusal) return false;
    reply(refusal.status, { error: refusal.error });
    return true;
  });
  await host.ready;

  const phone = await pairBroker(context, ipc, port);
  const grant = await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/grant", { cwd: "/tmp" });
  assert.equal(grant.status, 200);
  const granted = await realpath("/tmp");
  assert.deepEqual(new Set((await phone.get("/sessions")).projects), new Set([granted]));

  // Host refusals pass their status and code straight through to the phone.
  refusals.set(granted, { status: 404, error: "desktop_workspace_not_registered" });
  assert.deepEqual(await phone.post("/close-workspace", { cwd: granted }), { status: 404, data: { error: "desktop_workspace_not_registered" } });
  refusals.set(granted, { status: 409, error: "desktop_workspace_kind_unsupported" });
  assert.deepEqual(await phone.post("/close-workspace", { cwd: granted }), { status: 409, data: { error: "desktop_workspace_kind_unsupported" } });
  // A failed close keeps the grant so the workspace stays reachable for the next attempt.
  assert.deepEqual(new Set((await phone.get("/sessions")).projects), new Set([granted]));

  // Without a reachable host the close is refused instead of silently skipped.
  await host.stop();
  assert.deepEqual(await phone.post("/close-workspace", { cwd: granted }), { status: 409, data: { error: "desktop_handoff_required" } });
});

test("desktop edits and removes registrations and deletes only unoccupied history, updating the phone catalog", { timeout: 30000 }, async (context) => {
  const root = await realpath(await mkdtemp("/tmp/pigo-library-"));
  const cwd = join(root, "project");
  const empty = join(root, "empty");
  const agent = join(root, "agent");
  const ipc = join(root, "ipc");
  const store = join(agent, "sessions", "project");
  const trash = join(root, "trash");
  await Promise.all([cwd, empty, store, ipc, trash].map((path) => mkdir(path, { recursive: true, mode: 0o700 })));
  context.after(async () => rm(root, { recursive: true, force: true }));
  for (const [key, value] of Object.entries({ PI_CODING_AGENT_DIR: agent, PIGO_IPC_DIR: ipc, PIGO_STATE_DIR: join(root, "state") })) {
    const previous = process.env[key];
    process.env[key] = value;
    context.after(() => {
      if (previous === undefined) delete process.env[key];
      else process.env[key] = previous;
    });
  }

  const id = "aaaaaaaa-0000-4000-8000-000000000001";
  const otherId = "aaaaaaaa-0000-4000-8000-000000000002";
  const history = (sessionId) => JSON.stringify({ type: "session", id: sessionId, cwd }) + "\n" +
    JSON.stringify({ type: "message", message: { role: "user", content: "History" } }) + "\n";
  const file = join(store, `dated_${id}.jsonl`);
  const otherFile = join(store, `${otherId}.jsonl`);
  await Promise.all([writeFile(file, history(id)), writeFile(otherFile, history(otherId))]);

  const registryFile = join(root, "registry", "workspaces.json");
  const registry = new WorkspaceRegistry(registryFile);
  const registration = registry.create("Original", cwd);
  const emptyRegistration = registry.create("Empty", empty);
  let externalPi = false;
  const closed = [];
  const active = [];
  let finishTrash;
  let signalTrash;
  const trashStarted = new Promise((resolve) => { signalTrash = resolve; });
  const trashGate = new Promise((resolve) => { finishTrash = resolve; });
  const host = createDaemonHost({
    registry,
    runtimes: { list: () => active, killFor: async (path) => closed.push(path) },
    hasExternalPi: async () => externalPi,
    trash: async (path) => {
      signalTrash();
      await trashGate;
      await rename(path, join(trash, `${id}.jsonl`));
    },
  });
  host.server.listen(host.path);
  await once(host.server, "listening");
  context.after(() => { finishTrash(); host.shutdown(); });
  const desktop = (path, input = {}) => localRequest(host.path, "POST", path, input);

  const initial = await desktop("/workspace-library", { scope: "workspaces" });
  assert.deepEqual(initial.data.workspaces.map((row) => [row.cwd, row.sessions]), [[cwd, []], [empty, []]]);
  const scoped = await desktop("/workspace-library", { scope: "workspace", cwd });
  assert.deepEqual(new Set(scoped.data.history.map((row) => row.id)), new Set([id, otherId]));
  assert.equal((await desktop("/workspace-library", { scope: "workspace", cwd: root })).status, 404);

  const library = await desktop("/workspace-library");
  assert.deepEqual(library.data.workspaces.find((row) => row.cwd === empty).sessions, []);
  assert.equal(library.data.workspaces.find((row) => row.cwd === cwd).sessions.length, 2);
  assert.equal((await desktop("/rename-workspace", { id: registration.id, name: "../bad" })).status, 400);
  assert.equal((await desktop("/rename-workspace", { id: registration.id, name: "Renamed" })).status, 200);
  assert.equal(new WorkspaceRegistry(registryFile).list().find((row) => row.id === registration.id).name, "Renamed");

  const port = await reservePort();
  const phone = await pairBroker(context, ipc, port);
  const admin = join(ipc, `bridge-${port}.sock`);
  assert.equal((await localRequest(admin, "POST", "/grant", { cwd: empty })).status, 200);
  assert.ok((await phone.get("/sessions")).projects.includes(empty));
  assert.equal((await desktop("/remove-workspace", { id: emptyRegistration.id })).status, 200);
  assert.deepEqual(closed, [empty]);
  assert.ok((await stat(empty)).isDirectory());
  assert.ok(!(await phone.get("/sessions")).projects.includes(empty));

  await localRequest(admin, "POST", "/computer-access");
  const before = await phone.get("/sessions");
  assert.deepEqual(before.workspaces, [{ cwd, name: "Renamed" }]);
  assert.ok(before.sessions.some((row) => row.id === id));

  // A session selected on the phone can close before its history is deleted.
  const worker = fakeWorker(context, ipc, { id, cwd, idle: true, name: "History" });
  await worker.ready;
  assert.equal((await phone.post("/open", { id })).status, 200);
  assert.equal((await desktop("/delete-session", { cwd, id })).data.error, "session_occupied");
  await worker.close();
  active.push({ sessionId: id, cwd, pid: 1 });
  assert.equal((await desktop("/delete-session", { cwd, id })).data.error, "session_occupied");
  active.pop();
  externalPi = true;
  assert.equal((await desktop("/delete-session", { cwd, id })).data.error, "session_occupied");
  externalPi = false;
  assert.equal((await desktop("/delete-session", { cwd: empty, id })).status, 404);
  assert.equal((await phone.post("/delete-session", { cwd, id })).status, 404);

  const deletion = desktop("/delete-session", { cwd, id });
  await trashStarted;
  assert.equal((await desktop("/open", { cwd, id })).data.error, "desktop_busy");
  finishTrash();
  assert.deepEqual(await deletion, { status: 200, data: { deleted: true } });
  assert.equal((await desktop("/delete-session", { cwd, id })).status, 404);
  assert.equal(await readFile(join(trash, `${id}.jsonl`), "utf8"), history(id));
  assert.equal(await readFile(otherFile, "utf8"), history(otherId));
  assert.deepEqual((await phone.get("/sessions")).sessions.map((row) => row.id), [otherId]);
  const snapshot = await phone.get("/session/snapshot");
  assert.equal(snapshot.state, "session_deleted");
  assert.equal(snapshot.deletedSessionId, id);

  assert.equal((await desktop("/remove-workspace", { id: registration.id })).status, 200);
  const remaining = (await desktop("/workspace-library")).data.workspaces.find((row) => row.cwd === cwd);
  assert.equal(remaining.registered, false);
  assert.equal((await desktop("/workspace-library", { scope: "workspaces" })).data.workspaces.some((row) => row.cwd === cwd), false);
  assert.deepEqual(remaining.sessions.map((row) => row.id), [otherId]);
  assert.deepEqual(new WorkspaceRegistry(registryFile).list(), []);
});

test("workspace browsing pages registered folders without adding an opened session directory", { timeout: 15000 }, async (context) => {
  const root = await realpath(await mkdtemp("/tmp/pigo-scoped-catalog-"));
  const cwd = join(root, "project");
  const other = join(root, "other");
  const agent = join(root, "agent");
  const sessions = join(agent, "sessions");
  const ipc = join(root, "ipc");
  for (const [key, value] of Object.entries({
    PI_CODING_AGENT_DIR: agent, CODEX_HOME: join(root, "codex"), PIGO_IPC_DIR: ipc, PIGO_STATE_DIR: join(root, "state"),
  })) {
    const previous = process.env[key];
    process.env[key] = value;
    context.after(() => {
      if (previous === undefined) delete process.env[key];
      else process.env[key] = previous;
    });
  }
  context.after(() => rm(root, { recursive: true, force: true }));
  const groups = [[cwd, 23], [other, 1]];
  let nextId = 0;
  let oldId;
  const projectIds = [];
  for (const [path, count] of groups) {
    const store = join(sessions, `--${path.slice(1).replaceAll("/", "-")}--`);
    await Promise.all([path, store, ipc].map((dir) => mkdir(dir, { recursive: true, mode: 0o700 })));
    for (let index = 0; index < count; index++) {
      const id = `aaaaaaaa-0000-4000-8000-${String(++nextId).padStart(12, "0")}`;
      const file = join(store, id + ".jsonl");
      await writeFile(file, [
        { type: "session", id, cwd: path },
        { type: "message", message: { role: "user", content: path === other ? "Old task elsewhere" : "Project task" } },
      ].map(JSON.stringify).join("\n") + "\n");
      await utimes(file, 1700000000 + nextId, 1700000000 + nextId);
      if (path === other) oldId = id;
      else projectIds.unshift(id);
    }
  }

  const registry = new WorkspaceRegistry(join(root, "registry", "workspaces.json"));
  const opened = [];
  const host = createDaemonHost({
    registry,
    runtimes: {
      list: () => [],
      start: (path, sessionPath) => ({
        async awaitReady(id) { opened.push([path, sessionPath, id]); return { sessionId: id }; },
        async sendCommand() { return {}; },
      }),
    },
  });
  host.server.listen(host.path);
  await once(host.server, "listening");
  context.after(() => host.shutdown());
  const desktop = (path, input = {}) => localRequest(host.path, "POST", path, input);
  assert.equal((await desktop("/authorize", { cwd })).status, 200);

  const port = await reservePort();
  const phone = await pairBroker(context, ipc, port);
  await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/computer-access");
  const initial = await phone.get("/sessions?scope=workspaces");
  assert.deepEqual(initial.projects, [cwd]);
  assert.deepEqual(initial.sessions, []);

  const workspace = "/sessions?scope=workspace&limit=10&cwd=" + encodeURIComponent(cwd);
  const pinned = await phone.post("/session-meta", { id: projectIds.at(-1), cwd, pinned: true, revision: 0 });
  assert.equal(pinned.status, 200);
  const first = await phone.get(workspace);
  const second = await phone.get(workspace + "&cursor=" + first.nextCursor);
  const last = await phone.get(workspace + "&cursor=" + second.nextCursor);
  assert.deepEqual(first.sessions.map(({ id }) => id), projectIds.slice(0, 10));
  assert.deepEqual(second.sessions.map(({ id }) => id), projectIds.slice(10, 20));
  assert.equal(last.sessions.length, 3);
  assert.deepEqual(last.sessions.map(({ id }) => id), projectIds.slice(20));
  assert.equal(last.sessions.at(-1).pinned, true);
  assert.equal(last.nextCursor, undefined);
  assert.deepEqual(new Set([...first.sessions, ...second.sessions, ...last.sessions].map((row) => row.cwd)), new Set([cwd]));

  const newId = "aaaaaaaa-0000-4000-8000-000000000025";
  const store = join(sessions, `--${cwd.slice(1).replaceAll("/", "-")}--`);
  await writeFile(join(store, newId + ".jsonl"), [
    { type: "session", id: newId, cwd },
    { type: "message", message: { role: "user", content: "New desktop task" } },
  ].map(JSON.stringify).join("\n") + "\n");
  const refreshed = await phone.get(workspace + "&refresh=1");
  assert.equal(refreshed.sessions.length, 10);
  assert.equal(refreshed.sessions[0].id, newId);

  assert.equal((await phone.get("/sessions?scope=history")).error, "invalid_scope");
  assert.equal((await desktop("/workspace-library", { scope: "history" })).status, 400);
  assert.equal((await desktop("/open", { cwd: other, id: oldId })).status, 200);
  assert.deepEqual(opened.map(([path, , id]) => [path, id]), [[other, oldId]]);
  assert.deepEqual(registry.list().map((row) => row.path), [cwd]);
});
