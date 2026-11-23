// Probe the local `codex app-server` protocol and record a fixture transcript.
//
//   node host/scripts/probe-codex.mjs [--cwd DIR] [--turn] [--out FILE]
//
// Without --turn, only read-only calls run (initialize, model/list, thread/list,
// thread/loaded/list, skills/list). With --turn, a throwaway ephemeral thread runs
// one tiny prompt with approvals/sandbox bypassed, then is interrupted/cleaned up.
import { writeFileSync } from 'node:fs';
import { JsonRpcProcess } from '../agents/jsonrpc.mjs';

const argv = process.argv.slice(2);
const option = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
const cwd = option('--cwd') ?? process.cwd();
const out = option('--out');
const runTurn = argv.includes('--turn');
const log = [];
const record = (kind, method, payload) => {
  log.push({ t: Date.now(), kind, method, payload });
  const text = JSON.stringify(payload);
  console.log(`${kind.padEnd(6)} ${method} ${text.length > 400 ? `${text.slice(0, 400)}…` : text}`);
};

const rpc = new JsonRpcProcess(process.env.PIGO_CODEX_BIN || 'codex', ['app-server'], { cwd });
rpc.on('notification', (method, params) => record('notify', method, params));
rpc.onRequest((method, params) => {
  record('srvreq', method, params);
  if (/requestApproval|Approval$/.test(method)) return { decision: 'decline' };
  throw Object.assign(new Error('unsupported'), { code: -32601 });
});
const call = async (method, params, timeout) => {
  try {
    const result = await rpc.request(method, params, timeout);
    record('result', method, result);
    return result;
  } catch (error) {
    record('error', method, { message: error.message, code: error.code });
    return undefined;
  }
};

try {
  await call('initialize', { clientInfo: { name: 'pi-go-probe', title: 'Pi Go', version: '0.0.1' }, capabilities: null });
  rpc.notify('initialized');
  await call('model/list', {});
  await call('thread/list', { limit: 5, cwd });
  await call('thread/loaded/list', {});
  await call('skills/list', { cwds: [cwd] });
  if (runTurn) {
    const started = await call('thread/start', { cwd, approvalPolicy: 'never', sandbox: 'danger-full-access', ephemeral: true });
    const threadId = started?.thread?.id;
    if (threadId) {
      const done = new Promise((resolve) => {
        const onNote = (method) => { if (method === 'turn/completed') { rpc.off('notification', onNote); resolve(); } };
        rpc.on('notification', onNote);
      });
      await call('turn/start', { threadId, input: [{ type: 'text', text: 'Reply with exactly: pong', text_elements: [] }] });
      await Promise.race([done, new Promise((resolve) => setTimeout(resolve, 90000))]);
      await call('thread/read', { threadId, includeTurns: true });
      await call('thread/turns/list', { threadId, limit: 10 });
    }
  }
} finally {
  await rpc.stop();
  if (rpc.stderr()) console.error(`stderr tail:\n${rpc.stderr().slice(-1500)}`);
  if (out) writeFileSync(out, `${log.map((row) => JSON.stringify(row)).join('\n')}\n`);
}
