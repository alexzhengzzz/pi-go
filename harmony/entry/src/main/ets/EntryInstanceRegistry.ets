import type { Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { formInfo } from '@kit.FormKit';

export interface EntryInstanceRecord {
  key: string;
  foreground: boolean;
  windowStatus: window.WindowStatusType;
  lastActiveAt: number;
}

export function isTargetedEntryLaunch(want: Want): boolean {
  if (want.action === 'ohos.want.action.sendData') return true;
  const params = want.parameters;
  if (!params) return false;
  if (params[formInfo.FormParam.IDENTITY_KEY] !== undefined) return true;
  if (typeof params['pigoPushDevice'] === 'string' && typeof params['pigoPushEvent'] === 'string') return true;
  if (typeof params['pigoLiveSession'] === 'string' && typeof params['pigoLiveAddress'] === 'string') return true;
  if (typeof params['address'] === 'string' || typeof params['ticket'] === 'string') return true;
  return false;
}

function pickPreferredInstance(records: EntryInstanceRecord[]): EntryInstanceRecord | undefined {
  let best: EntryInstanceRecord | undefined = undefined;
  for (const record of records) {
    if (!best) {
      best = record;
      continue;
    }
    if (record.foreground !== best.foreground) {
      if (record.foreground) best = record;
      continue;
    }
    if (record.lastActiveAt > best.lastActiveAt) {
      best = record;
    }
  }
  return best;
}

/**
 * Decides the specified-launch instance key for EntryAbility:
 * - Explicit pigoInstanceKey always routes to that key.
 * - Targeted launches (share, form card, push, live activity, pairing) reuse an
 *   existing instance when one is alive so the payload lands in onNewWant.
 * - Launcher icon clicks:
 *   - Cold start -> create first instance.
 *   - Any fullscreen instance exists -> allow only one instance, reuse it.
 *   - Any non-fullscreen instance is currently foreground -> create a new instance.
 *   - Otherwise (all non-fullscreen instances are backgrounded) -> resume the most recent one.
 */
export function resolveEntryInstanceKey(
  want: Want,
  records: EntryInstanceRecord[],
  allocateKey: () => string
): string {
  const explicitKey = want.parameters?.['pigoInstanceKey'];
  if (typeof explicitKey === 'string' && explicitKey.length > 0) {
    return explicitKey;
  }

  if (records.length === 0) {
    return allocateKey();
  }

  if (isTargetedEntryLaunch(want)) {
    const preferred = pickPreferredInstance(records);
    return preferred ? preferred.key : allocateKey();
  }

  const fullscreen = records.filter(
    (record: EntryInstanceRecord): boolean => record.windowStatus === window.WindowStatusType.FULL_SCREEN
  );
  if (fullscreen.length > 0) {
    const preferred = pickPreferredInstance(fullscreen);
    return preferred ? preferred.key : fullscreen[0].key;
  }

  const hasForeground = records.some((record: EntryInstanceRecord): boolean => record.foreground);
  if (hasForeground) {
    return allocateKey();
  }

  const preferred = pickPreferredInstance(records);
  return preferred ? preferred.key : allocateKey();
}

export class EntryInstanceRegistry {
  private readonly records: Map<string, EntryInstanceRecord> = new Map();
  private readonly pendingKeys: string[] = [];
  private sequence: number = 0;

  private nextKey(): string {
    this.sequence += 1;
    return `entry_${this.sequence}`;
  }

  acceptWant(want: Want): string {
    let created = false;
    const key = resolveEntryInstanceKey(want, Array.from(this.records.values()), (): string => {
      created = true;
      return this.nextKey();
    });
    if (created || !this.records.has(key)) {
      this.pendingKeys.push(key);
    }
    return key;
  }

  claimKey(want?: Want): string {
    const explicit = want?.parameters?.['pigoInstanceKey'];
    let key: string;
    if (typeof explicit === 'string' && explicit.length > 0) {
      const idx = this.pendingKeys.indexOf(explicit);
      if (idx >= 0) this.pendingKeys.splice(idx, 1);
      key = explicit;
    } else {
      const pending = this.pendingKeys.shift();
      key = pending ?? this.nextKey();
    }
    if (!this.records.has(key)) {
      this.records.set(key, {
        key: key,
        foreground: false,
        windowStatus: window.WindowStatusType.UNDEFINED,
        lastActiveAt: Date.now()
      });
    }
    return key;
  }

  isPrimary(key: string): boolean {
    const preferred = pickPreferredInstance(Array.from(this.records.values()));
    return !preferred || preferred.key === key;
  }

  setForeground(key: string, foreground: boolean): void {
    const record = this.records.get(key);
    if (!record) return;
    record.foreground = foreground;
    record.lastActiveAt = Date.now();
  }

  setWindowStatus(key: string, status: window.WindowStatusType): void {
    const record = this.records.get(key);
    if (!record) return;
    record.windowStatus = status;
    record.lastActiveAt = Date.now();
  }

  touch(key: string): void {
    const record = this.records.get(key);
    if (!record) return;
    record.lastActiveAt = Date.now();
  }

  unregister(key: string): void {
    this.records.delete(key);
  }

  count(): number {
    return this.records.size;
  }

  snapshot(): EntryInstanceRecord[] {
    return Array.from(this.records.values());
  }

  reset(): void {
    this.records.clear();
    this.pendingKeys.length = 0;
    this.sequence = 0;
  }
}

export const entryInstances: EntryInstanceRegistry = new EntryInstanceRegistry();
