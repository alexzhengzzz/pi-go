import { glassCardSurface, glassComposerSurface } from '../Immersive';
import { CommandRow } from '../model/PiGoTypes';
import { VoiceComposerState } from '../model/VoiceComposerController';
import { unboundAction } from './ComponentAction';

@ComponentV2
export struct CommandPaletteCard {
  @Param @Require darkMode: boolean;
  @Param @Require reachable: boolean;
  @Param @Require commandsLoading: boolean;
  @Param @Require commandError: string;
  @Param @Require hasCommands: boolean;
  @Param @Require matches: CommandRow[];
  @Param @Require maxHeight: number;
  @Event commandSourceLabel: (source: string) => string = () => '';
  @Event reloadCommands: () => Promise<void> = unboundAction;
  @Event pickCommand: (row: CommandRow) => void = unboundAction;

  build() {
    Column({ space: 2 }) {
      if (!this.matches.length) {
        Text(this.commandsLoading ? '正在加载命令…' : !this.reachable ? '电脑离线，等待重连' :
          this.commandError || (this.hasCommands ? '没有匹配的命令' : '暂无可用命令'))
          .fontSize(13).fontColor($r('app.color.pigo_muted')).padding({ left: 10, right: 10, top: 10, bottom: 10 }).maxLines(2)
          .onClick(() => { if (this.commandError) void this.reloadCommands(); })
      } else {
        Scroll() {
          Column({ space: 2 }) {
            ForEach(this.matches, (row: CommandRow) => {
              Column({ space: 2 }) {
                Row({ space: 8 }) {
                  Text(row.invoke ?? `/${row.name}`).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.pigo_text')).maxLines(1).layoutWeight(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (row.source) {
                    Text(this.commandSourceLabel(row.source)).fontSize(10).fontColor($r('app.color.pigo_muted'))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(8)
                      .backgroundColor($r('app.color.pigo_control')).maxLines(1)
                  }
                }.width('100%')
                if (row.description) {
                  Text(row.description).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                }
              }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .borderRadius(10).id(`command-row-${row.name}`)
              .onClick(() => { this.pickCommand(row); })
            }, (row: CommandRow) => row.name)
          }.width('100%')
        }.constraintSize({ maxHeight: this.maxHeight })
          .width('100%').edgeEffect(EdgeEffect.Spring)
      }
    }.width('100%').padding(6)
    .attributeModifier(glassComposerSurface(this.darkMode, true))
    .id('command-palette')
  }
}

@ComponentV2
export struct VoiceFeedbackOverlay {
  @Param @Require state: VoiceComposerState;
  @Param @Require darkMode: boolean;

  build() {
    Column() {
      Column({ space: 16 }) {
        if (this.state.recording) {
          SymbolGlyph(this.state.holdCancel ? $r('sys.symbol.xmark') : $r('sys.symbol.mic'))
            .fontSize(38).fontColor([this.state.holdCancel ? '#FFFFFF' : $r('app.color.pigo_text')])
          Text(this.state.holdCancel ? '松开手指，取消发送' : '手指上滑，取消发送')
            .fontSize(15).fontColor(this.state.holdCancel ? '#FFFFFF' : $r('app.color.pigo_text'))
          Text(this.state.recordSeconds >= 50 ? `还可说 ${60 - this.state.recordSeconds} 秒` : `${this.state.recordSeconds}″`)
            .fontSize(13).fontColor(this.state.holdCancel ? '#FFFFFF' : $r('app.color.pigo_muted'))
          if (this.state.liveVoiceText && !this.state.holdCancel) {
            Text(this.state.liveVoiceText).fontSize(14).fontColor($r('app.color.pigo_text')).maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
          }
        } else if (this.state.voicePreparing || (this.state.voiceFinishing && !this.state.voiceCancelling && !this.state.voiceHint)) {
          LoadingProgress().width(36).height(36).color($r('app.color.pigo_text'))
          Text(this.state.voicePreparing ? '正在准备麦克风…' : '正在转为文字…').fontSize(15).fontColor($r('app.color.pigo_text'))
        } else {
          Text(this.state.voiceHint).fontSize(15).fontColor($r('app.color.pigo_text')).textAlign(TextAlign.Center)
        }
      }.id('voice-feedback').width(250).padding(26).alignItems(HorizontalAlign.Center)
        .borderRadius(20).backgroundColor(this.state.holdCancel ? '#B74747' : $r('app.color.pigo_control'))
        .attributeModifier(this.state.holdCancel ? undefined : glassCardSurface(this.darkMode, 20, true))
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .hitTestBehavior(HitTestMode.None)
  }
}
