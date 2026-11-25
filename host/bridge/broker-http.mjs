// Shared HTTP helpers, compression, body parsing, auth matching, and remote rate limiting for broker.mjs.
import { createHash, timingSafeEqual } from 'node:crypto';
import { gzipSync } from 'node:zlib';

export const digest = (text) => createHash('sha256').update(text).digest();

export const matches = (text, expected) =>
  typeof text === 'string' && expected !== undefined && timingSafeEqual(digest(text), expected);

export function reply(response, status, value) {
  const payload = JSON.stringify(value);
  const acceptEncoding = response.req?.headers?.['accept-encoding'];
  if (typeof acceptEncoding === 'string' && acceptEncoding.includes('gzip') && payload.length >= 1024) {
    const compressed = gzipSync(payload);
    response.writeHead(status, {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
      'Content-Encoding': 'gzip',
      'Vary': 'Accept-Encoding',
      'Content-Length': compressed.length,
    });
    response.end(compressed);
    return;
  }
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(payload);
}

export const error = (response, status, code) => reply(response, status, { error: code });

export function createRemoteLimiter({ maxBudget = 40, refillPerMs = 0.012, maxInFlight = 10 } = {}) {
  let requests = 0;
  let budget = maxBudget;
  let budgetAt = performance.now();
  return function acceptRemoteRequest(response) {
    const now = performance.now();
    budget = Math.min(maxBudget, budget + (now - budgetAt) * refillPerMs);
    budgetAt = now;
    if (budget < 1 || requests >= maxInFlight) {
      response.setHeader('Retry-After', '1');
      error(response, 429, 'too_many_requests');
      return false;
    }
    budget -= 1;
    requests += 1;
    response.once('close', () => { requests -= 1; });
    return true;
  };
}

export function workerPath(path, session, { remote = false, requireTarget = false } = {}) {
  if (!remote && !requireTarget) return path;
  const url = new URL(path, 'http://pi-go');
  url.searchParams.set('_pigoSession', session.id);
  url.searchParams.set('_pigoCwd', session.cwd);
  return url.pathname + url.search;
}

export async function body(request, limit = 16384) {
  if (request.headers['content-type'] !== 'application/json') throw new Error('invalid_content_type');
  if (Number(request.headers['content-length']) > limit) throw new Error('oversized_body');
  const chunks = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new Error('oversized_body');
    chunks.push(chunk);
  }
  const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_body');
  return value;
}

export async function rawBody(request, limit) {
  if (request.headers['content-type'] !== 'application/octet-stream') throw new Error('invalid_content_type');
  if (Number(request.headers['content-length']) > limit) throw new Error('oversized_body');
  const chunks = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > limit) throw new Error('oversized_body');
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks);
  if (bytes.length < 1 || bytes.length > limit) throw new Error('oversized_body');
  return bytes;
}
