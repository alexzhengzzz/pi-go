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

export function publicIPv4(host) {
  if (typeof host !== 'string' || !isIPv4(host) || privateIPv4(host)) return false;
  const [first, second, third] = host.split('.').map(Number);
  return first > 0 && first < 224 && first !== 127 &&
    !(first === 100 && second >= 64 && second <= 127) &&
    !(first === 169 && second === 254) &&
    !(first === 192 && ((second === 0 && (third === 0 || third === 2)) || (second === 88 && third === 99))) &&
    !(first === 198 && (second === 18 || second === 19 || (second === 51 && third === 100))) &&
    !(first === 203 && second === 0 && third === 113);
}

export function publicAddress(ip, port) {
  if (!publicIPv4(ip) || !Number.isInteger(port) || (port !== 443 && (port < 1024 || port > 65535))) {
    throw new Error('invalid_public_endpoint');
  }
  return port === 443 ? ip : `${ip}:${port}`;
}

export function newLanIdentity(host, saved) {
  if (!localLanAddress(host)) throw new Error('invalid_lan_address');
  return newIPIdentity(host, 'Pi Go LAN', saved);
}

export function newPublicIdentity(ip, saved) {
  if (!publicIPv4(ip)) throw new Error('invalid_public_endpoint');
  return newIPIdentity(ip, 'Pi Go Remote', saved);
}

function newIPIdentity(host, name, saved) {
  if (saved) {
    const cert = new X509Certificate(saved.cert);
    if (!cert.checkIP(host)) throw new Error('invalid_tls_identity');
    if (Date.parse(cert.validTo) > Date.now()) return { ...saved, pin: certificatePin(cert) };
  }
  const directory = mkdtempSync(join(tmpdir(), 'pigo-tls-'));
  try {
    const keyFile = join(directory, 'key.pem');
    const certFile = join(directory, 'cert.pem');
    execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
      '-nodes', '-sha256', '-days', '365', '-subj', `/CN=${name}`,
      '-addext', `subjectAltName=IP:${host}`, '-addext', 'basicConstraints=critical,CA:FALSE',
      '-addext', 'extendedKeyUsage=serverAuth', '-keyout', keyFile, '-out', certFile],
    { stdio: 'ignore', timeout: 5000 });
    const cert = readFileSync(certFile, 'utf8');
    const key = readFileSync(keyFile, 'utf8');
    return { key, cert, pin: certificatePin(new X509Certificate(cert)) };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function certificatePin(cert) {
  const spki = cert.publicKey.export({ type: 'spki', format: 'der' });
  return createHash('sha256').update(spki).digest('base64');
}
