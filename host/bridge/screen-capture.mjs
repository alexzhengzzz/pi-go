import { access, mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { maxHistoryImageBase64 } from './attachments.mjs';

const captureFailed = 'Mac 截图失败。请检查 Mac 桌面是否可用，并确认 Pi Go.app 已获得录屏权限。';
const captureErrors = new Map([
  ['permission_denied', '请在 Mac 上打开 Pi Go.app，选择菜单「Pi Go → 授权电脑截图」，然后在系统设置中允许 Pi Go 录制屏幕。'],
  ['display_unavailable', '找不到主显示器。请保持 Mac 已登录且桌面可用。'],
]);

export async function captureMainDisplay(pi, signal) {
  const apps = process.env.PIGO_SCREEN_CAPTURE_APP ? [process.env.PIGO_SCREEN_CAPTURE_APP] :
    ['/Applications/Pi Go.app', join(homedir(), 'Applications', 'Pi Go.app')];
  let app;
  for (const candidate of apps) {
    if (await access(join(candidate, 'Contents', 'Resources', 'screen-capture-v1')).then(() => true, () => false)) {
      app = candidate;
      break;
    }
  }
  if (!app) throw new Error('请构建新版 Pi Go.app 并安装到「应用程序」后再截图。');

  signal?.throwIfAborted();
  const directory = await mkdtemp(join(tmpdir(), 'pigo-screen-'));
  try {
    signal?.throwIfAborted();
    const launch = await pi.exec('/usr/bin/open', ['-n', '-g', '-j', '-a', app, '--args', '--pigo-screen-capture', directory],
      { signal, timeout: 5000 });
    signal?.throwIfAborted();
    if (launch.code !== 0) throw new Error('无法在 Mac 桌面启动 Pi Go 截图。请确认 Mac 已登录且 Pi Go.app 可正常打开。');

    // LaunchServices may lose track of a short-lived app with `open -W`.
    // The app publishes the status atomically after it finishes writing the image.
    const statusPath = join(directory, 'status');
    const deadline = performance.now() + 16_000;
    let status;
    while (performance.now() < deadline) {
      status = await readFile(statusPath, { encoding: 'utf8', signal }).catch((error) => {
        if (error.code !== 'ENOENT') throw error;
      });
      if (status !== undefined) break;
      await delay(100, undefined, { signal });
    }
    if (status === undefined) throw new Error('等待 Mac 截图超时。请确认 Mac 已登录并重试。');
    if (status !== 'ok') throw new Error(captureErrors.get(status) ?? captureFailed);
    const path = join(directory, 'screenshot.jpg');
    const file = await stat(path).catch(() => undefined);
    if (!file?.isFile() || file.size === 0) throw new Error(captureFailed);
    if (Math.ceil(file.size / 3) * 4 > maxHistoryImageBase64) throw new Error('Mac 截图超过图片大小限制。');
    const image = await readFile(path, { signal });
    return { type: 'image', mimeType: 'image/jpeg', data: image.toString('base64') };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
