import { image } from '@kit.ImageKit';

interface EmberSpark {
  x: number;
  y: number;
  vx: number;
  vy: number;
  radius: number;
  life: number;
  maxLife: number;
  phase: number;
  swirl: number;
  ambient: boolean;
}

interface SmokeWisp {
  x: number;
  y: number;
  vx: number;
  vy: number;
  radius: number;
  maxRadius: number;
  life: number;
  maxLife: number;
  phase: number;
}

interface DesertStar {
  nx: number;
  ny: number;
  radius: number;
  phase: number;
  speed: number;
}

interface ShootingStar {
  active: boolean;
  x: number;
  y: number;
  vx: number;
  vy: number;
  life: number;
  maxLife: number;
  cooldown: number;
}

interface HeatRipple {
  x: number;
  y: number;
  radius: number;
  maxRadius: number;
  speed: number;
  alpha: number;
}

@ComponentV2
export struct SaharaScene {
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

  private energyBoost: number = 0;
  private embers: EmberSpark[] = [];
  private smokes: SmokeWisp[] = [];
  private stars: DesertStar[] = [];
  private ripples: HeatRipple[] = [];
  private meteor: ShootingStar = {
    active: false,
    x: 0,
    y: 0,
    vx: 0,
    vy: 0,
    life: 0,
    maxLife: 0.9,
    cooldown: 4.5
  };

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

  private rawfileName(): string {
    return this.darkMode ? 'sahara_dark.jpg' : 'sahara_light.jpg';
  }

  private fireOriginRatioX(): number {
    return this.darkMode ? 0.616 : 0.632;
  }

  private fireOriginRatioY(): number {
    return this.darkMode ? 0.725 : 0.715;
  }

  private async loadBitmap(): Promise<void> {
    const gen = ++this.loadGen;
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    let source: image.ImageSource | undefined;
    try {
      const bytes = await context.resourceManager.getRawFileContent(this.rawfileName());
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
    this.energyBoost = Math.max(this.energyBoost, celebrate ? 1.0 : 0.7);
    const w = this.canvasW > 0 ? this.canvasW : 390;
    const h = this.canvasH > 0 ? this.canvasH : 840;
    const fx = this.calcDrawX(w, h) + this.calcDrawW(w, h) * this.fireOriginRatioX();
    const fy = h * this.fireOriginRatioY();
    const count = celebrate ? 16 : 9;

    for (let i = 0; i < count; i += 1) {
      const spread = (i - (count - 1) * 0.5) * 4.2;
      this.embers.push({
        x: fx + spread,
        y: fy + (i % 3) * 4,
        vx: -4 + (i % 7 - 3) * 10,
        vy: -(36 + (i % 5) * 16),
        radius: 1.2 + (i % 3) * 0.7,
        life: 0,
        maxLife: 1.5 + (i % 4) * 0.45,
        phase: i * 1.15,
        swirl: 10 + (i % 3) * 6,
        ambient: false
      });
    }
  }

  @Monitor('tapSeq')
  private onTapChange(): void {
    if (this.compact || this.tapSeq <= 0) return;
    this.energyBoost = Math.max(this.energyBoost, 0.55);
    const x = this.tapX > 0 ? this.tapX : (this.canvasW || 390) * 0.5;
    const y = this.tapY > 0 ? this.tapY : (this.canvasH || 840) * 0.5;
    this.ripples.push({ x: x, y: y, radius: 4, maxRadius: 84, speed: 52, alpha: 0.36 });
    const vxList: number[] = [-18, -8, 2, 11, 20];
    for (let i = 0; i < 5; i += 1) {
      this.embers.push({
        x: x + (i - 2) * 4,
        y: y,
        vx: vxList[i],
        vy: -(24 + (i % 3) * 12),
        radius: 1.2 + (i % 3) * 0.55,
        life: 0,
        maxLife: 1.2 + (i % 3) * 0.35,
        phase: i * 1.3,
        swirl: 8,
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

  private calcDrawW(w: number, h: number): number {
    const imgRatio = (this.imgWidth > 0 && this.imgHeight > 0) ? (this.imgWidth / this.imgHeight) : (768 / 1376);
    return h * imgRatio;
  }

  private calcDrawX(w: number, h: number): number {
    const drawW = this.calcDrawW(w, h);
    return w > drawW ? (w - drawW) : (w - drawW) * 0.5;
  }

  private initElements(w: number, h: number): void {
    if (this.initialized) return;
    this.initialized = true;
    const drawX = this.calcDrawX(w, h);
    const drawW = this.calcDrawW(w, h);
    const fx = drawX + drawW * this.fireOriginRatioX();
    const fy = h * this.fireOriginRatioY();

    const emberCount = this.compact ? 8 : 18;
    this.embers = [];
    for (let i = 0; i < emberCount; i += 1) {
      const maxLife = 2.2 + (i % 5) * 0.55;
      this.embers.push({
        x: fx + ((i % 7) - 3) * 4.5,
        y: fy - (i / emberCount) * h * 0.24,
        vx: -4.5 + ((i % 5) - 2) * 3.8,
        vy: -(18 + (i % 5) * 7.5),
        radius: (this.compact ? 1.0 : 1.25) + (i % 3) * 0.55,
        life: (i / emberCount) * maxLife,
        maxLife: maxLife,
        phase: i * 1.37,
        swirl: 8 + (i % 4) * 4.5,
        ambient: true
      });
    }

    const smokeCount = this.compact ? 4 : 7;
    this.smokes = [];
    for (let i = 0; i < smokeCount; i += 1) {
      const maxLife = 3.8 + (i % 3) * 0.9;
      this.smokes.push({
        x: fx + ((i % 3) - 1) * 5,
        y: fy - 16 - (i / smokeCount) * h * 0.16,
        vx: -4.5 - (i % 3) * 1.8,
        vy: -(13 + (i % 3) * 3.5),
        radius: 10 + (i % 3) * 4,
        maxRadius: (this.compact ? 26 : 42) + (i % 3) * 10,
        life: (i / smokeCount) * maxLife,
        maxLife: maxLife,
        phase: i * 1.7
      });
    }

    this.stars = [
      { nx: 0.16, ny: 0.11, radius: 1.2, phase: 0.5, speed: 1.8 },
      { nx: 0.29, ny: 0.08, radius: 1.5, phase: 1.9, speed: 2.3 },
      { nx: 0.44, ny: 0.15, radius: 1.1, phase: 3.1, speed: 1.6 },
      { nx: 0.54, ny: 0.07, radius: 1.6, phase: 0.9, speed: 2.5 },
      { nx: 0.64, ny: 0.14, radius: 1.3, phase: 4.2, speed: 2.0 },
      { nx: 0.72, ny: 0.20, radius: 1.5, phase: 2.4, speed: 1.9 },
      { nx: 0.81, ny: 0.11, radius: 1.2, phase: 5.0, speed: 2.2 },
      { nx: 0.87, ny: 0.26, radius: 1.4, phase: 1.2, speed: 1.7 },
      { nx: 0.37, ny: 0.25, radius: 1.1, phase: 3.8, speed: 2.1 },
      { nx: 0.76, ny: 0.31, radius: 1.2, phase: 0.3, speed: 2.4 }
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

    const drawW = this.calcDrawW(w, h);
    const drawX = this.calcDrawX(w, h);
    const wideScreen = w > drawW;

    if (this.sceneMap && this.imgWidth > 0 && this.imgHeight > 0) {
      this.drawCampScene(this.sceneMap, w, h, drawX, drawW, wideScreen);
    }

    const fx = drawX + drawW * this.fireOriginRatioX();
    const fy = h * this.fireOriginRatioY();
    const dimFactor = this.dimmed ? 0.60 : 1.0;

    if (this.darkMode) {
      this.drawNightSky(w, h, drawX, drawW, dt, dimFactor);
    }
    this.updateAndDrawSmoke(fx, fy, dt, dimFactor);
    this.drawFirelight(w, h, fx, fy, dimFactor);
    this.updateAndDrawEmbers(fx, fy, dt, dimFactor);
    this.updateAndDrawRipples(dt);
  }

  private drawCampScene(
    bitmap: image.PixelMap,
    w: number,
    h: number,
    drawX: number,
    drawW: number,
    wideScreen: boolean
  ): void {
    const t = this.elapsed;
    const boost = 1 + this.energyBoost * 0.6;
    const clipX = wideScreen ? Math.max(0, drawX - 2) : 0;
    const clipW = wideScreen ? (w - clipX) : w;

    // 1. 清晰绘制写实底图（沙丘、帐篷与星空保持锐利稳定）
    this.ctx.save();
    this.ctx.beginPath();
    this.ctx.rect(clipX, 0, clipW, h);
    this.ctx.clip();
    this.ctx.drawImage(bitmap, drawX, 0, drawW, h);
    this.ctx.restore();

    // 2. 仅对远景小篝火火焰做克制的局部微颤，沙丘与帐篷保持锐利静止
    const fx = drawX + drawW * this.fireOriginRatioX();
    const fy = h * this.fireOriginRatioY();
    const flameW = drawW * 0.085;
    const flameTop = fy - h * 0.045;
    const flameH = h * 0.055;
    const strips = this.compact ? 4 : 6;
    const stepH = flameH / strips;

    for (let i = 0; i < strips; i += 1) {
      const local = (i + 0.5) / strips;
      const env = Math.sin(local * Math.PI);
      const dx = (Math.sin(t * 4.6 + local * 9.0) * 1.0 + Math.sin(t * 8.2 + local * 14.0) * 0.45) * env * boost;
      const dy = Math.cos(t * 3.8 + local * 7.0) * 0.45 * env * boost;
      this.ctx.save();
      this.ctx.beginPath();
      this.ctx.rect(fx - flameW * 0.5, flameTop + i * stepH, flameW, stepH + 1.0);
      this.ctx.clip();
      this.ctx.drawImage(bitmap, drawX + dx, dy, drawW, h);
      this.ctx.restore();
    }

    // 3. 宽屏/平板左侧自然羽化融入主题底色
    if (wideScreen && drawX > 2) {
      const featherW = Math.min(92, drawW * 0.24);
      const rgb = this.darkMode ? '18,17,24' : '251,245,236';
      const grad = this.ctx.createLinearGradient(drawX - 2, 0, drawX + featherW, 0);
      grad.addColorStop(0, `rgba(${rgb},1)`);
      grad.addColorStop(0.55, `rgba(${rgb},0.55)`);
      grad.addColorStop(1, `rgba(${rgb},0)`);
      this.ctx.fillStyle = grad;
      this.ctx.fillRect(drawX - 2, 0, featherW + 2, h);
    }
  }

  private drawNightSky(w: number, h: number, drawX: number, drawW: number, dt: number, dimFactor: number): void {
    const t = this.elapsed;
    // 微闪星点
    for (let i = 0; i < this.stars.length; i += 1) {
      const s = this.stars[i];
      const twinkle = 0.2 + 0.8 * (0.5 + 0.5 * Math.sin(t * s.speed + s.phase));
      const sx = drawX + drawW * s.nx;
      const sy = h * s.ny;
      const a = twinkle * 0.72 * dimFactor;
      this.ctx.fillStyle = `rgba(255,246,226,${a.toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.arc(sx, sy, s.radius * (0.8 + twinkle * 0.35), 0, Math.PI * 2);
      this.ctx.fill();
    }

    if (this.compact) return;

    // 偶发沙漠流星划过夜空
    if (!this.meteor.active) {
      this.meteor.cooldown -= dt;
      if (this.meteor.cooldown <= 0) {
        this.meteor.active = true;
        this.meteor.x = drawX + drawW * (0.52 + ((t * 0.13) % 0.36));
        this.meteor.y = h * (0.06 + ((t * 0.07) % 0.12));
        this.meteor.vx = -(155 + (t % 45));
        this.meteor.vy = 62 + (t % 24);
        this.meteor.life = 0;
        this.meteor.maxLife = 0.85;
      }
    } else {
      this.meteor.life += dt;
      this.meteor.x += this.meteor.vx * dt;
      this.meteor.y += this.meteor.vy * dt;
      const p = this.meteor.life / this.meteor.maxLife;
      if (p >= 1) {
        this.meteor.active = false;
        this.meteor.cooldown = 6.5 + (t % 4.5);
      } else {
        const alpha = Math.sin(p * Math.PI) * 0.78 * dimFactor;
        const tailX = this.meteor.x - this.meteor.vx * 0.22;
        const tailY = this.meteor.y - this.meteor.vy * 0.22;
        const grad = this.ctx.createLinearGradient(this.meteor.x, this.meteor.y, tailX, tailY);
        grad.addColorStop(0, `rgba(255,250,234,${alpha.toFixed(3)})`);
        grad.addColorStop(0.45, `rgba(210,224,255,${(alpha * 0.45).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(210,224,255,0)');
        this.ctx.strokeStyle = grad;
        this.ctx.lineWidth = 1.5;
        this.ctx.beginPath();
        this.ctx.moveTo(this.meteor.x, this.meteor.y);
        this.ctx.lineTo(tailX, tailY);
        this.ctx.stroke();
      }
    }
  }

  private drawFirelight(
    w: number,
    h: number,
    fx: number,
    fy: number,
    dimFactor: number
  ): void {
    const t = this.elapsed;
    // 克制自然的多频火光呼吸
    const flicker = 0.92
      + 0.06 * Math.sin(t * 4.1)
      + 0.04 * Math.sin(t * 7.5 + 1.1)
      + 0.02 * Math.cos(t * 12.6)
      + this.energyBoost * 0.20;

    // 1. 篝火映照在周边沙坡上的柔和暖光晕
    const wideR = Math.min(w, h) * (this.compact ? 0.24 : 0.20) * flicker;
    const wideGrad = this.ctx.createRadialGradient(fx, fy, 2, fx, fy, wideR);
    const peakA = (this.darkMode ? 0.22 : 0.10) * dimFactor;
    wideGrad.addColorStop(0, `rgba(255,192,108,${peakA.toFixed(3)})`);
    wideGrad.addColorStop(0.45, `rgba(236,134,64,${(peakA * 0.42).toFixed(3)})`);
    wideGrad.addColorStop(1, 'rgba(236,112,48,0)');
    this.ctx.fillStyle = wideGrad;
    this.ctx.beginPath();
    this.ctx.arc(fx, fy, wideR, 0, Math.PI * 2);
    this.ctx.fill();

    // 2. 火焰中心微光
    const coreR = (this.compact ? 14 : 20) * flicker;
    const coreGrad = this.ctx.createRadialGradient(fx, fy - 3, 1, fx, fy - 3, coreR);
    const coreA = (this.darkMode ? 0.28 : 0.16) * dimFactor;
    coreGrad.addColorStop(0, `rgba(255,238,184,${coreA.toFixed(3)})`);
    coreGrad.addColorStop(0.55, `rgba(248,162,76,${(coreA * 0.38).toFixed(3)})`);
    coreGrad.addColorStop(1, 'rgba(248,136,54,0)');
    this.ctx.fillStyle = coreGrad;
    this.ctx.beginPath();
    this.ctx.arc(fx, fy - 3, coreR, 0, Math.PI * 2);
    this.ctx.fill();
  }

  private updateAndDrawSmoke(fx: number, fy: number, dt: number, dimFactor: number): void {
    for (let i = 0; i < this.smokes.length; i += 1) {
      const s = this.smokes[i];
      s.life += dt;
      s.phase += dt * 1.1;
      if (s.life >= s.maxLife) {
        s.life = 0;
        s.x = fx + ((i % 3) - 1) * 5;
        s.y = fy - 18;
      }
      const p = s.life / s.maxLife;
      s.x += (s.vx + Math.sin(s.phase) * 5.5) * dt;
      s.y += s.vy * dt;

      const curR = s.radius + (s.maxRadius - s.radius) * p;
      const alpha = Math.sin(p * Math.PI) * (this.darkMode ? 0.085 : 0.11) * dimFactor;
      if (alpha <= 0.005) continue;

      const grad = this.ctx.createRadialGradient(s.x, s.y, curR * 0.1, s.x, s.y, curR);
      if (this.darkMode) {
        grad.addColorStop(0, `rgba(196,174,158,${alpha.toFixed(3)})`);
        grad.addColorStop(0.6, `rgba(148,136,136,${(alpha * 0.4).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(120,114,120,0)');
      } else {
        grad.addColorStop(0, `rgba(255,248,238,${alpha.toFixed(3)})`);
        grad.addColorStop(0.6, `rgba(232,216,200,${(alpha * 0.45).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(224,206,188,0)');
      }
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(s.x, s.y, curR, 0, Math.PI * 2);
      this.ctx.fill();
    }
  }

  private updateAndDrawEmbers(fx: number, fy: number, dt: number, dimFactor: number): void {
    const next: EmberSpark[] = [];
    const boost = 1 + this.energyBoost * 0.55;

    for (let i = 0; i < this.embers.length; i += 1) {
      const e = this.embers[i];
      e.life += dt;
      e.phase += dt * 2.6;
      const prevX = e.x;
      const prevY = e.y;
      e.x += (e.vx + Math.sin(e.phase) * e.swirl) * dt;
      e.y += e.vy * boost * dt;

      const p = e.life / e.maxLife;
      if (p >= 1) {
        if (e.ambient) {
          e.life = 0;
          e.x = fx + (((i * 13) % 11) - 5) * 3.2;
          e.y = fy + 4 - (i % 3) * 3;
          next.push(e);
        }
        continue;
      }
      next.push(e);

      const flicker = 0.68 + 0.32 * Math.sin(e.phase * 2.3);
      const alpha = Math.sin(Math.min(1, p * 1.15) * Math.PI) * (this.darkMode ? 0.92 : 0.72) * flicker * dimFactor;
      if (alpha <= 0.03) continue;

      // 火星由炽白黄渐冷为深橙红
      const g = Math.round(236 - p * 136);
      const b = Math.round(160 * Math.max(0, 1 - p * 1.6));

      // 微小运动拖尾，增强真实火花感
      this.ctx.strokeStyle = `rgba(255,${g},${b},${(alpha * 0.75).toFixed(3)})`;
      this.ctx.lineWidth = Math.max(0.9, e.radius * 0.95);
      this.ctx.beginPath();
      this.ctx.moveTo(prevX, prevY);
      this.ctx.lineTo(e.x, e.y);
      this.ctx.stroke();

      // 火星发光核心
      const haloR = e.radius * 2.4;
      const grad = this.ctx.createRadialGradient(e.x, e.y, 0.2, e.x, e.y, haloR);
      grad.addColorStop(0, `rgba(255,${Math.min(255, g + 22)},${Math.min(255, b + 40)},${alpha.toFixed(3)})`);
      grad.addColorStop(0.5, `rgba(255,${g},${b},${(alpha * 0.45).toFixed(3)})`);
      grad.addColorStop(1, 'rgba(255,108,36,0)');
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(e.x, e.y, haloR, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.embers = next;
  }

  private updateAndDrawRipples(dt: number): void {
    if (this.ripples.length === 0) return;
    const next: HeatRipple[] = [];
    for (let i = 0; i < this.ripples.length; i += 1) {
      const r = this.ripples[i];
      r.radius += r.speed * dt;
      const progress = r.radius / r.maxRadius;
      if (progress < 1) {
        const a = r.alpha * (1 - progress);
        this.ctx.strokeStyle = this.darkMode
          ? `rgba(255,186,118,${a.toFixed(3)})`
          : `rgba(196,104,46,${a.toFixed(3)})`;
        this.ctx.lineWidth = 1.3;
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
