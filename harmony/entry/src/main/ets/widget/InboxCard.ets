const storage = new LocalStorage();

@Entry(storage)
@Component
struct InboxCard {
  @LocalStorageProp('pending') private pending: string = '0';
  @LocalStorageProp('syncedAt') private syncedAt: string = '';

  private syncLabel(): string {
    if (!Number(this.syncedAt)) return '打开 Pi Go 同步';
    const time = new Date(Number(this.syncedAt));
    const clock = `${String(time.getHours()).padStart(2, '0')}:${String(time.getMinutes()).padStart(2, '0')}`;
    return time.toDateString() === new Date().toDateString()
      ? `同步于 ${clock}` : `同步于 ${time.getMonth() + 1}/${time.getDate()} ${clock}`;
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        Image($r('app.media.pigo')).width(22).height(22)
        Text('收件箱').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
          .maxLines(1).layoutWeight(1)
        Text('↗').fontSize(15).fontColor($r('app.color.pigo_widget_accent'))
      }.width('100%')
      Blank()
      if (Number(this.syncedAt)) {
        Row({ space: 7 }) {
          Text(Number(this.pending) > 99 ? '99+' : this.pending)
            .fontSize(38).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink')).maxLines(1)
          Text('待处理').fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_accent'))
            .maxLines(1).padding({ bottom: 5 })
        }.alignItems(VerticalAlign.Bottom).width('100%')
      } else {
        Text('待同步').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink')).maxLines(1)
      }
      Divider().color($r('app.color.pigo_widget_line')).margin({ top: 7, bottom: 7 })
      Text(this.syncLabel()).fontSize(10).fontColor($r('app.color.pigo_widget_muted')).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%').height('100%').padding(14).alignItems(HorizontalAlign.Start)
    .linearGradient({
      direction: GradientDirection.RightBottom,
      colors: [[$r('app.color.pigo_widget_surface'), 0], [$r('app.color.pigo_widget_tint'), 1]]
    })
    .accessibilityText(Number(this.syncedAt) ? `Pi Go 收件箱，${this.pending} 项待处理，${this.syncLabel()}` : '打开 Pi Go 收件箱')
    .onClick(() => {
      postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { destination: 'inbox' } });
    })
  }
}
