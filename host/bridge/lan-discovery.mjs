import { createSocket } from 'node:dgram';
import { networkInterfaces } from 'node:os';
import { privateIPv4 } from './lan-tls.mjs';

export const discoveryPort = 18976;
const numberOf = (address) => address.split('.').reduce((value, byte) => (value << 8) | Number(byte), 0);

export function startDiscovery(host, port, udpPort = discoveryPort) {
  const found = Object.values(networkInterfaces()).flat().find((entry) => entry.address === host);
  if (!found) return undefined;
  const mask = numberOf(found.netmask);
  const subnet = numberOf(host) & mask;
  const socket = createSocket({ type: 'udp4', reuseAddr: true });
  let remaining = 16;
  let windowStart = 0;
  const stop = () => { try { socket.close(); } catch {} };
  socket.on('error', stop);
  socket.on('message', (packet, peer) => {
    if (packet.length !== 96 || !privateIPv4(peer.address) || (numberOf(peer.address) & mask) !== subnet) return;
    const query = /^PIGO-DISCOVER\/1 ([a-f0-9]{32}) +$/.exec(packet.toString('utf8'));
    if (!query) return;
    const now = Date.now();
    if (now - windowStart >= 1000) { windowStart = now; remaining = 16; }
    if (remaining-- <= 0) return;
    const reply = `PIGO-HERE/1 ${query[1]} ${host} ${port}`;
    socket.send(reply, peer.port, peer.address, () => {});
  });
  socket.bind(udpPort, '0.0.0.0');
  return stop;
}
