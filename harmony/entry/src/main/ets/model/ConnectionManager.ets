import { connection } from '@kit.NetworkKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import type { Companion } from '../CredentialVault';
import { validCompanion } from '../CompanionCheck';
import { withComputerAssignment } from '../ComputerGroups';
import { discoverLan } from '../LanDiscovery';
import { decodePairingBundle, normalizeSecureUrl, pinMatchesPrefix, validSecureAddress, validSecureHostUrl, validUsb } from '../PairingCode';
import { MAX_COMPUTERS } from './PiGoConstants';
import type { BridgeEndpoint, BridgeReply, Payload } from './PiGoTypes';

export interface PairingRequest {
  endpoint: BridgeEndpoint;
  ticket: string;
  remote: boolean;
  pinPrefix?: string;
}

export interface PairedCredentials {
  token: string;
  ca?: string;
  pin?: string;
}

export class ConnectionManager {
  private active: BridgeEndpoint = { address: '', token: '' };
  private pollTimer: number = -1;
  private retryTimer: number = -1;
  private networkMonitor?: connection.NetConnection;
  private networkRegistered: boolean = false;

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
    let code = ticket.replace(/\s+/g, '').toLowerCase();
    const remote = mode === 'remote';
    let pinPrefix: string | undefined;
    if (mode !== 'usb') {
      if (rawBundle.trim()) {
        try {
          const bundle = decodePairingBundle(rawBundle, remote);
          endpoint = bundle.ca && bundle.pin
            ? { address: bundle.url, token: '', ca: bundle.ca, pin: bundle.pin }
            : { address: bundle.url, token: '', skipTlsVerify: true };
          code = bundle.ticket;
          pinPrefix = bundle.pinPrefix;
        } catch {
          throw new Error(remote ? '请扫描 Pi Go.app「公网」二维码，或输入地址和 6 位配对码。' :
            '请扫描 Pi Go.app「局域网」二维码，或输入地址和 6 位配对码。');
        }
      } else {
        const url = normalizeSecureUrl(address, remote);
        if (!validSecureHostUrl(url, remote)) {
          throw new Error(remote ? '请输入有效的公网地址（如 IP:端口）。' : '请先发现或输入电脑局域网地址（如 192.168.1.50:18981）。');
        }
        if (!/^\d{6}$/.test(code)) {
          throw new Error('请输入 6 位数字配对码。');
        }
        endpoint = { address: url, token: '', skipTlsVerify: true };
      }
    } else if (!validUsb(endpoint.address) || !/^(\d{6}|\d{8}|[a-f0-9]{64})$/.test(code)) {
      throw new Error('请输入本机 USB 地址和有效的 6 位配对码或一次性票据。');
    }
    if (computers.length >= MAX_COMPUTERS &&
        !computers.some((record: Companion): boolean => record.address === endpoint.address)) {
      throw new Error('已保存 12 条连接。请先移除不再使用的连接。');
    }
    return { endpoint: endpoint, ticket: code, remote: remote, pinPrefix: pinPrefix };
  }

  async pair(
    pairing: PairingRequest,
    request: (path: string, input: Payload, endpoint: BridgeEndpoint) => Promise<BridgeReply>
  ): Promise<PairedCredentials> {
    const result = await request('/pair', { ticket: pairing.ticket }, pairing.endpoint);
    if (!result.token || !/^[a-f0-9]{64}$/.test(result.token)) throw new Error('invalid_token');
    if (validUsb(pairing.endpoint.address)) {
      return { token: result.token };
    }
    const ca = pairing.endpoint.ca ?? result.ca;
    const pin = pairing.endpoint.pin ?? result.pin;
    if (!ca || !pin || !validSecureAddress(pairing.endpoint.address, ca, pin, pairing.remote) ||
        !pinMatchesPrefix(pin, pairing.pinPrefix)) {
      throw new Error('invalid_tls_identity');
    }
    return { token: result.token, ca: ca, pin: pin };
  }

  pairedComputer(endpoint: BridgeEndpoint, credentials: PairedCredentials, computers: Companion[], computerId: string,
    newId: () => string): Companion {
    const previous = computers.find((item: Companion): boolean => item.address === endpoint.address);
    const target = computers.find((item: Companion): boolean => item.computerId === computerId);
    const computer = previous ?? target;
    return { address: endpoint.address, token: credentials.token, ca: credentials.ca ?? endpoint.ca, pin: credentials.pin ?? endpoint.pin,
      computerId: computer?.computerId ?? newId(), computerName: computer?.computerName };
  }

  discover(): Promise<string[]> {
    return discoverLan();
  }

  watchNetwork(onChange: () => void): void {
    if (this.networkMonitor) return;
    try {
      const monitor = connection.createNetConnection();
      const onEvent = (): void => {
        if (this.networkMonitor === monitor) onChange();
      };
      monitor.on('netAvailable', onEvent);
      monitor.on('netLost', onEvent);
      this.networkMonitor = monitor;
      monitor.register((error: BusinessError): void => {
        if (error) {
          if (this.networkMonitor === monitor) this.networkMonitor = undefined;
        } else if (this.networkMonitor === monitor) {
          this.networkRegistered = true;
        } else {
          monitor.unregister((): void => {});
        }
      });
    } catch {
      this.networkMonitor = undefined;
    }
  }

  stopWatchingNetwork(): void {
    const monitor = this.networkMonitor;
    this.networkMonitor = undefined;
    if (monitor && this.networkRegistered) monitor.unregister((): void => {});
    this.networkRegistered = false;
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
