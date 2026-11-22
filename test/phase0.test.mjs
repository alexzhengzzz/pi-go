import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, realpath, rm, stat, truncate, utimes, writeFile, symlink, link } from "node:fs/promises";
import { createServer as createHttpServer } from "node:http";
import { request as httpsRequest } from "node:https";
import { checkServerIdentity } from "node:tls";
import { createHash, randomBytes, X509Certificate } from "node:crypto";
import { createSocket } from "node:dgram";
import { createServer } from "node:net";
import { networkInterfaces, tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { buffer } from "node:stream/consumers";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { localRequest } from "../desktop/local-ipc.mjs";
import { localLanAddress } from "../desktop/lan-tls.mjs";
import { startDiscovery } from "../desktop/lan-discovery.mjs";
import { listFiles, previewFile, saveFile, openWorkspaceDownload, maxTextBytes, maxDownloadBytes } from "../desktop/workspace-files.mjs";
import { SessionMetadata } from "../desktop/session-metadata.mjs";
import { validPromptImage, stageAttachment, stagedAttachment, stagingDir, maxFileBytes } from "../desktop/attachments.mjs";

const project = fileURLToPath(new URL("../", import.meta.url));
const provider = fileURLToPath(new URL("./offline-provider.ts", import.meta.url));
const pi = process.env.PI_BIN ?? "pi";
const lanHost = Object.values(networkInterfaces()).flat().find(({ address }) => localLanAddress(address))?.address;

test("workspace files enforce scope, text limits and conflict-safe atomic saves", async () => {
  const root = await mkdtemp(join(tmpdir(), "pigo-files-"));
  const cwd = join(root, "project");
  try {
    await mkdir(cwd);
    await writeFile(join(root, "outside.txt"), "outside");
    await writeFile(join(cwd, "note.txt"), "hello\r\n世界", { mode: 0o640 });
    await symlink(join(root, "outside.txt"), join(cwd, "escape"));
    await symlink(cwd, join(cwd, "inside-link"));
    await writeFile(join(cwd, "binary"), Buffer.from([0xff, 0x00]));
    await writeFile(join(cwd, "large"), Buffer.alloc(maxTextBytes + 1, 65));
    await writeFile(join(cwd, "huge"), "");
    await truncate(join(cwd, "huge"), maxDownloadBytes + 1);
    const before = previewFile(cwd, "note.txt");
    assert.equal(before.text, "hello\r\n世界");
    assert.throws(() => previewFile(cwd, "../outside.txt"), /invalid_path/);
    assert.throws(() => previewFile(cwd, join(root, "outside.txt")), /invalid_path/);
    assert.throws(() => previewFile(cwd, "escape"), /path_forbidden/);
    assert.throws(() => listFiles(cwd, "inside-link"), /path_forbidden/);
    assert.throws(() => previewFile(cwd, "binary"), /not_text_file/);
    assert.throws(() => previewFile(cwd, "large"), /file_too_large/);
    // 电脑→手机方向：二进制原样下发，路径限制与文本接口一致。
    assert.deepEqual(await buffer(openWorkspaceDownload(cwd, "binary").stream), Buffer.from([0xff, 0x00]));
    const large = openWorkspaceDownload(cwd, "large");
    assert.equal(large.size, maxTextBytes + 1);
    assert.equal((await buffer(large.stream)).length, large.size);
    assert.throws(() => openWorkspaceDownload(cwd, "huge"), /file_too_large/);
    assert.throws(() => openWorkspaceDownload(cwd, "escape"), /path_forbidden/);
    assert.throws(() => openWorkspaceDownload(cwd, "../outside.txt"), /invalid_path/);
    assert.throws(() => openWorkspaceDownload(cwd, join(root, "outside.txt")), /invalid_path/);
    assert.throws(() => openWorkspaceDownload(cwd, ""), /not_file/);
    await writeFile(join(cwd, "note.txt"), "desktop edit");
    assert.throws(() => saveFile(cwd, "note.txt", "phone edit", before.version), /file_conflict/);
    assert.equal(await readFile(join(cwd, "note.txt"), "utf8"), "desktop edit");
    const current = previewFile(cwd, "note.txt");
    const saved = saveFile(cwd, "note.txt", "phone edit", current.version);
    assert.equal(saved.version, previewFile(cwd, "note.txt").version);
    assert.equal(await readFile(join(cwd, "note.txt"), "utf8"), "phone edit");
    assert.equal((await stat(join(cwd, "note.txt"))).mode & 0o777, 0o640);
    await link(join(cwd, "note.txt"), join(cwd, "hardlink"));
    assert.throws(() => saveFile(cwd, "hardlink", "x", saved.version), /path_forbidden/);
    assert.equal(listFiles(cwd).entries.find((row) => row.name === "escape").kind, "blocked");
    await Promise.all(Array.from({ length: 110 }, (_, i) => writeFile(join(cwd, `page-${i}`), "")));
    const first = listFiles(cwd);
    const second = listFiles(cwd, "", first.nextCursor);
    assert.equal(first.entries.length, 100);
    assert.equal(first.entries.length + second.entries.length, first.total);
    assert.equal(second.nextCursor, undefined);
    assert.ok(!listFiles(cwd).entries.some((row) => row.name.startsWith('.pigo-')));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("session presentation metadata persists separately and rejects stale revisions", async () => {
  const directory = await mkdtemp(join(tmpdir(), "pigo-meta-"));
  try {
    const store = new SessionMetadata(18977, directory);
    const row = { id: "native-id", cwd: "/project/one" };
    assert.equal(store.get(row).revision, 0);
    const pinned = store.update(row, { pinned: true }, 0);
    assert.equal(pinned.revision, 1);
    assert.throws(() => store.update(row, { archived: true }, 0), /metadata_conflict/);
    const restarted = new SessionMetadata(18977, directory);
    assert.equal(restarted.get(row).pinned, true);
    assert.equal(restarted.get({ ...row, cwd: "/project/two" }).pinned, false);
    restarted.visit(row);
    const archived = restarted.update(row, { archived: true }, 2);
    assert.equal(archived.pinned, true);
    assert.ok(archived.lastVisited);
    assert.equal((await stat(restarted.file(row))).mode & 0o777, 0o600);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("prompt images require bounded JPEG dimensions and canonical base64", async () => {
  const image = (await readFile(join(project, "test/prompt-image.base64"), "utf8")).trim();
  assert.equal(validPromptImage(image), true);
  assert.equal(validPromptImage(image + "\n"), false);
  const enlarged = Buffer.from(image, "base64");
  const frame = enlarged.indexOf(Buffer.from([0xff, 0xc0]));
  assert.ok(frame > 0);
  enlarged.writeUInt16BE(1281, frame + 7);
  assert.equal(validPromptImage(enlarged.toString("base64")), false);
  assert.equal(validPromptImage(Buffer.from(image, "base64").subarray(0, -2).toString("base64")), false);
});

test("staged attachments are content-addressed, sanitized, and pruned when stale", async () => {
  const root = await mkdtemp(join(tmpdir(), "pigo-attach-"));
  try {
    const bytes = Buffer.from("手机附件内容");
    const staged = stageAttachment(root, "../../说明 v2.txt", bytes);
    assert.match(staged.token, /^[a-f0-9]{16}$/);
    assert.equal(staged.name, "说明 v2.txt");
    assert.equal(staged.path, join(stagingDir(root), `${staged.token}-说明 v2.txt`));
    assert.equal(await readFile(staged.path, "utf8"), "手机附件内容");
    assert.equal((await stat(staged.path)).mode & 0o777, 0o600);
    const repeat = stageAttachment(root, "说明 v2.txt", bytes);
    assert.equal(repeat.token, staged.token);
    assert.equal(repeat.path, staged.path);
    const renamed = stageAttachment(root, "renamed.bin", bytes);
    assert.equal(renamed.token, staged.token);
    assert.equal(renamed.path, join(stagingDir(root), `${staged.token}-renamed.bin`));
    const other = stageAttachment(root, "other.txt", Buffer.from("other"));
    assert.notEqual(other.token, staged.token);
    assert.equal(stagedAttachment(root, "not-a-token"), undefined);
    assert.equal(stagedAttachment(root, other.token).name, "other.txt");
    assert.equal(stagedAttachment(root, other.token).size, 5);
    // 同一 token 的多个名字按字典序确定性解析。
    assert.equal(stagedAttachment(root, staged.token).name, "renamed.bin");
    assert.throws(() => stageAttachment(root, "big.bin", Buffer.alloc(maxFileBytes + 1, 65)), /invalid_attachment/);
    assert.throws(() => stageAttachment(root, "", Buffer.from("x")), /invalid_attachment/);
    assert.throws(() => stageAttachment(root, "empty", Buffer.alloc(0)), /invalid_attachment/);
    const stale = stageAttachment(root, "stale.txt", Buffer.from("old"));
    const expired = new Date(Date.now() - 16 * 24 * 60 * 60 * 1000);
    await utimes(stale.path, expired, expired);
    stageAttachment(root, "fresh.txt", Buffer.from("new"));
    await assert.rejects(stat(stale.path), { code: "ENOENT" });
    assert.equal(await readFile(join(stagingDir(root), `${stageAttachment(root, "fresh.txt", Buffer.from("new")).token}-fresh.txt`), "utf8"), "new");
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("HTTPS LAN pairing checks identity, Host, ticket and revocation", { skip: !lanHost, timeout: 12000 }, async (context) => {
  const ipc = await mkdtemp(join(tmpdir(), "pigo-lan-"));
  const reservation = createServer().listen(0, lanHost);
  await once(reservation, "listening");
  const { port } = reservation.address();
  await promisify(reservation.close.bind(reservation))();
  const admin = join(ipc, `bridge-${port}.sock`);
  const bridge = spawn(process.execPath, [join(project, "desktop/broker.mjs"), String(port), lanHost],
    { env: { ...process.env, PIGO_IPC_DIR: ipc }, stdio: "inherit" });
  const exit = once(bridge, "exit");
  context.after(async () => {
    await localRequest(admin, "POST", "/stop").catch(() => bridge.kill());
    await exit;
    await rm(ipc, { force: true, recursive: true });
  });
  let issued;
  for (let attempt = 0; attempt < 60 && !issued; attempt += 1) {
    issued = await localRequest(admin, "POST", "/ticket-lan", { host: lanHost }).catch(() => undefined);
    if (!issued) await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.equal(issued?.status, 200);
  assert.equal((await localRequest(admin, "POST", "/ticket")).status, 409);
  assert.equal((await stat(issued.data.file)).mode & 0o777, 0o600);
  const { bundle } = JSON.parse(await readFile(issued.data.file, "utf8"));
  const { url, ticket, ca, pin } = JSON.parse(Buffer.from(bundle, "base64url"));
  assert.equal(url, `https://${lanHost}:${port}`);
  const pinOf = (raw) => createHash("sha256").update(new X509Certificate(raw).publicKey.export({ type: "spki", format: "der" })).digest("base64");
  const request = (route, { trust = ca, expected = pin, headers, body } = {}) => new Promise((resolve, reject) => {
    const connection = httpsRequest(url + route, {
      agent: false, ca: trust, rejectUnauthorized: true, method: body ? "POST" : "GET",
      headers: { "content-type": "application/json", ...headers },
      checkServerIdentity: (_name, cert) => checkServerIdentity(lanHost, cert) ??
        (pinOf(cert.raw) !== expected ? new Error("pin mismatch") : undefined),
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks)) }));
    });
    connection.on("error", reject);
    connection.end(body ? JSON.stringify(body) : undefined);
  });
  await assert.rejects(request("/health", { expected: "not-the-pin" }), /pin mismatch/);
  await assert.rejects(request("/health", { trust: null }), /self.signed/);
  assert.equal((await request("/health", { headers: { host: "localhost" } })).status, 403);
  assert.equal((await request("/health", { headers: { origin: "https://example.invalid" } })).status, 403);
  assert.equal((await request("/pair", { body: { ticket: "12345678" } })).status, 401);
  assert.equal((await request("/session")).status, 401);
  const paired = await request("/pair", { body: { ticket } });
  assert.equal(paired.status, 200);
  assert.equal((await request("/pair", { body: { ticket } })).status, 401);
  const headers = { authorization: `Bearer ${paired.body.token}` };
  assert.equal((await request("/session", { headers })).status, 200);
  assert.equal((await localRequest(admin, "POST", "/revoke-device")).status, 200);
  assert.equal((await request("/session", { headers })).status, 401);
});

test("UDP discovery returns only a nonce-matched LAN address hint", { skip: !lanHost }, async () => {
  const reservation = createSocket("udp4");
  reservation.bind(0, "0.0.0.0");
  await once(reservation, "listening");
  const udpPort = reservation.address().port;
  await promisify(reservation.close.bind(reservation))();
  const stop = startDiscovery(lanHost, 18981, udpPort);
  const udp = createSocket("udp4");
  try {
    udp.bind(0, lanHost);
    await once(udp, "listening");
    const nonce = "a".repeat(32);
    const received = once(udp, "message", { signal: AbortSignal.timeout(2000) });
    udp.send(`PIGO-DISCOVER/1 ${nonce}`.padEnd(96, " "), udpPort, lanHost);
    const [packet, peer] = await received;
    assert.equal(peer.port, udpPort);
    assert.equal(peer.address, lanHost);
    assert.equal(packet.toString(), `PIGO-HERE/1 ${nonce} ${lanHost} 18981`);
    assert.ok(packet.length <= 96);
  } finally { udp.close(); stop(); }
});

test("shared bridge /events forwards worker frames, follows selection and ends on revocation", { timeout: 20000 }, async (context) => {
  const ipc = await mkdtemp(join(tmpdir(), "pigo-events-"));
  const workers = [];
  const spawnWorker = async (id, cwd) => {
    const clients = new Set();
    const cursor = { sessionId: id, streamId: `stream-${id}`, runId: null, seq: 0 };
    let historyRequested;
    let releaseHistory;
    const historyWaiting = new Promise(resolve => { historyRequested = resolve; });
    const holdHistory = new Promise(resolve => { releaseHistory = resolve; });
    const server = createHttpServer((request, response) => {
      const route = `${request.method} ${(request.url ?? "").split("?")[0]}`;
      if (route === "GET /session") {
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ session: { id, cwd, idle: true, queued: false } }));
        return;
      }
      if (route === "GET /history") {
        historyRequested();
        void holdHistory.then(() => {
          response.writeHead(200, { "Content-Type": "application/json" });
          response.end(JSON.stringify({ cursor, session: { id, cwd }, messages: [{ id: "history" }] }));
        });
        return;
      }
      if (route === "GET /session/snapshot") {
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify({ cursor, session: { id, cwd, idle: true, queued: false } }));
        return;
      }
      if (route === "GET /events") {
        const params = new URL(request.url, "http://worker").searchParams;
        if (params.get("sync") === "2") {
          assert.equal(params.get("_pigoSession"), id);
          assert.equal(params.get("_pigoCwd"), cwd);
        }
        response.writeHead(200, { "Content-Type": "text/event-stream" });
        response.write(`data: ${JSON.stringify({ type: "ready", session: { id, cwd, idle: true, queued: false },
          cursor: params.get("sync") === "2" ? cursor : undefined })}\n\n`);
        clients.add(response);
        response.on("close", () => clients.delete(response));
        return;
      }
      response.writeHead(404);
      response.end();
    });
    const socket = join(ipc, `w-${process.pid}-${randomBytes(4).toString("hex")}.sock`);
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(socket, () => { server.off("error", reject); resolve(); });
    });
    const record = {
      server, socket, id, cwd, clients, historyWaiting, releaseHistory, cursor,
      emit: (data) => {
        const frame = `data: ${JSON.stringify({ sessionId: id, ...data })}\n\n`;
        for (const client of clients) client.write(frame);
      },
    };
    workers.push(record);
    return record;
  };
  const port = 18990;
  const admin = join(ipc, `bridge-${port}.sock`);
  const bridge = spawn(process.execPath, [join(project, "desktop/broker.mjs"), String(port)],
    { env: { ...process.env, PIGO_IPC_DIR: ipc }, stdio: "ignore" });
  const exit = once(bridge, "exit");
  context.after(async () => {
    await localRequest(admin, "POST", "/stop").catch(() => bridge.kill());
    await exit;
    for (const worker of workers) worker.server.close();
    await rm(ipc, { force: true, recursive: true });
  });
  let issued;
  for (let attempt = 0; attempt < 80 && !issued; attempt += 1) {
    issued = await localRequest(admin, "POST", "/ticket").catch(() => undefined);
    if (!issued) await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.equal(issued.status, 200);
  const { url, ticket } = JSON.parse(await readFile(issued.data.file, "utf8"));
  assert.match(url, /^http:\/\/127\.0\.0\.1:18990$/);
  const alpha = await spawnWorker("session-alpha", join(ipc, "project-a"));
  assert.equal((await fetch(`${url}/events`, { signal: AbortSignal.timeout(2000) })).status, 401);
  const paired = await fetch(`${url}/pair`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ticket }),
    signal: AbortSignal.timeout(2000),
  });
  assert.equal(paired.status, 200);
  const { token } = await paired.json();
  const headers = { authorization: `Bearer ${token}` };
  const post = (route, data) => fetch(`${url}${route}`, {
    method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(data),
    signal: AbortSignal.timeout(4000),
  });
  const feed = events(await fetch(`${url}/events`, { headers }));
  const ready = await feed.next();
  assert.equal(ready.value.type, "ready");
  assert.equal(ready.value.session.id, "session-alpha");
  alpha.emit({ type: "message/delta", text: "hello", seq: 1 });
  const delta = await feed.next();
  assert.equal(delta.value.text, "hello");
  assert.equal(delta.value.seq, 1);
  alpha.emit({ type: "tool/start", tool: { id: "t1", name: "bash", detail: "npm test", state: "run" } });
  assert.equal((await feed.next()).value.tool.name, "bash");
  const sequenced = events(await fetch(`${url}/events?sync=2`, { headers, signal: AbortSignal.timeout(5000) }));
  assert.deepEqual((await sequenced.next()).value.cursor, alpha.cursor);
  const oldHistory = fetch(`${url}/history?id=session-alpha`, { headers, signal: AbortSignal.timeout(5000) });
  await alpha.historyWaiting;
  const beta = await spawnWorker("session-beta", join(ipc, "project-b"));
  assert.equal((await post("/open", { id: "session-beta" })).status, 200);
  alpha.releaseHistory();
  assert.equal((await oldHistory).status, 409);
  assert.equal((await sequenced.next()).done, true);
  const next = events(await fetch(`${url}/events?sync=2`, { headers, signal: AbortSignal.timeout(5000) }));
  assert.deepEqual((await next.next()).value.cursor, beta.cursor);
  const state = await (await fetch(`${url}/session/snapshot`, { headers })).json();
  assert.deepEqual(state.cursor, beta.cursor);
  assert.equal(state.messages, undefined);
  await next.return();
  const switched = await feed.next();
  assert.equal(switched.value.type, "ready");
  assert.equal(switched.value.session.id, "session-beta");
  beta.emit({ type: "tool/end", tool: { id: "t1", name: "bash", state: "ok", ms: 12 } });
  assert.equal((await feed.next()).value.tool.state, "ok");
  for (const client of beta.clients) client.end();
  const reconnected = await feed.next();
  assert.equal(reconnected.value.type, "ready");
  assert.equal(reconnected.value.session.id, "session-beta");
  assert.equal((await localRequest(admin, "POST", "/revoke-device")).status, 200);
  assert.equal((await feed.next()).done, true);
  await feed.return();
});

function start(agentDir, cwd, env = {}, tools = false, skills = false) {
  const child = spawn(pi, ["--offline", "--mode", "rpc", ...(tools ? [] : ["--no-tools"]),
    "--no-mcp", "--no-approve", ...(skills ? [] : ["--no-skills"]), "--no-context-files", "-e", provider,
    "--provider", "pi-go-test", "--model", "fixture"], { cwd, env: { ...process.env, ...env, PI_CODING_AGENT_DIR: agentDir } });
  const exit = once(child, "exit");
  const messages = [];
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  createInterface({ input: child.stdout }).on("line", (line) => { messages.push(JSON.parse(line)); });
  let sequence = 0;
  const wait = async (predicate, since = 0) => {
    for (let attempt = 0; attempt < 250; attempt++) {
      const found = messages.slice(since).find(predicate);
      if (found) return found;
      if (child.exitCode !== null) break;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`Pi RPC event missing: ${stderr}\n${JSON.stringify(messages.slice(-8))}`);
  };
  const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
  const rpc = async (type, data = {}) => {
    const id = `test-${++sequence}`;
    send({ type, id, ...data });
    const response = await wait((event) => event.type === "response" && event.id === id);
    assert.equal(response.success, true, JSON.stringify(response));
    return response.data;
  };
  return { exit, child, rpc, wait, send, messages };
}

async function pair(runtime, useCode = false, command = "/pi-go") {
  const since = runtime.messages.length;
  await runtime.rpc("prompt", { message: command });
  const notification = await runtime.wait((event) => event.method === "notify" && event.message.startsWith("Pi Go ticket file: "), since);
  const path = notification.message.slice("Pi Go ticket file: ".length);
  assert.equal((await stat(path)).mode & 0o777, 0o600);
  const { url, ticket, code } = JSON.parse(await readFile(path, "utf8"));
  assert.match(code, /^\d{8}$/);
  const request = (route, options) => fetch(`${url}${route}`, { signal: AbortSignal.timeout(5000), ...options });
  const post = (route, data, headers = {}) => request(route, {
    method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(data),
  });
  assert.equal((await request("/sessions")).status, 401);
  assert.equal((await request("/sessions", { headers: { origin: "http://example.invalid" } })).status, 403);
  const response = await post("/pair", { ticket: useCode ? code : ticket });
  assert.equal(response.status, 200);
  const { token } = await response.json();
  assert.equal((await post("/pair", { ticket })).status, 401);
  assert.equal((await post("/pair", { ticket: code })).status, 401);
  await assert.rejects(stat(path), { code: "ENOENT" });
  const headers = { authorization: `Bearer ${token}` };
  const upload = (kind, name, bytes) => request(`/upload?kind=${encodeURIComponent(kind)}&name=${encodeURIComponent(name)}`, {
    method: "POST", headers: { "content-type": "application/octet-stream", ...headers }, body: bytes,
  });
  return { url, get: (route) => request(route, { headers }), post: (route, data) => post(route, data, headers), upload };
}

async function* events(response) {
  assert.equal(response.status, 200);
  let buffer = "";
  for await (const chunk of response.body.pipeThrough(new TextDecoderStream())) {
    buffer += chunk;
    let boundary;
    while ((boundary = buffer.indexOf("\n\n")) >= 0) {
      const block = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      const data = block.split("\n").filter((line) => line.startsWith("data: ")).map((line) => line.slice(6)).join("");
      if (data) yield JSON.parse(data);
    }
  }
}

test("phase 0 against Pi 1.4.0 RPC, using an offline provider and disposable projects", { timeout: 30000 }, async (context) => {
  const root = await mkdtemp(join(tmpdir(), "pi-go-test-"));
  const agent = join(root, "agent");
  const first = join(root, "first");
  const second = join(root, "second");
  await Promise.all([agent, first, second].map((directory) => mkdir(directory)));
  const runtimes = [];
  const run = (cwd, tools = false) => {
    const runtime = start(agent, cwd, { PIGO_ALLOW_RPC_SWITCH: "1" }, tools);
    runtimes.push(runtime);
    return runtime;
  };
  context.after(async () => {
    for (const runtime of runtimes) runtime.child.stdin.end();
    const fallback = setTimeout(() => { for (const runtime of runtimes) runtime.child.kill(); }, 1500);
    await Promise.allSettled(runtimes.map(({ exit }) => exit));
    clearTimeout(fallback);
    await rm(root, { force: true, recursive: true });
  });
  const runPi = promisify(execFile);
  const options = { cwd: first, env: { ...process.env, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1" } };
  assert.equal((await runPi(pi, ["--version"], options)).stdout.trim(), "1.4.0");
  await runPi(pi, ["install", project], options);
  const persist = async (runtime, message) => {
    const since = runtime.messages.length;
    await runtime.rpc("prompt", { message });
    await runtime.wait((event) => event.type === "agent_settled", since);
    return runtime.rpc("get_state");
  };

  const desktop = run(first, true);
  const historic = await persist(desktop, "Create a disposable historical session.");
  await desktop.rpc("new_session");
  const current = await persist(desktop, "Create a second disposable session.");
  const other = run(second);
  const unrelated = await persist(other, "Create a different project's session.");
  const [bridge, otherBridge] = await Promise.all([pair(desktop, true), pair(other)]);
  assert.notEqual(bridge.url, otherBridge.url);
  const listed = await (await bridge.get("/sessions")).json();
  assert.deepEqual(new Set(listed.sessions.map(({ id }) => id)), new Set([historic.sessionId, current.sessionId]));
  assert.equal((await bridge.post("/open", { id: unrelated.sessionId })).status, 404);
  const paged = await (await bridge.get("/sessions?limit=1")).json();
  assert.equal(paged.total, 2);
  assert.equal(paged.sessions.length, 1);
  assert.equal(paged.nextCursor, 1);
  assert.equal((await (await bridge.get(`/sessions?limit=1&cursor=${paged.nextCursor}`)).json()).nextCursor, undefined);

  assert.equal((await (await bridge.get("/sessions?query=nothing-here")).json()).total, 0);
  const readFrame = async (stream, label) => {
    try { return await stream.next(); }
    catch (error) {
      throw new Error(`Could not read ${label} from the Pi event stream`, { cause: error });
    }
  };
  const feed = events(await bridge.get("/events"));
  assert.equal((await readFrame(feed, "feed")).value.type, "ready");
  const opened = await bridge.post("/open", { id: historic.sessionId });
  assert.equal(opened.status, 200, await opened.clone().text());
  assert.equal((await desktop.rpc("get_state")).sessionId, historic.sessionId);
  assert.equal((await readFrame(feed, "feed")).value.session.id, historic.sessionId);
  const syncFeed = events(await bridge.get("/events?sync=2"));
  const syncReady = (await readFrame(syncFeed, "syncFeed")).value;
  assert.equal(syncReady.cursor.sessionId, historic.sessionId);
  assert.equal(syncReady.cursor.runId, null);
  const since = desktop.messages.length;
  const input = { id: historic.sessionId, requestId: "offline-turn", text: "Continue the historical session." };
  assert.equal((await bridge.post("/prompt", input)).status, 202);
  assert.equal((await bridge.post("/prompt", input)).status, 409);
  // 运行开始即携带 runId/queued，手机立即可引导。
  const started = (await readFrame(feed, "feed")).value;
  assert.equal(started.idle, false);
  assert.match(started.runId ?? "", /^[a-f0-9]{32}$/);
  assert.equal(started.queued, false);
  assert.equal((await readFrame(feed, "feed")).value.text, "fixture delta");
  const syncStarted = (await readFrame(syncFeed, "syncFeed")).value.cursor;
  const syncDelta = (await readFrame(syncFeed, "syncFeed")).value.cursor;
  assert.equal(syncStarted.seq, syncReady.cursor.seq + 1);
  assert.equal(syncStarted.runId, started.runId);
  assert.deepEqual(syncDelta, { ...syncStarted, seq: syncStarted.seq + 1 });
  const liveSnapshot = await (await bridge.get("/session/snapshot")).json();
  assert.deepEqual(liveSnapshot.cursor, syncDelta);
  assert.equal(liveSnapshot.liveText, "fixture delta");
  assert.equal(liveSnapshot.messages, undefined);
  await syncFeed.return();
  const recoveredFeed = events(await bridge.get("/events?sync=2"));
  assert.deepEqual((await readFrame(recoveredFeed, "recoveredFeed")).value.cursor, liveSnapshot.cursor);
  const recentHistory = await (await bridge.get(`/history?id=${historic.sessionId}&sync=2`)).json();
  assert.equal(recentHistory.historyLeaf, liveSnapshot.historyLeaf);
  assert.ok(recentHistory.messages.some(message => message.text === input.text));
  assert.equal(recentHistory.liveText, undefined);
  const streaming = await (await bridge.get("/chat")).json();
  assert.equal(streaming.session.id, historic.sessionId);
  assert.equal(streaming.session.idle, false);
  assert.equal(streaming.liveText, "fixture delta");
  assert.equal((await bridge.post("/abort", { id: historic.sessionId })).status, 202);
  assert.equal((await readFrame(feed, "feed")).value.reason, "aborted");
  await desktop.wait((event) => event.type === "agent_settled", since);
  const { messages } = await desktop.rpc("get_messages");
  assert.ok(messages.some((message) => message.role === "user" && JSON.stringify(message.content).includes(input.text)));
  const finalFrame = (await readFrame(recoveredFeed, "recoveredFeed")).value;
  const settledFrame = (await readFrame(recoveredFeed, "recoveredFeed")).value;
  assert.equal(finalFrame.type, "message/final");
  assert.equal(settledFrame.type, "session/status");
  assert.equal(settledFrame.cursor.runId, started.runId);
  assert.equal(settledFrame.cursor.seq, finalFrame.cursor.seq + 1);
  const idleSnapshot = await (await bridge.get("/session/snapshot")).json();
  assert.deepEqual(idleSnapshot.cursor, { ...settledFrame.cursor, runId: null });
  await recoveredFeed.return();
  const snapshot = await (await bridge.get("/chat")).json();
  assert.equal(snapshot.session.idle, true);
  assert.equal(snapshot.liveText, "");
  assert.ok(snapshot.messages.some((message) => message.role === "user" && message.text === input.text));

  const nextType = async (type) => {
    for (;;) {
      const next = await readFrame(feed, "feed");
      if (next.done) throw new Error(`event stream ended before ${type}`);
      if (next.value.type === type) return next.value;
    }
  };
  const toolSince = desktop.messages.length;
  const toolInput = { id: historic.sessionId, requestId: "offline-tool-turn", text: "Pi Go fixture: check native tool approval" };
  assert.equal((await bridge.post("/prompt", toolInput)).status, 202);
  const toolStart = await nextType("tool/start");
  assert.equal(toolStart.sessionId, historic.sessionId);
  assert.equal(toolStart.tool.name, "bash");
  assert.match(toolStart.tool.detail, /printf/);
  const toolEnd = await nextType("tool/end");
  assert.equal(toolEnd.tool.state, "ok");
  const runningTools = await (await bridge.get("/chat")).json();
  assert.ok(Array.isArray(runningTools.tools) && runningTools.tools.some((tool) => tool.id === toolStart.tool.id),
    JSON.stringify(runningTools.tools));
  const detailUrl = `/tool-detail?id=${historic.sessionId}&tool=${toolStart.tool.id}`;
  const liveDetails = (await (await bridge.get(detailUrl)).json()).toolDetail;
  assert.equal(liveDetails.command, true);
  assert.match(liveDetails.input, /result\.txt\nprintf pi-go-output/);
  assert.equal(liveDetails.output.trim(), "pi-go-output");
  assert.equal(liveDetails.state, "ok");
  await desktop.wait((event) => event.type === "agent_settled", toolSince);
  assert.equal((await nextType("session/status")).idle, true);
  const settledChat = await (await bridge.get("/chat")).json();
  assert.deepEqual(settledChat.tools, []);
  assert.equal(settledChat.liveSeq, 0);
  assert.ok(settledChat.messages.some((message) => message.role === "assistant" && message.text === "fixture delta"));
  const savedCall = settledChat.messages.find((message) => message.tools?.some((tool) => tool.id === toolStart.tool.id));
  const savedIndex = settledChat.messages.indexOf(savedCall);
  assert.equal(savedCall?.tools[0].state, "ok");
  assert.equal(settledChat.messages[savedIndex + 1].text, "fixture delta");
  const history = await (await bridge.get(`/history?id=${historic.sessionId}&before=${settledChat.messages[savedIndex + 1].id}&limit=1`)).json();
  assert.deepEqual(history.messages, [savedCall]);
  assert.deepEqual((await (await bridge.get(`${detailUrl}&message=${savedCall.id}`)).json()).toolDetail, liveDetails);
  assert.equal((await bridge.get(`${detailUrl}&message=unknown`)).status, 404);
  assert.equal((await bridge.get(`/tool-detail?id=${current.sessionId}&tool=${toolStart.tool.id}`)).status, 409);

  const modelSwitch = await bridge.post("/model", { id: historic.sessionId, provider: "pi-go-test", modelId: "reasoning-0" });
  assert.equal(modelSwitch.status, 200, await modelSwitch.clone().text());
  const thinkSince = desktop.messages.length;
  const thinkInput = { id: historic.sessionId, requestId: "offline-thinking", text: "Reasoning fixture turn." };
  assert.equal((await bridge.post("/prompt", thinkInput)).status, 202);
  const firstThinking = await nextType("message/thinking");
  assert.equal(firstThinking.text, "fixture thinking ");
  assert.equal(typeof firstThinking.seq, "number");
  const secondThinking = await nextType("message/thinking");
  assert.equal(secondThinking.text, "before answering");
  assert.ok(secondThinking.seq > firstThinking.seq);
  const streamingThinking = await (await bridge.get("/chat")).json();
  assert.equal(streamingThinking.liveThinking, "fixture thinking before answering");
  assert.equal(streamingThinking.liveThinkSeq, secondThinking.seq);
  await desktop.wait((event) => event.type === "agent_settled", thinkSince);
  assert.equal((await nextType("session/status")).idle, true);
  const thoughtChat = await (await bridge.get("/chat")).json();
  const thought = thoughtChat.messages.find((message) => message.thinking);
  assert.ok(thought, JSON.stringify(thoughtChat.messages.map(({ role }) => role)));
  assert.equal(thought.thinking, "fixture thinking before answering");
  assert.equal(thought.role, "assistant");
  assert.ok(typeof thought.thinkingMs === "number");
  assert.ok(thoughtChat.messages.some((message) => message.role === "assistant" && message.text === "fixture delta" && message.thinking));
  assert.equal((await bridge.post("/model", { id: historic.sessionId, provider: "pi-go-test", modelId: "fixture", thinkingLevel: "off" })).status, 200);
  assert.equal((await bridge.post("/open", { id: current.sessionId })).status, 200);

  const uiSince = desktop.messages.length;
  const uiCommand = desktop.rpc("prompt", { message: "/pi-go-check-ui" });
  const dialog = await desktop.wait((event) => event.method === "confirm", uiSince);
  desktop.send({ type: "extension_ui_response", id: dialog.id, confirmed: true });
  await uiCommand;
  await desktop.wait((event) => event.method === "notify" && event.message === "Pi Go UI confirmed", uiSince);
  await feed.return();

  desktop.child.stdin.end();
  assert.equal((await desktop.exit)[0], 0);
  await assert.rejects(bridge.get("/session"), TypeError);
  assert.equal((await otherBridge.get("/session")).status, 200);
  const restarted = run(first);
  await restarted.rpc("switch_session", { sessionPath: historic.sessionFile });
  assert.equal((await restarted.rpc("get_state")).sessionId, historic.sessionId);
  const restartedBridge = await pair(restarted);
  await restarted.rpc("prompt", { message: "/pi-go-stop" });
  await assert.rejects(restartedBridge.get("/session"), TypeError);
});

test("shared bridge selects native runtimes without replacing their sessions", { timeout: 30000 }, async (context) => {
  const root = await mkdtemp(join(tmpdir(), "pigo-"));
  const agent = join(root, "agent");
  const ipc = join(root, "ipc");
  const first = join(root, "first");
  const second = join(root, "second");
  await Promise.all([agent, first, second].map((directory) => mkdir(directory)));
  const server = createServer().listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  await promisify(server.close.bind(server))();
  const runtimes = [];
  context.after(async () => {
    await localRequest(join(ipc, `bridge-${port}.sock`), "POST", "/stop").catch(() => {});
    for (const runtime of runtimes) runtime.child.stdin.end();
    const fallback = setTimeout(() => { for (const runtime of runtimes) runtime.child.kill(); }, 1500);
    await Promise.allSettled(runtimes.map(({ exit }) => exit));
    clearTimeout(fallback);
    await rm(root, { force: true, recursive: true });
  });
  const env = { PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PIGO_IPC_DIR: ipc, PIGO_ALLOW_RPC_SWITCH: "0" };
  await promisify(execFile)(pi, ["install", project], { cwd: first, env: { ...process.env, ...env } });
  const runtimeA = start(agent, first, env);
  const runtimeB = start(agent, second, env, true);
  runtimes.push(runtimeA, runtimeB);
  const [historic, sessionB] = await Promise.all([runtimeA, runtimeB].map(async (runtime) => {
    await runtime.rpc("prompt", { message: "Create a saved fixture." });
    await runtime.wait((event) => event.type === "agent_settled");
    return runtime.rpc("get_state");
  }));
  await runtimeA.rpc("new_session");
  const sessionA = await runtimeA.rpc("get_state");
  const bridge = await pair(runtimeA, true, `/pi-go-bridge ${port}`);
  assert.equal((await (await bridge.get("/session")).json()).session.id, sessionA.sessionId);
  await runtimeB.rpc("prompt", { message: "/pi-go-share" });
  await runtimeB.wait((event) => event.method === "notify" && event.message === "Pi Go session shared");
  const listed = await (await bridge.get("/sessions")).json();
  assert.equal(listed.current.id, sessionA.sessionId);
  assert.deepEqual((await (await bridge.get("/sessions/status")).json()).runningSessionIds, []);
  assert.deepEqual(new Set(listed.sessions.filter(({ active }) => active).map(({ id }) => id)), new Set([sessionA.sessionId, sessionB.sessionId]));
  assert.equal(listed.sessions.find(({ id }) => id === historic.sessionId)?.active, false);
  assert.equal((await bridge.post("/open", { id: historic.sessionId })).status, 409);
  assert.equal((await bridge.post("/open", { id: sessionB.sessionId })).status, 200);
  assert.equal((await runtimeA.rpc("get_state")).sessionId, sessionA.sessionId);
  assert.equal((await runtimeB.rpc("get_state")).sessionId, sessionB.sessionId);
  assert.equal((await bridge.post("/prompt", { id: sessionA.sessionId, requestId: "stale", text: "Wrong session" })).status, 409);
  const since = runtimeB.messages.length;
  const input = { id: sessionB.sessionId, requestId: "shared-route", text: "Continue only in runtime B." };
  assert.equal((await bridge.post("/prompt", input)).status, 202);
  await runtimeB.wait((event) => event.type === "message_update", since);
  // Running status includes background tasks, regardless of the selected chat.
  assert.equal((await bridge.post("/open", { id: sessionA.sessionId })).status, 200);
  const running = await (await bridge.get("/sessions/status")).json();
  assert.deepEqual(running.runningSessionIds, [sessionB.sessionId]);
  assert.deepEqual(running.idleSessionIds, [sessionA.sessionId]);
  assert.equal((await bridge.post("/open", { id: sessionB.sessionId })).status, 200);
  assert.equal((await bridge.post("/abort", { id: sessionB.sessionId })).status, 202);
  await runtimeB.wait((event) => event.type === "agent_settled", since);
  const settled = await (await bridge.get("/sessions/status")).json();
  assert.deepEqual(settled.runningSessionIds, []);
  assert.deepEqual(new Set(settled.idleSessionIds), new Set([sessionA.sessionId, sessionB.sessionId]));
  const [{ messages: messagesA }, { messages: messagesB }] = await Promise.all([runtimeA.rpc("get_messages"), runtimeB.rpc("get_messages")]);
  assert.ok(!JSON.stringify(messagesA).includes(input.text));
  assert.ok(JSON.stringify(messagesB).includes(input.text));
  for (const mode of ["steer", "followUp"]) {
    const turn = runtimeB.messages.length;
    const queue = { id: sessionB.sessionId, mode, text: `Pi Go queue fixture: ${mode}`, requestId: `queue-${mode}` };
    assert.equal((await bridge.post("/prompt", queue)).status, 409);
    await runtimeB.rpc("prompt", { message: `Start a desktop turn for ${mode}.` });
    await runtimeB.wait((event) => event.type === "message_update", turn);
    const running = (await (await bridge.get("/chat")).json()).session;
    assert.match(running.runId, /^[a-f0-9]{32}$/);
    assert.equal((await bridge.post("/prompt", { ...queue, runId: "stale" })).status, 409);
    assert.equal((await bridge.post("/prompt", { ...queue, mode: "send" })).status, 409);
    const queued = { ...queue, runId: running.runId };
    const feed = events(await bridge.get("/events"));
    assert.equal((await feed.next()).value.type, "ready");
    assert.equal((await bridge.post("/prompt", queued)).status, 202);
    await runtimeB.wait((event) => event.method === "notify" && event.message === `Pi Go fixture mode: ${mode}`, turn);
    // 排队状态即时广播：queue/status 帧携带 runId 与 queued，无需等 /chat 轮询。
    for (;;) {
      const next = await feed.next();
      if (next.done) throw new Error("event stream ended before queue/status");
      if (next.value.type === "queue/status") {
        assert.equal(next.value.queued, true);
        assert.equal(next.value.runId, running.runId);
        break;
      }
    }
    const queuedChat = (await (await bridge.get("/chat")).json()).session;
    assert.equal(queuedChat.queued, true);
    assert.equal(queuedChat.runId, running.runId);
    await feed.return();
    // 排队中允许继续追加第二条引导/补充（新 requestId），不再拒收。
    const second = { ...queue, requestId: `queue-${mode}-second`,
      text: `Pi Go extra interjection for ${mode}`, runId: running.runId };
    assert.equal((await bridge.post("/prompt", second)).status, 202);
    assert.equal((await bridge.post("/prompt", queued)).status, 409);
    assert.deepEqual(await (await bridge.post("/receipt", { id: queue.id, requestId: queue.requestId })).json(),
      { dispatched: true, requestId: queue.requestId });
    assert.deepEqual(await (await bridge.post("/receipt", { id: queue.id, requestId: "never-sent" })).json(),
      { dispatched: false, requestId: "never-sent" });
    await runtimeB.wait((event) => event.type === "agent_settled", turn);
    const history = await runtimeB.rpc("get_messages");
    assert.equal(history.messages.filter((message) => message.role === "user" && JSON.stringify(message.content).includes(queue.text)).length, 1);
    assert.equal(history.messages.filter((message) => message.role === "user" && JSON.stringify(message.content).includes(second.text)).length, 1);
  }
  const markdownTurn = runtimeB.messages.length;
  await runtimeB.rpc("prompt", { message: "Pi Go fixture: long Markdown" });
  await runtimeB.wait((event) => event.type === "agent_settled", markdownTurn);
  const markdownChat = await (await bridge.get("/chat")).json();
  const markdown = markdownChat.messages.find(({ text }) => text.startsWith("# 长回复"));
  const completeMarkdown = "# 长回复\n\n```txt\n" + "a".repeat(131057) + "🚀\n```\n\n最后一段";
  assert.ok(markdown, "long Markdown is present in the transcript");
  assert.equal(markdown.textTruncated, true, "the transcript must report when it returns only a preview");
  const textUrl = `/message-text?id=${sessionB.sessionId}&message=${markdown.id}`;
  const firstText = await (await bridge.get(textUrl)).json();
  assert.equal(firstText.nextTextOffset, 131071, "the page does not split the emoji at the boundary");
  const remainingText = await (await bridge.get(`${textUrl}&offset=${firstText.nextTextOffset}`)).json();
  assert.equal(firstText.text + remainingText.text, completeMarkdown);
  assert.equal(remainingText.nextTextOffset, undefined);
  assert.equal((await bridge.get(`${textUrl}&offset=-1`)).status, 400);
  assert.equal((await bridge.get(`/message-text?id=${sessionA.sessionId}&message=${markdown.id}`)).status, 409);
  const image = (await readFile(join(project, "test/prompt-image.base64"), "utf8")).trim();
  const imagePrompt = { id: sessionB.sessionId, text: "", requestId: "image", image };
  assert.equal((await (await bridge.get("/session")).json()).session.acceptsImage, true);
  assert.equal((await bridge.post("/prompt", { ...imagePrompt, id: sessionA.sessionId })).status, 409);
  assert.deepEqual(await (await bridge.post("/prompt", { ...imagePrompt, image: "not-jpeg" })).json(), { error: "invalid_image" });
  assert.equal((await bridge.post("/prompt", { ...imagePrompt, image: "A".repeat(800000) })).status, 413);
  await runtimeB.rpc("set_model", { provider: "pi-go-test", modelId: "text-only" });
  assert.equal((await (await bridge.get("/session")).json()).session.acceptsImage, false);
  assert.deepEqual(await (await bridge.post("/prompt", imagePrompt)).json(), { error: "image_not_supported" });
  await runtimeB.rpc("set_model", { provider: "pi-go-test", modelId: "fixture" });
  const imageTurn = runtimeB.messages.length;
  assert.equal((await bridge.post("/prompt", imagePrompt)).status, 202);
  await runtimeB.wait((event) => event.type === "agent_settled", imageTurn);
  assert.equal((await bridge.post("/prompt", imagePrompt)).status, 409);
  const withImage = await (await bridge.get("/chat")).json();
  const imageMessage = withImage.messages.find((message) => message.imageCount === 1);
  assert.equal(imageMessage?.role, "user");
  const imageUrl = `/message-image?id=${sessionB.sessionId}&message=${imageMessage.id}`;
  const restoredImage = await bridge.get(`${imageUrl}&index=0`);
  assert.equal(restoredImage.status, 200);
  assert.deepEqual((await restoredImage.json()).image, { mimeType: "image/jpeg", data: image });
  assert.equal((await bridge.get(`${imageUrl}&index=1`)).status, 404);
  assert.equal((await bridge.get(`${imageUrl}&index=-1`)).status, 400);
  assert.equal((await bridge.post("/open", { id: sessionA.sessionId })).status, 200);
  assert.equal((await bridge.get(`${imageUrl}&index=0`)).status, 409);
  assert.equal((await bridge.post("/open", { id: sessionB.sessionId })).status, 200);
  assert.ok(withImage.messages.some((message) => message.text === "fixture image received"));
  assert.ok(!JSON.stringify(withImage).includes(image));
  // 附件上传：内容寻址、幂等、落到所选会话工作区后以 token 引用发送。
  const jpeg = Buffer.from(image, "base64");
  await writeFile(join(second, "fixture.jpg"), jpeg);
  const toolImageTurn = runtimeB.messages.length;
  await runtimeB.rpc("prompt", { message: "Pi Go fixture: read image" });
  await runtimeB.wait((event) => event.type === "agent_settled", toolImageTurn);
  const toolChat = await (await bridge.get("/chat")).json();
  const toolMessage = toolChat.messages.find((message) => message.tools?.some((tool) => tool.id === "pi-go-image-call"));
  assert.ok(toolMessage);
  const detailUrl = `id=${sessionB.sessionId}&message=${toolMessage.id}&tool=pi-go-image-call`;
  const imageDetail = (await (await bridge.get(`/tool-detail?${detailUrl}&images=1`)).json()).toolDetail;
  assert.equal(imageDetail.imageCount, 1);
  assert.ok(!imageDetail.output.includes("［图片输出］"));
  const toolImage = await (await bridge.get(`/message-image?${detailUrl}&index=0`)).json();
  assert.equal(toolImage.image.mimeType, "image/jpeg");
  assert.ok(Buffer.from(toolImage.image.data, "base64").length);
  const secondReal = await realpath(second);
  const attachmentsRoot = join(secondReal, ".pi-go", "attachments");
  const uploadedImage = await (await bridge.upload("image", "手机照片.jpg", jpeg)).json();
  assert.match(uploadedImage.attachment.token, /^[a-f0-9]{16}$/);
  assert.ok(uploadedImage.attachment.path.startsWith(attachmentsRoot));
  assert.ok(uploadedImage.attachment.path.endsWith(`${uploadedImage.attachment.token}-手机照片.jpg`));
  assert.ok((await readFile(uploadedImage.attachment.path)).equals(jpeg));
  const reuploaded = await (await bridge.upload("image", "手机照片.jpg", jpeg)).json();
  assert.equal(reuploaded.attachment.token, uploadedImage.attachment.token);
  assert.equal(reuploaded.attachment.path, uploadedImage.attachment.path);
  assert.deepEqual(await (await bridge.upload("image", "bad.jpg", Buffer.from("not-jpeg"))).json(), { error: "invalid_image" });
  assert.deepEqual(await (await bridge.upload("bogus", "bad.txt", Buffer.from("x"))).json(), { error: "invalid_attachment" });
  assert.equal((await bridge.upload("file", "", Buffer.from("x"))).status, 400);
  assert.equal((await bridge.upload("file", "太", Buffer.alloc(maxFileBytes + 1, 65))).status, 413);
  const sneaky = await (await bridge.upload("file", "../../假目录/报告.pdf", Buffer.from("pdf-bytes"))).json();
  assert.equal(sneaky.attachment.name, "假目录报告.pdf");
  assert.ok(sneaky.attachment.path.startsWith(attachmentsRoot));
  const secondJpeg = Buffer.concat([jpeg.subarray(0, 2), Buffer.from([0xff, 0xfe, 0, 3, 65]), jpeg.subarray(2)]);
  const secondImage = (await (await bridge.upload("image", "照片 2.jpg", secondJpeg)).json()).attachment;
  const tokenImagePrompt = { id: sessionB.sessionId, text: "", requestId: "token-image",
    attachments: [{ token: uploadedImage.attachment.token, kind: "image" }, { token: secondImage.token, kind: "image" }] };
  const fileUpload = await (await bridge.upload("file", "说明.txt", Buffer.from("手机附件内容", "utf8"))).json();
  assert.equal((await bridge.post("/prompt", tokenImagePrompt)).status, 202);
  const imageTurn2 = runtimeB.messages.length;
  await runtimeB.wait((event) => event.type === "agent_settled", imageTurn2);
  const tokenImageChat = await (await bridge.get("/chat")).json();
  assert.equal(tokenImageChat.messages.filter((message) => message.imageCount === 2).length, 1);
  assert.equal(tokenImageChat.messages.filter((message) => message.text === "fixture image received").length, 2);
  assert.ok(!JSON.stringify(tokenImageChat).includes(image));
  const multiple = tokenImageChat.messages.find((message) => message.role === "user" && message.imageCount === 2);
  const history = await (await bridge.get(`/history?id=${sessionB.sessionId}&before=${tokenImageChat.messages.at(-1).id}`)).json();
  assert.ok(history.messages.some((message) => message.id === multiple.id));
  assert.equal((await (await bridge.get(`/message-image?id=${sessionB.sessionId}&message=${multiple.id}&index=0`)).json()).image.data, image);
  assert.equal((await (await bridge.get(`/message-image?id=${sessionB.sessionId}&message=${multiple.id}&index=1`)).json()).image.data, secondJpeg.toString("base64"));
  assert.deepEqual(await (await bridge.post("/prompt", { id: sessionB.sessionId, text: "x", requestId: "unknown-token",
    attachments: [{ token: "0123456789abcdef", kind: "file" }] })).json(), { error: "unknown_attachment" });
  assert.deepEqual(await (await bridge.post("/prompt", { id: sessionB.sessionId, text: "x", requestId: "bad-attach",
    attachments: [{ token: "short", kind: "file" }] })).json(), { error: "invalid_attachment" });
  assert.deepEqual(await (await bridge.post("/prompt", { id: sessionB.sessionId, text: "x", requestId: "bad-kind",
    attachments: [{ token: uploadedImage.attachment.token, kind: "movie" }] })).json(), { error: "invalid_attachment" });
  await runtimeB.rpc("set_model", { provider: "pi-go-test", modelId: "text-only" });
  assert.deepEqual(await (await bridge.post("/prompt", { id: sessionB.sessionId, text: "看图", requestId: "token-image-text-only",
    attachments: [{ token: uploadedImage.attachment.token, kind: "image" }] })).json(), { error: "image_not_supported" });
  await runtimeB.rpc("set_model", { provider: "pi-go-test", modelId: "fixture" });
  const fileTurn = runtimeB.messages.length;
  const filePrompt = { id: sessionB.sessionId, text: "", requestId: "file-send",
    attachments: [{ token: fileUpload.attachment.token, kind: "file" }] };
  assert.equal((await bridge.post("/prompt", filePrompt)).status, 202);
  await runtimeB.wait((event) => event.type === "agent_settled", fileTurn);
  const fileChat = await (await bridge.get("/chat")).json();
  assert.ok(fileChat.messages.some((message) => message.role === "user" &&
    message.text.includes("[Pi Go 附件]") && message.text.includes("说明.txt") &&
    message.text.includes(fileUpload.attachment.path)));
  assert.equal(await readFile(fileUpload.attachment.path, "utf8"), "手机附件内容");
  assert.equal((await bridge.get(`/history?id=${sessionA.sessionId}`)).status, 409);
  const latest = await (await bridge.get(`/history?id=${sessionB.sessionId}&limit=1`)).json();
  assert.equal(latest.messages.length, 1);
  assert.ok(latest.historyCursor);
  const earlier = await (await bridge.get(`/history?id=${sessionB.sessionId}&before=${latest.historyCursor}`)).json();
  assert.ok(earlier.messages.length > 0);
  assert.equal(earlier.historyCursor, undefined);
  assert.ok(!earlier.messages.some((row) => row.id === latest.messages[0].id));
  assert.equal((await bridge.get(`/history?id=${sessionB.sessionId}&before=missing`)).status, 409);
  const models = await (await bridge.get("/models")).json();
  assert.equal(models.current.provider, "pi-go-test");
  assert.equal(models.current.id, "fixture");
  assert.equal(models.current.image, true);
  assert.deepEqual(models.models.find((row) => row.id === "fixture").levels, ["off"]);
  assert.deepEqual(models.current.levels, ["off"]);
  assert.ok(models.models.some((row) => row.id === "text-only" && row.image === false));
  assert.ok(models.models.some((row) => row.id === "reasoning-104"), "model picker must include models beyond the first 100");
  const reasoning = await (await bridge.post("/model", { id: sessionB.sessionId, provider: "pi-go-test", modelId: "reasoning-104", thinkingLevel: "high" })).json();
  assert.equal(reasoning.current.id, "reasoning-104");
  assert.equal(reasoning.current.thinkingLevel, "high");
  assert.equal(reasoning.session.thinkingLevel, "high");
  assert.equal((await (await bridge.get("/models")).json()).current.id, "reasoning-104");
  await bridge.post("/model", { id: sessionB.sessionId, provider: "pi-go-test", modelId: "fixture", thinkingLevel: "off" });
  assert.equal((await bridge.post("/model", { id: sessionA.sessionId, provider: "pi-go-test", modelId: "text-only" })).status, 409);
  assert.equal((await bridge.post("/model", { id: sessionB.sessionId, provider: "pi-go-test", modelId: "missing" })).status, 404);
  assert.deepEqual(await (await bridge.post("/model", { id: sessionB.sessionId, provider: "pi-go-test", modelId: "text-only", thinkingLevel: "wild" })).json(), { error: "invalid_thinking_level" });
  const switched = await (await bridge.post("/model", { id: sessionB.sessionId, provider: "pi-go-test", modelId: "text-only", thinkingLevel: "high" })).json();
  assert.equal(switched.current.id, "text-only");
  assert.equal(switched.current.thinkingLevel, "off");
  assert.equal((await (await bridge.get("/session")).json()).session.acceptsImage, false);
  const backToFixture = await (await bridge.post("/model", { id: sessionB.sessionId, provider: "pi-go-test", modelId: "fixture" })).json();
  assert.equal(backToFixture.current.id, "fixture");
  assert.equal(backToFixture.current.thinkingLevel, "off");
  assert.equal((await (await bridge.get("/session")).json()).session.model.id, "fixture");
  const busyTurn = runtimeB.messages.length;
  await runtimeB.rpc("prompt", { message: "Pi Go fixture: long answer" });
  await runtimeB.wait((event) => event.type === "message_update", busyTurn);
  assert.deepEqual(await (await bridge.post("/model", { id: sessionB.sessionId, provider: "pi-go-test", modelId: "text-only" })).json(), { error: "session_busy" });
  assert.equal((await bridge.post("/abort", { id: sessionB.sessionId })).status, 202);
  await runtimeB.wait((event) => event.type === "agent_settled", busyTurn);
  assert.deepEqual(await (await bridge.post("/rename", { id: sessionB.sessionId, name: " padded " })).json(), { error: "invalid_name" });
  assert.equal((await bridge.post("/rename", { id: sessionA.sessionId, name: "Wrong session" })).status, 409);
  assert.equal((await bridge.post("/rename", { id: sessionB.sessionId, name: "Renamed from the phone" })).status, 200);
  assert.equal((await (await bridge.get("/session")).json()).session.name, "Renamed from the phone");
  const search = await (await bridge.get("/sessions?limit=2")).json();
  assert.equal(search.total, 3);
  assert.equal(search.sessions.length, 2);
  assert.equal(search.nextCursor, 2);
  const exhausted = await (await bridge.get("/sessions?limit=2&cursor=999")).json();
  assert.deepEqual(exhausted.sessions, []);
  assert.equal(exhausted.nextCursor, undefined);
  const fractional = await (await bridge.get("/sessions?limit=1.5")).json();
  assert.equal(fractional.sessions.length, 1);
  assert.equal(fractional.nextCursor, 1);
  const rest = await (await bridge.get("/sessions?limit=2&cursor=2")).json();
  assert.equal(rest.sessions.length, 1);
  assert.equal(rest.nextCursor, undefined);
  assert.equal((await (await bridge.get("/sessions?query=phone")).json()).total, 1);
  assert.equal((await (await bridge.get("/sessions?query=fixture")).json()).total, 1);
  const fileCwd = (await (await bridge.get("/session")).json()).session.cwd;
  await writeFile(join(second, "phone-file.txt"), "desktop baseline");
  assert.equal((await bridge.post("/files/list", { cwd: root, path: "" })).status, 403);
  assert.equal((await bridge.post("/files/read", { cwd: fileCwd, path: "../first" })).status, 400);
  const fileList = await (await bridge.post("/files/list", { cwd: fileCwd, path: "" })).json();
  assert.ok(fileList.entries.some((row) => row.name === "phone-file.txt"));
  const originalFile = await (await bridge.post("/files/read", { cwd: fileCwd, path: "phone-file.txt" })).json();
  assert.equal(originalFile.text, "desktop baseline");
  assert.equal((await bridge.post("/files/save", { cwd: fileCwd, path: "phone-file.txt", version: originalFile.version, text: "phone edit" })).status, 200);
  assert.equal((await bridge.post("/files/save", { cwd: fileCwd, path: "phone-file.txt", version: originalFile.version, text: "stale phone edit" })).status, 409);
  assert.equal(await readFile(join(second, "phone-file.txt"), "utf8"), "phone edit");
  // 电脑→手机：任意文件经 GET /files/download 原样下发，受同样的工作区范围限制。
  const report = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
  await writeFile(join(second, "report.pdf"), report);
  const download = await bridge.get(`/files/download?cwd=${encodeURIComponent(fileCwd)}&path=${encodeURIComponent("report.pdf")}`);
  assert.equal(download.status, 200);
  assert.equal(download.headers.get("content-type"), "application/octet-stream");
  assert.equal(Number(download.headers.get("content-length")), report.length);
  assert.deepEqual(Buffer.from(await download.arrayBuffer()), report);
  const largeName = "项目 报告.bin";
  const largeDownload = () => bridge.get(`/files/download?cwd=${encodeURIComponent(fileCwd)}&path=${encodeURIComponent(largeName)}`);
  await writeFile(join(second, largeName), "");
  const emptyDownload = await largeDownload();
  assert.equal(emptyDownload.status, 200);
  assert.equal(emptyDownload.headers.get("content-length"), "0");
  assert.equal((await emptyDownload.arrayBuffer()).byteLength, 0);
  await truncate(join(second, largeName), maxDownloadBytes);
  const largest = await largeDownload();
  assert.equal(largest.status, 200);
  assert.equal(Number(largest.headers.get("content-length")), maxDownloadBytes);
  let downloadedBytes = 0;
  for await (const chunk of largest.body) downloadedBytes += chunk.byteLength;
  assert.equal(downloadedBytes, maxDownloadBytes);
  await truncate(join(second, largeName), maxDownloadBytes + 1);
  const oversized = await largeDownload();
  assert.equal(oversized.status, 413);
  assert.deepEqual(await oversized.json(), { error: "file_too_large" });
  assert.equal((await bridge.get(`/files/download?cwd=${encodeURIComponent(fileCwd)}&path=${encodeURIComponent("../first")}`)).status, 400);
  assert.equal((await bridge.get(`/files/download?cwd=${encodeURIComponent(fileCwd)}&path=${encodeURIComponent("missing.png")}`)).status, 404);
  assert.equal((await bridge.get(`/files/download?cwd=${encodeURIComponent(fileCwd)}&path=`)).status, 400);
  assert.equal((await bridge.get(`/files/download?cwd=${encodeURIComponent(root)}&path=${encodeURIComponent("first.txt")}`)).status, 403);
  await mkdir(join(second, "exports"));
  await mkdir(join(second, "archive"));
  await writeFile(join(second, "exports", "nested.pdf"), report);
  const namedDownload = (path, lookup = false) =>
    bridge.get(`/files/download?cwd=${encodeURIComponent(fileCwd)}&path=${encodeURIComponent(path)}${lookup ? "&lookup=name" : ""}`);
  assert.equal((await namedDownload("nested.pdf")).status, 404);
  const nested = await namedDownload("nested.pdf", true);
  assert.equal(nested.status, 200);
  assert.deepEqual(Buffer.from(await nested.arrayBuffer()), report);
  await symlink(join(second, "exports"), join(second, "archive", "symlink"));
  assert.equal((await namedDownload("nested.pdf", true)).status, 200);
  await writeFile(join(second, "archive", "nested.pdf"), "different file");
  const ambiguous = await namedDownload("nested.pdf", true);
  assert.equal(ambiguous.status, 409);
  assert.deepEqual(await ambiguous.json(), { error: "ambiguous_file_name" });
  assert.equal((await namedDownload("exports/nested.pdf", true)).status, 200);
  await writeFile(join(second, "exports", "editable.md"), "# Draft");
  const namedRead = () => bridge.post("/files/read", { cwd: fileCwd, path: "editable.md", lookup: "name" });
  const editable = await (await namedRead()).json();
  assert.equal(editable.path, "exports/editable.md");
  assert.equal(editable.text, "# Draft");
  await writeFile(join(second, "editable.md"), "# Root");
  assert.equal((await (await namedRead()).json()).path, "editable.md");
  assert.equal((await bridge.post("/files/save", { cwd: fileCwd, path: editable.path, version: editable.version, text: "# Edited" })).status, 200);
  assert.equal(await readFile(join(second, "exports", "editable.md"), "utf8"), "# Edited");
  assert.equal(await readFile(join(second, "editable.md"), "utf8"), "# Root");
  await rm(join(second, "editable.md"));
  await writeFile(join(second, "archive", "editable.md"), "# Archive");
  const ambiguousRead = await namedRead();
  assert.equal(ambiguousRead.status, 409);
  assert.deepEqual(await ambiguousRead.json(), { error: "ambiguous_file_name" });
  const metaRow = (await (await bridge.get("/sessions")).json()).sessions.find((row) => row.id === sessionB.sessionId);
  const metadataInput = { id: metaRow.id, cwd: metaRow.cwd, revision: metaRow.revision, pinned: true };
  assert.equal((await bridge.post("/session-meta", { ...metadataInput, cwd: "/unshared" })).status, 404);
  assert.equal((await bridge.post("/session-meta", { ...metadataInput, pinned: "yes" })).status, 400);
  const pinned = await (await bridge.post("/session-meta", metadataInput)).json();
  assert.equal(pinned.metadata.pinned, true);
  assert.equal((await bridge.post("/session-meta", metadataInput)).status, 409);
  const pinList = await (await bridge.get("/sessions?view=pinned")).json();
  assert.deepEqual(pinList.sessions.map((row) => row.id), [sessionB.sessionId]);
  assert.ok((await (await bridge.get("/sessions?view=recent")).json()).sessions.some((row) => row.id === sessionB.sessionId));
  assert.equal((await bridge.post("/session-meta", { ...metadataInput, revision: pinned.metadata.revision, archived: true })).status, 200);
  assert.ok(!(await (await bridge.get("/sessions")).json()).sessions.some((row) => row.id === sessionB.sessionId));
  const archived = await (await bridge.get("/sessions?view=archived")).json();
  assert.equal(archived.sessions[0].id, sessionB.sessionId);
  assert.equal((await bridge.post("/session-meta", { id: metaRow.id, cwd: metaRow.cwd, revision: archived.sessions[0].revision, archived: false })).status, 200);
  assert.equal((await bridge.get("/sessions?view=invalid")).status, 400);
  const duplicate = start(agent, second, env);
  runtimes.push(duplicate);
  await duplicate.rpc("switch_session", { sessionPath: sessionB.sessionFile });
  await duplicate.rpc("prompt", { message: "/pi-go-share" });
  await duplicate.wait((event) => event.method === "notify" && event.message === "Pi Go session shared");
  const occupied = await (await bridge.get("/sessions")).json();
  assert.equal(occupied.sessions.find(({ id }) => id === sessionB.sessionId)?.occupied, true);
  assert.deepEqual(await (await bridge.post("/open", { id: sessionB.sessionId })).json(), { error: "session_occupied" });
  assert.equal((await bridge.post("/prompt", { ...input, requestId: "occupied" })).status, 409);
  duplicate.child.stdin.end();
  await duplicate.exit;
  runtimeB.child.stdin.end();
  await runtimeB.exit;
  assert.equal((await (await bridge.get("/chat")).json()).state, "session_closed");
  assert.equal((await bridge.post("/prompt", input)).status, 409);
  assert.equal((await bridge.post("/open", { id: sessionA.sessionId })).status, 200);
  const hosted = start(agent, first, env);
  runtimes.push(hosted);
  const calls = [];
  let profile = "a".repeat(64);
  const authorizedProfile = profile;
  const host = createHttpServer(async (request, response) => {
    response.setHeader("content-type", "application/json");
    try {
      if (request.url === "/health") return response.end(JSON.stringify({ protocol: "pi-go-desktop-host/1", profile }));
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (request.url === "/authorize") return response.end(JSON.stringify({ cwd: payload.cwd, profile }));
      if (request.url === "/catalog") return response.end(JSON.stringify({ sessions: [{ id: historic.sessionId }] }));
      calls.push({ route: request.url, ...payload });
      if (request.url === "/open") await hosted.rpc("switch_session", { sessionPath: historic.sessionFile });
      else await hosted.rpc("new_session");
      const beforeShare = hosted.messages.length;
      await hosted.rpc("prompt", { message: "/pi-go-share" });
      await hosted.wait((event) => event.method === "notify" && event.message === "Pi Go session shared", beforeShare);
      const opened = await hosted.rpc("get_state");
      response.end(JSON.stringify({ id: opened.sessionId }));
    } catch {
      response.writeHead(500).end(JSON.stringify({ error: "fixture_failed" }));
    }
  }).listen(join(ipc, "host-42.sock"));
  context.after(() => promisify(host.close.bind(host))());
  await once(host, "listening");
  assert.equal((await (await bridge.get("/sessions")).json()).desktopHandoff, true);
  assert.equal((await bridge.post("/new", { cwd: "/not-shared" })).status, 403);
  const restored = await bridge.post("/open", { id: historic.sessionId, cwd: "/ignored-phone-path" });
  assert.equal(restored.status, 200, await restored.clone().text());
  assert.equal((await restored.json()).session.id, historic.sessionId);
  assert.deepEqual(calls[0], { route: "/open", cwd: listed.current.cwd, id: historic.sessionId });
  const created = await bridge.post("/new", { cwd: listed.current.cwd });
  assert.equal(created.status, 200, await created.clone().text());
  assert.notEqual((await created.json()).session.id, historic.sessionId);
  assert.deepEqual(calls[1], { route: "/new", cwd: listed.current.cwd });
  assert.equal((await runtimeA.rpc("get_state")).sessionId, sessionA.sessionId);
  assert.equal((await bridge.post("/open", { id: sessionA.sessionId })).status, 200);
  await runtimeA.rpc("prompt", { message: `/pi-go-project ${port}` });
  await runtimeA.wait((event) => event.method === "notify" && event.message === "Pi Go project reopening enabled");
  hosted.child.stdin.end();
  await hosted.exit;
  runtimeA.child.stdin.end();
  await runtimeA.exit;
  const empty = await bridge.get("/chat");
  assert.equal(empty.status, 200);
  assert.equal((await empty.json()).state, "session_closed");
  const closedList = await (await bridge.get("/sessions")).json();
  assert.deepEqual(closedList.projects, [listed.current.cwd]);
  assert.equal(closedList.sessions.find(({ id }) => id === historic.sessionId)?.active, false);
  profile = "b".repeat(64);
  assert.deepEqual((await (await bridge.get("/sessions")).json()).projects, []);
  assert.equal((await bridge.post("/open", { id: historic.sessionId })).status, 409);
  profile = authorizedProfile;
  const admin = join(ipc, `bridge-${port}.sock`);
  assert.equal((await localRequest(admin, "POST", "/revoke-project", { cwd: listed.current.cwd })).status, 200);
  assert.deepEqual((await (await bridge.get("/sessions")).json()).projects, []);
  assert.equal((await bridge.post("/new", { cwd: listed.current.cwd })).status, 403);
});

test("phone bridge lists commands and delivers /skill: and extension commands", { timeout: 30000 }, async (context) => {
  const root = await mkdtemp(join(tmpdir(), "pi-go-command-"));
  const agent = join(root, "agent");
  const work = join(root, "work");
  await Promise.all([agent, work].map((directory) => mkdir(directory)));
  await mkdir(join(agent, "skills", "summarize"), { recursive: true });
  await writeFile(join(agent, "skills", "summarize", "SKILL.md"),
    "---\nname: summarize\ndescription: Summarize material. Use when asked to summarize or condense text.\n---\n\nAlways answer with a one-line summary prefixed with [summarize].");
  const runPi = promisify(execFile);
  await runPi(pi, ["install", project], { cwd: work, env: { ...process.env, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1" } });
  const runtime = start(agent, work, {}, false, true);
  context.after(async () => {
    runtime.child.stdin.end();
    const fallback = setTimeout(() => runtime.child.kill(), 1500);
    await runtime.exit;
    clearTimeout(fallback);
    await rm(root, { force: true, recursive: true });
  });
  const bridge = await pair(runtime);
  const state = await (await bridge.get("/session")).json();
  const id = state.session.id;
  const listed = await (await bridge.get("/commands")).json();
  const commands = listed.commands;
  assert.ok(Array.isArray(commands));
  const names = commands.map(({ name }) => name);
  assert.ok(names.includes("pi-go"));
  assert.ok(names.includes("skill:summarize"));
  const skill = commands.find(({ name }) => name === "skill:summarize");
  assert.equal(skill.source, "skill");
  assert.match(skill.description, /Summarize/);
  assert.equal(skill.invoke, "/skill:summarize");
  assert.deepEqual(await (await bridge.post("/prompt", { id, requestId: "unknown-cmd", text: "/no-such-command" })).json(), { error: "unknown_command" });
  assert.deepEqual(await (await bridge.post("/prompt", { id, requestId: "attach-cmd", text: "/skill:summarize", attachments: [{ token: "aaaaaaaaaaaaaaaa", kind: "file" }] })).json(), { error: "command_attachments" });
  const since = runtime.messages.length;
  const input = { id, requestId: "skill-turn", text: "/skill:summarize chapter one of the fixture" };
  assert.equal((await bridge.post("/prompt", input)).status, 202);
  await runtime.wait((event) => event.type === "agent_settled", since);
  const chat = await (await bridge.get("/chat")).json();
  const userTurn = chat.messages.find(({ role, text }) => role === "user" && text.includes("chapter one"));
  assert.ok(userTurn, JSON.stringify(chat.messages.map(({ text }) => text)));
  assert.match(userTurn.text, /<skill name="summarize"/);
  assert.match(userTurn.text, /one-line summary/);
  assert.equal(chat.promptError, undefined);
  const stopSince = runtime.messages.length;
  const stopped = await (await bridge.post("/prompt", { id, requestId: "stop-cmd", text: "/pi-go-stop" })).json();
  assert.equal(stopped.dispatched, true);
  assert.equal(stopped.handled, true);
  await runtime.wait((event) => event.method === "notify" && event.message === "Pi Go probe stopped", stopSince);
});
