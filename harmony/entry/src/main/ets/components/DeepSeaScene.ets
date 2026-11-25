interface SeaBubble {
  x: number;
  y: number;
  vx: number;
  vy: number;
  radius: number;
  phase: number;
  alpha: number;
  ambient: boolean;
}

interface PlanktonDot {
  x: number;
  y: number;
  vx: number;
  vy: number;
  radius: number;
  phase: number;
  speed: number;
  hue: number;
  alpha: number;
}

interface SeaRipple {
  x: number;
  y: number;
  radius: number;
  maxRadius: number;
  speed: number;
  alpha: number;
}

interface JellyfishActor {
  x: number;
  y: number;
  baseY: number;
  vx: number;
  vy: number;
  scale: number;
  pulsePhase: number;
  pulseSpeed: number;
  driftPhase: number;
  tilt: number;
  hue: number;
  depth: number;
  tentacles: number;
}

interface MantaActor {
  x: number;
  y: number;
  baseY: number;
  speed: number;
  dir: number;
  scale: number;
  flapPhase: number;
  flapSpeed: number;
  depth: number;
}

interface WhaleActor {
  x: number;
  y: number;
  baseY: number;
  speed: number;
  dir: number;
  scale: number;
  tailPhase: number;
  depth: number;
}

interface SquidActor {
  x: number;
  y: number;
  vx: number;
  vy: number;
  scale: number;
  pulsePhase: number;
  pulseSpeed: number;
  hue: number;
  depth: number;
}

interface AnglerActor {
  x: number;
  y: number;
  baseY: number;
  speed: number;
  dir: number;
  scale: number;
  swimPhase: number;
  lurePhase: number;
  depth: number;
}

interface SchoolFish {
  offsetX: number;
  offsetY: number;
  size: number;
  phase: number;
}

interface FishSchool {
  x: number;
  y: number;
  baseY: number;
  speed: number;
  dir: number;
  wavePhase: number;
  waveAmp: number;
  depth: number;
  hue: number;
  members: SchoolFish[];
}

interface LightShaft {
  nx: number;
  widthRatio: number;
  angle: number;
  phase: number;
  speed: number;
  alpha: number;
}

@ComponentV2
export struct DeepSeaScene {
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

  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasReady: boolean = false;
  private loopTimer: number = -1;
  private loopIntervalMs: number = 33;
  private lastTickMs: number = 0;
  private elapsed: number = 0;
  private canvasW: number = 0;
  private canvasH: number = 0;
  private initialized: boolean = false;

  private energyBoost: number = 0;
  private shafts: LightShaft[] = [];
  private bubbles: SeaBubble[] = [];
  private plankton: PlanktonDot[] = [];
  private ripples: SeaRipple[] = [];
  private jellies: JellyfishActor[] = [];
  private mantas: MantaActor[] = [];
  private whales: WhaleActor[] = [];
  private squids: SquidActor[] = [];
  private anglers: AnglerActor[] = [];
  private schools: FishSchool[] = [];

  aboutToDisappear(): void {
    this.stopLoop();
  }

  @Monitor('burstSeq')
  private onBurstChange(): void {
    if (this.compact || this.burstSeq <= 0) return;
    const celebrate = this.burstKind === 'celebrate';
    this.energyBoost = Math.max(this.energyBoost, celebrate ? 1.0 : 0.65);
    const w = this.canvasW > 0 ? this.canvasW : 390;
    const h = this.canvasH > 0 ? this.canvasH : 840;
    const originX = w * 0.68;
    const originY = h * 0.52;
    const count = celebrate ? 14 : 7;

    for (let i = 0; i < count; i += 1) {
      const spread = (i - (count - 1) * 0.5) * 14;
      this.bubbles.push({
        x: originX + spread * 0.7,
        y: originY + (i % 3) * 9,
        vx: (i % 5 - 2) * 10,
        vy: -(28 + (i % 4) * 12),
        radius: 3.0 + (i % 3) * 1.5,
        phase: i * 1.1,
        alpha: celebrate ? 0.82 : 0.66,
        ambient: false
      });
    }
    this.ripples.push({
      x: originX,
      y: originY,
      radius: 8,
      maxRadius: celebrate ? 138 : 94,
      speed: 52,
      alpha: 0.46
    });
  }

  @Monitor('tapSeq')
  private onTapChange(): void {
    if (this.compact || this.tapSeq <= 0) return;
    this.energyBoost = Math.max(this.energyBoost, 0.55);
    const x = this.tapX > 0 ? this.tapX : (this.canvasW || 390) * 0.5;
    const y = this.tapY > 0 ? this.tapY : (this.canvasH || 840) * 0.5;
    this.ripples.push({ x: x, y: y, radius: 5, maxRadius: 102, speed: 58, alpha: 0.48 });
    const vxList: number[] = [-26, -12, 2, 14, 28];
    for (let i = 0; i < 5; i += 1) {
      this.bubbles.push({
        x: x + (i - 2) * 6,
        y: y,
        vx: vxList[i],
        vy: -(24 + (i % 3) * 13),
        radius: 2.8 + (i % 3) * 1.3,
        phase: i * 1.3,
        alpha: 0.72,
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

  private initScene(w: number, h: number): void {
    if (this.initialized) return;
    this.initialized = true;
    const sc = this.compact ? 0.62 : 1.0;

    // 1. 穿透海面的深海丁达尔光束
    this.shafts = [
      { nx: 0.24, widthRatio: 0.16, angle: 0.18, phase: 0.3, speed: 0.32, alpha: 0.085 },
      { nx: 0.56, widthRatio: 0.22, angle: 0.14, phase: 1.9, speed: 0.26, alpha: 0.105 },
      { nx: 0.82, widthRatio: 0.18, angle: 0.12, phase: 3.7, speed: 0.36, alpha: 0.095 }
    ];

    // 2. 远景深海巨鲸（缓慢游弋，营造宏大纵深）
    this.whales = [
      {
        x: w * 0.22,
        y: h * 0.26,
        baseY: h * 0.26,
        speed: this.compact ? 7 : 10,
        dir: 1,
        scale: (this.compact ? 0.52 : 1.05) * (w > 500 ? 1.18 : 1.0),
        tailPhase: 0.6,
        depth: 0.35
      }
    ];

    // 3. 深海蝠鲼（优雅滑翔）
    this.mantas = [
      {
        x: w * 0.78,
        y: h * 0.38,
        baseY: h * 0.38,
        speed: this.compact ? 14 : 21,
        dir: -1,
        scale: 0.88 * sc,
        flapPhase: 0.4,
        flapSpeed: 1.55,
        depth: 0.62
      }
    ];
    if (!this.compact) {
      this.mantas.push({
        x: w * 0.15,
        y: h * 0.62,
        baseY: h * 0.62,
        speed: 15,
        dir: 1,
        scale: 0.58,
        flapPhase: 2.5,
        flapSpeed: 1.3,
        depth: 0.44
      });
    }

    // 4. 荧光水母群（不同大小、色彩与脉冲节奏，真实推进游动）
    this.jellies = [
      {
        x: w * 0.74,
        y: h * 0.30,
        baseY: h * 0.30,
        vx: -5.2,
        vy: -7.5,
        scale: 1.08 * sc,
        pulsePhase: 0.0,
        pulseSpeed: 1.65,
        driftPhase: 0.5,
        tilt: -0.14,
        hue: 0, // 冰蓝青荧光
        depth: 0.92,
        tentacles: 6
      },
      {
        x: w * 0.34,
        y: h * 0.56,
        baseY: h * 0.56,
        vx: 4.5,
        vy: -6.2,
        scale: 0.78 * sc,
        pulsePhase: 2.2,
        pulseSpeed: 1.9,
        driftPhase: 1.8,
        tilt: 0.12,
        hue: 1, // 幽紫粉荧光
        depth: 0.78,
        tentacles: 5
      }
    ];
    if (!this.compact) {
      this.jellies.push({
        x: w * 0.84,
        y: h * 0.74,
        baseY: h * 0.74,
        vx: -3.6,
        vy: -5.4,
        scale: 0.58,
        pulsePhase: 4.1,
        pulseSpeed: 2.15,
        driftPhase: 3.3,
        tilt: -0.09,
        hue: 2, // 碧绿海藻荧光
        depth: 0.64,
        tentacles: 4
      });
    }

    // 5. 深海发光鱿鱼（中层斜向穿梭）
    this.squids = [
      {
        x: w * 0.18,
        y: h * 0.72,
        vx: this.compact ? 14 : 20,
        vy: this.compact ? -4.5 : -6.5,
        scale: 0.82 * sc,
        pulsePhase: 1.1,
        pulseSpeed: 2.8,
        hue: 0,
        depth: 0.76
      }
    ];

    // 6. 深渊灯笼鱼（下层深海提灯巡游）
    this.anglers = [];
    if (!this.compact) {
      this.anglers.push({
        x: w * 0.64,
        y: h * 0.84,
        baseY: h * 0.84,
        speed: 11.5,
        dir: -1,
        scale: 0.86,
        swimPhase: 0.9,
        lurePhase: 0.2,
        depth: 0.72
      });
    }

    // 7. 荧光深海鱼群（协同波浪游动）
    const school1Members: SchoolFish[] = [
      { offsetX: 0, offsetY: 0, size: 7.2 * sc, phase: 0.0 },
      { offsetX: -18 * sc, offsetY: -10 * sc, size: 6.2 * sc, phase: 0.7 },
      { offsetX: -22 * sc, offsetY: 11 * sc, size: 6.5 * sc, phase: 1.4 },
      { offsetX: -38 * sc, offsetY: -3 * sc, size: 5.8 * sc, phase: 2.1 },
      { offsetX: -48 * sc, offsetY: 14 * sc, size: 5.2 * sc, phase: 2.9 }
    ];
    this.schools = [
      {
        x: w * 0.42,
        y: h * 0.45,
        baseY: h * 0.45,
        speed: this.compact ? 22 : 30,
        dir: 1,
        wavePhase: 0.4,
        waveAmp: this.compact ? 8 : 16,
        depth: 0.74,
        hue: 0,
        members: school1Members
      }
    ];
    if (!this.compact) {
      const school2Members: SchoolFish[] = [
        { offsetX: 0, offsetY: 0, size: 5.6, phase: 0.4 },
        { offsetX: 15, offsetY: -8, size: 5.0, phase: 1.2 },
        { offsetX: 19, offsetY: 9, size: 5.2, phase: 2.0 },
        { offsetX: 33, offsetY: -2, size: 4.5, phase: 2.8 },
        { offsetX: 41, offsetY: 10, size: 4.2, phase: 3.6 },
        { offsetX: 52, offsetY: -6, size: 4.0, phase: 4.3 }
      ];
      this.schools.push({
        x: w * 0.85,
        y: h * 0.20,
        baseY: h * 0.20,
        speed: 24,
        dir: -1,
        wavePhase: 2.6,
        waveAmp: 12,
        depth: 0.50,
        hue: 1,
        members: school2Members
      });
    }

    // 8. 浮游微光浮雪（Marine Snow & 生物荧光浮游生物）
    const planktonCount = this.compact ? 14 : 30;
    this.plankton = [];
    for (let i = 0; i < planktonCount; i += 1) {
      this.plankton.push({
        x: ((i * 0.37) % 1) * w,
        y: ((i * 0.29) % 1) * h,
        vx: ((i % 3) - 1) * 3.5,
        vy: -(2.5 + (i % 4) * 1.8),
        radius: (this.compact ? 1.1 : 1.4) + (i % 3) * 0.75,
        phase: i * 0.95,
        speed: 1.2 + (i % 4) * 0.45,
        hue: i % 3,
        alpha: 0.26 + (i % 4) * 0.14
      });
    }

    // 9. 上升微泡
    const bubbleCount = this.compact ? 7 : 14;
    this.bubbles = [];
    for (let i = 0; i < bubbleCount; i += 1) {
      this.bubbles.push({
        x: w * (0.08 + ((i * 0.23) % 0.86)),
        y: h * (0.10 + (i / bubbleCount) * 0.86),
        vx: (i % 2 === 0 ? 1 : -1) * (2 + (i % 3)),
        vy: -(12 + (i % 4) * 5.5),
        radius: (this.compact ? 1.8 : 2.4) + (i % 4) * 1.15,
        phase: i * 1.25,
        alpha: 0.24 + (i % 3) * 0.11,
        ambient: true
      });
    }
  }

  private tick(): void {
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    const resized = this.canvasW > 0 && (Math.abs(w - this.canvasW) > 40 || Math.abs(h - this.canvasH) > 40);
    this.canvasW = w;
    this.canvasH = h;
    if (resized) {
      this.initialized = false;
    }
    this.initScene(w, h);

    const now = Date.now();
    const dt = Math.min(0.06, Math.max(0.01, (now - this.lastTickMs) / 1000));
    this.lastTickMs = now;
    this.elapsed += dt;
    if (this.energyBoost > 0) this.energyBoost = Math.max(0, this.energyBoost - dt * 0.55);

    const dimFactor = this.dimmed ? 0.62 : 1.0;

    // 按景深从远到近分层绘制
    this.drawOceanBackdrop(w, h);
    this.drawLightShafts(w, h, dimFactor);
    this.updateAndDrawWhales(w, h, dt, dimFactor);
    this.updateAndDrawMantas(w, h, dt, dimFactor);
    this.updateAndDrawSchools(w, h, dt, dimFactor);
    this.updateAndDrawSquids(w, h, dt, dimFactor);
    this.updateAndDrawAnglers(w, h, dt, dimFactor);
    this.updateAndDrawJellies(w, h, dt, dimFactor);
    this.updateAndDrawPlankton(w, h, dt, dimFactor);
    this.updateAndDrawBubbles(w, h, dt, dimFactor);
    this.updateAndDrawRipples(dt);
  }

  private drawOceanBackdrop(w: number, h: number): void {
    const grad = this.ctx.createLinearGradient(0, 0, 0, h);
    if (this.darkMode) {
      grad.addColorStop(0.0, '#07223B');
      grad.addColorStop(0.28, '#081C34');
      grad.addColorStop(0.64, '#061226');
      grad.addColorStop(1.0, '#030812');
    } else {
      grad.addColorStop(0.0, '#EBF7FD');
      grad.addColorStop(0.32, '#CBE9F9');
      grad.addColorStop(0.70, '#9DD4F0');
      grad.addColorStop(1.0, '#6FB2DA');
    }
    this.ctx.fillStyle = grad;
    this.ctx.fillRect(0, 0, w, h);

    // 深海柔和焦散暗涌光晕
    const t = this.elapsed;
    const glowX = w * (0.68 + Math.sin(t * 0.22) * 0.06);
    const glowY = h * 0.16;
    const glowR = Math.max(w, h) * 0.58;
    const topGlow = this.ctx.createRadialGradient(glowX, glowY, 8, glowX, glowY, glowR);
    if (this.darkMode) {
      topGlow.addColorStop(0, 'rgba(34,154,212,0.22)');
      topGlow.addColorStop(0.5, 'rgba(18,86,142,0.09)');
      topGlow.addColorStop(1, 'rgba(6,18,38,0)');
    } else {
      topGlow.addColorStop(0, 'rgba(255,255,255,0.45)');
      topGlow.addColorStop(0.5, 'rgba(176,232,255,0.18)');
      topGlow.addColorStop(1, 'rgba(140,210,245,0)');
    }
    this.ctx.fillStyle = topGlow;
    this.ctx.fillRect(0, 0, w, h);

    // 底部深渊幽蓝柔雾
    const abyssH = h * 0.24;
    const abyssGrad = this.ctx.createLinearGradient(0, h - abyssH, 0, h);
    if (this.darkMode) {
      abyssGrad.addColorStop(0, 'rgba(2,8,18,0)');
      abyssGrad.addColorStop(1, 'rgba(2,6,14,0.55)');
    } else {
      abyssGrad.addColorStop(0, 'rgba(42,118,168,0)');
      abyssGrad.addColorStop(1, 'rgba(32,104,156,0.22)');
    }
    this.ctx.fillStyle = abyssGrad;
    this.ctx.fillRect(0, h - abyssH, w, abyssH);
  }

  private drawLightShafts(w: number, h: number, dimFactor: number): void {
    const t = this.elapsed;
    for (let i = 0; i < this.shafts.length; i += 1) {
      const s = this.shafts[i];
      const sway = Math.sin(t * s.speed + s.phase) * w * 0.04;
      const topX = w * s.nx + sway;
      const halfTop = w * s.widthRatio * 0.35;
      const halfBot = w * s.widthRatio * 1.15;
      const botX = topX - h * Math.tan(s.angle) + sway * 1.4;
      const pulse = 0.72 + 0.28 * Math.sin(t * (s.speed * 1.3) + s.phase);
      const peakA = s.alpha * pulse * dimFactor * (this.darkMode ? 1.0 : 1.35);

      const grad = this.ctx.createLinearGradient(topX, 0, botX, h * 0.82);
      if (this.darkMode) {
        grad.addColorStop(0, `rgba(116,226,255,${peakA.toFixed(3)})`);
        grad.addColorStop(0.48, `rgba(54,166,224,${(peakA * 0.42).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(18,74,126,0)');
      } else {
        grad.addColorStop(0, `rgba(255,255,255,${(peakA * 1.5).toFixed(3)})`);
        grad.addColorStop(0.5, `rgba(218,246,255,${(peakA * 0.55).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(166,224,250,0)');
      }

      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.moveTo(topX - halfTop, 0);
      this.ctx.lineTo(topX + halfTop, 0);
      this.ctx.lineTo(botX + halfBot, h * 0.85);
      this.ctx.lineTo(botX - halfBot, h * 0.85);
      this.ctx.closePath();
      this.ctx.fill();
    }
  }

  private updateAndDrawWhales(w: number, h: number, dt: number, dimFactor: number): void {
    const boost = 1 + this.energyBoost * 0.25;
    for (let i = 0; i < this.whales.length; i += 1) {
      const wh = this.whales[i];
      wh.tailPhase += dt * 1.15 * boost;
      wh.x += wh.speed * wh.dir * dt * boost;
      wh.y = wh.baseY + Math.sin(wh.tailPhase * 0.5) * 14;

      const margin = 175 * wh.scale;
      if (wh.dir > 0 && wh.x > w + margin) {
        wh.x = -margin;
        wh.baseY = h * (0.18 + ((this.elapsed * 0.07) % 0.28));
      } else if (wh.dir < 0 && wh.x < -margin) {
        wh.x = w + margin;
        wh.baseY = h * (0.18 + ((this.elapsed * 0.07) % 0.28));
      }

      this.ctx.save();
      this.ctx.translate(wh.x, wh.y);
      this.ctx.scale(wh.dir * wh.scale, wh.scale);

      const tailSwing = Math.sin(wh.tailPhase) * 11;
      const finSwing = Math.sin(wh.tailPhase - 0.8) * 5;
      const alpha = (this.darkMode ? 0.22 : 0.16) * dimFactor;
      const bodyColor = this.darkMode
        ? `rgba(42,138,196,${alpha.toFixed(3)})`
        : `rgba(18,86,138,${alpha.toFixed(3)})`;
      const bellyColor = this.darkMode
        ? `rgba(104,210,248,${(alpha * 0.65).toFixed(3)})`
        : `rgba(128,204,238,${(alpha * 0.7).toFixed(3)})`;

      // 鲸身轮廓（流线型座头鲸剪影）
      this.ctx.fillStyle = bodyColor;
      this.ctx.beginPath();
      this.ctx.moveTo(76, -2); // 吻部前端
      this.ctx.bezierCurveTo(64, -22, 24, -27, -14, -18); // 背脊
      this.ctx.bezierCurveTo(-48, -10, -74, -4 + tailSwing * 0.45, -100, tailSwing); // 尾柄上沿
      // 尾鳍上下叶
      this.ctx.bezierCurveTo(-114, tailSwing - 18, -128, tailSwing - 22, -132, tailSwing - 15);
      this.ctx.bezierCurveTo(-124, tailSwing - 5, -118, tailSwing + 2, -116, tailSwing + 5);
      this.ctx.bezierCurveTo(-124, tailSwing + 14, -126, tailSwing + 23, -118, tailSwing + 22);
      this.ctx.bezierCurveTo(-108, tailSwing + 17, -102, tailSwing + 10, -96, tailSwing + 6);
      // 尾柄下沿与腹部
      this.ctx.bezierCurveTo(-68, 9 + tailSwing * 0.35, -36, 17, 4, 18);
      this.ctx.bezierCurveTo(38, 19, 68, 12, 76, -2);
      this.ctx.closePath();
      this.ctx.fill();

      // 柔和的腹部浅光
      this.ctx.fillStyle = bellyColor;
      this.ctx.beginPath();
      this.ctx.moveTo(72, 2);
      this.ctx.bezierCurveTo(44, 14, 6, 15, -24, 9);
      this.ctx.bezierCurveTo(10, 6, 44, 4, 72, 2);
      this.ctx.closePath();
      this.ctx.fill();

      // 修长胸鳍
      this.ctx.fillStyle = bodyColor;
      this.ctx.beginPath();
      this.ctx.moveTo(24, 10);
      this.ctx.bezierCurveTo(10, 26 + finSwing, -10, 38 + finSwing, -22, 34 + finSwing * 0.7);
      this.ctx.bezierCurveTo(-12, 23 + finSwing * 0.5, 2, 16, 10, 9);
      this.ctx.closePath();
      this.ctx.fill();

      this.ctx.restore();
    }
  }

  private updateAndDrawMantas(w: number, h: number, dt: number, dimFactor: number): void {
    const boost = 1 + this.energyBoost * 0.35;
    for (let i = 0; i < this.mantas.length; i += 1) {
      const m = this.mantas[i];
      m.flapPhase += dt * m.flapSpeed * boost;
      m.x += m.speed * m.dir * dt * boost;
      m.y = m.baseY + Math.sin(m.flapPhase * 0.65) * 16;

      const margin = 96 * m.scale;
      if (m.dir > 0 && m.x > w + margin) {
        m.x = -margin;
        m.baseY = h * (0.28 + ((i * 0.24 + this.elapsed * 0.03) % 0.44));
      } else if (m.dir < 0 && m.x < -margin) {
        m.x = w + margin;
        m.baseY = h * (0.28 + ((i * 0.24 + this.elapsed * 0.03) % 0.44));
      }

      this.ctx.save();
      this.ctx.translate(m.x, m.y);
      const pitch = Math.cos(m.flapPhase * 0.65) * 0.08 * m.dir;
      this.ctx.rotate(pitch);
      this.ctx.scale(m.dir * m.scale, m.scale);

      const wingUp = Math.sin(m.flapPhase) * 16;
      const wingLag = Math.sin(m.flapPhase - 0.6) * 10;
      const tailWave = Math.sin(m.flapPhase * 1.4) * 7;
      const alpha = (this.darkMode ? 0.34 : 0.26) * m.depth * dimFactor;

      const grad = this.ctx.createLinearGradient(34, 0, -46, 0);
      if (this.darkMode) {
        grad.addColorStop(0, `rgba(92,216,255,${(alpha * 1.15).toFixed(3)})`);
        grad.addColorStop(0.55, `rgba(38,128,192,${alpha.toFixed(3)})`);
        grad.addColorStop(1, `rgba(20,76,136,${(alpha * 0.7).toFixed(3)})`);
      } else {
        grad.addColorStop(0, `rgba(22,102,152,${(alpha * 1.15).toFixed(3)})`);
        grad.addColorStop(0.6, `rgba(34,126,178,${alpha.toFixed(3)})`);
        grad.addColorStop(1, `rgba(56,148,196,${(alpha * 0.7).toFixed(3)})`);
      }

      // 蝠鲼优雅展翼身形（侧仰滑翔视角）
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.moveTo(34, -2); // 头部前缘
      // 上翼展（远侧翼）
      this.ctx.bezierCurveTo(18, -14 - wingUp * 0.45, -4, -34 - wingUp, -24, -26 - wingLag);
      this.ctx.bezierCurveTo(-18, -12 - wingLag * 0.4, -24, -6, -34, -2);
      // 细长尾鞭根部
      this.ctx.lineTo(-34, 3);
      // 下翼展（近侧大翼）
      this.ctx.bezierCurveTo(-22, 8 + wingLag * 0.3, -12, 22 + wingLag * 0.7, -20, 34 + wingUp * 0.85);
      this.ctx.bezierCurveTo(2, 28 + wingUp * 0.4, 22, 12, 34, 4);
      // 头鳍
      this.ctx.lineTo(42, 6);
      this.ctx.lineTo(38, 1);
      this.ctx.lineTo(42, -5);
      this.ctx.closePath();
      this.ctx.fill();

      // 翼缘微弱荧光高光
      this.ctx.strokeStyle = this.darkMode
        ? `rgba(148,238,255,${(alpha * 0.95).toFixed(3)})`
        : `rgba(255,255,255,${(alpha * 0.8).toFixed(3)})`;
      this.ctx.lineWidth = 1.2;
      this.ctx.beginPath();
      this.ctx.moveTo(32, -2);
      this.ctx.bezierCurveTo(16, -13 - wingUp * 0.45, -4, -33 - wingUp, -24, -26 - wingLag);
      this.ctx.stroke();

      // 柔摆尾鞭
      this.ctx.strokeStyle = this.darkMode
        ? `rgba(74,186,238,${(alpha * 0.9).toFixed(3)})`
        : `rgba(26,112,162,${(alpha * 0.85).toFixed(3)})`;
      this.ctx.lineWidth = 1.6;
      this.ctx.beginPath();
      this.ctx.moveTo(-32, 0.5);
      this.ctx.quadraticCurveTo(-56, tailWave * 0.7, -82, -tailWave);
      this.ctx.stroke();

      this.ctx.restore();
    }
  }

  private updateAndDrawSchools(w: number, h: number, dt: number, dimFactor: number): void {
    const boost = 1 + this.energyBoost * 0.5;
    for (let i = 0; i < this.schools.length; i += 1) {
      const sc = this.schools[i];
      sc.wavePhase += dt * 1.45 * boost;
      sc.x += sc.speed * sc.dir * dt * boost;
      sc.y = sc.baseY + Math.sin(sc.wavePhase) * sc.waveAmp;

      const margin = 95;
      if (sc.dir > 0 && sc.x > w + margin) {
        sc.x = -margin;
        sc.baseY = h * (0.16 + ((i * 0.31 + this.elapsed * 0.04) % 0.62));
      } else if (sc.dir < 0 && sc.x < -margin) {
        sc.x = w + margin;
        sc.baseY = h * (0.16 + ((i * 0.31 + this.elapsed * 0.04) % 0.62));
      }

      const baseAlpha = (this.darkMode ? 0.54 : 0.40) * sc.depth * dimFactor;
      for (let j = 0; j < sc.members.length; j += 1) {
        const f = sc.members[j];
        const fx = sc.x + f.offsetX * sc.dir;
        const fy = sc.y + f.offsetY + Math.sin(sc.wavePhase * 2.1 + f.phase) * 3.2;
        const wag = Math.sin(this.elapsed * 7.5 + f.phase * 2.0) * 2.4;

        this.ctx.save();
        this.ctx.translate(fx, fy);
        this.ctx.scale(sc.dir, 1);

        const len = f.size * 2.1;
        const halfH = f.size * 0.52;
        this.ctx.fillStyle = this.darkMode
          ? (sc.hue === 0
            ? `rgba(98,224,255,${baseAlpha.toFixed(3)})`
            : `rgba(146,198,255,${baseAlpha.toFixed(3)})`)
          : `rgba(22,116,166,${baseAlpha.toFixed(3)})`;

        // 鱼身
        this.ctx.beginPath();
        this.ctx.moveTo(len * 0.5, 0);
        this.ctx.quadraticCurveTo(0, -halfH, -len * 0.5, 0);
        this.ctx.quadraticCurveTo(0, halfH, len * 0.5, 0);
        this.ctx.closePath();
        this.ctx.fill();

        // 摆动尾鳍
        this.ctx.beginPath();
        this.ctx.moveTo(-len * 0.46, 0);
        this.ctx.lineTo(-len * 0.86, -halfH * 0.85 + wag * 0.45);
        this.ctx.lineTo(-len * 0.72, wag * 0.2);
        this.ctx.lineTo(-len * 0.86, halfH * 0.85 + wag * 0.45);
        this.ctx.closePath();
        this.ctx.fill();

        // 鱼侧发光器微点（深色模式更明显）
        if (this.darkMode) {
          this.ctx.fillStyle = `rgba(205,250,255,${(baseAlpha * 1.15).toFixed(3)})`;
          this.ctx.beginPath();
          this.ctx.arc(len * 0.14, -halfH * 0.12, Math.max(0.9, f.size * 0.16), 0, Math.PI * 2);
          this.ctx.fill();
        }

        this.ctx.restore();
      }
    }
  }

  private updateAndDrawSquids(w: number, h: number, dt: number, dimFactor: number): void {
    const boost = 1 + this.energyBoost * 0.45;
    for (let i = 0; i < this.squids.length; i += 1) {
      const sq = this.squids[i];
      sq.pulsePhase += dt * sq.pulseSpeed * boost;
      const surge = 0.65 + 0.55 * Math.max(0, Math.sin(sq.pulsePhase));
      sq.x += sq.vx * surge * dt * boost;
      sq.y += sq.vy * surge * dt * boost;

      const margin = 72 * sq.scale;
      if (sq.x > w + margin || sq.y < -margin) {
        sq.x = -margin;
        sq.y = h * (0.64 + ((this.elapsed * 0.09) % 0.24));
      }

      const angle = Math.atan2(sq.vy, sq.vx);
      const pulse = Math.sin(sq.pulsePhase);
      const alpha = (this.darkMode ? 0.56 : 0.36) * sq.depth * dimFactor;

      this.ctx.save();
      this.ctx.translate(sq.x, sq.y);
      this.ctx.rotate(angle);
      this.ctx.scale(sq.scale, sq.scale);

      // 外围柔光
      if (this.darkMode) {
        const glow = this.ctx.createRadialGradient(4, 0, 2, 4, 0, 34);
        glow.addColorStop(0, `rgba(116,226,255,${(alpha * 0.42).toFixed(3)})`);
        glow.addColorStop(0.6, `rgba(182,138,255,${(alpha * 0.18).toFixed(3)})`);
        glow.addColorStop(1, 'rgba(116,226,255,0)');
        this.ctx.fillStyle = glow;
        this.ctx.beginPath();
        this.ctx.arc(4, 0, 34, 0, Math.PI * 2);
        this.ctx.fill();
      }

      // 拖尾触腕（向后舒展摆动）
      this.ctx.strokeStyle = this.darkMode
        ? `rgba(156,232,255,${(alpha * 0.78).toFixed(3)})`
        : `rgba(32,126,178,${(alpha * 0.72).toFixed(3)})`;
      this.ctx.lineWidth = 1.3;
      for (let tIdx = -2; tIdx <= 2; tIdx += 1) {
        const yOff = tIdx * 2.6;
        const len = tIdx === 0 ? 32 : 24 - Math.abs(tIdx) * 2;
        const wave = Math.sin(sq.pulsePhase * 1.4 + tIdx * 0.9) * 4.5;
        this.ctx.beginPath();
        this.ctx.moveTo(-12, yOff * 0.5);
        this.ctx.quadraticCurveTo(-12 - len * 0.5, yOff + wave, -12 - len, yOff * 1.2 - wave * 0.6);
        this.ctx.stroke();
      }

      // 菱形侧鳍
      const finSpread = 12 + pulse * 2.5;
      this.ctx.fillStyle = this.darkMode
        ? `rgba(164,174,255,${(alpha * 0.75).toFixed(3)})`
        : `rgba(52,148,202,${(alpha * 0.65).toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.moveTo(22, 0);
      this.ctx.lineTo(10, -finSpread);
      this.ctx.lineTo(3, 0);
      this.ctx.lineTo(10, finSpread);
      this.ctx.closePath();
      this.ctx.fill();

      // 流线型外套膜
      const bodyGrad = this.ctx.createLinearGradient(24, 0, -14, 0);
      if (this.darkMode) {
        bodyGrad.addColorStop(0, `rgba(196,246,255,${(alpha * 1.15).toFixed(3)})`);
        bodyGrad.addColorStop(0.55, `rgba(116,214,255,${alpha.toFixed(3)})`);
        bodyGrad.addColorStop(1, `rgba(158,136,255,${(alpha * 0.85).toFixed(3)})`);
      } else {
        bodyGrad.addColorStop(0, `rgba(48,148,198,${(alpha * 1.1).toFixed(3)})`);
        bodyGrad.addColorStop(1, `rgba(92,168,216,${(alpha * 0.85).toFixed(3)})`);
      }
      this.ctx.fillStyle = bodyGrad;
      this.ctx.beginPath();
      this.ctx.moveTo(24, 0);
      this.ctx.bezierCurveTo(14, -8.5 + pulse * 1.2, -4, -7.5, -13, -4);
      this.ctx.lineTo(-13, 4);
      this.ctx.bezierCurveTo(-4, 7.5, 14, 8.5 - pulse * 1.2, 24, 0);
      this.ctx.closePath();
      this.ctx.fill();

      // 荧光斑点
      if (this.darkMode) {
        const spotAlpha = alpha * (0.7 + 0.3 * Math.sin(sq.pulsePhase * 2));
        this.ctx.fillStyle = `rgba(235,252,255,${spotAlpha.toFixed(3)})`;
        this.ctx.beginPath();
        this.ctx.arc(10, -1.5, 1.3, 0, Math.PI * 2);
        this.ctx.arc(3, 1.8, 1.1, 0, Math.PI * 2);
        this.ctx.arc(-4, -1.2, 1.0, 0, Math.PI * 2);
        this.ctx.fill();
      }

      this.ctx.restore();
    }
  }

  private updateAndDrawAnglers(w: number, h: number, dt: number, dimFactor: number): void {
    const boost = 1 + this.energyBoost * 0.25;
    for (let i = 0; i < this.anglers.length; i += 1) {
      const a = this.anglers[i];
      a.swimPhase += dt * 2.1 * boost;
      a.lurePhase += dt * 3.0;
      a.x += a.speed * a.dir * dt * boost;
      a.y = a.baseY + Math.sin(a.swimPhase * 0.7) * 7;

      const margin = 82 * a.scale;
      if (a.dir > 0 && a.x > w + margin) {
        a.x = -margin;
        a.baseY = h * 0.83;
      } else if (a.dir < 0 && a.x < -margin) {
        a.x = w + margin;
        a.baseY = h * 0.83;
      }

      this.ctx.save();
      this.ctx.translate(a.x, a.y);
      this.ctx.scale(a.dir * a.scale, a.scale);

      const alpha = (this.darkMode ? 0.42 : 0.24) * a.depth * dimFactor;
      const tailWag = Math.sin(a.swimPhase) * 4.5;
      const lureBobX = 28 + Math.sin(a.lurePhase) * 2.4;
      const lureBobY = -12 + Math.cos(a.lurePhase * 1.2) * 3.2;
      const lurePulse = 0.78 + 0.22 * Math.sin(a.lurePhase * 1.8) + this.energyBoost * 0.25;

      // 柔和的深渊灯笼光晕
      const haloR = (this.darkMode ? 36 : 24) * lurePulse;
      const halo = this.ctx.createRadialGradient(lureBobX, lureBobY, 1, lureBobX, lureBobY, haloR);
      if (this.darkMode) {
        halo.addColorStop(0, `rgba(178,248,255,${(0.68 * dimFactor).toFixed(3)})`);
        halo.addColorStop(0.35, `rgba(88,224,242,${(0.28 * dimFactor).toFixed(3)})`);
        halo.addColorStop(1, 'rgba(60,180,220,0)');
      } else {
        halo.addColorStop(0, `rgba(255,250,210,${(0.55 * dimFactor).toFixed(3)})`);
        halo.addColorStop(0.5, `rgba(130,225,248,${(0.20 * dimFactor).toFixed(3)})`);
        halo.addColorStop(1, 'rgba(130,225,248,0)');
      }
      this.ctx.fillStyle = halo;
      this.ctx.beginPath();
      this.ctx.arc(lureBobX, lureBobY, haloR, 0, Math.PI * 2);
      this.ctx.fill();

      // 鱼身剪影
      this.ctx.fillStyle = this.darkMode
        ? `rgba(26,76,122,${(alpha * 1.4).toFixed(3)})`
        : `rgba(20,92,138,${(alpha * 1.25).toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.ellipse(0, 0, 18, 13, 0, 0, Math.PI * 2);
      this.ctx.fill();

      // 尾鳍
      this.ctx.beginPath();
      this.ctx.moveTo(-16, 0);
      this.ctx.lineTo(-29, -9 + tailWag * 0.5);
      this.ctx.lineTo(-25, tailWag * 0.2);
      this.ctx.lineTo(-29, 9 + tailWag * 0.5);
      this.ctx.closePath();
      this.ctx.fill();

      // 触角钓竿
      this.ctx.strokeStyle = this.darkMode
        ? `rgba(110,206,242,${(alpha * 1.2).toFixed(3)})`
        : `rgba(38,128,176,${(alpha * 1.1).toFixed(3)})`;
      this.ctx.lineWidth = 1.4;
      this.ctx.beginPath();
      this.ctx.moveTo(8, -11);
      this.ctx.bezierCurveTo(16, -24, 28, -22, lureBobX, lureBobY);
      this.ctx.stroke();

      // 发光灯笼球
      this.ctx.fillStyle = `rgba(232,254,255,${(0.92 * dimFactor).toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.arc(lureBobX, lureBobY, 3.0 * (0.9 + 0.15 * lurePulse), 0, Math.PI * 2);
      this.ctx.fill();

      this.ctx.restore();
    }
  }

  private updateAndDrawJellies(w: number, h: number, dt: number, dimFactor: number): void {
    const boost = 1 + this.energyBoost * 0.45;
    for (let i = 0; i < this.jellies.length; i += 1) {
      const jf = this.jellies[i];
      jf.pulsePhase += dt * jf.pulseSpeed * boost;
      jf.driftPhase += dt * 0.55;

      // 真实水母喷射推进：收缩时加速上浮，舒张时轻盈滑翔
      const contract = Math.sin(jf.pulsePhase);
      const thrust = 0.45 + 0.85 * Math.max(0, contract);
      jf.x += (jf.vx + Math.sin(jf.driftPhase) * 7.5) * dt * boost;
      jf.y += jf.vy * thrust * dt * boost;

      const margin = 95 * jf.scale;
      if (jf.y < -margin) {
        jf.y = h + margin * 0.7;
        jf.x = w * (0.18 + ((i * 0.31 + this.elapsed * 0.05) % 0.68));
      }
      if (jf.x < -margin) jf.x = w + margin * 0.6;
      if (jf.x > w + margin) jf.x = -margin * 0.6;

      this.drawSingleJellyfish(jf, dimFactor);
    }
  }

  private drawSingleJellyfish(jf: JellyfishActor, dimFactor: number): void {
    const contract = Math.sin(jf.pulsePhase);
    const rx = 28 * (1 - contract * 0.13);
    const ry = 20 * (1 + contract * 0.12);
    const glowPulse = 0.86 + 0.14 * Math.sin(jf.pulsePhase + 0.5) + this.energyBoost * 0.22;
    const baseA = (this.darkMode ? 0.78 : 0.58) * jf.depth * dimFactor;

    let coreRgb = '126,232,255';
    let edgeRgb = '76,184,248';
    let tentacleRgb = '164,218,255';
    if (jf.hue === 1) {
      coreRgb = this.darkMode ? '210,168,255' : '158,128,236';
      edgeRgb = this.darkMode ? '142,118,255' : '110,116,220';
      tentacleRgb = this.darkMode ? '228,176,255' : '142,130,224';
    } else if (jf.hue === 2) {
      coreRgb = this.darkMode ? '118,246,218' : '54,178,176';
      edgeRgb = this.darkMode ? '56,204,196' : '38,148,168';
      tentacleRgb = this.darkMode ? '156,248,232' : '72,172,184';
    } else if (!this.darkMode) {
      coreRgb = '68,168,224';
      edgeRgb = '42,136,198';
      tentacleRgb = '58,154,212';
    }

    this.ctx.save();
    this.ctx.translate(jf.x, jf.y);
    const dynamicTilt = jf.tilt + Math.sin(jf.driftPhase) * 0.08;
    this.ctx.rotate(dynamicTilt);
    this.ctx.scale(jf.scale, jf.scale);

    // 1. 生物荧光外光环
    const haloR = 54 * glowPulse;
    const halo = this.ctx.createRadialGradient(0, -4, 4, 0, -4, haloR);
    halo.addColorStop(0, `rgba(${coreRgb},${(baseA * (this.darkMode ? 0.34 : 0.22)).toFixed(3)})`);
    halo.addColorStop(0.55, `rgba(${edgeRgb},${(baseA * (this.darkMode ? 0.14 : 0.08)).toFixed(3)})`);
    halo.addColorStop(1, `rgba(${edgeRgb},0)`);
    this.ctx.fillStyle = halo;
    this.ctx.beginPath();
    this.ctx.arc(0, -4, haloR, 0, Math.PI * 2);
    this.ctx.fill();

    // 2. 摇曳的多段式透明触须与口腕（带相位延迟波形）
    for (let tIdx = 0; tIdx < jf.tentacles; tIdx += 1) {
      const ratio = jf.tentacles > 1 ? (tIdx / (jf.tentacles - 1)) - 0.5 : 0;
      const startX = ratio * rx * 1.35;
      const startY = 3;
      const len = (52 + (tIdx % 3) * 18) * (1 - Math.abs(ratio) * 0.22);
      const wave1 = Math.sin(jf.pulsePhase * 1.15 - 0.7 + tIdx * 0.9) * 9;
      const wave2 = Math.sin(jf.pulsePhase * 1.15 - 1.9 + tIdx * 0.9) * 14;
      const lineA = baseA * (tIdx % 2 === 0 ? 0.62 : 0.42);

      this.ctx.strokeStyle = `rgba(${tentacleRgb},${lineA.toFixed(3)})`;
      this.ctx.lineWidth = tIdx % 2 === 0 ? 1.65 : 1.05;
      this.ctx.beginPath();
      this.ctx.moveTo(startX, startY);
      this.ctx.bezierCurveTo(
        startX + wave1 * 0.55, startY + len * 0.33,
        startX - wave1 * 0.45, startY + len * 0.68,
        startX + wave2, startY + len
      );
      this.ctx.stroke();
    }

    // 3. 半透明伞盖主体
    const bellGrad = this.ctx.createRadialGradient(-rx * 0.16, -ry * 0.52, 2, 0, -ry * 0.12, rx * 1.22);
    if (this.darkMode) {
      bellGrad.addColorStop(0, `rgba(242,252,255,${(baseA * 0.92).toFixed(3)})`);
      bellGrad.addColorStop(0.38, `rgba(${coreRgb},${(baseA * 0.68).toFixed(3)})`);
      bellGrad.addColorStop(0.82, `rgba(${edgeRgb},${(baseA * 0.36).toFixed(3)})`);
      bellGrad.addColorStop(1, `rgba(${edgeRgb},${(baseA * 0.12).toFixed(3)})`);
    } else {
      bellGrad.addColorStop(0, `rgba(255,255,255,${(baseA * 0.95).toFixed(3)})`);
      bellGrad.addColorStop(0.45, `rgba(${coreRgb},${(baseA * 0.56).toFixed(3)})`);
      bellGrad.addColorStop(1, `rgba(${edgeRgb},${(baseA * 0.24).toFixed(3)})`);
    }

    this.ctx.fillStyle = bellGrad;
    this.ctx.beginPath();
    this.ctx.moveTo(-rx, 3);
    this.ctx.bezierCurveTo(-rx * 1.05, -ry * 1.18, rx * 1.05, -ry * 1.18, rx, 3);
    // 伞缘微褶波浪裙边
    const skirtDip = 4.5 + contract * 2.2;
    this.ctx.quadraticCurveTo(rx * 0.55, skirtDip, rx * 0.18, 2);
    this.ctx.quadraticCurveTo(0, skirtDip + 1.5, -rx * 0.18, 2);
    this.ctx.quadraticCurveTo(-rx * 0.55, skirtDip, -rx, 3);
    this.ctx.closePath();
    this.ctx.fill();

    // 4. 伞盖发光内腔与顶缘高光弧
    this.ctx.fillStyle = `rgba(255,255,255,${(baseA * (this.darkMode ? 0.52 : 0.68)).toFixed(3)})`;
    this.ctx.beginPath();
    this.ctx.ellipse(-rx * 0.16, -ry * 0.44, rx * 0.34, ry * 0.22, -0.22, 0, Math.PI * 2);
    this.ctx.fill();

    this.ctx.strokeStyle = `rgba(232,250,255,${(baseA * 0.65).toFixed(3)})`;
    this.ctx.lineWidth = 1.15;
    this.ctx.beginPath();
    this.ctx.moveTo(-rx * 0.92, 1.5);
    this.ctx.bezierCurveTo(-rx * 0.94, -ry * 1.06, rx * 0.94, -ry * 1.06, rx * 0.92, 1.5);
    this.ctx.stroke();

    this.ctx.restore();
  }

  private updateAndDrawPlankton(w: number, h: number, dt: number, dimFactor: number): void {
    for (let i = 0; i < this.plankton.length; i += 1) {
      const p = this.plankton[i];
      p.phase += dt * p.speed;
      p.x += (p.vx + Math.sin(p.phase) * 4.5) * dt;
      p.y += p.vy * dt;

      if (p.y < -8) {
        p.y = h + 8;
        p.x = ((i * 0.37 + this.elapsed * 0.02) % 1) * w;
      }
      if (p.x < -8) p.x = w + 8;
      if (p.x > w + 8) p.x = -8;

      const twinkle = 0.35 + 0.65 * (0.5 + 0.5 * Math.sin(p.phase * 1.4));
      const a = p.alpha * twinkle * dimFactor;
      if (a <= 0.02) continue;

      let rgb = '144,236,255';
      if (p.hue === 1) rgb = this.darkMode ? '196,178,255' : '255,255,255';
      else if (p.hue === 2) rgb = this.darkMode ? '126,246,220' : '206,242,255';

      const rad = p.radius * (this.darkMode ? 2.4 : 1.9);
      const grad = this.ctx.createRadialGradient(p.x, p.y, 0.2, p.x, p.y, rad);
      grad.addColorStop(0, `rgba(${rgb},${a.toFixed(3)})`);
      grad.addColorStop(1, `rgba(${rgb},0)`);
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(p.x, p.y, rad, 0, Math.PI * 2);
      this.ctx.fill();
    }
  }

  private updateAndDrawBubbles(w: number, h: number, dt: number, dimFactor: number): void {
    const next: SeaBubble[] = [];
    for (let i = 0; i < this.bubbles.length; i += 1) {
      const b = this.bubbles[i];
      b.phase += dt * 1.9;
      b.x += (b.vx + Math.sin(b.phase) * 7.5) * dt;
      b.y += b.vy * dt;

      if (b.ambient) {
        if (b.y < -12 || b.x < -16 || b.x > w + 16) {
          b.x = w * (0.08 + ((i * 0.23 + this.elapsed * 0.03) % 0.86));
          b.y = h + 10 + (i % 4) * 14;
        }
        next.push(b);
      } else {
        b.alpha -= dt * 0.42;
        if (b.alpha > 0.02 && b.y > -20) {
          next.push(b);
        }
      }

      const pulse = 0.7 + 0.3 * Math.sin(b.phase * 1.2);
      const a = Math.max(0, Math.min(0.86, b.alpha * pulse * dimFactor));
      if (a <= 0.02) continue;

      this.ctx.fillStyle = this.darkMode
        ? `rgba(148,232,255,${(a * 0.20).toFixed(3)})`
        : `rgba(255,255,255,${(a * 0.50).toFixed(3)})`;
      this.ctx.strokeStyle = this.darkMode
        ? `rgba(182,242,255,${(a * 0.78).toFixed(3)})`
        : `rgba(38,142,188,${(a * 0.58).toFixed(3)})`;
      this.ctx.lineWidth = 1;
      this.ctx.beginPath();
      this.ctx.arc(b.x, b.y, b.radius, 0, Math.PI * 2);
      this.ctx.fill();
      this.ctx.stroke();

      this.ctx.fillStyle = `rgba(255,255,255,${(a * 0.9).toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.arc(b.x - b.radius * 0.32, b.y - b.radius * 0.32, Math.max(0.8, b.radius * 0.26), 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.bubbles = next;
  }

  private updateAndDrawRipples(dt: number): void {
    if (this.ripples.length === 0) return;
    const next: SeaRipple[] = [];
    for (let i = 0; i < this.ripples.length; i += 1) {
      const r = this.ripples[i];
      r.radius += r.speed * dt;
      const progress = r.radius / r.maxRadius;
      if (progress < 1) {
        const a = r.alpha * (1 - progress);
        this.ctx.strokeStyle = this.darkMode
          ? `rgba(142,232,255,${a.toFixed(3)})`
          : `rgba(28,136,184,${a.toFixed(3)})`;
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
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .opacity(this.sceneOpacity)
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => {
        this.canvasReady = true;
        this.ensureLoop();
      })
  }
}
