import assert from 'node:assert/strict';
import { constants, generateKeyPairSync, verify } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { RunPush } from '../host/bridge/run-push.mjs';

test('Push Kit signs requests and deduplicates a retried event across paired transports', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'pigo-push-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  process.env.PIGO_STATE_DIR = directory;
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const account = { project: '12345', keyId: 'key-id', issuer: 'service-account', privateKey, test: true };
  const requests = [];
  const fetch = async (url, options) => {
    const [, jwt] = options.headers.Authorization.split(' ');
    const [header, claims, signature] = jwt.split('.');
    assert.equal(verify('sha256', Buffer.from(`${header}.${claims}`), {
      key: publicKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32
    }, Buffer.from(signature, 'base64url')), true);
    assert.equal(JSON.parse(Buffer.from(header, 'base64url')).alg, 'PS256');
    assert.equal(JSON.parse(Buffer.from(claims, 'base64url')).iss, account.issuer);
    requests.push({ url, body: JSON.parse(options.body) });
    if (requests.length === 1) throw new Error('network down');
    return { ok: true, json: async () => ({ code: '80000000' }) };
  };
  const bridgeA = new RunPush(join(directory, 'pair-a.json'), { account, fetch });
  const bridgeB = new RunPush(join(directory, 'pair-b.json'), { account, fetch });
  const register = { enabled: true, token: 't'.repeat(112), device: 'a'.repeat(64) };
  assert.equal(bridgeA.register('bearer-a', register)[0], 200);
  assert.equal(bridgeB.register('bearer-b', { ...register, device: 'b'.repeat(64) })[0], 200);
  const event = { id: 'e'.repeat(32), sessionId: 'opaque-session', status: 'waiting',
    title: 'Confidential title', cwd: '/private/repo', pendingId: 'question-id', finishedAt: Date.now() };
  await bridgeA.deliver([event], 'revoked', () => false);
  assert.equal(requests.length, 0);
  await bridgeA.deliver([event], 'bearer-a', () => true);
  await Promise.all([bridgeA.deliver([event], 'bearer-a', () => true),
    bridgeB.deliver([event], 'bearer-b', () => true)]);
  await bridgeB.deliver([event], 'bearer-b', () => true);
  assert.equal(requests.length, 2);
  const { body } = requests[1];
  assert.equal(requests[1].url, 'https://push-api.cloud.huawei.com/v3/12345/messages:send');
  assert.equal(body.pushOptions.testMessage, true);
  assert.equal(body.payload.notification.clickAction.data.pigoPushPending, 'question-id');
  assert.doesNotMatch(JSON.stringify(body), /Confidential|\/private\/repo/);
  assert.equal(body.pushOptions.ttl, 120);
  assert.equal(bridgeA.register('bearer-a', { enabled: false })[0], 200);
  assert.equal(bridgeA.subscription('bearer-a'), undefined);
});
