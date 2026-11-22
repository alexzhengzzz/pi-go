import { unboundAction } from './ComponentAction';
import { glassButtonSurface } from '../Immersive';
import { ChatContent } from '../ChatContent';
import { ChatImage } from '../ChatImage';
import { markdownWorkspacePath, messageFileChips, normalizeWorkspacePath } from '../ChatPaths';
import { RunEvent, runStatus } from '../RunResults';
import { ChatMessage, LiveTool, QueuedSteering } from '../model/PiGoTypes';
import {
  buildTranscriptTurns,
  isReadOnlyTool,
  ProcessStep,
  ProcessSummary,
  RecentToolRef,
  toolActionTitle,
  TranscriptTurn
} from '../TranscriptTurns';
import { headerSymbol } from './HeaderSymbol';
import { ThemePalette, ThemeStyle, themePalette, themeStyle } from '../Appearance';

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
  @Prop @Watch('onSessionChanged') currentId: string;
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
  @Prop runResults: RunEvent[] = [];
  @Require openRunResult: (run: RunEvent) => void = unboundAction;
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
  @Prop themeId: string = 'mint';
  @Prop topPadding: number = 10;
  @Prop bottomPadding: number = 8;
  @Prop scrollBottomOffset: number = 14;
  @Require readTranscriptHeight: () => number = unboundAction;
  @Require setTranscriptViewport: (height: number) => void = unboundAction;

  @State private processOpenIds: string[] = [];

  private onSessionChanged(): void {
    this.processOpenIds = [];
  }

  private isProcessOpen(processId: string): boolean {
    if (!processId) return false;
    if (processId === 'live') return this.liveThinkingOpen;
    return this.processOpenIds.includes(processId);
  }

  private toggleProcess(processId: string): void {
    if (!processId) return;
    if (processId === 'live') {
      this.liveThinkingOpen = !this.liveThinkingOpen;
      return;
    }
    if (this.processOpenIds.includes(processId)) {
      this.processOpenIds = this.processOpenIds.filter((item: string): boolean => item !== processId);
    } else {
      this.processOpenIds = this.processOpenIds.concat([processId]);
    }
  }

  private currentTheme(): ThemeStyle {
    return themeStyle(this.themeId);
  }

  private currentPalette(): ThemePalette {
    return themePalette(this.themeId, this.darkMode);
  }

  private bubbleCorners(): BorderRadiuses {
    const r = this.currentTheme().bubbleRadius;
    return { topLeft: r, topRight: Math.max(4, Math.round(r * 0.35)), bottomLeft: r, bottomRight: r };
  }

  private displayTurns(): TranscriptTurn[] {
    return buildTranscriptTurns(this.messages, this.unlistedLiveTools(), this.liveThinking, this.liveText, this.idle);
  }

  private needsWaitingPulse(): boolean {
    if (this.idle || this.liveText || this.liveThinking || this.unlistedLiveTools().length) return false;
    if (!this.messages.length) return true;
    return this.messages[this.messages.length - 1].role === 'user';
  }

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
            ForEach(this.displayTurns(), (turn: TranscriptTurn) => {
              if (turn.kind === 'user' && turn.message) {
                this.userBubble(turn.message)
              } else {
                this.assistantTurn(turn)
              }
              ForEach(this.resultsForTurn(turn), (run: RunEvent) => {
                Button(`本轮结果 · ${runStatus(run.status)} · ${run.files?.length ?? 0} 个文件`).chatAction()
                  .id(`turn-result-${run.id}`).onClick(() => { this.openRunResult(run); })
              }, (run: RunEvent) => run.id)
            }, (turn: TranscriptTurn) => this.turnKey(turn))
            if (this.needsWaitingPulse()) {
              Row({ space: 8 }) {
                LoadingProgress().width(13).height(13).color(this.accent)
                Text('正在思考…').fontSize(13).fontColor($r('app.color.pigo_muted'))
              }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor(this.currentPalette().cardBg).borderRadius(this.currentTheme().codeRadius)
                .border({ width: 1, radius: this.currentTheme().codeRadius, color: this.currentPalette().cardBorder })
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
                    .backgroundColor(this.currentTheme().bubble === 'gradient' ? Color.Transparent : this.currentPalette().bubbleStart)
                    .linearGradient(this.currentTheme().bubble === 'gradient' ? {
                      angle: 135,
                      colors: [[this.currentPalette().bubbleStart, 0], [this.currentPalette().bubbleEnd, 1]]
                    } : undefined)
                    .borderRadius(this.bubbleCorners())
                    .border({
                      width: this.currentTheme().bubble === 'outline' ? 1.2 : 0.6,
                      radius: this.bubbleCorners(),
                      color: this.currentPalette().bubbleBorder
                    })
                }.width('100%').justifyContent(FlexAlign.End).padding({ top: 10, bottom: 4 })
              }, (message: QueuedSteering) => message.id)
          }.width('100%').padding({ left: 16, right: 16, top: this.topPadding, bottom: this.bottomPadding })
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
        }.id('scroll-bottom').headerAction().attributeModifier(glassButtonSurface(this.darkMode)).margin({ right: 16, bottom: this.scrollBottomOffset })
          .accessibilityText('滚动到最新消息')
          .onClick(() => { this.transcriptFollow = true; this.transcript.scrollEdge(Edge.Bottom); })
      }
    }.layoutWeight(1).width('100%')
  }

  @Builder
  userBubble(message: ChatMessage) {
    Row() {
      Column({ space: 8 }) {
        if (message.text) {
          Text(message.text).fontSize(16).lineHeight(26)
            .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.pigo_text'))
          if (this.messageFiles(message).length) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.messageFiles(message), (path: string) => {
                Column() {
                  this.fileChip(path, false)
                }.margin({ right: 8, bottom: 8 })
              }, (path: string) => path)
            }.width('100%')
          }
        }
        if (message.imageCount) {
          Column({ space: 6 }) {
            this.historyImages(message.imageCount, this.currentId, message.id)
          }.id(`image-message-${message.id}`).alignItems(HorizontalAlign.Start)
        }
      }.alignItems(HorizontalAlign.Start).padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .constraintSize({ maxWidth: '88%' })
        .backgroundColor(this.currentTheme().bubble === 'gradient' ? Color.Transparent : this.currentPalette().bubbleStart)
        .linearGradient(this.currentTheme().bubble === 'gradient' ? {
          angle: 135,
          colors: [[this.currentPalette().bubbleStart, 0], [this.currentPalette().bubbleEnd, 1]]
        } : undefined)
        .borderRadius(this.bubbleCorners())
        .border({
          width: this.currentTheme().bubble === 'outline' ? 1.2 : (this.themeId === 'sakura' ? 1 : 0.6),
          radius: this.bubbleCorners(),
          color: this.currentPalette().bubbleBorder
        })
        .shadow(this.themeId === 'sakura'
          ? { radius: 12, offsetY: 3, color: this.darkMode ? '#33FF7EB3' : '#2CE86A98' }
          : undefined)
    }.width('100%').justifyContent(FlexAlign.End).padding({ top: 14, bottom: 4 })
  }

  @Builder
  assistantTurn(turn: TranscriptTurn) {
    Column({ space: 8 }) {
      if (turn.summary) {
        this.processBlock(turn, turn.summary)
      }
      if (turn.message) {
        if (turn.message.text) {
          this.richChatText(turn.message.text, this.workspaceCwd)
          if (this.messageFiles(turn.message).length) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.messageFiles(turn.message), (path: string) => {
                Column() {
                  this.fileChip(path, true)
                }.margin({ right: 8, bottom: 8 })
              }, (path: string) => path)
            }.width('100%')
          }
          if (turn.message.textTruncated) {
            Button(this.loadingMessageText === turn.message.id ? '正在加载全文…' : '查看完整回复').chatAction()
              .enabled(this.reachable && !this.loadingMessageText)
              .onClick(() => { if (turn.message) void this.showFullReply(turn.message.id); })
          } else {
            this.copyButton('复制回复', turn.message.text)
          }
        }
        if (turn.message.imageCount) {
          Column({ space: 6 }) {
            this.historyImages(turn.message.imageCount, this.currentId, turn.message.id)
          }.id(`image-message-${turn.message.id}`).alignItems(HorizontalAlign.Start)
        }
      }
      if (turn.extraImageMessages.length) {
        ForEach(turn.extraImageMessages, (imageMessage: ChatMessage) => {
          if (imageMessage.imageCount) {
            Column({ space: 6 }) {
              this.historyImages(imageMessage.imageCount, this.currentId, imageMessage.id)
            }.id(`image-message-${imageMessage.id}`).alignItems(HorizontalAlign.Start)
          }
        }, (imageMessage: ChatMessage) => `${imageMessage.id}:${imageMessage.imageCount ?? 0}`)
      }
      if (turn.liveText) {
        Column({ space: 8 }) {
          this.richChatText(turn.liveText, this.workspaceCwd)
          if (messageFileChips(turn.liveText, this.workspaceCwd).length) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(messageFileChips(turn.liveText, this.workspaceCwd), (path: string) => {
                Column() {
                  this.fileChip(path, true)
                }.margin({ right: 8, bottom: 8 })
              }, (path: string) => path)
            }.width('100%')
          }
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 4, bottom: 12 })
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 6, bottom: 4 })
  }

  @Builder
  processBlock(turn: TranscriptTurn, summary: ProcessSummary) {
    if (turn.isLive && !this.idle && !turn.liveText && !this.isProcessOpen(turn.processId)) {
      this.livePulseCard(turn, summary)
    } else {
      Column({ space: 6 }) {
        this.processCapsule(turn, summary, this.isProcessOpen(turn.processId))
        if (this.isProcessOpen(turn.processId)) {
          this.processTimeline(turn)
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  livePulseCard(turn: TranscriptTurn, summary: ProcessSummary) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        LoadingProgress().width(13).height(13).color(this.accent)
        Text(summary.liveTitle)
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').onClick(() => { this.toggleProcess(turn.processId); })

      if (summary.toolCount > summary.recentTools.length) {
        Text(`已完成前 ${summary.toolCount - summary.recentTools.length} 项操作，点击展开全部`)
          .fontSize(11).fontColor($r('app.color.pigo_muted')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          .onClick(() => { this.toggleProcess(turn.processId); })
      }

      if (summary.recentTools.length) {
        Column({ space: 2 }) {
          ForEach(summary.recentTools, (item: RecentToolRef) => {
            this.compactToolRow(item.tool, item.messageId, item.tool.state !== 'run' && item.tool.state !== 'fail')
          }, (item: RecentToolRef) => `${item.messageId}:${this.toolKey(item.tool)}`)
        }.width('100%')
      }

      if (summary.latestThinking) {
        Text(summary.latestThinking)
          .fontSize(12).fontStyle(FontStyle.Italic).fontColor($r('app.color.pigo_muted'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          .onClick(() => { this.toggleProcess(turn.processId); })
      }
    }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(this.currentPalette().cardBg).borderRadius(this.currentTheme().codeRadius)
      .border({ width: 1, radius: this.currentTheme().codeRadius, color: this.currentPalette().cardBorder })
  }

  @Builder
  processCapsule(turn: TranscriptTurn, summary: ProcessSummary, open: boolean) {
    Row({ space: 6 }) {
      if (turn.isLive && !this.idle) {
        LoadingProgress().width(12).height(12).color(this.accent)
      } else {
        Text('✻').fontSize(12).fontColor(summary.hasFailure ? $r('app.color.pigo_error') : $r('app.color.pigo_info'))
      }
      Text(summary.label)
        .fontSize(12.5)
        .fontColor(summary.hasFailure ? $r('app.color.pigo_error') : $r('app.color.pigo_muted'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      SymbolGlyph(open ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
        .fontSize(13).fontColor([$r('app.color.pigo_muted')])
    }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor(summary.hasFailure ? $r('app.color.pigo_error_panel') : $r('app.color.pigo_control'))
      .borderRadius(10)
      .onClick(() => { this.toggleProcess(turn.processId); })
  }

  @Builder
  processTimeline(turn: TranscriptTurn) {
    Column() {
      Column({ space: 6 }) {
        ForEach(turn.steps, (step: ProcessStep) => {
          if (step.kind === 'thinking') {
            this.timelineThinkingStep(step, this.thinkingOpenIds.includes(step.id))
          } else if (step.kind === 'note') {
            Text(step.text)
              .fontSize(13).lineHeight(20).fontColor($r('app.color.pigo_muted'))
              .copyOption(CopyOptions.LocalDevice).width('100%').padding({ left: 4, right: 4, top: 2, bottom: 2 })
          } else if (step.kind === 'tool' && step.tool) {
            this.compactToolRow(step.tool, step.messageId, false)
          }
        }, (step: ProcessStep) => this.stepKey(step))
        if (turn.steps.length >= 4) {
          Row({ space: 4 }) {
            Text('收起过程').fontSize(12).fontColor($r('app.color.pigo_muted'))
            SymbolGlyph($r('sys.symbol.chevron_up')).fontSize(12).fontColor([$r('app.color.pigo_muted')])
          }.padding({ left: 4, top: 4, bottom: 2 })
            .onClick(() => { this.toggleProcess(turn.processId); })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 10, top: 2, bottom: 4 })
        .border({ width: { left: 2 }, color: $r('app.color.pigo_line') })
    }.width('100%').padding({ left: 6 })
  }

  @Builder
  timelineThinkingStep(step: ProcessStep, open: boolean) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(step.live ? '思考中…' : (step.ms >= 0 ? `思考 · ${(step.ms / 1000).toFixed(1)}s` : '思考'))
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_info')).layoutWeight(1)
        Text(open ? '收起' : '全文').fontSize(11).fontColor($r('app.color.pigo_muted'))
      }.width('100%').onClick(() => { this.toggleThinking(step.id, !open); })
      if (open) {
        Scroll() {
          Text(step.text).fontSize(12.5).fontStyle(FontStyle.Italic).fontColor($r('app.color.pigo_muted')).lineHeight(20)
            .copyOption(CopyOptions.LocalDevice).width('100%')
        }.constraintSize({ maxHeight: 280 }).width('100%').scrollBar(BarState.Off)
      } else {
        Text(step.text)
          .fontSize(12.5).fontStyle(FontStyle.Italic).fontColor($r('app.color.pigo_muted')).lineHeight(19)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          .onClick(() => { this.toggleThinking(step.id, true); })
      }
    }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.pigo_control')).borderRadius(10)
  }

  @Builder
  compactToolRow(tool: LiveTool, messageId: string, dimmed: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        SymbolGlyph(this.toolIcon(tool)).fontSize(15)
          .fontColor([tool.state === 'fail' ? $r('app.color.pigo_error') :
            (isReadOnlyTool(tool.name) ? $r('app.color.pigo_muted') : this.accent)])
        Text(toolActionTitle(tool.name)).fontSize(12.5)
          .fontWeight(isReadOnlyTool(tool.name) ? FontWeight.Regular : FontWeight.Medium)
          .fontColor(tool.state === 'fail' ? $r('app.color.pigo_error') :
            (isReadOnlyTool(tool.name) ? $r('app.color.pigo_muted') : $r('app.color.pigo_text')))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '36%' })
        Text(tool.detail).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (tool.state === 'run' && !this.idle) {
          LoadingProgress().width(12).height(12).color(this.accent)
        } else if (tool.state === 'fail') {
          Text('失败').fontSize(11.5).fontColor($r('app.color.pigo_error'))
        } else if (tool.ms && tool.ms >= 100) {
          Text(`${(tool.ms / 1000).toFixed(1)}s`).fontSize(11).fontColor($r('app.color.pigo_muted'))
        }
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.pigo_muted')])
      }.width('100%')
    }.width('100%').height(34).padding({ left: 8, right: 6 }).borderRadius(8)
      .backgroundColor($r('app.color.pigo_panel'))
      .border({ width: 0.5, color: $r('app.color.pigo_line') })
      .opacity(dimmed ? 0.68 : 1)
      .onClick(() => { this.openToolDetails(tool, messageId); })
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
  copyButton(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(17).fontColor([$r('app.color.pigo_muted')])
    }.width(36).height(36).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
      .accessibilityText(label).onClick(() => { void this.copyText(value); })
  }

  @Builder
  richChatText(text: string, cwd: string, documentPath: string = '', allowLandscape: boolean = true) {
    ChatContent({
      text: text,
      accent: this.accent,
      codeBg: this.currentPalette().codeBg,
      codeBorder: this.currentPalette().codeBorder,
      codeHeaderBg: this.currentPalette().codeHeaderBg,
      codeRadius: this.currentTheme().codeRadius,
      allowLandscape: allowLandscape,
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

  private toolIcon(tool: LiveTool): Resource {
    if (tool.name === 'bash') return $r('sys.symbol.code_square');
    if (tool.name === 'grep' || tool.name === 'find' || tool.name === 'web_search') return $r('sys.symbol.magnifyingglass');
    if (tool.name === 'write' || tool.name === 'edit') return $r('sys.symbol.square_and_pencil');
    return $r('sys.symbol.folder');
  }

  private toolKey(tool: LiveTool): string {
    return `${tool.id}-${tool.state}-${tool.ms ?? 0}`;
  }

  private stepKey(step: ProcessStep): string {
    if (step.kind === 'tool' && step.tool) return `${step.id}:${this.toolKey(step.tool)}`;
    if (step.kind === 'thinking') {
      const open = this.thinkingOpenIds.includes(step.id) ? '1' : '0';
      return `${step.id}:${open}:${step.text.length}:${step.ms}`;
    }
    return `${step.id}:${step.text.length}`;
  }

  private resultsForTurn(turn: TranscriptTurn): RunEvent[] {
    return this.runResults.filter((run: RunEvent): boolean => !!run.messageId &&
      (run.messageId === turn.message?.id ||
        turn.steps.some((step: ProcessStep): boolean => step.messageId === run.messageId) ||
        turn.extraImageMessages.some((message: ChatMessage): boolean => message.id === run.messageId)));
  }

  private turnKey(turn: TranscriptTurn): string {
    const results = this.resultsForTurn(turn).map((run: RunEvent): string => run.id).join(',');
    if (turn.kind === 'user' && turn.message) {
      return `u:${turn.message.id}:${turn.message.text.length}:${turn.message.imageCount ?? 0}:${results}`;
    }
    const open = this.isProcessOpen(turn.processId) ? '1' : '0';
    const stepSig = turn.steps.map((step: ProcessStep): string => this.stepKey(step)).join('|');
    const finalSig = turn.message
      ? `${turn.message.id}:${turn.message.text.length}:${turn.message.textTruncated ?? false}:${turn.message.imageCount ?? 0}`
      : '';
    return `a:${turn.id}:${open}:${this.idle ? 1 : 0}:${turn.liveText.length}:${finalSig}:${stepSig}:${results}`;
  }

  private unlistedLiveTools(): LiveTool[] {
    if (!this.liveTools.length) return this.liveTools;
    const saved = new Set<string>();
    for (const message of this.messages) {
      for (const tool of message.tools ?? []) saved.add(tool.id);
    }
    return this.liveTools.filter((tool: LiveTool): boolean => !saved.has(tool.id));
  }

  private draftKey(sessionId: string): string {
    return `${this.base}::${sessionId}`;
  }
}
