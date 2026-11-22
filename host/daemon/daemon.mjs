// Pi Go daemon entry point.
//
// The always-on host for the Pi Go bridge:
//   - serves the `pi-go-desktop-host/1` protocol on a host socket in the Pi Go
//     IPC directory for the broker;
//   - spawns and supervises `pi --mode rpc` child processes per workspace
//     session (native open / new / close);
//   - bridges extension UI requests (confirm/select/input/editor) from the RPC
//     event stream to the phone via /pending and /answer.
//
// Lifecycle: run under launchd (RunAtLoad + KeepAlive) or directly. SIGTERM
// stops every managed runtime and exits. A second instance refuses to start
// while a live host socket still answers.
import { unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { once } from 'node:events';
import { desktopHosts } from '../bridge/local-ipc.mjs';
import { stateDirectory } from '../bridge/session-metadata.mjs';
import { WorkspaceRegistry } from './registry.mjs';
import { RuntimePool } from './runtimes.mjs';
import { ScheduleService } from './schedules.mjs';
import { createDaemonHost } from './host.mjs';

async function main() {
  const directory = join(stateDirectory(), 'daemon');
  const registry = new WorkspaceRegistry(join(directory, 'workspaces.json'));
  const runtimes = new RuntimePool();

  const existing = await desktopHosts();
  if (existing.length > 0) {
    process.stderr.write('pi-go daemon: another host is already serving\n');
    process.exit(1);
  }
  let schedules;
  try {
    schedules = new ScheduleService(join(directory, 'schedules.json'), { registry, runtimes });
  } catch (error) {
    process.stderr.write(`pi-go scheduler unavailable: ${error.message}\n`);
    schedules = undefined;
  }
  const host = createDaemonHost({ registry, runtimes, schedules });

  await new Promise((resolve, reject) => {
    host.server.once('error', reject);
    host.server.listen(host.path, () => { host.server.off('error', reject); resolve(); });
  });
  process.stderr.write(`pi-go daemon: serving ${host.path}\n`);
  try { schedules?.start(); }
  catch (error) {
    try { schedules.stop(); } catch {}
    process.stderr.write(`pi-go scheduler unavailable: ${error.message}\n`);
  }

  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    host.shutdown();
    try { schedules?.stop(); }
    catch (error) { process.stderr.write(`pi-go scheduler: ${error.message}\n`); }
    await runtimes.stopAll();
    try { unlinkSync(host.path); } catch {}
    process.exit(0);
  };
  process.on('SIGTERM', () => { void stop(); });
  process.on('SIGINT', () => { void stop(); });
  // Keep running even if stdin closes (launchd runs the daemon detached).
  process.stdin.on('error', () => {});
  await once(process, 'beforeExit');
  await stop();
}

main().catch((error) => {
  process.stderr.write(`pi-go daemon: ${error?.stack ?? error}\n`);
  process.exit(1);
});
