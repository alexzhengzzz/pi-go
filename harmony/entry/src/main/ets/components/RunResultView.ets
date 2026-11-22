import { DiffLine, diffLines, RunCheck, RunEvent, RunFile, RunScreenshot, runStatus } from '../RunResults';
import { ChatImage } from '../ChatImage';
import { unboundAction } from './ComponentAction';

@Extend(Button)
function resultButton() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .borderRadius(10)
}

@Component
export struct RunResultView {
  @Prop result: RunEvent | undefined = undefined;
  @Prop file: RunFile | undefined = undefined;
  @Prop patch: string = '';
  @Prop loading: boolean = false;
  @Prop error: string = '';
  @Prop top: number = 0;
  @Prop bottom: number = 0;
  @Prop canvas: ResourceColor = $r('app.color.pigo_panel');
  @Require back: () => void = unboundAction;
  @Require openDiff: (file: RunFile) => void = unboundAction;
  @Require openArtifact: (file: RunFile) => void = unboundAction;
  @Require loadScreenshot: (image: RunScreenshot) => Promise<string> = unboundAction;
  @Require openScreenshot: (source: string, label: string) => void = unboundAction;
  @Require citeLine: (line: DiffLine) => void = unboundAction;

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button('返回').resultButton().onClick(() => { this.back(); })
        Text(this.file?.path ?? '本轮结果').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          .fontColor($r('app.color.pigo_text')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      if (this.file) {
        if (this.loading) {
          LoadingProgress().width(32).height(32).color($r('app.color.pigo_text'))
        } else if (this.error) {
          Text(this.error).fontColor($r('app.color.pigo_muted'))
          Button('重试').resultButton().onClick(() => { if (this.file) this.openDiff(this.file); })
        } else {
          Text('点选新版本的代码行，将引用加入输入框').fontSize(12).fontColor($r('app.color.pigo_muted'))
          List() {
            ForEach(diffLines(this.patch), (line: DiffLine) => {
              ListItem() {
                Row({ space: 8 }) {
                  Text(line.line > 0 ? String(line.line) : '').width(36).fontSize(11)
                    .fontColor($r('app.color.pigo_muted')).textAlign(TextAlign.End)
                  Text(line.text).layoutWeight(1).fontFamily('monospace').fontSize(12)
                    .copyOption(CopyOptions.LocalDevice)
                    .fontColor(line.kind === 'remove' ? $r('app.color.pigo_error') :
                      line.kind === 'add' ? $r('app.color.pigo_success') : $r('app.color.pigo_text'))
                }.width('100%').padding({ top: 4, bottom: 4, right: 4 }).alignItems(VerticalAlign.Top)
                  .onClick(() => { if (line.line > 0) this.citeLine(line); })
              }
            }, (line: DiffLine) => String(line.key))
          }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
        }
      } else if (this.result) {
        Scroll() {
          Column({ space: 14 }) {
            Text(runStatus(this.result.status)).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(this.result.status === 'failed' ? $r('app.color.pigo_error') : $r('app.color.pigo_text'))
            if (this.result.partial) {
              Text('工作区超出记录范围或快照不可用，以下只展示已捕获的结果。').fontSize(12)
                .fontColor($r('app.color.pigo_muted'))
            }
            Text('文件变更').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
            if (!this.result.files?.length) {
              Text('没有记录到文件变更').fontSize(13).fontColor($r('app.color.pigo_muted'))
            }
            ForEach(this.result.files ?? [], (file: RunFile) => {
              Column({ space: 8 }) {
                Text(file.path).fontSize(14).fontColor($r('app.color.pigo_text')).width('100%')
                Row({ space: 8 }) {
                  Text(file.change === 'added' ? '新增' : file.change === 'deleted' ? '删除' : '修改')
                    .fontSize(12).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
                  if (file.diff) Button('查看 Diff').resultButton().onClick(() => { this.openDiff(file); })
                  if (!file.diff && !file.artifact) {
                    Text('无文本 Diff').fontSize(12).fontColor($r('app.color.pigo_muted'))
                  }
                  if (file.artifact) Button('打开文件').resultButton().onClick(() => { this.openArtifact(file); })
                }.width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
                .backgroundColor($r('app.color.pigo_panel')).borderRadius(10)
            }, (file: RunFile) => file.path)
            if (this.result.screenshots?.length) {
              Text('工具图片').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
              ForEach(this.result.screenshots, (image: RunScreenshot) => {
                ChatImage({
                  label: '工具图片',
                  load: (): Promise<string> => this.loadScreenshot(image),
                  open: (source: string, label: string): void => this.openScreenshot(source, label)
                })
              }, (image: RunScreenshot) => image.toolId)
            }
            Text('验证命令').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
            if (!this.result.checks?.length) {
              Text('没有识别到测试、检查或构建命令').fontSize(13).fontColor($r('app.color.pigo_muted'))
            }
            ForEach(this.result.checks ?? [], (check: RunCheck) => {
              Row({ space: 8 }) {
                Text(check.state === 'ok' ? '通过' : check.state === 'fail' ? '失败' : '未完成')
                  .fontSize(13).fontColor(check.state === 'fail' ? $r('app.color.pigo_error') : $r('app.color.pigo_muted'))
                Text(check.command).fontSize(13).fontFamily('monospace').layoutWeight(1)
                  .fontColor($r('app.color.pigo_text')).copyOption(CopyOptions.LocalDevice)
              }.width('100%')
            }, (check: RunCheck) => check.id)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%').align(Alignment.TopStart)
      }
    }.width('100%').height('100%').padding({ top: this.top + 8, bottom: this.bottom + 12, left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start).backgroundColor(this.canvas).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }
}
