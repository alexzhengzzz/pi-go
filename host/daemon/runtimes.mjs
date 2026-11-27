// Managed runtime pool for the Pi Go daemon (Pi RPC + non-Pi agent worker shims).
//
// - For `pi`: each managed runtime is one `pi --mode rpc [--session <file>]`
//   child process spawned in the workspace. Extension UI requests
//   (`extension_ui_request`, methods confirm/select/input/editor) are surfaced
//   so the phone can answer them through the host's /pending and /answer routes.
// - For `codex` (and future agents): spawns `node host/agents/agent-worker.mjs`
//   which directly serves a `w-<pid>-<hex>.sock` worker socket and handles its
//   own `/pending` and `/answer` routes.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { localRequest } from '../bridge/local-ipc.mjs';
import { messageText } from '../bridge/message-view.mjs';

const agentWorkerScript = fileURLToPath(new URL('../agents/agent-worker.mjs', import.meta.url));
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
  constructor(pool, cwd, sessionPath, scheduled = false) {
    this.agent = 'pi';
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
    const env = scheduled ? { ...process.env, PIGO_SCHEDULED_RESULTS: '1' } : process.env;
    this.child = spawn(bin, args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
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
    this.scheduledPrompt?.complete({ reason: 'runtime_exited' });
    for (const { reject, timer } of this.commands.values()) {
      clearTimeout(timer);
      reject(new Error('runtime_exited'));
    }
    this.commands.clear();
    this.uiQueue = [];
    this.pool.forget(this);
  }

  onLine(line) {
    let event;
    try { event = JSON.parse(line); } catch { return; }
    if (!event || typeof event !== 'object') return;
    this.scheduledPrompt?.event(event);
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
      this.uiQueue.push({ event, expires, requestedAt: Date.now() });
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
      timer.unref?.();
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

  runScheduledPrompt(prompt, timeout) {
    return new Promise((resolve) => {
      let assistant;
      let final;
      const complete = (outcome) => {
        clearTimeout(timer);
        this.scheduledPrompt = undefined;
        resolve(outcome);
      };
      const timer = setTimeout(() => complete({ reason: 'run_timeout' }), timeout);
      this.scheduledPrompt = {
        complete,
        event: (event) => {
          if (event.type === 'message_end' && event.message?.role === 'assistant') assistant = event.message;
          if (event.type === 'extension_ui_request' && blockingMethods.has(event.method)) {
            complete({ reason: 'interaction_required' });
          }
          if (event.type === 'agent_end') {
            final = event.messages?.filter(({ role }) => role === 'assistant').at(-1) ?? assistant;
          }
          if (event.type === 'agent_settled') {
            const message = final ?? assistant;
            const output = messageText(message?.content);
            const reason = !event.aborted && (message?.stopReason === 'stop' || message?.stopReason === 'length')
              ? undefined : 'model_failed';
            complete({ output, reason });
          }
        }
      };
      this.sendCommand('prompt', { message: prompt }).catch(() => {
        this.scheduledPrompt?.complete({ reason: 'prompt_failed' });
      });
    });
  }

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
      const delay = attempt < 10 ? 20 : attempt < 25 ? 50 : statePollMs;
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
    throw new Error(`runtime_not_ready:${JSON.stringify(last ?? null)}`);
  }

  pendingInteraction() {
    const now = Date.now();
    const entry = this.uiQueue.find((item) => item.expires === undefined || item.expires > now);
    const event = entry?.event;
    if (!event) return undefined;
    return { id: event.id, method: event.method, requestedAt: entry.requestedAt, title: event.title, message: event.message,
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

export class AgentWorkerRuntime {
  constructor(pool, agent, cwd, sessionId, scheduled = false, options = {}) {
    this.agent = agent;
    this.pool = pool;
    this.cwd = cwd;
    this.sessionPath = options.sessionPath || sessionId;
    this.sessionId = sessionId;
    this.socketPath = undefined;
    this.readyEvent = undefined;
    this.exited = false;
    this.exitCode = null;
    this.readyResolvers = [];
    const args = [
      agentWorkerScript,
      '--agent', agent,
      '--cwd', cwd,
      ...(sessionId ? ['--session', sessionId] : []),
      ...(options.sessionPath ? ['--session-path', options.sessionPath] : []),
      ...(options.appDataDir ? ['--app-data-dir', options.appDataDir] : []),
      ...(options.sessionName ? ['--session-name', options.sessionName] : []),
    ];
    const env = scheduled ? { ...process.env, PIGO_SCHEDULED_RESULTS: '1' } : process.env;
    this.child = spawn(process.execPath, args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
    this.startedAt = Date.now();
    createInterface({ input: this.child.stdout }).on('line', (line) => {
      try {
        const msg = JSON.parse(line);
        if (msg?.type === 'worker_ready' && typeof msg.sessionId === 'string') {
          this.readyEvent = msg;
          this.sessionId = msg.sessionId;
          this.socketPath = msg.socket;
          this.notifyReady();
        }
      } catch {}
    });
    let stderr = '';
    this.child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr = (stderr + chunk).slice(-4000); });
    this.child.on('error', () => this.onExit(null));
    this.child.on('exit', (code) => this.onExit(code));
    this.stderr = () => stderr;
  }

  get pid() { return this.child.pid; }

  notifyReady() {
    const waiters = this.readyResolvers.splice(0);
    for (const wake of waiters) wake();
  }

  onExit(code) {
    if (this.exited) return;
    this.exited = true;
    this.exitCode = code;
    this.notifyReady();
    this.pool.forget(this);
  }

  async awaitReady(expectedId) {
    if (!this.readyEvent && !this.exited) {
      await new Promise((resolve) => {
        const timer = setTimeout(() => {
          this.readyResolvers = this.readyResolvers.filter((fn) => fn !== wake);
          resolve();
        }, statePollAttempts * statePollMs);
        const wake = () => {
          clearTimeout(timer);
          resolve();
        };
        this.readyResolvers.push(wake);
      });
    }
    if (this.exited) throw new Error(`runtime_exited:${this.exitCode}:${this.stderr().slice(-500)}`);
    if (this.readyEvent) {
      if (expectedId && this.sessionId !== expectedId) {
        throw new Error(`runtime_not_ready:${JSON.stringify(this.readyEvent)}`);
      }
      return { sessionId: this.sessionId, socketPath: this.socketPath };
    }
    throw new Error('runtime_not_ready:timeout');
  }

  async runScheduledPrompt(prompt, timeout) {
    const { sessionId, socketPath } = await this.awaitReady();
    if (!socketPath) return { reason: 'prompt_failed' };
    const dispatched = await localRequest(socketPath, 'POST', '/prompt', {
      id: sessionId,
      requestId: `sched-${randomUUID()}`,
      text: prompt,
      mode: 'send',
    }, 10000).catch(() => undefined);
    if (dispatched?.status !== 202) return { reason: 'prompt_failed' };
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (this.exited) return { reason: 'runtime_exited' };
      await new Promise((resolve) => setTimeout(resolve, 250));
      const pending = await localRequest(socketPath, 'GET', '/pending', undefined, 1500).catch(() => undefined);
      if (pending?.status === 200 && pending.data?.interaction) {
        return { reason: 'interaction_required' };
      }
      const chat = await localRequest(socketPath, 'GET', '/chat', undefined, 3000).catch(() => undefined);
      if (chat?.status === 200 && chat.data?.session?.idle === true) {
        if (chat.data.promptError) return { reason: 'model_failed' };
        const last = (chat.data.messages ?? []).findLast((message) => message.role === 'assistant');
        if (!last?.textTruncated) return { output: last?.text };
        let offset = 0;
        const chunks = [];
        while (offset !== undefined) {
          const params = new URLSearchParams({ id: sessionId, message: last.id, offset: String(offset) });
          const page = await localRequest(socketPath, 'GET', `/message-text?${params}`, undefined, 3000).catch(() => undefined);
          if (page?.status !== 200 || typeof page.data?.text !== 'string' ||
            (page.data.nextTextOffset !== undefined && (!page.data.text || page.data.nextTextOffset !== offset + page.data.text.length))) {
            return { reason: 'result_unavailable' };
          }
          chunks.push(page.data.text);
          offset = page.data.nextTextOffset;
        }
        return { output: chunks.join('') };
      }
    }
    return { reason: 'run_timeout' };
  }

  pendingInteraction() { return undefined; }
  respondFromPiGo() { return false; }

  kill() {
    if (!this.exited) { try { this.child.kill('SIGTERM'); } catch {} }
  }
}

export class RuntimePool {
  constructor() { this.runtimes = new Map(); }

  start(cwd, sessionPath, scheduled = false, agent = 'pi', options = {}) {
    const runtime = agent === 'pi'
      ? new RpcRuntime(this, cwd, sessionPath, scheduled)
      : new AgentWorkerRuntime(this, agent, cwd, sessionPath, scheduled, options);
    this.runtimes.set(`${runtime.pid}`, runtime);
    return runtime;
  }

  forget(runtime) { this.runtimes.delete(`${runtime.pid}`); }

  find(pid, sessionId) {
    if (!Number.isInteger(pid) || typeof sessionId !== 'string') return undefined;
    const runtime = this.runtimes.get(`${pid}`);
    if (!runtime || runtime.exited) return undefined;
    if (runtime.sessionId && runtime.sessionId !== sessionId) return undefined;
    return runtime;
  }

  findBySession(cwd, sessionId, agent = 'pi') {
    return [...this.runtimes.values()].find((runtime) =>
      !runtime.exited && (runtime.agent ?? 'pi') === agent && runtime.cwd === cwd && runtime.sessionId === sessionId);
  }

  list() { return [...this.runtimes.values()].filter((runtime) => !runtime.exited); }

  stop(runtime) {
    if (runtime.exited) return Promise.resolve();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        try { runtime.child.kill('SIGKILL'); } catch {}
        resolve();
      }, 4000);
      runtime.child.once('exit', () => { clearTimeout(timer); resolve(); });
      runtime.kill();
    });
  }

  async killFor(cwd) {
    const victims = this.list().filter((runtime) => runtime.cwd === cwd);
    await Promise.all(victims.map((runtime) => this.stop(runtime)));
    return victims.length;
  }

  async stopAll() {
    await Promise.all(this.list().map((runtime) => this.stop(runtime)));
  }
}
