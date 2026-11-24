import { image } from '@kit.ImageKit';

interface SunMote {
  x: number;
  y: number;
  vx: number;
  vy: number;
  radius: number;
  phase: number;
  alpha: number;
  ambient: boolean;
}

interface SeaGlint {
  nx: number;
  ny: number;
  width: number;
  phase: number;
  speed: number;
}

interface SunRipple {
  x: number;
  y: number;
  radius: number;
  maxRadius: number;
  speed: number;
  alpha: number;
}

@ComponentV2
export struct SunsetScene {
  @Param darkMode: boolean = false;
  @Param sceneOpacity: number = 0.92;
  @Param dimmed: boolean = false;
  @Param active: boolean = true;
  @Param compact: boolean = false;
  @Param burstSeq: number = 0;
  @Param burstKind: string = 'send';
  @Param tapSeq: number = 0;
  @Param tapX: number = 0;
  @Param tapY: number = 0;

  @Local private pixelsReady: boolean = false;

  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private sceneMap?: image.PixelMap;
  private imgWidth: number = 0;
  private imgHeight: number = 0;
  private loadGen: number = 0;
  private canvasReady: boolean = false;
  private loopTimer: number = -1;
  private loopIntervalMs: number = 33;
  private lastTickMs: number = 0;
  private elapsed: number = 0;
  private canvasW: number = 0;
  private canvasH: number = 0;
  private initialized: boolean = false;

  private breezeBoost: number = 0;
  private motes: SunMote[] = [];
  private glints: SeaGlint[] = [];
  private ripples: SunRipple[] = [];

  aboutToAppear(): void {
    void this.loadBitmap();
  }

  aboutToDisappear(): void {
    this.loadGen += 1;
    this.stopLoop();
    this.releaseBitmap();
  }

  private releaseBitmap(): void {
    if (this.sceneMap) {
      void this.sceneMap.release();
      this.sceneMap = undefined;
    }
    this.pixelsReady = false;
  }

  @Monitor('darkMode')
  private onDarkModeChange(): void {
    void this.loadBitmap();
  }

  private async loadBitmap(): Promise<void> {
    const gen = ++this.loadGen;
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    const name = this.darkMode ? 'sunset_dark.jpg' : 'sunset_light.jpg';
    let source: image.ImageSource | undefined;
    try {
      const bytes = await context.resourceManager.getRawFileContent(name);
      const copy = new Uint8Array(bytes.byteLength);
      copy.set(bytes);
      source = image.createImageSource(copy.buffer as ArrayBuffer);
      const loaded = await source.createPixelMap();
      if (gen !== this.loadGen) {
        void loaded.release();
        return;
      }
      this.releaseBitmap();
      this.sceneMap = loaded;
      try {
        const info = await loaded.getImageInfo();
        this.imgWidth = info.size.width;
        this.imgHeight = info.size.height;
      } catch {
        this.imgWidth = 768;
        this.imgHeight = 1376;
      }
      this.pixelsReady = true;
      this.ensureLoop();
    } catch {
      // 回退静态底层图
    } finally {
      if (source) {
        try { await source.release(); } catch {}
      }
    }
  }

  @Monitor('burstSeq')
  private onBurstChange(): void {
    if (this.compact || this.burstSeq <= 0) return;
    const celebrate = this.burstKind === 'celebrate';
    this.breezeBoost = Math.max(this.breezeBoost, celebrate ? 1.0 : 0.65);
    const w = this.canvasW > 0 ? this.canvasW : 390;
    const h = this.canvasH > 0 ? this.canvasH : 840;
    const count = celebrate ? 12 : 6;
    for (let i = 0; i < count; i += 1) {
      this.motes.push({
        x: w * (0.30 + (i / count) * 0.66),
        y: h * (0.48 + (i % 4) * 0.08),
        vx: -(12 + (i % 4) * 7),
        vy: -(24 + (i % 4) * 10),
        radius: 4.5 + (i % 3) * 2.2,
        phase: i * 1.1,
        alpha: celebrate ? 0.68 : 0.54,
        ambient: false
      });
    }
    this.ripples.push({
      x: w * 0.58, y: h * 0.56, radius: 8, maxRadius: celebrate ? 135 : 90, speed: 46, alpha: 0.45
    });
  }

  @Monitor('tapSeq')
  private onTapChange(): void {
    if (this.compact || this.tapSeq <= 0) return;
    this.breezeBoost = Math.max(this.breezeBoost, 0.55);
    const x = this.tapX > 0 ? this.tapX : (this.canvasW || 390) * 0.5;
    const y = this.tapY > 0 ? this.tapY : (this.canvasH || 840) * 0.5;
    this.ripples.push({ x: x, y: y, radius: 5, maxRadius: 105, speed: 58, alpha: 0.48 });
    const vxList: number[] = [-30, -14, 2, 18, 32];
    for (let i = 0; i < 5; i += 1) {
      this.motes.push({
        x: x + (i - 2) * 6,
        y: y,
        vx: vxList[i],
        vy: -(28 + (i % 3) * 12),
        radius: 4 + (i % 3) * 1.8,
        phase: i * 1.2,
        alpha: 0.66,
        ambient: false
      });
    }
  }

  @Monitor('dimmed', 'active')
  private onLoopPolicyChange(): void {
    if (!this.active) {
      this.stopLoop();
      return;
    }
    const desired = this.dimmed ? 50 : 33;
    if (this.loopTimer !== -1 && this.loopIntervalMs !== desired) {
      this.stopLoop();
    }
    this.ensureLoop();
  }

  private ensureLoop(): void {
    if (!this.canvasReady || !this.active || this.loopTimer !== -1) return;
    this.loopIntervalMs = this.dimmed ? 50 : 33;
    this.lastTickMs = Date.now();
    this.loopTimer = setInterval(() => {
      this.tick();
    }, this.loopIntervalMs);
    this.tick();
  }

  private stopLoop(): void {
    if (this.loopTimer !== -1) {
      clearInterval(this.loopTimer);
      this.loopTimer = -1;
    }
  }

  private initElements(w: number, h: number): void {
    if (this.initialized && this.canvasW > 0) return;
    this.initialized = true;
    this.motes = [];
    const count = this.compact ? 5 : 10;
    for (let i = 0; i < count; i += 1) {
      this.motes.push({
        x: w * (0.14 + ((i * 0.23) % 0.80)),
        y: (i / count) * h,
        vx: -(4 + (i % 3) * 3),
        vy: -(10 + (i % 4) * 4),
        radius: (this.compact ? 4 : 7) + (i % 4) * 2.5,
        phase: i * 1.3,
        alpha: 0.24 + (i % 3) * 0.08,
        ambient: true
      });
    }
    this.glints = [
      { nx: 0.56, ny: 0.52, width: 22, phase: 0.2, speed: 2.4 },
      { nx: 0.59, ny: 0.55, width: 28, phase: 1.4, speed: 2.1 },
      { nx: 0.54, ny: 0.58, width: 18, phase: 2.7, speed: 2.8 },
      { nx: 0.61, ny: 0.61, width: 24, phase: 3.9, speed: 2.3 },
      { nx: 0.52, ny: 0.64, width: 16, phase: 5.1, speed: 2.6 }
    ];
  }

  private tick(): void {
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    this.canvasW = w;
    this.canvasH = h;
    this.initElements(w, h);

    const now = Date.now();
    const dt = Math.min(0.06, Math.max(0.01, (now - this.lastTickMs) / 1000));
    this.lastTickMs = now;
    this.elapsed += dt;
    if (this.breezeBoost > 0) this.breezeBoost = Math.max(0, this.breezeBoost - dt * 0.55);

    this.ctx.clearRect(0, 0, w, h);

    if (this.sceneMap && this.imgWidth > 0 && this.imgHeight > 0) {
      this.drawWarpedSunset(this.sceneMap, w, h);
    }
    this.drawSeaGlints(w, h);
    this.updateAndDrawMotes(w, h, dt);
    this.updateAndDrawRipples(dt);
  }

  private drawWarpedSunset(bitmap: image.PixelMap, w: number, h: number): void {
    const imgRatio = this.imgWidth / this.imgHeight;
    const viewRatio = w / h;
    const wideScreen = viewRatio > imgRatio;
    const drawH = h;
    const drawW = h * imgRatio;
    const drawX = wideScreen ? (w - drawW) : (w - drawW) * 0.5;
    const drawY = 0;

    const t = this.elapsed;
    const gust = 1 + this.breezeBoost * 0.65;
    const padX = 8;
    const clipX = wideScreen ? Math.max(0, drawX - 2) : 0;
    const clipW = wideScreen ? (w - clipX) : w;

    // 1. 静态天空、海滩人群与底部留白一次性绘制，大幅降低每帧开销
    this.ctx.save();
    this.ctx.beginPath();
    this.ctx.rect(clipX, 0, clipW, h);
    this.ctx.clip();
    this.ctx.drawImage(bitmap, drawX, drawY, drawW, drawH);
    this.ctx.restore();

    // 2. 仅对上部加州棕榈叶 (0 ~ 0.34) 做 8 条带微风轻摇
    const palmStrips = this.compact ? 5 : 8;
    const palmBandH = h * 0.34;
    const palmStepH = palmBandH / palmStrips;
    for (let i = 0; i < palmStrips; i += 1) {
      const local = (i + 0.5) / palmStrips;
      const v = local * 0.34;
      const palmW = Math.sin(local * Math.PI);
      const dx = Math.sin(t * 1.05 + v * 5.2) * 3.0 * palmW * gust;
      const dy = Math.cos(t * 0.85 + v * 3.4) * 1.0 * palmW * gust;
      this.ctx.save();
      this.ctx.beginPath();
      this.ctx.rect(clipX, i * palmStepH, clipW, palmStepH + 1.2);
      this.ctx.clip();
      this.ctx.drawImage(bitmap, drawX - padX + dx, drawY + dy, drawW + padX * 2, drawH);
      this.ctx.restore();
    }

    // 3. 仅对中部橘子海海浪带 (0.54 ~ 0.67) 做 8 条带双频轻微颤动
    const waveStrips = this.compact ? 5 : 8;
    const waveTop = h * 0.54;
    const waveBandH = h * 0.13;
    const waveStepH = waveBandH / waveStrips;
    for (let i = 0; i < waveStrips; i += 1) {
      const local = (i + 0.5) / waveStrips;
      const waveEnv = Math.sin(local * Math.PI);
      const swell = Math.sin(t * 1.4 + local * 5.8) * 1.9;
      const tremor = Math.sin(t * 3.0 + local * 14.0) * 1.1;
      const dx = (swell + tremor) * waveEnv * gust;
      const dy = Math.cos(t * 2.4 + local * 9.5) * 0.6 * waveEnv * gust;
      this.ctx.save();
      this.ctx.beginPath();
      this.ctx.rect(clipX, waveTop + i * waveStepH, clipW, waveStepH + 1.2);
      this.ctx.clip();
      this.ctx.drawImage(bitmap, drawX - padX + dx, drawY + dy, drawW + padX * 2, drawH);
      this.ctx.restore();
    }

    if (wideScreen && drawX > 0) {
      const featherW = Math.min(88, drawW * 0.24);
      const edgeGrad = this.ctx.createLinearGradient(drawX, 0, drawX + featherW, 0);
      if (this.darkMode) {
        edgeGrad.addColorStop(0, 'rgba(26, 18, 16, 1)');
        edgeGrad.addColorStop(1, 'rgba(26, 18, 16, 0)');
      } else {
        edgeGrad.addColorStop(0, 'rgba(253, 246, 242, 1)');
        edgeGrad.addColorStop(1, 'rgba(253, 246, 242, 0)');
      }
      this.ctx.fillStyle = edgeGrad;
      this.ctx.fillRect(drawX - 1, 0, featherW + 2, h);
    }
  }

  private drawSeaGlints(w: number, h: number): void {
    const t = this.elapsed;
    const dimFactor = this.dimmed ? 0.5 : 1;
    const imgRatio = this.imgWidth > 0 && this.imgHeight > 0 ? this.imgWidth / this.imgHeight : 0.5625;
    const drawW = h * imgRatio;
    const drawX = (w / h) > imgRatio ? (w - drawW) : (w - drawW) * 0.5;

    this.ctx.save();
    for (const g of this.glints) {
      const shimmer = 0.25 + 0.75 * Math.pow(0.5 + 0.5 * Math.sin(t * g.speed + g.phase), 2);
      const gx = drawX + drawW * g.nx + Math.sin(t * 1.4 + g.phase) * 5;
      const gy = h * g.ny;
      const gw = g.width * (0.7 + 0.3 * shimmer) * (this.compact ? 0.45 : 1);
      const a = shimmer * (this.darkMode ? 0.46 : 0.62) * dimFactor;
      this.ctx.fillStyle = this.darkMode
        ? `rgba(255, 206, 152, ${a.toFixed(3)})`
        : `rgba(255, 250, 224, ${a.toFixed(3)})`;
      this.ctx.fillRect(gx - gw * 0.5, gy, gw, this.compact ? 1.4 : 2.0);
    }
    this.ctx.restore();
  }

  private updateAndDrawMotes(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    const dimFactor = this.dimmed ? 0.55 : 1;
    const kept: SunMote[] = [];

    this.ctx.save();
    for (const m of this.motes) {
      m.x += (m.vx + Math.sin(t * 0.9 + m.phase) * 8) * dt;
      m.y += m.vy * dt;
      if (m.y < -20) {
        if (m.ambient) {
          m.y = h + 16;
          m.x = (m.x + w * 0.31) % w;
          kept.push(m);
        }
        continue;
      }
      kept.push(m);
      const pulse = 0.5 + 0.5 * Math.sin(t * 1.8 + m.phase);
      const a = m.alpha * pulse * dimFactor;
      const grad = this.ctx.createRadialGradient(m.x, m.y, 0, m.x, m.y, m.radius);
      if (this.darkMode) {
        grad.addColorStop(0, `rgba(255, 198, 146, ${a.toFixed(3)})`);
        grad.addColorStop(1, 'rgba(255, 198, 146, 0)');
      } else {
        grad.addColorStop(0, `rgba(255, 242, 208, ${(a * 1.4).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(255, 210, 168, 0)');
      }
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(m.x, m.y, m.radius, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
    this.motes = kept;
  }

  private updateAndDrawRipples(dt: number): void {
    if (!this.ripples.length) return;
    const next: SunRipple[] = [];
    const rgb = this.darkMode ? '255, 186, 138' : '214, 108, 58';
    this.ctx.save();
    this.ctx.lineWidth = 1.2;
    for (const r of this.ripples) {
      r.radius += r.speed * dt;
      if (r.radius >= r.maxRadius) continue;
      const a = r.alpha * (1 - r.radius / r.maxRadius);
      this.ctx.strokeStyle = `rgba(${rgb}, ${a.toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.arc(r.x, r.y, r.radius, 0, Math.PI * 2);
      this.ctx.stroke();
      next.push(r);
    }
    this.ctx.restore();
    this.ripples = next;
  }

  build() {
    Stack() {
      if (!this.pixelsReady) {
        Image($rawfile(this.darkMode ? 'sunset_dark.jpg' : 'sunset_light.jpg'))
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
    .opacity(this.compact ? 0.85 : this.sceneOpacity)
    .animation({ duration: 320, curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
  }
}
