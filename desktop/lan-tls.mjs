import { execFileSync } from 'node:child_process';
import { createHash, X509Certificate } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { isIPv4 } from 'node:net';
import { networkInterfaces, tmpdir } from 'node:os';
import { join } from 'node:path';

export function privateIPv4(host) {
  if (!isIPv4(host)) return false;
  const [first, second] = host.split('.').map(Number);
  return first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168);
}

export function localLanAddress(host) {
  return privateIPv4(host) && Object.values(networkInterfaces()).flat().some((entry) => entry?.address === host && !entry.internal);
}

export function newLanIdentity(host) {
  if (!localLanAddress(host)) throw new Error('invalid_lan_address');
  const directory = mkdtempSync(join(tmpdir(), 'pigo-tls-'));
  try {
    const keyFile = join(directory, 'key.pem');
    const certFile = join(directory, 'cert.pem');
    execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
      '-nodes', '-sha256', '-days', '365', '-subj', '/CN=Pi Go LAN',
      '-addext', `subjectAltName=IP:${host}`, '-addext', 'basicConstraints=critical,CA:FALSE',
      '-addext', 'extendedKeyUsage=serverAuth', '-keyout', keyFile, '-out', certFile],
    { stdio: 'ignore', timeout: 5000 });
    const cert = readFileSync(certFile, 'utf8');
    const key = readFileSync(keyFile);
    const spki = new X509Certificate(cert).publicKey.export({ type: 'spki', format: 'der' });
    const pin = createHash('sha256').update(spki).digest('base64');
    return { key, cert, pin };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
