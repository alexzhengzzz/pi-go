import { fileIo, fileUri } from '@kit.CoreFileKit';

@Component
export struct ChatImage {
  @Prop label: string = '图片';
  @Prop remoteUrl: string = '';
  load: () => Promise<string> = async (): Promise<string> => '';
  open: (source: string, label: string) => void = () => {};
  @State private source: string = '';
  @State private loading: boolean = false;
  @State private error: string = '';
  private started: boolean = false;
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.disposed = false;
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  private async show(): Promise<void> {
    if (this.loading) return;
    this.started = true;
    this.loading = true;
    this.error = '';
    try {
      const source = this.remoteUrl || await this.load();
      if (this.disposed) return;
      if (!source) throw new Error('image_not_found');
      this.source = source;
    } catch (error) {
      if (this.disposed) return;
      const code = (error as Error).message;
      this.error = code === 'not_found' ? '请更新电脑端 Pi Go' :
        code === 'image_too_large' || code === 'file_too_large' ? '图片超过 8 MiB' :
          code === 'unsupported_image' ? '图片格式暂不支持' : '无法加载图片';
    } finally {
      if (!this.disposed) this.loading = false;
    }
  }

  build() {
    Column() {
      if (this.source) {
        Image(this.remoteUrl ? this.source : fileUri.getUriFromPath(this.source))
          .width('100%').height(180).objectFit(ImageFit.Contain).borderRadius(10)
          .accessibilityText(this.label)
          .onClick(() => { this.open(this.source, this.label); })
          .onError(() => {
            if (!this.remoteUrl && this.source) {
              try { fileIo.unlinkSync(this.source); } catch {}
            }
            this.source = '';
            this.error = '图片无法解码';
          })
      } else if (this.loading) {
        Text('正在加载图片…').fontSize(13).fontColor($r('app.color.pigo_muted'))
      } else {
        Button(this.error ? `${this.label} · ${this.error} · 重试` : `查看${this.label}`)
          .fontSize(13).type(ButtonType.Normal).backgroundColor($r('app.color.pigo_control'))
          .fontColor($r('app.color.pigo_text')).onClick(() => { void this.show(); })
      }
    }.width('100%').constraintSize({ minHeight: 52 }).justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.pigo_panel')).borderRadius(10)
      .onVisibleAreaChange([0, 0.01], (visible: boolean, ratio: number) => {
        if (visible && ratio > 0 && !this.started && !this.remoteUrl) void this.show();
      })
  }
}
