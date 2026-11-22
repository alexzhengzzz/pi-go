interface PetalSpec {
  id: string;
  startX: string;
  w: number;
  h: number;
  startAngle: number;
  endAngle: number;
  driftX: number;
  duration: number;
  delay: number;
  alpha: number;
  tint: number;
}

const FULL_PETALS: PetalSpec[] = [
  { id: 'p1', startX: '14%', w: 15, h: 10, startAngle: -20, endAngle: 240, driftX: -48, duration: 9600, delay: 0, alpha: 0.56, tint: 0 },
  { id: 'p2', startX: '30%', w: 12, h: 8, startAngle: 15, endAngle: -230, driftX: -62, duration: 11200, delay: 1400, alpha: 0.46, tint: 1 },
  { id: 'p3', startX: '48%', w: 18, h: 12, startAngle: -35, endAngle: 260, driftX: -76, duration: 10400, delay: 2900, alpha: 0.52, tint: 2 },
  { id: 'p4', startX: '64%', w: 13, h: 9, startAngle: 28, endAngle: 300, driftX: -58, duration: 8800, delay: 600, alpha: 0.48, tint: 0 },
  { id: 'p5', startX: '78%', w: 20, h: 13, startAngle: -14, endAngle: -260, driftX: -88, duration: 12400, delay: 2100, alpha: 0.58, tint: 1 },
  { id: 'p6', startX: '90%', w: 14, h: 9, startAngle: 42, endAngle: 310, driftX: -70, duration: 9200, delay: 3900, alpha: 0.50, tint: 2 },
  { id: 'p7', startX: '22%', w: 11, h: 7, startAngle: -45, endAngle: 220, driftX: -42, duration: 10800, delay: 5200, alpha: 0.42, tint: 1 },
  { id: 'p8', startX: '56%', w: 16, h: 11, startAngle: 10, endAngle: -245, driftX: -66, duration: 11800, delay: 6600, alpha: 0.54, tint: 0 },
  { id: 'p9', startX: '84%', w: 13, h: 8, startAngle: -28, endAngle: 275, driftX: -82, duration: 9800, delay: 7800, alpha: 0.48, tint: 2 },
  { id: 'p10', startX: '40%', w: 14, h: 9, startAngle: 36, endAngle: -210, driftX: -54, duration: 10200, delay: 4500, alpha: 0.46, tint: 0 },
  { id: 'p11', startX: '72%', w: 11, h: 7, startAngle: -10, endAngle: 250, driftX: -60, duration: 8600, delay: 8400, alpha: 0.44, tint: 1 },
  { id: 'p12', startX: '95%', w: 17, h: 11, startAngle: 22, endAngle: -280, driftX: -94, duration: 11600, delay: 1100, alpha: 0.52, tint: 2 }
];

const COMPACT_PETALS: PetalSpec[] = [
  { id: 'c1', startX: '16%', w: 11, h: 7, startAngle: -24, endAngle: 210, driftX: -22, duration: 4800, delay: 0, alpha: 0.72, tint: 0 },
  { id: 'c2', startX: '42%', w: 9, h: 6, startAngle: 18, endAngle: -190, driftX: -26, duration: 5400, delay: 1100, alpha: 0.62, tint: 1 },
  { id: 'c3', startX: '68%', w: 12, h: 8, startAngle: -32, endAngle: 230, driftX: -30, duration: 5000, delay: 2200, alpha: 0.68, tint: 2 },
  { id: 'c4', startX: '88%', w: 10, h: 6, startAngle: 28, endAngle: -220, driftX: -28, duration: 4600, delay: 600, alpha: 0.66, tint: 0 },
  { id: 'c5', startX: '54%', w: 10, h: 7, startAngle: -12, endAngle: 200, driftX: -20, duration: 5600, delay: 3200, alpha: 0.60, tint: 1 }
];

@Component
export struct SakuraPetals {
  @Prop darkMode: boolean = false;
  @Prop compact: boolean = false;
  @State private drifting: boolean = false;
  @State private swaying: boolean = false;
  @State private areaHeight: number = 0;
  private startTimer: number = -1;

  aboutToDisappear(): void {
    if (this.startTimer !== -1) {
      clearTimeout(this.startTimer);
      this.startTimer = -1;
    }
  }

  private startMotion(): void {
    if (this.drifting) return;
    if (this.startTimer !== -1) clearTimeout(this.startTimer);
    this.startTimer = setTimeout(() => {
      this.startTimer = -1;
      this.drifting = true;
      this.swaying = true;
    }, 32);
  }

  private petals(): PetalSpec[] {
    return this.compact ? COMPACT_PETALS : FULL_PETALS;
  }

  private travelY(): number {
    if (this.areaHeight > 40) return this.areaHeight + (this.compact ? 24 : 56);
    return this.compact ? 170 : 960;
  }

  private petalColors(tint: number): [ResourceColor, number][] {
    if (this.darkMode) {
      if (tint === 1) return [['#FFB8D2', 0], ['#F278AA', 1]];
      if (tint === 2) return [['#FFD2E3', 0], ['#E86B9D', 1]];
      return [['#FFA8C8', 0], ['#F06B9E', 1]];
    }
    if (tint === 1) return [['#FFD4E6', 0], ['#FF8FB8', 1]];
    if (tint === 2) return [['#FFF0F6', 0], ['#FFB0CF', 1]];
    return [['#FFE0EC', 0], ['#FF9EC4', 1]];
  }

  private petalRadius(h: number): BorderRadiuses {
    return {
      topLeft: Math.round(h * 0.72),
      topRight: Math.round(h * 0.95),
      bottomLeft: Math.round(h * 0.95),
      bottomRight: Math.round(h * 0.22)
    };
  }

  build() {
    Stack() {
      ForEach(this.petals(), (spec: PetalSpec) => {
        Blank()
          .width(spec.w)
          .height(spec.h)
          .borderRadius(this.petalRadius(spec.h))
          .linearGradient({
            angle: 135,
            colors: this.petalColors(spec.tint)
          })
          .opacity(this.darkMode ? spec.alpha * 0.68 : spec.alpha)
          .position({ x: spec.startX, y: this.compact ? -16 : -28 })
          .translate({
            x: this.drifting ? spec.driftX : 0,
            y: this.drifting ? this.travelY() : 0
          })
          .rotate({ angle: this.drifting ? spec.endAngle : spec.startAngle })
          .animation({
            duration: spec.duration,
            delay: spec.delay,
            curve: Curve.Linear,
            iterations: -1,
            playMode: PlayMode.Normal
          })
      }, (spec: PetalSpec) => spec.id)

      if (!this.compact) {
        Text('✿')
          .fontSize(26)
          .fontColor(this.darkMode ? '#FF9EBF' : '#FF9AC1')
          .opacity(this.darkMode ? 0.16 : 0.28)
          .position({ x: '82%', y: '16%' })
          .rotate({ angle: this.swaying ? 22 : -8 })
          .translate({ y: this.swaying ? 6 : -4 })
          .animation({
            duration: 4200,
            curve: Curve.EaseInOut,
            iterations: -1,
            playMode: PlayMode.Alternate
          })
        Text('✿')
          .fontSize(19)
          .fontColor(this.darkMode ? '#FFB4CF' : '#FFAEC9')
          .opacity(this.darkMode ? 0.14 : 0.24)
          .position({ x: '8%', y: '72%' })
          .rotate({ angle: this.swaying ? -18 : 12 })
          .translate({ y: this.swaying ? -5 : 5 })
          .animation({
            duration: 4800,
            delay: 700,
            curve: Curve.EaseInOut,
            iterations: -1,
            playMode: PlayMode.Alternate
          })
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const h = Number(newArea.height);
      if (h > 0 && Math.abs(h - this.areaHeight) > 8) this.areaHeight = h;
    })
    .onAppear(() => {
      this.startMotion();
    })
  }
}
