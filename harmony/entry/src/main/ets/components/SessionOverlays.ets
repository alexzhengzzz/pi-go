import { glassCardSurface } from '../Immersive';
import { RunMessage, scheduleRunStatus } from '../ScheduledRuns';
import { ModelOption, RunNotice } from '../model/PiGoTypes';
import { unboundAction } from './ComponentAction';
import { bannerTransition, subPageTransition } from './PageTransitions';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@ComponentV2
export struct RunCompletionBanner {
  @Param @Require notice: RunNotice;
  @Param @Require iconColor: ResourceColor;
  @Param @Require darkMode: boolean;
  @Param @Require statusBarHeight: number;
  @Event dismiss: () => void = unboundAction;

  build() {
    Row() {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph(this.notice.stopped ? $r('sys.symbol.minus_circle') : $r('sys.symbol.checkmark_circle'))
            .fontSize(20).fontColor([this.iconColor])
        }.width(32).height(32).borderRadius(16).backgroundColor($r('app.color.pigo_control'))
          .accessibilityLevel('no')
        Column({ space: 2 }) {
          Text(this.notice.stopped ? '运行已停止' : '运行已结束')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          Text(this.notice.title).fontSize(13).fontColor($r('app.color.pigo_muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
        }.id('run-completion-dismiss').width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('关闭运行通知').onClick(() => { this.dismiss(); })
      }.id('run-completion-banner').width('100%').constraintSize({ maxWidth: 440 })
        .padding({ left: 14, right: 4, top: 6, bottom: 6 })
        .attributeModifier(glassCardSurface(this.darkMode, 16, true))
    }.width('100%').justifyContent(FlexAlign.Center).padding({ left: 16, right: 16 })
      .margin({ top: this.statusBarHeight + 8 }).hitTestBehavior(HitTestMode.Transparent)
      .transition(bannerTransition())
  }
}

@ComponentV2
export struct ScheduledRunBanner {
  @Param @Require message: RunMessage;
  @Param @Require darkMode: boolean;
  @Event open: (message: RunMessage) => void = unboundAction;
  @Event dismiss: () => void = unboundAction;

  build() {
    Row({ space: 6 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 2 }) {
          Text(`${this.message.run.name} · ${scheduleRunStatus(this.message.run.status)}`).fontSize(15)
            .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.message.computer).fontSize(13).fontColor($r('app.color.pigo_muted'))
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).height(48).padding({ left: 12 }).backgroundColor(Color.Transparent)
        .onClick(() => { this.open(this.message); })
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
      }.width(40).height(40).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
        .accessibilityText('关闭定时任务通知').onClick(() => { this.dismiss(); })
    }.id('schedule-completion-banner').width('92%').constraintSize({ maxWidth: 440 }).padding(6)
      .attributeModifier(glassCardSurface(this.darkMode, 16, true))
  }
}

@ComponentV2
export struct OfflineNotice {
  @Param @Require compact: boolean;
  @Param @Require narrow: boolean;
  @Param @Require busy: boolean;
  @Event retry: () => void = unboundAction;
  @Event dismiss: () => void = unboundAction;
  @Event openComputers: () => void = unboundAction;

  build() {
    Row({ space: this.narrow ? 6 : 10 }) {
      if (!this.narrow) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(20)
          .fontColor([$r('app.color.pigo_warning')])
      }
      Column({ space: 4 }) {
        Text(this.narrow ? '电脑离线' : this.compact ? '设备已离线，当前为缓存内容' : '电脑设备已离线')
          .fontSize(this.compact ? 13 : 16).fontWeight(FontWeight.Medium).fontColor(this.compact ? $r('app.color.pigo_warning') : $r('app.color.pigo_text'))
        if (!this.compact) Text('请检查电脑与网络连接').fontSize(12).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (!this.compact) Button('切换').chatAction().height(34).fontSize(13)
        .onClick(() => { if (!this.busy) this.openComputers(); })
      if (this.compact) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16).fontColor([$r('app.color.pigo_warning')])
        }.id('drawer-retry').width(36).height(34).padding(0).borderRadius(10)
          .backgroundColor(Color.Transparent).enabled(!this.busy)
          .accessibilityText('重试连接')
          .onClick(() => { this.retry(); })
      } else {
        Button('重试').chatAction().id('offline-retry')
          .height(34).fontSize(13).enabled(!this.busy)
          .accessibilityText('重试连接')
          .onClick(() => { this.retry(); })
      }
      if (!this.compact) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
        }.width(34).height(34).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
          .accessibilityText('关闭离线提示').onClick(() => { this.dismiss(); })
      }
    }.width('100%').padding(this.narrow ? 8 : this.compact ? 10 : 14).borderRadius(this.compact ? 12 : 16)
      .backgroundColor(this.compact ? $r('app.color.pigo_warning_panel') : $r('app.color.pigo_panel'))
      .border({ width: this.compact ? 0 : 1, color: $r('app.color.pigo_line') })
  }
}

export interface RunningSessionPill {
  id: string;
  name?: string;
  label: string;
  color: ResourceColor;
}

@ComponentV2
export struct RunningSessionStrip {
  @Param @Require rows: RunningSessionPill[];
  @Param @Require canOpen: boolean;
  @Event openSession: (id: string) => void = unboundAction;

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.rows, (row: RunningSessionPill) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 6 }) {
              Text('').width(6).height(6).borderRadius(3)
                .backgroundColor(row.color)
              Text(row.name || '后台任务').fontSize(13).fontColor($r('app.color.pigo_text')).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 152 })
              Text(row.label).fontSize(11)
                .fontColor(row.color)
            }
          }.id(`running-${row.id}`).height(34).padding({ left: 12, right: 12 }).borderRadius(17)
            .backgroundColor($r('app.color.pigo_panel')).accessibilityText(`${row.name || '后台任务'}${row.label}，点击切换查看`)
            .enabled(this.canOpen)
            .onClick(() => {
              this.openSession(row.id);
            })
        }, (row: RunningSessionPill) => `${row.id}:${row.name}:${row.label}`)
      }.padding({ left: 2, right: 6 })
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      .edgeEffect(EdgeEffect.Spring).friction(0.5)
  }
}

@ComponentV2
export struct SessionSettings {
  @Param @Require renameDraft: string;
  @Param @Require busy: boolean;
  @Param @Require reachable: boolean;
  @Param @Require modelLabel: string;
  @Param @Require models: ModelOption[];
  @Param @Require selectedModel: number;
  @Param @Require selectedLevel: string;
  @Param @Require idle: boolean;
  @Param @Require queued: boolean;
  @Param @Require sharingSession: boolean;
  @Param @Require darkMode: boolean;
  @Param @Require hasSession: boolean;
  @Param @Require accent: string;
  @Param @Require accentForeground: string;
  @Param @Require topContentClearance: number;
  @Param @Require bottomPad: number;
  @Event changeName: (value: string) => void = unboundAction;
  @Event rename: () => void = unboundAction;
  @Event selectModel: (index: number) => void = unboundAction;
  @Event selectLevel: (level: string) => void = unboundAction;
  @Event applyModel: () => void = unboundAction;
  @Event share: () => void = unboundAction;
  @Event thinkingLevelLabel: (level: string) => string = unboundAction;

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Column({ space: 10 }) {
          Text('会话名称').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
          TextInput({ text: this.renameDraft, placeholder: '输入会话名称' }).id('rename-draft').maxLength(200)
            .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
            .placeholderColor($r('app.color.pigo_muted'))
            .onChange((value: string) => { this.changeName(value); })
          Button('保存名称').chatAction().id('rename-save').width('100%').height(42)
            .backgroundColor(this.accent).fontColor(this.accentForeground)
            .enabled(!this.busy && this.reachable && !!this.renameDraft.trim())
            .onClick(() => { this.rename(); })
        }.width('100%').padding(14).attributeModifier(glassCardSurface(this.darkMode, 16))
        Column({ space: 10 }) {
          Row() {
            Text('模型与思考').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
            Text(this.modelLabel).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '60%' })
          }.width('100%')
          if (this.models.length) {
            Select(this.models.map((model: ModelOption): SelectOption => ({
              value: `${model.name} · ${model.provider}${model.image ? ' · 图片' : ''}`
            })))
              .id('model-select').width('100%').selected(this.selectedModel)
              .value(this.models[this.selectedModel] ? `${this.models[this.selectedModel].name} · ${this.models[this.selectedModel].provider}` : '选择模型')
              .fontColor($r('app.color.pigo_text')).backgroundColor($r('app.color.pigo_control'))
              .enabled(!this.busy)
              .onSelect((index: number) => {
                this.selectModel(index);
              })
          }
          if (this.selectedModel >= 0 && this.models[this.selectedModel]) {
            Text('思考级别').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_muted')).width('100%')
            if (this.models[this.selectedModel].levels.length > 1) {
              Row({ space: 4 }) {
                ForEach(this.models[this.selectedModel].levels, (level: string) => {
                  Button(this.thinkingLevelLabel(level), { type: ButtonType.Normal }).chatAction()
                    .layoutWeight(1).height(36).padding(2).borderRadius(10).fontSize(13)
                    .backgroundColor(this.selectedLevel === level ? this.accent : Color.Transparent)
                    .fontColor(this.selectedLevel === level ? this.accentForeground : $r('app.color.pigo_muted'))
                    .enabled(!this.busy)
                    .onClick(() => { this.selectLevel(level); })
                }, (level: string) => level)
              }.id('thinking-select').width('100%').padding(4).borderRadius(14)
                .backgroundColor($r('app.color.pigo_control'))
            } else {
              Text('此模型不支持调整思考级别。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
            }
            Button('应用模型与思考级别').chatAction().id('model-apply').width('100%').height(44)
              .backgroundColor(this.accent).fontColor(this.accentForeground)
              .enabled(this.reachable && !this.busy && this.idle && !this.queued)
              .onClick(() => {
                this.applyModel();
              })
          }
          if (!this.idle || this.queued) {
            Text('等待当前任务和队列结束后可切换模型。').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
          }
          if (!this.models.length) {
            Text('没有可用模型，请在电脑上检查当前 Agent 的模型配置。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
          }
        }.width('100%').padding(14).attributeModifier(glassCardSurface(this.darkMode, 16))
        Column({ space: 10 }) {
          Text('会话分享').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
          Text('将当前会话整理为 Markdown 文件，通过系统分享发送给其他应用。')
            .fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
          Button(this.sharingSession ? '正在准备分享…' : '分享会话').chatAction().id('session-share')
            .width('100%').height(42).backgroundColor(this.accent).fontColor(this.accentForeground)
            .enabled(!this.sharingSession && this.hasSession)
            .onClick(() => { this.share(); })
        }.width('100%').padding(14).attributeModifier(glassCardSurface(this.darkMode, 16))
      }.width('100%').padding({ left: 16, right: 16, top: this.topContentClearance, bottom: this.bottomPad + 16 })
    }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
      .transition(subPageTransition())
  }
}
