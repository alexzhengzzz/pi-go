import type { WidgetActionParams } from '../InboxWidget';

@Entry
@ComponentV2
struct QuickActionsCard {
  @Local private dimension: number = 2;
  @Local private pending: string = '0';
  @Local private unread: string = '0';
  @Local private running: string = '0';
  @Local private paired: boolean = false;
  @Local private reachable: boolean = false;
  @Local private computer: string = '';
  @Local private workspace: string = '';
  @Local private currentSessionId: string = '';
  @Local private currentSessionTitle: string = '';

  private route(params: WidgetActionParams): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: params
    });
  }

  private routeTo(destination: string, sessionId?: string): void {
    const params: WidgetActionParams = sessionId
      ? { destination: destination, sessionId: sessionId }
      : { destination: destination };
    this.route(params);
  }

  private statusDotColor(): Resource {
    if (!this.paired) return $r('app.color.pigo_widget_muted');
    if (Number(this.pending) > 0) return $r('app.color.pigo_warning');
    return this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_widget_muted');
  }

  private hostTitle(): string {
    if (!this.paired) return '连接电脑';
    return this.computer || '已连接电脑';
  }

  @Builder
  tileButton(icon: Resource, title: string, subtitle: string, destination: string, highlight: boolean = false, sessionId: string = '') {
    Column({ space: 3 }) {
      Row({ space: 5 }) {
        Image(icon).width(14).height(14).fillColor($r('app.color.pigo_widget_accent'))
        Text(title).fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%')
      Text(subtitle).fontSize(10).fontColor($r('app.color.pigo_widget_muted'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1).height('100%').padding(8).justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(highlight ? $r('app.color.pigo_widget_pill') : $r('app.color.pigo_widget_card'))
    .borderRadius(10)
    .border({ width: 0.5, color: $r('app.color.pigo_widget_line') })
    .onClick(() => { this.routeTo(destination, sessionId || undefined); })
  }

  @Builder
  mini1x2() {
    Row({ space: 8 }) {
      Row({ space: 6 }) {
        Image($r('app.media.pigo')).width(22).height(22).borderRadius(6)
        Column({ space: 2 }) {
          Row({ space: 4 }) {
            Blank().width(6).height(6).borderRadius(3).backgroundColor(this.statusDotColor())
            Text(this.hostTitle()).fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(Number(this.pending) > 0 ? `${this.pending} 待处理` :
            Number(this.running) > 0 ? `${this.running} 运行中` : (this.currentSessionTitle || '就绪'))
            .fontSize(10).fontColor($r('app.color.pigo_widget_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).onClick(() => {
        if (Number(this.pending) > 0) this.routeTo('inbox');
        else if (this.currentSessionId) this.routeTo('session', this.currentSessionId);
        else this.routeTo('tasks');
      })

      Row({ space: 5 }) {
        Stack() {
          Image($r('app.media.ic_compose')).width(14).height(14).fillColor($r('app.color.pigo_widget_accent'))
        }
        .width(30).height(30).borderRadius(9).backgroundColor($r('app.color.pigo_widget_card'))
        .border({ width: 0.5, color: $r('app.color.pigo_widget_line') })
        .onClick(() => { this.routeTo('new_task'); })

        Stack() {
          Image($r('app.media.ic_inbox')).width(14).height(14).fillColor($r('app.color.pigo_widget_accent'))
        }
        .width(30).height(30).borderRadius(9).backgroundColor($r('app.color.pigo_widget_card'))
        .border({ width: 0.5, color: $r('app.color.pigo_widget_line') })
        .onClick(() => { this.routeTo('inbox'); })
      }
    }.width('100%').height('100%').alignItems(VerticalAlign.Center)
  }

  @Builder
  grid2x2() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Image($r('app.media.pigo')).width(18).height(18).borderRadius(5)
        Blank().width(6).height(6).borderRadius(3).backgroundColor(this.statusDotColor())
        Text(this.hostTitle()).fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%').onClick(() => { this.routeTo(this.paired ? 'tasks' : 'computers'); })

      Row({ space: 6 }) {
        this.tileButton(
          $r('app.media.ic_compose'),
          '新建会话',
          this.workspace || '发起新任务',
          'new_task',
          true
        )
        this.tileButton(
          $r('app.media.ic_terminal'),
          '当前会话',
          this.currentSessionTitle || '会话列表',
          this.currentSessionId ? 'session' : 'tasks',
          false,
          this.currentSessionId
        )
      }.width('100%').layoutWeight(1)

      Row({ space: 6 }) {
        this.tileButton(
          $r('app.media.ic_inbox'),
          '收件箱',
          Number(this.pending) > 0 ? `${this.pending} 项待处理` :
            Number(this.unread) > 0 ? `${this.unread} 条未读` : '查看消息',
          'inbox'
        )
        this.tileButton(
          $r('app.media.ic_tasks'),
          '任务看板',
          Number(this.running) > 0 ? `${this.running} 个运行中` : '定时与后台',
          'pending'
        )
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
  }

  @Builder
  wide2x4() {
    Column({ space: 7 }) {
      Row({ space: 6 }) {
        Image($r('app.media.pigo')).width(20).height(20).borderRadius(5)
        Blank().width(6).height(6).borderRadius(3).backgroundColor(this.statusDotColor())
        Text(this.workspace ? `${this.hostTitle()} · ${this.workspace}` : this.hostTitle())
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_widget_ink'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.currentSessionTitle) {
          Text(`当前：${this.currentSessionTitle}`)
            .fontSize(11).fontColor($r('app.color.pigo_widget_accent'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 140 })
            .onClick(() => {
              this.routeTo('session', this.currentSessionId);
            })
        }
      }.width('100%')

      Row({ space: 6 }) {
        this.tileButton(
          $r('app.media.ic_compose'),
          '新建会话',
          this.workspace || '快速提问',
          'new_task',
          true
        )
        this.tileButton(
          $r('app.media.ic_terminal'),
          '继续会话',
          this.currentSessionTitle || '打开会话列表',
          this.currentSessionId ? 'session' : 'tasks',
          false,
          this.currentSessionId
        )
        this.tileButton(
          $r('app.media.ic_inbox'),
          '收件箱',
          Number(this.pending) > 0 ? `${this.pending} 待确认` : `${this.unread} 未读`,
          'inbox'
        )
      }.width('100%').layoutWeight(1)

      Row({ space: 6 }) {
        this.tileButton(
          $r('app.media.ic_tasks'),
          '后台与定时',
          Number(this.running) > 0 ? `${this.running} 运行中` : '任务中心',
          'pending'
        )
        this.tileButton(
          $r('app.media.ic_folder'),
          '工作区文件',
          this.workspace || '浏览代码',
          'files'
        )
        this.tileButton(
          $r('app.media.ic_computer'),
          '电脑管理',
          this.reachable ? '在线连接' : '切换/配对',
          'computers'
        )
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
  }

  build() {
    Column() {
      if (this.dimension === 1) {
        this.mini1x2()
      } else if (this.dimension === 3) {
        this.wide2x4()
      } else {
        this.grid2x2()
      }
    }
    .width('100%').height('100%').padding(this.dimension === 1 ? { left: 10, right: 10, top: 6, bottom: 6 } : 12)
    .linearGradient({
      direction: GradientDirection.RightBottom,
      colors: [[$r('app.color.pigo_widget_surface'), 0], [$r('app.color.pigo_widget_tint'), 1]]
    })
    .accessibilityText('Pi Go 快捷指令卡片')
  }
}
