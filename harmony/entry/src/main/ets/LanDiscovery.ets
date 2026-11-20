import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

export async function discoverLan(): Promise<string[]> {
  const udp = socket.constructUDPSocketInstance();
  const nonce = util.generateRandomUUID().replace(/-/g, '');
  const results = new Set<string>();
  const decoder = new util.TextDecoder('utf-8');
  try {
    await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
    await udp.setExtraOptions({ broadcast: true });
    udp.on('message', (event: socket.SocketMessageInfo) => {
      if (event.message.byteLength > 96 || event.remoteInfo.port !== 18976 || results.size >= 20) return;
      const match = /^PIGO-HERE\/1 ([a-f0-9]{32}) ([0-9.]{7,15}) ([0-9]{1,5})$/.exec(decoder.decodeWithStream(new Uint8Array(event.message)));
      if (!match || match[1] !== nonce || match[2] !== event.remoteInfo.address || Number(match[3]) < 1024 || Number(match[3]) > 65535) return;
      const ip = match[2].split('.').map((part: string): number => Number(part));
      if (ip.length !== 4 || !(ip[0] === 10 || (ip[0] === 172 && ip[1] >= 16 && ip[1] <= 31) ||
        (ip[0] === 192 && ip[1] === 168))) return;
      results.add(`https://${match[2]}:${match[3]}`);
    });
    const query = `PIGO-DISCOVER/1 ${nonce}`.padEnd(96, ' ');
    for (let attempt = 0; attempt < 2; attempt++) {
      await udp.send({ data: query, address: { address: '255.255.255.255', port: 18976, family: 1 } });
      await new Promise<void>((resolve) => { setTimeout(resolve, 600); });
    }
    return Array.from(results).sort();
  } finally { await udp.close().catch((): void => {}); }
}
