import type { WidgetActionParams, WidgetItem } from '../InboxWidget';

const storage = new LocalStorage();

@Entry(storage)
@Component
struct ScheduleCard {
  @LocalStorageProp('dimension') private dimension: number = 3;
  @LocalStorageProp('running') private running: string = '0';
  @LocalStorageProp('scheduleCount') private scheduleCount: string = '0';
  @LocalStorageProp('paired') private paired: boolean = false;
  @LocalStorageProp('reachable') private reachable: boolean = false;
  @LocalStorageProp('computer') private computer: string = '';
  @LocalStorageProp('nextScheduleName') private nextScheduleName: string = '';
  @LocalStorageProp('nextScheduleTime') private nextScheduleTime: string = '';
  @LocalStorageProp('runningItems') private runningItems: WidgetItem[] = [];
  @LocalStorageProp('scheduleItems') private scheduleItems: WidgetItem[] = [];

  private route(params: WidgetActionParams): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: params
    });
  }

  private routeTo(destination: string): void {
    this.route({ destination: destination });
  }

  private badgeColor(status: string): Resource {
    if (status === 'waiting') return $r('app.color.pigo_warning');
    if (status === 'failed' || status === 'interrupted') return $r('app.color.pigo_error');
    if (status === 'streaming' || status === 'running' || status === 'succeeded') return $r('app.color.pigo_success');
    if (status === 'queued') return $r('app.color.pigo_queued');
    return $r('app.color.pigo_widget_accent');
  }

  @Builder
  rowEntry(item: WidgetItem) {
    Row({ space: 6 }) {
      Blank().width(6).height(6).borderRadius(3).backgroundColor(this.badgeColor(item.status))
      Column({ space: 1 }) {
        Text(item.title).fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.subtitle) {
          Text(item.subtitle).fontSize(9).fontColor($r('app.color.pigo_widget_muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text(item.statusText).fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.badgeColor(item.status))
    }
    .width('100%').padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(9)
    .onClick(() => {
      if (item.sessionId) {
        this.route({ destination: 'session', sessionId: item.sessionId, address: item.address || '' });
      } else {
        this.routeTo('pending');
      }
    })
  }

  @Builder
  compact2x2() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Image($r('app.media.ic_tasks')).width(16).height(16).fillColor($r('app.color.pigo_widget_accent'))
        Text('定时与后台').fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink'))
          .layoutWeight(1).maxLines(1)
        if (Number(this.running) > 0) {
          Text(`${this.running} 运行`).fontSize(10).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_success'))
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor($r('app.color.pigo_widget_pill')).borderRadius(6)
        }
      }.width('100%').onClick(() => { this.routeTo('pending'); })

      if (this.nextScheduleName) {
        Column({ space: 2 }) {
          Text('下次定时执行').fontSize(9).fontColor($r('app.color.pigo_widget_muted'))
          Text(this.nextScheduleName).fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.nextScheduleTime).fontSize(10).fontColor($r('app.color.pigo_widget_accent')).maxLines(1)
        }
        .width('100%').padding(7).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(9)
        .onClick(() => { this.routeTo('pending'); })
      } else if (this.runningItems.length > 0) {
        this.rowEntry(this.runningItems[0])
      } else if (this.scheduleItems.length > 0) {
        this.rowEntry(this.scheduleItems[0])
      } else {
        Column({ space: 2 }) {
          Text(this.paired ? '暂无运行或定时计划' : '尚未连接电脑').fontSize(11).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.pigo_widget_ink'))
          Text('点击新建定时任务').fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
        }
        .width('100%').padding(7).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(9)
        .onClick(() => { this.routeTo('new_schedule'); })
      }

      Blank()
      Row({ space: 6 }) {
        Row({ space: 4 }) {
          Image($r('app.media.ic_plus')).width(11).height(11).fillColor($r('app.color.pigo_widget_accent'))
          Text('新建定时').fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
        }
        .layoutWeight(1).height(26).justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(8)
        .onClick(() => { this.routeTo('new_schedule'); })

        Row({ space: 4 }) {
          Text('历史').fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
        }
        .width(46).height(26).justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(8)
        .onClick(() => { this.routeTo('schedule_history'); })
      }.width('100%')
    }.width('100%').height('100%')
  }

  @Builder
  wide2x4() {
    Column({ space: 7 }) {
      Row({ space: 6 }) {
        Image($r('app.media.ic_tasks')).width(17).height(17).fillColor($r('app.color.pigo_widget_accent'))
        Text(this.computer ? `定时与后台 · ${this.computer}` : 'Pi Go 定时与后台看板')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink'))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 4 }) {
          Image($r('app.media.ic_plus')).width(11).height(11).fillColor($r('app.color.pigo_widget_accent'))
          Text('新建定时').fontSize(10).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor($r('app.color.pigo_widget_pill')).borderRadius(8)
        .onClick(() => { this.routeTo('new_schedule'); })
      }.width('100%')

      Row({ space: 8 }) {
        Column({ space: 5 }) {
          Column({ space: 2 }) {
            Row({ space: 6 }) {
              Text(`${this.running} 运行中`).fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor(Number(this.running) > 0 ? $r('app.color.pigo_success') : $r('app.color.pigo_widget_ink'))
              Text(`· ${this.scheduleCount} 计划`).fontSize(11).fontColor($r('app.color.pigo_widget_muted'))
            }
            if (this.nextScheduleName) {
              Text(`下次：${this.nextScheduleName}`).fontSize(11).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.pigo_widget_ink')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.nextScheduleTime).fontSize(10).fontColor($r('app.color.pigo_widget_accent')).maxLines(1)
            } else {
              Text('暂无待执行的定时计划').fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
            }
          }
          .width('100%').layoutWeight(1).padding(8).justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
          .onClick(() => { this.routeTo('pending'); })

          Row({ space: 5 }) {
            Row() {
              Text('任务面板').fontSize(10).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
            }
            .layoutWeight(1).height(25).justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(7)
            .onClick(() => { this.routeTo('pending'); })

            Row() {
              Text('运行历史').fontSize(10).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
            }
            .layoutWeight(1).height(25).justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(7)
            .onClick(() => { this.routeTo('schedule_history'); })
          }.width('100%')
        }.width(136).height('100%')

        Column({ space: 5 }) {
          if (this.runningItems.length > 0 || this.scheduleItems.length > 0) {
            ForEach(this.runningItems.concat(this.scheduleItems).slice(0, 2), (item: WidgetItem) => {
              this.rowEntry(item)
            }, (item: WidgetItem, index: number) => `${item.id}:${item.sessionId}:${index}`)
          } else {
            Column({ space: 4 }) {
              Text('后台与定时运行空闲').fontSize(12).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.pigo_widget_ink'))
              Text('创建每日汇总、定时巡检或无人值守任务，执行结果会自动推送到此处')
                .fontSize(10).fontColor($r('app.color.pigo_widget_muted')).maxLines(2)
            }
            .width('100%').layoutWeight(1).padding(10).justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
            .onClick(() => { this.routeTo('new_schedule'); })
          }
        }.layoutWeight(1).height('100%').justifyContent(FlexAlign.SpaceBetween)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
  }

  build() {
    Column() {
      if (this.dimension === 2) {
        this.compact2x2()
      } else {
        this.wide2x4()
      }
    }
    .width('100%').height('100%').padding(12).alignItems(HorizontalAlign.Start)
    .linearGradient({
      direction: GradientDirection.RightBottom,
      colors: [[$r('app.color.pigo_widget_surface'), 0], [$r('app.color.pigo_widget_tint'), 1]]
    })
    .accessibilityText('Pi Go 定时与后台看板')
  }
}
