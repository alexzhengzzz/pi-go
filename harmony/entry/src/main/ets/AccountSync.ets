import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const TABLE = 'accountsettings';
export const SYNC_THEME = 'theme_style';
export const SYNC_MODE = 'appearance_mode';

export interface CloudComputer {
  address: string;
  mode: string;
}

export interface SyncRow {
  key: string;
  payload: string;
}

export interface SyncSnapshot {
  computers: CloudComputer[];
  theme: string;
  mode: string;
}

function digest(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encodeInto(value) });
  return Array.from(md.digestSync().data, (byte: number): string => byte.toString(16).padStart(2, '0')).join('');
}

export function computerSyncRow(address: string, mode: string): SyncRow {
  const computer: CloudComputer = { address: address, mode: mode };
  return { key: 'computer_' + digest(address), payload: mode ? JSON.stringify(computer) : '' };
}

function decodeComputer(row: SyncRow): CloudComputer | undefined {
  if (!row.payload || row.payload.length > 256) return undefined;
  try {
    const computer = JSON.parse(row.payload) as CloudComputer;
    if (typeof computer?.address !== 'string' || !computer.address) return undefined;
    if (computer.mode === 'usb') {
      if (!/^http:\/\/127\.0\.0\.1:[1-9]\d{0,4}$/.test(computer.address) ||
        Number(computer.address.split(':').pop()) > 65535) return undefined;
    } else if ((computer.mode !== 'lan' && computer.mode !== 'remote') ||
      !/^https:\/\/\d{1,3}(\.\d{1,3}){3}(:[1-9]\d{0,4})?$/.test(computer.address)) return undefined;
    if (computerSyncRow(computer.address, computer.mode).key !== row.key) return undefined;
    return { address: computer.address, mode: computer.mode };
  } catch { return undefined; }
}

export class AccountSync {
  private readonly store: relationalStore.RdbStore;
  private distributed?: Promise<void>;

  private constructor(store: relationalStore.RdbStore) { this.store = store; }

  static async open(context: common.Context, openId: string): Promise<AccountSync> {
    // The cloud container is keyed by database name. Local copies live in account-specific directories.
    const store = await relationalStore.getRdbStore(context, {
      name: 'pigo_sync.db',
      customDir: digest(openId).slice(0, 32),
      securityLevel: relationalStore.SecurityLevel.S1
    });
    await store.executeSql('CREATE TABLE IF NOT EXISTS accountsettings (recordkey TEXT PRIMARY KEY, payload TEXT)');
    await store.executeSql('CREATE TABLE IF NOT EXISTS sync_local (record_key TEXT PRIMARY KEY)');
    return new AccountSync(store);
  }

  private enableDistributed(): Promise<void> {
    if (!this.distributed) {
      this.distributed = this.store.setDistributedTables([TABLE], relationalStore.DistributedType.DISTRIBUTED_CLOUD,
        { autoSync: false }).catch((error: Error) => {
        this.distributed = undefined;
        throw error;
      });
    }
    return this.distributed;
  }

  async synchronize(): Promise<relationalStore.ProgressCode> {
    await this.enableDistributed();
    let timeout = -1;
    try {
      return await new Promise<relationalStore.ProgressCode>((resolve, reject) => {
        timeout = setTimeout(() => { reject(new Error('cloud_sync_timeout')); }, 30000);
        void this.store.cloudSync(relationalStore.SyncMode.SYNC_MODE_TIME_FIRST, [TABLE],
          (progress: relationalStore.ProgressDetails) => {
            if (progress.schedule === relationalStore.Progress.SYNC_FINISH) resolve(progress.code);
          }).catch(reject);
      });
    } finally { clearTimeout(timeout); }
  }

  async save(row: SyncRow): Promise<void> {
    await this.enableDistributed();
    await this.store.executeSql('INSERT INTO accountsettings (recordkey, payload) VALUES (?, ?) ' +
      'ON CONFLICT(recordkey) DO UPDATE SET payload = excluded.payload', [row.key, row.payload]);
  }

  async seed(rows: SyncRow[]): Promise<boolean> {
    const marker = await this.store.querySql("SELECT record_key FROM sync_local WHERE record_key = 'seeded'");
    try {
      if (marker.goToFirstRow()) return false;
    } finally { marker.close(); }
    for (const row of rows) {
      // An existing cloud preference or a removal marker takes precedence over legacy phone data.
      await this.store.executeSql('INSERT OR IGNORE INTO accountsettings (recordkey, payload) VALUES (?, ?)',
        [row.key, row.payload]);
    }
    await this.store.executeSql("INSERT OR IGNORE INTO sync_local (record_key) VALUES ('seeded')");
    return rows.length > 0;
  }

  async read(): Promise<SyncSnapshot> {
    const snapshot: SyncSnapshot = { computers: [], theme: '', mode: '' };
    const rows = await this.store.querySql('SELECT recordkey, payload FROM accountsettings ORDER BY recordkey');
    try {
      while (rows.goToNextRow()) {
        const key = rows.getString(0);
        const payload = rows.getString(1);
        if (key === SYNC_THEME) snapshot.theme = payload;
        else if (key === SYNC_MODE) snapshot.mode = payload;
        else if (key.startsWith('computer_')) {
          const computer = decodeComputer({ key: key, payload: payload });
          if (computer) snapshot.computers.push(computer);
        }
      }
    } finally { rows.close(); }
    return snapshot;
  }
}
