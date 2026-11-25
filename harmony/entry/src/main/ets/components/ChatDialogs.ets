import { glassCardSurface } from '../Immersive';
import { IncomingShare } from '../IncomingShare';
import { toolActionTitle } from '../TranscriptTurns';
import { AgentInfo, LiveTool, PendingInteraction, ToolDetails, WorkspaceRow } from '../model/PiGoTypes';
import { workspaceName } from '../model/SessionStore';
import { unboundAction } from './ComponentAction';
import { modalCardTransition, modalFadeTransition } from './PageTransitions';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@ComponentV2
export struct NewSessionDialog {
  @Param @Require openingSession: boolean;
  @Param @Require busy: boolean;
  @Param @Require reachable: boolean;
  @Param @Require newSessionFixedWorkspace: boolean;
  @Param @Require projects: string[];
  @Param @Require workspaces: WorkspaceRow[];
  @Param @Require newSessionCwd: string;
  @Param @Require canCreateWorkspace: boolean;
  @Param @Require sessionLoading: boolean;
  @Param @Require agents: AgentInfo[];
  @Param @Require newSessionAgent: string;
  @Param @Require newSessionError: string;
  @Param @Require sessionCatalogFailed: boolean;
  @Param @Require hostAvailable: boolean;
  @Param @Require windowHeight: number;
  @Param @Require darkMode: boolean;
  @Param @Require accent: string;
  @Param @Require accentForeground: string;
  @Param @Require accentTint: string;
  @Param @Require canCreateSession: boolean;
  @Event closeNewSession: () => void = unboundAction;
  @Event selectWorkspace: (cwd: string) => void = unboundAction;
  @Event openSpace: () => void = unboundAction;
  @Event refreshAgents: () => Promise<void> = unboundAction;
  @Event selectAgent: (agent: string) => void = unboundAction;
  @Event createSession: () => Promise<void> = unboundAction;

  private labelWorkspace(path: string): string {
    return workspaceName(this.workspaces, path);
  }

  build() {
    Stack() {
      Button({ type: ButtonType.Normal }).width('100%').height('100%').borderRadius(0).backgroundColor('#66000000')
        .accessibilityText('取消新建会话').enabled(!this.openingSession).onClick(() => { this.closeNewSession(); })
      Scroll() {
        Column({ space: 12 }) {
          Text('新建会话').fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          Row({ space: 8 }) {
            Text('工作区').fontSize(14).fontColor($r('app.color.pigo_muted'))
            if (!this.newSessionFixedWorkspace && this.projects.length > 0) {
              Select(this.projects.map((path: string): SelectOption => ({ value: this.labelWorkspace(path) })))
                .id('new-session-workspace').layoutWeight(1).selected(this.projects.indexOf(this.newSessionCwd))
                .value(this.newSessionCwd ? this.labelWorkspace(this.newSessionCwd) : '选择工作区')
                .fontColor($r('app.color.pigo_text')).backgroundColor($r('app.color.pigo_control'))
                .enabled(!this.busy && !this.openingSession)
                .onSelect((index: number) => {
                  this.selectWorkspace(this.projects[index] ?? '');
                })
            } else {
              Text(this.newSessionCwd ? this.labelWorkspace(this.newSessionCwd) : '暂无工作区')
                .fontSize(14).fontColor($r('app.color.pigo_text')).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (!this.newSessionFixedWorkspace && this.canCreateWorkspace) {
              Button('新空间').chatAction().height(36).padding({ left: 10, right: 10 })
                .enabled(this.reachable && !this.busy && !this.openingSession)
                .onClick(() => { this.openSpace() })
            }
          }.width('100%')
          Row({ space: 8 }) {
            Text('Agent').fontSize(14).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
            Button({ type: ButtonType.Normal }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16).fontColor([this.accent])
            }.id('new-session-refresh').width(44).height(32).padding(0).backgroundColor(Color.Transparent)
              .accessibilityText('刷新 Agent 列表')
              .enabled(this.reachable && !this.busy && !this.openingSession && !this.sessionLoading)
              .onClick(() => { void this.refreshAgents(); })
          }.width('100%')
          ForEach(this.agents, (agent: AgentInfo) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                Text(agent.label).fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.pigo_text')).layoutWeight(1)
                if (agent.installed !== true || agent.authed === false) {
                  Text(agent.installed === undefined ? '检测中' : agent.installed ? '请检查登录或配置' : '未安装')
                    .fontSize(12).fontColor($r('app.color.pigo_muted'))
                }
                if (this.newSessionAgent === agent.id) {
                  SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(18).fontColor([this.accent])
                    .accessibilityLevel('no')
                }
              }.width('100%').padding({ left: 12, right: 12 })
            }.id(`new-session-agent-${agent.id}`).width('100%').height(44).padding(0).borderRadius(12)
              .backgroundColor(this.newSessionAgent === agent.id ? this.accentTint : $r('app.color.pigo_control'))
              .accessibilitySelected(this.newSessionAgent === agent.id)
              .enabled(agent.installed === true && !this.busy && !this.openingSession)
              .onClick(() => { this.selectAgent(agent.id); })
          }, (agent: AgentInfo) => `${agent.id}:${agent.label}:${agent.installed}:${agent.authed}`)
          if (this.newSessionError || !this.reachable || this.sessionCatalogFailed || !this.hostAvailable ||
            (this.newSessionFixedWorkspace && !this.projects.includes(this.newSessionCwd))) {
            Text(this.newSessionError || (!this.reachable ? '正在等待电脑连接…' :
              this.sessionCatalogFailed ? '加载失败，请刷新 Agent 列表。' :
              this.sessionLoading ? '正在加载电脑端配置…' : !this.hostAvailable ? '请在电脑上启动 Pi Go 后台服务。' :
              '该工作区已不可用。'))
              .fontSize(13).fontColor($r('app.color.pigo_error')).width('100%')
          }
          Row({ space: 8 }) {
            Button('取消').chatAction().layoutWeight(1)
              .enabled(!this.openingSession).onClick(() => { this.closeNewSession(); })
            Button(this.openingSession ? '正在创建…' : '创建会话').id('new-session-submit').layoutWeight(2)
              .backgroundColor(this.accent).fontColor(this.accentForeground)
              .enabled(this.canCreateSession).onClick(() => { void this.createSession(); })
          }.width('100%')
        }.width('100%').padding(18)
      }.width('90%').constraintSize({ maxWidth: 380, maxHeight: this.windowHeight * 0.85 })
        .scrollBar(BarState.Auto).attributeModifier(glassCardSurface(this.darkMode, 20, true))
        .transition(modalCardTransition())
    }.id('new-session-dialog').width('100%').height('100%')
      .transition(modalFadeTransition())
  }
}

@ComponentV2
export struct NewSpaceDialog {
  @Param @Require busy: boolean;
  @Param @Require reachable: boolean;
  @Param @Require newSpaceName: string;
  @Param @Require newSpaceError: string;
  @Param @Require darkMode: boolean;
  @Param @Require accent: string;
  @Param @Require accentForeground: string;
  @Event closeNewSpace: () => void = unboundAction;
  @Event changeName: (value: string) => void = unboundAction;
  @Event createWorkspaceTask: () => Promise<void> = unboundAction;

  build() {
    Stack() {
      Button({ type: ButtonType.Normal }).width('100%').height('100%').borderRadius(0).backgroundColor('#66000000')
        .accessibilityText('取消新建空间').enabled(!this.busy).onClick(() => { this.closeNewSpace(); })
      Column({ space: 12 }) {
        Text('新空间').fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        TextInput({ text: this.newSpaceName, placeholder: '空间名称' }).id('new-space-name').width('100%')
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .maxLength(80).enterKeyType(EnterKeyType.Done).enabled(!this.busy)
          .onChange((value: string) => { this.changeName(value); })
          .onSubmit(() => { if (this.newSpaceName.trim()) void this.createWorkspaceTask(); })
        if (this.newSpaceError) {
          Text(this.newSpaceError).fontSize(13).fontColor($r('app.color.pigo_error')).width('100%')
        }
        Row({ space: 8 }) {
          Button('取消').layoutWeight(1).backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
            .enabled(!this.busy).onClick(() => { this.closeNewSpace(); })
          Button(this.busy ? '正在创建…' : '创建空间').id('new-space-submit').layoutWeight(2)
            .backgroundColor(this.accent).fontColor(this.accentForeground)
            .enabled(!this.busy && this.reachable && !!this.newSpaceName.trim())
            .onClick(() => { void this.createWorkspaceTask(); })
        }.width('100%')
      }.width('90%').constraintSize({ maxWidth: 360 }).padding(18)
        .attributeModifier(glassCardSurface(this.darkMode, 20, true))
        .transition(modalCardTransition())
    }.id('new-space-dialog').width('100%').height('100%')
      .transition(modalFadeTransition())
  }
}

@ComponentV2
export struct PendingInteractionCard {
  @Param @Require request: PendingInteraction;
  @Param @Require interactionDraft: string;
  @Param @Require reachable: boolean;
  @Param @Require busy: boolean;
  @Param @Require openingSession: boolean;
  @Param @Require accent: string;
  @Param @Require accentForeground: string;
  @Event answerInteraction: (id: string, answer: string | boolean) => Promise<void> = unboundAction;
  @Event changeDraft: (id: string, value: string) => void = unboundAction;

  build() {
    Scroll() {
      Column({ space: 8 }) {
        Text(this.request.title || 'Pi 等待应答').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.pigo_warning')).width('100%')
        if (this.request.message) Text(this.request.message).fontSize(14).fontColor($r('app.color.pigo_text')).width('100%')
        if (this.request.method === 'confirm') {
          Row({ space: 10 }) {
            Button('拒绝').chatAction().id('interaction-deny').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(this.request.id, false); })
            Button('确认').chatAction().id('interaction-confirm').enabled(this.reachable && !this.busy && !this.openingSession)
              .backgroundColor(this.accent).fontColor(this.accentForeground)
              .onClick(() => { void this.answerInteraction(this.request.id, true); })
          }.width('100%')
        } else if (this.request.method === 'input' || this.request.method === 'editor') {
          if (this.request.method === 'editor') {
            TextArea({ text: this.interactionDraft, placeholder: '编辑内容' }).id('interaction-editor').height(92).maxLength(1024)
              .backgroundColor($r('app.color.pigo_panel')).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted'))
              .onChange((value: string) => { this.changeDraft(this.request.id, value); })
          } else {
            TextInput({ text: this.interactionDraft, placeholder: this.request.placeholder ?? '输入答复' }).id('interaction-input').maxLength(1024)
              .backgroundColor($r('app.color.pigo_panel')).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted'))
              .onChange((value: string) => { this.changeDraft(this.request.id, value); })
          }
          Row({ space: 10 }) {
            Button('取消').chatAction().id('interaction-cancel').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(this.request.id, false); })
            Button('提交').chatAction().id('interaction-submit').enabled(this.reachable && !this.busy && !this.openingSession)
              .backgroundColor(this.accent).fontColor(this.accentForeground)
              .onClick(() => { void this.answerInteraction(this.request.id, this.interactionDraft); })
          }.width('100%')
        } else {
          ForEach(this.request.options ?? [], (option: string, index: number) => {
            Button(option).chatAction().id(`interaction-option-${index}`).width('100%').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(this.request.id, option); })
          }, (option: string, index: number) => `${index}-${option}`)
          Button('取消').chatAction().id('interaction-cancel').enabled(this.reachable && !this.busy && !this.openingSession)
            .onClick(() => { void this.answerInteraction(this.request.id, false); })
        }
      }.padding(12).width('100%').backgroundColor($r('app.color.pigo_warning_panel')).borderRadius(14)
    }.constraintSize({ maxHeight: 240 }).width('100%').scrollBar(BarState.Off)
  }
}

@ComponentV2
export struct IncomingShareBanner {
  @Param @Require incomingShare: IncomingShare;
  @Param @Require shareError: string;
  @Param @Require isPaired: boolean;
  @Param @Require canAddShareToCurrent: boolean;
  @Param @Require sessionName: string;
  @Param @Require project: string;
  @Param @Require shareTargetLocked: boolean;
  @Param @Require busy: boolean;
  @Param @Require openingSession: boolean;
  @Param @Require hasPendingSend: boolean;
  @Param @Require accent: string;
  @Param @Require accentForeground: string;
  @Event clearIncomingShare: () => void = unboundAction;
  @Event chooseShareComputer: () => void = unboundAction;
  @Event chooseShareSession: () => void = unboundAction;
  @Event addShareToDraft: () => void = unboundAction;

  build() {
    Column({ space: 6 }) {
      Row() {
        Text(this.incomingShare.text || this.incomingShare.attachments.length ? '分享至 Pi Go' : '无法读取分享内容')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
        Button('关闭').chatAction().height(32).onClick((): void => { this.clearIncomingShare(); })
      }.width('100%')
      if (this.incomingShare.text) {
        Text(this.incomingShare.text).fontSize(13).fontColor($r('app.color.pigo_text')).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      if (this.incomingShare.attachments.length) {
        Text(`${this.incomingShare.attachments.length} 个附件`).fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
      }
      if (this.shareError || (this.incomingShare.skipped && (this.incomingShare.text || this.incomingShare.attachments.length))) {
        Text(this.shareError || '部分内容无法读取或超出限制。')
          .fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
      }
      if (this.incomingShare.text || this.incomingShare.attachments.length) {
        if (!this.isPaired) {
          Text('配对电脑并打开会话后，可加入草稿。')
            .fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
        } else if (this.canAddShareToCurrent) {
          Text(`当前会话 · ${this.sessionName || this.project || '未命名会话'}`)
            .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }
      if ((this.incomingShare.text || this.incomingShare.attachments.length) && this.isPaired) {
        Row({ space: 8 }) {
          Button('选电脑').chatAction().height(36).enabled(!this.shareTargetLocked).onClick((): void => {
            this.chooseShareComputer();
          })
          Button('选会话').chatAction().height(36).enabled(!this.shareTargetLocked)
            .onClick((): void => { this.chooseShareSession(); })
          if (this.canAddShareToCurrent) {
            Button('加入当前草稿').chatAction().height(36).backgroundColor(this.accent).fontColor(this.accentForeground)
              .enabled(!this.busy && !this.openingSession && !this.hasPendingSend)
              .onClick((): void => { this.addShareToDraft(); })
          }
        }.width('100%')
      }
    }.id('incoming-share').width('93%').constraintSize({ maxWidth: 420 }).padding(14).borderRadius(18)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
  }
}

@ComponentV2
export struct ToolDetailsSheet {
  @Param @Require selectedTool: LiveTool | undefined;
  @Param @Require selectedToolDetails: ToolDetails | undefined;
  @Param @Require idle: boolean;
  @Param @Require toolDetailError: string;
  @Param @Require accent: string;
  @Param @Require icon: Resource;
  @Param @Require path: string;
  @Param @Require openingFile: boolean;
  @Event openFile: (path: string) => Promise<void> = unboundAction;
  @Event copyText: (value: string) => Promise<void> = unboundAction;
  @Event loadToolDetails: () => Promise<void> = unboundAction;
  @BuilderParam images: () => void;

  @Builder
  fileChip(path: string) {
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
      .onClick(() => { void this.openFile(path); })
  }

  @Builder
  copyButton(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(17).fontColor([$r('app.color.pigo_muted')])
    }.width(36).height(36).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
      .accessibilityText(label).onClick(() => { void this.copyText(value); })
  }

  @Builder
  toolDetailBlock(label: string, value: string) {
    Column({ space: 4 }) {
      Row() {
        Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.accent).layoutWeight(1)
        if (value) this.copyButton(`复制${label}`, value)
      }.width('100%')
      if (value) {
        Text(value).width('100%').fontFamily('monospace').fontSize(14).lineHeight(22).fontColor($r('app.color.pigo_text'))
          .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
      .padding({ left: 12, right: 8, top: 4, bottom: 12 })
      .backgroundColor($r('app.color.launch_background')).borderRadius(12).border({ width: 1, color: $r('app.color.pigo_line') })
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.selectedTool) {
          Row({ space: 10 }) {
            SymbolGlyph(this.icon).fontSize(20).fontColor([this.accent])
            Text(toolActionTitle(this.selectedTool.name)).fontSize(21).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          }.width('100%').padding({ right: 40 })
          if (this.path) this.fileChip(this.path)
          if (this.selectedToolDetails) {
            if (this.selectedToolDetails.input) {
              this.toolDetailBlock(this.selectedToolDetails.command ? '命令' : '输入', this.selectedToolDetails.input)
            }
            if (this.selectedToolDetails.output) {
              this.toolDetailBlock(this.selectedToolDetails.state === 'fail' ? '错误输出' : '输出', this.selectedToolDetails.output)
            } else if (!this.selectedToolDetails.imageCount) {
              Text(this.selectedTool.state === 'run' && !this.idle ? '正在运行…' : '没有文本输出')
                .fontSize(14).fontColor($r('app.color.pigo_muted'))
            }
            if (this.selectedToolDetails.imageCount) {
              this.images()
            }
            if (this.selectedToolDetails.truncated) {
              Text('较长的输入或输出仅显示前 64K 字符').fontSize(12).fontColor($r('app.color.pigo_muted'))
            }
          } else if (this.selectedTool.detail) {
            this.toolDetailBlock('摘要', this.selectedTool.detail)
          }
          if (this.toolDetailError) {
            Text(this.toolDetailError).fontSize(14).fontColor($r('app.color.pigo_muted'))
            Button('重试').chatAction().onClick(() => { void this.loadToolDetails(); })
          } else if (!this.selectedToolDetails) {
            LoadingProgress().width(22).height(22).color($r('app.color.pigo_muted')).accessibilityText('正在加载工具详情')
          }
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 18, right: 18, top: 22, bottom: 24 })
    }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }
}
