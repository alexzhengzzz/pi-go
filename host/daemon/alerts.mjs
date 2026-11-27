import { randomBytes } from 'node:crypto';
import { closeSync, fsyncSync, openSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs';

const alertLimit = 200;
const severities = new Set(['info', 'warn', 'error']);
const idPattern = /^[a-f0-9]{32,64}$/;

function cleanText(value, limit) {
  if (typeof value !== 'string') return '';
  return value.replace(/\r\n?/g, '\n').trim().slice(0, limit);
}

function cleanArtifacts(value) {
  if (!Array.isArray(value)) return undefined;
  const items = [];
  for (const entry of value) {
    if (typeof entry !== 'string') continue;
    const path = entry.trim();
    if (!path || path.length > 512 || path.startsWith('/') || path.includes('..') || /[\u0000-\u001f\u007f\\]/.test(path)) continue;
    if (!items.includes(path)) items.push(path);
    if (items.length >= 8) break;
  }
  return items.length ? items : undefined;
}

function resolveCwd(value) {
  if (value === undefined || value === null || value === '') return { ok: true, cwd: '' };
  if (typeof value !== 'string' || value.length > 1024 || /[\u0000-\u001f\u007f]/.test(value)) return { ok: false };
  try {
    const resolved = realpathSync(value);
    if (!statSync(resolved).isDirectory()) return { ok: false };
    return { ok: true, cwd: resolved };
  } catch {
    return { ok: false };
  }
}

export class AlertService {
  constructor(file, { now = Date.now } = {}) {
    this.file = file;
    this.now = now;
    try {
      this.state = JSON.parse(readFileSync(file, 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      this.state = { version: 1, alerts: [] };
      this.save(this.state);
    }
    if (this.state.version !== 1 || !Array.isArray(this.state.alerts)) {
      throw new Error('invalid_alert_store');
    }
  }

  save(state) {
    const temporary = `${this.file}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
    const fd = openSync(temporary, 'wx', 0o600);
    try {
      writeFileSync(fd, JSON.stringify(state));
      fsyncSync(fd);
      closeSync(fd);
      renameSync(temporary, this.file);
      this.state = state;
    } catch (error) {
      try { closeSync(fd); } catch {}
      try { unlinkSync(temporary); } catch {}
      throw error;
    }
  }

  emit(input) {
    if (!input || typeof input !== 'object') return [400, { error: 'invalid_alert' }];
    const title = cleanText(input.title, 80);
    if (!title) return [400, { error: 'invalid_alert' }];
    const source = cleanText(input.source, 64) || 'local';
    const body = cleanText(input.body, 4000);
    const severity = input.severity === undefined ? 'info' : String(input.severity);
    if (!severities.has(severity)) return [400, { error: 'invalid_alert' }];
    const dedupeKey = cleanText(input.dedupeKey, 128);
    const suggestedPrompt = cleanText(input.suggestedPrompt, 1600);
    const cwdResult = resolveCwd(input.cwd);
    if (!cwdResult.ok) return [400, { error: 'invalid_alert_cwd' }];
    const artifacts = cleanArtifacts(input.artifacts);

    if (dedupeKey) {
      const existing = this.state.alerts.find((row) => row.source === source && row.dedupeKey === dedupeKey);
      if (existing) return [200, { alert: existing, deduplicated: true }];
    }

    const alert = {
      id: randomBytes(16).toString('hex'),
      source,
      title,
      ...(body ? { body } : {}),
      severity,
      ...(dedupeKey ? { dedupeKey } : {}),
      ...(cwdResult.cwd ? { cwd: cwdResult.cwd } : {}),
      ...(suggestedPrompt ? { suggestedPrompt } : {}),
      ...(artifacts ? { artifacts } : {}),
      createdAt: this.now(),
    };
    const alerts = [alert, ...this.state.alerts].slice(0, alertLimit);
    this.save({ ...this.state, alerts });
    return [200, { alert, deduplicated: false }];
  }

  visible(alert, paths) {
    return !alert.cwd || paths.includes(alert.cwd);
  }

  snapshot(paths = []) {
    const allowed = Array.isArray(paths) ? paths.filter((p) => typeof p === 'string') : [];
    return {
      alerts: this.state.alerts.filter((row) => this.visible(row, allowed)),
    };
  }

  remove(id, paths = []) {
    if (typeof id !== 'string' || !idPattern.test(id)) return [400, { error: 'invalid_alert' }];
    const allowed = Array.isArray(paths) ? paths.filter((p) => typeof p === 'string') : [];
    const target = this.state.alerts.find((row) => row.id === id && this.visible(row, allowed));
    if (!target) return [200, { deleted: false }];
    this.save({ ...this.state, alerts: this.state.alerts.filter((row) => row.id !== id) });
    return [200, { deleted: true }];
  }
}
