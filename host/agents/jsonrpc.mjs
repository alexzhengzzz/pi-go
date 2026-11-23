// Minimal JSON-RPC 2.0 peer over a child process's stdio (one JSON object per
// line). Used by the Codex app-server driver; the ACP driver can reuse it.
//
// - request(method, params) → Promise<result>
// - notify(method, params)
// - onNotification(fn(method, params))
// - onRequest(fn(method, params) → Promise<result> | result)  (server→client)
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';

export class JsonRpcProcess extends EventEmitter {
  constructor(bin, args, { cwd, env, requestTimeoutMs = 30000, wireVersion = false } = {}) {
    super();
    this.requestTimeoutMs = requestTimeoutMs;
    this.wireVersion = wireVersion;
    this.sequence = 0;
    this.pending = new Map();
    this.exited = false;
    this.exitCode = null;
    this.requestHandler = undefined;
    let stderr = '';
    this.child = spawn(bin, args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stdin.on('error', () => {});
    createInterface({ input: this.child.stdout, crlfDelay: Infinity }).on('line', (line) => this.onLine(line));
    this.child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr = (stderr + chunk).slice(-8000); });
    this.stderr = () => stderr;
    this.child.on('error', (error) => this.onExit(null, error));
    this.child.on('exit', (code) => this.onExit(code));
  }

  get pid() { return this.child.pid; }

  onExit(code, error) {
    if (this.exited) return;
    this.exited = true;
    this.exitCode = code;
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(new Error(error ? `spawn_failed:${error.code ?? error.message}` : 'process_exited'));
    }
    this.pending.clear();
    this.emit('exit', code);
  }

  write(message) {
    if (this.exited) return false;
    try {
      this.child.stdin.write(`${JSON.stringify(this.wireVersion ? { jsonrpc: '2.0', ...message } : message)}\n`);
      return true;
    } catch { return false; }
  }

  onLine(line) {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (!message || typeof message !== 'object') return;
    const hasId = message.id !== undefined && message.id !== null;
    if (hasId && typeof message.method !== 'string') {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        const error = new Error(typeof message.error.message === 'string' ? message.error.message : 'rpc_error');
        error.code = message.error.code;
        error.data = message.error.data;
        pending.reject(error);
      } else pending.resolve(message.result);
      return;
    }
    if (typeof message.method !== 'string') return;
    if (hasId) {
      this.handleRequest(message.id, message.method, message.params);
      return;
    }
    this.emit('notification', message.method, message.params ?? {});
  }

  async handleRequest(id, method, params) {
    try {
      if (!this.requestHandler) throw Object.assign(new Error('method_not_found'), { code: -32601 });
      const result = await this.requestHandler(method, params ?? {}, id);
      this.write({ id, result: result ?? {} });
    } catch (error) {
      this.write({ id, error: { code: typeof error.code === 'number' ? error.code : -32603, message: String(error.message ?? error) } });
    }
  }

  onRequest(handler) { this.requestHandler = handler; }

  request(method, params, timeoutMs = this.requestTimeoutMs) {
    if (this.exited) return Promise.reject(new Error('process_exited'));
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`rpc_timeout:${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      if (!this.write({ id, method, params })) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(new Error('process_exited'));
      }
    });
  }

  notify(method, params) { return this.write(params === undefined ? { method } : { method, params }); }

  kill(signal = 'SIGTERM') {
    if (!this.exited) { try { this.child.kill(signal); } catch {} }
  }

  stop(graceMs = 3000) {
    if (this.exited) return Promise.resolve();
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.kill('SIGKILL'); resolve(); }, graceMs);
      this.once('exit', () => { clearTimeout(timer); resolve(); });
      try { this.child.stdin.end(); } catch {}
      this.kill();
    });
  }
}
