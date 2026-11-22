// Bundled macOS service management. The same user owns the GUI, jobs and IPC.
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { setTimeout as pause } from 'node:timers/promises';
import { promisify } from 'node:util';
import { desktopHosts, ipcDirectory, localRequest, workers } from './local-ipc.mjs';

const run = promisify(execFile);
const hostLabel = 'dev.pi.go.daemon';
const remoteLabel = 'com.alex.pigo.remote.broker';
const tunnelLabel = 'com.alex.pigo.remote.tunnel';
const domain = `gui/${process.getuid()}`;
const agents = join(homedir(), 'Library', 'LaunchAgents');
const logs = join(homedir(), 'Library', 'Logs');
const ctl = (...args) => run('/bin/launchctl', args, { timeout: 8000 });
const job = (label) => `${domain}/${label}`;
const plist = (label) => join(agents, `${label}.plist`);
const usbWatchLabel = (port) => `dev.pi.go.usb-watch.${port}`;
const labelFor = (mode, port) => mode === 'remote' ? remoteLabel : `dev.pi.go.bridge.${mode}.${port}`;

async function jobInfo(label) {
  try { return (await ctl('print', job(label))).stdout; }
  catch (error) { if (error.code === 113) return ''; throw error; }
}

async function bootout(label) {
  const info = await jobInfo(label);
  if (!info) return;
  await ctl('bootout', job(label));
  const pid = jobPID(info);
  await waitFor(async () => {
    if (await jobInfo(label)) return false;
    if (!pid) return true;
    try { process.kill(pid, 0); return false; }
    catch (error) { if (error.code === 'ESRCH') return true; throw error; }
  }, `${label} 尚未停止。`);
}

async function bootstrap(label, file) {
  for (let attempt = 0; ; attempt += 1) {
    try { await ctl('bootstrap', domain, file); return; }
    catch (error) {
      if (error.code !== 5 || attempt === 9) throw error;
      if (await jobInfo(label)) return;
      await pause(250);
    }
  }
}

async function parsePlist(file) {
  const { stdout } = await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file]);
  return JSON.parse(stdout);
}

async function waitFor(probe, message) {
  for (let attempt = 0; attempt < 45; attempt += 1) {
    const state = await probe();
    if (state) return state;
    await pause(150);
  }
  throw new Error(message);
}

function jobPID(info) {
  return Number(/^\s*pid = (\d+)$/m.exec(info)?.[1]) || undefined;
}

export function createAppServices(root) {
  const env = {
    PATH: process.env.PATH,
    TMPDIR: tmpdir(),
    PIGO_PI_BIN: process.env.PIGO_PI_BIN || 'pi',
  };
  for (const name of ['PI_CODING_AGENT_DIR', 'PIGO_IPC_DIR', 'PIGO_STATE_DIR', 'PIGO_PI_ARGS', 'HDC_BIN']) {
    if (process.env[name] !== undefined) env[name] = process.env[name];
  }

  async function bridgeStatus(port) {
    try {
      const result = await localRequest(join(ipcDirectory(), `bridge-${port}.sock`), 'GET', '/status', undefined, 900);
      if (result.status !== 200 || result.data.protocol !== 'pi-go-pairing/1') throw new Error('此端口已有其他服务。');
      return result.data;
    } catch (error) {
      if (['ENOENT', 'ECONNREFUSED'].includes(error.code)) return undefined;
      throw error;
    }
  }

  async function stopBridge(port) {
    if (!await bridgeStatus(port)) return;
    const result = await localRequest(join(ipcDirectory(), `bridge-${port}.sock`), 'POST', '/stop');
    if (result.status !== 200) throw new Error('现有连接服务无法停止。');
    await waitFor(async () => {
      try { return !await bridgeStatus(port); }
      catch (error) { if (error.code === 'ECONNRESET') return false; throw error; }
    }, '现有连接服务仍在停止。');
  }

  async function replace(label, args, ready, handoff = async () => {}) {
    await Promise.all([mkdir(agents, { recursive: true }), mkdir(logs, { recursive: true })]);
    const file = plist(label);
    const current = await readFile(file).catch((error) => { if (error.code !== 'ENOENT') throw error; });
    const previous = current && await parsePlist(file);
    const loaded = Boolean(await jobInfo(label));
    const config = {
      Label: label, ProgramArguments: args, RunAtLoad: true, KeepAlive: true, ProcessType: 'Background',
      StandardErrorPath: join(logs, `${label}.log`),
      EnvironmentVariables: { ...previous?.EnvironmentVariables, ...env },
    };
    if (loaded && JSON.stringify(previous?.ProgramArguments) === JSON.stringify(args) && await ready()) return;
    const draft = join(agents, `.${label}.${randomUUID()}`);
    try {
      await writeFile(draft, JSON.stringify(config), { mode: 0o600, flag: 'wx' });
      await run('/usr/bin/plutil', ['-convert', 'xml1', draft]);
      await bootout(label);
      try {
        await handoff();
        await rename(draft, file);
        await ctl('enable', job(label));
        await bootstrap(label, file);
        await waitFor(ready, `${label} 未就绪，请查看 ~/Library/Logs 下的日志。`);
      } catch (error) {
        await bootout(label);
        if (current) await writeFile(file, current, { mode: 0o600 });
        else await rm(file, { force: true });
        if (loaded && current) await bootstrap(label, file);
        throw error;
      }
    } finally {
      await rm(draft, { force: true });
    }
  }

  async function startHost() {
    await run(env.PIGO_PI_BIN, ['--version'], { env: { ...process.env, ...env }, timeout: 5000 });
    const info = await jobInfo(hostLabel);
    const pid = jobPID(info);
    const hosts = await desktopHosts();
    if (hosts.some((socket) => socket !== join(ipcDirectory(), `host-${pid}.sock`))) {
      throw new Error('当前已有其他 Pi Go 宿主，请退出旧宿主再启用后台服务。');
    }
    const args = [process.execPath, join(root, 'daemon', 'daemon.mjs')];
    const ready = async () => {
      const active = jobPID(await jobInfo(hostLabel));
      return active && (await desktopHosts()).includes(join(ipcDirectory(), `host-${active}.sock`));
    };
    // Wait for hosted work to finish before replacing the old runtime parent.
    if (pid && (await parsePlist(plist(hostLabel))).ProgramArguments?.[1] !== args[1]) {
      const { stdout } = await run('/bin/ps', ['-axo', 'pid=,ppid=']);
      const children = new Set(stdout.trim().split('\n').map((line) => line.trim().split(/\s+/))
        .filter(([, parent]) => Number(parent) === pid).map(([child]) => child));
      const managed = workers().filter((socket) => children.has(/^w-(\d+)-/.exec(basename(socket))?.[1]));
      for (const socket of managed) {
        const { data } = await localRequest(socket, 'GET', '/session');
        if (!data.session?.idle || data.session.queued) throw new Error('Pi Go 后台仍有任务运行，请等任务结束后再升级。');
      }
    }
    await replace(hostLabel, args, ready);
  }

  async function startBridge(mode, port, host, endpoint) {
    const current = await bridgeStatus(port);
    if (current && (current.transport !== mode || (mode === 'lan' && current.host !== host) ||
      (mode === 'remote' && current.address !== endpoint))) {
      throw new Error('该端口已使用其他连接配置，请先停用现有连接。');
    }
    const options = mode === 'lan' ? [host] : mode === 'remote' ? ['--remote', ...endpoint.split(':')] : [];
    const label = labelFor(mode, port);
    const mayStopLegacy = Boolean(current);
    await replace(label, [process.execPath, join(root, 'desktop', 'broker.mjs'), String(port), ...options],
      async () => {
        if (!jobPID(await jobInfo(label))) return false;
        const state = await bridgeStatus(port);
        return state && (!current?.paired || state.paired);
      },
      async () => { if (mayStopLegacy) await stopBridge(port); });
    const status = await bridgeStatus(port);
    if (current?.paired && !status?.paired) throw new Error('现有配对状态未恢复，请检查连接地址和 Pi 用户目录。');
    return status;
  }

  async function adoptTunnel() {
    let config;
    try { config = await parsePlist(plist(tunnelLabel)); }
    catch (error) {
      if (await readFile(plist(tunnelLabel)).catch(() => undefined)) throw error;
      return false;
    }
    const [python, script, ...args] = config.ProgramArguments ?? [];
    if (!python || basename(script ?? '') !== 'run-remote-tunnel.py') return false;
    await replace(tunnelLabel, [python, join(root, 'scripts', 'run-remote-tunnel.py'), ...args],
      async () => Boolean(jobPID(await jobInfo(tunnelLabel))));
    return true;
  }

  async function setUSB(port, enabled) {
    const label = usbWatchLabel(port);
    if (!enabled) {
      await bootout(label);
      await ctl('disable', job(label));
      return;
    }
    await replace(label, [process.execPath, join(root, 'desktop', 'usb-watch.mjs'), String(port)],
      async () => Boolean(jobPID(await jobInfo(label))));
  }

  return {
    startHost, startBridge, adoptTunnel, setUSB,
    async status(mode, port) {
      const label = labelFor(mode, port);
      const [host, bridge, tunnel, config, usbWatch] = await Promise.all([
        jobInfo(hostLabel), jobInfo(label), mode === 'remote' ? jobInfo(tunnelLabel) : '',
        parsePlist(plist(label)).catch(() => undefined), mode === 'usb' ? jobInfo(usbWatchLabel(port)) : '',
      ]);
      return { hostRunning: Boolean(jobPID(host)), managed: Boolean(jobPID(bridge)) &&
          config?.ProgramArguments?.[1] === join(root, 'desktop', 'broker.mjs'),
        tunnelRunning: mode === 'remote' ? Boolean(jobPID(tunnel)) : undefined,
        usbAuto: mode === 'usb' ? Boolean(jobPID(usbWatch)) : undefined };
    },
    async stop(mode, port) {
      if (mode === 'usb') await setUSB(port, false);
      await bootout(labelFor(mode, port));
      await stopBridge(port);
      if (mode === 'remote') {
        const config = await parsePlist(plist(tunnelLabel)).catch(() => undefined);
        if (config?.ProgramArguments?.[1] === join(root, 'scripts', 'run-remote-tunnel.py')) {
          await bootout(tunnelLabel);
          await ctl('disable', job(tunnelLabel));
        }
      }
      await ctl('disable', job(labelFor(mode, port)));
    },
  };
}
