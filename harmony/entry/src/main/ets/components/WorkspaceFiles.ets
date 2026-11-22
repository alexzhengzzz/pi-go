import { unboundAction } from './ComponentAction';
import { FileTreeRow } from '../model/PiGoTypes';

@Component
export struct WorkspaceFiles {
  @Prop bottomContentClearance: number;
  @Prop busy: boolean;
  @Prop fileRoot: string;
  fileTreeIndex: number = 0;
  @Link fileTreeRows: FileTreeRow[];
  @Require loadFileDirectory: (path: string, more?: boolean) => Promise<void> = unboundAction;
  @Require openFile: (cwd: string, path: string, lookupName?: boolean) => Promise<void> = unboundAction;
  @Prop openingSession: boolean;
  @Prop project: string;
  @Require toggleFileDirectory: (path: string) => Promise<void> = unboundAction;
  @Prop topContentClearance: number;
  @Prop accent: string;
  @Require setFileTreeIndex: (index: number) => void = unboundAction;

  build() {
    List({ initialIndex: this.fileTreeIndex }) {
      ListItem() {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(21).fontColor([this.accent])
          Column({ space: 2 }) {
            Text(this.project || '项目根目录').fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.fileRoot).fontSize(11).fontColor($r('app.color.pigo_muted')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
          .border({ width: 1, color: $r('app.color.pigo_line') })
          .margin({ bottom: 8 })
      }
      if (this.fileTreeRows.length) {
        ForEach(this.fileTreeRows, (row: FileTreeRow) => {
          ListItem() {
            Column() {
              this.workspaceTreeRow(row)
            }.width('100%').backgroundColor($r('app.color.pigo_panel')).borderRadius(10)
              .margin({ bottom: 2 })
          }
        }, (row: FileTreeRow): string => `${row.kind}:${row.expanded ?? false}:${row.path}`)
      } else {
        ListItem() {
          Text(this.busy ? '正在读取目录…' : '未能读取目录')
            .fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%').padding(16)
            .borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
            .border({ width: 1, color: $r('app.color.pigo_line') })
        }
      }
    }.width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(this.topContentClearance)
      .contentEndOffset(this.bottomContentClearance)
      .padding({ left: 16, right: 16 })
      .onScrollIndex((start: number) => { this.setFileTreeIndex(Math.max(0, start)); })
  }
  @Builder
  workspaceTreeRow(row: FileTreeRow) {
    if (row.kind === 'empty') {
      Text(row.name).fontSize(13).fontColor($r('app.color.pigo_muted'))
        .width('100%').height(42).padding({ left: 36 + Math.min(row.depth, 10) * 14 })
    } else {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          SymbolGlyph(row.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(13).fontColor([$r('app.color.pigo_muted')])
            .opacity(row.kind === 'directory' ? 1 : 0)
          if (row.kind === 'directory') {
            SymbolGlyph($r('sys.symbol.folder')).fontSize(18).fontColor([this.accent])
          } else if (row.kind !== 'more') {
            SymbolGlyph($r('sys.symbol.doc')).fontSize(18).fontColor([$r('app.color.pigo_muted')]).width(19)
          }
          Text(row.name).fontSize(14).fontWeight(row.kind === 'directory' ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(row.kind === 'more' ? this.accent : $r('app.color.pigo_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (row.kind === 'blocked') {
            Text('不可访问').fontSize(11).fontColor($r('app.color.pigo_muted'))
          }
        }.width('100%').padding({ left: 12 + Math.min(row.depth, 10) * 14, right: 12 })
      }.id(row.kind === 'more' ? `workspace-more-${row.path}` : `file-${row.path}`)
        .width('100%').height(44).padding(0).borderRadius(8).backgroundColor(Color.Transparent)
        .enabled(!this.busy && !this.openingSession && row.kind !== 'blocked')
        .accessibilityText(row.kind === 'directory' ? `${row.name}，${row.expanded ? '已展开' : '已收起'}` :
          row.kind === 'more' && row.path ? `加载更多，${row.path}` :
          row.kind === 'blocked' ? `${row.name}，不可访问` : row.name)
        .onClick(() => {
          if (row.kind === 'directory') void this.toggleFileDirectory(row.path);
          else if (row.kind === 'more') void this.loadFileDirectory(row.path, true);
          else void this.openFile(this.fileRoot, row.path);
        })
    }
  }
}
