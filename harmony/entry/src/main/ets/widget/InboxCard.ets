import type { WidgetActionParams, WidgetItem } from '../InboxWidget';

const storage = new LocalStorage();

@Entry(storage)
@Component
struct InboxCard {
  @LocalStorageProp('dimension') private dimension: number = 3;
  @LocalStorageProp('pending') private pending: string = '0';
  @LocalStorageProp('unread') private unread: string = '0';
  @LocalStorageProp('running') private running: string = '0';
  @LocalStorageProp('scheduleCount') private scheduleCount: string = '0';
  @LocalStorageProp('syncedAt') private syncedAt: string = '';
  @LocalStorageProp('paired') private paired: boolean = false;
  @LocalStorageProp('reachable') private reachable: boolean = false;
  @LocalStorageProp('computer') private computer: string = '';
  @LocalStorageProp('workspace') private workspace: string = '';
  @LocalStorageProp('currentSessionId') private currentSessionId: string = '';
  @LocalStorageProp('currentSessionTitle') private currentSessionTitle: string = '';
  @LocalStorageProp('nextScheduleName') private nextScheduleName: string = '';
  @LocalStorageProp('nextScheduleTime') private nextScheduleTime: string = '';
  @LocalStorageProp('items') private items: WidgetItem[] = [];
  @LocalStorageProp('runningItems') private runningItems: WidgetItem[] = [];

  private syncLabel(): string {
    if (!Number(this.syncedAt)) return '轻触连接电脑';
    const time = new Date(Number(this.syncedAt));
    const clock = `${String(time.getHours()).padStart(2, '0')}:${String(time.getMinutes()).padStart(2, '0')}`;
    return time.toDateString() === new Date().toDateString()
      ? `${clock} 同步` : `${time.getMonth() + 1}/${time.getDate()} ${clock}`;
  }

  private computerSummary(): string {
    if (!this.paired && !Number(this.syncedAt)) return '未配对电脑';
    const host = this.computer || '已配对电脑';
    return this.workspace ? `${host} · ${this.workspace}` : host;
  }

  private statusDotColor(): Resource {
    if (!this.paired && !Number(this.syncedAt)) return $r('app.color.pigo_widget_muted');
    if (Number(this.pending) > 0) return $r('app.color.pigo_warning');
    return this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_widget_muted');
  }

  private itemBadgeColor(status: string): Resource {
    if (status === 'waiting') return $r('app.color.pigo_warning');
    if (status === 'failed' || status === 'interrupted') return $r('app.color.pigo_error');
    if (status === 'streaming' || status === 'running') return $r('app.color.pigo_success');
    if (status === 'queued') return $r('app.color.pigo_queued');
    return $r('app.color.pigo_widget_accent');
  }

  private itemBadgeBg(status: string): Resource {
    if (status === 'waiting') return $r('app.color.pigo_warning_panel');
    if (status === 'failed' || status === 'interrupted') return $r('app.color.pigo_error_panel');
    return $r('app.color.pigo_widget_pill');
  }

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

  private openItem(item: WidgetItem): void {
    if (item.sessionId) {
      this.route({
        destination: 'session',
        sessionId: item.sessionId,
        address: item.address || '',
        pendingId: item.pendingId || '',
        eventId: item.id || ''
      });
    } else {
      this.routeTo('inbox');
    }
  }

  @Builder
  headerBar(compact: boolean) {
    Row({ space: 6 }) {
      Image($r('app.media.pigo')).width(compact ? 18 : 20).height(compact ? 18 : 20).borderRadius(5)
      Row({ space: 5 }) {
        Blank().width(6).height(6).borderRadius(3).backgroundColor(this.statusDotColor())
        Text(this.computerSummary())
          .fontSize(compact ? 11 : 12).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.layoutWeight(1)
      if (!compact) {
        Text(this.syncLabel()).fontSize(10).fontColor($r('app.color.pigo_widget_muted')).maxLines(1)
      }
    }.width('100%').onClick(() => {
      this.routeTo(this.paired || Number(this.syncedAt) ? 'inbox' : 'computers');
    })
  }

  @Builder
  actionPill(icon: Resource, label: string, destination: string) {
    Row({ space: 4 }) {
      Image(icon).width(12).height(12).fillColor($r('app.color.pigo_widget_accent'))
      Text(label).fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink')).maxLines(1)
    }
    .layoutWeight(1).height(28).justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(8)
    .border({ width: 0.5, color: $r('app.color.pigo_widget_line') })
    .onClick(() => { this.routeTo(destination); })
  }

  @Builder
  taskItemRow(item: WidgetItem, compact: boolean) {
    Row({ space: 7 }) {
      Blank().width(6).height(6).borderRadius(3).backgroundColor(this.itemBadgeColor(item.status))
      Column({ space: 1 }) {
        Text(item.title || 'Pi 会话')
          .fontSize(compact ? 11 : 12)
          .fontWeight(item.unread || item.status === 'waiting' ? FontWeight.Bold : FontWeight.Medium)
          .fontColor($r('app.color.pigo_widget_ink'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!compact && item.subtitle) {
          Text(item.subtitle).fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text(item.statusText)
        .fontSize(10).fontWeight(FontWeight.Medium)
        .fontColor(this.itemBadgeColor(item.status))
        .backgroundColor(this.itemBadgeBg(item.status))
        .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
    }
    .width('100%').padding({ left: 8, right: 8, top: compact ? 5 : 6, bottom: compact ? 5 : 6 })
    .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
    .onClick(() => { this.openItem(item); })
  }

  @Builder
  compact2x2() {
    Column({ space: 6 }) {
      this.headerBar(true)
      Row({ space: 6 }) {
        Column({ space: 1 }) {
          Text(Number(this.pending) > 99 ? '99+' : this.pending)
            .fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(Number(this.pending) > 0 ? $r('app.color.pigo_warning') : $r('app.color.pigo_widget_ink'))
            .maxLines(1)
          Text('待处理').fontSize(10).fontColor($r('app.color.pigo_widget_muted')).maxLines(1)
        }
        .layoutWeight(1).padding({ left: 8, right: 6, top: 5, bottom: 5 }).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
        .onClick(() => { this.routeTo('inbox'); })

        Column({ space: 1 }) {
          Text(Number(this.running) > 99 ? '99+' : this.running)
            .fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(Number(this.running) > 0 ? $r('app.color.pigo_success') : $r('app.color.pigo_widget_ink'))
            .maxLines(1)
          Text('运行中').fontSize(10).fontColor($r('app.color.pigo_widget_muted')).maxLines(1)
        }
        .layoutWeight(1).padding({ left: 8, right: 6, top: 5, bottom: 5 }).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
        .onClick(() => { this.routeTo('pending'); })
      }.width('100%')

      if (this.items.length > 0) {
        this.taskItemRow(this.items[0], true)
      } else if (this.currentSessionTitle) {
        this.taskItemRow({
          id: '',
          sessionId: this.currentSessionId,
          address: '',
          computer: this.computer,
          title: this.currentSessionTitle,
          subtitle: this.workspace,
          status: 'active',
          statusText: '当前',
          timeText: '',
          unread: false
        }, true)
      } else {
        Row({ space: 5 }) {
          Image($r('app.media.ic_inbox')).width(12).height(12).fillColor($r('app.color.pigo_widget_muted'))
          Text(Number(this.syncedAt) ? '暂无待办消息' : '打开 Pi Go 同步状态')
            .fontSize(11).fontColor($r('app.color.pigo_widget_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
        .width('100%').padding({ left: 8, right: 8, top: 5, bottom: 5 })
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
        .onClick(() => { this.routeTo('inbox'); })
      }

      Blank()
      Row({ space: 6 }) {
        this.actionPill($r('app.media.ic_compose'), '新任务', 'new_task')
        this.actionPill($r('app.media.ic_inbox'), Number(this.unread) > 0 ? `收件箱 ${this.unread}` : '收件箱', 'inbox')
      }.width('100%')
    }.width('100%').height('100%')
  }

  @Builder
  medium2x4() {
    Column({ space: 7 }) {
      this.headerBar(false)
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Row({ space: 5 }) {
            Column({ space: 1 }) {
              Text(Number(this.pending) > 99 ? '99+' : this.pending)
                .fontSize(20).fontWeight(FontWeight.Bold)
                .fontColor(Number(this.pending) > 0 ? $r('app.color.pigo_warning') : $r('app.color.pigo_widget_ink'))
              Text('待处理').fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
            }
            .layoutWeight(1).padding(6).alignItems(HorizontalAlign.Start)
            .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(9)
            .onClick(() => { this.routeTo('inbox'); })

            Column({ space: 1 }) {
              Text(Number(this.running) > 99 ? '99+' : this.running)
                .fontSize(20).fontWeight(FontWeight.Bold)
                .fontColor(Number(this.running) > 0 ? $r('app.color.pigo_success') : $r('app.color.pigo_widget_ink'))
              Text('运行中').fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
            }
            .layoutWeight(1).padding(6).alignItems(HorizontalAlign.Start)
            .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(9)
            .onClick(() => { this.routeTo('pending'); })
          }.width('100%')

          Row({ space: 5 }) {
            this.actionPill($r('app.media.ic_compose'), '新建', 'new_task')
            this.actionPill($r('app.media.ic_tasks'), '任务', 'pending')
          }.width('100%')
        }.width(126)

        Column({ space: 5 }) {
          if (this.items.length > 0) {
            ForEach(this.items.slice(0, 2), (item: WidgetItem) => {
              this.taskItemRow(item, false)
            }, (item: WidgetItem, index: number) => `${item.id}:${item.sessionId}:${index}`)
          } else if (this.currentSessionTitle) {
            this.taskItemRow({
              id: 'current',
              sessionId: this.currentSessionId,
              address: '',
              computer: this.computer,
              title: this.currentSessionTitle,
              subtitle: this.workspace ? `当前会话 · ${this.workspace}` : '点击继续当前会话',
              status: 'active',
              statusText: '当前会话',
              timeText: '',
              unread: false
            }, false)
            if (this.nextScheduleName) {
              Row({ space: 6 }) {
                Image($r('app.media.ic_pending')).width(12).height(12).fillColor($r('app.color.pigo_widget_accent'))
                Text(`定时：${this.nextScheduleName} · ${this.nextScheduleTime}`)
                  .fontSize(11).fontColor($r('app.color.pigo_widget_muted')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              }
              .width('100%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
              .onClick(() => { this.routeTo('pending'); })
            }
          } else {
            Column({ space: 4 }) {
              Text(Number(this.syncedAt) ? '收件箱一切就绪' : '尚未同步电脑任务')
                .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
              Text(Number(this.syncedAt) ? '待确认请求、后台运行结果与定时消息会在此实时展示' : '点击打开 Pi Go 连接电脑或新建会话')
                .fontSize(10).fontColor($r('app.color.pigo_widget_muted')).maxLines(2)
            }
            .width('100%').layoutWeight(1).padding(10).justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
            .onClick(() => { this.routeTo('inbox'); })
          }
        }.layoutWeight(1).height('100%').justifyContent(FlexAlign.SpaceBetween)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
  }

  @Builder
  large4x4() {
    Column({ space: 8 }) {
      this.headerBar(false)
      Row({ space: 6 }) {
        Column({ space: 2 }) {
          Text(Number(this.pending) > 99 ? '99+' : this.pending)
            .fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(Number(this.pending) > 0 ? $r('app.color.pigo_warning') : $r('app.color.pigo_widget_ink'))
          Text('待处理请求').fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
        }
        .layoutWeight(1).padding(8).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
        .onClick(() => { this.routeTo('inbox'); })

        Column({ space: 2 }) {
          Text(Number(this.running) > 99 ? '99+' : this.running)
            .fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(Number(this.running) > 0 ? $r('app.color.pigo_success') : $r('app.color.pigo_widget_ink'))
          Text('后台运行中').fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
        }
        .layoutWeight(1).padding(8).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
        .onClick(() => { this.routeTo('pending'); })

        Column({ space: 2 }) {
          Text(Number(this.unread) > 99 ? '99+' : this.unread)
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_accent'))
          Text('未读结果').fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
        }
        .layoutWeight(1).padding(8).alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
        .onClick(() => { this.routeTo('inbox'); })
      }.width('100%')

      if (this.currentSessionTitle) {
        Row({ space: 8 }) {
          Image($r('app.media.ic_terminal')).width(14).height(14).fillColor($r('app.color.pigo_widget_accent'))
          Column({ space: 1 }) {
            Text(`当前会话：${this.currentSessionTitle}`)
              .fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.workspace) {
              Text(`工作区：${this.workspace}`).fontSize(10).fontColor($r('app.color.pigo_widget_muted')).maxLines(1)
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('继续 →').fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_accent'))
        }
        .width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .backgroundColor($r('app.color.pigo_widget_pill')).borderRadius(10)
        .onClick(() => {
          this.route({ destination: 'session', sessionId: this.currentSessionId });
        })
      }

      Column({ space: 5 }) {
        Row() {
          Text('任务与收件箱动态').fontSize(11).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_muted'))
          Blank()
          if (this.nextScheduleName) {
            Text(`下次定时：${this.nextScheduleTime}`)
              .fontSize(10).fontColor($r('app.color.pigo_widget_accent'))
              .onClick(() => { this.routeTo('pending'); })
          }
        }.width('100%')

        if (this.items.length > 0) {
          ForEach(this.items.slice(0, this.currentSessionTitle ? 3 : 4), (item: WidgetItem) => {
            this.taskItemRow(item, false)
          }, (item: WidgetItem, index: number) => `${item.id}:${item.sessionId}:${index}`)
        } else {
          Column({ space: 4 }) {
            Text(Number(this.syncedAt) ? '暂无待处理的任务或新通知' : '等待同步电脑端任务')
              .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_widget_ink'))
            Text('可以在下方一键新建会话、查看工作区文件或管理定时任务')
              .fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
          }
          .width('100%').layoutWeight(1).padding(12).justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor($r('app.color.pigo_widget_card')).borderRadius(10)
          .onClick(() => { this.routeTo('inbox'); })
        }
      }.width('100%').layoutWeight(1)

      Row({ space: 6 }) {
        this.actionPill($r('app.media.ic_compose'), '新建会话', 'new_task')
        this.actionPill($r('app.media.ic_inbox'), '收件箱', 'inbox')
        this.actionPill($r('app.media.ic_tasks'), '定时任务', 'pending')
        this.actionPill($r('app.media.ic_folder'), '工作区', 'files')
      }.width('100%')
    }.width('100%').height('100%')
  }

  build() {
    Column() {
      if (this.dimension === 4) {
        this.large4x4()
      } else if (this.dimension === 3) {
        this.medium2x4()
      } else {
        this.compact2x2()
      }
    }
    .width('100%').height('100%').padding(12).alignItems(HorizontalAlign.Start)
    .linearGradient({
      direction: GradientDirection.RightBottom,
      colors: [[$r('app.color.pigo_widget_surface'), 0], [$r('app.color.pigo_widget_tint'), 1]]
    })
    .accessibilityText(Number(this.syncedAt)
      ? `Pi Go 智能工作台，${this.pending} 项待处理，${this.running} 项运行中，${this.syncLabel()}`
      : '打开 Pi Go 智能工作台')
  }
}
