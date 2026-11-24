import assert from 'node:assert/strict';
import { test } from 'node:test';
import './harmony-modules.mjs';

const { WatchReminderController, watchReminderText, watchReminderStatusText } =
  await import('../harmony/entry/src/main/ets/WatchReminders.ets');

function fakeWearEngine(devices, notify = async () => {}) {
  globalThis.pigoTestWearEngine = {
    NotificationType: { NOTIFICATION_WITHOUT_BUTTONS: 50 },
    WearEngineCapability: { NOTIFICATION: 3 },
    getDeviceClient: () => ({ getConnectedDevices: async () => devices }),
    getNotifyClient: () => ({ notify }),
  };
}

function capableDevice(randomId = 'watch-1') {
  return { randomId, isWearEngineCapabilitySupported: async capability => capability === 3 };
}

test('watch reminders are sent without a watch app and deduplicated across restores', async () => {
  const calls = [];
  const delivered = [];
  fakeWearEngine([capableDevice()], async (deviceId, options) => calls.push({ deviceId, options }));
  const controller = new WatchReminderController(() => true);
  controller.attach({}, status => delivered.push(`status:${status}`), id => delivered.push(id));
  const reminder = { id: 'inbox:run-1', title: 'Pi Go · 已完成', text: '已完成 · Mac\nFix the build' };
  controller.notify(reminder);
  controller.notify(reminder);
  await controller.flush();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].deviceId, 'watch-1');
  assert.equal(calls[0].options.notification.bundleName, 'com.alex.pigo');
  assert.equal(calls[0].options.notification.type, 50);
  assert.equal(calls[0].options.notification.text, reminder.text);
  assert.ok(delivered.includes('inbox:run-1'));
  assert.equal(delivered.at(-1), 'status:ready');

  controller.notify(reminder);
  await controller.flush();
  assert.equal(calls.length, 1);

  const restored = new WatchReminderController(() => true);
  restored.restore(delivered.filter(id => id.startsWith('inbox:')));
  restored.attach({}, () => {}, () => {});
  restored.notify(reminder);
  await restored.flush();
  assert.equal(calls.length, 1);
});

test('watch reminders can be disabled and the test action reports a connected device', async () => {
  const calls = [];
  fakeWearEngine([capableDevice()], async (...args) => calls.push(args));
  const controller = new WatchReminderController(() => true, () => 1234);
  controller.setEnabled(false);
  controller.attach({}, () => {}, () => {});
  controller.notify({ id: 'run', title: 'Pi Go', text: 'done' });
  await controller.test();
  assert.equal(calls.length, 0);

  const statuses = [];
  controller.setEnabled(true);
  controller.attach({}, status => statuses.push(status), () => {});
  await controller.test();
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1].notification.text, 'Pi Go 手表提醒已开启');
  assert.equal(statuses.at(-1), 'ready');
});

test('watch status explains missing service permission and unavailable system capability', async () => {
  globalThis.pigoTestWearEngine = {
    getDeviceClient: () => ({ getConnectedDevices: async () => { throw { code: 1008500004 }; } }),
  };
  let status = '';
  const service = new WatchReminderController(() => true);
  service.attach({}, value => { status = value; }, () => {});
  await service.flush();
  assert.equal(status, 'service');
  assert.match(watchReminderStatusText(status), /AppGallery Connect/);

  status = '';
  const unsupported = new WatchReminderController(() => false);
  unsupported.attach({}, value => { status = value; }, () => {});
  await unsupported.flush();
  assert.equal(status, 'unsupported');
});

test('watch reminder text stays below the 400 byte API limit', () => {
  const text = watchReminderText('运行失败', '开发电脑', '超'.repeat(500));
  assert.ok(new TextEncoder().encode(text).length < 400);
  assert.ok(text.startsWith('运行失败 · 开发电脑\n'));
});
