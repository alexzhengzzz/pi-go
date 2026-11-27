import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { validSecureAddress } from '../PairingCode';
import { BridgeFailure } from './PiGoTypes';
import type { BridgeEndpoint, BridgeReply, Payload, UploadedAttachment } from './PiGoTypes';
import { MAX_DOWNLOAD_BYTES, MAX_DOWNLOAD_ERROR_BYTES } from './PiGoConstants';

export interface BridgeEvents {
  current: () => boolean;
  ready: () => void;
  frame: (payload: string) => void;
  closed: (retryDelay: number) => void;
  revoked: () => void;
}

export class PiGoClient {
  async request(endpoint: BridgeEndpoint, path: string, input?: Payload): Promise<BridgeReply> {
    const req = http.createHttp();
    const address = endpoint.address;
    const token = endpoint.token;
    const ca = endpoint.ca;
    const pin = endpoint.pin;
    const remoteEndpoint = ca !== undefined && pin !== undefined && validSecureAddress(address, ca, pin, true);
    const remoteCatalog = path.startsWith('/sessions?') && remoteEndpoint;
    const slowRequest = path === '/open' || path === '/session/open' || path === '/new' || path === '/fork' || path === '/create-workspace' || path === '/close-workspace';
    const headers: Record<string, string> = { 'Accept-Encoding': 'gzip' };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (input) headers['Content-Type'] = 'application/json';
    try {
      const opts: http.HttpRequestOptions = {
        method: input ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: false,
        maxRedirects: 0,
        connectTimeout: remoteCatalog ? 6000 : (remoteEndpoint ? 4500 : 2000),
        readTimeout: remoteCatalog || path === '/fork' ? 20000 : (slowRequest ? 16000 : 6500)
      };
      if (ca && pin) {
        opts.caData = ca;
        opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: pin };
      } else if (endpoint.skipTlsVerify && path === '/pair') {
        opts.remoteValidation = 'skip';
      }
      if (input) opts.extraData = JSON.stringify(input);
      const response = await req.request(`${address}${path}`, opts);
      let reply: BridgeReply | undefined;
      try {
        reply = JSON.parse(response.result as string) as BridgeReply;
      } catch {
        reply = undefined;
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new BridgeFailure(response.responseCode, reply?.error ?? 'request_failed');
      }
      if (!reply) throw new BridgeFailure(response.responseCode, 'invalid_response');
      return reply;
    } finally { req.destroy(); }
  }

  async downloadFile(endpoint: BridgeEndpoint, cwd: string, path: string, temporary: string, lookupName: boolean, limit: number = MAX_DOWNLOAD_BYTES): Promise<void> {
    const req = http.createHttp();
    let file: fileIo.File | undefined;
    try {
      const output = fileIo.openSync(temporary, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      file = output;
      const headers: Record<string, string> = { 'Authorization': `Bearer ${endpoint.token}` };
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        usingCache: false,
        usingProxy: false,
        maxRedirects: 0,
        connectTimeout: 4000,
        readTimeout: 60000,
        maxLimit: limit
      };
      if (endpoint.ca && endpoint.pin) {
        opts.caData = endpoint.ca;
        opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: endpoint.pin };
      }
      let expected = -1;
      let received = 0;
      let writeError = '';
      const prefix = new Uint8Array(MAX_DOWNLOAD_ERROR_BYTES);
      req.on('headersReceive', (header: Object) => {
        const fields = header as Record<string, string>;
        const key = Object.keys(fields).find((field: string): boolean => field.toLowerCase() === 'content-length');
        expected = key === undefined ? -1 : Number(fields[key]);
      });
      req.on('dataReceive', (chunk: ArrayBuffer) => {
        if (writeError) return;
        if (received + chunk.byteLength > limit) {
          writeError = 'file_too_large';
          return;
        }
        if (received < prefix.length) {
          prefix.set(new Uint8Array(chunk, 0, Math.min(chunk.byteLength, prefix.length - received)), received);
        }
        try {
          let offset = 0;
          while (offset < chunk.byteLength) {
            const written = fileIo.writeSync(output.fd, offset === 0 ? chunk : chunk.slice(offset));
            if (written <= 0) throw new Error('write_failed');
            offset += written;
          }
          received += chunk.byteLength;
        } catch {
          writeError = 'write_failed';
        }
      });
      const lookup = lookupName && !path.includes('/') ? '&lookup=name' : '';
      const status = await req.requestInStream(`${endpoint.address}/files/download?cwd=${encodeURIComponent(cwd)}&path=${encodeURIComponent(path)}${lookup}`, opts);
      if (status !== 200) {
        let code = 'download_failed';
        if (!writeError && received <= prefix.length) {
          try {
            const reply = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(prefix.subarray(0, received))) as BridgeReply;
            if (reply.error) code = reply.error;
          } catch {
            // 错误体不是 JSON 时保留 download_failed。
          }
        }
        throw new BridgeFailure(status, code);
      }
      if (writeError) throw new Error(writeError);
      if (expected > limit) throw new Error('file_too_large');
      if (expected >= 0 && received !== expected) throw new Error('incomplete_download');
    } finally {
      req.destroy();
      if (file) fileIo.closeSync(file);
    }
  }

  async uploadAttachment(endpoint: BridgeEndpoint, kind: string, name: string, bytes: Uint8Array, pane: string = ''): Promise<UploadedAttachment> {
    const req = http.createHttp();
    const headers: Record<string, string> = { 'Authorization': `Bearer ${endpoint.token}`, 'Content-Type': 'application/octet-stream' };
    try {
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: false,
        maxRedirects: 0,
        connectTimeout: 4000,
        readTimeout: 60000
      };
      if (endpoint.ca && endpoint.pin) {
        opts.caData = endpoint.ca;
        opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: endpoint.pin };
      }
      opts.extraData = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      const response = await req.request(`${endpoint.address}/upload?kind=${encodeURIComponent(kind)}&name=${encodeURIComponent(name)}${pane}`, opts);
      let reply: BridgeReply | undefined;
      try {
        reply = JSON.parse(response.result as string) as BridgeReply;
      } catch {
        reply = undefined;
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new BridgeFailure(response.responseCode, reply?.error ?? 'request_failed');
      }
      if (!reply?.attachment || typeof reply.attachment.token !== 'string' || reply.attachment.kind !== kind) {
        throw new BridgeFailure(response.responseCode, 'invalid_attachment');
      }
      return reply.attachment;
    } finally { req.destroy(); }
  }

  openEvents(endpoint: BridgeEndpoint, path: string, events: BridgeEvents): http.HttpRequest {
    const req = http.createHttp();
    const remoteEndpoint = endpoint.ca !== undefined && endpoint.pin !== undefined &&
      validSecureAddress(endpoint.address, endpoint.ca, endpoint.pin, true);
    const headers: Record<string, string> = { 'Authorization': `Bearer ${endpoint.token}`, 'Accept': 'text/event-stream' };
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      usingCache: false,
      usingProxy: false,
      maxRedirects: 0,
      connectTimeout: remoteEndpoint ? 6000 : 3000,
      readTimeout: 30000
    };
    if (endpoint.ca && endpoint.pin) {
      opts.caData = endpoint.ca;
      opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: endpoint.pin };
    }
    let buffer = '';
    const decoder = new util.TextDecoder('utf-8');
    req.on('headersReceive', (_header: Object) => {
      if (!events.current()) return;
      events.ready();
    });
    req.on('dataReceive', (data: ArrayBuffer) => {
      if (!events.current()) return;
      buffer += decoder.decodeWithStream(new Uint8Array(data), { stream: true }).replace(/\r\n/g, '\n');
      if (buffer.length > 262144) {
        events.closed(500);
        return;
      }
      let boundary = buffer.indexOf('\n\n');
      while (boundary >= 0) {
        const raw = buffer.substring(0, boundary);
        buffer = buffer.substring(boundary + 2);
        const lines: string[] = [];
        for (const line of raw.split('\n')) {
          if (line.startsWith('data: ')) lines.push(line.substring(6));
          else if (line.startsWith('data:')) lines.push(line.substring(5));
        }
        const payload = lines.join('\n');
        if (payload) events.frame(payload);
        if (!events.current()) return;
        boundary = buffer.indexOf('\n\n');
      }
    });
    req.on('dataEnd', () => { if (events.current()) events.closed(2000); });
    req.requestInStream(`${endpoint.address}${path}`, opts).then((code: number) => {
      if (!events.current()) return;
      if (code === 401) { events.revoked(); return; }
      if (code >= 400) events.closed(code === 429 ? 8000 : 3000);
    }).catch(() => { if (events.current()) events.closed(2000); });
    return req;
  }
}
