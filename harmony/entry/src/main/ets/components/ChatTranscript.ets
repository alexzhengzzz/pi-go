import { unboundAction } from './ComponentAction';
import { glassButtonSurface } from '../Immersive';
import { ChatContent } from '../ChatContent';
import { ChatImage } from '../ChatImage';
import { markdownWorkspacePath, messageFileChips, normalizeWorkspacePath } from '../ChatPaths';
import { ChatMessage, LiveTool, QueuedSteering } from '../model/PiGoTypes';
import { headerSymbol } from './HeaderSymbol';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@Extend(Button)
function headerAction() {
  .width(44).height(44).padding(0).borderRadius(22).backgroundColor(Color.Transparent)
}

@Component
export struct ChatTranscript {
  @Prop base: string;
  @Prop busy: boolean;
  @Require closeMarkdownTableReader: () => void = unboundAction;
  @Require copyText: (value: string) => Promise<void> = unboundAction;
  @Prop currentId: string;
  @Prop darkMode: boolean;
  @Require dismissKeyboard: () => void = unboundAction;
  @Prop historyCursor?: string;
  @Prop idle: boolean;
  @Prop keyboardHeight: number;
  @Prop liveText: string;
  @Prop liveThinking: string;
  @Link liveThinkingOpen: boolean;
  @Link liveTools: LiveTool[];
  @Require loadHistory: () => Promise<void> = unboundAction;
  @Require loadHistoryImage: (sessionId: string, messageId: string, index: number, toolId: string) => Promise<string> = unboundAction;
  @Require loadMarkdownImage: (target: string, cwd: string, documentPath: string) => Promise<string> = unboundAction;
  @Prop loadingMessageText: string;
  @Link messages: ChatMessage[];
  @Require openMarkdownLink: (target: string, cwd: string, documentPath: string) => Promise<void> = unboundAction;
  @Require openMarkdownTableReader: (source: string, cwd: string, documentPath: string) => void = unboundAction;
  @Require openReferencedFile: (cwd: string, path: string, lookupName: boolean) => Promise<void> = unboundAction;
  @Require openToolDetails: (tool: LiveTool, messageId: string) => void = unboundAction;
  @Prop openingFile: boolean;
  @Require positionTranscript: (id: string, contentHeight: number) => void = unboundAction;
  @Link queuedSteering: QueuedSteering[];
  @Prop reachable: boolean;
  @Require showChatImage: (source: string, label: string) => void = unboundAction;
  @Require showFullReply: (messageId: string) => Promise<void> = unboundAction;
  @Link thinkingOpenIds: string[];
  @Require toggleThinking: (id: string, open: boolean) => void = unboundAction;
  @Require transcript: Scroller = new Scroller();
  @Link transcriptFollow: boolean;
  @Prop workspaceCwd: string;
  @BuilderParam emptyTranscript: () => void = this.defaultEmptyTranscript;
  @Prop accent: string;
  @Prop accentTint: string;
  @Prop topPadding: number = 10;
  @Require readTranscriptHeight: () => number = unboundAction;
  @Require setTranscriptViewport: (height: number) => void = unboundAction;

  @Builder
  defaultEmptyTranscript() {}

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      ForEach([this.currentId], (transcriptId: string) => {
        Scroll(this.transcript) {
          Column({ space: 10 }) {
            if (this.historyCursor) {
              Button('更早的消息').chatAction().id('history-more').enabled(this.reachable && !this.busy)
                .onClick(() => { void this.loadHistory(); })
            }
            if (!this.messages.length && !this.liveText && !this.liveTools.length && !this.liveThinking && this.idle) {
              this.emptyTranscript()
            }
            ForEach(this.messages, (message: ChatMessage) => {
              if (message.text || message.thinking || message.imageCount) {
                Row() {
                  Column({ space: 8 }) {
                    if (message.thinking) this.thinkingCard(message.id, message.thinking, message.thinkingMs ?? -1,
                      this.thinkingOpenIds.includes(message.id))
                    if (message.text) {
                      if (message.role === 'user') {
                        Text(message.text).fontSize(16).lineHeight(26)
                          .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.pigo_text'))
                      } else {
                        this.richChatText(message.text, this.workspaceCwd)
                      }
                      if (this.messageFiles(message).length) {
                        Flex({ wrap: FlexWrap.Wrap }) {
                          ForEach(this.messageFiles(message), (path: string) => {
                            Column() {
                              this.fileChip(path, message.role !== 'user')
                            }.margin({ right: 8, bottom: 8 })
                          }, (path: string) => path)
                        }.width('100%')
                      }
                      if (message.textTruncated) {
                        Button(this.loadingMessageText === message.id ? '正在加载全文…' : '查看完整回复').chatAction()
                          .enabled(this.reachable && !this.loadingMessageText)
                          .onClick(() => { void this.showFullReply(message.id); })
                      } else if (message.role !== 'user') {
                        this.copyButton('复制回复', message.text)
                      }
                    }
                    if (message.imageCount) {
                      Column({ space: 6 }) {
                        this.historyImages(message.imageCount, this.currentId, message.id)
                      }.id(`image-message-${message.id}`).alignItems(HorizontalAlign.Start)
                    }
                  }.alignItems(HorizontalAlign.Start).padding(message.role === 'user' ?
                    { left: 14, right: 14, top: 10, bottom: 10 } : 0)
                    .width(message.role === 'user' ? undefined : '100%')
                    .constraintSize({ maxWidth: message.role === 'user' ? '88%' : '100%' })
                    .backgroundColor(message.role === 'user' ? this.accentTint : Color.Transparent)
                    .borderRadius({ topLeft: 17, topRight: 6, bottomLeft: 17, bottomRight: 17 })
                }.width('100%').justifyContent(message.role === 'user' ? FlexAlign.End : FlexAlign.Start)
                  .padding({ top: message.role === 'user' ? 14 : 8, bottom: 4 })
              }
              this.toolGroup(message.tools ?? [], message.id)
            }, (message: ChatMessage) => this.transcriptMessageKey(message))
            this.toolGroup(this.unlistedLiveTools(), '')
            if (this.liveThinking) this.thinkingCard('', this.liveThinking, -1, this.liveThinkingOpen)
            if (this.liveText) {
              Column({ space: 8 }) {
                this.richChatText(this.liveText, this.workspaceCwd)
                if (messageFileChips(this.liveText, this.workspaceCwd).length) {
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(messageFileChips(this.liveText, this.workspaceCwd), (path: string) => {
                      Column() {
                        this.fileChip(path, true)
                      }.margin({ right: 8, bottom: 8 })
                    }, (path: string) => path)
                  }.width('100%')
                }
              }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 10, bottom: 18 })
            }
            ForEach(this.queuedSteering.filter((message: QueuedSteering): boolean => message.sessionKey === this.draftKey(this.currentId)),
              (message: QueuedSteering) => {
                Row() {
                  Column({ space: 6 }) {
                    if (message.text) Text(message.text).fontSize(16).lineHeight(26)
                      .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.pigo_text'))
                    if (message.imageCount) Text(`图片 × ${message.imageCount}`).fontSize(13).fontColor($r('app.color.pigo_muted'))
                    ForEach(message.files, (name: string) => {
                      Text(name).fontSize(13).fontColor($r('app.color.pigo_muted'))
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    })
                    Text('排队中').fontSize(12).fontColor($r('app.color.pigo_muted'))
                  }.alignItems(HorizontalAlign.Start).padding(13).constraintSize({ maxWidth: '88%' })
                    .backgroundColor(this.accentTint).borderRadius({ topLeft: 17, topRight: 6, bottomLeft: 17, bottomRight: 17 })
                }.width('100%').justifyContent(FlexAlign.End).padding({ top: 10, bottom: 4 })
              }, (message: QueuedSteering) => message.id)
          }.width('100%').padding({ left: 16, right: 16, top: this.topPadding, bottom: 8 })
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              this.positionTranscript(transcriptId, Number(newArea.height));
            })
        }.width('100%').height('100%').align(Alignment.TopStart)
          .scrollBar(BarState.Off)
          .onTouch((event: TouchEvent) => {
            // 点击手势会被带 copyOption 的消息文本夺走，改用触摸广播：手指一按下就收键盘。
            if (event.type === TouchType.Down && this.keyboardHeight > 0) this.dismissKeyboard();
          })
          .onWillScroll((_xOffset: number, yOffset: number, _state: ScrollState, source: ScrollSource) => {
            if (yOffset < -2 && source !== ScrollSource.SCROLLER && source !== ScrollSource.SCROLLER_ANIMATION) {
              this.transcriptFollow = false;
            }
          })
          .onScrollEdge((side: Edge) => {
            if (side === Edge.Bottom) this.transcriptFollow = true;
          })
          .onAreaChange((oldArea: Area, newArea: Area) => {
            this.setTranscriptViewport(Number(newArea.height));
            if (this.transcriptFollow && (oldArea.width !== newArea.width || oldArea.height !== newArea.height)) {
              // Wait for the transcript to finish wrapping at the new width before scrolling.
              setTimeout(() => {
                if (this.currentId === transcriptId && this.transcriptFollow) {
                  this.transcript.scrollTo({ xOffset: 0, yOffset: this.readTranscriptHeight(), animation: false });
                }
              }, 0);
            }
          })
      }, (transcriptId: string) => transcriptId)
      if (!this.transcriptFollow) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_down'), $r('app.color.pigo_text'), 19)
        }.id('scroll-bottom').headerAction().attributeModifier(glassButtonSurface(this.darkMode)).margin({ right: 16, bottom: 14 })
          .accessibilityText('滚动到最新消息')
          .onClick(() => { this.transcriptFollow = true; this.transcript.scrollEdge(Edge.Bottom); })
      }
    }.layoutWeight(1).width('100%')
  }
  @Builder
  thinkingCard(id: string, content: string, ms: number, open: boolean) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('✻').fontSize(13).fontColor($r('app.color.pigo_info'))
        Text(id ? (ms >= 0 ? `思考 · ${(ms / 1000).toFixed(1)}s` : '思考') : '思考中…')
          .fontSize(13).fontColor($r('app.color.pigo_info')).layoutWeight(1)
        SymbolGlyph(open ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(14).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').onClick(() => {
        if (id) this.toggleThinking(id, !open);
        else this.liveThinkingOpen = !open;
      })
      if (open) {
        Scroll() {
          Text(content).fontSize(13).fontStyle(FontStyle.Italic).fontColor($r('app.color.pigo_muted')).lineHeight(21)
            .copyOption(CopyOptions.LocalDevice).width('100%')
        }.constraintSize({ maxHeight: 320 }).width('100%').scrollBar(BarState.Off)
      } else if (!id) {
        Text(content.split('\n').pop() ?? '').fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
    }.width('100%').padding(12).backgroundColor($r('app.color.pigo_control')).borderRadius(12)
  }
  @Builder
  fileChip(path: string, lookupName: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.doc')).fontSize(14).fontColor([this.accent])
        Text(path.split('/').pop() ?? path).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pigo_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 196 })
        if (this.openingFile) {
          LoadingProgress().width(12).height(12).color($r('app.color.pigo_muted'))
        }
      }
    }.id(`file-chip-${path}`).backgroundColor($r('app.color.pigo_panel'))
      .border({ width: 1, radius: 10, color: $r('app.color.pigo_line') })
      .padding({ left: 10, right: 10, top: 7, bottom: 7 }).enabled(!this.openingFile)
      .onClick(() => { void this.openReferencedFile(this.workspaceCwd, path, lookupName); })
  }
  @Builder
  toolRow(tool: LiveTool, messageId: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        SymbolGlyph(this.toolIcon(tool)).fontSize(17).fontColor([this.accent])
        Text(this.toolTitle(tool)).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '38%' })
        Text(tool.detail).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (tool.state === 'run' && !this.idle) {
          LoadingProgress().width(13).height(13).color(this.accent)
        } else if (tool.state === 'fail') {
          Text('失败').fontSize(12).fontColor($r('app.color.pigo_error'))
        }
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([$r('app.color.pigo_muted')])
      }.width('100%')
    }.width('100%').height(44).padding({ left: 10, right: 8 }).borderRadius(8).backgroundColor(Color.Transparent)
      .onClick(() => { this.openToolDetails(tool, messageId); })
  }
  @Builder
  toolGroup(tools: LiveTool[], messageId: string) {
    if (tools.length) {
      Column() {
        ForEach(tools, (tool: LiveTool, index: number) => {
          if (index > 0) Divider().color($r('app.color.pigo_line')).margin({ left: 36, right: 8 })
          this.toolRow(tool, messageId)
        }, (tool: LiveTool) => this.toolKey(tool))
      }.width('100%').padding({ left: 2, right: 2 })
        .backgroundColor($r('app.color.pigo_panel')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.pigo_line') })
    }
  }
  @Builder
  copyButton(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(17).fontColor([$r('app.color.pigo_muted')])
    }.width(36).height(36).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
      .accessibilityText(label).onClick(() => { void this.copyText(value); })
  }
  @Builder
  richChatText(text: string, cwd: string, documentPath: string = '', allowLandscape: boolean = true) {
    ChatContent({ text: text, accent: this.accent, allowLandscape: allowLandscape,
      loadImage: (target: string): Promise<string> => this.loadMarkdownImage(target, cwd, documentPath),
      openImage: (source: string, label: string): void => { this.showChatImage(source, label); },
      openLink: (target: string): void => {
        if (!allowLandscape && markdownWorkspacePath(target, cwd, documentPath)) this.closeMarkdownTableReader();
        void this.openMarkdownLink(target, cwd, documentPath);
      },
      openLandscape: (source: string): void => { this.openMarkdownTableReader(source, cwd, documentPath); },
      copyCode: (value: string): void => { void this.copyText(value); }
    })
  }
  @Builder
  historyImages(count: number, sessionId: string, messageId: string, toolId: string = '') {
    ForEach(Array.from({ length: count }, (_: Object, index: number): number => index), (index: number) => {
      ChatImage({
        label: count === 1 ? '图片' : `图片 ${index + 1}`,
        load: (): Promise<string> => this.loadHistoryImage(sessionId, messageId, index, toolId),
        open: (source: string, label: string): void => { this.showChatImage(source, label); }
      })
    }, (index: number): string => `${sessionId}-${messageId}-${toolId}-${index}`)
  }
  private messageFiles(message: ChatMessage): string[] {
    if (message.role !== 'user') return messageFileChips(message.text, this.workspaceCwd);
    const start = message.text.lastIndexOf('\n\n[Pi Go 附件] 手机上传了 ');
    if (start < 0) return [];
    const prefix = `：${this.workspaceCwd.replace(/\/$/, '')}/.pi-go/attachments/`;
    const paths: string[] = [];
    for (const line of message.text.slice(start).split('\n')) {
      const index = line.indexOf(prefix);
      if (index < 0) continue;
      const path = normalizeWorkspacePath(this.workspaceCwd, line.slice(index + 1));
      if (/^\.pi-go\/attachments\/[a-f0-9]{16}-[^/]+$/.test(path) && !paths.includes(path)) paths.push(path);
    }
    return paths;
  }
  private toolTitle(tool: LiveTool): string {
    switch (tool.name) {
      case 'bash': return '执行命令';
      case 'read': return '读取文件';
      case 'write': return '写入文件';
      case 'edit': return '编辑文件';
      case 'grep':
      case 'find': return '搜索工作区';
      case 'ls': return '列出目录';
      case 'web_search': return '网页搜索';
      default: return tool.name;
    }
  }
  private toolIcon(tool: LiveTool): Resource {
    if (tool.name === 'bash') return $r('sys.symbol.code_square');
    if (tool.name === 'grep' || tool.name === 'find' || tool.name === 'web_search') return $r('sys.symbol.magnifyingglass');
    if (tool.name === 'write' || tool.name === 'edit') return $r('sys.symbol.square_and_pencil');
    return $r('sys.symbol.folder');
  }
  private toolKey(tool: LiveTool): string {
    return `${tool.id}-${tool.state}-${tool.ms ?? 0}`;
  }
  private transcriptMessageKey(message: ChatMessage): string {
    const thinking = message.thinking && this.thinkingOpenIds.includes(message.id) ? 'open' : '';
    const tools = message.tools?.map((tool: LiveTool): string => this.toolKey(tool)).join(',') ?? '';
    return `${message.id}:${thinking}:${tools}:${message.textTruncated ?? false}`;
  }
  private unlistedLiveTools(): LiveTool[] {
    if (!this.liveTools.length) return this.liveTools;
    const saved = new Set<string>();
    for (const message of this.messages) {
      for (const tool of message.tools ?? []) saved.add(tool.id);
    }
    return this.liveTools.filter((tool: LiveTool): boolean => !saved.has(tool.id));
  }
  private draftKey(id: string): string {
    return `${this.base}|${id}`;
  }
}
