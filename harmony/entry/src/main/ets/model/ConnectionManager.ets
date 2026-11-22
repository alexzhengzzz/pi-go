import type { Companion } from '../CredentialVault';
import { validCompanion } from '../CompanionCheck';
import { withComputerAssignment } from '../ComputerGroups';
import { discoverLan } from '../LanDiscovery';
import { decodePairingBundle, validUsb } from '../PairingCode';
import { MAX_COMPUTERS } from './PiGoConstants';
import type { BridgeEndpoint, BridgeReply, Payload } from './PiGoTypes';

export interface PairingRequest {
  endpoint: BridgeEndpoint;
  ticket: string;
}

export class ConnectionManager {
  private active: BridgeEndpoint = { address: '', token: '' };
  private pollTimer: number = -1;
  private retryTimer: number = -1;

  endpoint(): BridgeEndpoint {
    return this.active;
  }

  activate(record: Companion): void {
    const usb = validUsb(record.address);
    this.active = { address: record.address, token: record.token, ca: usb ? undefined : record.ca, pin: usb ? undefined : record.pin };
  }

  disconnect(): void {
    this.active = { address: '', token: '' };
  }

  restoreComputers(records: Companion[], newId: () => string): Companion[] {
    const seen = new Set<string>();
    return records.filter((record: Companion): boolean => {
      if (!validCompanion(record) || seen.has(record.address)) return false;
      seen.add(record.address);
      return true;
    }).slice(0, MAX_COMPUTERS).map((record: Companion): Companion => record.computerId ? record :
      withComputerAssignment(record, newId(), record.computerName));
  }

  pairingRequest(mode: string, address: string, ticket: string, rawBundle: string, computers: Companion[]): PairingRequest {
    let endpoint: BridgeEndpoint = { address: address.trim(), token: '' };
    let code = ticket.trim().toLowerCase();
    if (mode !== 'usb') {
      try {
        const bundle = decodePairingBundle(rawBundle, mode === 'remote');
        endpoint = { address: bundle.url, token: '', ca: bundle.ca, pin: bundle.pin };
        code = bundle.ticket;
      } catch {
        throw new Error(mode === 'remote' ? '请导入 Pi Go.app 生成的公网配对包。' : '请导入 Pi Go.app 生成的局域网配对包。');
      }
    } else if (!validUsb(endpoint.address) || !/^(\d{8}|[a-f0-9]{64})$/.test(code)) {
      throw new Error('请输入本机 USB 地址和有效的一次性票据。');
    }
    if (computers.length >= MAX_COMPUTERS &&
        !computers.some((record: Companion): boolean => record.address === endpoint.address)) {
      throw new Error('已保存 12 条连接。请先移除不再使用的连接。');
    }
    return { endpoint: endpoint, ticket: code };
  }

  async pair(
    pairing: PairingRequest,
    request: (path: string, input: Payload, endpoint: BridgeEndpoint) => Promise<BridgeReply>
  ): Promise<string> {
    const result = await request('/pair', { ticket: pairing.ticket }, pairing.endpoint);
    if (!result.token || !/^[a-f0-9]{64}$/.test(result.token)) throw new Error('invalid_token');
    return result.token;
  }

  pairedComputer(endpoint: BridgeEndpoint, token: string, computers: Companion[], computerId: string,
    newId: () => string): Companion {
    const previous = computers.find((item: Companion): boolean => item.address === endpoint.address);
    const target = computers.find((item: Companion): boolean => item.computerId === computerId);
    const computer = previous ?? target;
    return { address: endpoint.address, token: token, ca: endpoint.ca, pin: endpoint.pin,
      computerId: computer?.computerId ?? newId(), computerName: computer?.computerName };
  }

  discover(): Promise<string[]> {
    return discoverLan();
  }

  schedulePoll(delay: number, poll: () => void): void {
    this.pollTimer = setTimeout(poll, delay);
  }

  cancelPoll(): void {
    if (this.pollTimer !== -1) clearTimeout(this.pollTimer);
    this.pollTimer = -1;
  }

  scheduleRetry(delay: number, retry: () => void): void {
    this.retryTimer = setTimeout(retry, delay);
  }

  cancelRetry(): void {
    if (this.retryTimer !== -1) clearTimeout(this.retryTimer);
    this.retryTimer = -1;
  }
}
