import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test } from 'node:test';
import { promisify } from 'node:util';
import { AlertService } from '../host/daemon/alerts.mjs';
import { createDaemonHost } from '../host/daemon/host.mjs';
import { WorkspaceRegistry } from '../host/daemon/registry.mjs';
import { pushMessage } from '../host/bridge/run-push.mjs';

const execFileAsync = promisify(execFile);
const notifyCli = resolve('host/scripts/pigo-notify.mjs');

test('AlertService persists, deduplicates, filters by workspace, and deletes alerts', () => {
  const root = mkdtempSync(join(tmpdir(), 'pigo-alerts-'));
  const wsA = join(root, 'ws-a');
  const wsB = join(root, 'ws-b');
  mkdirSync(wsA);
  mkdirSync(wsB);
  const realA = realpathSync(wsA);
  const realB = realpathSync(wsB);
  let clock = 1764255000000;
  try {
    const storeFile = join(root, 'alerts.json');
    const service = new AlertService(storeFile, { now: () => ++clock });

    const [s1, d1] = service.emit({
      source: 'monitor',
      dedupeKey: 'sig-1',
      title: '构建失败',
      body: 'main 分支单测失败 2 项',
      severity: 'error',
      cwd: wsA,
      suggestedPrompt: '查看最新失败日志并修复',
    });
    assert.equal(s1, 200);
    assert.equal(d1.deduplicated, false);
    assert.match(d1.alert.id, /^[a-f0-9]{32}$/);
    assert.equal(d1.alert.cwd, realA);

    // Same source + dedupeKey is idempotent
    const [sDup, dDup] = service.emit({
      source: 'monitor',
      dedupeKey: 'sig-1',
      title: '构建失败（重复）',
      cwd: wsA,
    });
    assert.equal(sDup, 200);
    assert.equal(dDup.deduplicated, true);
    assert.equal(dDup.alert.id, d1.alert.id);

    // Global alert (no cwd) and wsB alert
    const [, dGlobal] = service.emit({ source: 'cron', title: '磁盘剩余不足 10%' });
    const [, dOther] = service.emit({ source: 'other', title: '其他工作区事件', cwd: wsB });

    // Workspace scoping: wsA sees wsA + global, not wsB
    const snapA = service.snapshot([realA]);
    assert.deepEqual(snapA.alerts.map((a) => a.id).sort(), [d1.alert.id, dGlobal.alert.id].sort());
    assert.ok(!snapA.alerts.some((a) => a.id === dOther.alert.id));

    // Reload from disk preserves state
    const reloaded = new AlertService(storeFile);
    assert.equal(reloaded.snapshot([realA, realB]).alerts.length, 3);

    // Delete enforces visibility
    const [sDelDenied, dDelDenied] = reloaded.remove(dOther.alert.id, [realA]);
    assert.equal(sDelDenied, 200);
    assert.equal(dDelDenied.deleted, false);
    const [sDelOk, dDelOk] = reloaded.remove(d1.alert.id, [realA]);
    assert.equal(sDelOk, 200);
    assert.equal(dDelOk.deleted, true);
    assert.equal(reloaded.snapshot([realA]).alerts.length, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('pushMessage passes alert title and body through for lockscreen/watch visibility', () => {
  const payload = pushMessage({
    id: 'a'.repeat(32),
    status: 'alert',
    title: '600519.SH MACD金叉',
    body: '15m DIF 上穿 DEA，差值 +0.42',
    source: 'stock-dashboard',
    sessionId: '',
  }, { device: 'b'.repeat(64), token: 't'.repeat(40) }, false);

  assert.equal(payload.payload.notification.title, '600519.SH MACD金叉');
  assert.equal(payload.payload.notification.body, '15m DIF 上穿 DEA，差值 +0.42');
  assert.equal(payload.payload.notification.clickAction.data.pigoPushEvent, 'a'.repeat(32));
  assert.equal(payload.payload.notification.clickAction.data.pigoPushSession, '');
});

test('pigo-notify CLI emits alerts to a live daemon host over Unix socket', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pigo-notify-cli-'));
  const ipcDir = join(root, 'ipc');
  const wsDir = join(root, 'workspace');
  mkdirSync(ipcDir, { mode: 0o700 });
  mkdirSync(wsDir);
  const prevIpc = process.env.PIGO_IPC_DIR;
  process.env.PIGO_IPC_DIR = ipcDir;

  const registry = new WorkspaceRegistry(join(root, 'workspaces.json'));
  const alerts = new AlertService(join(root, 'alerts.json'));
  const runtimes = { list: () => [], find: () => undefined, killFor: async () => {} };
  const host = createDaemonHost({ registry, runtimes, alerts });

  await new Promise((resolveListen, rejectListen) => {
    host.server.once('error', rejectListen);
    host.server.listen(host.path, () => { host.server.off('error', rejectListen); resolveListen(); });
  });

  try {
    const { stdout } = await execFileAsync(process.execPath, [
      notifyCli,
      '--source', 'test-script',
      '--title', '脚本命中提醒',
      '--body', '阈值已触发',
      '--dedupe', 'cli-1',
      '--cwd', wsDir,
      '--prompt', '帮我分析原因',
    ], { env: { ...process.env, PIGO_IPC_DIR: ipcDir } });

    const parsed = JSON.parse(stdout);
    assert.equal(parsed.deduplicated, false);
    assert.equal(parsed.alert.title, '脚本命中提醒');
    assert.equal(parsed.alert.source, 'test-script');
    assert.equal(parsed.alert.suggestedPrompt, '帮我分析原因');
    assert.equal(alerts.snapshot([realpathSync(wsDir)]).alerts.length, 1);
  } finally {
    host.shutdown();
    if (prevIpc === undefined) delete process.env.PIGO_IPC_DIR;
    else process.env.PIGO_IPC_DIR = prevIpc;
    rmSync(root, { recursive: true, force: true });
  }
});
