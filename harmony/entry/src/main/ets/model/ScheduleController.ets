import type { AppUiState } from '../AppUiState';
import { util } from '@kit.ArkTS';
import type { preferences } from '@kit.ArkData';
import type { UIContext } from '@kit.ArkUI';
import { validCompanion } from '../CompanionCheck';
import { computerGroupId } from '../ComputerGroups';
import type { Companion } from '../CredentialVault';
import { parseScheduleTime, scheduleRunStatus, scheduleTime } from '../ScheduledRuns';
import type { RunMessage, ScheduleJob, ScheduleRun, ScheduleWatch } from '../ScheduledRuns';
import type { InboxRun } from '../RunResults';
import { BridgeFailure } from './PiGoTypes';
import type { BridgeEndpoint, BridgeReply, Payload } from './PiGoTypes';

export interface ScheduleHost {
  visible: () => boolean;
  base: () => string;
  activeTab: () => string;
  computers: () => Companion[];
  projects: () => string[];
  workspaceCwd: () => string;
  settings: () => preferences.Preferences | undefined;
  saveSetting: (key: string, value: string | boolean) => Promise<void>;
  request: (path: string, input?: Payload, endpoint?: BridgeEndpoint) => Promise<BridgeReply>;
  publishWidgets: () => void;
  scheduleEndpoint: (computer: Companion) => BridgeEndpoint;
  scheduleComputerName: (computer: Companion) => string;
  getUIContext: () => UIContext;
  dismissKeyboard: () => void;
  queueWatchReminder: (id: string, status: string, computer: string, title: string, finishedAt: number) => void;
  runNoticesEnabled: () => boolean;
  inboxCleaning: () => boolean;
  loading: () => boolean;
  isPaired: () => boolean;
  closeReviewOverlays: () => void;
  openComputers: () => void;
  openNotifiedSession: (target: Companion, id: string, pendingId: string, eventId: string) => Promise<boolean>;
  markRunRead: (id: string) => void;
  showScheduleInbox: () => void;
  selectRootTab: (tab: string) => boolean;
  openWorkspaceFiles: () => boolean;
  openNewSession: () => void;
}

@ObservedV2
export class ScheduleState {
  @Trace schedulePage: string = '';
  @Trace scheduleMessages: RunMessage[] = [];
  @Trace scheduleActive: RunMessage[] = [];
  @Trace scheduleOffline: string[] = [];
  @Trace scheduleDetail?: RunMessage = undefined;
  @Trace scheduleDetailFromInbox: boolean = false;
  @Trace scheduleResult: string = '';
  @Trace scheduleResultError: string = '';
  @Trace scheduleAlert?: InboxRun = undefined;
  @Trace scheduleAlertSource: string = '';
  @Trace sessionRunDetail?: InboxRun = undefined;
  @Trace sessionRunResult: string = '';
  @Trace sessionRunResultError: string = '';
  @Trace scheduleBanner?: RunMessage = undefined;
  @Trace scheduleJobs: ScheduleJob[] = [];
  @Trace scheduleZone: string = '';
  @Trace scheduleError: string = '';
  @Trace scheduleListError: string = '';
  @Trace scheduleSaving: boolean = false;
  @Trace scheduleDismissing: boolean = false;
  @Trace scheduleLoading: boolean = false;
  @Trace scheduleLoaded: boolean = false;
  @Trace scheduleEditing?: ScheduleJob = undefined;
  @Trace scheduleName: string = '';
  @Trace schedulePrompt: string = '';
  @Trace scheduleCwd: string = '';
  @Trace scheduleKind: string = 'once';
  @Trace scheduleWhen: string = '';
  @Trace scheduleCatchUp: string = '0';
}

export class ScheduleController {
  readonly state: ScheduleState = new ScheduleState();
  private schedulePrevious: string = '';
  private scheduleRead: Map<string, string[]> = new Map<string, string[]>();
  private scheduleDismissed: Map<string, string[]> = new Map<string, string[]>();
  private scheduleWatches: ScheduleWatch[] = [];
  private scheduleRetries: Map<string, number> = new Map<string, number>();
  private scheduleDue: Map<string, number> = new Map<string, number>();
  private scheduleTimer: number = -1;
  private scheduleBannerTimer: number = -1;
  private schedulePolling: boolean = false;
  private scheduleDiscovery: boolean = false;
  private scheduleMutation: number = 0;
  private scheduleComputerGeneration: number = 0;
  private scheduleResultRequest: number = 0;

  private readonly host: ScheduleHost;

  constructor(host: ScheduleHost) {
    this.host = host;
  }

  consumeFormLaunch(appState: AppUiState): void {
    if (!appState.inboxFormLaunch || !this.host.visible() || this.host.loading()) return;
    appState.inboxFormLaunch = false;
    const destination = appState.formDestination || 'inbox';
    const sessionId = appState.formSessionId;
    const address = appState.formAddress;
    const pendingId = appState.formPendingId;
    const eventId = appState.formEventId;
    appState.formDestination = '';
    appState.formSessionId = '';
    appState.formAddress = '';
    appState.formPendingId = '';
    appState.formEventId = '';
    this.host.closeReviewOverlays();
    if (destination === 'computers' || (!this.host.isPaired() && destination !== 'inbox')) {
      this.state.schedulePage = '';
      this.host.openComputers();
      return;
    }
    if (destination === 'session' && sessionId) {
      const target = (address ? this.host.computers().find((item: Companion): boolean =>
        item.address === address && validCompanion(item)) : undefined) ??
        this.host.computers().find((item: Companion): boolean => item.address === this.host.base() && validCompanion(item));
      if (target) {
        void this.host.openNotifiedSession(target, sessionId, pendingId, eventId).then((opened: boolean) => {
          if (opened && eventId) this.host.markRunRead(eventId);
          else if (!opened) this.host.showScheduleInbox();
        });
        return;
      }
    }
    if (destination === 'new_task') {
      this.state.schedulePage = '';
      this.host.selectRootTab('tasks');
      this.host.openNewSession();
      return;
    }
    if (destination === 'pending') {
      this.state.schedulePage = '';
      this.host.selectRootTab('pending');
      return;
    }
    if (destination === 'new_schedule') {
      this.host.selectRootTab('pending');
      this.editSchedule();
      return;
    }
    if (destination === 'schedule_history') {
      this.host.selectRootTab('pending');
      this.state.scheduleError = '';
      this.state.schedulePage = 'history';
      return;
    }
    if (destination === 'files') {
      this.state.schedulePage = '';
      if (!this.host.openWorkspaceFiles()) this.host.selectRootTab('tasks');
      return;
    }
    if (destination === 'tasks') {
      this.state.schedulePage = '';
      this.host.selectRootTab('tasks');
      return;
    }
    this.host.showScheduleInbox();
  }

  restoreSettings(settings: preferences.Preferences): void {
    const scheduleWatches = settings.getSync('schedule_watches', '[]') as string;
    this.scheduleWatches = JSON.parse(scheduleWatches) as ScheduleWatch[];
  }

  stopScheduleSync(): void {
    if (this.scheduleTimer !== -1) clearTimeout(this.scheduleTimer);
    if (this.scheduleBannerTimer !== -1) clearTimeout(this.scheduleBannerTimer);
    this.scheduleTimer = -1;
    this.scheduleBannerTimer = -1;
    this.state.scheduleBanner = undefined;
  }

  queueScheduleSync(discover: boolean = false, delay: number = 0): void {
    if (discover) {
      this.scheduleDiscovery = true;
      this.scheduleDue.clear();
    }
    if (!this.host.visible() || this.schedulePolling) return;
    if (this.scheduleTimer !== -1) clearTimeout(this.scheduleTimer);
    this.scheduleTimer = setTimeout(() => { void this.syncSchedules(); }, delay);
  }

  private setScheduleWatch(address: string, source: string, watching: boolean): void {
    const current = this.scheduleWatches.find((watch: ScheduleWatch): boolean => watch.address === address);
    if (watching && current?.source === source) return;
    if (!watching && !current) return;
    this.scheduleWatches = this.scheduleWatches.filter((watch: ScheduleWatch): boolean => watch.address !== address);
    if (watching) {
      const watch: ScheduleWatch = { address: address, source: source };
      this.scheduleWatches = this.scheduleWatches.concat([watch]);
    }
    void this.host.saveSetting('schedule_watches', JSON.stringify(this.scheduleWatches)).catch(() => {});
  }

  private async syncSchedules(): Promise<void> {
    if (!this.host.visible() || this.schedulePolling) return;
    this.scheduleTimer = -1;
    const discover = this.scheduleDiscovery;
    this.scheduleDiscovery = false;
    const now = Date.now();
    const computers = this.host.computers().slice();
    this.state.scheduleMessages = this.state.scheduleMessages.filter((message: RunMessage): boolean =>
      computers.some((computer: Companion): boolean => computer.address === message.address));
    this.state.scheduleActive = this.state.scheduleActive.filter((message: RunMessage): boolean =>
      computers.some((computer: Companion): boolean => computer.address === message.address));
    this.state.scheduleOffline = this.state.scheduleOffline.filter((address: string): boolean =>
      computers.some((computer: Companion): boolean => computer.address === address));
    const targets = computers.filter((computer: Companion): boolean => discover ||
      (this.scheduleWatches.some((watch: ScheduleWatch): boolean => watch.address === computer.address) &&
        now >= (this.scheduleDue.get(computer.address) ?? 0)));
    this.schedulePolling = true;
    try {
      await Promise.all(targets.map((computer: Companion): Promise<void> => this.syncScheduleComputer(computer)));
    } finally {
      this.schedulePolling = false;
      if (this.scheduleDiscovery) this.queueScheduleSync();
      else {
        const due = this.scheduleWatches.filter((watch: ScheduleWatch): boolean =>
          this.host.computers().some((computer: Companion): boolean => computer.address === watch.address))
          .map((watch: ScheduleWatch): number => this.scheduleDue.get(watch.address) ?? Date.now());
        if (due.length) this.queueScheduleSync(false, Math.max(0, Math.min(...due) - Date.now()));
      }
    }
  }

  private async syncScheduleComputer(computer: Companion): Promise<void> {
    const mutation = this.scheduleMutation;
    const generation = this.scheduleComputerGeneration;
    const watch = this.scheduleWatches.find((item: ScheduleWatch): boolean => item.address === computer.address);
    const knownRuns = this.state.scheduleMessages.filter((message: RunMessage): boolean =>
      message.address === computer.address || (!!watch?.source && message.source === watch.source))
      .map((message: RunMessage): string => message.run.id).slice(0, 80);
    try {
      const includeJobs = this.host.activeTab() === 'pending' && this.host.base() === computer.address;
      const result = await this.host.request('/schedules/sync', { knownRuns: knownRuns, includeJobs: includeJobs },
        this.host.scheduleEndpoint(computer));
      if (!this.host.visible() || mutation !== this.scheduleMutation || !this.host.computers().some((item: Companion): boolean =>
        item.address === computer.address && item.token === computer.token)) return;
      this.acceptScheduleSync(computer, result);
      this.setScheduleOffline(computer.address, false);
      if (includeJobs && generation === this.scheduleComputerGeneration && this.host.activeTab() === 'pending' &&
        !this.state.scheduleSaving && !this.state.scheduleLoading) this.applyScheduleJobs(result);
      this.scheduleRetries.delete(computer.address);
      this.scheduleDue.set(computer.address, Date.now() + 12_000);
    } catch (error) {
      if (mutation !== this.scheduleMutation || !this.host.computers().some((item: Companion): boolean =>
        item.address === computer.address && item.token === computer.token)) return;
      if (error instanceof BridgeFailure && (error.status === 401 || error.status === 404)) {
        this.setScheduleWatch(computer.address, '', false);
        this.setScheduleOffline(computer.address, false);
        this.state.scheduleMessages = this.state.scheduleMessages.filter((message: RunMessage): boolean => message.address !== computer.address);
        this.state.scheduleActive = this.state.scheduleActive.filter((message: RunMessage): boolean => message.address !== computer.address);
        return;
      }
      const retries = Math.min(5, (this.scheduleRetries.get(computer.address) ?? 0) + 1);
      this.scheduleRetries.set(computer.address, retries);
      this.scheduleDue.set(computer.address, Date.now() + 6000 * Math.pow(2, retries));
      this.setScheduleOffline(computer.address, true);
      if (watch?.source) {
        const alternatives = this.host.computers().filter((item: Companion): boolean =>
          item.address !== computer.address && computerGroupId(item) === computerGroupId(computer));
        for (const alternate of alternatives) {
          try {
            const result = await this.host.request('/schedules/sync', { knownRuns: knownRuns }, this.host.scheduleEndpoint(alternate));
            if (result.source !== watch.source || !this.host.visible() || mutation !== this.scheduleMutation ||
              !this.host.computers().some((item: Companion): boolean =>
              item.address === alternate.address && item.token === alternate.token)) continue;
            this.acceptScheduleSync(alternate, result);
            this.setScheduleOffline(computer.address, false);
            this.setScheduleOffline(alternate.address, false);
            // Keep the original connection under backoff so either transport can recover.
            break;
          } catch { }
        }
      }
    }
  }

  private setScheduleOffline(address: string, offline: boolean): void {
    if (this.state.scheduleOffline.includes(address) === offline) return;
    this.state.scheduleOffline = offline ? this.state.scheduleOffline.concat([address]) :
      this.state.scheduleOffline.filter((item: string): boolean => item !== address);
  }

  private acceptScheduleSync(computer: Companion, result: BridgeReply): void {
    const source = result.source;
    if (!source) return;
    this.setScheduleWatch(computer.address, source, result.watching === true);
    const name = this.host.scheduleComputerName(computer);
    const readRuns = this.readScheduleRuns(source);
    const dismissedRuns = this.readScheduleRuns(source, true);
    const incoming = (result.runs ?? []).map((run: ScheduleRun): RunMessage => {
      const dismissed = dismissedRuns.includes(run.id);
      return { key: `${source}:${run.id}`, source: source, address: computer.address, computer: name, run: run,
        unread: !dismissed && !readRuns.includes(run.id), dismissed: dismissed };
    });
    const old = this.state.scheduleMessages;
    const newMessage = incoming.find((message: RunMessage): boolean => message.unread &&
      !old.some((previous: RunMessage): boolean => previous.key === message.key));
    this.state.scheduleMessages = old.filter((message: RunMessage): boolean => message.address !== computer.address &&
      !incoming.some((item: RunMessage): boolean => item.key === message.key)).concat(incoming)
      .sort((left: RunMessage, right: RunMessage): number => (right.run.finishedAt ?? 0) - (left.run.finishedAt ?? 0));
    for (const message of incoming) {
      if (message.unread && !message.dismissed) {
        this.host.queueWatchReminder(`schedule:${message.key}`, scheduleRunStatus(message.run.status), message.computer,
          message.run.name, message.run.finishedAt ?? message.run.scheduledAt);
      }
    }
    const active = (result.activeRuns ?? []).map((run: ScheduleRun): RunMessage => ({
      key: `${source}:${run.id}`, source: source, address: computer.address, computer: name, run: run, unread: false
    }));
    this.state.scheduleActive = this.state.scheduleActive.filter((message: RunMessage): boolean => message.address !== computer.address &&
      !active.some((item: RunMessage): boolean => item.key === message.key) &&
      !incoming.some((item: RunMessage): boolean => item.key === message.key)).concat(active);
    if (newMessage && !this.state.schedulePage && this.host.runNoticesEnabled()) {
      this.state.scheduleBanner = newMessage;
      if (this.scheduleBannerTimer !== -1) clearTimeout(this.scheduleBannerTimer);
      this.scheduleBannerTimer = setTimeout(() => { this.state.scheduleBanner = undefined; }, 6500);
    }
    this.host.publishWidgets();
  }

  private readScheduleRuns(source: string, dismissed: boolean = false): string[] {
    const cache = dismissed ? this.scheduleDismissed : this.scheduleRead;
    const key = dismissed ? `schedule_dismissed_${source}` : `schedule_read_${source}`;
    const cached = cache.get(source);
    if (cached) return cached;
    let read: string[] = [];
    try {
      const raw = this.host.settings()?.getSync(key, '[]') as string;
      if (raw) {
        const ids = JSON.parse(raw) as string[];
        if (Array.isArray(ids)) {
          read = ids.filter((id: string): boolean => typeof id === 'string');
          if (!dismissed) read = read.slice(0, 80);
        }
      }
    } catch { }
    cache.set(source, read);
    return read;
  }

  async dismissScheduleMessages(messages: RunMessage[]): Promise<boolean> {
    if (this.state.scheduleDismissing || this.state.scheduleSaving || !messages.length) return false;
    const idsBySource = new Map<string, Set<string>>();
    for (const message of messages) {
      const ids = idsBySource.get(message.source) ?? new Set<string>();
      ids.add(message.run.id);
      idsBySource.set(message.source, ids);
    }
    this.state.scheduleDismissing = true;
    let savedAll = true;
    try {
      for (const source of idsBySource.keys()) {
        const ids = idsBySource.get(source)!;
        const dismissed = new Set<string>(this.readScheduleRuns(source, true));
        ids.forEach((id: string) => { dismissed.add(id); });
        const savedIds = Array.from(dismissed);
        try {
          await this.host.saveSetting(`schedule_dismissed_${source}`, JSON.stringify(savedIds));
        } catch {
          savedAll = false;
          continue;
        }
        this.scheduleDismissed.set(source, savedIds);
        this.state.scheduleMessages = this.state.scheduleMessages.map((item: RunMessage): RunMessage =>
          item.source === source && ids.has(item.run.id) ?
            { key: item.key, source: item.source, address: item.address, computer: item.computer, run: item.run,
              unread: false, dismissed: true } : item);
        const banner = this.state.scheduleBanner;
        if (banner && banner.source === source && ids.has(banner.run.id)) this.state.scheduleBanner = undefined;
      }
      this.host.publishWidgets();
      if (!savedAll) this.host.getUIContext().getPromptAction().showToast({ message: '部分动态暂时无法移除，请重试。' });
      return savedAll;
    } finally {
      this.state.scheduleDismissing = false;
    }
  }

  private removeScheduleMessage(message: RunMessage): void {
    this.state.scheduleMessages = this.state.scheduleMessages.filter((item: RunMessage): boolean => item.key !== message.key);
    if (this.state.scheduleBanner?.key === message.key) this.state.scheduleBanner = undefined;
    if (this.state.scheduleDetail?.key === message.key) this.state.scheduleDetail = undefined;
    const read = this.readScheduleRuns(message.source);
    if (read.includes(message.run.id)) {
      const nextRead = read.filter((id: string): boolean => id !== message.run.id);
      this.scheduleRead.set(message.source, nextRead);
      void this.host.saveSetting(`schedule_read_${message.source}`, JSON.stringify(nextRead)).catch(() => {});
    }
    const dismissed = this.readScheduleRuns(message.source, true);
    if (dismissed.includes(message.run.id)) {
      const nextDismissed = dismissed.filter((id: string): boolean => id !== message.run.id);
      this.scheduleDismissed.set(message.source, nextDismissed);
      void this.host.saveSetting(`schedule_dismissed_${message.source}`, JSON.stringify(nextDismissed)).catch(() => {});
    }
  }

  async deleteScheduleRuns(messages: RunMessage[]): Promise<boolean> {
    if (this.state.scheduleSaving || this.state.scheduleDismissing || !messages.length) return false;
    const computer = this.host.computers().find((item: Companion): boolean => item.address === this.host.base());
    if (!computer) {
      this.host.getUIContext().getPromptAction().showToast({ message: '请先连接电脑。' });
      return false;
    }
    const generation = this.scheduleComputerGeneration;
    this.state.scheduleSaving = true;
    this.state.scheduleError = '';
    let deleted = 0;
    let failureText = '';
    try {
      for (const message of messages) {
        if (generation !== this.scheduleComputerGeneration) return false;
        try {
          const payload: Payload = { operation: 'delete-run', cwd: message.run.cwd, id: message.run.id };
          await this.host.request('/schedules/update', payload, this.host.scheduleEndpoint(computer));
          this.scheduleMutation += 1;
          this.removeScheduleMessage(message);
          deleted += 1;
        } catch (error) {
          const failure = error as Error;
          if (!failureText) failureText = failure.message === 'schedule_missing' ?
            '请先更新电脑端 Pi Go。' : this.scheduleFailure(failure);
          if (!(error instanceof BridgeFailure) || error.status === 401 || error.status === 404 ||
            error.status >= 500 || failure.message === 'desktop_handoff_required' ||
            failure.message === 'desktop_handoff_unconfirmed') break;
        }
      }
      if (generation !== this.scheduleComputerGeneration) return false;
      if (failureText) {
        const message = deleted ? `已删除 ${deleted} 条。${failureText}` : failureText;
        this.host.getUIContext().getPromptAction().showToast({ message: message });
      }
      return deleted === messages.length;
    } finally {
      this.queueScheduleSync(true);
      if (generation === this.scheduleComputerGeneration) this.state.scheduleSaving = false;
    }
  }

  showScheduleDetail(message: RunMessage, fromInbox: boolean = false): void {
    this.host.dismissKeyboard();
    this.schedulePrevious = this.state.schedulePage;
    this.state.scheduleDetail = message;
    this.state.scheduleDetailFromInbox = fromInbox && !message.dismissed;
    this.state.scheduleResult = message.run.hasFullResult ? '' : (message.run.summary ?? '');
    this.state.scheduleResultError = '';
    this.state.scheduleError = '';
    this.state.schedulePage = 'detail';
    this.state.scheduleBanner = undefined;
    if (message.run.hasFullResult) void this.loadScheduleResult();
    if (!message.unread) return;
    const read = [message.run.id].concat(this.readScheduleRuns(message.source)
      .filter((id: string): boolean => id !== message.run.id)).slice(0, 80);
    this.scheduleRead.set(message.source, read);
    this.state.scheduleMessages = this.state.scheduleMessages.map((item: RunMessage): RunMessage => item.key === message.key
      ? { key: item.key, source: item.source, address: item.address, computer: item.computer, run: item.run, unread: false } : item);
    void this.host.saveSetting(`schedule_read_${message.source}`, JSON.stringify(read)).catch(() => {});
  }

  async dismissScheduleDetail(): Promise<void> {
    const message = this.state.scheduleDetail;
    if (this.state.schedulePage !== 'detail' || !this.state.scheduleDetailFromInbox || !message) return;
    if (await this.dismissScheduleMessages([message])) {
      if (this.state.schedulePage === 'detail' && this.state.scheduleDetail === message) this.backFromSchedule();
    }
  }

  async loadScheduleResult(): Promise<void> {
    const message = this.state.scheduleDetail;
    if (!message || !message.run.hasFullResult || this.state.schedulePage !== 'detail') return;
    const request = ++this.scheduleResultRequest;
    this.state.scheduleResultError = '';
    const computer = this.host.computers().find((item: Companion): boolean => item.address === message.address);
    try {
      if (!computer) throw new Error('schedule_computer_missing');
      const endpoint = this.host.scheduleEndpoint(computer);
      const text = await this.loadResultText((offset: number): Promise<BridgeReply> => this.host.request('/schedules/result',
        { cwd: message.run.cwd, id: message.run.id, source: message.source, offset: offset }, endpoint),
        (): boolean => this.isCurrentScheduleResult(message, request));
      if (text !== undefined && this.isCurrentScheduleResult(message, request)) this.state.scheduleResult = text;
    } catch {
      if (this.isCurrentScheduleResult(message, request)) this.state.scheduleResultError = '暂时无法加载运行结果。';
    }
  }

  private async loadResultText(fetchPage: (offset: number) => Promise<BridgeReply>, isCurrent: () => boolean): Promise<string | undefined> {
    const chunks: string[] = [];
    let offset: number | undefined = 0;
    while (offset !== undefined) {
      const page: BridgeReply = await fetchPage(offset);
      if (!isCurrent()) return undefined;
      if (!page.text || (page.nextTextOffset !== undefined && page.nextTextOffset !== offset + page.text.length)) {
        throw new Error('invalid_result_page');
      }
      chunks.push(page.text);
      offset = page.nextTextOffset;
    }
    return chunks.join('');
  }

  showSessionRunDetail(row: InboxRun): void {
    this.host.dismissKeyboard();
    this.scheduleResultRequest += 1;
    this.schedulePrevious = this.state.schedulePage;
    this.state.sessionRunDetail = row;
    this.state.sessionRunResult = '';
    this.state.sessionRunResultError = '';
    this.state.scheduleError = '';
    this.state.schedulePage = 'session-run';
    if (row.unread) this.host.markRunRead(row.run.id);
    if (row.run.hasFullResult) void this.loadSessionRunResult();
  }

  async loadSessionRunResult(): Promise<void> {
    const row = this.state.sessionRunDetail;
    if (!row?.run.hasFullResult || this.state.schedulePage !== 'session-run') return;
    const request = ++this.scheduleResultRequest;
    const isCurrent = (): boolean => request === this.scheduleResultRequest && this.state.schedulePage === 'session-run';
    this.state.sessionRunResultError = '';
    try {
      const computer = this.host.computers().find((item: Companion): boolean => item.address === row.address);
      if (!computer) throw new Error('run_computer_missing');
      const endpoint = this.host.scheduleEndpoint(computer);
      const path = '/runs/text?session=' + encodeURIComponent(row.run.sessionId) + '&run=' + encodeURIComponent(row.run.id);
      const text = await this.loadResultText((offset: number): Promise<BridgeReply> =>
        this.host.request(path + '&offset=' + offset, undefined, endpoint), isCurrent);
      if (text !== undefined && isCurrent()) this.state.sessionRunResult = text;
    } catch {
      if (isCurrent()) this.state.sessionRunResultError = '暂时无法加载运行结果。';
    }
  }

  async openSessionRun(): Promise<void> {
    const row = this.state.sessionRunDetail;
    if (!row || this.state.schedulePage !== 'session-run') return;
    const computer = this.host.computers().find((item: Companion): boolean =>
      item.address === row.address && validCompanion(item));
    this.state.scheduleError = '';
    if (computer && await this.host.openNotifiedSession(computer, row.run.sessionId, '', '')) return;
    if (this.state.schedulePage === 'session-run' && !this.state.scheduleError) {
      this.state.scheduleError = '暂时无法打开会话，请检查来源电脑。';
    }
  }

  private isCurrentScheduleResult(message: RunMessage, request: number): boolean {
    return request === this.scheduleResultRequest && this.state.schedulePage === 'detail' &&
      this.state.scheduleDetail?.key === message.key;
  }

  showAlertSourceHistory(source: string): void {
    this.host.dismissKeyboard();
    this.schedulePrevious = this.state.schedulePage;
    this.state.scheduleAlertSource = source.trim() || 'local';
    this.state.schedulePage = 'source_history';
    this.state.scheduleError = '';
  }

  showAlertDetail(row: InboxRun): void {
    this.host.dismissKeyboard();
    this.schedulePrevious = this.state.schedulePage;
    this.state.scheduleAlert = row;
    this.state.schedulePage = 'alert';
    this.state.scheduleError = '';
  }

  backFromSchedule(): void {
    if (this.state.scheduleSaving || this.host.inboxCleaning()) return;
    if (this.state.schedulePage === 'detail') {
      this.state.scheduleDetail = undefined;
      this.state.scheduleDetailFromInbox = false;
      this.state.scheduleResult = '';
      this.state.scheduleResultError = '';
      this.state.schedulePage = this.schedulePrevious;
    } else if (this.state.schedulePage === 'alert') {
      this.state.scheduleAlert = undefined;
      this.state.schedulePage = this.schedulePrevious;
    } else if (this.state.schedulePage === 'source_history') {
      this.state.scheduleAlertSource = '';
      this.state.schedulePage = '';
    } else if (this.state.schedulePage === 'session-run') {
      this.scheduleResultRequest += 1;
      this.state.sessionRunDetail = undefined;
      this.state.sessionRunResult = '';
      this.state.sessionRunResultError = '';
      this.state.schedulePage = this.schedulePrevious;
    } else this.state.schedulePage = '';
    this.state.scheduleError = '';
  }

  async loadScheduleJobs(): Promise<void> {
    const computer = this.host.computers().find((item: Companion): boolean => item.address === this.host.base());
    if (!computer || this.state.scheduleLoading) return;
    const generation = this.scheduleComputerGeneration;
    this.state.scheduleLoading = true;
    this.state.scheduleListError = '';
    try {
      const result = await this.host.request('/schedules/sync', { includeJobs: true }, this.host.scheduleEndpoint(computer));
      if (generation !== this.scheduleComputerGeneration) return;
      this.applyScheduleJobs(result);
      this.acceptScheduleSync(computer, result);
    } catch (error) {
      if (generation === this.scheduleComputerGeneration) this.state.scheduleListError = this.scheduleFailure(error as Error);
    } finally {
      if (generation === this.scheduleComputerGeneration) this.state.scheduleLoading = false;
    }
  }

  private applyScheduleJobs(result: BridgeReply): void {
    this.state.scheduleJobs = (result.jobs ?? []).sort((left: ScheduleJob, right: ScheduleJob): number =>
      (left.nextAt ?? Number.MAX_SAFE_INTEGER) - (right.nextAt ?? Number.MAX_SAFE_INTEGER));
    this.state.scheduleZone = result.timezone ?? '';
    this.state.scheduleListError = '';
    this.state.scheduleLoaded = true;
    this.host.publishWidgets();
  }

  resetScheduleJobs(): void {
    this.scheduleComputerGeneration += 1;
    this.state.scheduleJobs = [];
    this.state.scheduleZone = '';
    this.state.scheduleListError = '';
    this.state.scheduleLoading = false;
    this.state.scheduleLoaded = false;
    this.state.scheduleSaving = false;
    if (this.state.schedulePage === 'editor' || this.state.schedulePage === 'history') this.state.schedulePage = '';
    if (this.schedulePrevious === 'history') this.schedulePrevious = '';
  }

  editSchedule(job?: ScheduleJob): void {
    this.state.scheduleEditing = job;
    this.state.scheduleName = job?.name ?? '';
    this.state.schedulePrompt = job?.prompt ?? '';
    this.state.scheduleCwd = job?.cwd ?? (this.host.projects().includes(this.host.workspaceCwd()) ? this.host.workspaceCwd() : this.host.projects()[0] ?? '');
    this.state.scheduleKind = job?.kind ?? 'once';
    this.state.scheduleWhen = job?.kind === 'daily' ? job.time ?? '' : job?.kind === 'interval' ? String(job.interval ?? 60) :
      scheduleTime(job?.at ?? Date.now() + 120_000);
    this.state.scheduleCatchUp = String(job?.catchUp ?? 0);
    this.state.scheduleError = '';
    this.state.schedulePage = 'editor';
  }

  private scheduleFailure(error: Error): string {
    const code = error.message;
    if (code === 'not_found' || code === 'schedules_unsupported') return '请先更新电脑端 Pi Go。';
    if (code === 'desktop_workspace_unshared') return '请先在电脑端共享所选工作区。';
    if (code === 'schedule_changed') return '定时任务已被修改，请返回列表刷新。';
    if (code === 'schedule_busy') return '任务已在运行，或电脑已达并发上限。';
    if (code === 'schedule_expired') return '请编辑并选择新的执行时间。';
    if (code === 'invalid_schedule') return '请检查时间、补跑窗口和提示词。';
    return '电脑端未确认操作结果，请检查连接后刷新。';
  }

  async updateSchedule(operation: string, job?: ScheduleJob): Promise<void> {
    if (this.state.scheduleSaving || this.state.scheduleLoading) return;
    const computer = this.host.computers().find((item: Companion): boolean => item.address === this.host.base());
    if (!computer) { this.state.scheduleError = '请先连接电脑。'; return; }
    const payload: Payload = { operation: operation, cwd: job?.cwd ?? this.state.scheduleCwd, id: job?.id,
      scheduleVersion: job?.version, requestId: util.generateRandomUUID() };
    if (operation === 'create' || operation === 'edit') {
      const when = this.state.scheduleWhen.trim();
      const catchUp = this.state.scheduleCatchUp.trim();
      if (!payload.cwd || !this.state.scheduleName.trim() || !this.state.schedulePrompt.trim() ||
        this.state.schedulePrompt.trim().startsWith('/') || !/^\d{1,4}$/.test(catchUp) || Number(catchUp) > 1440) {
        this.state.scheduleError = '请选择工作区并填写名称、提示词和有效的补跑分钟数。';
        return;
      }
      payload.name = this.state.scheduleName;
      payload.prompt = this.state.schedulePrompt;
      payload.kind = this.state.scheduleKind;
      payload.catchUp = Number(catchUp);
      if (this.state.scheduleKind === 'once') {
        payload.at = parseScheduleTime(when);
        if (payload.at <= Date.now()) { this.state.scheduleError = '请输入未来时间，格式为 YYYY-MM-DD HH:mm。'; return; }
      } else if (this.state.scheduleKind === 'daily') {
        if (!/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(when)) { this.state.scheduleError = '请输入 24 小时时间，格式为 HH:mm。'; return; }
        payload.time = when;
      } else {
        if (!/^\d{1,5}$/.test(when) || Number(when) < 1 || Number(when) > 10080) {
          this.state.scheduleError = '间隔须为 1 至 10080 分钟。'; return;
        }
        payload.interval = Number(when);
      }
    }
    const generation = this.scheduleComputerGeneration;
    const editing = operation === 'create' || operation === 'edit';
    this.state.scheduleSaving = true;
    this.state.scheduleError = '';
    try {
      await this.host.request('/schedules/update', payload, this.host.scheduleEndpoint(computer));
      this.scheduleMutation += 1;
      const current = this.scheduleWatches.find((watch: ScheduleWatch): boolean => watch.address === computer.address);
      this.setScheduleWatch(computer.address, current?.source ?? '', true);
      this.queueScheduleSync(true);
      if (generation !== this.scheduleComputerGeneration) return;
      if (editing) this.state.schedulePage = '';
      if (operation === 'run') this.host.getUIContext().getPromptAction().showToast({ message: '已提交到电脑运行' });
      await this.loadScheduleJobs();
    } catch (error) {
      if (generation === this.scheduleComputerGeneration) {
        const message = this.scheduleFailure(error as Error);
        if (editing) this.state.scheduleError = message;
        else this.host.getUIContext().getPromptAction().showToast({ message: message });
      }
    } finally {
      if (generation === this.scheduleComputerGeneration) this.state.scheduleSaving = false;
    }
  }
}
