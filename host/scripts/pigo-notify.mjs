#!/usr/bin/env node
// Send a generic workspace alert to the local Pi Go daemon so it reaches the
// phone inbox, HarmonyOS Push Kit, and connected Wear Engine watch.
import { desktopHosts, localRequest } from '../bridge/local-ipc.mjs';

function usage() {
  process.stderr.write(
    'Usage: pigo-notify --title <text> [--body <text>] [--source <name>] [--dedupe <key>]\n' +
    '                   [--severity info|warn|error] [--cwd <dir>] [--prompt <text>]\n' +
    '                   [--artifact <relpath>]... [--json]\n'
  );
}

function parseArgs(argv) {
  const payload = {};
  const artifacts = [];
  let readStdin = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '-h' || arg === '--help') {
      usage();
      process.exit(0);
    }
    if (arg === '--json') {
      readStdin = true;
      continue;
    }
    const next = argv[i + 1];
    if (next === undefined) {
      throw new Error(`missing value for ${arg}`);
    }
    switch (arg) {
      case '--title': payload.title = next; i++; break;
      case '--body': payload.body = next; i++; break;
      case '--source': payload.source = next; i++; break;
      case '--dedupe': payload.dedupeKey = next; i++; break;
      case '--severity': payload.severity = next; i++; break;
      case '--cwd': payload.cwd = next; i++; break;
      case '--prompt': payload.suggestedPrompt = next; i++; break;
      case '--artifact': artifacts.push(next); i++; break;
      default:
        throw new Error(`unknown option: ${arg}`);
    }
  }
  if (artifacts.length) payload.artifacts = artifacts;
  return { payload, readStdin };
}

async function readStdinJson() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString('utf8').trim();
  if (!raw) return {};
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('stdin JSON must be an object');
  }
  return parsed;
}

async function main() {
  const { payload: cliPayload, readStdin } = parseArgs(process.argv.slice(2));
  const stdinPayload = readStdin ? await readStdinJson() : {};
  const payload = { ...stdinPayload, ...cliPayload };
  if (Array.isArray(stdinPayload.artifacts) && Array.isArray(cliPayload.artifacts)) {
    payload.artifacts = [...stdinPayload.artifacts, ...cliPayload.artifacts];
  }
  if (typeof payload.title !== 'string' || !payload.title.trim()) {
    usage();
    process.exit(2);
  }
  const hosts = await desktopHosts();
  if (hosts.length === 0) {
    process.stderr.write('pigo-notify: no running Pi Go daemon found\n');
    process.exit(1);
  }
  const reply = await localRequest(hosts[0], 'POST', '/alerts/emit', payload, 3000);
  if (reply.status !== 200) {
    process.stderr.write(`pigo-notify: daemon rejected alert (${reply.status}): ${JSON.stringify(reply.data)}\n`);
    process.exit(1);
  }
  process.stdout.write(JSON.stringify(reply.data) + '\n');
}

main().catch((error) => {
  process.stderr.write(`pigo-notify: ${error?.message ?? error}\n`);
  process.exit(1);
});
