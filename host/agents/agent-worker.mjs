// Worker shim process entry point for non-Pi agents.
//
//   node host/agents/agent-worker.mjs --agent codex --cwd /path/to/workspace [--session <id>] [--attach]
//
// Starts the requested AgentDriver, binds it to a `w-<pid>-<hex>.sock` worker
// server via `createWorkerServer`, and prints a single JSON readiness line on
// stdout for the spawning daemon:
//   {"type":"worker_ready","agent":"codex","sessionId":"...","socket":"/path/to/w-....sock"}
import { createWorkerServer } from './worker-core.mjs';
import { CodexDriver } from './codex/driver.mjs';
import { AgyDriver } from './agy/driver.mjs';

const argv = process.argv.slice(2);
const option = (name) => {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : undefined;
};

const agent = option('--agent') || 'codex';
const cwd = option('--cwd') || process.cwd();
const sessionId = option('--session');
const sessionPath = option('--session-path');
const appDataDir = option('--app-data-dir');
const sessionName = option('--session-name');
const attach = argv.includes('--attach');
const scheduled = process.env.PIGO_SCHEDULED_RESULTS === '1';

async function main() {
  let driver;
  if (agent === 'codex') {
    driver = new CodexDriver({ cwd, sessionId, sessionPath, sessionName, attach, scheduled });
  } else if (agent === 'agy') {
    driver = new AgyDriver({ cwd, sessionId, sessionPath, appDataDir, sessionName, attach, scheduled });
  } else {
    throw new Error(`unsupported_agent:${agent}`);
  }
  await driver.start();
  const server = createWorkerServer(driver, {
    scheduled,
    onShutdown: () => { setImmediate(() => process.exit(0)); },
  });
  const socket = await server.listen();
  const state = server.status();
  process.stdout.write(`${JSON.stringify({
    type: 'worker_ready',
    agent,
    sessionId: state?.id,
    cwd: state?.cwd,
    socket,
  })}\n`);

  let stopping = false;
  const shutdown = async () => {
    if (stopping) return;
    stopping = true;
    await server.stop();
    process.exit(0);
  };
  process.on('SIGTERM', () => { void shutdown(); });
  process.on('SIGINT', () => { void shutdown(); });
  process.stdin.on('error', () => {});
  if (!process.stdin.isTTY) {
    process.stdin.resume();
    process.stdin.once('end', () => { void shutdown(); });
    process.stdin.once('close', () => { void shutdown(); });
  }
}

main().catch((error) => {
  process.stderr.write(`pi-go agent-worker (${agent}): ${error?.stack ?? error}\n`);
  process.exit(1);
});
