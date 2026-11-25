import type { UIContext } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import type { ChatState } from './ChatState';
import type { SessionViewState, StreamSyncController } from './StreamSyncController';
import { BridgeFailure } from './PiGoTypes';
import type { AttachmentRef, BridgeReply, DraftAttachment, ModelOption, OptimisticMessage, Payload, PendingInteraction, PendingSend,
  QueuedSteering, SessionState, UploadedAttachment } from './PiGoTypes';

export interface SessionActionsHost {
  session: SessionViewState;
  streamSync: StreamSyncController;
  chatState: () => ChatState;
  request: (path: string, input?: Payload) => Promise<BridgeReply>;
  leaveComputer: (forget: boolean) => void;
  observeSessionRun: (session: SessionState) => void;
  setInteraction: (interaction?: PendingInteraction) => void;
  syncCommandPalette: () => void;
  getUIContext: () => UIContext;
  accent: () => string;
  resetVoice: () => void;
  revealSessionDrawer: () => void;
  showSessions: () => boolean;
  invalidateCatalog: () => void;
  refreshExpandedSpace: (cwd: string) => void;
  catalogConnection: () => number;
  canCreateWorkspace: () => boolean;
  canCreateSession: () => boolean;
  closeNewSession: () => void;
  closeNewSpace: () => void;
  openNewSession: (cwd: string) => void;
  loadSessions: () => Promise<void>;
  addWorkspace: (cwd: string, name: string) => void;
  showTasks: () => void;
  animateSend: () => void;
  uploadAttachment: (kind: string, name: string, bytes: Uint8Array) => Promise<UploadedAttachment>;
}

@ObservedV2
export class SessionCreationState {
  @Trace showNewSession: boolean = false;
  @Trace newSessionCwd: string = '';
  @Trace newSessionAgent: string = '';
  @Trace newSessionFixedWorkspace: boolean = false;
  @Trace newSessionError: string = '';
  newSessionPreferredAgent: string = 'pi';
  @Trace showNewSpace: boolean = false;
  @Trace newSpaceName: string = '';
  @Trace newSpaceError: string = '';
}

export class SessionActions {

  readonly creation: SessionCreationState = new SessionCreationState();
  private readonly host: SessionActionsHost;
  private readonly session: SessionViewState;
  private readonly streamSync: StreamSyncController;

  constructor(host: SessionActionsHost) {
    this.host = host;
    this.session = host.session;
    this.streamSync = host.streamSync;
  }

  async createSession(): Promise<void> {
    if (!this.creation.showNewSession || !this.host.canCreateSession()) return;
    const connection = this.host.catalogConnection();
    const payload: Payload = { cwd: this.creation.newSessionCwd, agent: this.creation.newSessionAgent };
    this.creation.newSessionError = '';
    this.host.showTasks();
    const created = await this.requestAction('/new', payload);
    if (connection !== this.host.catalogConnection() || !this.creation.showNewSession) return;
    if (created) this.host.closeNewSession();
    else this.creation.newSessionError = this.session.status || '暂时无法创建会话。';
  }

  async createWorkspaceTask(): Promise<void> {
    if (!this.creation.showNewSpace || !this.session.reachable || !this.host.canCreateWorkspace() || this.session.busy || this.session.openingSession) return;
    const rawName = this.creation.newSpaceName;
    const name = rawName.trim();
    if (!name || name.length > 80 || name === '.' || name === '..' || /[\x00-\x1f\x7f/\\]/.test(rawName)) {
      this.creation.newSpaceError = '请输入 1–80 个字符，名称不能是「.」「..」或包含路径分隔符和控制字符。';
      return;
    }
    const epoch = this.session.epoch;
    this.creation.newSpaceError = '';
    this.session.busy = true;
    let cwd = '';
    let refresh = false;
    try {
      const result = await this.host.request('/create-workspace', { name: name });
      if (epoch !== this.session.epoch) return;
      if (!result.cwd) throw new Error('workspace_not_confirmed');
      cwd = result.cwd;
    } catch (error) {
      if (epoch !== this.session.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) {
        this.host.leaveComputer(true);
        return;
      }
      const code = error instanceof BridgeFailure ? error.message : '';
      if (code === 'workspace_exists') this.creation.newSpaceError = '已有同名文件夹，请换一个名称。';
      else if (code === 'desktop_busy') this.creation.newSpaceError = '电脑端正在处理其他操作，请稍后再试。';
      else if (code === 'desktop_workspace_creation_unsupported' || code === 'not_found') this.creation.newSpaceError = '请更新电脑端 Pi Go 后再创建空间。';
      else if (code === 'computer_access_required') this.creation.newSpaceError = '此连接需要启用整机访问才能创建空间。';
      else if (code === 'desktop_create_workspace_failed') this.creation.newSpaceError = '电脑端创建空间失败，请检查默认目录。';
      else {
        refresh = true;
        this.creation.newSpaceError = '电脑端未确认结果，请先查看空间列表。';
      }
    } finally {
      this.session.busy = false;
    }
    if (refresh) {
      this.host.invalidateCatalog();
      void this.host.loadSessions();
      return;
    }
    if (!cwd) return;
    this.host.closeNewSpace();
    this.host.addWorkspace(cwd, name);
    this.host.invalidateCatalog();
    this.host.showTasks();
    this.host.openNewSession(cwd);
  }

  async requestAction(path: string, input?: Payload): Promise<boolean> {
    if (this.session.busy || this.session.openingSession) return false;
    if (path === '/open' || path === '/new' || path === '/fork') {
      return this.navigate(path, input);
    }
    return this.performAction(path, input);
  }

  private async navigate(path: string, input?: Payload): Promise<boolean> {
    const previous = this.host.chatState().chatCache.get(this.streamSync.draftKey(this.session.currentId));
    if (previous?.session) this.streamSync.cacheChat(previous.session);
    const cached = path === '/open' && input?.id ? this.host.chatState().chatCache.get(this.streamSync.draftKey(input.id)) : undefined;
    const epoch = ++this.session.epoch;
    this.host.resetVoice();
    this.session.openingSession = true;
    this.session.openingSessionId = path === '/open' ? input?.id ?? '' : '';
    this.session.pendingSessionReveal = '';
    this.streamSync.cancelSchedule();
    if (this.session.syncMode === 'sequenced') {
      this.streamSync.stopStream();
      this.session.historyStream = '';
      this.session.historyLeaf = undefined;
    }
    if (cached) this.streamSync.presentChat(cached, true);
    this.session.status = '';
    let navigationConfirmed = false;
    let refreshSpace = '';
    try {
      let requestPath = path;
      let payload = input;
      if (path === '/open' && this.session.syncMode !== 'legacy') {
        requestPath = '/session/open';
        payload = { id: input?.id, history: true };
        if (input?.agent) payload.agent = input.agent;
      }
      let result: BridgeReply;
      try {
        result = await this.host.request(requestPath, payload);
      } catch (error) {
        if (requestPath === '/session/open' && error instanceof BridgeFailure && error.status === 404) {
          result = await this.host.request('/open', payload);
        } else {
          throw error as Error;
        }
      }
      if (epoch !== this.session.epoch) return false;
      if (path === '/new') {
        if (!result.session) throw new BridgeFailure(409, 'desktop_handoff_unconfirmed');
        if ((result.session.agent ?? 'pi') !== (input?.agent ?? 'pi')) throw new BridgeFailure(409, 'desktop_agent_mismatch');
      }
      if (path === '/new' || path === '/fork') {
        this.host.invalidateCatalog();
        refreshSpace = result.session?.cwd ?? '';
      }
      if (result.session) {
        if (path === '/open' && result.session.id !== input?.id) throw new Error('session_changed');
        navigationConfirmed = true;
        return await this.confirmNavigation(path, result, result.session, epoch, !!cached);
      }
      return true;
    } catch (error) {
      if (epoch !== this.session.epoch) return false;
      if (cached && !navigationConfirmed && !(error instanceof BridgeFailure && error.status === 401)) {
        this.session.pendingSessionReveal = '';
        if (previous) this.streamSync.presentChat(previous, false);
        this.host.revealSessionDrawer();
      }
      this.reportActionFailure(path, error as Error);
      return false;
    } finally {
      this.session.openingSession = false;
      this.session.openingSessionId = '';
      if (epoch === this.session.epoch) {
        this.host.syncCommandPalette();
        if (this.session.syncMode === 'sequenced') this.streamSync.startStream();
        this.streamSync.schedule(this.session.reachable && !this.session.idle ? 650 : 1500);
        if (refreshSpace) this.host.refreshExpandedSpace(refreshSpace);
      }
    }
  }

  private async confirmNavigation(path: string, result: BridgeReply, expected: SessionState,
    epoch: number, cached: boolean): Promise<boolean> {
    const liveRevision = this.session.liveRevision;
    let chat = result;
    if (!chat.cursor || chat.messages === undefined) {
      const previousId = this.session.currentId;
      const previousCwd = this.session.workspaceCwd;
      this.session.currentId = expected.id;
      this.session.workspaceCwd = expected.cwd;
      try {
        chat = await this.streamSync.requestSessionSnapshot(epoch, true);
      } catch (error) {
        if (epoch === this.session.epoch) {
          this.session.currentId = previousId;
          this.session.workspaceCwd = previousCwd;
        }
        throw error as Error;
      }
    } else if (this.session.syncMode === 'probe') {
      this.session.syncMode = 'sequenced';
    }
    if (epoch !== this.session.epoch) return false;
    if (chat.session?.id !== expected.id || chat.session.cwd !== expected.cwd) throw new Error('session_changed');
    if (path === '/new' && (chat.session.agent ?? 'pi') !== (expected.agent ?? 'pi')) {
      throw new BridgeFailure(409, 'desktop_agent_mismatch');
    }
    if (chat.cursor) {
      const page = chat.messages !== undefined ? chat : await this.streamSync.refreshSessionHistory(chat, true);
      if (epoch !== this.session.epoch) return false;
      if (!page || !this.streamSync.applySessionSnapshot(chat)) throw new Error('session_changed');
      this.host.setInteraction(chat.interaction);
      this.streamSync.applySessionHistory(page);
      this.streamSync.revealChat(!cached);
    } else {
      const current = liveRevision === this.session.liveRevision;
      if (current) this.host.observeSessionRun(chat.session);
      this.streamSync.presentChat(chat, !cached, current);
      this.reconcileSteering(current && chat.session.idle);
      this.streamSync.cacheChat(chat.session);
    }
    return true;
  }

  private async performAction(path: string, input?: Payload): Promise<boolean> {
    const epoch = this.session.epoch;
    const liveRevision = this.session.liveRevision;
    this.session.busy = true;
    this.session.status = '';
    let refreshSpace = '';
    try {
      const result = await this.host.request(path, input);
      if (epoch !== this.session.epoch) return false;
      if (path === '/rename' || path === '/session-meta' || path === '/close-workspace') this.host.invalidateCatalog();
      if (path === '/rename') refreshSpace = result.session?.cwd ?? '';
      if (path === '/models' && result.session?.id === this.session.currentId) {
        this.session.models = result.models ?? [];
        this.session.selectedModel = this.session.models.findIndex((model: ModelOption): boolean =>
          model.provider === result.current?.provider && model.id === result.current?.id);
        if (this.session.selectedModel < 0 && this.session.models.length) this.session.selectedModel = 0;
        const levels = this.session.models[this.session.selectedModel]?.levels ?? [];
        const currentLevel = result.current?.thinkingLevel ?? 'off';
        this.session.selectedLevel = levels.includes(currentLevel) ? currentLevel : levels[0] ?? 'off';
        this.session.renameDraft = this.session.sessionName;
        this.session.showSettings = true;
      }
      if ((path === '/rename' || path === '/model') && result.session?.id === this.session.currentId) {
        this.streamSync.applySession(result.session);
        this.session.status = path === '/rename' ? '会话名称已更新。' : `已切换到 ${this.session.modelLabel}`;
        this.session.showSettings = false;
      }
      if (path === '/regenerate') {
        if (result.dispatched === true && input?.id === this.session.currentId) this.streamSync.trackDispatchedLiveRun(liveRevision);
        this.session.transcriptFollow = true;
        this.session.pendingBottom = true;
        this.streamSync.schedule(0);
      }
      return true;
    } catch (error) {
      if (epoch === this.session.epoch) this.reportActionFailure(path, error as Error);
      return false;
    } finally {
      this.session.busy = false;
      if (epoch === this.session.epoch && refreshSpace) this.host.refreshExpandedSpace(refreshSpace);
    }
  }

  private reportActionFailure(path: string, error: Error): void {
    if (error instanceof BridgeFailure && error.status === 401) this.host.leaveComputer(true);
    else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_required' && path === '/close-workspace') this.session.status = '电脑端 Pi Go 宿主未运行，暂时无法关闭工作区。';
    else if (error instanceof BridgeFailure && error.message === 'not_found' && path === '/close-workspace') this.session.status = '当前电脑端 Pi Go 宿主不支持远程关闭工作区，请更新电脑端。';
    else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_required') this.session.status = '电脑端 Pi Go 宿主未运行。启动宿主后重试，或在电脑上打开并共享该会话。';
    else if (error instanceof BridgeFailure && error.message === 'desktop_agent_unavailable') this.session.status = '所选 Agent 在电脑端不可用，请检查安装后刷新。';
    else if (error instanceof BridgeFailure && error.message === 'desktop_agent_mismatch') this.session.status = '电脑端返回的会话与所选 Agent 不一致，请刷新会话列表。';
    else if (path === '/new' && error instanceof BridgeFailure &&
      (error.message === 'desktop_session_not_ready' || error.message === 'desktop_handoff_failed')) {
      this.session.status = '所选 Agent 启动失败，请在电脑上检查登录和配置。';
    }
    else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_unshared') this.session.status = '该工作区尚未共享给手机。';
    else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_not_registered') this.session.status = '该工作区未在电脑端 Pi Go 的工作区列表中登记。';
    else if (error instanceof BridgeFailure && error.message === 'desktop_close_failed') this.session.status = '电脑端关闭工作区失败，请稍后重试。';
    else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_untrusted') this.session.status = '该工作区未在电脑端 Pi Go 中登记或授权。';
    else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_unconfirmed' && path === '/close-workspace') this.session.status = '电脑端尚未确认，请刷新列表查看工作区是否已移除。';
    else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_unconfirmed') this.session.status = '电脑端尚未确认操作，请刷新会话列表查看结果。';
    else if (error instanceof BridgeFailure && error.message === 'session_occupied') this.session.status = '同一会话由多个 Pi 进程打开。请在电脑上关闭重复会话后重试。';
    else if (error instanceof BridgeFailure && error.message === 'interaction_unavailable') {
      this.host.setInteraction();
      this.session.status = '此请求已处理或已失效。';
      this.streamSync.schedule(0);
    }
    else if (error instanceof BridgeFailure && error.message === 'metadata_conflict') this.session.status = '会话标记已变化，请重新搜索后再操作。';
    else if (error instanceof BridgeFailure && error.message === 'model_not_found') this.session.status = '模型已不可用，请重新打开设置。';
    else if (error instanceof BridgeFailure && error.message === 'session_busy') {
      this.session.status = path === '/model' ? '等待当前任务和队列结束后，再应用模型设置。' : '请等待当前任务和队列结束。';
    }
    else if (error instanceof BridgeFailure && error.message === 'reply_not_latest') this.session.status = '只有最近一轮回复可以重新生成。';
    else if (error instanceof BridgeFailure && error.message === 'image_not_supported') this.session.status = '当前模型不支持原消息中的图片。';
    else if (error instanceof BridgeFailure && error.message === 'not_found' && (path === '/fork' || path === '/regenerate')) {
      this.session.status = '请更新电脑端 Pi Go 后重试。';
    }
    else if (error instanceof BridgeFailure && error.message === 'model_not_applied') this.session.status = 'Pi 未应用所选模型，请在电脑上检查模型的登录状态或 API 配置。';
    else if (error instanceof BridgeFailure && error.message === 'invalid_name') this.session.status = '名称须为 1–200 字且不含换行。';
    else if (error instanceof BridgeFailure && error.status === 409) this.session.status = 'Pi 正在处理任务或会话已变化，请刷新后再试。';
    else this.session.status = '电脑端尚未确认操作，请刷新查看结果。';
    if (((path === '/open' && this.host.showSessions()) || path === '/fork' || path === '/regenerate') && this.session.status) {
      this.host.getUIContext().getPromptAction().showToast({ message: this.session.status });
    }
  }

  async send(): Promise<void> {
    const text = this.session.draft.trim();
    const id = this.session.currentId;
    const mode = this.session.idle ? 'send' : 'steer';
    const runId = this.session.idle ? undefined : this.session.runId;
    const attachments = this.session.attachments ?? [];
    if (!id || (!text && !attachments.length) || this.session.busy || this.session.openingSession || !this.session.reachable || this.session.pendingSend) return;
    if (attachments.some((item: DraftAttachment): boolean => item.kind === 'image') && !this.session.acceptsImage) {
      this.session.status = '此模型不支持图片，请先移除图片附件或换模型。';
      return;
    }
    if (text.startsWith('/') && attachments.length) {
      this.session.status = '命令发送不支持附件，请先移除附件。';
      return;
    }
    if (mode === 'steer' && !runId) return;
    if (this.host.chatState().unconfirmed.size >= 128) { this.session.status = '请先核对未确认的发送。'; return; }
    const epoch = this.session.epoch;
    const key = this.streamSync.draftKey(id);
    const afterId = this.session.messages[this.session.messages.length - 1]?.id ?? '';
    const pending: PendingSend = { requestId: util.generateRandomUUID(), text: text, attachments: attachments,
      steeringAfter: mode === 'steer' && !text.startsWith('/') ? afterId : undefined };
    this.host.chatState().unconfirmed.set(key, pending);
    this.session.pendingSend = pending;
    this.session.busy = true;
    this.session.status = '';
    if (!text.startsWith('/')) {
      const imageCount = attachments.filter((item: DraftAttachment): boolean => item.kind === 'image').length;
      const files = attachments.filter((item: DraftAttachment): boolean => item.kind === 'file')
        .map((item: DraftAttachment): string => item.name);
      if (mode === 'send') {
        const optimistic: OptimisticMessage = {
          id: pending.requestId,
          sessionKey: key,
          afterId: afterId,
          text: text,
          imageCount: imageCount,
          files: files,
          sending: true
        };
        this.session.optimisticMessages = this.session.optimisticMessages.concat([optimistic]).slice(-32);
      } else {
        const queued: QueuedSteering = {
          id: pending.requestId,
          sessionKey: key,
          afterId: afterId,
          text: text,
          imageCount: imageCount,
          files: files
        };
        this.session.liveRevision += 1;
        this.session.queuedSteering = this.session.queuedSteering.concat([queued]).slice(-128);
      }
    }
    this.session.draft = '';
    this.session.attachments = [];
    this.streamSync.rememberDraft(id);
    this.host.syncCommandPalette();
    this.session.transcriptFollow = true;
    this.session.pendingBottom = true;
    this.host.animateSend();
    try {
      const refs: AttachmentRef[] = [];
      for (let index = 0; index < pending.attachments.length; index += 1) {
        const item = pending.attachments[index];
        this.session.status = `正在上传附件（${index + 1}/${pending.attachments.length}）…`;
        const bytes = item.kind === 'image' && item.image
          ? new util.Base64Helper().decodeSync(item.image.jpeg)
          : item.file ? item.file.bytes : new Uint8Array(0);
        const uploaded = await this.uploadAttachment(item.kind, item.name, bytes);
        if (epoch !== this.session.epoch) return;
        refs.push({ token: uploaded.token, kind: item.kind });
      }
      if (refs.length) this.session.status = '附件已上传，正在发送…';
      if (mode === 'send') this.streamSync.beginOptimisticLiveRun();
      const liveRevision = this.session.liveRevision;
      const result = await this.host.request('/prompt', { id: id, text: text, requestId: pending.requestId, mode: mode,
        runId: runId, attachments: refs.length ? refs : undefined });
      if (epoch !== this.session.epoch) return;
      if (result.dispatched !== true) throw new Error('dispatch_unconfirmed');
      this.finishSend(key, pending);
      if (mode === 'send') {
        if (result.handled === true) {
          this.removeOptimistic(pending.requestId);
          this.streamSync.cancelOptimisticLiveRun();
        } else this.streamSync.trackDispatchedLiveRun(liveRevision);
      } else {
        this.session.status = '引导请求已交给 Pi。';
        this.streamSync.trackDispatchedLiveRun(liveRevision);
      }
    } catch (error) {
      this.removeOptimistic(pending.requestId);
      if (mode === 'steer') {
        this.session.queuedSteering = this.session.queuedSteering.filter((item: QueuedSteering): boolean => item.id !== pending.requestId);
      }
      if (mode === 'send') this.streamSync.cancelOptimisticLiveRun();
      if (epoch !== this.session.epoch) return;
      if (this.session.currentId === id) {
        if (!this.session.draft.trim() && pending.text) {
          this.session.draft = pending.text;
          this.streamSync.rememberDraft(id);
        }
        if (!this.session.attachments.length && pending.attachments.length) {
          this.session.attachments = pending.attachments;
        }
        this.host.syncCommandPalette();
      }
      if (error instanceof BridgeFailure && error.status === 401) this.host.leaveComputer(true);
      else if (error instanceof BridgeFailure && ['session_busy', 'session_not_streaming', 'session_changed',
        'session_occupied', 'invalid_prompt', 'invalid_request_id', 'probe_request_limit', 'invalid_image', 'image_not_supported', 'payload_too_large',
        'invalid_attachment', 'unknown_attachment', 'invalid_content_type', 'not_found',
        'unknown_command', 'command_attachments'].includes(error.message)) {
        this.host.chatState().unconfirmed.delete(key);
        this.session.pendingSend = undefined;
        if (error.message === 'session_occupied') {
          this.session.status = '该会话正被电脑 Codex 桌面端占用，可一键创建分支接力。';
          this.promptForkAndContinue(id, text, attachments);
        } else {
          this.session.status = error.message === 'image_not_supported' ? '此模型不支持图片；草稿已保留。' :
            ['invalid_image', 'payload_too_large'].includes(error.message) ? '发送内容过大（单文件 8MB 内）或图片格式无效；草稿已保留。' :
              ['invalid_attachment', 'unknown_attachment', 'invalid_content_type'].includes(error.message) ? '附件无效或已过期；草稿已保留。' :
                error.message === 'not_found' ? '电脑端扩展版本过旧，不支持附件上传；草稿已保留。' :
                  error.message === 'unknown_command' ? '电脑未找到该命令；输入 / 可查看可用命令，草稿已保留。' :
                    error.message === 'command_attachments' ? '命令发送不支持附件；草稿已保留。' :
                      '电脑未接收此次发送。请检查会话是否仍在运行；草稿已保留。';
        }
      } else this.session.status = '发送结果未知。草稿已保留，不会自动重发。';
    } finally {
      this.session.busy = false;
      this.streamSync.schedule(0);
    }
  }

  private promptForkAndContinue(sessionId: string, text: string, attachments: DraftAttachment[]): void {
    const ui = this.host.getUIContext();
    if (!ui.showAlertDialog) return;
    let lastAssistantId: string | undefined = undefined;
    for (let index = this.session.messages.length - 1; index >= 0; index -= 1) {
      if (this.session.messages[index].role === 'assistant') {
        lastAssistantId = this.session.messages[index].id;
        break;
      }
    }
    const epoch = this.session.epoch;
    ui.showAlertDialog({
      title: '会话正被电脑 Codex 占用',
      message: '电脑上的 Codex 桌面端正停在该会话上（持有独占写入锁）。是否一键创建分支会话并立即发送这条消息？',
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      primaryButton: {
        value: '稍后',
        fontColor: $r('app.color.pigo_muted'),
        action: () => {}
      },
      secondaryButton: {
        value: '一键分支接力',
        fontColor: this.host.accent(),
        action: () => {
          if (epoch !== this.session.epoch || this.session.currentId !== sessionId) return;
          void this.forkAndContinue(sessionId, lastAssistantId, text, attachments);
        }
      }
    });
  }

  async forkAndContinue(sessionId: string, messageId: string | undefined,
    text: string, attachments: DraftAttachment[]): Promise<void> {
    const forked = await this.requestAction('/fork', {
      id: sessionId,
      messageId: messageId,
      history: this.session.syncMode !== 'legacy'
    });
    if (!forked || !this.session.currentId || this.session.currentId === sessionId) return;
    const oldKey = this.streamSync.draftKey(sessionId);
    this.host.chatState().drafts.delete(oldKey);
    this.host.chatState().draftAttachments.delete(oldKey);
    this.session.draft = text;
    this.session.attachments = attachments;
    await this.send();
  }

  private async uploadAttachment(kind: string, name: string, bytes: Uint8Array): Promise<UploadedAttachment> {
    return this.host.uploadAttachment(kind, name, bytes);
  }

  private finishSend(key: string, pending: PendingSend): void {
    this.host.chatState().unconfirmed.delete(key);
    this.host.chatState().draftAttachments.delete(key);
    for (const item of pending.attachments) {
      if (item.image) item.image.preview.release().catch((): void => {});
    }
    if (key !== this.streamSync.draftKey(this.session.currentId)) return;
    if (pending.steeringAfter !== undefined) {
      if (!this.session.queuedSteering.some((item: QueuedSteering): boolean => item.id === pending.requestId)) {
        const message: QueuedSteering = { id: pending.requestId, sessionKey: key, afterId: pending.steeringAfter, text: pending.text,
          imageCount: pending.attachments.filter((item: DraftAttachment): boolean => item.kind === 'image').length,
          files: pending.attachments.filter((item: DraftAttachment): boolean => item.kind === 'file')
            .map((item: DraftAttachment): string => item.name) };
        this.session.liveRevision += 1;
        this.session.queuedSteering = this.session.queuedSteering.concat([message]).slice(-128);
      }
      this.reconcileSteering(this.session.idle);
    } else if (this.session.optimisticMessages.some((item: OptimisticMessage): boolean => item.id === pending.requestId && item.sending)) {
      this.session.optimisticMessages = this.session.optimisticMessages.map((item: OptimisticMessage): OptimisticMessage =>
        item.id === pending.requestId ? {
          id: item.id,
          sessionKey: item.sessionKey,
          afterId: item.afterId,
          text: item.text,
          imageCount: item.imageCount,
          files: item.files,
          sending: false
        } : item);
      this.reconcileSteering(false);
    }
    this.session.pendingSend = undefined;
    // 自己刚发出的消息必须立刻滚到可见位置，即使之前在翻历史。
    this.session.transcriptFollow = true;
    this.session.pendingBottom = true;
    if (this.session.draft.trim() === pending.text) this.session.draft = '';
    this.session.attachments = [];
    this.host.syncCommandPalette();
  }

  private removeOptimistic(requestId: string): void {
    if (!this.session.optimisticMessages.some((item: OptimisticMessage): boolean => item.id === requestId)) return;
    this.session.optimisticMessages = this.session.optimisticMessages.filter((item: OptimisticMessage): boolean => item.id !== requestId);
  }

  reconcileSteering(settled: boolean): void {
    const key = this.streamSync.draftKey(this.session.currentId);
    const remaining = this.host.chatState().reconcileSteering(this.session.queuedSteering, this.session.messages, key,
      settled, this.session.pendingSend);
    if (remaining !== this.session.queuedSteering) this.session.queuedSteering = remaining;
    const optimistic = this.host.chatState().reconcileOptimistic(this.session.optimisticMessages, this.session.messages, key, settled);
    if (optimistic !== this.session.optimisticMessages) this.session.optimisticMessages = optimistic;
  }

  async checkSend(): Promise<void> {
    const pending = this.session.pendingSend;
    const id = this.session.currentId;
    if (!pending || !id || this.session.busy || this.session.openingSession || !this.session.reachable) return;
    const epoch = this.session.epoch;
    const key = this.streamSync.draftKey(id);
    this.session.busy = true;
    try {
      const result = await this.host.request('/receipt', { id: id, requestId: pending.requestId });
      if (epoch !== this.session.epoch) return;
      if (result.dispatched) {
        this.finishSend(key, pending);
        this.session.status = '电脑已记录此次发送。';
      } else this.session.status = '未找到发送记录。请先在电脑上核对会话，再决定是否重发。';
    } catch (error) {
      if (epoch !== this.session.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.host.leaveComputer(true);
      else this.session.status = '仍无法核对发送；草稿已保留。';
    } finally { this.session.busy = false; }
  }
}
