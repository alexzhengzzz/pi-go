import { DiffLine, diffLines, RunCheck, RunEvent, RunFile, RunScreenshot, runStatus } from '../RunResults';
import { ChatImage } from '../ChatImage';
import { unboundAction } from './ComponentAction';

import { canvasFadeStops, ThemePalette, themePalette, themeStyle } from '../Appearance';
import { immersiveSurface, themedCardSurface } from '../Immersive';
import { headerSymbol } from './HeaderSymbol';
import { runStatusInk, runStatusMark } from './RunStatusMark';

@Component
export struct RunResultView {
  @Prop result: RunEvent | undefined = undefined;
  @Prop file: RunFile | undefined = undefined;
  @Prop patch: string = '';
  @Prop loading: boolean = false;
  @Prop error: string = '';
  @Prop top: number = 0;
  @Prop bottom: number = 0;
  @Prop themeId: string = 'mint';
  @Prop darkMode: boolean = false;
  @Require back: () => void = unboundAction;
  @Require openDiff: (file: RunFile) => void = unboundAction;
  @Require openArtifact: (file: RunFile) => void = unboundAction;
  @Require loadScreenshot: (image: RunScreenshot) => Promise<string> = unboundAction;
  @Require openScreenshot: (source: string, label: string) => void = unboundAction;
  @Require citeLine: (line: DiffLine) => void = unboundAction;

  private palette(): ThemePalette {
    return themePalette(this.themeId, this.darkMode);
  }

  private fileName(path: string): string {
    return path.split('/').pop() || path;
  }

  private parentPath(path: string): string {
    return path.substring(0, Math.max(0, path.lastIndexOf('/')));
  }

  private fileStatus(file: RunFile): string {
    if (file.change === 'added') return '新增';
    if (file.change === 'deleted') return '删除';
    if (file.change === 'artifact') return '产物';
    return '修改';
  }

  private fileInk(file: RunFile): ResourceColor {
    if (file.change === 'deleted') return $r('app.color.pigo_error');
    if (file.change === 'added') return $r('app.color.pigo_success');
    return $r('app.color.pigo_muted');
  }

  @Builder
  reviewHeader() {
    Row({ space: 12 }) {
      Button({ type: ButtonType.Normal }) {
        headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
      }.id('run-review-back').width(44).height(44).padding(0).borderRadius(22)
        .backgroundColor(Color.Transparent).attributeModifier(immersiveSurface(this.darkMode))
        .accessibilityText('返回').onClick(() => { this.back(); })
      Column({ space: 3 }) {
        Text(this.file ? this.fileName(this.file.path) : '本轮结果')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.file && this.parentPath(this.file.path)) {
          Text(this.parentPath(this.file.path)).fontSize(12).fontColor($r('app.color.pigo_muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ left: 16, right: 16, top: this.top + 8, bottom: 12 })
      .linearGradient({ direction: GradientDirection.Bottom, colors: canvasFadeStops(this.palette().canvas) })
  }

  @Builder
  resultOverview(run: RunEvent) {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          runStatusMark(run.status, this.palette().accent, this.palette().accentTint, 44)
          Column({ space: 4 }) {
            Text(run.title || runStatus(run.status)).fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.pigo_text')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (run.title) {
              Text(runStatus(run.status)).fontSize(12).fontColor(runStatusInk(run.status, this.palette().accent))
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding(14).attributeModifier(themedCardSurface(this.darkMode, this.themeId, true))

        if (run.partial) {
          Row({ space: 8 }) {
            headerSymbol($r('sys.symbol.exclamationmark_circle'), $r('app.color.pigo_warning'), 16)
            Text('工作区快照只记录了部分结果。').fontSize(12).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
          }.width('100%').padding({ left: 4, right: 4 })
        }
        if (run.files?.length) {
          Column({ space: 8 }) {
            this.sectionTitle('文件变更和产物', run.files.length)
            Column() {
              ForEach(run.files, (file: RunFile, index: number) => {
                if (index > 0) this.divider()
                this.fileRow(file)
              }, (file: RunFile) => file.path)
            }.width('100%').attributeModifier(themedCardSurface(this.darkMode, this.themeId)).clip(true)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        if (run.checks?.length) {
          Column({ space: 8 }) {
            this.sectionTitle('验证命令', run.checks.length)
            Column() {
              ForEach(run.checks, (check: RunCheck, index: number) => {
                if (index > 0) this.divider()
                this.checkRow(check)
              }, (check: RunCheck) => check.id)
            }.width('100%').attributeModifier(themedCardSurface(this.darkMode, this.themeId)).clip(true)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        if (run.screenshots?.length) {
          Column({ space: 8 }) {
            this.sectionTitle('工具图片', run.screenshots.length)
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(run.screenshots, (image: RunScreenshot) => {
                Column() {
                  ChatImage({
                    label: '工具图片',
                    load: (): Promise<string> => this.loadScreenshot(image),
                    open: (source: string, label: string): void => this.openScreenshot(source, label)
                  })
                }.margin({ right: 8, bottom: 8 })
              }, (image: RunScreenshot) => image.toolId)
            }.width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        if (!run.files?.length && !run.checks?.length && !run.screenshots?.length) {
          Text('这轮没有可查看的文件、验证命令或图片。').fontSize(13).fontColor($r('app.color.pigo_muted'))
            .padding({ left: 4, top: 4 })
        }
      }.width('100%').constraintSize({ maxWidth: 680 }).alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 6, bottom: this.bottom + 16 })
    }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
  }

  @Builder
  sectionTitle(title: string, count: number) {
    Row({ space: 7 }) {
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
      Text(String(count)).fontSize(11).fontColor($r('app.color.pigo_muted'))
    }.width('100%').padding({ left: 4, right: 4 })
  }

  @Builder
  divider() {
    Divider().color(this.palette().cardBorder).strokeWidth(0.5).margin({ left: 12, right: 12 })
  }

  @Builder
  fileRow(file: RunFile) {
    Row({ space: 7 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          Stack() {
            headerSymbol($r('sys.symbol.doc'), this.palette().accent, 16)
          }.width(30).height(30).borderRadius(9).backgroundColor(this.palette().accentTint)
          Column({ space: 4 }) {
            Text(this.fileName(file.path)).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.parentPath(file.path)) {
              Text(this.parentPath(file.path)).fontSize(11).fontColor($r('app.color.pigo_muted'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text(this.fileStatus(file)).fontSize(11).fontColor(this.fileInk(file))
          if (file.diff) {
            Text('Diff').fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.palette().accent)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 }).borderRadius(6)
              .backgroundColor(this.palette().accentTint)
          }
          if (file.diff || file.artifact) headerSymbol($r('sys.symbol.chevron_right'), $r('app.color.pigo_muted'), 12)
        }.width('100%').padding({ left: 11, right: 11, top: 10, bottom: 10 })
      }.id(`run-file-${file.path}`).layoutWeight(1).padding(0).borderRadius(0).backgroundColor(Color.Transparent)
        .accessibilityText(`${file.path}，${this.fileStatus(file)}${file.diff ? '，查看 Diff' : file.artifact ? '，打开文件' : '，无文本 Diff'}`)
        .onClick(() => {
          if (file.diff) this.openDiff(file);
          else if (file.artifact) this.openArtifact(file);
        })
      if (file.diff && file.artifact) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.arrow_down'), this.palette().accent, 16)
        }.id(`run-artifact-${file.path}`).width(38).height(38).padding(0).margin({ right: 10 }).borderRadius(11)
          .backgroundColor(this.palette().accentTint).accessibilityText(`打开文件 ${file.path}`)
          .onClick(() => { this.openArtifact(file); })
      }
    }.width('100%')
  }

  @Builder
  checkRow(check: RunCheck) {
    Row({ space: 10 }) {
      runStatusMark(check.state === 'ok' ? 'completed' : check.state === 'fail' ? 'failed' : 'stopped',
        this.palette().accent, this.palette().accentTint, 30)
      Text(check.command).fontSize(12).fontFamily('monospace').layoutWeight(1)
        .fontColor($r('app.color.pigo_text')).copyOption(CopyOptions.LocalDevice)
      Text(check.state === 'ok' ? '成功' : check.state === 'fail' ? '失败' : '未完成')
        .fontSize(11).fontColor(check.state === 'fail' ? $r('app.color.pigo_error') : $r('app.color.pigo_muted'))
    }.width('100%').padding(11)
  }

  @Builder
  diffRow(line: DiffLine) {
    Row({ space: 0 }) {
      Text(line.line > 0 ? String(line.line) : '').width(35).fontSize(11).fontFamily('monospace')
        .fontColor($r('app.color.pigo_muted')).textAlign(TextAlign.End).padding({ right: 8, top: 5 })
      Text(line.text).layoutWeight(1).fontFamily('monospace').fontSize(12).lineHeight(19)
        .padding({ left: 6, right: 8, top: 3, bottom: 3 })
        .copyOption(line.line > 0 ? CopyOptions.None : CopyOptions.LocalDevice)
        .fontColor(line.kind === 'remove' ? $r('app.color.pigo_error') :
          line.kind === 'add' ? $r('app.color.pigo_success') :
          line.kind === 'hunk' ? this.palette().accent : $r('app.color.pigo_text'))
    }.id(`diff-line-${line.key}`).width('100%').alignItems(VerticalAlign.Top)
      .backgroundColor(line.kind === 'hunk' ? this.palette().codeHeaderBg :
        line.kind === 'add' ? this.palette().accentTint :
        line.kind === 'remove' ? $r('app.color.pigo_error_panel') : Color.Transparent)
      .onClick(() => { if (line.line > 0) this.citeLine(line); })
  }

  @Builder
  diffReview(lines: DiffLine[]) {
    Column({ space: 9 }) {
      Row({ space: 8 }) {
        Text('Diff').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.palette().accent)
        Text('点代码行可添加引用').fontSize(12).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
      }.width('100%').padding({ left: 4, right: 4 })
      if (lines.length <= 12 && this.patch.length <= 1200) {
        Scroll() {
          Column() {
            ForEach(lines, (line: DiffLine) => { this.diffRow(line) }, (line: DiffLine) => String(line.key))
          }.width('100%').backgroundColor(this.palette().codeBg)
            .border({ width: 1, radius: themeStyle(this.themeId).codeRadius, color: this.palette().codeBorder })
            .clip(true)
        }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
      } else {
        List() {
          ForEach(lines, (line: DiffLine) => {
            ListItem() { this.diffRow(line) }
          }, (line: DiffLine) => String(line.key))
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
          .backgroundColor(this.palette().codeBg)
          .border({ width: 1, radius: themeStyle(this.themeId).codeRadius, color: this.palette().codeBorder }).clip(true)
      }
    }.width('100%').constraintSize({ maxWidth: 840 }).layoutWeight(1)
      .padding({ left: 16, right: 16, top: 5, bottom: this.bottom + 12 })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column().width('100%').height('100%')
        .radialGradient({ center: ['16%', '8%'], radius: '78%',
          colors: [[this.palette().auraTop, 0], ['#00000000', 1]] })
        .hitTestBehavior(HitTestMode.None)
      Column() {
        this.reviewHeader()
        if (this.file) {
          if (this.loading || this.error) {
            Column({ space: 12 }) {
              if (this.loading) LoadingProgress().width(28).height(28).color(this.palette().accent)
              else {
                Text(this.error).fontSize(14).fontColor($r('app.color.pigo_muted'))
                Button('重试').height(38).fontSize(13).fontColor(this.palette().accent)
                  .backgroundColor(this.palette().accentTint)
                  .onClick(() => { if (this.file) this.openDiff(this.file); })
              }
            }.layoutWeight(1).justifyContent(FlexAlign.Center).padding({ bottom: this.bottom })
          } else {
            this.diffReview(diffLines(this.patch))
          }
        } else if (this.result) {
          this.resultOverview(this.result)
        }
      }.width('100%').height('100%')
    }.width('100%').height('100%').backgroundColor(this.palette().canvas).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }
}
