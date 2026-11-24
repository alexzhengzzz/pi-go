import { image } from '@kit.ImageKit';

interface ArtParticle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  radius: number;
  phase: number;
  alpha: number;
  ambient: boolean;
}

interface ArtRipple {
  x: number;
  y: number;
  radius: number;
  maxRadius: number;
  speed: number;
  alpha: number;
}

interface SkyStar {
  nx: number;
  ny: number;
  radius: number;
  phase: number;
  speed: number;
}

@ComponentV2
export struct ArtThemeScene {
  @Param themeId: string = 'bookstore';
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
  private initializedForTheme: string = '';

  private energyBoost: number = 0;
  private particles: ArtParticle[] = [];
  private ripples: ArtRipple[] = [];
  private stars: SkyStar[] = [];

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

  @Monitor('themeId', 'darkMode')
  private onAssetChange(): void {
    this.initializedForTheme = '';
    void this.loadBitmap();
  }

  private rawfileName(): string {
    const suffix = this.darkMode ? 'dark' : 'light';
    if (this.themeId === 'jellyfish') return `jellyfish_${suffix}.jpg`;
    if (this.themeId === 'sahara') return `sahara_${suffix}.jpg`;
    return `bookstore_${suffix}.jpg`;
  }

  private featherRgb(): string {
    if (this.themeId === 'jellyfish') {
      return this.darkMode ? '10,18,32' : '241,248,252';
    }
    if (this.themeId === 'sahara') {
      return this.darkMode ? '18,17,24' : '251,245,236';
    }
    return this.darkMode ? '23,19,16' : '250,246,238';
  }

  private async loadBitmap(): Promise<void> {
    const gen = ++this.loadGen;
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    const name = this.rawfileName();
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
    this.energyBoost = Math.max(this.energyBoost, celebrate ? 1.0 : 0.65);
    const w = this.canvasW > 0 ? this.canvasW : 390;
    const h = this.canvasH > 0 ? this.canvasH : 840;
    const count = celebrate ? 12 : 6;
    const originX = this.themeId === 'bookstore' ? w * 0.64 : (this.themeId === 'jellyfish' ? w * 0.74 : w * 0.585);
    const originY = this.themeId === 'bookstore' ? h * 0.36 : (this.themeId === 'jellyfish' ? h * 0.54 : h * 0.635);

    for (let i = 0; i < count; i += 1) {
      const spread = (i - (count - 1) * 0.5) * 14;
      this.particles.push({
        x: originX + spread * 0.6,
        y: originY + (i % 3) * 8,
        vx: (this.themeId === 'sahara' ? -6 : 0) + (i % 5 - 2) * 9,
        vy: -(24 + (i % 4) * 11),
        radius: (this.themeId === 'jellyfish' ? 3.5 : 2.6) + (i % 3) * 1.4,
        phase: i * 1.1,
        alpha: celebrate ? 0.78 : 0.62,
        ambient: false
      });
    }
    this.ripples.push({
      x: originX,
      y: originY,
      radius: 8,
      maxRadius: celebrate ? 128 : 88,
      speed: 48,
      alpha: 0.44
    });
  }

  @Monitor('tapSeq')
  private onTapChange(): void {
    if (this.compact || this.tapSeq <= 0) return;
    this.energyBoost = Math.max(this.energyBoost, 0.55);
    const x = this.tapX > 0 ? this.tapX : (this.canvasW || 390) * 0.5;
    const y = this.tapY > 0 ? this.tapY : (this.canvasH || 840) * 0.5;
    this.ripples.push({ x: x, y: y, radius: 5, maxRadius: 96, speed: 56, alpha: 0.46 });
    const vxList: number[] = [-24, -10, 4, 16, 26];
    for (let i = 0; i < 5; i += 1) {
      this.particles.push({
        x: x + (i - 2) * 5,
        y: y,
        vx: vxList[i],
        vy: -(22 + (i % 3) * 12),
        radius: (this.themeId === 'jellyfish' ? 3.2 : 2.4) + (i % 3) * 1.2,
        phase: i * 1.3,
        alpha: 0.68,
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
    if (this.initializedForTheme === this.themeId && this.canvasW > 0) return;
    this.initializedForTheme = this.themeId;
    this.particles = [];
    this.ripples = [];

    const count = this.compact ? 6 : 12;
    for (let i = 0; i < count; i += 1) {
      if (this.themeId === 'bookstore') {
        this.particles.push({
          x: w * (0.42 + ((i * 0.17) % 0.52)),
          y: h * (0.14 + ((i * 0.23) % 0.58)),
          vx: -3 + (i % 3) * 2.5,
          vy: -(4 + (i % 3) * 2.5),
          radius: (this.compact ? 1.6 : 2.2) + (i % 3) * 0.9,
          phase: i * 1.4,
          alpha: 0.30 + (i % 3) * 0.14,
          ambient: true
        });
      } else if (this.themeId === 'jellyfish') {
        this.particles.push({
          x: w * (0.46 + ((i * 0.19) % 0.48)),
          y: h * (0.10 + (i / count) * 0.66),
          vx: (i % 2 === 0 ? 1 : -1) * (2 + (i % 3)),
          vy: -(11 + (i % 4) * 5),
          radius: (this.compact ? 2.2 : 3.0) + (i % 4) * 1.4,
          phase: i * 1.2,
          alpha: 0.28 + (i % 3) * 0.12,
          ambient: true
        });
      } else {
        // sahara embers rising from campfire around (0.585, 0.635)
        this.particles.push({
          x: w * (0.53 + ((i * 0.09) % 0.14)),
          y: h * (0.28 + (i / count) * 0.36),
          vx: -(3 + (i % 3) * 2.5),
          vy: -(12 + (i % 4) * 5.5),
          radius: (this.compact ? 1.5 : 2.0) + (i % 3) * 0.85,
          phase: i * 1.35,
          alpha: 0.42 + (i % 3) * 0.16,
          ambient: true
        });
      }
    }

    this.stars = [
      { nx: 0.62, ny: 0.11, radius: 1.8, phase: 0.4, speed: 2.1 },
      { nx: 0.71, ny: 0.08, radius: 1.5, phase: 1.7, speed: 1.7 },
      { nx: 0.89, ny: 0.12, radius: 1.7, phase: 2.8, speed: 2.4 },
      { nx: 0.93, ny: 0.24, radius: 1.4, phase: 4.0, speed: 1.9 },
      { nx: 0.68, ny: 0.23, radius: 1.4, phase: 5.1, speed: 2.2 },
      { nx: 0.76, ny: 0.30, radius: 1.6, phase: 0.9, speed: 1.8 }
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
    if (this.energyBoost > 0) this.energyBoost = Math.max(0, this.energyBoost - dt * 0.55);

    this.ctx.clearRect(0, 0, w, h);

    let drawX = 0;
    let drawW = w;
    if (this.sceneMap && this.imgWidth > 0 && this.imgHeight > 0) {
      const imgRatio = this.imgWidth / this.imgHeight;
      const viewRatio = w / h;
      const wideScreen = viewRatio > imgRatio;
      drawW = h * imgRatio;
      drawX = wideScreen ? (w - drawW) : (w - drawW) * 0.5;
      this.drawWarpedScene(this.sceneMap, w, h, drawX, drawW, wideScreen);
    }

    this.drawAtmosphere(w, h, drawX, drawW);
    this.updateAndDrawParticles(w, h, drawX, drawW, dt);
    this.updateAndDrawRipples(dt);
  }

  private drawWarpedScene(
    bitmap: image.PixelMap,
    w: number,
    h: number,
    drawX: number,
    drawW: number,
    wideScreen: boolean
  ): void {
    const drawH = h;
    const drawY = 0;
    const t = this.elapsed;
    const boost = 1 + this.energyBoost * 0.65;
    const padX = 8;
    const clipX = wideScreen ? Math.max(0, drawX - 2) : 0;
    const clipW = wideScreen ? (w - clipX) : w;

    // 1. 静态主体一次性绘制（低负载核心）
    this.ctx.save();
    this.ctx.beginPath();
    this.ctx.rect(clipX, 0, clipW, h);
    this.ctx.clip();
    this.ctx.drawImage(bitmap, drawX, drawY, drawW, drawH);
    this.ctx.restore();

    // 2. 仅对局部动态带做少量条带波形扰动
    if (this.themeId === 'jellyfish') {
      const strips = this.compact ? 6 : 10;
      const bandTop = h * 0.18;
      const bandH = h * 0.50;
      const stepH = bandH / strips;
      for (let i = 0; i < strips; i += 1) {
        const local = (i + 0.5) / strips;
        const env = Math.sin(local * Math.PI);
        const dx = Math.sin(t * 1.15 + local * 5.2) * 3.2 * env * boost;
        const dy = Math.cos(t * 0.95 + local * 3.8) * 1.8 * env * boost;
        this.ctx.save();
        this.ctx.beginPath();
        this.ctx.rect(clipX, bandTop + i * stepH, clipW, stepH + 1.2);
        this.ctx.clip();
        this.ctx.drawImage(bitmap, drawX - padX + dx, drawY + dy, drawW + padX * 2, drawH);
        this.ctx.restore();
      }
    } else if (this.themeId === 'sahara') {
      // 仅对篝火火焰与热浪带 (0.56 ~ 0.67) 做轻微热浪摇曳
      const strips = this.compact ? 4 : 7;
      const bandTop = h * 0.56;
      const bandH = h * 0.11;
      const stepH = bandH / strips;
      for (let i = 0; i < strips; i += 1) {
        const local = (i + 0.5) / strips;
        const env = Math.sin(local * Math.PI);
        const dx = (Math.sin(t * 3.6 + local * 9.0) * 1.6 + Math.sin(t * 6.2 + local * 15.0) * 0.8) * env * boost;
        const dy = Math.cos(t * 2.8 + local * 6.0) * 0.7 * env * boost;
        this.ctx.save();
        this.ctx.beginPath();
        this.ctx.rect(clipX, bandTop + i * stepH, clipW, stepH + 1.2);
        this.ctx.clip();
        this.ctx.drawImage(bitmap, drawX - padX + dx, drawY + dy, drawW + padX * 2, drawH);
        this.ctx.restore();
      }
    }

    // 3. 折叠屏 / 平板 / 横屏宽屏适配：左边缘自然羽化融入主题底色
    if (wideScreen && drawX > 2) {
      const featherW = Math.min(88, drawW * 0.24);
      const grad = this.ctx.createLinearGradient(drawX - 2, 0, drawX + featherW, 0);
      const rgb = this.featherRgb();
      grad.addColorStop(0, `rgba(${rgb},1)`);
      grad.addColorStop(0.55, `rgba(${rgb},0.55)`);
      grad.addColorStop(1, `rgba(${rgb},0)`);
      this.ctx.fillStyle = grad;
      this.ctx.fillRect(drawX - 2, 0, featherW + 2, h);
    }
  }

  private drawAtmosphere(w: number, h: number, drawX: number, drawW: number): void {
    const t = this.elapsed;
    const dimFactor = this.dimmed ? 0.58 : 1.0;

    if (this.themeId === 'bookstore') {
      // 银行家台灯呼吸暖光晕
      const lx = drawX + drawW * 0.63;
      const ly = h * 0.34;
      const pulse = 0.86 + 0.14 * Math.sin(t * 1.4) + this.energyBoost * 0.22;
      const rad = Math.min(w, h) * (this.compact ? 0.32 : 0.28) * pulse;
      const grad = this.ctx.createRadialGradient(lx, ly, 4, lx, ly, rad);
      const peakAlpha = (this.darkMode ? 0.24 : 0.14) * dimFactor;
      grad.addColorStop(0, `rgba(255,212,126,${peakAlpha.toFixed(3)})`);
      grad.addColorStop(0.5, `rgba(244,182,88,${(peakAlpha * 0.42).toFixed(3)})`);
      grad.addColorStop(1, 'rgba(244,182,88,0)');
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(lx, ly, rad, 0, Math.PI * 2);
      this.ctx.fill();
    } else if (this.themeId === 'jellyfish') {
      // 水母生物荧光轻微脉动光环
      const jx = drawX + drawW * 0.78;
      const jy = h * 0.27;
      const pulse = 0.88 + 0.12 * Math.sin(t * 1.65) + this.energyBoost * 0.2;
      const rad = Math.min(w, h) * (this.compact ? 0.30 : 0.24) * pulse;
      const grad = this.ctx.createRadialGradient(jx, jy, 4, jx, jy, rad);
      const peakAlpha = (this.darkMode ? 0.22 : 0.12) * dimFactor;
      grad.addColorStop(0, `rgba(130,228,255,${peakAlpha.toFixed(3)})`);
      grad.addColorStop(0.55, `rgba(165,175,255,${(peakAlpha * 0.35).toFixed(3)})`);
      grad.addColorStop(1, 'rgba(130,228,255,0)');
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(jx, jy, rad, 0, Math.PI * 2);
      this.ctx.fill();
    } else {
      // 撒哈拉：篝火暖光呼吸 + 帐篷挂灯微光 + 夜空微闪星点
      const fx = drawX + drawW * 0.585;
      const fy = h * 0.635;
      const flicker = 0.90 + 0.10 * Math.sin(t * 4.2) + 0.05 * Math.cos(t * 7.1) + this.energyBoost * 0.24;
      const rad = Math.min(w, h) * (this.compact ? 0.34 : 0.28) * flicker;
      const grad = this.ctx.createRadialGradient(fx, fy, 3, fx, fy, rad);
      const peakAlpha = (this.darkMode ? 0.30 : 0.18) * dimFactor;
      grad.addColorStop(0, `rgba(255,176,84,${peakAlpha.toFixed(3)})`);
      grad.addColorStop(0.5, `rgba(255,118,52,${(peakAlpha * 0.38).toFixed(3)})`);
      grad.addColorStop(1, 'rgba(255,118,52,0)');
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(fx, fy, rad, 0, Math.PI * 2);
      this.ctx.fill();

      if (this.darkMode) {
        for (let i = 0; i < this.stars.length; i += 1) {
          const s = this.stars[i];
          const twinkle = 0.25 + 0.75 * (0.5 + 0.5 * Math.sin(t * s.speed + s.phase));
          const sx = drawX + drawW * s.nx;
          const sy = h * s.ny;
          this.ctx.fillStyle = `rgba(255,244,218,${(twinkle * 0.75 * dimFactor).toFixed(3)})`;
          this.ctx.beginPath();
          this.ctx.arc(sx, sy, s.radius * (0.85 + twinkle * 0.3), 0, Math.PI * 2);
          this.ctx.fill();
        }
      }
    }
  }

  private updateAndDrawParticles(w: number, h: number, drawX: number, drawW: number, dt: number): void {
    const dimFactor = this.dimmed ? 0.55 : 1.0;
    const next: ArtParticle[] = [];

    for (let i = 0; i < this.particles.length; i += 1) {
      const p = this.particles[i];
      p.phase += dt * 1.8;
      p.x += (p.vx + Math.sin(p.phase) * 7.0) * dt;
      p.y += p.vy * dt;

      if (p.ambient) {
        if (p.y < h * 0.06 || p.x < -16 || p.x > w + 16) {
          if (this.themeId === 'bookstore') {
            p.x = drawX + drawW * (0.44 + ((i * 0.19) % 0.48));
            p.y = h * (0.52 + ((i * 0.07) % 0.18));
          } else if (this.themeId === 'jellyfish') {
            p.x = drawX + drawW * (0.48 + ((i * 0.17) % 0.46));
            p.y = h * (0.68 + ((i * 0.05) % 0.08));
          } else {
            p.x = drawX + drawW * (0.54 + ((i * 0.07) % 0.10));
            p.y = h * (0.57 + ((i * 0.03) % 0.06));
          }
        }
        next.push(p);
      } else {
        p.alpha -= dt * 0.45;
        if (p.alpha > 0.02 && p.y > -24) {
          next.push(p);
        }
      }

      const pulse = 0.65 + 0.35 * Math.sin(p.phase * 1.3);
      const a = Math.max(0, Math.min(0.88, p.alpha * pulse * dimFactor));
      if (a <= 0.02) continue;

      if (this.themeId === 'jellyfish') {
        // 透明微泡：柔光外圈 + 白色高光点
        this.ctx.fillStyle = this.darkMode
          ? `rgba(148,232,255,${(a * 0.24).toFixed(3)})`
          : `rgba(255,255,255,${(a * 0.55).toFixed(3)})`;
        this.ctx.strokeStyle = this.darkMode
          ? `rgba(182,242,255,${(a * 0.85).toFixed(3)})`
          : `rgba(38,142,188,${(a * 0.65).toFixed(3)})`;
        this.ctx.lineWidth = 1;
        this.ctx.beginPath();
        this.ctx.arc(p.x, p.y, p.radius, 0, Math.PI * 2);
        this.ctx.fill();
        this.ctx.stroke();

        this.ctx.fillStyle = `rgba(255,255,255,${(a * 0.9).toFixed(3)})`;
        this.ctx.beginPath();
        this.ctx.arc(p.x - p.radius * 0.32, p.y - p.radius * 0.32, Math.max(0.8, p.radius * 0.26), 0, Math.PI * 2);
        this.ctx.fill();
      } else if (this.themeId === 'sahara') {
        // 篝火余烬火星：暖橙金光斑
        const grad = this.ctx.createRadialGradient(p.x, p.y, 0.3, p.x, p.y, p.radius * 2.2);
        grad.addColorStop(0, `rgba(255,232,164,${a.toFixed(3)})`);
        grad.addColorStop(0.55, `rgba(255,146,66,${(a * 0.55).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(255,120,46,0)');
        this.ctx.fillStyle = grad;
        this.ctx.beginPath();
        this.ctx.arc(p.x, p.y, p.radius * 2.2, 0, Math.PI * 2);
        this.ctx.fill();
      } else {
        // 书店暖灯浮尘与金箔微粒
        const grad = this.ctx.createRadialGradient(p.x, p.y, 0.3, p.x, p.y, p.radius * 2.0);
        const core = this.darkMode ? `rgba(255,222,146,${a.toFixed(3)})` : `rgba(218,158,64,${(a * 0.85).toFixed(3)})`;
        grad.addColorStop(0, core);
        grad.addColorStop(1, 'rgba(232,176,82,0)');
        this.ctx.fillStyle = grad;
        this.ctx.beginPath();
        this.ctx.arc(p.x, p.y, p.radius * 2.0, 0, Math.PI * 2);
        this.ctx.fill();
      }
    }
    this.particles = next;
  }

  private updateAndDrawRipples(dt: number): void {
    if (this.ripples.length === 0) return;
    const next: ArtRipple[] = [];
    for (let i = 0; i < this.ripples.length; i += 1) {
      const r = this.ripples[i];
      r.radius += r.speed * dt;
      const progress = r.radius / r.maxRadius;
      if (progress < 1) {
        const a = r.alpha * (1 - progress);
        let stroke = this.darkMode ? `rgba(246,204,132,${a.toFixed(3)})` : `rgba(176,112,38,${a.toFixed(3)})`;
        if (this.themeId === 'jellyfish') {
          stroke = this.darkMode ? `rgba(142,232,255,${a.toFixed(3)})` : `rgba(28,136,184,${a.toFixed(3)})`;
        } else if (this.themeId === 'sahara') {
          stroke = this.darkMode ? `rgba(255,182,118,${a.toFixed(3)})` : `rgba(196,98,44,${a.toFixed(3)})`;
        }
        this.ctx.strokeStyle = stroke;
        this.ctx.lineWidth = 1.4;
        this.ctx.beginPath();
        this.ctx.arc(r.x, r.y, r.radius, 0, Math.PI * 2);
        this.ctx.stroke();
        next.push(r);
      }
    }
    this.ripples = next;
  }

  build() {
    Stack() {
      if (!this.pixelsReady) {
        Image($rawfile(this.rawfileName()))
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.sceneOpacity)
      }
      Canvas(this.ctx)
        .width('100%').height('100%')
        .opacity(this.sceneOpacity)
        .onReady(() => {
          this.canvasReady = true;
          this.ensureLoop();
        })
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
}
