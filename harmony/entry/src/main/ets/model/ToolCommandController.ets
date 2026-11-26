import { normalizeWorkspacePath } from '../ChatPaths';
import { CommandList, CommandState, commandDraft, skillDraft } from './CommandState';
import { BridgeFailure, BridgeReply, CommandRow, LiveTool, ModelOption, Payload, ToolDetails } from './PiGoTypes';
import { SessionActions } from './SessionActions';
import { SessionViewState } from './StreamSyncController';
import { VoiceComposerState } from './VoiceComposerController';

export interface ToolCommandHost {
  session: SessionViewState;
  voiceState: VoiceComposerState;
  sessionActions: SessionActions;
  request: (path: string, input?: Payload) => Promise<BridgeReply>;
  dismissKeyboard: () => void;
  leaveComputer: (revoked?: boolean) => void;
  themeId: () => string;
  themeMotionEnabled: () => boolean;
  canObserveSakuraTap: () => boolean;
}

@ObservedV2
export class ToolCommandState {
  @Trace showToolDetails: boolean = false;
  @Trace selectedTool?: LiveTool = undefined;
  @Trace selectedToolDetails?: ToolDetails = undefined;
  @Trace toolDetailError: string = '';
  @Trace commandRows: CommandRow[] = [];
  @Trace commandPalette: boolean = false;
  @Trace commandsLoading: boolean = false;
  @Trace commandError: string = '';
  @Trace showComposerMenu: boolean = false;
  @Trace showSkillPicker: boolean = false;
  @Trace showModelMenu: boolean = false;
  @Trace sakuraBurstSeq: number = 0;
  @Trace sakuraBurstKind: string = 'send';
  @Trace sakuraBloomSeq: number = 0;
  @Trace sakuraBloomX: number = 0;
  @Trace sakuraBloomY: number = 0;
  @Trace sakuraGirlTapSeq: number = 0;
  @Trace sakuraCelebrateSeq: number = 0;
}

export class ToolCommandController {
  readonly state: ToolCommandState = new ToolCommandState();
  readonly commandState: CommandState = new CommandState();
  selectedToolMessageId: string = '';
  private toolDetailRevision: number = 0;
  private themeTapDownX: number = 0;
  private themeTapDownY: number = 0;
  private themeTapDownAt: number = 0;
  private themeTapMoved: boolean = false;
  private readonly host: ToolCommandHost;

  constructor(host: ToolCommandHost) {
    this.host = host;
  }

  toolFile(tool: LiveTool): string {
    if (tool.state === 'run' || !['write', 'edit', 'read'].includes(tool.name)) return '';
    return normalizeWorkspacePath(this.host.session.workspaceCwd, this.state.selectedToolDetails?.path ?? tool.detail);
  }

  toolIcon(tool: LiveTool): Resource {
    if (tool.name === 'computer_screenshot') return $r('sys.symbol.camera');
    if (tool.name === 'bash') return $r('sys.symbol.code_square');
    if (tool.name === 'grep' || tool.name === 'find' || tool.name === 'web_search') return $r('sys.symbol.magnifyingglass');
    if (tool.name === 'write' || tool.name === 'edit') return $r('sys.symbol.square_and_pencil');
    return $r('sys.symbol.folder');
  }

  openToolDetails(tool: LiveTool, messageId: string): void {
    this.host.dismissKeyboard();
    this.state.selectedTool = tool;
    this.selectedToolMessageId = messageId;
    this.state.selectedToolDetails = undefined;
    this.state.showToolDetails = true;
    void this.loadToolDetails();
  }

  closeToolDetails(): void {
    this.toolDetailRevision++;
    this.state.showToolDetails = false;
    this.state.selectedTool = undefined;
    this.state.selectedToolDetails = undefined;
    this.selectedToolMessageId = '';
    this.state.toolDetailError = '';
  }

  refreshSelectedTool(tool: LiveTool, messageId: string = ''): void {
    if (this.state.selectedTool?.id !== tool.id || this.state.selectedTool.state === 'ok' || this.state.selectedTool.state === 'fail' ||
      this.state.selectedTool.state === tool.state ||
      (messageId && this.selectedToolMessageId && messageId !== this.selectedToolMessageId)) return;
    this.state.selectedTool = tool;
    if (messageId) this.selectedToolMessageId = messageId;
    void this.loadToolDetails();
  }

  async loadToolDetails(): Promise<void> {
    const tool = this.state.selectedTool;
    const session = this.host.session;
    if (!tool || !session.currentId) return;
    const revision = ++this.toolDetailRevision;
    this.state.toolDetailError = '';
    const message = this.selectedToolMessageId ? `&message=${encodeURIComponent(this.selectedToolMessageId)}` : '';
    try {
      const reply = await this.host.request(`/tool-detail?id=${encodeURIComponent(session.currentId)}&tool=${encodeURIComponent(tool.id)}${message}&images=1`);
      if (revision !== this.toolDetailRevision) return;
      this.state.selectedToolDetails = reply.toolDetail;
      if (!reply.toolDetail) this.state.toolDetailError = '没有可用的工具详情';
    } catch (error) {
      if (revision !== this.toolDetailRevision) return;
      this.state.toolDetailError = error instanceof BridgeFailure && error.message === 'not_found'
        ? '请更新电脑端 Pi Go 以查看完整详情' : '暂时无法加载工具详情';
    }
  }

  commandPaletteActive(): boolean {
    if (this.host.voiceState.voiceMode || !this.host.session.draft) return false;
    const text = this.host.session.draft.trimStart();
    return text.startsWith('/') && !/\s/.test(text);
  }

  commandMatches(): CommandRow[] {
    const text = this.host.session.draft.trimStart();
    const token = text.length > 1 ? text.slice(1) : '';
    const needle = token.toLowerCase();
    return this.state.commandRows.filter((row: CommandRow): boolean =>
      !needle || row.name.toLowerCase().includes(needle)).slice(0, 12);
  }

  syncCommandPalette(): void {
    if (!this.commandPaletteActive()) { this.state.commandPalette = false; return; }
    this.state.commandPalette = true;
    if (this.commandState.stale()) void this.loadCommands();
  }

  resetCommands(): void {
    this.commandState.reset();
    this.state.commandsLoading = false;
    this.state.commandError = '';
    this.state.commandPalette = false;
    this.state.commandRows = [];
    this.state.showComposerMenu = false;
  }

  async loadCommands(): Promise<void> {
    const session = this.host.session;
    if (!session.reachable || !session.currentId || session.openingSession) return;
    await this.commandState.load(session.currentId, (): Promise<BridgeReply> => this.host.request('/commands'), (list: CommandList): void => {
      this.state.commandError = list.error;
      if (list.rows) this.state.commandRows = list.rows;
      this.state.commandsLoading = list.loading;
    });
  }

  pickCommand(row: CommandRow, prompt: string = ''): void {
    this.host.session.draft = commandDraft(row, prompt);
    this.state.commandPalette = false;
  }

  openComposerMenu(): void {
    this.host.dismissKeyboard();
    this.state.showSkillPicker = false;
    this.state.showComposerMenu = true;
  }

  openSkillPicker(): void {
    this.state.showSkillPicker = true;
    if (this.commandState.stale()) void this.loadCommands();
  }

  pickSkill(row: CommandRow): void {
    this.host.session.draft = skillDraft(row, this.host.session.draft);
    this.state.commandPalette = false;
    this.host.voiceState.voiceMode = false;
    this.state.showComposerMenu = false;
  }

  commandSourceLabel(source: string): string {
    if (source === 'skill') return '技能';
    if (source === 'prompt') return '模板';
    if (source === 'extension') return '扩展';
    return source;
  }

  async openModelMenu(): Promise<void> {
    const session = this.host.session;
    if (!session.reachable || !session.currentId || session.busy || session.openingSession) return;
    if (!session.idle || session.queued) { session.status = '等待当前任务和队列结束后可切换模型。'; return; }
    const epoch = session.epoch;
    session.busy = true;
    session.status = '';
    this.host.dismissKeyboard();
    try {
      const result = await this.host.request('/models');
      if (epoch !== session.epoch || result.session?.id !== session.currentId) return;
      session.models = result.models ?? [];
      if (!session.models.length) { session.status = '没有可用模型，请在电脑上检查 Pi CLI 的模型配置。'; return; }
      this.state.showModelMenu = true;
    } catch (error) {
      if (epoch !== session.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.host.leaveComputer(true);
      else if (error instanceof BridgeFailure && error.message === 'session_busy') session.status = '等待当前任务和队列结束后可切换模型。';
      else if (error instanceof BridgeFailure && error.message === 'model_not_found') session.status = '模型已不可用，请重新打开。';
      else session.status = '模型列表加载失败，请重试。';
    } finally { session.busy = false; }
  }

  async applyModelFromMenu(index: number): Promise<void> {
    const session = this.host.session;
    const model = session.models[index];
    if (!model) return;
    const level = model.levels.includes(session.currentLevel) ? session.currentLevel : model.levels[0] ?? 'off';
    await this.host.sessionActions.requestAction('/model', { id: session.currentId, provider: model.provider,
      modelId: model.id, thinkingLevel: level });
  }

  async applyThinkingLevelFromMenu(level: string): Promise<void> {
    const session = this.host.session;
    const model = session.currentModel ?? session.models.find((item: ModelOption): boolean => this.isCurrentModel(item));
    if (!model || level === session.currentLevel) return;
    await this.host.sessionActions.requestAction('/model', { id: session.currentId, provider: model.provider,
      modelId: model.id, thinkingLevel: level });
  }

  thinkingLevelLabel(level: string): string {
    switch (level) {
      case 'off': return '关闭';
      case 'minimal': return '极简';
      case 'low': return '低';
      case 'medium': return '中';
      case 'high': return '高';
      case 'xhigh': return '极高';
      case 'max': return '最高';
      default: return level;
    }
  }

  isCurrentModel(model: ModelOption): boolean {
    const session = this.host.session;
    return session.currentModel?.provider === model.provider && session.currentModel?.id === model.id;
  }

  triggerSakuraBloom(x: number, y: number): void {
    this.state.sakuraBloomX = x;
    this.state.sakuraBloomY = y;
    this.state.sakuraBloomSeq += 1;
  }

  tapSakuraGirl(): void {
    this.state.sakuraGirlTapSeq += 1;
  }

  observeThemeTap(event: TouchEvent): void {
    if (!this.host.themeMotionEnabled()) return;
    const theme = this.host.themeId();
    if (theme !== 'sakura' && theme !== 'jellyfish' && theme !== 'sahara') return;
    if (!this.host.canObserveSakuraTap()) return;
    const touch = event.touches.length ? event.touches[0] : (event.changedTouches.length ? event.changedTouches[0] : undefined);
    if (!touch) return;
    if (event.type === TouchType.Down) {
      this.themeTapDownX = touch.x;
      this.themeTapDownY = touch.y;
      this.themeTapDownAt = Date.now();
      this.themeTapMoved = false;
    } else if (event.type === TouchType.Move) {
      if (Math.hypot(touch.x - this.themeTapDownX, touch.y - this.themeTapDownY) > 16) this.themeTapMoved = true;
    } else if (event.type === TouchType.Up && !this.themeTapMoved && Date.now() - this.themeTapDownAt < 340) {
      this.triggerSakuraBloom(touch.x, touch.y);
    }
  }
}
