// Pi RPC runtime pool for the Pi Go daemon.
//
// Each managed runtime is one `pi --mode rpc [--session <file>]` child process
// spawned in the workspace. The daemon speaks the public JSON-lines RPC protocol
// over the child's stdio: commands on stdin, responses and events on stdout.
// Extension UI requests (`extension_ui_request`, methods confirm/select/input/
// editor) are surfaced so the phone can answer them through the host's
// /pending and /answer routes; answers are written back as
// `extension_ui_response` lines.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const blockingMethods = new Set(['confirm', 'select', 'input', 'editor']);
const textLimit = 1024;
const commandTimeoutMs = 15000;
const statePollMs = 100;
const statePollAttempts = 150;

const extraArgs = () => {
  if (!process.env.PIGO_PI_ARGS) return [];
  try {
    const value = JSON.parse(process.env.PIGO_PI_ARGS);
    return Array.isArray(value) && value.every((item) => typeof item === 'string') ? value : [];
  } catch { return []; }
};

const admissible = (event) => {
  if ((event.title?.length ?? 0) > 512 || (event.message?.length ?? 0) > 8192) return false;
  if (event.method === 'confirm') return true;
  if (event.method === 'select') {
    return Array.isArray(event.options) && event.options.length <= 20 &&
      event.options.every((option) => typeof option === 'string' && option.length <= 400);
  }
  if (event.method === 'input') return (event.placeholder?.length ?? 0) <= 512;
  if (event.method === 'editor') return (event.prefill?.length ?? 0) <= textLimit;
  return false;
};

export class RpcRuntime {
  constructor(pool, cwd, sessionPath) {
    this.pool = pool;
    this.cwd = cwd;
    this.sessionPath = sessionPath;
    this.exited = false;
    this.exitCode = null;
    this.uiQueue = [];
    this.commands = new Map();
    this.sequence = 0;
    const bin = process.env.PIGO_PI_BIN || 'pi';
    const args = ['--mode', 'rpc', ...(sessionPath ? ['--session', sessionPath] : []), ...extraArgs()];
    this.child = spawn(bin, args, { cwd, env: { ...process.env }, stdio: ['pipe', 'pipe', 'pipe'] });
    this.startedAt = Date.now();
    createInterface({ input: this.child.stdout }).on('line', (line) => this.onLine(line));
    let stderr = '';
    this.child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr = (stderr + chunk).slice(-4000); });
    this.child.on('error', () => this.onExit(null));
    this.child.on('exit', (code) => this.onExit(code));
    this.stderr = () => stderr;
  }

  get pid() { return this.child.pid; }

  onExit(code) {
    if (this.exited) return;
    this.exited = true;
    this.exitCode = code;
    for (const { reject } of this.commands.values()) reject(new Error('runtime_exited'));
    this.commands.clear();
    this.uiQueue = [];
    this.pool.forget(this);
  }

  onLine(line) {
    let event;
    try { event = JSON.parse(line); } catch { return; }
    if (!event || typeof event !== 'object') return;
    if (event.type === 'response' && typeof event.id === 'string') {
      const pending = this.commands.get(event.id);
      if (!pending) return;
      this.commands.delete(event.id);
      clearTimeout(pending.timer);
      if (event.success === true) pending.resolve(event.data);
      else pending.reject(new Error(typeof event.error === 'string' ? event.error : 'command_failed'));
      return;
    }
    if (event.type === 'extension_ui_request' && blockingMethods.has(event.method) &&
      typeof event.id === 'string' && admissible(event)) {
      const expires = typeof event.timeout === 'number' && event.timeout > 0 ? Date.now() + event.timeout : undefined;
      this.uiQueue = this.uiQueue.filter((item) => item.event.id !== event.id);
      this.uiQueue.push({ event, expires });
      if (this.uiQueue.length > 8) this.uiQueue.shift();
    }
  }

  sendCommand(type, data = {}) {
    if (this.exited) return Promise.reject(new Error('runtime_exited'));
    const id = `daemon-${++this.sequence}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.commands.delete(id);
        reject(new Error('command_timeout'));
      }, commandTimeoutMs);
      this.commands.set(id, { resolve, reject, timer });
      try {
        this.child.stdin.write(`${JSON.stringify({ type, id, ...data })}\n`);
      } catch (error) {
        this.commands.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  // Poll get_state until the runtime reports the expected session (or any
  // session when expectedId is omitted) and is neither streaming nor compacting.
  async awaitReady(expectedId) {
    let last;
    for (let attempt = 0; attempt < statePollAttempts; attempt += 1) {
      if (this.exited) throw new Error(`runtime_exited:${this.exitCode}:${this.stderr().slice(-500)}`);
      try {
        const state = await this.sendCommand('get_state');
        last = state;
        if ((!expectedId || state.sessionId === expectedId) && !state.isStreaming && !state.isCompacting) {
          this.sessionId = state.sessionId;
          return state;
        }
      } catch { /* retry: the engine may not be ready yet */ }
      await new Promise((resolve) => setTimeout(resolve, statePollMs));
    }
    throw new Error(`runtime_not_ready:${JSON.stringify(last ?? null)}`);
  }

  // Snapshot of the currently pending interaction, skipping expired entries.
  pendingInteraction() {
    const now = Date.now();
    const entry = this.uiQueue.find((item) => item.expires === undefined || item.expires > now);
    const event = entry?.event;
    if (!event) return undefined;
    return { id: event.id, method: event.method, title: event.title, message: event.message,
      options: event.method === 'select' ? event.options : undefined,
      placeholder: event.method === 'input' ? event.placeholder : undefined,
      prefill: event.method === 'editor' ? event.prefill : undefined };
  }

  writeUiResponse(id, response) {
    if (this.exited) return false;
    try {
      this.child.stdin.write(`${JSON.stringify({ type: 'extension_ui_response', id, ...response })}\n`);
      return true;
    } catch { return false; }
  }

  // Confirm accepts a boolean, select accepts an offered option, and input
  // and editor accept up to 1024 characters. False cancels select, input, or editor.
  respondFromPiGo(pendingId, answer) {
    const interaction = this.pendingInteraction();
    if (!interaction || interaction.id !== pendingId) return false;
    let response;
    if (interaction.method === 'confirm' && typeof answer === 'boolean') response = { confirmed: answer };
    else if (interaction.method === 'select' && typeof answer === 'string' && interaction.options?.includes(answer)) response = { value: answer };
    else if (interaction.method === 'select' && answer === false) response = { cancelled: true };
    else if (interaction.method === 'input' || interaction.method === 'editor') {
      if (answer === false) response = { cancelled: true };
      else if (typeof answer === 'string' && answer.length <= textLimit &&
        (interaction.method === 'editor' || !/[\r\n]/.test(answer))) response = { value: answer };
      else return false;
    } else return false;
    if (!this.writeUiResponse(pendingId, response)) return false;
    this.uiQueue = this.uiQueue.filter((item) => item.event.id !== pendingId);
    return true;
  }

  kill() {
    if (!this.exited) { try { this.child.kill('SIGTERM'); } catch {} }
  }
}

export class RuntimePool {
  constructor() { this.runtimes = new Map(); }

  // Spawn a fresh runtime. The caller validates readiness and triggers
  // /pi-go-share so the extension's worker socket appears for the broker.
  start(cwd, sessionPath) {
    const runtime = new RpcRuntime(this, cwd, sessionPath);
    this.runtimes.set(`${runtime.pid}`, runtime);
    return runtime;
  }

  forget(runtime) { this.runtimes.delete(`${runtime.pid}`); }

  find(pid, sessionId) {
    if (!Number.isInteger(pid) || typeof sessionId !== 'string') return undefined;
    const runtime = this.runtimes.get(`${pid}`);
    return runtime && !runtime.exited ? runtime : undefined;
  }

  findBySession(cwd, sessionId) {
    return [...this.runtimes.values()].find((runtime) =>
      !runtime.exited && runtime.cwd === cwd && runtime.sessionId === sessionId);
  }

  list() { return [...this.runtimes.values()].filter((runtime) => !runtime.exited); }

  async killFor(cwd) {
    const victims = this.list().filter((runtime) => runtime.cwd === cwd);
    for (const runtime of victims) runtime.kill();
    await Promise.all(victims.map((runtime) =>
      new Promise((resolve) => {
        if (runtime.exited) return resolve();
        const timer = setTimeout(() => { try { runtime.child.kill('SIGKILL'); } catch {} resolve(); }, 4000);
        runtime.child.once('exit', () => { clearTimeout(timer); resolve(); });
      })));
    return victims.length;
  }

  async stopAll() {
    const victims = this.list();
    for (const runtime of victims) runtime.kill();
    await Promise.all(victims.map((runtime) =>
      new Promise((resolve) => {
        if (runtime.exited) return resolve();
        const timer = setTimeout(() => { try { runtime.child.kill('SIGKILL'); } catch {} resolve(); }, 4000);
        runtime.child.once('exit', () => { clearTimeout(timer); resolve(); });
      })));
  }
}
