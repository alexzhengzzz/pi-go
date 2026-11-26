import { PiGoPageStore } from '../model/PiGoPageStore';
import { glassComposerSurface, hasImmersiveMaterial, immersiveSheetMaterial } from '../Immersive';
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
  @Param @Require store: PiGoPageStore;

  build() {
    Column({ space: 2 }) {
      if (this.store.session.attachments.length) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.store.session.attachments, (item: DraftAttachment, index: number) => {
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
                  .enabled(!this.store.session.busy && !(this.store.session.pendingSend !== undefined))
                  .onClick(() => { this.store.shareController.removeAttachment(index); })
              }.width(item.kind === 'image' ? 64 : 170).height(64)
                .borderRadius(item.kind === 'image' ? 10 : 12)
                .backgroundColor(item.kind === 'image' ? Color.Transparent : $r('app.color.pigo_control'))
                .padding(item.kind === 'file' ? 6 : 0)
            }, (item: DraftAttachment, index: number) => `${index}-${item.kind}-${item.name}-${item.size}`)
          }.padding({ bottom: 2 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start)
          .width('100%').height(70).padding({ left: 6, right: 6 })
      }
      if (this.store.voiceComposer.state.voiceMode) {
        Button({ type: ButtonType.Normal }) {
          Text(this.store.voiceComposer.state.voicePreparing ? '正在准备…' : this.store.voiceComposer.state.voiceFinishing ? (this.store.voiceComposer.state.voiceCancelling ? '按住说话' : '正在转文字…') : this.store.voiceComposer.state.recording ? (this.store.voiceComposer.state.holdCancel ? '松开取消' : '松开发送') : '按住说话')
            .fontSize(16).fontColor(this.store.voiceComposer.state.holdCancel ? $r('app.color.pigo_error') : $r('app.color.pigo_text')).maxLines(1)
        }.id('hold-to-talk').width('100%').height(44).borderRadius(12)
          .backgroundColor(this.store.voiceComposer.state.recording ? (this.store.voiceComposer.state.holdCancel ? $r('app.color.pigo_error_panel') : $r('app.color.pigo_selected')) : $r('app.color.pigo_control'))
          .enabled(!!this.store.session.currentId && this.store.session.reachable && !(this.store.session.pendingSend !== undefined) && !this.store.session.busy && !(this.store.session.openingSession || this.store.split.state.splitNavigating))
          .onTouch((event: TouchEvent) => { this.store.voiceComposer.holdTouch(event); })
      } else {
        TextArea({ placeholder: !this.store.session.reachable ? '设备离线' : (this.store.split.state.splitOpen ? this.store.chatTitle() : '') ? `发送到 ${(this.store.split.state.splitOpen ? this.store.chatTitle() : '')}` : this.store.windowWidth < 360 ? '输入消息' : '输入消息，/ 唤起命令',
          text: this.store.session.draft })
          .id('draft').width('100%').constraintSize({ minHeight: 42, maxHeight: 108 }).onFocus(() => { this.store.armTranscriptFollow(); })
          .fontSize(16).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted')).backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6, top: 8, bottom: 8 })
          .enabled(!((this.store.session.pendingSend !== undefined) && !this.store.session.busy)).onChange((value: string) => { this.store.session.draft = value; this.store.toolCmd.syncCommandPalette(); })
      }
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph(this.store.voiceComposer.state.voiceMode ? $r('sys.symbol.keyboard') : $r('sys.symbol.mic')).fontSize(21)
            .fontColor([this.store.voiceComposer.state.voiceMode ? this.store.accent() : $r('app.color.pigo_muted')])
        }.id('voice-toggle').width(44).height(44).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
          .accessibilityText(this.store.voiceComposer.state.voiceMode ? '切换到文字输入' : '切换到语音输入')
          .enabled(!!this.store.session.currentId && !(this.store.session.pendingSend !== undefined) && !this.store.session.busy && !this.store.voiceComposer.state.recording && !this.store.voiceComposer.state.voicePreparing && !this.store.voiceComposer.state.voiceFinishing)
          .onClick(() => { const voiceMode = !this.store.voiceComposer.state.voiceMode;
            this.store.voiceComposer.state.voiceMode = voiceMode;
            this.store.voiceComposer.state.liveVoiceText = '';
            this.store.session.status = '';
            if (voiceMode) this.store.dismissKeyboard(); })
        Button({ type: ButtonType.Normal }) {
          Row({ space: 5 }) {
            Text(this.store.session.modelLabel || '选择模型').fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.pigo_muted')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '85%' })
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.pigo_muted')])
          }
        }.id('model-pill').height(44).padding({ left: 6, right: 6 }).borderRadius(10)
          .constraintSize({ maxWidth: '48%' }).backgroundColor(Color.Transparent)
          .accessibilityText(this.store.session.modelLabel ? `切换模型，当前为${this.store.session.modelLabel}` : '切换模型')
          .enabled(this.store.session.reachable && !this.store.session.busy && !(this.store.session.openingSession || this.store.split.state.splitNavigating) && !!this.store.session.currentId && this.store.session.idle && !this.store.session.queued)
          .onClick(() => { void this.store.toolCmd.openModelMenu(); })
          .bindSheet(this.store.toolCmd.state.showModelMenu!!, this.modelSheet(), {
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
          .enabled(!!this.store.session.currentId && this.store.session.reachable && !this.store.session.busy && !(this.store.session.openingSession || this.store.split.state.splitNavigating) && !(this.store.session.pendingSend !== undefined) &&
            !this.store.voiceComposer.state.recording && !this.store.voiceComposer.state.voicePreparing && !this.store.voiceComposer.state.voiceFinishing)
          .onClick(() => { this.store.toolCmd.openComposerMenu(); })
          .bindSheet(this.store.toolCmd.state.showComposerMenu!!, this.composerMenu(), {
            height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM, showClose: false,
            backgroundColor: hasImmersiveMaterial() ? undefined : $r('app.color.pigo_panel'),
            systemMaterial: immersiveSheetMaterial(),
            maskColor: '#52000000'
          })
        if (this.store.session.idle || this.hasDraft()) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(20)
              .fontColor([this.canSend() ? this.store.accentForeground() : $r('app.color.pigo_muted')])
          }.id('send').width(44).height(44).padding(0).borderRadius(16)
            .backgroundColor(this.canSend() ? this.store.accent() : $r('app.color.pigo_control'))
            .accessibilityText(this.store.session.idle ? '发送消息' : '发送消息以引导当前任务').enabled(this.canSend())
            .onClick(() => { void this.store.sessionActions.send(); })
        } else {
          Button({ type: ButtonType.Normal }) {
            Rect().width(12).height(12).fill(this.store.accentForeground()).radius(2)
          }.id('abort').width(44).height(44).borderRadius(16).backgroundColor(this.store.accent())
            .accessibilityText('停止生成').enabled(this.store.session.reachable && !this.store.session.busy && !(this.store.session.openingSession || this.store.split.state.splitNavigating))
            .onClick(() => { void this.store.sessionActions.requestAction('/abort', { id: this.store.session.currentId }); })
        }
      }.width('100%')
    }.width('100%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .attributeModifier(glassComposerSurface(this.store.darkMode))
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
        .accessibilityText('返回添加菜单').onClick(() => { this.store.toolCmd.state.showSkillPicker = false; })
      Text('技能').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
    }.width('100%')
    if (this.store.session.attachments.length) {
      Text('使用技能前请先移除附件。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
    }
    if (this.store.toolCmd.state.commandsLoading) {
      Text('正在加载技能…').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
    } else if (this.store.toolCmd.state.commandError) {
      Button(this.store.toolCmd.state.commandError).chatAction().width('100%')
        .onClick(() => { void this.store.toolCmd.loadCommands(); })
    } else if (!skillCommands(this.store.toolCmd.state.commandRows).length) {
      Text('当前会话没有可用技能。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
    } else {
      Scroll() {
        Column({ space: 6 }) {
          ForEach(skillCommands(this.store.toolCmd.state.commandRows), (row: CommandRow) => {
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
              .enabled(this.store.session.reachable && !(this.store.session.openingSession || this.store.split.state.splitNavigating) && !(this.store.session.pendingSend !== undefined))
              .onClick(() => { this.store.toolCmd.pickSkill(row); })
          }, (row: CommandRow) => row.name)
        }.width('100%')
      }.width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
        .constraintSize({ maxHeight: Math.min(320, Math.max(72, this.store.windowHeight - 180)) })
    }
  }
  @Builder
  composerMenu() {
    Column({ space: 12 }) {
      if (this.store.toolCmd.state.showSkillPicker) {
        this.skillPicker()
      } else {
        Row({ space: 8 }) {
          this.composerMenuAction('拍照', $r('sys.symbol.camera'), 'composer-camera', this.store.session.acceptsImage, () => {
            this.store.toolCmd.state.showComposerMenu = false;
            void this.store.shareController.attachImage('camera');
          })
          this.composerMenuAction('照片', $r('sys.symbol.picture'), 'composer-photos', this.store.session.acceptsImage, () => {
            this.store.toolCmd.state.showComposerMenu = false;
            void this.store.shareController.attachImage('gallery');
          })
          this.composerMenuAction('添加文件', $r('sys.symbol.paperclip'), 'composer-files', true, () => {
            this.store.toolCmd.state.showComposerMenu = false;
            void this.store.shareController.attachFile();
          })
        }.width('100%')
        if (!this.store.session.acceptsImage) {
          Text('当前模型不支持图片输入。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
        }
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(22).fontColor([$r('app.color.pigo_text')])
            Text('技能').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
          }.width('100%')
        }.id('composer-skills').width('100%').height(48).padding({ left: 10, right: 10 })
          .borderRadius(12).backgroundColor(Color.Transparent).onClick(() => { this.store.toolCmd.openSkillPicker(); })
      }
    }.id('composer-menu').width('100%').constraintSize({ maxWidth: 560 })
      .padding({ left: 16, right: 16, top: 14, bottom: 16 })
  }
  @Builder
  modelSheet() {
    Column({ space: 12 }) {
      Text('模型与思考').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).width('100%')
      if (!this.store.session.idle || this.store.session.queued) {
        Text('等待当前任务和队列结束后可切换模型。').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if ((this.currentModelOption()?.levels.length ?? 0) > 1) {
        Column({ space: 6 }) {
          Text('思考级别').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_muted')).width('100%')
          Row({ space: 4 }) {
            ForEach(this.currentModelOption()?.levels ?? [], (level: string) => {
              Button(this.thinkingLevelLabel(level), { type: ButtonType.Normal }).chatAction()
                .layoutWeight(1).height(36).padding(2).borderRadius(10).fontSize(13)
                .backgroundColor(this.store.session.currentLevel === level ? this.store.accent() : Color.Transparent)
                .fontColor(this.store.session.currentLevel === level ? this.store.accentForeground() : $r('app.color.pigo_muted'))
                .enabled(this.store.session.reachable && this.store.session.idle && !this.store.session.queued && !this.store.session.busy)
                .onClick(() => { this.store.toolCmd.state.showModelMenu = false; void this.store.toolCmd.applyThinkingLevelFromMenu(level); })
            }, (level: string) => level)
          }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
        }.width('100%')
      }
      List({ initialIndex: this.currentModelIndex(), space: 8 }) {
        ForEach(this.store.session.models, (model: ModelOption, index: number) => {
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
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.store.accent()])
                }
              }.width('100%')
            }.id(`model-option-${index}`).width('100%').height(54).padding({ left: 14, right: 14 })
              .backgroundColor(this.isCurrentModel(model) ? this.store.accentTint() : $r('app.color.pigo_control'))
              .border({ width: this.isCurrentModel(model) ? 1 : 0, radius: 12, color: this.store.accent() })
              .accessibilitySelected(this.isCurrentModel(model))
              .enabled(this.store.session.reachable && this.store.session.idle && !this.store.session.queued && !this.store.session.busy)
              .onClick(() => { this.store.toolCmd.state.showModelMenu = false; void this.store.toolCmd.applyModelFromMenu(index); })
          }
        }, (model: ModelOption) => `${model.provider}-${model.id}`)
        if (!this.store.session.models.length) {
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
    return this.store.session.draft.trim().length > 0 || this.store.session.attachments.length > 0;
  }
  private canSend(): boolean {
    return !!this.store.session.currentId && (this.store.session.idle || !!this.store.session.runId) &&
      this.store.session.reachable && !this.store.session.busy && !(this.store.session.openingSession || this.store.split.state.splitNavigating) && !(this.store.session.pendingSend !== undefined) &&
      !this.store.voiceComposer.state.recording && !this.store.voiceComposer.state.voicePreparing && !this.store.voiceComposer.state.voiceFinishing &&
      this.hasDraft() &&
      (this.store.session.acceptsImage || !this.store.session.attachments.some((item: DraftAttachment): boolean => item.kind === 'image'));
  }
  private currentModelIndex(): number {
    const idx = this.store.session.models.findIndex((item: ModelOption): boolean => this.isCurrentModel(item));
    return idx >= 0 ? idx : 0;
  }
  private currentModelOption(): ModelOption | undefined {
    return this.store.session.models.find((item: ModelOption): boolean => this.isCurrentModel(item)) ?? this.store.session.currentModel;
  }
  private isCurrentModel(model: ModelOption): boolean {
    return this.store.session.currentModel?.provider === model.provider && this.store.session.currentModel?.id === model.id;
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
