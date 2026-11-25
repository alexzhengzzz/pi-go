import type { UIContext } from '@kit.ArkUI';
import type { LiveActivitySnapshot } from '../LiveActivity';
import { ChatState } from './ChatState';
import { ConnectionManager } from './ConnectionManager';
import { PiGoClient } from './PiGoClient';
import { SessionActions, SessionActionsHost } from './SessionActions';
import { SessionViewState, StreamSyncController, StreamSyncHost } from './StreamSyncController';
import { BridgeEndpoint, BridgeReply, DraftAttachment, LiveTool, Payload, PendingInteraction, UploadedAttachment } from './PiGoTypes';

export const WINDOW_CONVERSATION_STORAGE: string = 'piGoWindowConversation';

export class WindowConversation {
  readonly session: SessionViewState = new SessionViewState();
  readonly stream: StreamSyncController;
  readonly actions: SessionActions;
  readonly id: string;
  readonly cwd: string;
  readonly endpoint: BridgeEndpoint;
  readonly statusChanged: (message: string) => void;
  readonly onSplitReady: () => void;
  readonly markdownImage: (target: string, cwd: string, document: string) => Promise<string>;
  readonly historyImage: (message: string, index: number, tool: string) => Promise<string>;
  private readonly connection: ConnectionManager = new ConnectionManager();
  private readonly chat: ChatState;
  private readonly client: PiGoClient;
  private readonly pane: string;
  private foreground: boolean = false;
  private disposed: boolean = false;
  private ui?: UIContext;
  private closeWindow?: () => void;
  private presentText?: (text: string) => void;

  constructor(initial: BridgeReply, endpoint: BridgeEndpoint, client: PiGoClient, sharedDrafts: ChatState,
    statusChanged: (message: string) => void, onSplitReady: () => void,
    historyImage: (message: string, index: number, tool: string) => Promise<string>,
    markdownImage: (target: string, cwd: string, document: string) => Promise<string>) {
    this.id = initial.session?.id ?? '';
    this.cwd = initial.session?.cwd ?? '';
    this.endpoint = endpoint;
    this.client = client;
    this.statusChanged = statusChanged;
    this.onSplitReady = onSplitReady;
    this.markdownImage = markdownImage;
    this.historyImage = historyImage;
    this.chat = new ChatState(sharedDrafts);
    this.pane = paneQuery(this.id, this.cwd);
    this.stream = new StreamSyncController(this.streamHost());
    this.actions = new SessionActions(this.actionsHost());
    this.session.reachable = true;
    if (initial.cursor) {
      this.session.syncMode = 'sequenced';
      this.stream.applySessionSnapshot(initial);
      if (initial.messages !== undefined) this.stream.applySessionHistory(initial);
    } else {
      this.stream.presentChat(initial, false);
    }
    this.setInteraction(initial.interaction);
  }

  private getUIContext(): UIContext {
    if (!this.ui) throw new Error('window_not_attached');
    return this.ui;
  }

  attach(ui: UIContext, presentText: (text: string) => void): void {
    this.ui = ui;
    this.presentText = presentText;
    this.resume();
  }

  bindClose(close: () => void): void {
    this.closeWindow = close;
  }

  close(): void {
    this.closeWindow?.();
  }

  resume(): void {
    if (this.disposed) return;
    this.foreground = true;
    if (!this.ui) return;
    this.stream.startStream();
    this.stream.schedule(0);
  }

  suspend(): void {
    this.foreground = false;
    this.stream.cancelSchedule();
    this.stream.stopStream();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.stream.rememberDraft(this.id);
    this.suspend();
    this.session.epoch += 1;
    this.ui = undefined;
    this.closeWindow = undefined;
    this.presentText = undefined;
  }

  setDraft(value: string): void {
    this.session.draft = value;
    this.stream.rememberDraft(this.id);
  }

  setAttachments(items: DraftAttachment[]): void {
    this.session.attachments = items;
    const key = this.stream.draftKey(this.id);
    if (items.length) this.chat.draftAttachments.set(key, items);
    else this.chat.draftAttachments.delete(key);
  }

  removeAttachment(index: number): void {
    this.session.attachments[index]?.image?.preview.release().catch((): void => {});
    this.setAttachments(this.session.attachments.filter((_item: DraftAttachment, i: number): boolean => i !== index));
  }

  clearPending(): void {
    this.chat.unconfirmed.delete(this.stream.draftKey(this.id));
    this.session.pendingSend = undefined;
    this.session.status = '已保留草稿。';
  }

  title(): string {
    return this.session.sessionName || '未命名会话';
  }

  private setInteraction(request?: PendingInteraction): void {
    if (request?.id === this.session.interaction?.id) return;
    this.session.interaction = request;
    this.session.interactionDraft = request?.prefill ?? '';
  }

  async answer(pendingId: string, answer: boolean | string): Promise<void> {
    if (pendingId !== this.session.interaction?.id) return;
    const succeeded = await this.actions.requestAction('/answer', { id: this.id, pendingId: pendingId, answer: answer });
    if (succeeded && this.session.interaction?.id === pendingId) this.setInteraction();
    this.stream.schedule(0);
  }

  async previewFile(cwd: string, path: string, lookupName: boolean): Promise<string | undefined> {
    if (cwd !== this.cwd || this.disposed) return undefined;
    const reply = await this.client.request(this.endpoint, '/files/read', { cwd: cwd, path: path,
      lookup: lookupName ? 'name' : undefined });
    return reply.text;
  }

  async request(path: string, input?: Payload): Promise<BridgeReply> {
    const result = await this.client.request(this.endpoint, appendPane(path, this.pane), input);
    if (result.session && (result.session.id !== this.id || result.session.cwd !== this.cwd)) {
      throw new Error('session_changed');
    }
    return result;
  }

  private streamHost(): StreamSyncHost {
    return {
      session: this.session,
      connection: (): ConnectionManager => this.connection,
      streamEndpoint: (): BridgeEndpoint => this.endpoint,
      streamPath: (path: string): string => appendPane(path, this.pane),
      chatState: (): ChatState => this.chat,
      client: (): PiGoClient => this.client,
      isPaired: (): boolean => !this.disposed && !!this.endpoint.token,
      visible: (): boolean => this.foreground,
      base: (): string => this.endpoint.address,
      liveViewsEnabled: (): boolean => false,
      selectedTool: (): LiveTool | undefined => undefined,
      selectedToolMessageId: (): string => '',
      request: (path: string, input?: Payload): Promise<BridgeReply> => this.request(path, input),
      leaveComputer: (): void => { this.close(); },
      refreshSelectedTool: (): void => {},
      chatTitle: (): string => this.title(),
      closeToolDetails: (): void => {},
      resetCommands: (): void => {},
      observeSessionRun: (): void => {},
      resetVoice: (): void => {},
      updateCachedSessionTitle: (): void => {},
      workspaceChanged: (): void => {},
      showChat: (): void => {},
      syncCommandPalette: (): void => {},
      setInteraction: (request?: PendingInteraction): void => this.setInteraction(request),
      reconcileSteering: (settled: boolean): void => this.actions.reconcileSteering(settled),
      tryPublicConnection: (): Promise<void> => Promise.resolve(),
      getUIContext: (): UIContext => this.getUIContext(),
      restoreOnlineNotice: (): void => {},
      refreshVisibleCatalog: (): void => {},
      sessionDeleted: (): void => {},
      showTextPreview: (_cwd: string, _path: string, text: string): void => { this.presentText?.(text); },
      observeRun: (): void => {},
      requestPermissionAfterDispatch: (): void => {},
      publishLiveActivity: (_snapshot?: LiveActivitySnapshot): void => {}
    };
  }

  private actionsHost(): SessionActionsHost {
    return {
      session: this.session,
      streamSync: this.stream,
      chatState: (): ChatState => this.chat,
      request: (path: string, input?: Payload): Promise<BridgeReply> => this.request(path, input),
      leaveComputer: (): void => { this.close(); },
      observeSessionRun: (): void => {},
      setInteraction: (request?: PendingInteraction): void => this.setInteraction(request),
      syncCommandPalette: (): void => {},
      getUIContext: (): UIContext => this.getUIContext(),
      accent: (): string => '#2A806F',
      resetVoice: (): void => {},
      revealSessionDrawer: (): void => {},
      showSessions: (): boolean => false,
      invalidateCatalog: (): void => {},
      refreshExpandedSpace: (): void => {},
      catalogConnection: (): number => 0,
      canCreateWorkspace: (): boolean => false,
      canCreateSession: (): boolean => false,
      closeNewSession: (): void => {},
      closeNewSpace: (): void => {},
      openNewSession: (): void => {},
      loadSessions: (): Promise<void> => Promise.resolve(),
      addWorkspace: (): void => {},
      showTasks: (): void => {},
      animateSend: (): void => {},
      uploadAttachment: (kind: string, name: string, bytes: Uint8Array): Promise<UploadedAttachment> =>
        this.client.uploadAttachment(this.endpoint, kind, name, bytes, '&' + this.pane)
    };
  }
}

export function paneQuery(id: string, cwd: string): string {
  return `pane=${encodeURIComponent(id)}&paneCwd=${encodeURIComponent(cwd)}`;
}

export function panePath(path: string, id: string, cwd: string): string {
  return appendPane(path, paneQuery(id, cwd));
}

function appendPane(path: string, query: string): string {
  return path + (path.includes('?') ? '&' : '?') + query;
}
