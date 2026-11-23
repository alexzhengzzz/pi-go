import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { captureMainDisplay } from '../host/bridge/screen-capture.mjs';

test('Pi launches the native capture app and handles its result and permissions', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'pigo-capture-test-'));
  const app = join(root, 'Pi Go.app');
  const resources = join(app, 'Contents', 'Resources');
  const originalApp = process.env.PIGO_SCREEN_CAPTURE_APP;
  process.env.PIGO_SCREEN_CAPTURE_APP = app;
  t.after(async () => {
    if (originalApp === undefined) delete process.env.PIGO_SCREEN_CAPTURE_APP;
    else process.env.PIGO_SCREEN_CAPTURE_APP = originalApp;
    await rm(root, { recursive: true, force: true });
  });

  await assert.rejects(captureMainDisplay({}), /构建新版 Pi Go.app/);
  await mkdir(resources, { recursive: true });
  await writeFile(join(resources, 'screen-capture-v1'), '');
  const image = (await readFile(new URL('./prompt-image.base64', import.meta.url), 'utf8')).trim();
  let resultDirectory;
  const pi = {
    async exec(binary, args) {
      assert.equal(binary, '/usr/bin/open');
      resultDirectory = args.at(-1);
      assert.deepEqual(args.slice(0, -1), ['-n', '-g', '-j', '-a', app, '--args', '--pigo-screen-capture']);
      assert.equal((await stat(resultDirectory)).mode & 0o777, 0o700);
      await writeFile(join(resultDirectory, 'screenshot.jpg'), Buffer.from(image, 'base64'));
      await writeFile(join(resultDirectory, 'status'), 'ok');
      return { code: 0 };
    },
  };
  assert.deepEqual(await captureMainDisplay(pi), { type: 'image', mimeType: 'image/jpeg', data: image });
  await assert.rejects(stat(resultDirectory), { code: 'ENOENT' });

  const denied = {
    async exec(_binary, args) {
      resultDirectory = args.at(-1);
      await writeFile(join(resultDirectory, 'status'), 'permission_denied');
      return { code: 0 };
    },
  };
  await assert.rejects(captureMainDisplay(denied), /允许 Pi Go 录制屏幕/);
  await assert.rejects(stat(resultDirectory), { code: 'ENOENT' });

  const controller = new AbortController();
  const cancelled = {
    async exec(_binary, args, { signal }) {
      resultDirectory = args.at(-1);
      assert.equal(signal, controller.signal);
      controller.abort();
      return { killed: true };
    },
  };
  await assert.rejects(captureMainDisplay(cancelled, controller.signal), { name: 'AbortError' });
  await assert.rejects(stat(resultDirectory), { code: 'ENOENT' });
});
