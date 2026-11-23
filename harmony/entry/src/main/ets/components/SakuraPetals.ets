import { image } from '@kit.ImageKit';

interface CompactPetalSpec {
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

const COMPACT_PETALS: CompactPetalSpec[] = [
  { id: 'c1', startX: '18%', w: 11, h: 7, startAngle: -24, endAngle: 210, driftX: -22, duration: 4800, delay: 0, alpha: 0.72, tint: 0 },
  { id: 'c2', startX: '44%', w: 9, h: 6, startAngle: 18, endAngle: -190, driftX: -26, duration: 5400, delay: 1100, alpha: 0.62, tint: 1 },
  { id: 'c3', startX: '70%', w: 12, h: 8, startAngle: -32, endAngle: 230, driftX: -30, duration: 5000, delay: 2200, alpha: 0.68, tint: 2 },
  { id: 'c4', startX: '88%', w: 10, h: 6, startAngle: 28, endAngle: -220, driftX: -28, duration: 4600, delay: 600, alpha: 0.66, tint: 0 },
  { id: 'c5', startX: '56%', w: 10, h: 7, startAngle: -12, endAngle: 200, driftX: -20, duration: 5600, delay: 3200, alpha: 0.60, tint: 1 }
];

@Component
export struct SakuraPetals {
  @Prop darkMode: boolean = false;
  @Prop compact: boolean = true;
  @State private drifting: boolean = false;
  @State private areaHeight: number = 150;
  private startTimer: number = -1;

  aboutToDisappear(): void {
    if (this.startTimer !== -1) {
      clearTimeout(this.startTimer);
      this.startTimer = -1;
    }
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
      ForEach(COMPACT_PETALS, (spec: CompactPetalSpec) => {
        Blank()
          .width(spec.w)
          .height(spec.h)
          .borderRadius(this.petalRadius(spec.h))
          .linearGradient({ angle: 135, colors: this.petalColors(spec.tint) })
          .opacity(this.darkMode ? spec.alpha * 0.72 : spec.alpha)
          .position({ x: spec.startX, y: -16 })
          .translate({
            x: this.drifting ? spec.driftX : 0,
            y: this.drifting ? Math.max(this.areaHeight, 150) + 30 : 0
          })
          .rotate({ angle: this.drifting ? spec.endAngle : spec.startAngle })
          .animation({
            duration: spec.duration,
            delay: spec.delay,
            curve: Curve.Linear,
            iterations: -1,
            playMode: PlayMode.Normal
          })
      }, (spec: CompactPetalSpec) => spec.id)
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const h = Number(newArea.height);
      if (h > 40 && Math.abs(h - this.areaHeight) > 8) this.areaHeight = h;
    })
    .onAppear(() => {
      if (this.drifting) return;
      this.startTimer = setTimeout(() => {
        this.startTimer = -1;
        this.drifting = true;
      }, 32);
    })
  }
}

interface LivePetal {
  x: number;
  y: number;
  vx: number;
  vy: number;
  size: number;
  angle: number;
  vAngle: number;
  flip: number;
  vFlip: number;
  swayAmp: number;
  swayFreq: number;
  phase: number;
  alpha: number;
  tint: number;
  ambient: boolean;
}

interface BokehMote {
  nx: number;
  ny: number;
  radius: number;
  speedY: number;
  phase: number;
  alpha: number;
}

interface FloatingSpark {
  x: number;
  y: number;
  vx: number;
  vy: number;
  symbol: string;
  size: number;
  life: number;
  maxLife: number;
}

@Component
export struct SakuraScene {
  @Prop @Watch('onDarkModeChange') darkMode: boolean = false;
  @Prop sceneOpacity: number = 0.92;
  @Prop dimmed: boolean = false;
  @Prop @Watch('onGirlTap') girlTapSeq: number = 0;
  @Prop @Watch('onCelebrate') celebrateSeq: number = 0;
  @Prop @Watch('onBurstChange') burstSeq: number = 0;
  @Prop burstKind: string = 'send';
  @Prop @Watch('onBloomChange') bloomSeq: number = 0;
  @Prop bloomX: number = 0;
  @Prop bloomY: number = 0;

  @State private canvasReady: boolean = false;
  @State private pixelsReady: boolean = false;

  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private idleMap?: image.PixelMap;
  private happyMap?: image.PixelMap;
  private imgWidth: number = 0;
  private imgHeight: number = 0;
  private loadGen: number = 0;
  private loopTimer: number = -1;
  private elapsed: number = 0;
  private lastTickMs: number = 0;
  private canvasW: number = 0;
  private canvasH: number = 0;

  // 平滑互动状态（类 Wallpaper Engine 连续插值，无生硬跳变）
  private happyTarget: number = 0;
  private happyBlend: number = 0;
  private happyHoldTimer: number = -1;
  private windGust: number = 0;

  private petals: LivePetal[] = [];
  private motes: BokehMote[] = [];
  private sparks: FloatingSpark[] = [];

  aboutToAppear(): void {
    this.initMotes();
    void this.loadBitmaps();
  }

  aboutToDisappear(): void {
    this.loadGen += 1;
    this.stopLoop();
    if (this.happyHoldTimer !== -1) {
      clearTimeout(this.happyHoldTimer);
      this.happyHoldTimer = -1;
    }
    this.releaseBitmaps();
  }

  private releaseBitmaps(): void {
    if (this.idleMap) {
      void this.idleMap.release();
      this.idleMap = undefined;
    }
    if (this.happyMap) {
      void this.happyMap.release();
      this.happyMap = undefined;
    }
    this.pixelsReady = false;
  }

  private onDarkModeChange(): void {
    void this.loadBitmaps();
  }

  private async decodeRaw(name: string): Promise<image.PixelMap | undefined> {
    const context = this.getUIContext().getHostContext();
    if (!context) return undefined;
    let source: image.ImageSource | undefined;
    try {
      const bytes = await context.resourceManager.getRawFileContent(name);
      const copy = new Uint8Array(bytes.byteLength);
      copy.set(bytes);
      source = image.createImageSource(copy.buffer as ArrayBuffer);
      return await source.createPixelMap();
    } catch {
      return undefined;
    } finally {
      if (source) {
        try { await source.release(); } catch {}
      }
    }
  }

  private async loadBitmaps(): Promise<void> {
    const gen = ++this.loadGen;
    const idleName = this.darkMode ? 'sakura_dark.jpg' : 'sakura_light.jpg';
    const happyName = this.darkMode ? 'sakura_dark_happy.jpg' : 'sakura_light_happy.jpg';
    const loadedIdle = await this.decodeRaw(idleName);
    if (gen !== this.loadGen) {
      if (loadedIdle) void loadedIdle.release();
      return;
    }
    const loadedHappy = await this.decodeRaw(happyName);
    if (gen !== this.loadGen) {
      if (loadedIdle) void loadedIdle.release();
      if (loadedHappy) void loadedHappy.release();
      return;
    }
    this.releaseBitmaps();
    this.idleMap = loadedIdle;
    this.happyMap = loadedHappy;
    if (loadedIdle) {
      try {
        const info = await loadedIdle.getImageInfo();
        this.imgWidth = info.size.width;
        this.imgHeight = info.size.height;
      } catch {
        this.imgWidth = 768;
        this.imgHeight = 1376;
      }
      this.pixelsReady = true;
    }
    this.ensureLoop();
  }

  private initMotes(): void {
    this.motes = [
      { nx: 0.14, ny: 0.22, radius: 14, speedY: 0.012, phase: 0.4, alpha: 0.22 },
      { nx: 0.28, ny: 0.64, radius: 18, speedY: 0.010, phase: 1.7, alpha: 0.18 },
      { nx: 0.46, ny: 0.36, radius: 11, speedY: 0.015, phase: 2.8, alpha: 0.20 },
      { nx: 0.72, ny: 0.24, radius: 16, speedY: 0.011, phase: 4.1, alpha: 0.24 },
      { nx: 0.84, ny: 0.52, radius: 12, speedY: 0.014, phase: 5.2, alpha: 0.20 },
      { nx: 0.62, ny: 0.78, radius: 15, speedY: 0.012, phase: 0.9, alpha: 0.18 },
      { nx: 0.18, ny: 0.86, radius: 20, speedY: 0.009, phase: 3.5, alpha: 0.16 }
    ];
  }

  private initAmbientPetals(w: number, h: number): void {
    if (this.petals.some((p: LivePetal): boolean => p.ambient)) return;
    for (let i = 0; i < 14; i += 1) {
      this.petals.push(this.makeAmbientPetal(w, h, (i / 14) * (h + 40) - 20, i));
    }
  }

  private makeAmbientPetal(w: number, h: number, y: number, seed: number): LivePetal {
    const depth = (seed % 3); // 0 = 远景小花瓣, 1 = 中景, 2 = 近景大花瓣
    const size = depth === 0 ? 5.2 : depth === 1 ? 7.2 : 9.4;
    const speedY = depth === 0 ? 34 : depth === 1 ? 48 : 64;
    const xRatio = ((seed * 0.29 + 0.17) % 1.08);
    return {
      x: w * xRatio,
      y: y,
      vx: -(10 + depth * 6),
      vy: speedY + (seed % 4) * 5,
      size: size,
      angle: (seed * 0.9) % 6.28,
      vAngle: (seed % 2 === 0 ? 1 : -1) * (0.9 + (seed % 3) * 0.45),
      flip: seed * 1.1,
      vFlip: 1.6 + (seed % 4) * 0.55,
      swayAmp: 12 + depth * 7,
      swayFreq: 1.1 + (seed % 3) * 0.35,
      phase: seed * 1.3,
      alpha: depth === 0 ? 0.36 : depth === 1 ? 0.50 : 0.62,
      tint: seed % 3,
      ambient: true
    };
  }

  private triggerHappy(): void {
    this.happyTarget = 1;
    this.windGust = Math.max(this.windGust, 0.85);
    if (this.happyHoldTimer !== -1) clearTimeout(this.happyHoldTimer);
    this.happyHoldTimer = setTimeout(() => {
      this.happyHoldTimer = -1;
      this.happyTarget = 0;
    }, 1850);

    const w = this.canvasW > 0 ? this.canvasW : 390;
    const h = this.canvasH > 0 ? this.canvasH : 840;
    this.sparks.push(
      { x: w * 0.68, y: h * 0.60, vx: -14, vy: -34, symbol: '✿', size: 17, life: 0, maxLife: 1.25 },
      { x: w * 0.83, y: h * 0.57, vx: 12, vy: -38, symbol: '♡', size: 15, life: 0, maxLife: 1.35 },
      { x: w * 0.59, y: h * 0.66, vx: -18, vy: -28, symbol: '✦', size: 13, life: 0, maxLife: 1.15 }
    );
  }

  private onGirlTap(): void {
    if (this.girlTapSeq <= 0) return;
    this.triggerHappy();
  }

  private onCelebrate(): void {
    if (this.celebrateSeq <= 0) return;
    this.triggerHappy();
  }

  private onBurstChange(): void {
    if (this.burstSeq <= 0) return;
    const celebrate = this.burstKind === 'celebrate';
    this.windGust = Math.max(this.windGust, celebrate ? 1.0 : 0.65);
    const w = this.canvasW > 0 ? this.canvasW : 390;
    const count = celebrate ? 16 : 7;
    for (let i = 0; i < count; i += 1) {
      const ratio = count > 1 ? i / (count - 1) : 0.5;
      const startX = celebrate ? w * (0.24 + ratio * 0.78) : w * (0.58 + ratio * 0.40);
      const startY = celebrate ? -10 + (i % 4) * 32 : 16 + (i % 3) * 36;
      this.petals.push({
        x: startX,
        y: startY,
        vx: -(22 + (i % 4) * 9),
        vy: celebrate ? (92 + (i % 4) * 18) : (78 + (i % 3) * 15),
        size: 6.5 + (i % 4) * 1.4,
        angle: i * 0.8,
        vAngle: (i % 2 === 0 ? 1 : -1) * (1.8 + (i % 3) * 0.5),
        flip: i * 0.9,
        vFlip: 2.4 + (i % 3) * 0.6,
        swayAmp: 18 + (i % 3) * 8,
        swayFreq: 1.5 + (i % 3) * 0.3,
        phase: i * 1.1,
        alpha: celebrate ? 0.84 : 0.76,
        tint: i % 3,
        ambient: false
      });
    }
  }

  private onBloomChange(): void {
    if (this.bloomSeq <= 0) return;
    const vxList: number[] = [-42, -20, 4, 24, 44];
    const vyList: number[] = [46, 36, 54, 40, 50];
    for (let i = 0; i < 5; i += 1) {
      this.petals.push({
        x: this.bloomX,
        y: this.bloomY,
        vx: vxList[i] - 10,
        vy: vyList[i] + 22,
        size: 6.4 + (i % 3) * 1.3,
        angle: i * 1.2,
        vAngle: (i % 2 === 0 ? 1 : -1) * (2.0 + i * 0.25),
        flip: i * 0.7,
        vFlip: 2.6 + (i % 3) * 0.5,
        swayAmp: 15 + i * 3,
        swayFreq: 1.6 + (i % 2) * 0.4,
        phase: i * 0.9,
        alpha: 0.86,
        tint: i % 3,
        ambient: false
      });
    }
  }

  private ensureLoop(): void {
    if (!this.canvasReady || this.loopTimer !== -1) return;
    this.lastTickMs = Date.now();
    this.loopTimer = setInterval(() => {
      this.tickFrame();
    }, 33);
    this.tickFrame();
  }

  private stopLoop(): void {
    if (this.loopTimer !== -1) {
      clearInterval(this.loopTimer);
      this.loopTimer = -1;
    }
  }

  private tickFrame(): void {
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    this.canvasW = w;
    this.canvasH = h;
    this.initAmbientPetals(w, h);

    const now = Date.now();
    const dt = Math.min(0.06, Math.max(0.01, (now - this.lastTickMs) / 1000));
    this.lastTickMs = now;
    this.elapsed += dt;

    // 平滑插值表情融合与微风阵风，完全无帧跳变
    const blendRate = this.happyTarget > this.happyBlend ? 2.6 : 1.7;
    if (this.happyBlend < this.happyTarget) {
      this.happyBlend = Math.min(this.happyTarget, this.happyBlend + dt * blendRate);
    } else if (this.happyBlend > this.happyTarget) {
      this.happyBlend = Math.max(this.happyTarget, this.happyBlend - dt * blendRate);
    }
    if (this.windGust > 0) {
      this.windGust = Math.max(0, this.windGust - dt * 0.55);
    }

    this.ctx.clearRect(0, 0, w, h);

    // 1. 类 Wallpaper Engine 连续正弦网格形变渲染背景（樱花枝随风柔摆 + 少女自然呼吸与发丝微动）
    if (this.idleMap && this.imgWidth > 0 && this.imgHeight > 0) {
      this.drawWarpedImage(this.idleMap, w, h, 1);
      if (this.happyMap && this.happyBlend > 0.01) {
        this.drawWarpedImage(this.happyMap, w, h, this.happyBlend);
      }
    }

    // 2. 柔和漂浮的氛围光斑
    this.drawMotes(w, h, dt);

    // 3. 3D 翻飞樱花瓣（完整落出屏幕底部，永不半空消失）
    this.updateAndDrawPetals(w, h, dt);

    // 4. 点击少女时的微光点缀
    this.updateAndDrawSparks(dt);
  }

  private drawWarpedImage(bitmap: image.PixelMap, w: number, h: number, alpha: number): void {
    const imgRatio = this.imgWidth / this.imgHeight;
    const viewRatio = w / h;
    const wideScreen = viewRatio > imgRatio;
    let drawW = w;
    let drawH = h;
    let drawX = 0;
    let drawY = 0;
    if (wideScreen) {
      // 折叠屏展开 / 平板 / 横屏：按高度完整适配并靠右对齐，保留完整樱花树与少女不裁切，左侧自然延展天空留白。
      drawH = h;
      drawW = h * imgRatio;
      drawX = w - drawW;
      drawY = 0;
    } else {
      drawH = h;
      drawW = h * imgRatio;
      drawX = (w - drawW) * 0.5;
      drawY = 0;
    }

    const strips = 36;
    const dstStripH = h / strips;
    const t = this.elapsed;
    const gustBoost = 1 + this.windGust * 0.55;
    const padX = 8;

    this.ctx.save();
    this.ctx.globalAlpha = alpha;
    for (let i = 0; i < strips; i += 1) {
      const v = (i + 0.5) / strips;
      let dx = 0;
      let dy = 0;

      // 上部樱花枝区域 (0 ~ 0.46)：平滑钟形权重，顶端枝叶随微风柔摆，中部天空自然归零无接缝
      if (v < 0.46) {
        const treeWeight = Math.sin((v / 0.46) * Math.PI);
        dx += Math.sin(t * 1.15 + v * 5.2) * 3.4 * treeWeight * gustBoost;
        dy += Math.cos(t * 0.9 + v * 3.4) * 1.2 * treeWeight * gustBoost;
      }

      // 下部少女区域 (0.50 ~ 1.0)：底部锚定不悬空，肩颈与长发呈柔和呼吸起伏与发丝微风波纹
      if (v > 0.50) {
        const local = (v - 0.50) / 0.50;
        const env = Math.sin(local * Math.PI);
        dy += -Math.sin(t * 1.45) * 1.9 * env;
        dx += Math.sin(t * 1.25 + local * 4.4) * 2.1 * env * gustBoost;
      }

      const stripY = i * dstStripH;
      this.ctx.save();
      this.ctx.beginPath();
      this.ctx.rect(wideScreen ? Math.max(0, drawX - 2) : 0, stripY, wideScreen ? (w - Math.max(0, drawX - 2)) : w, dstStripH + 1.2);
      this.ctx.clip();
      this.ctx.drawImage(
        bitmap,
        drawX - padX + dx,
        drawY + dy,
        drawW + padX * 2,
        drawH
      );
      this.ctx.restore();
    }

    // 宽屏模式下在画作左边缘叠加柔和羽化过渡，使画作无缝融入左侧天空画布
    if (wideScreen && drawX > 0) {
      const featherW = Math.min(84, drawW * 0.22);
      const edgeGrad = this.ctx.createLinearGradient(drawX, 0, drawX + featherW, 0);
      if (this.darkMode) {
        edgeGrad.addColorStop(0, 'rgba(28, 18, 23, 1)');
        edgeGrad.addColorStop(1, 'rgba(28, 18, 23, 0)');
      } else {
        edgeGrad.addColorStop(0, 'rgba(255, 246, 249, 1)');
        edgeGrad.addColorStop(1, 'rgba(255, 246, 249, 0)');
      }
      this.ctx.fillStyle = edgeGrad;
      this.ctx.fillRect(drawX - 1, 0, featherW + 2, h);
    }
    this.ctx.restore();
  }

  private drawMotes(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    const dimFactor = this.dimmed ? 0.55 : 1;
    this.ctx.save();
    for (const m of this.motes) {
      m.ny -= m.speedY * dt;
      if (m.ny < -0.06) m.ny = 1.06;
      const x = (m.nx + Math.sin(t * 0.55 + m.phase) * 0.025) * w;
      const y = m.ny * h;
      const pulse = 0.55 + 0.45 * Math.sin(t * 1.3 + m.phase);
      const a = m.alpha * pulse * dimFactor;
      const grad = this.ctx.createRadialGradient(x, y, 0, x, y, m.radius);
      if (this.darkMode) {
        grad.addColorStop(0, `rgba(255, 184, 214, ${a.toFixed(3)})`);
        grad.addColorStop(1, 'rgba(255, 184, 214, 0)');
      } else {
        grad.addColorStop(0, `rgba(255, 255, 255, ${(a * 1.4).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(255, 224, 238, 0)');
      }
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(x, y, m.radius, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
  }

  private updateAndDrawPetals(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    const gustX = -this.windGust * 38;
    const dimFactor = this.dimmed ? 0.68 : 1;
    const kept: LivePetal[] = [];

    for (let i = 0; i < this.petals.length; i += 1) {
      const p = this.petals[i];
      const flutterX = Math.sin(t * p.swayFreq + p.phase) * p.swayAmp;
      p.x += (p.vx + flutterX + gustX) * dt;
      p.y += p.vy * dt;
      p.angle += p.vAngle * dt;
      p.flip += p.vFlip * dt;

      if (p.y > h + 28) {
        if (p.ambient) {
          p.y = -20 - (i % 4) * 14;
          p.x = w * (0.12 + ((i * 0.23 + (t * 0.07)) % 0.96));
          kept.push(p);
        }
        continue;
      }
      if (p.x < -36) {
        if (p.ambient) p.x = w + 22;
      }
      kept.push(p);
      this.drawSakuraPetal(p, dimFactor);
    }
    this.petals = kept;
  }

  private drawSakuraPetal(p: LivePetal, dimFactor: number): void {
    const scaleY = 0.36 + 0.64 * Math.abs(Math.cos(p.flip));
    const s = p.size;
    const alpha = (this.darkMode ? p.alpha * 0.82 : p.alpha) * dimFactor;

    this.ctx.save();
    this.ctx.translate(p.x, p.y);
    this.ctx.rotate(p.angle);
    this.ctx.scale(1, scaleY);
    this.ctx.globalAlpha = alpha;

    // 经典樱花缺口花瓣轮廓（贝塞尔曲线）
    this.ctx.beginPath();
    this.ctx.moveTo(0, s);
    this.ctx.bezierCurveTo(-s * 0.95, s * 0.45, -s * 0.85, -s * 0.72, -s * 0.22, -s * 0.95);
    this.ctx.lineTo(0, -s * 0.62);
    this.ctx.lineTo(s * 0.22, -s * 0.95);
    this.ctx.bezierCurveTo(s * 0.85, -s * 0.72, s * 0.95, s * 0.45, 0, s);
    this.ctx.closePath();

    const grad = this.ctx.createLinearGradient(0, -s, 0, s);
    if (this.darkMode) {
      if (p.tint === 1) {
        grad.addColorStop(0, '#FFD4E6');
        grad.addColorStop(1, '#F278AA');
      } else if (p.tint === 2) {
        grad.addColorStop(0, '#FFE4F0');
        grad.addColorStop(1, '#E86B9D');
      } else {
        grad.addColorStop(0, '#FFC4DC');
        grad.addColorStop(1, '#F06B9E');
      }
    } else {
      if (p.tint === 1) {
        grad.addColorStop(0, '#FFF2F8');
        grad.addColorStop(1, '#FF96BE');
      } else if (p.tint === 2) {
        grad.addColorStop(0, '#FFFFFF');
        grad.addColorStop(1, '#FFB4D2');
      } else {
        grad.addColorStop(0, '#FFE6F1');
        grad.addColorStop(1, '#FF8CB8');
      }
    }
    this.ctx.fillStyle = grad;
    this.ctx.fill();
    this.ctx.restore();
  }

  private updateAndDrawSparks(dt: number): void {
    if (!this.sparks.length) return;
    const next: FloatingSpark[] = [];
    this.ctx.save();
    for (const s of this.sparks) {
      s.life += dt;
      if (s.life >= s.maxLife) continue;
      s.x += s.vx * dt;
      s.y += s.vy * dt;
      const progress = s.life / s.maxLife;
      const alpha = progress < 0.2 ? (progress / 0.2) : (1 - (progress - 0.2) / 0.8);
      this.ctx.globalAlpha = Math.max(0, Math.min(1, alpha));
      this.ctx.fillStyle = this.darkMode ? '#FFB4D0' : '#E85A92';
      this.ctx.font = `${Math.round(s.size)}vp sans-serif`;
      this.ctx.fillText(s.symbol, s.x, s.y);
      next.push(s);
    }
    this.ctx.restore();
    this.sparks = next;
  }

  build() {
    Stack() {
      // 底层静态图兜底，确保首帧零白屏
      if (!this.pixelsReady) {
        Image($rawfile(this.darkMode ? 'sakura_dark.jpg' : 'sakura_light.jpg'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      }
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.canvasReady = true;
          this.ensureLoop();
        })
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .opacity(this.sceneOpacity)
    .animation({ duration: 320, curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
  }
}
