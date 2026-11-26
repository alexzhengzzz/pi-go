import { AbilityConstant, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { findConversationWindow, prepareConversationWindow, takeConversationWindow } from '../ConversationWindowLaunch';
import { ChatState } from './ChatState';
import { ConnectionManager } from './ConnectionManager';
import { PiGoClient } from './PiGoClient';
import { BridgeEndpoint, BridgeFailure, BridgeReply, LiveTool, Payload, PendingInteraction, SessionRow } from './PiGoTypes';
import { SessionActions } from './SessionActions';
import { SessionViewState, StreamSyncController, StreamSyncHost } from './StreamSyncController';
import { WindowConversation } from './WindowConversation';
import { WorkspaceFileController } from './WorkspaceFileController';

export interface TranscriptPosition {
  follow: boolean;
  offset: number;
}

export const PANE_SCOPED_PATHS: string[] = [
  '/session/snapshot', '/chat', '/history', '/events', '/tool-detail',
  '/message-image', '/message-text', '/upload', '/prompt', '/abort',
  '/answer', '/receipt', '/regenerate'
];

export function panePath(path: string, id: string, cwd: string): string {
  const separator = path.includes('?') ? '&' : '?';
  return `${path}${separator}pane=${encodeURIComponent(id)}&paneCwd=${encodeURIComponent(cwd)}`;
}

export interface SplitPaneHost {
  session: SessionViewState;
  transcript: Scroller;
  client: PiGoClient;
  chatState: ChatState;
  connection: ConnectionManager;
  sessionActions: SessionActions;
  fileController: WorkspaceFileController;
  base: () => string;
  isPaired: () => boolean;
  windowWidth: () => number;
  windowHeight: () => number;
  keyboardHeight: () => number;
  chatTitle: () => string;
  createBaseStreamHost: () => StreamSyncHost;
  request: (path: string, input?: Payload, endpoint?: BridgeEndpoint) => Promise<BridgeReply>;
  getUIContext: () => UIContext;
  dismissKeyboard: () => void;
  setDrawer: (open: boolean) => void;
  showTasksTab: () => void;
  leaveComputer: (revoked?: boolean) => void;
}

@ObservedV2
export class SplitPaneState {
  @Trace splitOpen: boolean = false;
  @Trace splitNavigating: boolean = false;
  @Trace focusedPaneFirst: boolean = true;
  @Trace otherId: string = '';
  @Trace otherTitle: string = '';
  @Trace otherSession: SessionViewState = new SessionViewState();
}

export class SplitPaneController {
  readonly state: SplitPaneState = new SplitPaneState();
  readonly otherConnection: ConnectionManager = new ConnectionManager();
  readonly otherChat: ChatState = new ChatState();
  readonly otherTranscript: Scroller = new Scroller();
  readonly otherStream: StreamSyncController;
  readonly splitPositions: Map<string, TranscriptPosition> = new Map<string, TranscriptPosition>();
  openingNativeWindow: boolean = false;
  launchedNativeWindow: boolean = false;
  otherCwd: string = '';
  otherTranscriptHeight: number = 0;
  pendingFocusedPosition: string = '';
  pendingOtherPosition: string = '';
  wasSplitKeyboardCompact: boolean = false;
  private readonly host: SplitPaneHost;

  constructor(host: SplitPaneHost) {
    this.host = host;
    this.otherStream = new StreamSyncController(this.otherStreamHost());
  }

  private otherStreamHost(): StreamSyncHost {
    const host = this.host.createBaseStreamHost();
    host.session = this.state.otherSession;
    host.connection = (): ConnectionManager => this.otherConnection;
    host.chatState = (): ChatState => this.otherChat;
    host.isPaired = (): boolean => this.host.isPaired() && this.state.splitOpen && !!this.state.otherId;
    host.streamEndpoint = (): BridgeEndpoint => this.host.connection.endpoint();
    host.streamPath = (path: string): string => panePath(path, this.state.otherId, this.otherCwd);
    host.request = (path: string): Promise<BridgeReply> => this.requestOtherPane(path);
    host.liveViewsEnabled = (): boolean => false;
    host.selectedTool = (): LiveTool | undefined => undefined;
    host.selectedToolMessageId = (): string => '';
    host.chatTitle = (): string => this.otherPaneTitle();
    host.refreshSelectedTool = (): void => {};
    host.closeToolDetails = (): void => {};
    host.resetVoice = (): void => {};
    host.resetCommands = (): void => {};
    host.observeSessionRun = (): void => {};
    host.observeRun = (): void => {};
    host.updateCachedSessionTitle = (): void => {};
    host.workspaceChanged = (): void => {};
    host.showChat = (): void => {};
    host.syncCommandPalette = (): void => {};
    host.setInteraction = (interaction?: PendingInteraction): void => { this.state.otherSession.interaction = interaction; };
    host.reconcileSteering = (): void => {};
    host.tryPublicConnection = (): Promise<void> => Promise.resolve();
    host.restoreOnlineNotice = (): void => {};
    host.refreshVisibleCatalog = (): void => {};
    host.sessionDeleted = (): void => {};
    host.requestPermissionAfterDispatch = (): void => {};
    host.publishLiveActivity = (): void => {};
    return host;
  }

  async requestOtherPane(path: string): Promise<BridgeReply> {
    const id = this.state.otherId;
    const cwd = this.otherCwd;
    const result = await this.host.request(panePath(path, id, cwd));
    if (result.session && (result.session.id !== id || result.session.cwd !== cwd)) {
      throw new Error('session_changed');
    }
    return result;
  }

  otherPaneTitle(): string {
    return this.state.otherSession.sessionName || this.state.otherTitle || '未命名会话';
  }

  suspendOtherPane(): void {
    this.state.otherSession.epoch += 1;
    this.otherStream.cancelSchedule();
    this.otherStream.stopStream();
  }

  resumeOtherPane(): void {
    if (!this.state.splitOpen || !this.state.otherId) return;
    this.otherStream.startStream();
    this.otherStream.schedule(0);
  }

  setOtherPane(snapshot?: BridgeReply): void {
    this.suspendOtherPane();
    this.state.otherId = snapshot?.session?.id ?? '';
    this.otherCwd = snapshot?.session?.cwd ?? '';
    this.state.otherTitle = snapshot?.session?.name ?? '';
    this.state.otherSession.currentId = '';
    this.state.otherSession.noSession = '';
    this.state.otherSession.loadingMessageText = '';
    this.state.otherSession.historyStream = '';
    this.state.otherSession.historyLeaf = undefined;
    this.state.otherSession.busy = false;
    this.state.otherSession.status = '';
    this.state.otherSession.reachable = !!snapshot?.session;
    this.state.otherSession.syncMode = 'probe';
    this.state.otherSession.interaction = undefined;
    this.pendingOtherPosition = this.state.otherId;
    if (!snapshot?.session) return;
    this.otherStream.presentChat(snapshot, false);
    this.state.otherSession.transcriptFollow = this.splitPositions.get(this.state.otherId)?.follow ?? true;
    this.resumeOtherPane();
  }

  clearSplit(): void {
    if (!this.state.splitOpen && !this.state.otherId) return;
    if (this.host.session.currentId && !this.host.session.transcriptFollow) {
      this.saveSplitPosition(this.host.session, this.host.transcript);
      this.pendingFocusedPosition = this.host.session.currentId;
    }
    this.state.splitOpen = false;
    this.state.splitNavigating = false;
    this.setOtherPane();
    this.state.focusedPaneFirst = true;
    this.wasSplitKeyboardCompact = false;
    const retained = this.splitPositions.get(this.pendingFocusedPosition);
    this.splitPositions.clear();
    if (retained) this.splitPositions.set(this.pendingFocusedPosition, retained);
  }

  saveSplitPosition(state: SessionViewState, scroller: Scroller): void {
    if (!state.currentId) return;
    if (state.transcriptFollow) {
      this.splitPositions.delete(state.currentId);
      return;
    }
    if ((scroller === this.host.transcript && this.pendingFocusedPosition === state.currentId) ||
      (scroller === this.otherTranscript && this.pendingOtherPosition === state.currentId)) return;
    try {
      const offset = scroller.currentOffset().yOffset;
      this.splitPositions.set(state.currentId, { follow: false, offset: offset });
    } catch { /* The transcript may be between layouts. */ }
  }

  captureFocusedPane(): BridgeReply | undefined {
    const session = this.host.session;
    if (!session.currentId) return undefined;
    return {
      session: { id: session.currentId, cwd: session.workspaceCwd, name: this.host.chatTitle(),
        agent: session.currentAgent, idle: session.idle, queued: session.queued, runId: session.runId },
      messages: session.messages,
      historyCursor: session.historyCursor,
      liveText: session.liveText,
      liveSeq: session.liveSeq,
      liveThinking: session.liveThinking,
      liveThinkSeq: session.liveThinkSeq,
      tools: session.liveTools,
      interaction: session.interaction
    };
  }

  async chooseSplitSession(id: string, agent: string | undefined, keepFocused: boolean): Promise<boolean> {
    const session = this.host.session;
    if (!id || this.state.splitNavigating || this.openingNativeWindow || session.openingSession || session.busy) return false;
    const existingWindow = this.launchedNativeWindow ? findConversationWindow(this.host.base(), id) : undefined;
    if (existingWindow && id === existingWindow.id) {
      this.host.getUIContext().getPromptAction().showToast({ message: '此会话已在另一窗口打开。' });
      return false;
    }
    this.host.showTasksTab();
    if (id === session.currentId) {
      if (keepFocused && !this.state.splitOpen) {
        this.saveSplitPosition(session, this.host.transcript);
        this.pendingFocusedPosition = id;
        this.state.splitOpen = true;
      }
      this.host.setDrawer(false);
      return true;
    }
    if (!session.reachable) return false;
    if (!keepFocused && !this.state.splitOpen) {
      return await this.host.sessionActions.requestAction('/open', { id: id, agent: agent });
    }
    const wasSplit = this.state.splitOpen;
    const previous = this.captureFocusedPane();
    const previousOtherId = this.state.otherId;
    const switchPanes = id === previousOtherId;
    const placeInOtherPane = switchPanes || ((keepFocused || (wasSplit && !previousOtherId)) && !!previous?.session);
    const base = this.host.base();
    this.state.splitNavigating = true;
    this.saveSplitPosition(session, this.host.transcript);
    if (this.state.otherId) this.saveSplitPosition(this.state.otherSession, this.otherTranscript);
    if (placeInOtherPane) this.host.dismissKeyboard();
    try {
      if (!await this.host.sessionActions.requestAction('/open', { id: id, agent: agent }) ||
        session.currentId !== id || this.host.base() !== base) return false;
      if (keepFocused || wasSplit) {
        this.state.splitOpen = true;
        if (placeInOtherPane) {
          this.state.focusedPaneFirst = !this.state.focusedPaneFirst;
          this.setOtherPane(previous);
        }
        this.splitPositions.forEach((_value: TranscriptPosition, key: string): void => {
          if (key !== id && key !== this.state.otherId) this.splitPositions.delete(key);
        });
        session.transcriptFollow = this.splitPositions.get(id)?.follow ?? true;
        this.pendingFocusedPosition = id;
      }
      this.host.setDrawer(false);
      return true;
    } finally {
      this.state.splitNavigating = false;
    }
  }

  openSidebarSession(row: SessionRow, split: boolean): void {
    void this.chooseSplitSession(row.id, row.agent, split);
  }

  async openInSystemSplit(row: SessionRow): Promise<void> {
    const session = this.host.session;
    if (this.openingNativeWindow || this.state.splitNavigating || session.busy ||
      session.openingSession || !session.reachable) return;
    const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!context) return;
    const toast = (message: string): void => { this.host.getUIContext().getPromptAction().showToast({ message: message }); };
    if (row.id === session.currentId) {
      toast('请选择另一条会话在系统分屏中打开。');
      return;
    }
    if (findConversationWindow(this.host.base(), row.id)) return;
    const endpoint = this.host.connection.endpoint();
    const epoch = session.epoch;
    let launchKey = '';
    this.openingNativeWindow = true;
    try {
      const snapshot = await this.host.request('/session/open', { id: row.id, agent: row.agent, history: true }, endpoint);
      if (session.epoch !== epoch || endpoint.token !== this.host.connection.endpoint().token ||
        endpoint.address !== this.host.connection.endpoint().address) return;
      if (snapshot.session?.id !== row.id || !snapshot.session.cwd) throw new Error('session_changed');
      const cwd = snapshot.session.cwd;
      const model = new WindowConversation(snapshot, endpoint, this.host.client, this.host.chatState, toast,
        (): void => {
          this.clearSplit();
          this.host.setDrawer(false);
        },
        (message: string, index: number, tool: string): Promise<string> =>
          this.host.fileController.loadHistoryImage(row.id, message, index, tool, cwd,
            (path: string): Promise<BridgeReply> => this.host.request(panePath(path, row.id, cwd), undefined, endpoint)),
        (target: string, workspace: string, document: string): Promise<string> =>
          this.host.fileController.loadMarkdownImage(target, workspace, document));
      launchKey = prepareConversationWindow(model);
      this.host.dismissKeyboard();
      await context.startAbility({
        bundleName: context.abilityInfo.bundleName,
        moduleName: context.abilityInfo.moduleName,
        abilityName: 'ConversationAbility',
        parameters: { conversationKey: launchKey }
      }, { windowMode: AbilityConstant.WindowMode.WINDOW_MODE_SPLIT });
      this.launchedNativeWindow = true;
    } catch (error) {
      if (launchKey) takeConversationWindow(launchKey)?.dispose();
      if (error instanceof BridgeFailure && error.status === 401) this.host.leaveComputer(true);
      else toast(error instanceof BridgeFailure && error.status === 404
        ? '请更新电脑端 Pi Go 后再打开系统分屏。' : '暂时无法打开系统分屏，请检查设备窗口模式和会话连接。');
    } finally {
      this.openingNativeWindow = false;
    }
  }

  async focusOtherPane(): Promise<boolean> {
    return await this.chooseSplitSession(this.state.otherId, this.state.otherSession.currentAgent, false);
  }

  async closeSplitPane(focused: boolean): Promise<void> {
    if (this.state.splitNavigating || this.host.session.openingSession || this.host.session.busy) return;
    if (focused && this.state.otherId && !await this.focusOtherPane()) return;
    this.clearSplit();
  }

  restoreSplitPosition(id: string, scroller: Scroller): boolean {
    const position = this.splitPositions.get(id);
    if (!position || position.follow) return false;
    scroller.scrollTo({ xOffset: 0, yOffset: position.offset, animation: false });
    return true;
  }

  positionOtherTranscript(id: string, contentHeight: number): void {
    if (id !== this.state.otherId || contentHeight <= 0) return;
    this.otherTranscriptHeight = contentHeight;
    if (this.pendingOtherPosition === id) {
      this.pendingOtherPosition = '';
      if (this.restoreSplitPosition(id, this.otherTranscript)) {
        this.state.otherSession.pendingBottom = false;
        return;
      }
    }
    if (this.state.otherSession.pendingBottom && this.state.otherSession.transcriptFollow) {
      this.otherTranscript.scrollTo({ xOffset: 0, yOffset: contentHeight, animation: false });
    }
    this.state.otherSession.pendingBottom = false;
  }

  splitPaneStatus(state: SessionViewState): string {
    if (!state.reachable) return '离线';
    if (state.interaction) return '待处理';
    if (state.queued) return '排队中';
    return state.idle ? '' : '运行中';
  }

  mainPaneWidth(sidebar: number): number {
    return Math.max(0, this.host.windowWidth() - sidebar);
  }

  splitHorizontal(docked: boolean, sessionPaneWidth: number): boolean {
    return this.mainPaneWidth(docked ? sessionPaneWidth : 0) >= 620;
  }

  splitKeyboardCompact(docked: boolean, sessionPaneWidth: number): boolean {
    return !this.splitHorizontal(docked, sessionPaneWidth) && this.host.keyboardHeight() > 0 && this.host.windowHeight() - this.host.keyboardHeight() < 560;
  }
}
