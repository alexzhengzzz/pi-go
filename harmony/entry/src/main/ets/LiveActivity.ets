import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { liveViewManager } from '@kit.LiveViewKit';

export interface LiveActivitySnapshot {
  sessionId: string;
  address: string;
  state: string;
  foreground: boolean;
  title?: string;
  summary?: string;
  badge?: string;
  progress?: number;
}

const LIVE_VIEW_ID: number = 18977;
const WANT_REQUEST_CODE: number = 18978;
const RETRY_INTERVAL_MS: number = 30000;

function clipLiveText(value: string | undefined, maxChars: number, fallback: string): string {
  const cleaned = (value ?? '').replace(/\s+/g, ' ').trim();
  if (!cleaned) return fallback;
  const chars = Array.from(cleaned);
  return chars.length > maxChars ? `${chars.slice(0, maxChars - 1).join('')}…` : cleaned;
}

/**
 * Owns the single local live view used by the selected Agent run.
 * Calls are serialized and only the newest requested state is applied.
 */
export class LiveActivityController {
  private context?: common.UIAbilityContext = undefined;
  private work: Promise<void> = Promise.resolve();
  private revision: number = 0;
  private started: boolean = false;
  private activeKey: string = '';
  private dismissedKey: string = '';
  private activeSnapshot?: LiveActivitySnapshot = undefined;
  private lastSignature: string = '';
  private startedAt: number = 0;
  private sequence: number = 0;
  private retryAfter: number = 0;
  private clickKey: string = '';
  private clickAction?: WantAgent = undefined;
  private statusCallback?: (status: string) => void = undefined;

  attach(context: common.UIAbilityContext, statusCallback: (status: string) => void): void {
    this.context = context;
    this.statusCallback = statusCallback;
  }

  detach(context: common.UIAbilityContext): void {
    if (this.context !== context) return;
    this.context = undefined;
    this.statusCallback = undefined;
  }

  sync(snapshot?: LiveActivitySnapshot, owner?: common.UIAbilityContext): void {
    if (owner && this.context && owner !== this.context) return;
    const revision = ++this.revision;
    this.work = this.work.then(async (): Promise<void> => {
      if (snapshot && revision !== this.revision) return;
      await this.apply(revision, snapshot);
    }).catch((error: Error): void => {
      const code = (error as BusinessError).code;
      console.warn(`[PiGoLiveView] sync failed, code=${code ?? 'unknown'}`);
    });
  }

  async dispose(): Promise<void> {
    ++this.revision;
    this.work = this.work.then(async (): Promise<void> => { await this.stopCurrent(); }).catch((): void => {});
    await this.work;
    this.context = undefined;
    this.clickAction = undefined;
    this.clickKey = '';
    this.dismissedKey = '';
    this.lastSignature = '';
    this.retryAfter = 0;
    this.statusCallback = undefined;
  }

  private reportError(code?: number): void {
    const status = code === 1003500005 ? 'rights' : code === 1003500004 ? 'disabled' : 'error';
    if (this.statusCallback) this.statusCallback(status);
  }

  private async apply(revision: number, snapshot?: LiveActivitySnapshot): Promise<void> {
    if (!snapshot) {
      this.dismissedKey = '';
      await this.stopCurrent();
      return;
    }
    if (!this.context || Date.now() < this.retryAfter) return;
    const key = `${snapshot.address}|${snapshot.sessionId}`;
    if (this.dismissedKey === key) return;
    const signature = `${snapshot.state}|${snapshot.title ?? ''}|${snapshot.summary ?? ''}|${snapshot.badge ?? ''}|${snapshot.progress ?? 0}`;
    if (this.started && this.activeKey === key && this.lastSignature === signature) return;
    if (this.started && this.activeKey !== key) await this.stopCurrent();
    if (this.started && this.activeKey !== key) return;
    // Live View Kit only permits creation while the app is in the foreground.
    if (!this.started && !snapshot.foreground) return;
    if (this.started) await this.updateCurrent(snapshot, signature);
    else await this.startCurrent(snapshot, key, signature, revision);
  }

  private async startCurrent(snapshot: LiveActivitySnapshot, key: string, signature: string,
    revision: number): Promise<void> {
    try {
      if (!await liveViewManager.isLiveViewEnabled()) {
        console.warn('[PiGoLiveView] disabled in system settings');
        this.reportError(1003500004);
        this.deferRetry();
        return;
      }
      this.startedAt = Date.now();
      const view = await this.buildView(snapshot, 1, false);
      if (revision !== this.revision) return;
      const result = await liveViewManager.startLiveView(view);
      if (result.resultCode !== 0) {
        console.warn(`[PiGoLiveView] start result=${result.resultCode}`);
        this.reportError();
        this.deferRetry();
        return;
      }
      console.info(`[PiGoLiveView] started state=${snapshot.state}`);
      if (this.statusCallback) this.statusCallback('');
      this.started = true;
      this.activeKey = key;
      this.activeSnapshot = snapshot;
      this.lastSignature = signature;
      this.sequence = 1;
      this.retryAfter = 0;
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code === 1003500006) {
        // Recover a persisted live view left by an earlier application process.
        await this.adoptCurrent(snapshot, key, signature);
        return;
      }
      console.warn(`[PiGoLiveView] start failed, code=${code ?? 'unknown'} msg=${(error as BusinessError).message ?? ''}`);
      this.reportError(code);
      this.deferRetry();
    }
  }

  private async adoptCurrent(snapshot: LiveActivitySnapshot, key: string, signature: string): Promise<void> {
    try {
      const active = await liveViewManager.getActiveLiveView(LIVE_VIEW_ID);
      this.started = true;
      this.activeKey = key;
      this.activeSnapshot = snapshot;
      this.sequence = active.sequence !== undefined && active.sequence >= 0 && active.sequence < 2147483647 ?
        active.sequence : 0;
      await this.updateCurrent(snapshot, signature);
    } catch (error) {
      this.started = false;
      this.activeSnapshot = undefined;
      const code = (error as BusinessError).code;
      console.warn(`[PiGoLiveView] adopt failed, code=${code ?? 'unknown'}`);
      this.reportError(code);
      this.deferRetry();
    }
  }

  private async updateCurrent(snapshot: LiveActivitySnapshot, signature: string): Promise<void> {
    try {
      const view = await this.buildView(snapshot, ++this.sequence, false);
      const result = await liveViewManager.updateLiveView(view);
      if (result.resultCode !== 0) {
        console.warn(`[PiGoLiveView] update result=${result.resultCode}`);
        this.reportError();
        this.deferRetry();
        return;
      }
      if (this.statusCallback) this.statusCallback('');
      this.activeSnapshot = snapshot;
      this.lastSignature = signature;
      this.retryAfter = 0;
    } catch (error) {
      const code = (error as BusinessError).code;
      console.warn(`[PiGoLiveView] update failed, code=${code ?? 'unknown'} msg=${(error as BusinessError).message ?? ''}`);
      if (code === 1003500009 || code === 1003500010) {
        this.dismissedKey = this.activeKey;
        this.clearCurrent();
        return;
      }
      this.reportError(code);
      this.deferRetry();
    }
  }

  private async stopCurrent(): Promise<void> {
    if (!this.started) return;
    const snapshot = this.activeSnapshot;
    if (!snapshot) return;
    try {
      const view = await this.buildView(snapshot, ++this.sequence, true);
      const result = await liveViewManager.stopLiveView(view);
      if (result.resultCode !== 0) {
        console.warn(`[PiGoLiveView] stop result=${result.resultCode}`);
        return;
      }
      this.clearCurrent();
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code === 1003500009 || code === 1003500010) this.clearCurrent();
      else console.warn(`[PiGoLiveView] stop failed, code=${code ?? 'unknown'}`);
    }
  }

  private clearCurrent(): void {
    this.started = false;
    this.activeKey = '';
    this.activeSnapshot = undefined;
    this.lastSignature = '';
    this.startedAt = 0;
  }

  private deferRetry(): void {
    this.retryAfter = Date.now() + RETRY_INTERVAL_MS;
  }

  private async buildView(snapshot: LiveActivitySnapshot, sequence: number,
    stopping: boolean): Promise<liveViewManager.LiveView> {
    const state = stopping ? '已完成' : snapshot.state;
    const waiting = !stopping && state === '等待处理';
    const accent = waiting ? '#FFD97706' : '#FF356B5F';
    const track = waiting ? '#1FD97706' : '#1F356B5F';
    const clickAction = await this.getClickAction(snapshot);
    const title = stopping ? '本轮任务已完成' : clipLiveText(snapshot.title, 40, 'Agent 运行中');
    const summary = clipLiveText(snapshot.summary, 90, waiting ? '点按返回会话处理' : '点按查看任务进展');
    const badge = stopping ? '已完成' : clipLiveText(snapshot.badge, 12, state === '重新连接中' ? '重连中' : state);
    const progress = stopping ? 100 : Math.max(5, Math.min(95, Math.round(snapshot.progress ?? 35)));
    const progressLayout: liveViewManager.ProgressLayout = {
      layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
      progress: progress,
      color: accent,
      backgroundColor: track,
      indicatorType: liveViewManager.IndicatorType.INDICATOR_TYPE_UNDISPLAYED,
      indicatorIcon: 'pigo.png',
      lineType: liveViewManager.LineType.LINE_TYPE_NORMAL_SOLID_LINE,
      nodeIcons: ['pigo.png', 'pigo.png']
    };
    const primary: liveViewManager.PrimaryData = {
      title: title,
      content: [{ text: summary }],
      keepTime: stopping ? 15 : 0,
      aliveTime: 28800,
      clickAction: clickAction,
      extensionData: {
        type: liveViewManager.ExtensionType.EXTENSION_TYPE_CAPSULE_TEXT,
        text: badge
      },
      layoutData: progressLayout
    };
    const elapsed = this.startedAt > 0 ? Math.max(0, Date.now() - this.startedAt) : 0;
    const capsule: liveViewManager.TimerCapsule = {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
      status: stopping ? -1 : 1,
      icon: 'pigo.png',
      backgroundColor: accent,
      content: state === '重新连接中' ? '重连中' : state,
      time: elapsed,
      isCountdown: false,
      isPaused: stopping || waiting || state === '重新连接中',
      isContentDisplayed: true,
      isTailIconDisplayed: false
    };
    const view: liveViewManager.LiveView = {
      id: LIVE_VIEW_ID,
      event: 'PROGRESS',
      sequence: sequence,
      isMute: true,
      liveViewData: { primary: primary, capsule: capsule }
    };
    if (deviceInfo.apiAvailable('26.0.0')) {
      view.lifeCycleMode = liveViewManager.LifeCycleMode.AUTO_STOP_WHEN_APP_TERMINATE;
    }
    return view;
  }

  private async getClickAction(snapshot: LiveActivitySnapshot): Promise<WantAgent | undefined> {
    const key = `${snapshot.address}|${snapshot.sessionId}`;
    if (this.clickAction && this.clickKey === key) return this.clickAction;
    const context = this.context;
    if (!context) return undefined;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.applicationInfo.name,
          abilityName: 'EntryAbility',
          parameters: { pigoLiveSession: snapshot.sessionId, pigoLiveAddress: snapshot.address }
        } as Want],
        actionType: wantAgent.OperationType.START_ABILITIES,
        requestCode: WANT_REQUEST_CODE,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      this.clickAction = await wantAgent.getWantAgent(info);
      this.clickKey = key;
      return this.clickAction;
    } catch (error) {
      console.warn(`[PiGoLiveView] click action failed, code=${(error as BusinessError).code ?? 'unknown'}`);
      return undefined;
    }
  }
}

export const liveActivity: LiveActivityController = new LiveActivityController();
