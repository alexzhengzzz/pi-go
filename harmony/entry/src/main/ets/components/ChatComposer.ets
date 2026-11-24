import { glassComposerSurface, hasImmersiveMaterial, immersiveSheetMaterial } from '../Immersive';
import { unboundAction } from './ComponentAction';
import { skillCommands } from '../model/CommandState';
import { ModelOption, DraftAttachment, CommandRow, Payload } from '../model/PiGoTypes';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@ComponentV2
export struct ChatComposer {
  @Param @Require darkMode: boolean;
  @Param @Require acceptsImage: boolean;
  @Event applyModelFromMenu: (index: number) => Promise<void> = unboundAction;
  @Event applyThinkingLevelFromMenu: (level: string) => Promise<void> = unboundAction;
  @Event armTranscriptFollow: () => void = unboundAction;
  @Event attachFile: () => Promise<void> = unboundAction;
  @Event attachImage: (source: string) => Promise<void> = unboundAction;
  @Param @Require attachments: DraftAttachment[];
  @Param @Require busy: boolean;
  @Param @Require commandError: string;
  @Param @Require commandRows: CommandRow[];
  @Param @Require commandsLoading: boolean;
  @Param @Require currentId: string;
  @Param @Require currentLevel: string;
  @Param @Require currentModel?: ModelOption;
  @Event dismissKeyboard: () => void = unboundAction;
  @Param @Require draft: string;
  @Event $draft: (value: string) => void = unboundAction;
  @Param @Require holdCancel: boolean;
  @Event holdTouch: (event: TouchEvent) => void = unboundAction;
  @Param @Require idle: boolean;
  @Param @Require liveVoiceText: string;
  @Event $liveVoiceText: (value: string) => void = unboundAction;
  @Event loadCommands: () => Promise<void> = unboundAction;
  @Param @Require modelLabel: string;
  @Param @Require models: ModelOption[];
  @Event openComposerMenu: () => void = unboundAction;
  @Event openModelMenu: () => Promise<void> = unboundAction;
  @Event openSkillPicker: () => void = unboundAction;
  @Param @Require openingSession: boolean;
  @Param @Require hasPendingSend: boolean;
  @Event pickSkill: (row: CommandRow) => void = unboundAction;
  @Param @Require queued: boolean;
  @Param @Require reachable: boolean;
  @Param @Require recording: boolean;
  @Event removeAttachment: (index: number) => void = unboundAction;
  @Event requestAction: (path: string, input?: Payload) => Promise<boolean> = unboundAction;
  @Param @Require runId: string;
  @Event send: () => Promise<void> = unboundAction;
  @Param @Require showComposerMenu: boolean;
  @Event $showComposerMenu: (value: boolean) => void = unboundAction;
  @Param @Require showModelMenu: boolean;
  @Event $showModelMenu: (value: boolean) => void = unboundAction;
  @Param @Require showSkillPicker: boolean;
  @Event $showSkillPicker: (value: boolean) => void = unboundAction;
  @Param @Require status: string;
  @Event $status: (value: string) => void = unboundAction;
  @Event syncCommandPalette: () => void = unboundAction;
  @Param @Require voiceCancelling: boolean;
  @Param @Require voiceFinishing: boolean;
  @Param @Require voiceMode: boolean;
  @Event $voiceMode: (value: boolean) => void = unboundAction;
  @Param @Require voicePreparing: boolean;
  @Param @Require windowHeight: number;
  @Param @Require windowWidth: number;
  @Param @Require accent: string;
  @Param @Require accentForeground: string;
  @Param @Require accentTint: string;

  build() {
    Column({ space: 2 }) {
      if (this.attachments.length) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.attachments, (item: DraftAttachment, index: number) => {
              Stack({ alignContent: Alignment.TopEnd }) {
                if (item.kind === 'image' && item.image) {
                  Image(item.image.preview).id(`attachment-${index}`).width(64).height(64).borderRadius(10)
                    .objectFit(ImageFit.Cover)
                } else if (item.kind === 'file') {
                  Column({ space: 3 }) {
                    Text(item.file ? this.fileIcon(item.file.name) : '文件').fontSize(15).fontColor($r('app.color.pigo_muted'))
                    Text(item.name).fontSize(12).fontColor($r('app.color.pigo_text')).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 150 })
                    Text(this.fileSize(item.size)).fontSize(11).fontColor($r('app.color.pigo_muted'))
                  }.justifyContent(FlexAlign.Center).width('100%').height('100%')
                }
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.xmark')).fontSize(11).fontColor([$r('app.color.pigo_text')])
                }.id(`remove-attachment-${index}`).width(26).height(26).backgroundColor($r('app.color.pigo_selected'))
                  .accessibilityText(`移除附件 ${item.name}`)
                  .enabled(!this.busy && !this.hasPendingSend)
                  .onClick(() => { this.removeAttachment(index); })
              }.width(item.kind === 'image' ? 64 : 170).height(64)
                .borderRadius(item.kind === 'image' ? 10 : 12)
                .backgroundColor(item.kind === 'image' ? Color.Transparent : $r('app.color.pigo_control'))
                .padding(item.kind === 'file' ? 6 : 0)
            }, (item: DraftAttachment, index: number) => `${index}-${item.kind}-${item.name}-${item.size}`)
          }.padding({ bottom: 2 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start)
          .width('100%').height(70).padding({ left: 6, right: 6 })
      }
      if (this.voiceMode) {
        Button({ type: ButtonType.Normal }) {
          Text(this.voicePreparing ? '正在准备…' : this.voiceFinishing ? (this.voiceCancelling ? '按住说话' : '正在转文字…') : this.recording ? (this.holdCancel ? '松开取消' : '松开发送') : '按住说话')
            .fontSize(16).fontColor(this.holdCancel ? $r('app.color.pigo_error') : $r('app.color.pigo_text')).maxLines(1)
        }.id('hold-to-talk').width('100%').height(44).borderRadius(12)
          .backgroundColor(this.recording ? (this.holdCancel ? $r('app.color.pigo_error_panel') : $r('app.color.pigo_selected')) : $r('app.color.pigo_control'))
          .enabled(!!this.currentId && this.reachable && !this.hasPendingSend && !this.busy && !this.openingSession)
          .onTouch((event: TouchEvent) => { this.holdTouch(event); })
      } else {
        TextArea({ placeholder: !this.reachable ? '设备离线' : this.windowWidth < 360 ? '输入消息' : '输入消息，/ 唤起命令',
          text: this.draft })
          .id('draft').width('100%').constraintSize({ minHeight: 42, maxHeight: 108 }).onFocus(() => { this.armTranscriptFollow(); })
          .fontSize(16).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted')).backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6, top: 8, bottom: 8 })
          .enabled(!this.hasPendingSend).onChange((value: string) => { this.$draft(value); this.syncCommandPalette(); })
      }
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph(this.voiceMode ? $r('sys.symbol.keyboard') : $r('sys.symbol.mic')).fontSize(21)
            .fontColor([this.voiceMode ? this.accent : $r('app.color.pigo_muted')])
        }.id('voice-toggle').width(44).height(44).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
          .accessibilityText(this.voiceMode ? '切换到文字输入' : '切换到语音输入')
          .enabled(!!this.currentId && !this.hasPendingSend && !this.busy && !this.recording && !this.voicePreparing && !this.voiceFinishing)
          .onClick(() => { const voiceMode = !this.voiceMode;
            this.$voiceMode(voiceMode);
            this.$liveVoiceText('');
            this.$status('');
            if (voiceMode) this.dismissKeyboard(); })
        Button({ type: ButtonType.Normal }) {
          Row({ space: 5 }) {
            Text(this.modelLabel || '选择模型').fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.pigo_muted')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '85%' })
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.pigo_muted')])
          }
        }.id('model-pill').height(44).padding({ left: 6, right: 6 }).borderRadius(10)
          .constraintSize({ maxWidth: '48%' }).backgroundColor(Color.Transparent)
          .accessibilityText(this.modelLabel ? `切换模型，当前为${this.modelLabel}` : '切换模型')
          .enabled(this.reachable && !this.busy && !this.openingSession && !!this.currentId && this.idle && !this.queued)
          .onClick(() => { void this.openModelMenu(); })
          .bindSheet(this.showModelMenu!!, this.modelSheet(), {
            detents: ['60%', SheetSize.LARGE], preferType: SheetType.BOTTOM, dragBar: true, showClose: false,
            backgroundColor: hasImmersiveMaterial() ? undefined : $r('app.color.pigo_panel'),
            systemMaterial: immersiveSheetMaterial(),
            maskColor: '#52000000'
          })
        Blank()
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(21).fontColor([$r('app.color.pigo_muted')])
        }.id('attach-image').width(44).height(44).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
          .accessibilityText('添加附件或技能')
          .enabled(!!this.currentId && this.reachable && !this.busy && !this.openingSession && !this.hasPendingSend &&
            !this.recording && !this.voicePreparing && !this.voiceFinishing)
          .onClick(() => { this.openComposerMenu(); })
          .bindSheet(this.showComposerMenu!!, this.composerMenu(), {
            height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM, showClose: false,
            backgroundColor: hasImmersiveMaterial() ? undefined : $r('app.color.pigo_panel'),
            systemMaterial: immersiveSheetMaterial(),
            maskColor: '#52000000'
          })
        if (this.idle || this.hasDraft()) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(20)
              .fontColor([this.canSend() ? this.accentForeground : $r('app.color.pigo_muted')])
          }.id('send').width(44).height(44).padding(0).borderRadius(16)
            .backgroundColor(this.canSend() ? this.accent : $r('app.color.pigo_control'))
            .accessibilityText(this.idle ? '发送消息' : '发送消息以引导当前任务').enabled(this.canSend())
            .onClick(() => { void this.send(); })
        } else {
          Button({ type: ButtonType.Normal }) {
            Rect().width(12).height(12).fill(this.accentForeground).radius(2)
          }.id('abort').width(44).height(44).borderRadius(16).backgroundColor(this.accent)
            .accessibilityText('停止生成').enabled(this.reachable && !this.busy && !this.openingSession)
            .onClick(() => { void this.requestAction('/abort', { id: this.currentId }); })
        }
      }.width('100%')
    }.width('100%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .attributeModifier(glassComposerSurface(this.darkMode))
  }
  @Builder
  composerMenuAction(label: string, symbol: Resource, id: string, enabled: boolean, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 8 }) {
        SymbolGlyph(symbol).fontSize(26).fontColor([$r('app.color.pigo_text')])
        Text(label).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
      }.width('100%').justifyContent(FlexAlign.Center)
    }.id(id).layoutWeight(1).height(86).padding(0).borderRadius(14)
      .backgroundColor($r('app.color.pigo_control')).enabled(enabled).onClick(action)
  }
  @Builder
  skillPicker() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([$r('app.color.pigo_text')])
      }.width(44).height(44).borderRadius(12).padding(0).backgroundColor(Color.Transparent)
        .accessibilityText('返回添加菜单').onClick(() => { this.$showSkillPicker(false); })
      Text('技能').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
    }.width('100%')
    if (this.attachments.length) {
      Text('使用技能前请先移除附件。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
    }
    if (this.commandsLoading) {
      Text('正在加载技能…').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
    } else if (this.commandError) {
      Button(this.commandError).chatAction().width('100%')
        .onClick(() => { void this.loadCommands(); })
    } else if (!skillCommands(this.commandRows).length) {
      Text('当前会话没有可用技能。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
    } else {
      Scroll() {
        Column({ space: 6 }) {
          ForEach(skillCommands(this.commandRows), (row: CommandRow) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 4 }) {
                Text(row.name.replace(/^skill:/, '')).fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                if (row.description) {
                  Text(row.description).fontSize(13).fontColor($r('app.color.pigo_muted'))
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.id(`composer-skill-${row.name}`).width('100%').constraintSize({ minHeight: 48 })
              .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12)
              .backgroundColor($r('app.color.pigo_control'))
              .enabled(this.reachable && !this.openingSession && !this.hasPendingSend)
              .onClick(() => { this.pickSkill(row); })
          }, (row: CommandRow) => row.name)
        }.width('100%')
      }.width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
        .constraintSize({ maxHeight: Math.min(320, Math.max(72, this.windowHeight - 180)) })
    }
  }
  @Builder
  composerMenu() {
    Column({ space: 12 }) {
      if (this.showSkillPicker) {
        this.skillPicker()
      } else {
        Row({ space: 8 }) {
          this.composerMenuAction('拍照', $r('sys.symbol.camera'), 'composer-camera', this.acceptsImage, () => {
            this.$showComposerMenu(false);
            void this.attachImage('camera');
          })
          this.composerMenuAction('照片', $r('sys.symbol.picture'), 'composer-photos', this.acceptsImage, () => {
            this.$showComposerMenu(false);
            void this.attachImage('gallery');
          })
          this.composerMenuAction('添加文件', $r('sys.symbol.paperclip'), 'composer-files', true, () => {
            this.$showComposerMenu(false);
            void this.attachFile();
          })
        }.width('100%')
        if (!this.acceptsImage) {
          Text('当前模型不支持图片输入。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
        }
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(22).fontColor([$r('app.color.pigo_text')])
            Text('技能').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
          }.width('100%')
        }.id('composer-skills').width('100%').height(48).padding({ left: 10, right: 10 })
          .borderRadius(12).backgroundColor(Color.Transparent).onClick(() => { this.openSkillPicker(); })
      }
    }.id('composer-menu').width('100%').constraintSize({ maxWidth: 560 })
      .padding({ left: 16, right: 16, top: 14, bottom: 16 })
  }
  @Builder
  modelSheet() {
    Column({ space: 12 }) {
      Text('模型与思考').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).width('100%')
      if (!this.idle || this.queued) {
        Text('等待当前任务和队列结束后可切换模型。').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if ((this.currentModelOption()?.levels.length ?? 0) > 1) {
        Column({ space: 6 }) {
          Text('思考级别').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_muted')).width('100%')
          Row({ space: 4 }) {
            ForEach(this.currentModelOption()?.levels ?? [], (level: string) => {
              Button(this.thinkingLevelLabel(level), { type: ButtonType.Normal }).chatAction()
                .layoutWeight(1).height(36).padding(2).borderRadius(10).fontSize(13)
                .backgroundColor(this.currentLevel === level ? this.accent : Color.Transparent)
                .fontColor(this.currentLevel === level ? this.accentForeground : $r('app.color.pigo_muted'))
                .enabled(this.reachable && this.idle && !this.queued && !this.busy)
                .onClick(() => { this.$showModelMenu(false); void this.applyThinkingLevelFromMenu(level); })
            }, (level: string) => level)
          }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
        }.width('100%')
      }
      List({ initialIndex: this.currentModelIndex(), space: 8 }) {
        ForEach(this.models, (model: ModelOption, index: number) => {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text(model.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${model.provider}${model.image ? ' · 支持图片' : ''}`)
                    .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                if (this.isCurrentModel(model)) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.accent])
                }
              }.width('100%')
            }.id(`model-option-${index}`).width('100%').height(54).padding({ left: 14, right: 14 })
              .backgroundColor(this.isCurrentModel(model) ? this.accentTint : $r('app.color.pigo_control'))
              .border({ width: this.isCurrentModel(model) ? 1 : 0, radius: 12, color: this.accent })
              .accessibilitySelected(this.isCurrentModel(model))
              .enabled(this.reachable && this.idle && !this.queued && !this.busy)
              .onClick(() => { this.$showModelMenu(false); void this.applyModelFromMenu(index); })
          }
        }, (model: ModelOption) => `${model.provider}-${model.id}`)
        if (!this.models.length) {
          ListItem() {
            Text('没有可用模型，请在电脑上检查 Pi CLI 的模型配置。').fontSize(13)
              .fontColor($r('app.color.pigo_muted')).width('100%')
          }
        }
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%').constraintSize({ maxWidth: 560 })
      .padding({ left: 16, right: 16, top: 8, bottom: 20 })
  }
  private fileIcon(name: string): string {
    const lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'PDF';
    if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z')) return 'ZIP';
    if (lower.endsWith('.md')) return 'MD';
    if (lower.endsWith('.txt') || lower.endsWith('.log')) return 'TXT';
    if (lower.endsWith('.csv') || lower.endsWith('.xlsx') || lower.endsWith('.xls')) return 'CSV';
    if (lower.endsWith('.json')) return 'JSON';
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') || lower.endsWith('.webp') || lower.endsWith('.heic')) return 'IMG';
    return '文件';
  }
  private fileSize(size: number): string {
    if (size >= 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
    if (size >= 1024) return `${Math.round(size / 1024)} KB`;
    return `${size} B`;
  }
  private hasDraft(): boolean {
    return this.draft.trim().length > 0 || this.attachments.length > 0;
  }
  private canSend(): boolean {
    return !!this.currentId && (this.idle || !!this.runId) &&
      this.reachable && !this.busy && !this.openingSession && !this.hasPendingSend &&
      !this.recording && !this.voicePreparing && !this.voiceFinishing &&
      this.hasDraft() &&
      (this.acceptsImage || !this.attachments.some((item: DraftAttachment): boolean => item.kind === 'image'));
  }
  private currentModelIndex(): number {
    const idx = this.models.findIndex((item: ModelOption): boolean => this.isCurrentModel(item));
    return idx >= 0 ? idx : 0;
  }
  private currentModelOption(): ModelOption | undefined {
    return this.models.find((item: ModelOption): boolean => this.isCurrentModel(item)) ?? this.currentModel;
  }
  private isCurrentModel(model: ModelOption): boolean {
    return this.currentModel?.provider === model.provider && this.currentModel?.id === model.id;
  }
  private thinkingLevelLabel(level: string): string {
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
}
