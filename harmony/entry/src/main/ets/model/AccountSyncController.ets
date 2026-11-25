import { common } from '@kit.AbilityKit';
import { preferences, relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountSync, CloudComputer, SyncRow, SyncSnapshot, SYNC_MODE, SYNC_THEME, computerSyncRow } from '../AccountSync';
import { appearanceMode, themeStyle } from '../Appearance';
import { connectionLabel } from '../CompanionCheck';
import { Companion } from '../CredentialVault';
import { HuaweiProfile, authorizeHuaweiProfile, isHuaweiProfileCurrent } from '../HuaweiProfile';
import { validUsb } from '../PairingCode';

export interface AccountSyncHost {
  context: () => common.UIAbilityContext | undefined;
  whenRestored: () => Promise<void>;
  settings: () => preferences.Preferences | undefined;
  saveSetting: (key: string, value: string) => Promise<void>;
  computers: () => Companion[];
  resetAvatar: () => void;
  cancelComputerRestore: () => void;
  applyTheme: (theme: string) => void;
  applyMode: (mode: string) => void;
}

@ObservedV2
export class AccountSyncState {
  @Trace huaweiProfile?: HuaweiProfile = undefined;
  @Trace accountBusy: boolean = false;
  @Trace accountNotice: string = '';
  @Trace cloudComputers: CloudComputer[] = [];
  @Trace cloudSyncStatus: string = '';
  @Trace cloudSyncBusy: boolean = false;
}

export class AccountSyncController {
  readonly state: AccountSyncState = new AccountSyncState();
  private cloudStore?: Promise<AccountSync>;
  private cloudWork: Promise<void> = Promise.resolve();
  private cloudWrites: Promise<void> = Promise.resolve();
  private cloudTimer: number = -1;
  private cloudRevision: number = 0;
  private readonly pendingCloudRows: Map<string, SyncRow> = new Map<string, SyncRow>();

  private readonly host: AccountSyncHost;

  constructor(host: AccountSyncHost) {
    this.host = host;
  }

  async checkHuaweiProfile(): Promise<void> {
    const profile = this.state.huaweiProfile;
    if (!profile || this.state.accountBusy) return;
    try {
      if (!await isHuaweiProfileCurrent(profile) && this.state.huaweiProfile === profile && !this.state.accountBusy) {
        await this.signOutHuawei();
      }
    } catch { /* A temporary Account Kit failure leaves the local profile available. */ }
  }

  async signInHuawei(): Promise<void> {
    const context = this.host.context();
    if (!context || this.state.accountBusy) return;
    this.state.accountBusy = true;
    this.state.accountNotice = '';
    try {
      this.state.huaweiProfile = await authorizeHuaweiProfile(context);
      this.scheduleCloudSync(0);
      this.host.resetAvatar();
      try { await this.host.saveSetting('huawei_profile', JSON.stringify(this.state.huaweiProfile)); }
      catch { this.state.accountNotice = '已登录，本次登录状态无法保存。'; }
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code !== 1001502012) {
        this.state.accountNotice = code === 1001500001 ? '华为账号登录需要配置应用签名指纹和 Client ID。' :
          '华为账号登录未完成，请检查系统账号后重试。';
      }
    } finally { this.state.accountBusy = false; }
  }

  async signOutHuawei(): Promise<void> {
    if (this.state.accountBusy) return;
    this.state.accountBusy = true;
    this.state.accountNotice = '';
    try {
      await this.host.saveSetting('huawei_profile', '');
      this.state.huaweiProfile = undefined;
      this.host.resetAvatar();
      this.cloudStore = undefined;
      this.state.cloudComputers = [];
      this.pendingCloudRows.clear();
      this.state.cloudSyncStatus = '';
      this.state.cloudSyncBusy = false;
      this.host.cancelComputerRestore();
      if (this.cloudTimer !== -1) clearTimeout(this.cloudTimer);
      this.cloudTimer = -1;
    }
    catch { this.state.accountNotice = '未能清除本地登录记录，请重试退出。'; }
    finally { this.state.accountBusy = false; }
  }

  private queueCloudWork(work: () => Promise<void>): void {
    this.cloudWork = this.cloudWork.then(work).catch(() => {});
  }

  private async accountCloudStore(profile: HuaweiProfile): Promise<AccountSync> {
    if (this.state.huaweiProfile !== profile) throw new Error('account_changed');
    if (!this.cloudStore) {
      const context = this.host.context();
      if (!context) throw new Error('context_unavailable');
      this.cloudStore = AccountSync.open(context, profile.openId).catch((error: Error) => {
        if (this.state.huaweiProfile === profile) this.cloudStore = undefined;
        throw error;
      });
    }
    return this.cloudStore;
  }

  dispose(): void {
    if (this.cloudTimer !== -1) {
      clearTimeout(this.cloudTimer);
      this.cloudTimer = -1;
    }
    this.cloudRevision += 1;
  }

  scheduleCloudSync(delay: number = 650): void {
    const profile = this.state.huaweiProfile;
    if (!profile) return;
    if (this.cloudTimer !== -1) clearTimeout(this.cloudTimer);
    this.cloudTimer = setTimeout(() => {
      this.cloudTimer = -1;
      const revision = this.cloudRevision;
      this.queueCloudWork(async () => { await this.syncAccountSettings(profile, revision); });
    }, delay);
  }

  private async syncAccountSettings(profile: HuaweiProfile, revision: number): Promise<void> {
    await this.host.whenRestored();
    if (this.state.huaweiProfile !== profile) return;
    this.state.cloudSyncBusy = true;
    this.state.cloudSyncStatus = '正在与华为云空间同步…';
    let step = 'account';
    try {
      if (!await isHuaweiProfileCurrent(profile) || this.state.huaweiProfile !== profile) {
        if (this.state.huaweiProfile === profile) this.state.cloudSyncStatus = '请重新登录华为账号。';
        return;
      }
      const settings = this.host.settings();
      if (settings && !settings.getSync('cloud_migration_owner', '')) {
        await this.host.saveSetting('cloud_migration_owner', profile.openId);
      }
      step = 'local';
      const store = await this.accountCloudStore(profile);
      await this.persistCloudRows(profile);
      const cached = await store.read();
      if (this.state.huaweiProfile === profile && revision === this.cloudRevision) this.state.cloudComputers = cached.computers;
      if (!await isHuaweiProfileCurrent(profile) || this.state.huaweiProfile !== profile) return;
      step = 'cloud';
      let result = await store.synchronize();
      if (this.state.huaweiProfile !== profile) return;
      if (result === relationalStore.ProgressCode.SUCCESS && revision === this.cloudRevision) {
        step = 'migration';
        if (await store.seed(this.legacyCloudSettings(profile))) {
          if (!await isHuaweiProfileCurrent(profile) || this.state.huaweiProfile !== profile) return;
          step = 'upload';
          result = await store.synchronize();
        }
      }
      step = 'restore';
      const snapshot = await store.read();
      if (this.state.huaweiProfile !== profile) return;
      if (revision === this.cloudRevision) this.applyCloudSettings(snapshot);
      this.state.cloudSyncStatus = result === relationalStore.ProgressCode.SUCCESS ? '电脑列表和主题偏好已同步' :
        result === relationalStore.ProgressCode.CLOUD_DISABLED ? '请在「设置 → 云空间」开启 Pi Go 同步。' :
        result === relationalStore.ProgressCode.NETWORK_ERROR ? '云空间连接失败，请检查网络后重试。' :
        '云空间同步暂未完成，请稍后重试。';
    } catch (error) {
      console.warn(`[PiGoCloud] ${step} failed, code=${(error as BusinessError).code ?? 'unknown'}`);
      if (this.state.huaweiProfile === profile) this.state.cloudSyncStatus = '云空间暂不可用，请检查同步设置后重试。';
    } finally {
      if (this.state.huaweiProfile === profile) this.state.cloudSyncBusy = false;
    }
  }

  private legacyCloudSettings(profile: HuaweiProfile): SyncRow[] {
    const settings = this.host.settings();
    if (!settings) return [];
    if (settings.getSync('cloud_migration_owner', '') !== profile.openId) return [];
    const rows = this.host.computers().map((computer: Companion): SyncRow =>
      computerSyncRow(computer.address, validUsb(computer.address) ? 'usb' :
        connectionLabel(computer) === '公网' ? 'remote' : 'lan'));
    const theme = settings.getSync(SYNC_THEME, '') as string;
    const mode = settings.getSync(SYNC_MODE, '') as string;
    if (theme && themeStyle(theme).id === theme) rows.push({ key: SYNC_THEME, payload: theme });
    if (mode && appearanceMode(mode).id === mode) rows.push({ key: SYNC_MODE, payload: mode });
    return rows;
  }

  private applyCloudSettings(snapshot: SyncSnapshot): void {
    this.state.cloudComputers = snapshot.computers;
    if (themeStyle(snapshot.theme).id === snapshot.theme) this.host.applyTheme(snapshot.theme);
    if (appearanceMode(snapshot.mode).id === snapshot.mode) this.host.applyMode(snapshot.mode);
  }

  writeCloudRow(row: SyncRow): void {
    const profile = this.state.huaweiProfile;
    if (!profile) return;
    this.cloudRevision += 1;
    this.pendingCloudRows.set(row.key, row);
    void this.persistCloudRows(profile).then(() => {
      if (this.state.huaweiProfile === profile) this.scheduleCloudSync();
    }).catch(() => {
      if (this.state.huaweiProfile === profile) this.state.cloudSyncStatus = '本次修改无法保存到同步库，请稍后重试。';
    });
  }

  private persistCloudRows(profile: HuaweiProfile): Promise<void> {
    const write = this.cloudWrites.then(async () => {
      if (this.state.huaweiProfile !== profile || !this.pendingCloudRows.size) return;
      const store = await this.accountCloudStore(profile);
      for (const row of Array.from(this.pendingCloudRows.values())) {
        if (this.state.huaweiProfile !== profile) return;
        await store.save(row);
        if (this.state.huaweiProfile === profile && this.pendingCloudRows.get(row.key) === row) {
          this.pendingCloudRows.delete(row.key);
        }
      }
    });
    this.cloudWrites = write.catch(() => {});
    return write;
  }

  updateCloudComputer(address: string, mode: string): void {
    try {
      this.writeCloudRow(computerSyncRow(address, mode));
    } catch {
      this.state.cloudSyncStatus = '未能同步电脑列表。';
    }
  }
}
