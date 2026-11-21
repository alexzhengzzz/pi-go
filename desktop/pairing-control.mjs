import { spawn, execFile } from 'node:child_process';
import { readFile, readdir, access } from 'node:fs/promises';
import { networkInterfaces } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { ipcDirectory, localRequest } from './local-ipc.mjs';
import { localLanAddress, publicAddress } from './lan-tls.mjs';
const run = promisify(execFile);
const root = dirname(fileURLToPath(import.meta.url));

async function sessions() {
  const directory = ipcDirectory();
  const entries = (await readdir(directory)).filter((name) => /^gui-\d+-[0-9a-f]{8}\.sock$/.test(name)).slice(0, 64);
  const results = await Promise.all(entries.map(async (name) => {
    const socket = join(directory, name);
    try { const r = await localRequest(socket, 'GET', '/session', undefined, 700); return r.status === 200 && r.data.session?.id ? { socket, ...r.data.session } : undefined; }
    catch { return undefined; }
  }));
  return results.filter(Boolean);
}
async function status(port) {
  try {
    const r = await localRequest(join(ipcDirectory(), `bridge-${port}.sock`), 'GET', '/status', undefined, 700);
    if (r.status !== 200 || r.data.protocol !== 'pi-go-pairing/1') throw new Error('旧版桥接服务正在运行，请先在 Desktop 停止旧桥后重试。');
    return { running: true, ...r.data };
  } catch (e) {
    if (['ENOENT', 'ECONNREFUSED'].includes(e.code)) return { running: false };
    throw e;
  }
}
const hdcPath = () => process.env.HDC_BIN || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc';
async function usbTargets() {
  const hdc = hdcPath();
  await access(hdc).catch(() => { throw new Error('未找到 USB 工具，请安装 DevEco Studio，或使用局域网扫码。'); });
  const { stdout } = await run(hdc, ['list', 'targets', '-v'], { timeout: 5000 });
  return stdout.split(/\r?\n/).map((line) => line.trim().split(/\s+/))
    .filter(([, transport, state]) => transport === 'USB' && state === 'Connected')
    .map(([target]) => target);
}
async function usbForwarded(target, port) {
  const endpoint = `tcp:${port}`;
  const { stdout } = await run(hdcPath(), ['-t', target, 'fport', 'ls'], { timeout: 5000 });
  const rule = [target, endpoint, endpoint, '[Reverse]'].join(' ');
  return stdout.split(/\r?\n/).some((line) => line.trim().replace(/\s+/g, ' ') === rule);
}
async function usbForward(port, expectedTarget) {
  const targets = await usbTargets();
  if (!targets.length) throw new Error('未发现手机，请连接 USB 并在手机允许调试。');
  if (targets.length !== 1) throw new Error('请只通过 USB 连接一台手机。');
  const [target] = targets;
  if (expectedTarget !== undefined && expectedTarget !== target) throw new Error('USB 手机已更换，请重新连接。');
  const args = ['-t', target];
  const endpoint = `tcp:${port}`;
  if (!await usbForwarded(target, port)) {
    const result = await run(hdcPath(), [...args, 'rport', endpoint, endpoint], { timeout: 5000 });
    if (/fail|error/i.test(result.stdout + result.stderr)) throw new Error('USB 转发失败，请重新连接手机。');
  }
  return { args, target };
}
async function usbLaunch(args, port, ticket) {
  const parameters = ['-a', 'EntryAbility', '-b', 'com.alex.pigo', '--ps', 'address', `http://127.0.0.1:${port}`];
  if (ticket) parameters.push('--ps', 'ticket', ticket);
  const warning = ticket ? '无法自动打开手机 Pi Go，请确认已安装应用；可手动打开并输入配对码。' :
    '请在手机打开 Pi Go，并选择已保存的 USB 连接。';
  try {
    const launched = await run(hdcPath(), [...args, 'shell', 'aa', 'start', ...parameters], { timeout: 5000 });
    if (/fail|error/i.test(launched.stdout + launched.stderr)) return warning;
  } catch { return warning; }
  return undefined;
}
export async function control(input) {
  const mode = input.mode ?? 'usb';
  if (!['usb', 'lan', 'remote'].includes(mode)) throw new Error('invalid_transport');
  const port = input.port ?? (mode === 'remote' ? 18982 : mode === 'lan' ? 18981 : 18977);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('invalid_port');
  const socket = join(ipcDirectory(), `bridge-${port}.sock`);
  if (input.action === 'usb-target') {
    const targets = await usbTargets();
    if (targets.length !== 1) return {};
    const [target] = targets;
    return { usbTarget: target, usbForwarded: target === input.target && await usbForwarded(target, port) };
  }
  if (input.action === 'refresh') return {
    sessions: await sessions(), addresses: [...new Set(Object.values(networkInterfaces()).flat().filter((e) => e && localLanAddress(e.address)).map((e) => e.address))],
    bridge: await status(port),
  };
  if (input.action === 'share' || input.action === 'unshare') {
    const target = (await sessions()).find((s) => s.socket === input.socket && s.id === input.id);
    if (!target) throw new Error('会话已关闭或已切换，请刷新后重试。');
    const r = await localRequest(target.socket, 'POST', `/${input.action}`, { id: input.id });
    if (r.status !== 200) throw new Error('无法共享会话，请重载 Desktop 会话后重试。');
    return r.data;
  }
  if (input.action === 'pair' || input.action === 'connect') {
    if (mode === 'lan' && !localLanAddress(input.host)) throw new Error('请选择当前电脑的局域网地址。');
    let endpoint;
    if (mode === 'remote') {
      try { endpoint = publicAddress(input.publicIP, Number(input.publicPort)); }
      catch { throw new Error('请输入 VPS 的公网 IPv4，以及 443 或 1024–65535 之间的端口。'); }
    }
    const usb = mode === 'usb' ? await usbForward(port, input.target) : undefined;
    let current = await status(port);
    if (current.running && current.computerAccess === undefined) {
      await localRequest(socket, 'POST', '/stop');
      for (let i = 0; i < 30 && current.running; i++) {
        await new Promise((resolve) => setTimeout(resolve, 100));
        current = await status(port);
      }
      if (current.running) throw new Error('旧服务仍在停止，请稍后重试。');
    }
    if (!current.running) {
      const args = mode === 'remote' ? ['--remote', input.publicIP, String(input.publicPort)] :
        mode === 'lan' ? [input.host] : [];
      const child = spawn(process.execPath, [join(root, 'broker.mjs'), String(port), ...args], { detached: true, stdio: ['ignore', 'ignore', 'pipe'] });
      let failure = '';
      child.stderr.on('data', (chunk) => { failure = (failure + chunk).slice(-2000); });
      child.on('error', (e) => { failure = e.message; });
      let exited = false;
      child.on('exit', () => { exited = true; });
      for (let i = 0; i < 65 && !current.running && !exited; i++) {
        await new Promise((resolve) => setTimeout(resolve, 100));
        current = await status(port);
      }
      child.stderr.destroy(); child.unref();
      if (!current.running) { if (!exited) child.kill(); throw new Error(`桥接启动失败，请检查端口或 OpenSSL。${failure ? '\n' + failure : ''}`); }
    }
    if (current.transport !== mode || (mode === 'lan' && current.host !== input.host) ||
        (mode === 'remote' && current.address !== endpoint)) {
      throw new Error('此端口正在使用其他配置，请先停止服务再连接。');
    }
    if (mode !== 'remote') {
      const access = await localRequest(socket, 'POST', '/computer-access');
      if (access.status !== 200) throw new Error('请停止旧版服务后再连接，以启用电脑全部会话。');
    }
    if (input.action === 'connect' && current.paired) {
      const warning = usb ? await usbLaunch(usb.args, port) : undefined;
      return { warning, usbTarget: usb?.target, bridge: await status(port) };
    }
    const route = mode === 'remote' ? '/ticket-remote' : mode === 'lan' ? '/ticket-lan' : '/ticket';
    const r = await localRequest(socket, 'POST', route, mode === 'lan' ? { host: input.host } : undefined);
    if (r.status !== 200) throw new Error('生成配对码失败。');
    const config = JSON.parse(await readFile(r.data.file, 'utf8'));
    // Deliver the one-time ticket through the same USB debugging channel that
    // launched the app, so the phone pairs without manual code entry.
    const warning = usb ? await usbLaunch(usb.args, port, config.ticket) : undefined;
    return { code: config.code, bundle: config.bundle, warning, usbTarget: usb?.target, bridge: await status(port) };
  }
  if (input.action === 'stop' || input.action === 'revoke') {
    if (mode === 'remote' && (await status(port)).transport !== mode) throw new Error('公网服务未运行。');
    const r = await localRequest(socket, 'POST', input.action === 'stop' ? '/stop' : '/revoke-device');
    if (r.status !== 200) throw new Error('操作失败，请刷新状态后重试。');
    return r.data;
  }
  throw new Error('invalid_action');
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    let data = ''; for await (const chunk of process.stdin) { data += chunk; if (data.length > 8192) throw new Error('invalid_input'); }
    console.log(JSON.stringify({ ok: true, data: await control(JSON.parse(data)) }));
  } catch (error) { console.log(JSON.stringify({ ok: false, error: error.message })); process.exitCode = 1; }
}
