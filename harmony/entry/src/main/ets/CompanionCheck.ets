// 电脑条目校验与标签:从 pages/Index.ets 外移的无状态纯函数。

import type { Companion } from './CredentialVault';
import { validSecureAddress, validUsb } from './PairingCode';

export function validCompanion(record: Companion): boolean {
  return !!record && typeof record.address === 'string' && typeof record.token === 'string' && /^[a-f0-9]{64}$/.test(record.token) &&
    (validUsb(record.address) || (typeof record.ca === 'string' && typeof record.pin === 'string' &&
      (validSecureAddress(record.address, record.ca, record.pin, false) ||
        validSecureAddress(record.address, record.ca, record.pin, true))));
}

export function connectionLabel(record: Companion): string {
  if (validUsb(record.address)) return 'USB';
  return record.ca && record.pin && validSecureAddress(record.address, record.ca, record.pin, true) ? '公网' : 'Wi-Fi';
}
