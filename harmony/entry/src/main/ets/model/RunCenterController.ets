import type { common } from '@kit.AbilityKit';
import type { preferences } from '@kit.ArkData';
import type { UIContext } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import type { AppUiState } from '../AppUiState';
import { validCompanion } from '../CompanionCheck';
import { computerGroupId } from '../ComputerGroups';
import type { Companion } from '../CredentialVault';
import { pushDeviceId, runNotificationId, runNotificationText, runStatus } from '../RunResults';
import type { InboxRun, RunEvent, RunFile } from '../RunResults';
import { WatchReminderController, watchReminderText } from '../WatchReminders';
import { RUN_NOTICE_SETTING, WATCH_REMINDERS_SETTING } from './PiGoConstants';
import type { BridgeEndpoint, BridgeReply, Payload, RunNotice } from './PiGoTypes';

export interface RunCenterHost {
  appState: AppUiState;
  computers: () => Companion[];
  epoch: () => number;
  workspaceCwd: () => string;
  currentId: () => string;
  visible: () => boolean;
  isPaired: () => boolean;
  reachable: () => boolean;
  idle: () => boolean;
  queued: () => boolean;
  base: () => string;
  loading: () => boolean;
  busy: () => boolean;
  openingSession: () => boolean;
  endpoint: () => BridgeEndpoint;
  whenRestored: () => Promise<void>;
  draftKey: (id: string) => string;
  request: (path: string, input?: Payload, endpoint?: BridgeEndpoint) => Promise<BridgeReply>;
  publishWidgets: () => void;
  scheduleEndpoint: (computer: Companion) => BridgeEndpoint;
  scheduleComputerName: (computer: Companion) => string;
  saveSetting: (key: string, value: string | boolean) => Promise<void>;
  openNotifiedSession: (target: Companion, id: string, pendingId: string, eventId: string) => Promise<boolean>;
  showScheduleInbox: () => void;
  dismissKeyboard: () => void;
  getUIContext: () => UIContext;
  openReferencedFile: (cwd: string, path: string, lookupName: boolean) => Promise<void>;
  celebrate: () => void;
}

@ObservedV2
export class RunCenterState {
  @Trace inboxRuns: InboxRun[] = [];
  @Trace inboxCleaning: boolean = false;
  @Trace pushEnabled: boolean = false;
  @Trace pushSaving: boolean = false;
  @Trace pushStatus: string = '';
  @Trace sessionRuns: RunEvent[] = [];
  @Trace sessionRunKey: string = '';
  @Trace reviewedRun?: RunEvent = undefined;
  @Trace reviewedFile?: RunFile = undefined;
  @Trace reviewPatch: string = '';
  @Trace reviewLoading: boolean = false;
  @Trace reviewError: string = '';
  @Trace runNotice?: RunNotice = undefined;
  @Trace runNoticesEnabled: boolean = true;
  @Trace watchRemindersEnabled: boolean = true;
  @Trace watchReminderStatus: string = '';
  @Trace watchReminderTesting: boolean = false;
}

export class RunCenterController {
  readonly state: RunCenterState = new RunCenterState();
  private openingPush: boolean = false;
  private pushToken: string = '';
  private pushTokenRequest?: Promise<string>;
  private nextPushTokenAttempt: number = 0;
  private runRead: string[] = [];
  private dismissedInboxRuns: Set<string> = new Set<string>();
  private runSyncTimer: number = -1;
  private runSyncing: boolean = false;
  private backgroundRunNoticesSince: number = 0;
  private backgroundRunTask: number = -1;
  private readonly backgroundRunSessions: Set<string> = new Set<string>();
  private readonly notifiedBackgroundRuns: Set<string> = new Set<string>();
  private askedForRunNotifications: boolean = false;
  private pushRegistrations: Map<string, string> = new Map<string, string>();
  private reviewRequest: number = 0;
  private readonly observedRuns: Map<string, string> = new Map<string, string>();
  private pendingRunNotices: RunNotice[] = [];
  private runNoticeTimer: number = -1;
  private watchReminderDelivered: string[] = [];
  private readonly watchReminders: WatchReminderController = new WatchReminderController();

  private readonly host: RunCenterHost;

  constructor(host: RunCenterHost) {
    this.host = host;
  }

  attachWatch(context: common.UIAbilityContext): void {
    this.watchReminders.attach(context, (status: string): void => {
      this.state.watchReminderStatus = status;
    }, (id: string): void => { this.rememberWatchReminder(id); });
  }

  resume(): void {
    this.backgroundRunNoticesSince = 0;
    this.stopBackgroundRunTask();
    this.backgroundRunSessions.clear();
    this.notifiedBackgroundRuns.clear();
  }

  close(): void {
    this.backgroundRunNoticesSince = 0;
    this.stopBackgroundRunTask();
    this.stopRunSync();
    this.clearRunNotices();
  }

  sessionChanged(): void {
    this.state.reviewedRun = undefined;
    this.state.reviewedFile = undefined;
    this.reviewRequest += 1;
    this.queueRunSync(0);
  }

  forgetPushRegistration(address: string): void {
    this.pushRegistrations.delete(address);
  }

  clearObservedRuns(): void {
    this.observedRuns.clear();
  }

  reconcileObservedRuns(idleIds: string[], runningIds: string[], selected: string): void {
    const idle = new Set<string>(idleIds);
    const current = this.host.currentId();
    for (const id of this.observedRuns.keys()) {
      if (id === current || id === selected || runningIds.includes(id)) continue;
      if (idle.has(id)) this.observeRun(id, '', false);
      else this.observedRuns.delete(id);
    }
  }

  requestPermissionAfterDispatch(): void {
    if (this.host.visible() && this.state.runNoticesEnabled && !this.askedForRunNotifications) {
      this.askedForRunNotifications = true;
      void this.requestRunNotificationPermission();
    }
  }

  restoreSettings(settings: preferences.Preferences): void {
    this.state.pushEnabled = settings.getSync('run_push_enabled', false) === true;
    const runRead = JSON.parse(settings.getSync('run_inbox_read', '[]') as string) as string[];
    if (Array.isArray(runRead)) this.runRead = runRead.slice(0, 240);
    try {
      const dismissed = JSON.parse(settings.getSync('run_inbox_dismissed', '[]') as string) as string[];
      if (Array.isArray(dismissed)) {
        this.dismissedInboxRuns = new Set<string>(dismissed.filter((id: string): boolean => typeof id === 'string'));
      }
    } catch { /* Ignore an invalid dismissal list. */ }
    this.state.runNoticesEnabled = settings.getSync(RUN_NOTICE_SETTING, true) !== false;
    this.state.watchRemindersEnabled = settings.getSync(WATCH_REMINDERS_SETTING, true) !== false;
    try {
      const delivered = JSON.parse(settings.getSync('watch_reminder_delivered', '[]') as string) as string[];
      if (Array.isArray(delivered)) {
        this.watchReminderDelivered = delivered.filter((id: string): boolean => typeof id === 'string').slice(0, 240);
      }
    } catch { /* Ignore an invalid watch delivery history. */ }
    this.watchReminders.restore(this.watchReminderDelivered);
    this.watchReminders.setEnabled(this.state.watchRemindersEnabled);
  }

  queueRunSync(delay: number): void {
    this.stopRunSync();
    if (!this.host.visible() && (!this.backgroundRunNoticesSince || !this.state.runNoticesEnabled || !this.host.computers().length)) return;
    this.runSyncTimer = setTimeout(() => { void this.syncRunCenter(); }, delay);
  }

  stopRunSync(): void {
    if (this.runSyncTimer !== -1) clearTimeout(this.runSyncTimer);
    this.runSyncTimer = -1;
  }

  startBackgroundRunNotices(): void {
    if (!this.state.runNoticesEnabled) return;
    this.backgroundRunNoticesSince = Date.now();
    this.backgroundRunSessions.clear();
    for (const id of this.observedRuns.keys()) this.backgroundRunSessions.add(id);
    if (this.host.currentId() && (!this.host.idle() || this.host.queued())) this.backgroundRunSessions.add(this.host.currentId());
    if (!this.backgroundRunSessions.size || this.backgroundRunTask !== -1) return;
    try {
      this.backgroundRunTask = backgroundTaskManager.requestSuspendDelay('接收正在运行的 Pi Go 任务结果', (): void => {
        this.stopBackgroundRunTask();
      }).requestId;
    } catch { /* The inbox can still sync while the process remains active. */ }
  }

  private stopBackgroundRunTask(): void {
    if (this.backgroundRunTask === -1) return;
    const task = this.backgroundRunTask;
    this.backgroundRunTask = -1;
    try { backgroundTaskManager.cancelSuspendDelay(task); } catch {}
  }

  private async syncRunCenter(): Promise<void> {
    if ((!this.host.visible() && (!this.backgroundRunNoticesSince || !this.state.runNoticesEnabled)) || this.runSyncing) return;
    this.runSyncing = true;
    const computers = this.host.computers().filter((item: Companion): boolean => validCompanion(item));
    const session = this.host.currentId();
    const key = this.host.draftKey(session);
    const endpoint = this.host.endpoint();
    try {
      const inbox = Promise.all(computers.map((computer: Companion): Promise<boolean> => this.syncRunInbox(computer)));
      const results = this.host.visible() && session && this.host.isPaired() && this.host.reachable() ?
        this.syncRunResults(endpoint, session, key) : undefined;
      const synced = await inbox;
      await results;
      if (this.host.visible()) {
        this.state.inboxRuns = this.state.inboxRuns.filter((row: InboxRun): boolean =>
          this.host.computers().some((computer: Companion): boolean => computer.address === row.address));
        if (synced.some((ready: boolean): boolean => ready) || !this.host.computers().length) {
          this.host.publishWidgets();
        }
      }
    } finally {
      this.runSyncing = false;
      this.queueRunSync(9000);
    }
  }

  private async syncRunInbox(computer: Companion): Promise<boolean> {
    const endpoint = this.host.scheduleEndpoint(computer);
    try {
      const result = await this.host.request('/runs/inbox', undefined, endpoint);
      if (!this.host.computers().some((item: Companion): boolean =>
        item.address === computer.address && item.token === computer.token)) return false;
      if (!this.host.visible()) {
        if (this.state.runNoticesEnabled && this.backgroundRunNoticesSince) {
          for (const run of result.runEvents ?? []) await this.publishBackgroundRunNotice(run);
        }
        return true;
      }
      const rows = (result.runEvents ?? []).filter((run: RunEvent): boolean =>
        run.status === 'waiting' || !this.dismissedInboxRuns.has(run.id)).map((run: RunEvent): InboxRun => ({
        run: run, address: computer.address, computer: this.host.scheduleComputerName(computer),
        unread: run.status === 'waiting' || !this.runRead.includes(run.id)
      }));
      this.state.inboxRuns = this.state.inboxRuns.filter((row: InboxRun): boolean => row.address !== computer.address).concat(rows);
      for (const row of rows) {
        if (row.unread) {
          this.queueWatchReminder(`inbox:${row.run.id}`, runStatus(row.run.status), row.computer,
            row.run.title ?? '', row.run.finishedAt);
        }
      }
      await this.syncPushRegistration(computer, result.pushAvailable === true).catch((): void => {});
      return true;
    } catch { return false; }
  }

  private async publishBackgroundRunNotice(run: RunEvent): Promise<void> {
    if (this.host.visible() || !this.state.runNoticesEnabled || !this.backgroundRunNoticesSince ||
      !(run.finishedAt >= this.backgroundRunNoticesSince) || !run.id || this.notifiedBackgroundRuns.has(run.id) ||
      !['completed', 'failed', 'stopped'].includes(run.status)) return;
    const since = this.backgroundRunNoticesSince;
    this.notifiedBackgroundRuns.add(run.id);
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled || this.backgroundRunNoticesSince !== since || !this.state.runNoticesEnabled) {
        if (this.backgroundRunNoticesSince === since) this.notifiedBackgroundRuns.delete(run.id);
        return;
      }
      const messageId = runNotificationId(run.id);
      const title = run.status === 'completed' ? 'OK' : runStatus(run.status);
      await notificationManager.publish({
        label: messageId,
        appMessageId: messageId,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: title, text: runNotificationText(run.title ?? '') }
        }
      });
      if (this.backgroundRunNoticesSince === since && this.backgroundRunSessions.delete(run.sessionId) &&
        !this.backgroundRunSessions.size) this.stopBackgroundRunTask();
    } catch {
      if (this.backgroundRunNoticesSince === since) this.notifiedBackgroundRuns.delete(run.id);
    }
  }

  queueWatchReminder(id: string, status: string, computer: string, title: string, finishedAt: number): void {
    const now = Date.now();
    if (!this.state.watchRemindersEnabled || finishedAt <= 0 || finishedAt < now - 5 * 60 * 1000 ||
      finishedAt > now + 5 * 60 * 1000) return;
    this.watchReminders.notify({
      id: id,
      title: `Pi Go · ${status}`,
      text: watchReminderText(status, computer, title)
    });
  }

  private rememberWatchReminder(id: string): void {
    this.watchReminderDelivered = [id].concat(this.watchReminderDelivered.filter((value: string): boolean => value !== id))
      .slice(0, 240);
    void this.host.saveSetting('watch_reminder_delivered', JSON.stringify(this.watchReminderDelivered)).catch(() => {});
  }

  async syncRunResults(endpoint: BridgeEndpoint, session: string, key: string): Promise<void> {
    try {
      const result = await this.host.request('/runs/results?session=' + encodeURIComponent(session), undefined, endpoint);
      if (key !== this.host.draftKey(this.host.currentId()) || endpoint.token !== this.host.endpoint().token) return;
      const rows = (result.runEvents ?? []).filter((row: RunEvent): boolean => row.cwd === this.host.workspaceCwd());
      if (key !== this.state.sessionRunKey || rows.length !== this.state.sessionRuns.length ||
          rows.some((row: RunEvent, index: number): boolean => row.id !== this.state.sessionRuns[index].id)) {
        this.state.sessionRunKey = key;
        this.state.sessionRuns = rows;
      }
    } catch { /* Old bridges can still display the session transcript. */ }
  }

  private inboxSessionKey(row: InboxRun): string {
    if (!row.run.sessionId) return '';
    const companion = this.host.computers().find((item: Companion): boolean => item.address === row.address);
    const group = companion ? computerGroupId(companion) : row.address;
    return `${group}:${row.run.sessionId}`;
  }

  displayedInboxRuns(): InboxRun[] {
    const byId = new Map<string, InboxRun>();
    for (const row of this.state.inboxRuns) {
      if (!byId.has(row.run.id) || row.address === this.host.base()) byId.set(row.run.id, row);
    }
    const records = new Map<string, InboxRun>();
    for (const row of byId.values()) {
      const sessionKey = row.run.status === 'waiting' ? '' : this.inboxSessionKey(row);
      const key = row.run.status === 'waiting' ? `waiting:${row.run.id}` :
        (sessionKey ? `session:${sessionKey}` : `run:${row.run.id}`);
      const existing = records.get(key);
      if (!existing) {
        records.set(key, row);
        continue;
      }
      const nextTime = row.run.finishedAt ?? 0;
      const prevTime = existing.run.finishedAt ?? 0;
      if (nextTime > prevTime || (nextTime === prevTime && row.address === this.host.base())) {
        records.set(key, row);
      }
    }
    return Array.from(records.values()).sort((a: InboxRun, b: InboxRun): number =>
      Number(b.run.status === 'waiting') - Number(a.run.status === 'waiting') || b.run.finishedAt - a.run.finishedAt);
  }

  async dismissInboxRuns(ids: string[]): Promise<boolean> {
    if (this.state.inboxCleaning) return false;
    const selected = new Set<string>(ids);
    const dismissedSessions = new Set<string>();
    for (const row of this.state.inboxRuns) {
      if (row.run.status !== 'waiting' && selected.has(row.run.id)) {
        const sessionKey = this.inboxSessionKey(row);
        if (sessionKey) dismissedSessions.add(sessionKey);
      }
    }
    const dismissed = new Set<string>(this.dismissedInboxRuns);
    for (const row of this.state.inboxRuns) {
      if (row.run.status === 'waiting') continue;
      const sessionKey = this.inboxSessionKey(row);
      if (selected.has(row.run.id) || (sessionKey && dismissedSessions.has(sessionKey))) {
        dismissed.add(row.run.id);
      }
    }
    this.state.inboxCleaning = true;
    try {
      await this.host.saveSetting('run_inbox_dismissed', JSON.stringify(Array.from(dismissed)));
      this.dismissedInboxRuns = dismissed;
      this.state.inboxRuns = this.state.inboxRuns.filter((row: InboxRun): boolean =>
        row.run.status === 'waiting' || !dismissed.has(row.run.id));
      return true;
    } catch {
      this.host.getUIContext().getPromptAction().showToast({ message: '暂时无法保存删除记录，请重试。' });
      return false;
    } finally {
      this.state.inboxCleaning = false;
    }
  }

  private async syncPushRegistration(computer: Companion, available: boolean): Promise<void> {
    const endpoint = this.host.scheduleEndpoint(computer);
    if (!available) {
      this.pushRegistrations.delete(computer.address);
      if (this.state.pushEnabled && computer.address === this.host.base()) this.state.pushStatus = '这台电脑尚未配置 Push Kit';
      return;
    }
    const registered = this.state.pushEnabled ? computer.token + ':' + this.pushToken : computer.token;
    if (this.pushRegistrations.get(computer.address) === registered) return;
    if (this.state.pushEnabled && !this.pushToken) {
      if (!this.pushTokenRequest && Date.now() >= this.nextPushTokenAttempt) {
        this.nextPushTokenAttempt = Date.now() + 60_000;
        this.pushTokenRequest = pushService.getToken().finally(() => { this.pushTokenRequest = undefined; });
      }
      try { this.pushToken = await this.pushTokenRequest ?? ''; }
      catch {
        if (computer.address === this.host.base()) this.state.pushStatus = '未能获取推送令牌，请检查应用的 Push Kit 权益';
        return;
      }
      if (!this.pushToken) return;
    }
    const enabled = this.state.pushEnabled;
    const response = await this.host.request('/runs/push', enabled ?
      { enabled: true, token: this.pushToken, device: pushDeviceId(computer.token) } : { enabled: false }, endpoint);
    if (enabled !== this.state.pushEnabled) return;
    if (!enabled || response.pushAvailable === true) {
      this.pushRegistrations.set(computer.address, enabled ? computer.token + ':' + this.pushToken : computer.token);
    }
    if (computer.address === this.host.base() && enabled) this.state.pushStatus = response.pushAvailable ? '当前电脑已注册后台通知' : '这台电脑尚未配置 Push Kit';
  }

  async setPushEnabled(enabled: boolean): Promise<void> {
    if (this.state.pushSaving) return;
    this.state.pushSaving = true;
    try {
      if (enabled && !(await notificationManager.isNotificationEnabled())) {
        const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
        await notificationManager.requestEnableNotification(context);
        if (!(await notificationManager.isNotificationEnabled())) throw new Error('notifications_disabled');
      }
      await this.host.saveSetting('run_push_enabled', enabled);
      this.state.pushEnabled = enabled;
      this.nextPushTokenAttempt = 0;
      this.state.pushStatus = enabled ? '正在连接电脑以启用后台通知…' : '';
      this.pushRegistrations.clear();
      this.queueRunSync(0);
    } catch {
      this.state.pushStatus = enabled ? '请在系统设置中允许 Pi Go 通知后重试' : '未能保存通知设置';
    } finally { this.state.pushSaving = false; }
  }

  markRunRead(id: string): void {
    this.runRead = [id].concat(this.runRead.filter((value: string): boolean => value !== id)).slice(0, 240);
    this.state.inboxRuns = this.state.inboxRuns.map((row: InboxRun): InboxRun => row.run.id === id ? {
      run: row.run, address: row.address, computer: row.computer, unread: false
    } : row);
    void this.host.saveSetting('run_inbox_read', JSON.stringify(this.runRead)).catch(() => {});
    this.host.publishWidgets();
  }

  async openInboxRun(row: InboxRun): Promise<void> {
    const target = this.host.computers().find((item: Companion): boolean => item.address === row.address && validCompanion(item));
    if (!target || !await this.host.openNotifiedSession(target, row.run.sessionId, row.run.pendingId ?? '', row.run.id)) return;
    this.markRunRead(row.run.id);
  }

  async consumePushLaunch(): Promise<void> {
    if (!this.host.appState.pushLaunchEvent || this.openingPush) return;
    this.openingPush = true;
    try {
      await this.host.whenRestored();
      for (let attempt = 0; attempt < 40 && this.host.appState.pushLaunchEvent; attempt++) {
        if (this.host.visible() && !this.host.loading() && !this.host.busy() && !this.host.openingSession()) {
          const event = this.host.appState.pushLaunchEvent;
          const device = this.host.appState.pushLaunchDevice;
          const session = this.host.appState.pushLaunchSession;
          const pending = this.host.appState.pushLaunchPending;
          this.host.appState.pushLaunchEvent = '';
          const target = this.host.computers().find((item: Companion): boolean =>
            validCompanion(item) && pushDeviceId(item.token) === device);
          let opened = false;
          if (target && session) {
            const alternatives = this.host.computers().filter((item: Companion): boolean =>
              item.address !== target.address && computerGroupId(item) === computerGroupId(target) && validCompanion(item));
            for (const connection of [target].concat(alternatives)) {
              if (await this.host.openNotifiedSession(connection, session, pending, event)) {
                opened = true;
                break;
              }
            }
          }
          if (opened) this.markRunRead(event);
          else this.host.showScheduleInbox();
          if (!this.host.appState.pushLaunchEvent) return;
        }
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 300); });
      }
    } finally { this.openingPush = false; }
  }

  openRunResult(run: RunEvent): void {
    if (run.sessionId !== this.host.currentId()) return;
    this.host.dismissKeyboard();
    this.state.reviewedRun = run;
    this.state.reviewedFile = undefined;
    this.state.reviewError = '';
  }

  backFromRunResult(): void {
    this.reviewRequest += 1;
    if (this.state.reviewedFile) this.state.reviewedFile = undefined;
    else this.state.reviewedRun = undefined;
    this.state.reviewPatch = '';
    this.state.reviewLoading = false;
    this.state.reviewError = '';
  }

  async openRunDiff(file: RunFile): Promise<void> {
    const run = this.state.reviewedRun;
    if (!run || run.sessionId !== this.host.currentId()) return;
    const request = ++this.reviewRequest;
    const epoch = this.host.epoch();
    this.state.reviewedFile = file;
    this.state.reviewPatch = '';
    this.state.reviewError = '';
    this.state.reviewLoading = true;
    try {
      const response = await this.host.request('/runs/diff?session=' + encodeURIComponent(run.sessionId) +
        '&run=' + encodeURIComponent(run.id) + '&path=' + encodeURIComponent(file.path));
      if (request !== this.reviewRequest || epoch !== this.host.epoch()) return;
      if (!response.text) throw new Error('diff_unavailable');
      this.state.reviewPatch = response.text;
    } catch {
      if (request === this.reviewRequest && epoch === this.host.epoch()) this.state.reviewError = '暂时无法读取本轮 Diff。';
    } finally {
      if (request === this.reviewRequest) this.state.reviewLoading = false;
    }
  }

  async openRunArtifact(file: RunFile): Promise<void> {
    const run = this.state.reviewedRun;
    if (!run || run.sessionId !== this.host.currentId()) return;
    this.state.reviewedRun = undefined;
    await this.host.openReferencedFile(run.cwd, file.path, false);
  }

  observeRun(id: string, title: string, active: boolean, stopped: boolean = false): void {
    if (!id) return;
    if (active) {
      if (this.host.visible()) this.observedRuns.set(id, title);
      return;
    }
    const previousTitle = this.observedRuns.get(id);
    if (!this.observedRuns.delete(id) || !this.host.visible()) return;
    if (!stopped) {
      this.host.celebrate();
    }
    if (!this.state.runNoticesEnabled) return;
    this.pendingRunNotices.push({ title: title || previousTitle || '任务', stopped: stopped });
    if (!this.state.runNotice) this.advanceRunNotice();
  }

  advanceRunNotice(): void {
    if (this.runNoticeTimer !== -1) clearTimeout(this.runNoticeTimer);
    this.runNoticeTimer = -1;
    this.state.runNotice = this.pendingRunNotices.shift();
    if (this.state.runNotice) this.runNoticeTimer = setTimeout(() => { this.advanceRunNotice(); }, 4500);
  }

  clearRunNotices(): void {
    this.pendingRunNotices = [];
    this.advanceRunNotice();
  }

  async setRunNoticesEnabled(enabled: boolean): Promise<void> {
    this.state.runNoticesEnabled = enabled;
    if (!enabled) this.clearRunNotices();
    try {
      await this.host.saveSetting(RUN_NOTICE_SETTING, enabled);
    } catch {
      if (this.state.runNoticesEnabled === enabled) {
        this.host.getUIContext().getPromptAction().showToast({ message: '未能保存通知设置' });
      }
    }
    if (enabled) void this.requestRunNotificationPermission();
  }

  private async requestRunNotificationPermission(): Promise<void> {
    try {
      const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
      if (context && !(await notificationManager.isNotificationEnabled())) {
        await notificationManager.requestEnableNotification(context);
      }
    } catch { /* System notification permissions can also be enabled in Settings. */ }
  }

  async setWatchRemindersEnabled(enabled: boolean): Promise<void> {
    this.state.watchRemindersEnabled = enabled;
    this.watchReminders.setEnabled(enabled);
    try {
      await this.host.saveSetting(WATCH_REMINDERS_SETTING, enabled);
    } catch {
      if (this.state.watchRemindersEnabled === enabled) {
        this.host.getUIContext().getPromptAction().showToast({ message: '未能保存手表提醒设置' });
      }
    }
  }

  async testWatchReminder(): Promise<void> {
    if (this.state.watchReminderTesting || !this.state.watchRemindersEnabled) return;
    this.state.watchReminderTesting = true;
    try {
      await this.watchReminders.test();
    } finally {
      this.state.watchReminderTesting = false;
    }
  }
}
