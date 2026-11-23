// Probe the local `agy acp` protocol and record a fixture transcript.
//
//   node host/scripts/probe-agy.mjs [--cwd DIR] [--session ID] [--out FILE]
import { writeFileSync } from 'node:fs';
import { JsonRpcProcess } from '../agents/jsonrpc.mjs';

const argv = process.argv.slice(2);
const option = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
const cwd = option('--cwd') ?? process.cwd();
const sessionId = option('--session');
const out = option('--out');
const log = [];
const record = (kind, method, payload) => {
  log.push({ t: Date.now(), kind, method, payload });
  const text = JSON.stringify(payload);
  console.log(`${kind.padEnd(6)} ${method} ${text.length > 400 ? `${text.slice(0, 400)}…` : text}`);
};

const rpc = new JsonRpcProcess(process.env.PIGO_AGY_BIN || 'agy', ['acp'], { cwd, wireVersion: true });
rpc.on('notification', (method, params) => record('notify', method, params));
rpc.onRequest((method, params) => {
  record('srvreq', method, params);
  if (method === 'session/request_permission') return { outcome: { outcome: 'cancelled' } };
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
  await call('initialize', { protocolVersion: 1, clientInfo: { name: 'pi-go-probe', title: 'Pi Go', version: '0.0.1' }, clientCapabilities: {} });
  await call('session/list', {});
  if (sessionId) {
    await call('session/load', { sessionId, cwd, mcpServers: [] });
  }
} finally {
  await rpc.stop();
  if (rpc.stderr()) console.error(`stderr tail:\n${rpc.stderr().slice(-1500)}`);
  if (out) writeFileSync(out, `${log.map((row) => JSON.stringify(row)).join('\n')}\n`);
}
