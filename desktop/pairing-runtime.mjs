import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { unlinkSync } from 'node:fs';
import { ipcDirectory } from './local-ipc.mjs';

// Local discovery is deliberately separate from the workers visible to a paired phone.
export function pairingRuntime(snapshot, share, unshare) {
  const path = join(ipcDirectory(), `gui-${process.pid}-${randomBytes(4).toString('hex')}.sock`);
  const server = createServer({ requestTimeout: 3000, headersTimeout: 3000 }, async (req, res) => {
    const reply = (status, data) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(data)); };
    if (req.headers.origin !== undefined) return reply(403, { error: 'invalid_source' });
    try {
      if (req.method === 'GET' && req.url === '/session') return reply(200, { session: snapshot() });
      if (req.method === 'POST' && ['/share', '/unshare'].includes(req.url)) {
        let body = '';
        for await (const chunk of req) { body += chunk; if (body.length > 512) return reply(400, { error: 'invalid_body' }); }
        if (JSON.parse(body).id !== snapshot()?.id) return reply(409, { error: 'session_changed' });
        if (req.url === '/share') await share(); else unshare();
        return reply(200, { session: snapshot() });
      }
      reply(404, { error: 'not_found' });
    } catch { reply(409, { error: 'session_unavailable' }); }
  });
  server.maxConnections = 4;
  server.setTimeout(4000, (socket) => socket.destroy());
  server.on('error', () => {});
  server.listen(path);
  return () => { server.close(); server.closeAllConnections(); try { unlinkSync(path); } catch {} };
}
