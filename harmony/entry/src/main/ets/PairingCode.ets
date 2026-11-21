// 配对码与地址校验:从 pages/Index.ets 外移的无状态纯函数。
// 负责 USB/安全地址格式校验与配对 bundle 解码,不持有任何状态。

import { util } from '@kit.ArkTS';

export interface SecurePairingBundle {
  url: string;
  ticket: string;
  ca: string;
  pin: string;
  transport?: string;
}

export function validUsb(address: string): boolean {
  const match = /^http:\/\/127\.0\.0\.1:(\d{1,5})$/.exec(address);
  return match !== null && Number(match[1]) >= 1 && Number(match[1]) <= 65535 && String(Number(match[1])) === match[1];
}

export function validSecureAddress(url: string, ca: string, pin: string, remote: boolean): boolean {
  const match = /^https:\/\/(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?::(\d{1,5}))?$/.exec(url);
  if (!match || (!remote && !match[5]) ||
    (match[5] && (Number(match[5]) < 1024 || Number(match[5]) > 65535 || String(Number(match[5])) !== match[5])) ||
    ca.length > 2000 || !/^-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+-----END CERTIFICATE-----\n?$/.test(ca) ||
    !/^[A-Za-z0-9+/]{43}=$/.test(pin)) return false;
  if (!match.slice(1, 5).every((part: string): boolean => Number(part) <= 255 && String(Number(part)) === part)) return false;
  const first = Number(match[1]);
  const second = Number(match[2]);
  const third = Number(match[3]);
  const lan = first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168);
  if (!remote) return lan;
  return !lan && first > 0 && first < 224 && first !== 127 &&
    !(first === 100 && second >= 64 && second <= 127) &&
    !(first === 169 && second === 254) &&
    !(first === 192 && ((second === 0 && (third === 0 || third === 2)) || (second === 88 && third === 99))) &&
    !(first === 198 && (second === 18 || second === 19 || (second === 51 && third === 100))) &&
    !(first === 203 && second === 0 && third === 113);
}

export function decodePairingBundle(value: string, remote: boolean): SecurePairingBundle {
  const encoded = value.trim().replace(/\s/g, '');
  if (!/^[a-zA-Z0-9_-]{100,4096}$/.test(encoded)) throw new Error('invalid_bundle');
  const raw = encoded.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(encoded.length / 4) * 4, '=');
  const bytes = new util.Base64Helper().decodeSync(raw);
  const bundle = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(bytes)) as SecurePairingBundle;
  if (typeof bundle.url !== 'string' || typeof bundle.ca !== 'string' || typeof bundle.pin !== 'string' ||
    (remote ? bundle.transport !== 'remote' : bundle.transport !== undefined) ||
    typeof bundle.ticket !== 'string' || !validSecureAddress(bundle.url, bundle.ca, bundle.pin, remote) ||
    !/^[a-f0-9]{64}$/.test(bundle.ticket)) throw new Error('invalid_bundle');
  return bundle;
}
