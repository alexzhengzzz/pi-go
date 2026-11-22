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

interface TransientPetal {
  id: string;
  x: number;
  y: number;
  dx: number;
  dy: number;
  w: number;
  h: number;
  startAngle: number;
  endAngle: number;
  duration: number;
  delay: number;
  alpha: number;
  tint: number;
}

@Component
struct BurstPetal {
  @Prop spec: TransientPetal;
  @Prop darkMode: boolean = false;
  @Prop dimmed: boolean = false;
  @State private launched: boolean = false;
  private timerId: number = -1;

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  private colors(): [ResourceColor, number][] {
    if (this.darkMode) {
      if (this.spec.tint === 1) return [['#FFB8D2', 0], ['#F278AA', 1]];
      if (this.spec.tint === 2) return [['#FFD2E3', 0], ['#E86B9D', 1]];
      return [['#FFA8C8', 0], ['#F06B9E', 1]];
    }
    if (this.spec.tint === 1) return [['#FFD4E6', 0], ['#FF8FB8', 1]];
    if (this.spec.tint === 2) return [['#FFF0F6', 0], ['#FFB0CF', 1]];
    return [['#FFE0EC', 0], ['#FF9EC4', 1]];
  }

  private radius(): BorderRadiuses {
    const h = this.spec.h;
    return {
      topLeft: Math.round(h * 0.72),
      topRight: Math.round(h * 0.95),
      bottomLeft: Math.round(h * 0.95),
      bottomRight: Math.round(h * 0.22)
    };
  }

  build() {
    Blank()
      .width(this.spec.w)
      .height(this.spec.h)
      .borderRadius(this.radius())
      .linearGradient({ angle: 135, colors: this.colors() })
      .position({ x: this.spec.x, y: this.spec.y })
      .translate({
        x: this.launched ? this.spec.dx : 0,
        y: this.launched ? this.spec.dy : 0
      })
      .rotate({ angle: this.launched ? this.spec.endAngle : this.spec.startAngle })
      .opacity((this.darkMode ? this.spec.alpha * 0.85 : this.spec.alpha) * (this.dimmed ? 0.75 : 1))
      .animation({
        duration: this.spec.duration,
        delay: this.spec.delay,
        curve: Curve.Linear
      })
      .onAppear(() => {
        if (this.launched) return;
        this.timerId = setTimeout(() => {
          this.timerId = -1;
          this.launched = true;
        }, 20);
      })
  }
}

const FULL_PETALS: PetalSpec[] = [
  { id: 'p1', startX: '18%', w: 15, h: 10, startAngle: -20, endAngle: 260, driftX: -54, duration: 9400, delay: 0, alpha: 0.56, tint: 0 },
  { id: 'p2', startX: '34%', w: 12, h: 8, startAngle: 15, endAngle: -240, driftX: -68, duration: 10800, delay: 1300, alpha: 0.46, tint: 1 },
  { id: 'p3', startX: '52%', w: 18, h: 12, startAngle: -35, endAngle: 280, driftX: -82, duration: 10200, delay: 2700, alpha: 0.52, tint: 2 },
  { id: 'p4', startX: '68%', w: 13, h: 9, startAngle: 28, endAngle: 310, driftX: -64, duration: 8800, delay: 600, alpha: 0.48, tint: 0 },
  { id: 'p5', startX: '82%', w: 20, h: 13, startAngle: -14, endAngle: -270, driftX: -96, duration: 11800, delay: 2000, alpha: 0.58, tint: 1 },
  { id: 'p6', startX: '92%', w: 14, h: 9, startAngle: 42, endAngle: 320, driftX: -78, duration: 9200, delay: 3700, alpha: 0.50, tint: 2 },
  { id: 'p7', startX: '26%', w: 11, h: 7, startAngle: -45, endAngle: 230, driftX: -48, duration: 10600, delay: 5000, alpha: 0.44, tint: 1 },
  { id: 'p8', startX: '60%', w: 16, h: 11, startAngle: 10, endAngle: -255, driftX: -72, duration: 11400, delay: 6400, alpha: 0.54, tint: 0 },
  { id: 'p9', startX: '86%', w: 13, h: 8, startAngle: -28, endAngle: 285, driftX: -88, duration: 9600, delay: 7600, alpha: 0.48, tint: 2 },
  { id: 'p10', startX: '44%', w: 14, h: 9, startAngle: 36, endAngle: -220, driftX: -60, duration: 10000, delay: 4300, alpha: 0.46, tint: 0 },
  { id: 'p11', startX: '75%', w: 11, h: 7, startAngle: -10, endAngle: 260, driftX: -66, duration: 8600, delay: 8200, alpha: 0.44, tint: 1 },
  { id: 'p12', startX: '96%', w: 17, h: 11, startAngle: 22, endAngle: -290, driftX: -102, duration: 11200, delay: 1000, alpha: 0.52, tint: 2 }
];

const COMPACT_PETALS: PetalSpec[] = [
  { id: 'c1', startX: '18%', w: 11, h: 7, startAngle: -24, endAngle: 210, driftX: -22, duration: 4800, delay: 0, alpha: 0.72, tint: 0 },
  { id: 'c2', startX: '44%', w: 9, h: 6, startAngle: 18, endAngle: -190, driftX: -26, duration: 5400, delay: 1100, alpha: 0.62, tint: 1 },
  { id: 'c3', startX: '70%', w: 12, h: 8, startAngle: -32, endAngle: 230, driftX: -30, duration: 5000, delay: 2200, alpha: 0.68, tint: 2 },
  { id: 'c4', startX: '88%', w: 10, h: 6, startAngle: 28, endAngle: -220, driftX: -28, duration: 4600, delay: 600, alpha: 0.66, tint: 0 },
  { id: 'c5', startX: '56%', w: 10, h: 7, startAngle: -12, endAngle: 200, driftX: -20, duration: 5600, delay: 3200, alpha: 0.60, tint: 1 }
];

@Component
export struct SakuraPetals {
  @Prop darkMode: boolean = false;
  @Prop compact: boolean = false;
  @Prop dimmed: boolean = false;
  @Prop @Watch('onBurstChange') burstSeq: number = 0;
  @Prop burstKind: string = 'send';
  @Prop @Watch('onBloomChange') bloomSeq: number = 0;
  @Prop bloomX: number = 0;
  @Prop bloomY: number = 0;

  @State private drifting: boolean = false;
  @State private swaying: boolean = false;
  @State private areaWidth: number = 390;
  @State private areaHeight: number = 0;
  @State private transients: TransientPetal[] = [];

  private startTimer: number = -1;
  private effectTimers: number[] = [];

  aboutToDisappear(): void {
    if (this.startTimer !== -1) {
      clearTimeout(this.startTimer);
      this.startTimer = -1;
    }
    for (const timer of this.effectTimers) clearTimeout(timer);
    this.effectTimers = [];
  }

  private scheduleTimer(fn: () => void, ms: number): void {
    const id = setTimeout(() => {
      this.effectTimers = this.effectTimers.filter((item: number): boolean => item !== id);
      fn();
    }, ms);
    this.effectTimers.push(id);
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

  private onBurstChange(): void {
    if (this.compact || this.burstSeq <= 0) return;
    const celebrate = this.burstKind === 'celebrate';
    const count = celebrate ? 14 : 6;
    const width = Math.max(300, this.areaWidth);
    const bottomY = this.travelY();
    const batch: TransientPetal[] = [];
    let maxEndMs = 0;
    for (let i = 0; i < count; i += 1) {
      const ratio = count > 1 ? i / (count - 1) : 0.5;
      // 花瓣从右上角樱花树枝区域飘出，并完整落到底部之外。
      const startX = celebrate
        ? width * (0.28 + ratio * 0.70)
        : width * (0.58 + ratio * 0.38);
      const startY = celebrate
        ? 10 + (i % 4) * 34
        : 24 + (i % 3) * 42;
      const dy = Math.max(260, bottomY - startY);
      const speed = celebrate ? (210 + (i % 4) * 28) : (190 + (i % 3) * 24);
      const duration = Math.round((dy / speed) * 1000);
      const delay = i * (celebrate ? 90 : 75);
      if (duration + delay > maxEndMs) maxEndMs = duration + delay;
      const w = 11 + (i % 4) * 3;
      const h = Math.round(w * 0.66);
      batch.push({
        id: `burst-${this.burstSeq}-${i}`,
        x: startX,
        y: startY,
        dx: -(65 + (i % 5) * 32),
        dy: dy,
        w: w,
        h: h,
        startAngle: -30 + (i % 6) * 18,
        endAngle: (i % 2 === 0 ? 1 : -1) * (240 + (i % 4) * 55),
        duration: duration,
        delay: delay,
        alpha: celebrate ? 0.88 : 0.78,
        tint: i % 3
      });
    }
    this.launchTransients(batch, maxEndMs + 220);
  }

  private onBloomChange(): void {
    if (this.compact || this.bloomSeq <= 0) return;
    const offsetsX: number[] = [-48, -22, 4, 28, 52];
    const bottomY = this.travelY();
    const batch: TransientPetal[] = [];
    let maxEndMs = 0;
    for (let i = 0; i < 5; i += 1) {
      const dy = Math.max(180, bottomY - this.bloomY);
      const speed = 175 + (i % 3) * 26;
      const duration = Math.round((dy / speed) * 1000);
      const delay = i * 45;
      if (duration + delay > maxEndMs) maxEndMs = duration + delay;
      const w = 12 + (i % 3) * 2;
      const h = Math.round(w * 0.68);
      batch.push({
        id: `bloom-${this.bloomSeq}-${i}`,
        x: this.bloomX,
        y: this.bloomY,
        dx: offsetsX[i] - 24,
        dy: dy,
        w: w,
        h: h,
        startAngle: -20 + i * 24,
        endAngle: (i % 2 === 0 ? 1 : -1) * (210 + i * 35),
        duration: duration,
        delay: delay,
        alpha: 0.88,
        tint: i % 3
      });
    }
    this.launchTransients(batch, maxEndMs + 220);
  }

  private launchTransients(batch: TransientPetal[], cleanupMs: number): void {
    const ids = new Set<string>(batch.map((item: TransientPetal): string => item.id));
    this.transients = this.transients.slice(-28).concat(batch);
    this.scheduleTimer(() => {
      this.transients = this.transients.filter((item: TransientPetal): boolean => !ids.has(item.id));
    }, cleanupMs);
  }

  private petals(): PetalSpec[] {
    return this.compact ? COMPACT_PETALS : FULL_PETALS;
  }

  private travelY(): number {
    if (this.compact) return Math.max(this.areaHeight, 150) + 32;
    return Math.max(this.areaHeight, 1000) + 84;
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
          .opacity((this.darkMode ? spec.alpha * 0.68 : spec.alpha) * (this.dimmed ? 0.62 : 1))
          .position({ x: spec.startX, y: this.compact ? -16 : -30 })
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

      ForEach(this.transients, (item: TransientPetal) => {
        BurstPetal({ spec: item, darkMode: this.darkMode, dimmed: this.dimmed })
      }, (item: TransientPetal) => item.id)

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
      const w = Number(newArea.width);
      const h = Number(newArea.height);
      if (w > 0 && Math.abs(w - this.areaWidth) > 8) this.areaWidth = w;
      if (h > 0 && Math.abs(h - this.areaHeight) > 8) this.areaHeight = h;
    })
    .onAppear(() => {
      this.startMotion();
    })
  }
}

interface GirlReaction {
  id: string;
  symbol: string;
  x: string;
  y: string;
  dx: number;
  dy: number;
  size: number;
  delay: number;
}

@Component
struct GirlReactionPop {
  @Prop spec: GirlReaction;
  @Prop darkMode: boolean = false;
  @State private popped: boolean = false;
  private timerId: number = -1;

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    Text(this.spec.symbol)
      .fontSize(this.spec.size)
      .fontColor(this.darkMode ? '#FFB4D0' : '#E85A92')
      .position({ x: this.spec.x, y: this.spec.y })
      .translate({ x: this.popped ? this.spec.dx : 0, y: this.popped ? this.spec.dy : 0 })
      .scale({ x: this.popped ? 1.15 : 0.45, y: this.popped ? 1.15 : 0.45 })
      .opacity(this.popped ? 0 : 0.92)
      .animation({
        duration: 900,
        delay: this.spec.delay,
        curve: Curve.EaseOut
      })
      .onAppear(() => {
        if (this.popped) return;
        this.timerId = setTimeout(() => {
          this.timerId = -1;
          this.popped = true;
        }, 20);
      })
  }
}

@Component
export struct SakuraScene {
  @Prop darkMode: boolean = false;
  @Prop sceneOpacity: number = 0.92;
  @Prop @Watch('onGirlTap') girlTapSeq: number = 0;
  @Prop @Watch('onCelebrate') celebrateSeq: number = 0;

  @State private blinkOpacity: number = 0;
  @State private blinkDuration: number = 180;
  @State private happyOpacity: number = 0;
  @State private happyDuration: number = 240;
  @State private reactions: GirlReaction[] = [];

  private blinkLoopTimer: number = -1;
  private blinkStepTimers: number[] = [];
  private happyTimers: number[] = [];
  private reactionTimers: number[] = [];
  private blinkCycle: number = 0;

  aboutToDisappear(): void {
    if (this.blinkLoopTimer !== -1) {
      clearTimeout(this.blinkLoopTimer);
      this.blinkLoopTimer = -1;
    }
    for (const timer of this.blinkStepTimers) clearTimeout(timer);
    this.blinkStepTimers = [];
    for (const timer of this.happyTimers) clearTimeout(timer);
    this.happyTimers = [];
    for (const timer of this.reactionTimers) clearTimeout(timer);
    this.reactionTimers = [];
  }

  private scheduleNextBlink(): void {
    if (this.blinkLoopTimer !== -1) clearTimeout(this.blinkLoopTimer);
    const intervals: number[] = [3400, 4300, 2900, 4700];
    const waitMs = intervals[this.blinkCycle % intervals.length];
    this.blinkLoopTimer = setTimeout(() => {
      this.blinkLoopTimer = -1;
      this.blinkCycle += 1;
      if (this.happyOpacity < 0.1) {
        this.playBlink(this.blinkCycle % 3 === 0);
      }
      this.scheduleNextBlink();
    }, waitMs);
  }

  private playBlink(doubleBlink: boolean): void {
    for (const timer of this.blinkStepTimers) clearTimeout(timer);
    this.blinkStepTimers = [];
    this.blinkDuration = 160;
    this.blinkOpacity = 1;
    const t1 = setTimeout(() => {
      this.blinkDuration = 220;
      this.blinkOpacity = 0;
    }, 320);
    this.blinkStepTimers.push(t1);
    if (doubleBlink) {
      const t2 = setTimeout(() => {
        if (this.happyOpacity > 0.1) return;
        this.blinkDuration = 140;
        this.blinkOpacity = 1;
      }, 640);
      const t3 = setTimeout(() => {
        this.blinkDuration = 220;
        this.blinkOpacity = 0;
      }, 900);
      this.blinkStepTimers.push(t2, t3);
    }
  }

  private triggerHappyExpression(withReactions: boolean): void {
    for (const timer of this.happyTimers) clearTimeout(timer);
    this.happyTimers = [];
    // 先用极短的眨眼帧做自然过渡，再平滑淡入开心弯眼笑帧，避免生硬切图。
    this.blinkDuration = 90;
    this.blinkOpacity = 0.7;
    const t1 = setTimeout(() => {
      this.happyDuration = 240;
      this.happyOpacity = 1;
      this.blinkDuration = 160;
      this.blinkOpacity = 0;
    }, 85);
    const t2 = setTimeout(() => {
      this.happyDuration = 420;
      this.happyOpacity = 0;
    }, 1850);
    this.happyTimers.push(t1, t2);

    if (withReactions) {
      const seq = this.girlTapSeq + this.celebrateSeq;
      const batch: GirlReaction[] = [
        { id: `gr-${seq}-0`, symbol: '✿', x: '70%', y: '58%', dx: -16, dy: -46, size: 17, delay: 40 },
        { id: `gr-${seq}-1`, symbol: '♡', x: '84%', y: '56%', dx: 14, dy: -52, size: 15, delay: 110 },
        { id: `gr-${seq}-2`, symbol: '✦', x: '60%', y: '65%', dx: -22, dy: -38, size: 13, delay: 160 }
      ];
      const ids = new Set<string>(batch.map((item: GirlReaction): string => item.id));
      this.reactions = this.reactions.slice(-9).concat(batch);
      const cleanup = setTimeout(() => {
        this.reactionTimers = this.reactionTimers.filter((item: number): boolean => item !== cleanup);
        this.reactions = this.reactions.filter((item: GirlReaction): boolean => !ids.has(item.id));
      }, 1200);
      this.reactionTimers.push(cleanup);
    }
  }

  private onGirlTap(): void {
    if (this.girlTapSeq <= 0) return;
    this.triggerHappyExpression(true);
  }

  private onCelebrate(): void {
    if (this.celebrateSeq <= 0) return;
    this.triggerHappyExpression(true);
  }

  private idleSource(): Resource {
    return $rawfile(this.darkMode ? 'sakura_dark.jpg' : 'sakura_light.jpg');
  }

  private blinkSource(): Resource {
    return $rawfile(this.darkMode ? 'sakura_dark_blink.jpg' : 'sakura_light_blink.jpg');
  }

  private happySource(): Resource {
    return $rawfile(this.darkMode ? 'sakura_dark_happy.jpg' : 'sakura_light_happy.jpg');
  }

  build() {
    Stack() {
      Image(this.idleSource())
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .syncLoad(true)

      Image(this.blinkSource())
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .syncLoad(true)
        .opacity(this.blinkOpacity)
        .animation({ duration: this.blinkDuration, curve: Curve.EaseInOut })

      Image(this.happySource())
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .syncLoad(true)
        .opacity(this.happyOpacity)
        .animation({ duration: this.happyDuration, curve: Curve.EaseInOut })

      ForEach(this.reactions, (item: GirlReaction) => {
        GirlReactionPop({ spec: item, darkMode: this.darkMode })
      }, (item: GirlReaction) => item.id)
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .opacity(this.sceneOpacity)
    .animation({ duration: 320, curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
    .onAppear(() => {
      this.scheduleNextBlink();
    })
  }
}
