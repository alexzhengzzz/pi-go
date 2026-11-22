import type { Companion } from './CredentialVault';

export interface ComputerGroup {
  id: string;
  name: string;
  connections: Companion[];
}

export function computerGroupId(record: Companion): string {
  return record.computerId || record.address;
}

export function computerGroups(records: Companion[]): ComputerGroup[] {
  const groups = new Map<string, ComputerGroup>();
  for (const record of records) {
    const id = computerGroupId(record);
    const group = groups.get(id);
    if (group) group.connections.push(record);
    else groups.set(id, { id: id, name: record.computerName ?? '', connections: [record] });
  }
  return Array.from(groups.values());
}

export function computerGroupTitle(group: ComputerGroup): string {
  if (group.name) return group.name;
  const network = group.connections.find((record: Companion): boolean => record.address.startsWith('https://'));
  return network ? network.address.slice('https://'.length) : 'USB 电脑';
}

export function withComputerAssignment(record: Companion, id: string, name?: string): Companion {
  return { address: record.address, token: record.token, ca: record.ca, pin: record.pin,
    computerId: id, computerName: name };
}

export function renameComputerGroup(records: Companion[], id: string, name: string): Companion[] {
  const remark = name.trim();
  return records.map((record: Companion): Companion => computerGroupId(record) === id ?
    withComputerAssignment(record, id, remark) : record);
}

export function moveComputerConnection(records: Companion[], address: string, id: string, name: string): Companion[] {
  return records.map((record: Companion): Companion => record.address === address ?
    withComputerAssignment(record, id, name) : record);
}
