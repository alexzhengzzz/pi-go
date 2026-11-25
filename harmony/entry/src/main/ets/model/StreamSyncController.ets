import type { UIContext } from '@kit.ArkUI';
import type { http } from '@kit.NetworkKit';
import type { LiveActivitySnapshot } from '../LiveActivity';
import type { ChatState } from './ChatState';
import type { ConnectionManager } from './ConnectionManager';
import type { PiGoClient } from './PiGoClient';
import { BridgeFailure } from './PiGoTypes';
import type { BridgeEndpoint, BridgeReply, ChatMessage, DraftAttachment, LiveTool, ModelOption, Payload, PendingInteraction, PendingSend,
  QueuedSteering, SessionState, StreamFrame } from './PiGoTypes';

export interface StreamSyncHost {
  session: SessionViewState;
  connection: () => ConnectionManager;
  streamEndpoint?: () => BridgeEndpoint;
  streamPath?: (path: string) => string;
  chatState: () => ChatState;
  client: () => PiGoClient;
  isPaired: () => boolean;
  visible: () => boolean;
  base: () => string;
  liveViewsEnabled: () => boolean;
  selectedTool: () => LiveTool | undefined;
  selectedToolMessageId: () => string;
  request: (path: string, input?: Payload) => Promise<BridgeReply>;
  leaveComputer: (forget: boolean) => void;
  refreshSelectedTool: (tool: LiveTool, message?: string) => void;
  chatTitle: () => string;
  closeToolDetails: () => void;
  resetCommands: () => void;
  observeSessionRun: (session: SessionState) => void;
  resetVoice: () => void;
  updateCachedSessionTitle: (id: string, name?: string) => void;
  workspaceChanged: () => void;
  showChat: () => void;
  syncCommandPalette: () => void;
  setInteraction: (interaction?: PendingInteraction) => void;
  reconcileSteering: (settled: boolean) => void;
  tryPublicConnection: () => Promise<void>;
  getUIContext: () => UIContext;
  restoreOnlineNotice: () => void;
  refreshVisibleCatalog: (connected: boolean) => void;
  sessionDeleted: (id: string) => void;
  showTextPreview: (cwd: string, path: string, text: string) => void;
  observeRun: (id: string, title: string, active: boolean, stopped?: boolean) => void;
  requestPermissionAfterDispatch: () => void;
  publishLiveActivity: (snapshot?: LiveActivitySnapshot) => void;
}

@ObservedV2
export class SessionViewState {
  pendingBottom: boolean = false;
  @Trace openingSession: boolean = false;
  @Trace openingSessionId: string = '';
  pendingSessionReveal: string = '';
  @Trace busy: boolean = false;
  @Trace reachable: boolean = false;
  @Trace idle: boolean = true;
  @Trace runId: string = '';
  @Trace queued: boolean = false;
  @Trace acceptsImage: boolean = false;
  @Trace attachments: DraftAttachment[] = [];
  @Trace project: string = '';
  @Trace workspaceCwd: string = '';
  @Trace currentAgent: string = 'pi';
  @Trace currentPermission: string = '';
  @Trace sessionName: string = '';
  @Trace currentId: string = '';
  @Trace noSession: string = '';
  @Trace status: string = '';
  @Trace draft: string = '';
  @Trace liveText: string = '';
  @Trace liveThinking: string = '';
  @Trace liveThinkingOpen: boolean = false;
  @Trace thinkingOpenIds: string[] = [];
  @Trace liveTools: LiveTool[] = [];
  syncMode: string = 'probe';
  historyStream: string = '';
  historyLeaf?: string | null;
  @Trace historyCursor?: string = undefined;
  @Trace loadingMessageText: string = '';
  @Trace messages: ChatMessage[] = [];
  @Trace interaction?: PendingInteraction = undefined;
  @Trace interactionDraft: string = '';
  liveSeq: number = 0;
  liveThinkSeq: number = 0;
  liveRevision: number = 0;
  @Trace pendingSend?: PendingSend = undefined;
  @Trace queuedSteering: QueuedSteering[] = [];
  @Trace transcriptFollow: boolean = true;
  liveViewSessionKey: string = '';
  liveViewRunId: string = '';
  liveViewPendingUntil: number = 0;
  epoch: number = 0;
  @Trace currentModel?: ModelOption = undefined;
  @Trace currentLevel: string = 'off';
  @Trace modelLabel: string = '';
  @Trace models: ModelOption[] = [];
  @Trace selectedModel: number = -1;
  @Trace selectedLevel: string = 'off';
  @Trace renameDraft: string = '';
  @Trace showSettings: boolean = false;
}

export class StreamSyncController {
  private historyLoadingEpoch?: number;
  private historyRequest: number = 0;
  private streamReq?: http.HttpRequest = undefined;
  private streamGen: number = 0;
  private streamAlive: boolean = false;
  private streamFailures: number = 0;
  private polling: boolean = false;
  private lastLiveDetailSync: number = 0;

  private readonly host: StreamSyncHost;
  private readonly session: SessionViewState;

  constructor(host: StreamSyncHost) {
    this.host = host;
    this.session = host.session;
  }

  draftKey(id: string): string {
    return `${this.host.base()}|${id}`;
  }

  rememberDraft(id: string): void {
    this.host.chatState().rememberDraft(this.draftKey(id), this.session.draft);
  }

  applySession(session: SessionState): void {
    if (session.id !== this.session.currentId) {
      this.flushStreamDeltas(false);
      this.host.closeToolDetails();
      this.host.resetVoice();
      if (this.session.currentId) this.rememberDraft(this.session.currentId);
      this.session.draft = this.host.chatState().drafts.get(this.draftKey(session.id)) ?? '';
      this.session.pendingSend = this.host.chatState().unconfirmed.get(this.draftKey(session.id));
      this.session.attachments = this.host.chatState().draftAttachments.get(this.draftKey(session.id)) ?? [];
      this.session.showSettings = false;
      this.session.models = [];
      this.session.currentId = session.id;
      this.session.messages = [];
      this.session.historyCursor = undefined;
      this.session.liveText = '';
      this.session.liveThinking = '';
      this.session.liveThinkSeq = 0;
      this.session.liveThinkingOpen = false;
      this.session.thinkingOpenIds = [];
      this.session.liveTools = [];
      this.session.liveSeq = 0;
      this.host.setInteraction();
      this.host.resetCommands();
      this.host.syncCommandPalette();
      this.session.pendingBottom = true;
      this.session.transcriptFollow = true;
    }
    this.session.noSession = '';
    if (this.session.workspaceCwd !== session.cwd) this.host.workspaceChanged();
    this.session.workspaceCwd = session.cwd;
    this.session.currentAgent = session.agent ?? 'pi';
    this.session.currentPermission = session.permission ?? '';
    this.session.project = session.cwd.split('/').pop() ?? session.cwd;
    this.session.sessionName = session.name ?? '';
    this.host.updateCachedSessionTitle(session.id, session.name);
    this.session.modelLabel = session.model ? `${session.model.name} · ${session.thinkingLevel ?? 'off'}` : '';
    this.session.currentModel = session.model;
    this.session.currentLevel = session.thinkingLevel ?? 'off';
    this.session.idle = session.idle;
    this.session.runId = session.runId ?? '';
    this.session.queued = session.queued ?? false;
    this.session.acceptsImage = session.acceptsImage ?? false;
    this.syncLiveActivity();
  }

  cacheChat(session: SessionState): void {
    const key = this.draftKey(session.id);
    const start = Math.max(0, this.session.messages.length - 60);
    const current: SessionState = this.session.syncMode === 'sequenced'
      ? { id: session.id, cwd: session.cwd, name: this.session.sessionName, idle: this.session.idle, runId: this.session.runId || null,
        queued: this.session.queued, acceptsImage: this.session.acceptsImage, model: this.session.currentModel, thinkingLevel: this.session.currentLevel }
      : session;
    this.host.chatState().cacheTranscript(key, {
      session: current, messages: this.session.messages.slice(start), liveText: this.session.liveText,
      liveSeq: this.session.liveSeq, liveThinking: this.session.liveThinking, liveThinkSeq: this.session.liveThinkSeq,
      tools: this.session.liveTools.slice(0),
      historyCursor: start > 0 ? this.session.messages[start].id : this.session.historyCursor,
      interaction: this.session.interaction
    });
  }

  presentChat(chat: BridgeReply, reveal: boolean, currentSnapshot: boolean = true): void {
    if (!chat.session) return;
    const moved = chat.session.id !== this.session.currentId;
    if (currentSnapshot || moved) this.applySession(chat.session);
    this.mergeTranscript(chat.messages ?? [], chat.historyCursor);
    if (currentSnapshot || moved) this.applyLiveSnapshot(chat, true);
    this.host.setInteraction(chat.interaction);
    this.revealChat(reveal);
  }

  revealChat(reveal: boolean): void {
    if (reveal) {
      this.session.pendingBottom = true;
      this.session.transcriptFollow = true;
      this.session.pendingSessionReveal = this.session.currentId;
    }
    this.session.showSettings = false;
    this.host.showChat();
  }

  cancelSchedule(): void {
    this.host.connection().cancelPoll();
  }

  schedule(delay: number): void {
    this.cancelSchedule();
    if (!this.host.isPaired() || (!this.host.visible() && !this.backgroundLiveActivity())) return;
    this.host.connection().schedulePoll(delay, (): void => { void this.poll(); });
  }

  stopStream(): void {
    this.host.chatState().sync.disconnect();
    this.historyRequest += 1;
    this.historyLoadingEpoch = undefined;
    this.streamGen += 1;
    this.flushStreamDeltas();
    this.host.connection().cancelRetry();
    const req = this.streamReq;
    this.streamReq = undefined;
    this.streamAlive = false;
    this.streamFailures = 0;
    if (req) req.destroy();
  }

  private streamEndpoint(): BridgeEndpoint {
    return this.host.streamEndpoint?.() ?? this.host.connection().endpoint();
  }

  private scheduleStream(delay: number): void {
    this.host.connection().cancelRetry();
    if (!this.host.isPaired() || (!this.host.visible() && !this.backgroundLiveActivity()) || !this.host.base() || !this.streamEndpoint().token) return;
    this.host.connection().scheduleRetry(delay, (): void => { this.startStream(); });
  }

  private streamDown(gen: number, delay: number): void {
    if (gen !== this.streamGen) return;
    this.host.chatState().sync.disconnect();
    this.historyRequest += 1;
    this.historyLoadingEpoch = undefined;
    if (this.session.syncMode === 'sequenced') this.schedule(0);
    this.streamGen += 1;
    this.flushStreamDeltas();
    const req = this.streamReq;
    this.streamReq = undefined;
    this.streamAlive = false;
    if (req) req.destroy();
    let retryDelay = delay;
    if (delay >= 2000) {
      const attempt = this.streamFailures;
      this.streamFailures = Math.min(this.streamFailures + 1, 5);
      const backedOff = delay >= 8000 ? delay : Math.min(15000, Math.round(delay * Math.pow(1.6, attempt)));
      retryDelay = Math.round(backedOff * (0.85 + Math.random() * 0.3));
    }
    this.scheduleStream(retryDelay);
  }

  startStream(): void {
    if (!this.host.isPaired() || (!this.host.visible() && !this.backgroundLiveActivity()) || !this.host.base() || !this.streamEndpoint().token || this.streamReq ||
        this.session.syncMode === 'probe' || (this.session.syncMode === 'sequenced' && this.session.openingSession)) return;
    const gen = ++this.streamGen;
    const path = this.session.syncMode === 'sequenced' ? '/events?sync=2' : '/events';
    this.streamReq = this.host.client().openEvents(this.streamEndpoint(), this.host.streamPath?.(path) ?? path, {
      current: (): boolean => gen === this.streamGen,
      ready: (): void => { this.streamAlive = true; this.streamFailures = 0; },
      frame: (payload: string): void => { this.handleFrame(payload); },
      closed: (delay: number): void => { this.streamDown(gen, delay); },
      revoked: (): void => { this.host.leaveComputer(true); }
    });
  }

  private queueStreamPaint(): void {
    this.host.chatState().queueStreamPaint((): void => { this.flushStreamDeltas(); });
  }

  flushStreamDeltas(paint: boolean = true): void {
    const delta = this.host.chatState().flushStreamDeltas(this.session.liveText, this.session.liveThinking, paint);
    if (!delta) return;
    this.session.pendingBottom = true;
    this.session.liveText = delta.text;
    this.session.liveThinking = delta.thinking;
  }

  private handleFrame(raw: string): void {
    if (this.host.chatState().receiveFrame(raw, this.session.syncMode === 'sequenced', (event: StreamFrame): void => this.applyStreamFrame(event))) {
      this.schedule(0);
    }
  }

  private applyStreamFrame(frame: StreamFrame): void {
    if (frame.sessionId && frame.sessionId !== this.session.currentId) {
      if (frame.type === 'session/changed' || frame.type === 'ready') this.schedule(150);
      return;
    }
    if (frame.type === 'message/delta') {
      if (typeof frame.text === 'string' && frame.text && (frame.cursor !== undefined || frame.seq === undefined || frame.seq > this.session.liveSeq)) {
        const hadText = !!this.session.liveText;
        this.host.chatState().appendDelta(frame.text, false);
        if (frame.seq !== undefined) this.session.liveSeq = frame.seq;
        this.queueStreamPaint();
        if (!hadText || Date.now() - this.lastLiveDetailSync >= 3500) {
          this.lastLiveDetailSync = Date.now();
          this.syncLiveActivity();
        }
      }
      return;
    }
    if (frame.type === 'message/thinking') {
      if (typeof frame.text === 'string' && frame.text && (frame.cursor !== undefined || frame.seq === undefined || frame.seq > this.session.liveThinkSeq)) {
        const hadThinking = !!this.session.liveThinking;
        this.host.chatState().appendDelta(frame.text, true);
        if (frame.seq !== undefined) this.session.liveThinkSeq = frame.seq;
        this.queueStreamPaint();
        if (!hadThinking) this.syncLiveActivity();
      }
      return;
    }
    if (frame.type === 'tool/start' || frame.type === 'tool/end') {
      const tool = frame.tool;
      if (tool && tool.id) {
        const index = this.session.liveTools.findIndex((item: LiveTool): boolean => item.id === tool.id);
        if (index >= 0) {
          const merged = this.session.liveTools.slice(0);
          merged[index] = tool;
          this.session.liveTools = merged;
        } else {
          this.session.liveTools = this.session.liveTools.concat([tool]);
        }
        if (frame.type === 'tool/end') {
          this.host.refreshSelectedTool(tool);
          this.schedule(150);
        }
        this.session.pendingBottom = true;
        this.syncLiveActivity();
      }
      return;
    }
    const eventRun = frame.cursor ? frame.cursor.runId : frame.runId;
    if (frame.type === 'queue/status') {
      // steering 排队状态即时回传：不重置流式内容，只更新 runId 与 queued。
      if (eventRun) this.session.runId = eventRun;
      if (frame.queued !== undefined) this.session.queued = frame.queued;
      this.syncLiveActivity();
      return;
    }
    if (frame.type === 'session/status') {
      this.session.liveRevision += 1;
      if (frame.idle === true) {
        this.session.liveViewPendingUntil = 0;
        this.session.idle = true;
        this.session.queued = frame.queued ?? false;
        this.host.observeRun(this.session.currentId, this.host.chatTitle(), this.session.queued, frame.aborted === true);
        this.session.runId = '';
        if (frame.cursor) {
          this.flushStreamDeltas(false);
          this.session.liveText = '';
          this.session.liveThinking = '';
          this.session.liveThinkingOpen = false;
          this.session.liveTools = [];
        }
        this.schedule(150);
      } else if (frame.idle === false) {
        this.session.liveViewPendingUntil = 0;
        this.host.observeRun(this.session.currentId, this.host.chatTitle(), true);
        this.flushStreamDeltas(false);
        this.session.idle = false;
        // 运行开始即携带 runId，手机可立即引导，无需等 /chat 轮询。
        if (eventRun) this.session.runId = eventRun;
        if (frame.queued !== undefined) this.session.queued = frame.queued;
        this.session.liveText = '';
        this.session.liveThinking = '';
        this.session.liveThinkSeq = 0;
        this.session.liveThinkingOpen = false;
        this.session.liveTools = [];
        this.session.liveSeq = 0;
      }
      this.syncLiveActivity();
      return;
    }
    if (frame.type === 'message/final') {
      this.session.liveRevision += 1;
      if (frame.cursor || (frame.seq !== undefined && frame.seq >= this.session.liveSeq)) {
        this.host.chatState().clearDelta(false);
        this.session.liveText = '';
        this.session.liveSeq = frame.seq ?? 0;
      }
      if (frame.cursor || (frame.thinkingSeq !== undefined && frame.thinkingSeq >= this.session.liveThinkSeq)) {
        this.host.chatState().clearDelta(true);
        this.session.liveThinking = '';
        this.session.liveThinkSeq = frame.thinkingSeq ?? 0;
        this.session.liveThinkingOpen = false;
      }
      if (frame.reason === 'error') this.session.status = 'Pi 模型运行失败，请在电脑上查看当前会话或 Pi Go 日志。';
      this.schedule(200);
      return;
    }
    if (frame.type === 'prompt/unconfirmed') {
      this.session.status = 'Pi 未确认这次发送。请在电脑上核对会话，应用不会自动重发。';
      return;
    }
    if (frame.type === 'session/changed') {
      this.schedule(150);
      return;
    }
  }

  private async poll(): Promise<void> {
    if (this.polling || this.session.openingSession) { this.schedule(350); return; }
    this.polling = true;
    const streamGen = this.streamGen;
    const epoch = this.session.epoch;
    const liveRevision = this.session.liveRevision;
    try {
      const result = await this.requestSessionSnapshot(epoch);
      if (epoch !== this.session.epoch) return;
      if (result.cursor && streamGen !== this.streamGen) return;
      const connected = !this.session.reachable;
      this.session.reachable = true;
      this.host.restoreOnlineNotice();
      this.host.refreshVisibleCatalog(connected);
      if (!result.session) {
        if (this.session.syncMode === 'sequenced') {
          this.host.chatState().sync.disconnect();
          this.session.historyStream = '';
          this.session.historyLeaf = undefined;
        }
        this.flushStreamDeltas(false);
        this.host.closeToolDetails();
        if (result.state === 'session_deleted' && result.deletedSessionId) {
          this.host.sessionDeleted(result.deletedSessionId);
        }
        this.session.noSession = result.state === 'session_deleted' ? '会话已在电脑端删除。' :
          result.state === 'session_closed' ? '原会话已关闭，请在会话列表选择历史记录或其他会话。' :
          result.state === 'no_shared_sessions' ? '电脑已连接，请在任务列表选择一条对话。' : '请在任务列表选择一个会话。';
        if (this.session.currentId) {
          this.rememberDraft(this.session.currentId);
          this.host.resetCommands();
        }
        this.session.currentId = '';
        this.session.project = '';
        this.session.sessionName = '';
        this.session.draft = '';
        this.session.idle = true;
        this.session.runId = '';
        this.session.queued = false;
        this.session.acceptsImage = false;
        this.session.attachments = [];
        this.session.messages = [];
        this.session.liveText = '';
        this.session.liveThinking = '';
        this.session.liveThinkSeq = 0;
        this.session.liveThinkingOpen = false;
        this.session.thinkingOpenIds = [];
        this.session.liveTools = [];
        this.session.liveSeq = 0;
        this.host.setInteraction();
        this.session.pendingSend = undefined;
        return;
      }
      const moved = result.session.id !== this.session.currentId;
      if (result.cursor) {
        const applied = this.applySessionSnapshot(result);
        if (applied || this.host.chatState().sync.matches(result.cursor)) {
          this.host.setInteraction(result.interaction);
          if (connected && !moved) this.host.syncCommandPalette();
          if (this.session.historyStream === result.cursor.streamId && this.session.historyLeaf === result.historyLeaf) {
            this.host.reconcileSteering(this.session.idle && !this.session.queued);
          } else {
            void this.refreshSessionHistory(result);
          }
        }
        return;
      }
      const incoming = result.messages ?? [];
      const currentSnapshot = moved || liveRevision === this.session.liveRevision;
      if (currentSnapshot) {
        this.host.observeSessionRun(result.session);
        this.applySession(result.session);
      }
      if (connected && !moved) this.host.syncCommandPalette();
      if (moved || incoming[incoming.length - 1]?.id !== this.session.messages[this.session.messages.length - 1]?.id) {
        this.session.pendingBottom = true;
      }
      this.mergeTranscript(incoming, result.historyCursor);
      this.host.reconcileSteering(currentSnapshot && result.session.idle);
      if (currentSnapshot) this.applyLiveSnapshot(result, moved || !this.streamAlive);
      const selectedTool = this.host.selectedTool();
      if (selectedTool?.state === 'run' || selectedTool?.state === 'unknown') {
        const selectedId = selectedTool.id;
        for (let index = incoming.length - 1; index >= 0; index--) {
          const message = incoming[index];
          if (this.host.selectedToolMessageId() && this.host.selectedToolMessageId() !== message.id) continue;
          const tool = message.tools?.find((item: LiveTool): boolean => item.id === selectedId);
          if (tool) {
            this.host.refreshSelectedTool(tool, message.id);
            break;
          }
        }
        const live = this.session.liveTools.find((item: LiveTool): boolean => item.id === selectedId);
        if (live) this.host.refreshSelectedTool(live);
      }
      this.host.setInteraction(result.interaction);
      this.session.reachable = true;
      if (result.promptError === 'unconfirmed') this.session.status = 'Pi 未确认这次发送。请在电脑上核对会话，应用不会自动重发。';
      else if (result.promptError === 'model_error') this.session.status = 'Pi 模型运行失败，请在电脑上查看当前会话或 Pi Go 日志。';
      this.cacheChat(result.session);
    } catch (error) {
      if (epoch !== this.session.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) {
        this.host.leaveComputer(true);
        return;
      }
      this.session.reachable = false;
      if (!this.session.currentId) this.session.noSession = '暂时无法加载会话，请检查电脑服务和网络，正在重试…';
      void this.host.tryPublicConnection();
    } finally {
      this.polling = false;
      if (epoch === this.session.epoch) {
        this.syncLiveActivity();
        const delay = !this.session.reachable ? 1500 :
          this.session.syncMode === 'sequenced' && this.host.chatState().sync.needsSnapshot() ? 150 :
          this.streamAlive ? (this.session.syncMode === 'sequenced' ? (this.session.idle ? 20000 : 6000) : (this.session.idle ? 3000 : 1200)) :
          this.session.idle ? 1500 : 650;
        this.schedule(delay);
      }
    }
  }

  async requestSessionSnapshot(epoch: number, includeHistory: boolean = false): Promise<BridgeReply> {
    if (this.session.syncMode === 'legacy') return await this.host.request('/chat');
    try {
      const result = await this.host.request(includeHistory ? '/session/snapshot?history=1' : '/session/snapshot');
      if (epoch === this.session.epoch && this.session.syncMode === 'probe') {
        this.session.syncMode = 'sequenced';
        this.startStream();
      }
      return result;
    } catch (error) {
      if (epoch !== this.session.epoch || !(error instanceof BridgeFailure) || error.status !== 404) throw error as Error;
      this.session.syncMode = 'legacy';
      this.stopStream();
      this.startStream();
      return await this.host.request('/chat');
    }
  }

  applySessionSnapshot(snapshot: BridgeReply): boolean {
    const cursor = snapshot.cursor;
    const session = snapshot.session;
    if (!cursor || !session || cursor.sessionId !== session.id) return false;
    const applied = this.host.chatState().sync.snapshot(cursor, (): void => {
      this.host.observeSessionRun(session);
      this.applySession(session);
      this.session.runId = cursor.runId ?? '';
      this.flushStreamDeltas(false);
      this.session.liveSeq = 0;
      this.session.liveThinkSeq = 0;
      this.applyLiveSnapshot(snapshot, true);
      const selectedTool = this.host.selectedTool();
      if (selectedTool?.state === 'run' || selectedTool?.state === 'unknown') {
        const selectedId = selectedTool.id;
        const live = this.session.liveTools.find((tool: LiveTool): boolean => tool.id === selectedId);
        if (live) this.host.refreshSelectedTool(live);
      }
      if (snapshot.promptError === 'unconfirmed') this.session.status = 'Pi 未确认这次发送。请在电脑上核对会话，应用不会自动重发。';
      else if (snapshot.promptError === 'model_error') this.session.status = 'Pi 模型运行失败，请在电脑上查看当前会话或 Pi Go 日志。';
    }, (frame: StreamFrame): void => this.applyStreamFrame(frame));
    if (applied) this.cacheChat(session);
    return applied;
  }

  async refreshSessionHistory(snapshot: BridgeReply, initial: boolean = false): Promise<BridgeReply | undefined> {
    const epoch = this.session.epoch;
    const cursor = snapshot.cursor;
    const session = snapshot.session;
    if (!cursor || !session || (!initial && this.historyLoadingEpoch === epoch) ||
        (!initial && this.session.historyStream === cursor.streamId && this.session.historyLeaf === snapshot.historyLeaf)) return undefined;
    const revision = ++this.historyRequest;
    this.historyLoadingEpoch = epoch;
    try {
      const page = await this.host.request(`/history?id=${encodeURIComponent(session.id)}&sync=2`);
      if (epoch !== this.session.epoch || revision !== this.historyRequest ||
          page.session?.id !== session.id || page.session?.cwd !== session.cwd ||
          page.cursor?.streamId !== cursor.streamId) return undefined;
      if (initial) return page;
      if (this.session.currentId !== session.id || !this.host.chatState().sync.matches(cursor)) return undefined;
      this.applySessionHistory(page);
      return page;
    } catch (error) {
      if (initial) throw error as Error;
      if (epoch === this.session.epoch && error instanceof BridgeFailure && error.status === 401) this.host.leaveComputer(true);
      return undefined;
    } finally {
      if (revision === this.historyRequest) this.historyLoadingEpoch = undefined;
    }
  }

  applySessionHistory(page: BridgeReply): void {
    const incoming = page.messages ?? [];
    if (incoming[incoming.length - 1]?.id !== this.session.messages[this.session.messages.length - 1]?.id) this.session.pendingBottom = true;
    this.mergeTranscript(incoming, page.historyCursor);
    this.session.historyStream = page.cursor?.streamId ?? '';
    this.session.historyLeaf = page.historyLeaf;
    this.host.reconcileSteering(this.session.idle && !this.session.queued);
    const selectedTool = this.host.selectedTool();
    if (selectedTool?.state === 'run' || selectedTool?.state === 'unknown') {
      const selectedId = selectedTool.id;
      for (let index = incoming.length - 1; index >= 0; index--) {
        const message = incoming[index];
        if (this.host.selectedToolMessageId() && this.host.selectedToolMessageId() !== message.id) continue;
        const tool = message.tools?.find((item: LiveTool): boolean => item.id === selectedId);
        if (tool) {
          this.host.refreshSelectedTool(tool, message.id);
          break;
        }
      }
    }
    if (page.session) this.cacheChat(page.session);
  }

  applyLiveSnapshot(snapshot: BridgeReply, replaceTools: boolean): void {
    const textSeq = snapshot.liveSeq ?? 0;
    if (this.session.idle || textSeq >= this.session.liveSeq) {
      this.host.chatState().clearDelta(false);
      const text = snapshot.liveText ?? '';
      if (text !== this.session.liveText) this.session.pendingBottom = true;
      this.session.liveText = text;
      this.session.liveSeq = textSeq;
    }
    const thinkingSeq = snapshot.liveThinkSeq ?? 0;
    if (this.session.idle || thinkingSeq >= this.session.liveThinkSeq) {
      this.host.chatState().clearDelta(true);
      const thinking = snapshot.liveThinking ?? '';
      if (thinking !== this.session.liveThinking) this.session.pendingBottom = true;
      this.session.liveThinking = thinking;
      this.session.liveThinkSeq = thinkingSeq;
    }
    if (this.session.idle) {
      if (this.session.liveTools.length) this.session.liveTools = [];
    } else if (replaceTools && (snapshot.tools?.length || this.session.liveTools.length)) {
      this.session.liveTools = snapshot.tools ?? [];
    }
  }

  mergeTranscript(incoming: ChatMessage[], cursor?: string): void {
    const transcript = this.host.chatState().mergeTranscript(this.session.messages, this.session.historyCursor, incoming, cursor);
    if (this.session.messages !== transcript.messages) this.session.messages = transcript.messages;
    this.session.historyCursor = transcript.cursor;
  }

  async loadHistory(): Promise<void> {
    if (this.session.busy || this.session.openingSession || !this.session.historyCursor || !this.session.currentId) return;
    const epoch = this.session.epoch;
    const id = this.session.currentId;
    const before = this.session.historyCursor;
    this.session.busy = true;
    try {
      const sync = this.session.syncMode === 'sequenced' ? '&sync=2' : '';
      const result = await this.host.request(`/history?id=${encodeURIComponent(id)}&before=${encodeURIComponent(before)}${sync}`);
      if (epoch !== this.session.epoch || this.session.currentId !== id || result.session?.id !== id || this.session.historyCursor !== before) return;
      if (this.session.syncMode === 'sequenced' && (!result.cursor || !this.host.chatState().sync.matches(result.cursor))) return;
      const known = new Set<string>(this.session.messages.map((message: ChatMessage): string => message.id));
      this.session.messages = (result.messages ?? []).filter((message: ChatMessage): boolean => !known.has(message.id)).concat(this.session.messages);
      this.session.historyCursor = result.historyCursor;
    } catch (error) {
      if (epoch !== this.session.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.host.leaveComputer(true);
      else this.session.status = '历史加载失败，会话可能已变化，请重新打开会话。';
    } finally { this.session.busy = false; }
  }

  private hasLiveViewGrace(): boolean {
    return this.session.liveViewPendingUntil > Date.now();
  }

  backgroundLiveActivity(): boolean {
    return this.host.liveViewsEnabled() && this.host.isPaired() && !!this.session.currentId &&
      this.session.liveViewSessionKey === this.draftKey(this.session.currentId) &&
      (!this.session.idle || this.session.queued || this.hasLiveViewGrace());
  }

  private liveActivityDetails(state: string): LiveActivitySnapshot {
    const sessionTitle = this.session.sessionName || this.host.chatTitle() || '当前会话';
    const tools = this.session.liveTools;
    const runningTool = tools.find((item: LiveTool): boolean => item.state === 'run' || item.state === 'unknown');
    const lastTool = tools.length ? tools[tools.length - 1] : undefined;
    const doneTools = tools.filter((item: LiveTool): boolean => item.state === 'ok' || item.state === 'fail').length;
    let title = '运行中';
    let summary = sessionTitle;
    let badge = state === '重新连接中' ? '重连中' : state;
    let progress = 35;
    if (state === '重新连接中') {
      title = '正在重新连接电脑';
      summary = `${sessionTitle} · 网络恢复后继续同步`;
      badge = '重连中';
      progress = 40;
    } else if (this.session.interaction) {
      title = this.session.interaction.title || '需要你确认后继续';
      summary = this.session.interaction.message || `${sessionTitle} · 点按返回会话处理`;
      badge = '待处理';
      progress = 65;
    } else if (state === '排队中') {
      title = '任务已派发，等待开始';
      summary = sessionTitle;
      badge = '排队中';
      progress = 15;
    } else if (runningTool) {
      title = `正在执行 ${runningTool.name}`;
      summary = runningTool.detail || sessionTitle;
      badge = `第 ${doneTools + 1} 步`;
      progress = Math.min(82, 35 + doneTools * 12);
    } else if (this.session.liveText.trim()) {
      const lines = this.session.liveText.trim().split('\n').map((line: string): string => line.trim()).filter((line: string): boolean => !!line);
      const snippet = lines.length ? lines[lines.length - 1] : this.session.liveText.trim();
      title = '正在生成回复';
      summary = snippet;
      badge = doneTools > 0 ? `第 ${doneTools} 步` : '输出中';
      progress = 88;
    } else if (this.session.liveThinking.trim()) {
      title = '正在思考推理';
      summary = sessionTitle;
      badge = doneTools > 0 ? `第 ${doneTools} 步` : '思考中';
      progress = Math.min(75, 30 + doneTools * 10);
    } else if (lastTool) {
      title = `已完成 ${lastTool.name}`;
      summary = lastTool.detail || sessionTitle;
      badge = `第 ${doneTools} 步`;
      progress = Math.min(80, 35 + doneTools * 12);
    }
    return {
      sessionId: this.session.currentId,
      address: this.host.base(),
      state: state,
      foreground: this.host.visible(),
      title: title,
      summary: summary,
      badge: badge,
      progress: progress
    };
  }

  syncLiveActivity(): void {
    if (!this.session.idle && this.session.runId) this.session.liveViewPendingUntil = 0;
    const grace = this.hasLiveViewGrace();
    if (this.session.liveViewSessionKey && (!this.host.isPaired() || this.session.liveViewSessionKey !== this.draftKey(this.session.currentId) ||
      (this.session.idle && !this.session.queued && !grace) ||
      (this.session.liveViewRunId && this.session.runId && this.session.liveViewRunId !== this.session.runId))) {
      this.session.liveViewSessionKey = '';
      this.session.liveViewRunId = '';
      this.session.liveViewPendingUntil = 0;
    }
    const active = this.backgroundLiveActivity();
    if (active) {
      if (this.session.runId) this.session.liveViewRunId = this.session.runId;
      const state = !this.session.reachable ? '重新连接中' : this.session.interaction ? '等待处理' :
        (this.session.queued || (this.session.idle && grace)) ? '排队中' : '运行中';
      this.host.publishLiveActivity(this.liveActivityDetails(state));
    } else this.host.publishLiveActivity(undefined);
    if (!this.host.visible() && !active) {
      this.cancelSchedule();
      this.stopStream();
    }
  }

  async fetchFullMessageText(sessionId: string, messageId: string, epoch: number,
    current?: () => boolean): Promise<string | undefined> {
    const path = `/message-text?id=${encodeURIComponent(sessionId)}&message=${encodeURIComponent(messageId)}`;
    const pages: string[] = [];
    let offset = 0;
    for (let page = 0; page < 40; page++) {
      const reply = await this.host.request(`${path}&offset=${offset}`);
      if (epoch !== this.session.epoch || sessionId !== this.session.currentId || (current && !current())) return undefined;
      if (reply.text === undefined) return undefined;
      pages.push(reply.text);
      if (reply.nextTextOffset === undefined) break;
      if (reply.nextTextOffset <= offset) return undefined;
      offset = reply.nextTextOffset;
    }
    return pages.join('');
  }

  async showFullReply(messageId: string): Promise<void> {
    if (this.session.loadingMessageText || !this.session.reachable || !this.session.currentId) return;
    const epoch = this.session.epoch;
    const id = this.session.currentId;
    const path = `/message-text?id=${encodeURIComponent(id)}&message=${encodeURIComponent(messageId)}`;
    this.session.loadingMessageText = messageId;
    try {
      const pages: string[] = [];
      let offset = 0;
      while (true) {
        const reply = await this.host.request(`${path}&offset=${offset}`);
        if (epoch !== this.session.epoch || id !== this.session.currentId) return;
        if (reply.text === undefined) throw new Error('invalid_message_text');
        pages.push(reply.text);
        if (reply.nextTextOffset === undefined) break;
        if (reply.nextTextOffset <= offset) throw new Error('invalid_message_text');
        offset = reply.nextTextOffset;
      }
      this.host.showTextPreview(this.session.workspaceCwd, '回复.md', pages.join(''));
    } catch {
      if (epoch === this.session.epoch && id === this.session.currentId) {
        this.host.getUIContext().getPromptAction().showToast({ message: '暂时无法加载完整回复，请重试' });
      }
    } finally {
      this.session.loadingMessageText = '';
    }
  }

  beginOptimisticLiveRun(): void {
    if (!this.host.visible() || !this.host.liveViewsEnabled() || !this.host.isPaired() || !this.session.currentId) return;
    this.session.liveViewSessionKey = this.draftKey(this.session.currentId);
    this.session.liveViewRunId = '';
    this.session.liveViewPendingUntil = Date.now() + 8000;
    this.syncLiveActivity();
  }

  cancelOptimisticLiveRun(): void {
    if (!this.session.liveViewPendingUntil) return;
    this.session.liveViewPendingUntil = 0;
    if (this.session.idle && !this.session.queued) {
      this.session.liveViewSessionKey = '';
      this.session.liveViewRunId = '';
    }
    this.syncLiveActivity();
  }

  trackDispatchedLiveRun(revision: number): void {
    if (this.session.liveRevision === revision && this.session.idle) this.session.idle = false;
    this.host.requestPermissionAfterDispatch();
    if (!this.host.liveViewsEnabled() || (this.session.idle && !this.session.queued)) return;
    const key = this.draftKey(this.session.currentId);
    if (!this.host.visible() && this.session.liveViewSessionKey !== key) return;
    this.session.liveViewSessionKey = key;
    this.session.liveViewRunId = this.session.runId;
    if (!this.session.runId) this.session.liveViewPendingUntil = Date.now() + 8000;
    this.syncLiveActivity();
  }
}
