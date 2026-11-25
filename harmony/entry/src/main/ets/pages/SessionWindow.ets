import { KeyboardAvoidMode } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppUiState, appUiState, windowAppUiState } from '../AppUiState';
import { themePalette } from '../Appearance';
import { ChatTranscript } from '../components/ChatTranscript';
import { PendingInteractionCard } from '../components/ChatDialogs';
import { headerSymbol } from '../components/HeaderSymbol';
import { SessionViewState } from '../model/StreamSyncController';
import { DraftAttachment, LiveTool } from '../model/PiGoTypes';
import { WINDOW_CONVERSATION_STORAGE, WindowConversation } from '../model/WindowConversation';
import { choosePromptFiles, MAX_FILES, PromptFile } from '../PromptFile';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { markdownWorkspacePath } from '../ChatPaths';

@Entry
@ComponentV2
struct SessionWindow {
  @Local private app: AppUiState = appUiState();
  @Local private win: AppUiState = windowAppUiState();
  @Local private session: SessionViewState = new SessionViewState();
  @Local private preview: string = '';
  @Local private previewImage: string = '';
  private model?: WindowConversation;
  private readonly scroll: Scroller = new Scroller();
  private transcriptHeight: number = 0;

  aboutToAppear(): void {
    this.model = LocalStorage.getShared().get<WindowConversation>(WINDOW_CONVERSATION_STORAGE);
    if (!this.model) return;
    this.session = this.model.session;
    const ui = this.getUIContext();
    ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.model.attach(ui, (text: string): void => { this.preview = text; });
  }

  onBackPress(): boolean {
    if (this.preview || this.previewImage) this.closePreview();
    else this.model?.close();
    return true;
  }

  private closePreview(): void {
    this.preview = '';
    this.previewImage = '';
  }

  private title(): string {
    return this.session.sessionName || '未命名会话';
  }

  private accent(): string {
    return themePalette(this.app.themeId, this.app.darkMode).accent;
  }

  private accentTint(): string {
    return themePalette(this.app.themeId, this.app.darkMode).accentTint;
  }

  private status(): string {
    if (!this.session.reachable) return '等待连接';
    if (this.session.interaction) return '待处理';
    if (this.session.queued) return '排队中';
    return this.session.idle ? '' : '运行中';
  }

  private async copy(value: string): Promise<void> {
    await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value));
  }

  private async openLink(target: string, cwd: string, document: string): Promise<void> {
    if (/^https?:\/\/[^\s]+$/i.test(target)) {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await context.openLink(target);
      } catch {
        this.getUIContext().getPromptAction().showToast({ message: '无法打开链接。' });
      }
      return;
    }
    const path = markdownWorkspacePath(target, cwd, document);
    if (path) await this.openFile(cwd, path, !document);
  }

  private async openFile(cwd: string, path: string, lookup: boolean): Promise<void> {
    try {
      const text = await this.model?.previewFile(cwd, path, lookup);
      if (text === undefined) throw new Error('file_unavailable');
      this.preview = text || '空文件';
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: '无法在会话窗口预览此文件。' });
    }
  }

  private positionTranscript(id: string, height: number): void {
    if (id !== this.session.currentId || height <= 0) return;
    this.transcriptHeight = height;
    if (this.session.pendingBottom && this.session.transcriptFollow) {
      this.scroll.scrollTo({ xOffset: 0, yOffset: height, animation: false });
    }
    this.session.pendingBottom = false;
  }

  private async toolDetail(tool: LiveTool, message: string): Promise<void> {
    if (!this.model) return;
    const id = encodeURIComponent(this.model.id);
    let detail = tool.detail || tool.name;
    try {
      const result = await this.model.request(`/tool-detail?id=${id}&message=${encodeURIComponent(message)}&tool=${encodeURIComponent(tool.id)}`);
      if (result.toolDetail) detail = [result.toolDetail.input, result.toolDetail.output].filter(Boolean).join('\n\n');
    } catch { /* The transcript already has a short tool summary. */ }
    this.preview = detail;
  }

  private async attachFile(): Promise<void> {
    if (!this.model || this.session.busy || this.session.pendingSend) return;
    const count = this.session.attachments.filter((item: DraftAttachment): boolean => item.kind === 'file').length;
    if (count >= MAX_FILES) return;
    this.session.busy = true;
    try {
      const files = await choosePromptFiles(MAX_FILES - count);
      const attachments = files.map((file: PromptFile): DraftAttachment => ({ kind: 'file', name: file.name, size: file.size, file: file }));
      this.model.setAttachments(this.session.attachments.concat(attachments));
    } catch {
      this.session.status = '未能读取所选文件。';
    } finally { this.session.busy = false; }
  }

  @Builder
  header() {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(this.title()).id('native-session-title').fontSize(18).fontWeight(FontWeight.Bold).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.pigo_text')).width('100%')
        if (this.status()) {
          Text(this.status()).fontSize(12).fontColor(this.accent()).width('100%')
        }
      }.layoutWeight(1)
      Button({ type: ButtonType.Normal }) {
        headerSymbol($r('sys.symbol.xmark'), $r('app.color.pigo_muted'), 18)
      }.id('native-session-close').width(44).height(44).padding(0).backgroundColor(Color.Transparent)
        .accessibilityText('关闭会话窗口').onClick(() => { this.model?.close(); })
    }.width('100%').padding({ left: 14, right: 4, top: 4, bottom: 4 })
  }

  @Builder
  transcript() {
    ChatTranscript({
      base: this.model?.endpoint.address ?? '',
      busy: this.session.busy,
      closeMarkdownTableReader: (): void => {},
      copyText: (text: string): Promise<void> => this.copy(text),
      replyActionsEnabled: false,
      replySpeechEnabled: false,
      currentId: this.session.currentId,
      darkMode: this.app.darkMode,
      dismissKeyboard: (): void => {},
      historyCursor: this.session.historyCursor,
      idle: this.session.idle,
      keyboardHeight: 0,
      liveText: this.session.liveText,
      liveThinking: this.session.liveThinking,
      liveThinkingOpen: this.session.liveThinkingOpen!!,
      liveTools: this.session.liveTools,
      loadHistory: (): Promise<void> => this.model?.stream.loadHistory() ?? Promise.resolve(),
      loadHistoryImage: (_id: string, message: string, index: number, tool: string): Promise<string> =>
        this.model?.historyImage(message, index, tool) ?? Promise.reject(new Error('image_not_found')),
      loadMarkdownImage: (target: string, cwd: string, document: string): Promise<string> =>
        this.model?.markdownImage(target, cwd, document) ?? Promise.reject(new Error('image_not_found')),
      loadingMessageText: this.session.loadingMessageText,
      messages: this.session.messages,
      openMarkdownLink: (target: string, cwd: string, document: string): Promise<void> => this.openLink(target, cwd, document),
      openMarkdownTableReader: (source: string): void => { this.preview = source; },
      openReferencedFile: (cwd: string, path: string, lookup: boolean): Promise<void> => this.openFile(cwd, path, lookup),
      openToolDetails: (tool: LiveTool, message: string): void => { void this.toolDetail(tool, message); },
      openingFile: false,
      positionTranscript: (id: string, height: number): void => this.positionTranscript(id, height),
      queuedSteering: this.session.queuedSteering,
      optimisticMessages: this.session.optimisticMessages,
      reachable: this.session.reachable,
      showChatImage: (source: string): void => { this.previewImage = source; },
      showFullReply: (message: string): Promise<void> => this.model?.stream.showFullReply(message) ?? Promise.resolve(),
      thinkingOpenIds: this.session.thinkingOpenIds,
      toggleThinking: (id: string, open: boolean): void => {
        const ids = this.session.thinkingOpenIds.filter((value: string): boolean => value !== id);
        this.session.thinkingOpenIds = open ? ids.concat([id]) : ids;
      },
      transcript: this.scroll,
      transcriptFollow: this.session.transcriptFollow!!,
      workspaceCwd: this.session.workspaceCwd,
      themeId: this.app.themeId,
      accent: this.accent(),
      accentTint: this.accentTint(),
      readTranscriptHeight: (): number => this.transcriptHeight,
      setTranscriptViewport: (): void => {}
    })
  }

  @Builder
  composer() {
    Column({ space: 5 }) {
      if (this.session.attachments.length) {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.session.attachments, (file: DraftAttachment, index: number) => {
              Button() {
                Text(`${file.name} ×`).fontSize(12).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.height(32).constraintSize({ maxWidth: 164 })
                .enabled(!this.session.busy && !this.session.pendingSend)
                .onClick(() => { this.model?.removeAttachment(index); })
            }, (file: DraftAttachment, index: number) => `${index}:${file.name}`)
          }
        }.scrollable(ScrollDirection.Horizontal).width('100%')
      }
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.plus'), $r('app.color.pigo_muted'), 18)
        }.width(40).height(42).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('添加附件').enabled(!this.session.busy && !this.session.pendingSend)
          .onClick(() => { void this.attachFile(); })
        TextArea({ text: this.session.draft, placeholder: '输入消息' }).id('native-session-draft').layoutWeight(1)
          .fontSize(15).fontColor($r('app.color.pigo_text')).backgroundColor($r('app.color.pigo_control'))
          .constraintSize({ minHeight: 42, maxHeight: 104 }).enabled(!(this.session.pendingSend && !this.session.busy))
          .onChange((value: string): void => { this.model?.setDraft(value); })
        if (!this.session.idle && !this.session.draft.trim() && !this.session.attachments.length) {
          Button('停止').id('native-session-stop').height(42).fontSize(13)
            .enabled(this.session.reachable && !this.session.busy)
            .onClick(() => { void this.model?.actions.requestAction('/abort', { id: this.session.currentId, runId: this.session.runId }); })
        } else {
          Button('发送').id('native-session-send').height(42).fontSize(13)
            .enabled(this.session.reachable && !this.session.busy && !this.session.pendingSend &&
              !!(this.session.draft.trim() || this.session.attachments.length) && (this.session.idle || !!this.session.runId))
            .onClick(() => { void this.model?.actions.send(); })
        }
      }.width('100%')
      if (this.session.status) {
        Text(this.session.status).fontSize(12).fontColor($r('app.color.pigo_muted')).alignSelf(ItemAlign.Start)
      }
    }.width('100%').padding({ left: 8, right: 8, top: 4, bottom: 8 })
  }

  build() {
    Column() {
      this.header()
      if (this.previewImage) {
        Button('返回会话').onClick(() => { this.closePreview(); })
        Image(fileUri.getUriFromPath(this.previewImage)).width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
      } else if (this.preview) {
        Button('返回会话').onClick(() => { this.closePreview(); })
        Scroll() {
          Text(this.preview).fontSize(14).width('100%').padding(12).fontColor($r('app.color.pigo_text')).copyOption(CopyOptions.LocalDevice)
        }.width('100%').layoutWeight(1)
      } else {
        if (this.session.interaction) {
          Scroll() {
            PendingInteractionCard({
              request: this.session.interaction,
              interactionDraft: this.session.interactionDraft,
              reachable: this.session.reachable,
              busy: this.session.busy,
              openingSession: false,
              accent: this.accent(),
              accentForeground: '#FFFFFF',
              answerInteraction: (id: string, answer: string | boolean): Promise<void> => this.model?.answer(id, answer) ?? Promise.resolve(),
              changeDraft: (id: string, value: string): void => {
                if (id === this.session.interaction?.id) this.session.interactionDraft = value;
              }
            })
          }.width('100%').constraintSize({ maxHeight: 150 })
        }
        if (this.session.pendingSend && !this.session.busy) {
          Row({ space: 8 }) {
            Button('核对发送').enabled(this.session.reachable).onClick(() => { void this.model?.actions.checkSend(); })
            Button('保留草稿').onClick(() => { this.model?.clearPending(); })
          }.width('100%').padding(8)
        }
        this.transcript()
        this.composer()
      }
    }.id('native-session-window').width('100%').height('100%').backgroundColor($r('app.color.pigo_panel'))
      .padding({ top: Math.max(0, this.win.statusBarHeight), bottom: Math.max(0, this.win.navBarHeight),
        left: Math.max(0, this.win.leftInset), right: Math.max(0, this.win.rightInset) })
  }
}
