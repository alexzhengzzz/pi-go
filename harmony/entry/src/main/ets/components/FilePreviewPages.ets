import { glassButtonSurface } from '../Immersive';
import { ReceivedFilePreview } from '../model/PiGoTypes';
import { unboundAction } from './ComponentAction';
import { headerSymbol } from './HeaderSymbol';
import { pagePushTransition } from './PageTransitions';

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

@ComponentV2
export struct TextFilePreviewPage {
  @Param @Require preview: ReceivedFilePreview;
  @Param @Require busy: boolean;
  @Param @Require savingPreview: boolean;
  @Param @Require canEdit: boolean;
  @Param @Require previewNotice: string;
  @Param @Require previewScroller: Scroller;
  @Param @Require pageNumber: number;
  @Param @Require darkMode: boolean;
  @Param @Require headerHeight: number;
  @Param @Require statusBarHeight: number;
  @Param @Require bottomPad: number;
  @Param @Require accent: ResourceColor;
  @Param @Require accentForeground: ResourceColor;
  @Event close: () => void = unboundAction;
  @Event editPreview: (preview: ReceivedFilePreview) => void = unboundAction;
  @Event savePreviewLocally: (preview: ReceivedFilePreview) => Promise<void> = unboundAction;
  @Event reopenSystemPreview: (preview: ReceivedFilePreview) => Promise<void> = unboundAction;
  @Event imagePreviewError: (preview: ReceivedFilePreview) => Promise<void> = unboundAction;
  @Event changePreviewPage: (forward: boolean) => void = unboundAction;
  @BuilderParam markdownBody: () => void;

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('text-preview-close').headerAction().attributeModifier(glassButtonSurface(this.darkMode)).accessibilityText('返回').enabled(!this.savingPreview)
          .onClick(() => { this.close(); })
        Text(this.preview.name).id('text-preview-title').layoutWeight(1)
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').height(this.headerHeight)
        .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
      if ((this.preview.version && this.canEdit) || this.preview.localPath || this.preview.text !== undefined || this.preview.systemUri) {
        Row({ space: 8 }) {
          if (this.preview.version && this.canEdit) {
            Button('编辑').chatAction().id('preview-edit').height(38).enabled(!this.busy && !this.savingPreview)
              .backgroundColor(this.accent).fontColor(this.accentForeground)
              .onClick(() => { this.editPreview(this.preview); })
          }
          if (this.preview.localPath || this.preview.text !== undefined) {
            Button(this.savingPreview ? '正在保存…' : '保存到本机').chatAction().id('preview-save-local').height(38)
              .enabled(!this.savingPreview).onClick(() => { void this.savePreviewLocally(this.preview); })
          }
          if (this.preview.systemUri) {
            Button('系统预览').chatAction().height(38).enabled(!this.savingPreview)
              .onClick(() => { void this.reopenSystemPreview(this.preview); })
          }
        }.width('100%')
      }
      if (this.previewNotice) {
        Text(this.previewNotice).id('preview-notice').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if (this.preview.imageUri) {
        Image(this.preview.imageUri).id('image-preview').width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
          .accessibilityText(this.preview.name).onError(() => { void this.imagePreviewError(this.preview); })
      } else {
        Scroll(this.previewScroller) {
          Column() {
            if (this.preview.text === undefined) {
              Text(this.preview.systemUri ? '点击「系统预览」打开文件。' : '已接收文件，可保存到本机。')
                .fontSize(15).fontColor($r('app.color.pigo_muted'))
            } else if (!this.preview.text.length) {
              Text('空文件').fontSize(15).fontColor($r('app.color.pigo_muted'))
            } else if (this.preview.markdown) {
              this.markdownBody()
            } else {
              Text(this.preview.text).fontSize(15).lineHeight(24).fontFamily('monospace').fontColor($r('app.color.pigo_text'))
                .width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 16 })
        }.id('text-preview-body').scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)
          .layoutWeight(1).width('100%').align(Alignment.TopStart)
      }
      if (this.preview.nextOffset !== undefined || (this.preview.offset ?? 0) > 0) {
        Row({ space: 8 }) {
          Button('上一页').chatAction().enabled((this.preview.offset ?? 0) > 0 && !this.savingPreview)
            .onClick(() => { this.changePreviewPage(false); })
          Text(`第 ${this.pageNumber} 页`).fontSize(13).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button('下一页').chatAction().enabled(this.preview.nextOffset !== undefined && !this.savingPreview)
            .onClick(() => { this.changePreviewPage(true); })
        }.width('100%')
      }
    }.id('text-file-preview').width('100%').constraintSize({ maxWidth: this.preview.imageUri ? 1024 : 840 })
      .height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 8, bottom: this.bottomPad + 8 })
  }
}

@ComponentV2
export struct MarkdownTableReaderPage {
  @Param @Require markdownRotationUnavailable: boolean;
  @Param @Require canvas: ResourceColor;
  @Param @Require darkMode: boolean;
  @Param @Require headerHeight: number;
  @Param @Require statusBarHeight: number;
  @Param @Require bottomPad: number;
  @Event close: () => void = unboundAction;
  @BuilderParam markdownBody: () => void;

  build() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('markdown-exit-landscape').headerAction().attributeModifier(glassButtonSurface(this.darkMode)).accessibilityText('退出横屏')
          .onClick(() => { this.close(); })
        Text('表格').fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).layoutWeight(1)
      }.width('100%').height(this.headerHeight)
        .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
      if (this.markdownRotationUnavailable) {
        Text('当前窗口无法自动横屏，可左右滑动表格。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
      }
      Scroll() {
        Column() {
          this.markdownBody()
        }.width('100%')
      }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
    }.width('100%').height('100%').padding({
      left: 16, right: 16, top: this.statusBarHeight + 8, bottom: this.bottomPad + 4
    }).backgroundColor(this.canvas).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      .transition(pagePushTransition())
  }
}

@ComponentV2
export struct WorkspaceFileEditor {
  @Param @Require editingPath: string;
  @Param @Require fileText: string;
  @Param @Require fileOriginal: string;
  @Param @Require busy: boolean;
  @Param @Require reachable: boolean;
  @Param @Require editorNotice: string;
  @Param @Require darkMode: boolean;
  @Param @Require headerHeight: number;
  @Param @Require statusBarHeight: number;
  @Param @Require bottomPad: number;
  @Param @Require accent: ResourceColor;
  @Param @Require accentForeground: ResourceColor;
  @Event back: () => void = unboundAction;
  @Event showPreview: () => void = unboundAction;
  @Event changeText: (text: string) => void = unboundAction;
  @Event saveFile: () => Promise<void> = unboundAction;

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('file-back').headerAction().attributeModifier(glassButtonSurface(this.darkMode)).accessibilityText(this.fileText !== this.fileOriginal ? '放弃修改' : '返回')
          .enabled(!this.busy).onClick(() => { this.back(); })
        Text(this.editingPath.split('/').pop() || this.editingPath)
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('预览').chatAction().id('file-editor-preview').height(38).enabled(!this.busy).onClick(() => {
          this.showPreview();
        })
      }.width('100%').height(this.headerHeight)
        .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
      Text(this.editingPath).fontSize(12).fontColor($r('app.color.pigo_muted'))
        .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      TextArea({ text: this.fileText }).id('file-editor').layoutWeight(1).width('100%').maxLength(65536)
        .fontFamily('monospace').fontSize(14).backgroundColor($r('app.color.pigo_panel'))
        .fontColor($r('app.color.pigo_text')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.pigo_line') })
        .enabled(!this.busy).onChange((value: string) => { this.changeText(value); })
      if (this.editorNotice) {
        Text(this.editorNotice).id('file-editor-notice').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      Button(this.busy ? '正在保存…' : '保存到电脑').chatAction().id('file-save').width('100%').height(46)
        .backgroundColor(this.accent).fontColor(this.accentForeground)
        .enabled(this.reachable && !this.busy && this.fileText !== this.fileOriginal)
        .onClick(() => { void this.saveFile(); })
    }.width('100%').constraintSize({ maxWidth: 840 }).height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 8, bottom: this.bottomPad + 8 })
  }
}
