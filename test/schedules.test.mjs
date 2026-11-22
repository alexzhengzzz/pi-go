import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { ScheduleService } from '../host/daemon/schedules.mjs';

const minute = 60_000;
const settings = { name: 'Digest', prompt: 'Summarize work', operation: 'create' };

test('wake-up coalesces missed intervals and keeps the original cadence', async (context) => {
  const cwd = realpathSync(mkdtempSync(join(tmpdir(), 'pigo-schedules-')));
  context.after(() => rmSync(cwd, { force: true, recursive: true }));
  const initial = Date.UTC(2026, 10, 23, 8);
  let now = initial;
  const prompts = [];
  const service = new ScheduleService(join(cwd, 'schedules.json'), {
    registry: { list: () => [{ path: cwd }] },
    runtimes: {
      start: () => ({
        awaitReady: async () => ({ sessionId: 'fixture' }),
        runScheduledPrompt: async (prompt) => { prompts.push(prompt); return { summary: 'Done' }; }
      }),
      stop: async () => {}
    },
    now: () => now
  });
  const [, repeating] = service.update({ ...settings, cwd, kind: 'interval', interval: 30, catchUp: 20 });
  const [, oneTime] = service.update({ ...settings, cwd, kind: 'once', at: initial + minute, catchUp: 0 });
  now = initial + 105 * minute;
  service.tick();
  await new Promise((resolve) => setImmediate(resolve));
  const { jobs, runs } = service.snapshot([cwd], true, []);
  const catchUp = runs.find(({ jobId }) => jobId === repeating.job.id);
  assert.equal(catchUp.status, 'succeeded');
  assert.equal(catchUp.scheduledAt, initial + 90 * minute);
  assert.equal(catchUp.coalesced, 2);
  assert.equal(jobs.find(({ id }) => id === repeating.job.id).nextAt, initial + 120 * minute);
  assert.equal(runs.find(({ jobId }) => jobId === oneTime.job.id).status, 'missed');
  assert.deepEqual(prompts, [settings.prompt]);
  assert.deepEqual(service.snapshot([], true, []).runs, []);
  assert.equal(service.update({ operation: 'pause', cwd, id: repeating.job.id, version: 0 })[0], 409);
});

test('restart recovers the claimed run without repeating its prompt', async (context) => {
  const cwd = realpathSync(mkdtempSync(join(tmpdir(), 'pigo-schedules-')));
  context.after(() => rmSync(cwd, { force: true, recursive: true }));
  const file = join(cwd, 'schedules.json');
  let now = Date.UTC(2026, 10, 23, 8);
  const at = now + minute;
  let prompts = 0;
  const options = {
    registry: { list: () => [{ path: cwd }] },
    runtimes: { start: () => ({
      awaitReady: async () => ({ sessionId: 'fixture' }),
      runScheduledPrompt: () => { prompts += 1; return new Promise(() => {}); },
      kill() {}
    }) },
    now: () => now
  };
  const original = new ScheduleService(file, options);
  original.update({ ...settings, cwd, kind: 'once', at, catchUp: 5 });
  now = at;
  original.tick();
  await new Promise((resolve) => setImmediate(resolve));
  const resumed = new ScheduleService(file, options);
  resumed.start();
  context.after(() => resumed.stop());
  const snapshot = resumed.snapshot([cwd], true, []);
  assert.equal(snapshot.runs.length, 1);
  assert.equal(snapshot.runs[0].status, 'interrupted');
  assert.equal(snapshot.runs[0].reason, 'desktop_restarted');
  assert.equal(snapshot.jobs[0].nextAt, null);
  assert.equal(prompts, 1);
  assert.equal(resumed.snapshot([cwd], false, [snapshot.runs[0].id]).watching, false);
});
