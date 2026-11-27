import assert from 'node:assert/strict';
import { test } from 'node:test';
import './harmony-modules.mjs';

const { PiGoClient } = await import('../harmony/entry/src/main/ets/model/PiGoClient.ets');
const { BridgeFailure } = await import('../harmony/entry/src/main/ets/model/PiGoTypes.ets');

test('bridge requests retain the endpoint, bearer, certificate pin and slow-operation timeout', async (context) => {
  const calls = [];
  let destroyed = false;
  context.after(() => { delete globalThis.pigoTestHttp; });
  globalThis.pigoTestHttp = {
    createHttp: () => ({
      async request(url, opts) {
        calls.push({ url, opts });
        return { responseCode: 401, result: '{"error":"not_paired"}' };
      },
      destroy() { destroyed = true; }
    })
  };
  const endpoint = { address: 'https://192.168.1.50:18981', token: 'test', ca: 'ca', pin: 'pin' };
  await assert.rejects(new PiGoClient().request(endpoint, '/open', { id: 'one' }),
    error => error instanceof BridgeFailure && error.status === 401 && error.message === 'not_paired');
  const [{ url, opts }] = calls;
  assert.equal(url, endpoint.address + '/open');
  assert.equal(opts.method, 'POST');
  assert.equal(opts.header.Authorization, 'Bearer test');
  assert.equal(opts.extraData, '{"id":"one"}');
  assert.equal(opts.maxRedirects, 0);
  assert.equal(opts.readTimeout, 16000);
  assert.equal(opts.caData, 'ca');
  assert.deepEqual(opts.certificatePinning, { hashAlgorithm: 'SHA-256', publicKeyHash: 'pin' });
  assert.equal(destroyed, true);
});

test('bridge skips TLS verification only for /pair when skipTlsVerify is set', async (context) => {
  const calls = [];
  context.after(() => { delete globalThis.pigoTestHttp; });
  globalThis.pigoTestHttp = {
    createHttp: () => ({
      async request(url, opts) {
        calls.push({ url, opts });
        return { responseCode: 200, result: '{"token":"' + 'a'.repeat(64) + '"}' };
      },
      destroy() {}
    })
  };
  const endpoint = { address: 'https://192.168.1.50:18981', token: '', skipTlsVerify: true };
  await new PiGoClient().request(endpoint, '/pair', { ticket: '123456' });
  await new PiGoClient().request(endpoint, '/chat');
  assert.equal(calls[0].opts.remoteValidation, 'skip');
  assert.equal(calls[1].opts.remoteValidation, undefined);
});

test('SSE assembles split UTF-8 frames and stops dispatching after the stream changes', async (context) => {
  const events = new Map();
  const frames = [];
  let current = true;
  let ready = 0;
  const response = Promise.withResolvers();
  context.after(() => { delete globalThis.pigoTestHttp; });
  globalThis.pigoTestHttp = {
    createHttp: () => ({
      on(event, handler) { events.set(event, handler); },
      requestInStream(url, opts) {
        assert.equal(url, 'http://127.0.0.1:18977/events?sync=2');
        assert.equal(opts.header.Accept, 'text/event-stream');
        return response.promise;
      }
    })
  };
  new PiGoClient().openEvents({ address: 'http://127.0.0.1:18977', token: 'test' }, '/events?sync=2', {
    current: () => current,
    ready: () => { ready++; },
    frame: frame => { frames.push(frame); current = false; },
    closed: () => assert.fail('the stale stream should not schedule a reconnect'),
    revoked: () => assert.fail('the stale stream should not revoke pairing'),
  });
  events.get('headersReceive')({});
  const bytes = new TextEncoder().encode('data: 中\n\ndata: stale\n\n');
  events.get('dataReceive')(bytes.slice(0, 7).buffer);
  assert.deepEqual(frames, []);
  events.get('dataReceive')(bytes.slice(7).buffer);
  events.get('dataEnd')();
  response.resolve(401);
  await response.promise;
  assert.equal(ready, 1);
  assert.deepEqual(frames, ['中']);
});
