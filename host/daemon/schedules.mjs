import { randomUUID } from 'node:crypto';
import { readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs';

const minute = 60_000;
const day = 24 * 60 * minute;
const grace = 15_000;
const historyLimit = 80;
const runTimeout = 30 * minute;

function nextDaily(time, after) {
  const [hour, minuteOfHour] = time.split(':').map(Number);
  const date = new Date(after);
  date.setHours(hour, minuteOfHour, 0, 0);
  if (+date <= after) date.setDate(date.getDate() + 1);
  // Reset the time after changing dates, including after a DST gap.
  date.setHours(hour, minuteOfHour, 0, 0);
  return +date;
}

function nextOccurrence(job, after) {
  if (job.kind === 'once') return null;
  if (job.kind === 'daily') return nextDaily(job.time, after);
  return job.nextAt + (Math.floor((after - job.nextAt) / (job.interval * minute)) + 1) * job.interval * minute;
}

function latestOccurrence(job, now) {
  if (job.kind === 'once') return job.nextAt;
  if (job.kind === 'interval') return nextOccurrence(job, now) - job.interval * minute;
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  yesterday.setHours(0, 0, 0, 0);
  let latest = nextDaily(job.time, +yesterday - 1);
  const today = nextDaily(job.time, latest);
  if (today <= now) latest = today;
  return Math.max(job.nextAt, latest);
}

function coalescedOccurrences(job, latest) {
  if (job.kind === 'once') return 0;
  if (job.kind === 'interval') return Math.round((latest - job.nextAt) / (job.interval * minute));
  const civilDay = (timestamp) => {
    const date = new Date(timestamp);
    return Date.UTC(date.getFullYear(), date.getMonth(), date.getDate());
  };
  return (civilDay(latest) - civilDay(job.nextAt)) / day;
}

function scheduleFields(input, now) {
  const { kind, time, interval, at, catchUp } = input;
  const name = typeof input.name === 'string' ? input.name.trim() : '';
  const prompt = typeof input.prompt === 'string' ? input.prompt.trim() : '';
  if (!name || name.length > 80 || !prompt || prompt.length > 1600 || prompt.startsWith('/') ||
    !Number.isInteger(catchUp) || catchUp < 0 || catchUp > 1440) return;
  if (kind === 'once' && Number.isSafeInteger(at) && at > now && at <= now + 366 * day) {
    return { name, prompt, kind, at, catchUp, nextAt: at };
  }
  if (kind === 'daily' && typeof time === 'string' && /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(time)) {
    return { name, prompt, kind, time, catchUp, nextAt: nextDaily(time, now) };
  }
  if (kind === 'interval' && Number.isInteger(interval) && interval >= 1 && interval <= 10080) {
    return { name, prompt, kind, interval, catchUp, nextAt: now + interval * minute };
  }
}

export class ScheduleService {
  constructor(file, { registry, runtimes, now = Date.now }) {
    this.file = file;
    this.registry = registry;
    this.runtimes = runtimes;
    this.now = now;
    try { this.state = JSON.parse(readFileSync(file, 'utf8')); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      this.state = { version: 1, source: randomUUID(), jobs: [], runs: [] };
      this.save(this.state);
    }
    if (this.state.version !== 1 || typeof this.state.source !== 'string' ||
      !Array.isArray(this.state.jobs) || !Array.isArray(this.state.runs)) throw new Error('invalid_schedule_store');
    this.closing = false;
    this.running = new Map();
  }

  save(state) {
    const temporary = `${this.file}.${process.pid}.tmp`;
    writeFileSync(temporary, JSON.stringify(state), { mode: 0o600 });
    renameSync(temporary, this.file);
    this.state = state;
  }

  start() {
    for (const run of this.state.runs.filter(({ status }) => status === 'running')) {
      this.finish(run.id, 'interrupted', 'desktop_restarted');
    }
    this.tick();
    this.timer = setInterval(() => {
      try { this.tick(); }
      catch (error) { process.stderr.write(`pi-go scheduler: ${error.message}\n`); }
    }, 2000);
    this.timer.unref();
  }

  stop() {
    this.closing = true;
    clearInterval(this.timer);
    for (const [id] of this.running) this.finish(id, 'interrupted', 'desktop_stopped');
  }

  snapshot(paths, includeJobs, knownRuns) {
    const jobs = this.state.jobs.filter(({ cwd }) => paths.includes(cwd));
    const runs = this.state.runs.filter(({ cwd, status }) => paths.includes(cwd) && status !== 'running');
    return {
      source: this.state.source,
      watching: jobs.some(({ enabled, nextAt }) => enabled && nextAt !== null) ||
        this.state.runs.some(({ cwd, status }) => paths.includes(cwd) && status === 'running') ||
        runs.some(({ id }) => !knownRuns.includes(id)),
      jobs: includeJobs ? jobs : undefined,
      activeRuns: this.state.runs.filter(({ cwd, status }) => paths.includes(cwd) && status === 'running'),
      runs,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone
    };
  }

  workspaceAvailable(cwd) {
    if (!this.registry.list().some(({ path }) => path === cwd)) return false;
    try { return realpathSync(cwd) === cwd; }
    catch { return false; }
  }

  update(input) {
    const { cwd, operation } = input;
    if (!this.workspaceAvailable(cwd)) return [403, { error: 'desktop_workspace_unshared' }];
    if (operation === 'delete-run') {
      if (typeof input.id !== 'string' || !/^[\w:-]{1,117}$/.test(input.id)) return [400, { error: 'invalid_schedule' }];
      const run = this.state.runs.find((row) => row.id === input.id && row.cwd === cwd);
      if (!run) return [200, { deleted: false }];
      if (run.status === 'running') return [409, { error: 'schedule_busy' }];
      this.save({ ...this.state, runs: this.state.runs.filter((row) => row.id !== run.id || row.cwd !== cwd) });
      return [200, { deleted: true }];
    }
    const job = this.state.jobs.find((row) => row.id === input.id && row.cwd === cwd);
    if (operation !== 'create' && !job) return [404, { error: 'schedule_missing' }];
    if (job && job.version !== input.version) return [409, { error: 'schedule_changed' }];
    const now = this.now();
    if (operation === 'run') {
      if (typeof input.requestId !== 'string' || !/^[\w-]{8,64}$/.test(input.requestId)) return [400, { error: 'invalid_schedule' }];
      const previous = this.state.runs.find(({ id }) => id === `${job.id}:manual:${input.requestId}`);
      if (previous) return [200, { run: previous }];
      if (this.running.size >= 3 || [...this.running.values()].includes(job.id)) return [409, { error: 'schedule_busy' }];
      return [200, { run: this.claim(job, now, now, undefined, input.requestId) }];
    }
    let next;
    if (operation === 'create' || operation === 'edit') {
      const schedule = scheduleFields(input, now);
      if (!schedule) return [400, { error: 'invalid_schedule' }];
      if (!job && this.state.jobs.length >= 50) return [409, { error: 'schedule_limit' }];
      next = { ...schedule, id: job?.id ?? randomUUID(), cwd, enabled: job?.enabled ?? true, version: (job?.version ?? 0) + 1 };
    } else if (operation === 'pause' || operation === 'resume') {
      let nextAt = job.nextAt;
      if (operation === 'resume' && (nextAt === null || nextAt <= now)) {
        if (job.kind === 'once') return [409, { error: 'schedule_expired' }];
        nextAt = job.kind === 'daily' ? nextDaily(job.time, now) : now + job.interval * minute;
      }
      next = { ...job, nextAt, enabled: operation === 'resume', version: job.version + 1 };
    } else if (operation !== 'delete') return [400, { error: 'invalid_schedule' }];
    const jobs = this.state.jobs.filter((row) => row.id !== job?.id);
    if (next) jobs.push(next);
    this.save({ ...this.state, jobs });
    return [200, { job: next }];
  }

  pauseWorkspace(cwd) {
    const jobs = this.state.jobs.map((job) => job.cwd === cwd && job.enabled
      ? { ...job, enabled: false, version: job.version + 1 } : job);
    if (jobs.some((job, index) => job !== this.state.jobs[index])) this.save({ ...this.state, jobs });
  }

  tick() {
    if (this.closing) return;
    const now = this.now();
    for (const job of this.state.jobs) {
      if (!job.enabled || job.nextAt === null || job.nextAt > now) continue;
      if (!this.workspaceAvailable(job.cwd)) {
        this.pauseWorkspace(job.cwd);
        this.claim(job, job.nextAt, now, 'workspace_closed');
        continue;
      }
      const latest = latestOccurrence(job, now);
      const reason = now - latest > Math.max(grace, job.catchUp * minute) ? 'missed_window' :
        [...this.running.values()].includes(job.id) ? 'overlap' :
          this.running.size >= 3 ? 'capacity' : undefined;
      this.claim(job, latest, now, reason);
    }
  }

  claim(job, scheduledAt, now, reason, requestId) {
    const id = requestId ? `${job.id}:manual:${requestId}` : `${job.id}:${scheduledAt}`;
    const run = { id, jobId: job.id, cwd: job.cwd, name: job.name, scheduledAt, startedAt: reason ? null : now,
      finishedAt: reason ? now : null, status: reason ? (reason === 'missed_window' ? 'missed' : 'skipped') : 'running',
      coalesced: requestId ? 0 : coalescedOccurrences(job, scheduledAt), reason };
    const jobs = requestId ? this.state.jobs : this.state.jobs.map((row) => row.id === job.id
      ? { ...row, nextAt: nextOccurrence(job, now) } : row);
    const history = [run, ...this.state.runs];
    const recent = history.filter(({ status }) => status !== 'running').slice(0, historyLimit);
    const active = history.filter(({ status }) => status === 'running');
    this.save({ ...this.state, jobs, runs: [...active, ...recent] });
    if (!reason) {
      this.running.set(id, job.id);
      void this.execute(job, run).catch((error) => {
        process.stderr.write(`pi-go scheduler: ${error.message}\n`);
      }).finally(() => { this.running.delete(id); });
    }
    return run;
  }

  finish(id, status, reason, summary) {
    const runs = this.state.runs.map((row) => row.id === id && row.status === 'running'
      ? { ...row, finishedAt: this.now(), status, reason, summary } : row);
    this.save({ ...this.state, runs });
  }

  async execute(job, run) {
    if (!this.workspaceAvailable(job.cwd)) return this.finish(run.id, 'skipped', 'workspace_closed');
    let runtime;
    let result;
    try {
      runtime = this.runtimes.start(job.cwd, undefined, true);
      const { sessionId } = await runtime.awaitReady();
      this.save({ ...this.state, runs: this.state.runs.map((row) => row.id === run.id ? { ...row, sessionId } : row) });
      result = await runtime.runScheduledPrompt(job.prompt, runTimeout);
    } catch {
      result = { reason: runtime?.exited ? 'runtime_exited' : 'prompt_failed' };
    } finally {
      if (runtime) await this.runtimes.stop(runtime);
    }
    this.finish(run.id, result.reason ? 'failed' : 'succeeded', result.reason, result.summary);
  }
}
