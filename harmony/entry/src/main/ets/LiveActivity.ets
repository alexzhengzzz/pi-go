import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { liveViewManager } from '@kit.LiveViewKit';

export interface LiveActivitySnapshot {
  sessionId: string;
  address: string;
  title: string;
  project: string;
  state: string;
  foreground: boolean;
}

const LIVE_VIEW_ID: number = 18977;
const WANT_REQUEST_CODE: number = 18978;
const RETRY_INTERVAL_MS: number = 30000;

function clipped(value: string, fallback: string, max: number): string {
  const normalized = value.replace(/[\r\n\t]+/g, ' ').trim();
  if (!normalized) return fallback;
  return normalized.length > max ? normalized.substring(0, max - 1) + '…' : normalized;
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
  private activeSnapshot?: LiveActivitySnapshot = undefined;
  private lastSignature: string = '';
  private sequence: number = 0;
  private retryAfter: number = 0;
  private clickKey: string = '';
  private clickAction?: WantAgent = undefined;
  private statusCallback?: (status: string) => void = undefined;

  attach(context: common.UIAbilityContext, statusCallback: (status: string) => void): void {
    this.context = context;
    this.statusCallback = statusCallback;
  }

  sync(snapshot?: LiveActivitySnapshot): void {
    const revision = ++this.revision;
    this.work = this.work.then(async (): Promise<void> => {
      if (revision !== this.revision) return;
      await this.apply(snapshot);
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
    this.lastSignature = '';
    this.retryAfter = 0;
    this.statusCallback = undefined;
  }

  private reportError(code?: number): void {
    const status = code === 1003500005 ? 'rights' : code === 1003500004 ? 'disabled' : 'error';
    if (this.statusCallback) this.statusCallback(status);
  }

  private async apply(snapshot?: LiveActivitySnapshot): Promise<void> {
    if (!snapshot) {
      await this.stopCurrent();
      this.lastSignature = '';
      return;
    }
    if (!this.context || Date.now() < this.retryAfter) return;
    const key = `${snapshot.address}|${snapshot.sessionId}`;
    const signature = `${key}|${snapshot.title}|${snapshot.project}|${snapshot.state}`;
    if (this.started && this.activeKey === key && this.lastSignature === signature) return;
    if (this.started && this.activeKey !== key) await this.stopCurrent();
    // Live View Kit only permits creation while the app is in the foreground.
    if (!this.started && !snapshot.foreground) return;
    if (this.started) await this.updateCurrent(snapshot, signature);
    else await this.startCurrent(snapshot, key, signature);
  }

  private async startCurrent(snapshot: LiveActivitySnapshot, key: string, signature: string): Promise<void> {
    try {
      if (!await liveViewManager.isLiveViewEnabled()) {
        this.reportError(1003500004);
        this.deferRetry();
        return;
      }
      const view = await this.buildView(snapshot, 1, false);
      const result = await liveViewManager.startLiveView(view);
      if (result.resultCode !== 0) {
        this.reportError();
        this.deferRetry();
        return;
      }
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
      console.warn(`[PiGoLiveView] start failed, code=${code ?? 'unknown'}`);
      this.reportError(code);
      this.deferRetry();
    }
  }

  private async adoptCurrent(snapshot: LiveActivitySnapshot, key: string, signature: string): Promise<void> {
    try {
      const active = await liveViewManager.getActiveLiveView(LIVE_VIEW_ID);
      this.started = true;
      this.activeKey = key;
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
      console.warn(`[PiGoLiveView] update failed, code=${code ?? 'unknown'}`);
      this.reportError(code);
      if (code === 1003500009 || code === 1003500010) {
        this.started = false;
        this.activeKey = '';
        this.activeSnapshot = undefined;
        this.lastSignature = '';
      }
      this.deferRetry();
    }
  }

  private async stopCurrent(): Promise<void> {
    if (!this.started) return;
    const snapshot = this.activeSnapshot;
    this.started = false;
    this.activeKey = '';
    this.activeSnapshot = undefined;
    this.lastSignature = '';
    if (!snapshot) return;
    try {
      const view = await this.buildView(snapshot, ++this.sequence, true);
      await liveViewManager.stopLiveView(view);
    } catch (error) {
      console.warn(`[PiGoLiveView] stop failed, code=${(error as BusinessError).code ?? 'unknown'}`);
    }
  }

  private deferRetry(): void {
    this.retryAfter = Date.now() + RETRY_INTERVAL_MS;
  }

  private async buildView(snapshot: LiveActivitySnapshot, sequence: number,
    stopping: boolean): Promise<liveViewManager.LiveView> {
    const title = clipped(snapshot.title, 'Agent 任务', 80);
    const project = clipped(snapshot.project, '', 60);
    const state = stopping ? '已结束' : clipped(snapshot.state, '运行中', 20);
    const clickAction = await this.getClickAction(snapshot);
    const primary: liveViewManager.PrimaryData = {
      title: title,
      content: [{ text: project ? `${project} · ${state}` : state }],
      keepTime: 0,
      aliveTime: 28800,
      clickAction: clickAction,
      extensionData: {
        type: liveViewManager.ExtensionType.EXTENSION_TYPE_COMMON_TEXT,
        text: stopping ? '已完成' : 'Pi Go'
      },
      layoutData: { layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT }
    };
    const capsule: liveViewManager.TextCapsule = {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
      status: stopping ? -1 : 1,
      icon: 'pigo.png',
      backgroundColor: '#FF356B5F',
      title: 'Pi Go',
      content: state,
      isContentDisplayed: true,
      isTailIconDisplayed: false
    };
    return {
      id: LIVE_VIEW_ID,
      event: 'PROGRESS',
      sequence: sequence,
      isMute: true,
      liveViewData: { primary: primary, capsule: capsule }
    };
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
