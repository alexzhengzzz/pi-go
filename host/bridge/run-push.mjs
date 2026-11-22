import { constants, createHash, createPrivateKey, randomBytes, sign } from 'node:crypto';
import { lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { stateDirectory } from './session-metadata.mjs';

const validId = /^[a-f0-9]{64}$/;
const validToken = /^[\w+/=.-]{32,512}$/;
const retention = 24 * 60 * 60 * 1000;
const recent = 60 * 60 * 1000;

function readPrivate(path, limit) {
  try {
    const info = lstatSync(path);
    if (info.isFile() && info.uid === process.getuid() && !(info.mode & 0o077) && info.size <= limit) {
      return JSON.parse(readFileSync(path, 'utf8'));
    }
  } catch {}
}

function writePrivate(path, value) {
  const temporary = `${path}.${randomBytes(6).toString('hex')}`;
  try {
    writeFileSync(temporary, JSON.stringify(value), { flag: 'wx', mode: 0o600 });
    renameSync(temporary, path);
  } finally { try { unlinkSync(temporary); } catch {} }
}

const hash = (value) => createHash('sha256').update(value).digest('hex');
const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');

export function loadPushAccount() {
  const account = readPrivate(process.env.PIGO_PUSH_ACCOUNT_FILE ?? join(stateDirectory(), 'push-service-account.json'), 20 * 1024);
  if (!account || !/^\d{5,32}$/.test(account.project_id) || !account.key_id ||
      !account.sub_account || !account.private_key) return;
  try {
    return { project: account.project_id, keyId: account.key_id, issuer: account.sub_account,
      privateKey: createPrivateKey(account.private_key), test: account.testMessage === true };
  } catch {}
}

function authorization(account) {
  const now = Math.floor(Date.now() / 1000);
  const header = encode({ alg: 'PS256', typ: 'JWT', kid: account.keyId });
  const claims = encode({ aud: 'https://oauth-login.cloud.huawei.com/oauth2/v3/token',
    iss: account.issuer, iat: now, exp: now + 3600 });
  const payload = `${header}.${claims}`;
  const signature = sign('sha256', Buffer.from(payload), { key: account.privateKey,
    padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: constants.RSA_PSS_SALTLEN_DIGEST });
  return `Bearer ${payload}.${signature.toString('base64url')}`;
}

export function pushMessage(event, subscription, test) {
  const status = { completed: '任务已完成', failed: '任务运行失败', stopped: '任务已停止', waiting: '任务等待你的处理' };
  return {
    payload: { notification: { category: 'WORK', title: 'Pi Go', body: status[event.status],
      appMessageId: hash(event.id).slice(0, 32),
      clickAction: { actionType: 0, data: { pigoPushDevice: subscription.device, pigoPushEvent: event.id,
        pigoPushSession: event.sessionId || '', pigoPushPending: event.status === 'waiting' ? event.pendingId : '' } } } },
    target: { token: [subscription.token] },
    pushOptions: { ttl: event.status === 'waiting' ? 120 : 3600, ...(test ? { testMessage: true } : {}) }
  };
}

export class RunPush {
  constructor(pairingPath, options = {}) {
    this.account = options.account ?? loadPushAccount();
    this.fetch = options.fetch ?? globalThis.fetch;
    this.now = options.now ?? Date.now;
    this.path = pairingPath + '.push';
    this.marks = join(stateDirectory(), 'push-delivery');
    this.lastPrune = 0;
  }

  subscription(bearer) {
    const row = bearer && readPrivate(this.path, 2048);
    if (row?.bearer === bearer && row && validToken.test(row.token) && validId.test(row.device)) return row;
  }

  register(bearer, input) {
    if (!input || typeof input.enabled !== 'boolean') return [400, { error: 'invalid_push_registration' }];
    if (!input.enabled) {
      if (this.subscription(bearer)) this.clear();
      return [200, { pushAvailable: Boolean(this.account) }];
    }
    if (typeof input.token !== 'string' || !validToken.test(input.token) ||
        typeof input.device !== 'string' || !validId.test(input.device)) return [400, { error: 'invalid_push_registration' }];
    if (!this.account) return [200, { pushAvailable: false }];
    const old = this.subscription(bearer);
    if (old?.token !== input.token || old.device !== input.device) {
      writePrivate(this.path, { token: input.token, device: input.device, bearer, since: this.now() });
    }
    return [200, { pushAvailable: true }];
  }

  clear() {
    try { unlinkSync(this.path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }

  async deliver(events, bearer, stillPaired) {
    if (!this.account || this.sending) return;
    const subscription = this.subscription(bearer);
    if (!subscription) return;
    this.sending = true;
    try {
      mkdirSync(this.marks, { mode: 0o700, recursive: true });
      const mode = lstatSync(this.marks);
      if (!mode.isDirectory() || mode.uid !== process.getuid() || mode.mode & 0o077) return;
      this.prune();
      const now = this.now();
      for (const event of events.filter((row) => row.finishedAt >= Math.max(subscription.since, now - recent))) {
        const current = this.subscription(bearer);
        if (!stillPaired() || current?.device !== subscription.device || current.token !== subscription.token) break;
        await this.deliverOne(event, subscription);
      }
    } finally { this.sending = false; }
  }

  async deliverOne(event, subscription) {
    const path = join(this.marks, hash(JSON.stringify([subscription.token, event.id])) + '.json');
    const lock = path + '.lock';
    if (readPrivate(path, 128)?.delivered === true) return;
    try {
      writeFileSync(lock, '', { flag: 'wx', mode: 0o600 });
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try { if (this.now() - lstatSync(lock).mtimeMs > 30_000) unlinkSync(lock); } catch {}
      return;
    }
    try {
      if (readPrivate(path, 128)?.delivered === true) return;
      const response = await this.fetch(`https://push-api.cloud.huawei.com/v3/${this.account.project}/messages:send`, {
        method: 'POST', signal: AbortSignal.timeout(5000),
        headers: { Authorization: authorization(this.account), 'Content-Type': 'application/json', 'push-type': '0' },
        body: JSON.stringify(pushMessage(event, subscription, this.account.test))
      });
      const outcome = await response.json();
      if (response.ok && outcome.code === '80000000') writePrivate(path, { delivered: true });
    } catch { /* Recent events remain eligible on the next poll. */ }
    finally { try { unlinkSync(lock); } catch {} }
  }

  prune() {
    if (this.now() - this.lastPrune < recent) return;
    this.lastPrune = this.now();
    for (const file of readdirSync(this.marks)) {
      if (!/^[a-f0-9]{64}\.json(?:\.lock)?$/.test(file)) continue;
      const path = join(this.marks, file);
      try { if (this.now() - lstatSync(path).mtimeMs > retention) unlinkSync(path); } catch {}
    }
  }
}
