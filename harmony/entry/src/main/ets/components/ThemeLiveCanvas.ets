interface MatrixColumn {
  xRatio: number;
  y: number;
  speed: number;
  length: number;
  seed: number;
}

interface FloatingParticle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  size: number;
  phase: number;
  alpha: number;
  tint: number;
}

interface RippleRing {
  x: number;
  y: number;
  radius: number;
  maxRadius: number;
  speed: number;
  alpha: number;
}

interface ShootingStar {
  x: number;
  y: number;
  vx: number;
  vy: number;
  life: number;
  maxLife: number;
}

const MATRIX_CHARS: string[] = [
  '0', '1', '1', '0', '0', '1', '1', '0',
  '0', '1', 'λ', '{', '}', '/', '>', 'π',
  '0', '1', 'Σ', 'A', 'F', '9', '1', '0'
];

@Component
export struct ThemeLiveCanvas {
  @Prop @Watch('onThemeChange') themeId: string = 'mint';
  @Prop darkMode: boolean = false;
  @Prop dimmed: boolean = false;
  @Prop compact: boolean = false;
  @Prop @Watch('onBurstChange') burstSeq: number = 0;
  @Prop burstKind: string = 'send';
  @Prop @Watch('onTapChange') tapSeq: number = 0;
  @Prop tapX: number = 0;
  @Prop tapY: number = 0;

  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasReady: boolean = false;
  private loopTimer: number = -1;
  private lastTickMs: number = 0;
  private elapsed: number = 0;
  private canvasW: number = 0;
  private canvasH: number = 0;
  private initializedTheme: string = '';

  private energy: number = 0;
  private matrixCols: MatrixColumn[] = [];
  private particles: FloatingParticle[] = [];
  private ripples: RippleRing[] = [];
  private shootingStars: ShootingStar[] = [];

  aboutToDisappear(): void {
    this.stopLoop();
  }

  private onThemeChange(): void {
    this.initializedTheme = '';
    this.ripples = [];
    this.shootingStars = [];
    this.energy = 0;
  }

  private onBurstChange(): void {
    if (this.compact || this.burstSeq <= 0) return;
    const celebrate = this.burstKind === 'celebrate';
    this.energy = Math.max(this.energy, celebrate ? 1.0 : 0.65);
    const w = this.canvasW > 0 ? this.canvasW : 390;
    const h = this.canvasH > 0 ? this.canvasH : 840;
    if (this.themeId === 'aurora' || this.themeId === 'iris') {
      this.spawnShootingStar(w, h);
      if (celebrate) this.spawnShootingStar(w, h);
    } else if (this.themeId === 'paper' || this.themeId === 'ocean') {
      this.ripples.push({
        x: w * 0.68, y: h * 0.42, radius: 8, maxRadius: celebrate ? 180 : 120, speed: 52, alpha: 0.55
      });
    }
  }

  private onTapChange(): void {
    if (this.compact || this.tapSeq <= 0) return;
    this.energy = Math.max(this.energy, 0.55);
    const x = this.tapX > 0 ? this.tapX : this.canvasW * 0.5;
    const y = this.tapY > 0 ? this.tapY : this.canvasH * 0.5;
    if (this.themeId === 'paper' || this.themeId === 'terminal' || this.themeId === 'tokyo' || this.themeId === 'iris') {
      this.ripples.push({ x: x, y: y, radius: 6, maxRadius: 115, speed: 64, alpha: 0.55 });
    } else if (this.themeId === 'aurora') {
      this.spawnShootingStar(this.canvasW || 390, this.canvasH || 840);
    } else {
      for (let i = 0; i < 4; i += 1) {
        this.particles.push({
          x: x + (i - 1.5) * 14,
          y: y + (i % 2) * 8,
          vx: (i - 1.5) * 16,
          vy: -(28 + i * 8),
          size: 3.5 + (i % 3) * 1.6,
          phase: i * 1.4,
          alpha: 0.72,
          tint: i % 2
        });
      }
      if (this.particles.length > 42) this.particles = this.particles.slice(-42);
    }
  }

  private spawnShootingStar(w: number, h: number): void {
    const startX = w * (0.25 + ((this.elapsed * 0.37) % 0.65));
    const startY = h * (0.06 + ((this.elapsed * 0.23) % 0.22));
    this.shootingStars.push({
      x: startX, y: startY, vx: -260, vy: 120, life: 0, maxLife: 0.85
    });
  }

  private ensureLoop(): void {
    if (!this.canvasReady || this.loopTimer !== -1) return;
    this.lastTickMs = Date.now();
    this.loopTimer = setInterval(() => {
      this.tick();
    }, 33);
    this.tick();
  }

  private stopLoop(): void {
    if (this.loopTimer !== -1) {
      clearInterval(this.loopTimer);
      this.loopTimer = -1;
    }
  }

  private initScene(w: number, h: number): void {
    if (this.initializedTheme === this.themeId && this.canvasW > 0) return;
    this.initializedTheme = this.themeId;
    this.matrixCols = [];
    this.particles = [];
    this.ripples = [];

    if (this.themeId === 'terminal') {
      const count = this.compact ? 12 : 18;
      for (let i = 0; i < count; i += 1) {
        this.matrixCols.push({
          xRatio: (i + 0.5) / count,
          y: ((i * 73) % Math.max(120, Math.round(h))) - 80,
          speed: (this.compact ? 38 : 54) + (i % 5) * 16,
          length: (this.compact ? 5 : 8) + (i % 5) * 2,
          seed: i * 7 + 3
        });
      }
      return;
    }

    const pCount = this.compact ? 12 : 24;
    for (let i = 0; i < pCount; i += 1) {
      const rx = ((i * 0.37 + 0.11) % 0.94) + 0.03;
      const ry = ((i * 0.29 + 0.07) % 0.94) + 0.03;
      this.particles.push({
        x: rx * w,
        y: ry * h,
        vx: ((i % 2 === 0 ? 1 : -1) * (5 + (i % 4) * 3)),
        vy: -(12 + (i % 5) * 8),
        size: 2.2 + (i % 4) * 1.4,
        phase: i * 1.15,
        alpha: 0.32 + (i % 4) * 0.14,
        tint: i % 3
      });
    }

    if (this.themeId === 'paper') {
      this.ripples = [
        { x: w * 0.76, y: h * 0.24, radius: 14, maxRadius: this.compact ? 58 : 135, speed: 16, alpha: 0.32 },
        { x: w * 0.22, y: h * 0.72, radius: 42, maxRadius: this.compact ? 64 : 150, speed: 14, alpha: 0.28 }
      ];
    }
  }

  private tick(): void {
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    // 折叠屏展开/合拢或横竖屏旋转时按比例重映射粒子坐标，保证满屏分布
    if (this.canvasW > 0 && this.canvasH > 0 &&
      (Math.abs(w - this.canvasW) > 36 || Math.abs(h - this.canvasH) > 36)) {
      const sx = w / this.canvasW;
      const sy = h / this.canvasH;
      for (const p of this.particles) {
        p.x = Math.max(0, Math.min(w, p.x * sx));
        p.y = Math.max(0, Math.min(h, p.y * sy));
      }
    }
    this.canvasW = w;
    this.canvasH = h;
    this.initScene(w, h);

    const now = Date.now();
    const dt = Math.min(0.06, Math.max(0.01, (now - this.lastTickMs) / 1000));
    this.lastTickMs = now;
    this.elapsed += dt;
    if (this.energy > 0) this.energy = Math.max(0, this.energy - dt * 0.65);

    this.ctx.clearRect(0, 0, w, h);

    if (this.themeId === 'terminal') {
      this.drawTerminalMatrix(w, h, dt);
    } else if (this.themeId === 'sunset') {
      this.drawCaliforniaSunset(w, h, dt);
    } else if (this.themeId === 'aurora') {
      this.drawNorthernAurora(w, h, dt);
    } else if (this.themeId === 'tokyo') {
      this.drawTokyoCyberRain(w, h, dt);
    } else if (this.themeId === 'ocean') {
      this.drawOceanSunbeams(w, h, dt);
    } else if (this.themeId === 'mint') {
      this.drawForestFireflies(w, h, dt);
    } else if (this.themeId === 'paper') {
      this.drawZenPaperRipples(w, h, dt);
    } else if (this.themeId === 'iris') {
      this.drawTwilightConstellations(w, h, dt);
    } else if (this.themeId === 'amber') {
      this.drawCafeWarmEmbers(w, h, dt);
    } else if (this.themeId === 'crimson') {
      this.drawCrimsonLanterns(w, h, dt);
    }

    this.drawRipples(dt);
  }

  // 1. 极客终端：黑客帝国 1001010 代码雨 + 扫描线
  private drawTerminalMatrix(w: number, h: number, dt: number): void {
    const fontSize = this.compact ? 10 : 13;
    const stepY = fontSize + 3;
    const boost = 1 + this.energy * 1.4;
    const leadColor = this.darkMode ? '#A6FFD0' : '#0E7A45';
    const tailRgb = this.darkMode ? '72, 232, 148' : '18, 122, 70';

    this.ctx.save();
    this.ctx.font = `${fontSize}vp monospace`;
    for (const col of this.matrixCols) {
      col.y += col.speed * boost * dt;
      if (col.y - col.length * stepY > h + 20) {
        col.y = -20 - (col.seed % 5) * 18;
      }
      const x = col.xRatio * w;
      const tickStep = Math.floor(this.elapsed * 4 + col.seed);
      for (let j = 0; j < col.length; j += 1) {
        const cy = col.y - j * stepY;
        if (cy < -stepY || cy > h + stepY) continue;
        const ch = MATRIX_CHARS[(col.seed + j * 3 + tickStep) % MATRIX_CHARS.length];
        if (j === 0) {
          this.ctx.fillStyle = leadColor;
          this.ctx.globalAlpha = this.darkMode ? 0.82 : 0.62;
        } else {
          const fade = Math.max(0.05, 1 - j / col.length);
          this.ctx.fillStyle = `rgba(${tailRgb}, ${(fade * (this.darkMode ? 0.48 : 0.34)).toFixed(3)})`;
          this.ctx.globalAlpha = 1;
        }
        this.ctx.fillText(ch, x, cy);
      }
    }

    // 极细 CRT 扫描线
    this.ctx.globalAlpha = 1;
    this.ctx.fillStyle = this.darkMode ? 'rgba(92, 230, 153, 0.035)' : 'rgba(18, 107, 63, 0.03)';
    const scanStep = this.compact ? 5 : 6;
    for (let sy = 0; sy < h; sy += scanStep) {
      this.ctx.fillRect(0, sy, w, 1);
    }
    this.ctx.restore();
  }

  // 2. 落日橘海：加州夕阳、金色海面碎波与海岸棕榈剪影
  private drawCaliforniaSunset(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    const horizonY = h * (this.compact ? 0.60 : 0.68);
    const sunX = w * 0.72;
    const sunY = horizonY - (this.compact ? 14 : 36);
    const sunR = this.compact ? 20 : 48;

    this.ctx.save();
    // 落日余晖光晕
    const sunHalo = this.ctx.createRadialGradient(sunX, sunY, sunR * 0.2, sunX, sunY, sunR * 3.2);
    if (this.darkMode) {
      sunHalo.addColorStop(0, 'rgba(255, 196, 132, 0.52)');
      sunHalo.addColorStop(0.45, 'rgba(255, 126, 95, 0.24)');
      sunHalo.addColorStop(1, 'rgba(255, 126, 95, 0)');
    } else {
      sunHalo.addColorStop(0, 'rgba(255, 212, 138, 0.72)');
      sunHalo.addColorStop(0.45, 'rgba(255, 146, 102, 0.34)');
      sunHalo.addColorStop(1, 'rgba(255, 146, 102, 0)');
    }
    this.ctx.fillStyle = sunHalo;
    this.ctx.beginPath();
    this.ctx.arc(sunX, sunY, sunR * 3.2, 0, Math.PI * 2);
    this.ctx.fill();

    // 落日本体
    const sunBody = this.ctx.createLinearGradient(sunX, sunY - sunR, sunX, sunY + sunR);
    sunBody.addColorStop(0, this.darkMode ? 'rgba(255, 224, 168, 0.75)' : 'rgba(255, 232, 178, 0.92)');
    sunBody.addColorStop(1, this.darkMode ? 'rgba(255, 134, 96, 0.45)' : 'rgba(255, 146, 108, 0.68)');
    this.ctx.fillStyle = sunBody;
    this.ctx.beginPath();
    this.ctx.arc(sunX, sunY, sunR, 0, Math.PI * 2);
    this.ctx.fill();

    // 橘子海面渐变
    const seaGrad = this.ctx.createLinearGradient(0, horizonY, 0, h);
    if (this.darkMode) {
      seaGrad.addColorStop(0, 'rgba(255, 132, 92, 0.22)');
      seaGrad.addColorStop(0.5, 'rgba(138, 62, 68, 0.16)');
      seaGrad.addColorStop(1, 'rgba(32, 20, 24, 0.06)');
    } else {
      seaGrad.addColorStop(0, 'rgba(255, 166, 120, 0.34)');
      seaGrad.addColorStop(0.5, 'rgba(255, 198, 168, 0.22)');
      seaGrad.addColorStop(1, 'rgba(253, 246, 242, 0.05)');
    }
    this.ctx.fillStyle = seaGrad;
    this.ctx.fillRect(0, horizonY, w, h - horizonY);

    // 流动的金色海面碎波倒影
    const rows = this.compact ? 8 : 16;
    const shimmerBoost = 1 + this.energy * 0.7;
    for (let i = 0; i < rows; i += 1) {
      const p = i / rows;
      const ry = horizonY + 5 + p * (h - horizonY - 10);
      const spread = (sunR * (1.5 - p * 0.45)) * (0.85 + 0.15 * Math.sin(t * 2.1 + i));
      const waveX = Math.sin(t * 1.6 + i * 0.9) * (6 + p * 12) * shimmerBoost;
      const lineW = Math.max(10, spread * (0.45 + 0.45 * Math.cos(t * 1.9 + i * 1.3)));
      const a = (1 - p * 0.65) * (this.darkMode ? 0.42 : 0.56);
      this.ctx.fillStyle = this.darkMode
        ? `rgba(255, 206, 152, ${a.toFixed(3)})`
        : `rgba(255, 248, 224, ${a.toFixed(3)})`;
      this.ctx.fillRect(sunX + waveX - lineW * 0.5, ry, lineW, this.compact ? 1.5 : 2.2);
    }

    // 右侧微风轻摇的加州棕榈叶剪影
    const sway = Math.sin(t * 1.1) * (this.compact ? 3 : 7);
    const palmColor = this.darkMode ? 'rgba(48, 24, 26, 0.52)' : 'rgba(178, 86, 56, 0.18)';
    this.ctx.strokeStyle = palmColor;
    this.ctx.lineCap = 'round';
    const baseX = w + 6;
    const baseY = horizonY + (this.compact ? 18 : 65);
    const crownX = w - (this.compact ? 18 : 44) + sway * 0.5;
    const crownY = horizonY - (this.compact ? 18 : 74);
    this.ctx.lineWidth = this.compact ? 3 : 6;
    this.ctx.beginPath();
    this.ctx.moveTo(baseX, baseY);
    this.ctx.quadraticCurveTo(w - (this.compact ? 6 : 16), (baseY + crownY) * 0.5, crownX, crownY);
    this.ctx.stroke();

    const frondAngles: number[] = [-2.5, -2.0, -1.45, 2.75, 2.25];
    const frondLen = this.compact ? 26 : 64;
    this.ctx.lineWidth = this.compact ? 2.2 : 4.2;
    for (let f = 0; f < frondAngles.length; f += 1) {
      const ang = frondAngles[f] + sway * 0.012;
      const ex = crownX + Math.cos(ang) * frondLen;
      const ey = crownY + Math.sin(ang) * frondLen + (this.compact ? 8 : 20);
      this.ctx.beginPath();
      this.ctx.moveTo(crownX, crownY);
      this.ctx.quadraticCurveTo((crownX + ex) * 0.5, crownY - (this.compact ? 4 : 12), ex, ey);
      this.ctx.stroke();
    }

    // 漂浮的暖阳尘光
    for (const p of this.particles) {
      p.y += p.vy * 0.35 * dt;
      p.x += Math.sin(t + p.phase) * 8 * dt;
      if (p.y < -10) { p.y = h + 10; p.x = (p.x + w * 0.37) % w; }
      this.ctx.fillStyle = this.darkMode
        ? `rgba(255, 204, 150, ${(p.alpha * 0.45).toFixed(3)})`
        : `rgba(255, 236, 198, ${(p.alpha * 0.65).toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.arc(p.x, p.y, p.size * 0.8, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
  }

  // 3. 极光之境：流动北欧极光帷幕 + 闪烁星点 + 流星
  private drawNorthernAurora(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    const boost = 1 + this.energy * 0.45;
    this.ctx.save();

    const bands = 3;
    for (let b = 0; b < bands; b += 1) {
      const baseY = h * (0.14 + b * 0.13);
      const ribbonH = h * (this.compact ? 0.28 : 0.24);
      const grad = this.ctx.createLinearGradient(0, baseY - ribbonH * 0.4, 0, baseY + ribbonH);
      if (b === 0) {
        grad.addColorStop(0, 'rgba(64, 236, 212, 0)');
        grad.addColorStop(0.45, this.darkMode ? 'rgba(72, 235, 218, 0.24)' : 'rgba(18, 178, 196, 0.18)');
        grad.addColorStop(1, 'rgba(64, 236, 212, 0)');
      } else if (b === 1) {
        grad.addColorStop(0, 'rgba(130, 118, 255, 0)');
        grad.addColorStop(0.5, this.darkMode ? 'rgba(148, 122, 255, 0.22)' : 'rgba(116, 102, 232, 0.15)');
        grad.addColorStop(1, 'rgba(130, 118, 255, 0)');
      } else {
        grad.addColorStop(0, 'rgba(98, 224, 176, 0)');
        grad.addColorStop(0.5, this.darkMode ? 'rgba(98, 224, 176, 0.16)' : 'rgba(34, 168, 152, 0.12)');
        grad.addColorStop(1, 'rgba(98, 224, 176, 0)');
      }

      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      const segs = 18;
      for (let s = 0; s <= segs; s += 1) {
        const px = (s / segs) * w;
        const wave = Math.sin(t * (0.7 + b * 0.22) + s * 0.45 + b * 1.7) * (this.compact ? 14 : 34) * boost;
        const py = baseY + wave;
        if (s === 0) this.ctx.moveTo(px, py);
        else this.ctx.lineTo(px, py);
      }
      for (let s = segs; s >= 0; s -= 1) {
        const px = (s / segs) * w;
        const wave = Math.sin(t * (0.65 + b * 0.2) + s * 0.45 + b * 1.7 + 0.8) * (this.compact ? 10 : 24) * boost;
        this.ctx.lineTo(px, baseY + ribbonH + wave);
      }
      this.ctx.closePath();
      this.ctx.fill();
    }

    // 闪烁星点
    for (const p of this.particles) {
      const twinkle = 0.35 + 0.65 * Math.abs(Math.sin(t * 1.6 + p.phase));
      this.ctx.fillStyle = this.darkMode
        ? `rgba(218, 246, 255, ${(p.alpha * twinkle).toFixed(3)})`
        : `rgba(14, 107, 138, ${(p.alpha * twinkle * 0.45).toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.arc(p.x, p.y * 0.72, Math.max(1.0, p.size * 0.42), 0, Math.PI * 2);
      this.ctx.fill();
    }

    this.drawShootingStars(dt);
    this.ctx.restore();
  }

  // 4. 东京夜色：赛博霓虹雨丝 + 底部透视网格 + 城市光斑
  private drawTokyoCyberRain(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    const boost = 1 + this.energy * 0.8;
    this.ctx.save();

    // 底部透视赛博网格
    const gridTop = h * (this.compact ? 0.66 : 0.76);
    const gridColor = this.darkMode ? 'rgba(138, 158, 255, 0.14)' : 'rgba(67, 82, 181, 0.10)';
    this.ctx.strokeStyle = gridColor;
    this.ctx.lineWidth = 1;
    const hLines = this.compact ? 4 : 7;
    const offset = (t * 0.45) % 1;
    for (let i = 0; i < hLines; i += 1) {
      const f = (i + offset) / hLines;
      const y = gridTop + (f * f) * (h - gridTop);
      this.ctx.beginPath();
      this.ctx.moveTo(0, y);
      this.ctx.lineTo(w, y);
      this.ctx.stroke();
    }
    const vLines = 8;
    const vpX = w * 0.5;
    for (let j = -vLines; j <= vLines; j += 1) {
      this.ctx.beginPath();
      this.ctx.moveTo(vpX + j * (w * 0.055), gridTop);
      this.ctx.lineTo(vpX + j * (w * 0.22), h);
      this.ctx.stroke();
    }

    // 斜向霓虹雨丝
    this.ctx.lineWidth = 1.2;
    for (const p of this.particles) {
      p.y += (135 + p.size * 22) * boost * dt;
      p.x -= 28 * dt;
      if (p.y > h + 20) {
        p.y = -24;
        p.x = ((p.x + w * 1.37) % (w + 60));
      }
      const len = (this.compact ? 10 : 18) + p.size * 2.5;
      const color = p.tint === 0
        ? (this.darkMode ? `rgba(154, 168, 255, ${(p.alpha * 0.65).toFixed(3)})` : `rgba(67, 82, 181, ${(p.alpha * 0.42).toFixed(3)})`)
        : (this.darkMode ? `rgba(187, 154, 247, ${(p.alpha * 0.55).toFixed(3)})` : `rgba(126, 92, 214, ${(p.alpha * 0.35).toFixed(3)})`);
      this.ctx.strokeStyle = color;
      this.ctx.beginPath();
      this.ctx.moveTo(p.x, p.y);
      this.ctx.lineTo(p.x + 3.5, p.y - len);
      this.ctx.stroke();
    }
    this.ctx.restore();
  }

  // 5. 晴空蔚蓝：深海丁达尔光柱 + 上升微光气泡
  private drawOceanSunbeams(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    this.ctx.save();

    // 4 道柔和斜向丁达尔水下光柱
    for (let i = 0; i < 4; i += 1) {
      const sway = Math.sin(t * 0.55 + i * 1.4) * (this.compact ? 12 : 28);
      const topX = w * (0.18 + i * 0.22) + sway;
      const rayW = this.compact ? 26 : 58;
      const grad = this.ctx.createLinearGradient(topX, 0, topX - 40, h * 0.78);
      if (this.darkMode) {
        grad.addColorStop(0, 'rgba(130, 198, 255, 0.14)');
        grad.addColorStop(1, 'rgba(130, 198, 255, 0)');
      } else {
        grad.addColorStop(0, 'rgba(72, 152, 238, 0.13)');
        grad.addColorStop(1, 'rgba(72, 152, 238, 0)');
      }
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.moveTo(topX, 0);
      this.ctx.lineTo(topX + rayW, 0);
      this.ctx.lineTo(topX + rayW * 1.7 - 55, h * 0.82);
      this.ctx.lineTo(topX - 55, h * 0.82);
      this.ctx.closePath();
      this.ctx.fill();
    }

    // 摇曳上升的半透明水泡
    for (const p of this.particles) {
      p.y += p.vy * (1 + this.energy * 0.7) * dt;
      const wobbleX = p.x + Math.sin(t * 1.8 + p.phase) * 9;
      if (p.y < -18) {
        p.y = h + 16;
        p.x = (p.x + w * 0.27) % w;
      }
      const r = p.size * (this.compact ? 0.9 : 1.35);
      this.ctx.strokeStyle = this.darkMode
        ? `rgba(165, 208, 255, ${(p.alpha * 0.55).toFixed(3)})`
        : `rgba(34, 91, 158, ${(p.alpha * 0.34).toFixed(3)})`;
      this.ctx.lineWidth = 1;
      this.ctx.beginPath();
      this.ctx.arc(wobbleX, p.y, r, 0, Math.PI * 2);
      this.ctx.stroke();

      // 气泡小高光点
      this.ctx.fillStyle = this.darkMode
        ? `rgba(220, 240, 255, ${(p.alpha * 0.65).toFixed(3)})`
        : `rgba(255, 255, 255, ${(p.alpha * 0.85).toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.arc(wobbleX - r * 0.32, p.y - r * 0.32, Math.max(0.9, r * 0.24), 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
  }

  // 6. 雾松玻璃：林间晨雾 + 游弋发光萤火虫
  private drawForestFireflies(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    this.ctx.save();

    // 底部缓慢流动的薄荷林间晨雾
    const mistY = h * 0.72;
    const mistGrad = this.ctx.createLinearGradient(0, mistY, 0, h);
    mistGrad.addColorStop(0, 'rgba(143, 227, 200, 0)');
    mistGrad.addColorStop(1, this.darkMode ? 'rgba(64, 168, 138, 0.14)' : 'rgba(130, 212, 186, 0.18)');
    this.ctx.fillStyle = mistGrad;
    this.ctx.fillRect(0, mistY, w, h - mistY);

    // 漫游呼吸的萤火虫
    for (const p of this.particles) {
      p.x += Math.cos(t * 0.65 + p.phase) * 14 * dt;
      p.y += (Math.sin(t * 0.85 + p.phase * 1.3) * 12 - 4 - this.energy * 18) * dt;
      if (p.y < -16) p.y = h + 14;
      if (p.x < -16) p.x = w + 14;
      if (p.x > w + 16) p.x = -14;
      const glow = 0.3 + 0.7 * (0.5 + 0.5 * Math.sin(t * 2.2 + p.phase));
      const r = p.size * (this.compact ? 2.2 : 3.2);
      const grad = this.ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, r);
      const coreRgb = p.tint === 0 ? (this.darkMode ? '168, 255, 222' : '22, 148, 118') : (this.darkMode ? '240, 245, 168' : '78, 168, 128');
      grad.addColorStop(0, `rgba(${coreRgb}, ${(p.alpha * glow).toFixed(3)})`);
      grad.addColorStop(1, `rgba(${coreRgb}, 0)`);
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
  }

  // 7. 京都纸墨：枯山水同心涟漪 + 水墨淡云
  private drawZenPaperRipples(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    this.ctx.save();

    // 极淡的水墨云纹（右上 & 左下）
    const inkColor = this.darkMode ? 'rgba(240, 163, 132, 0.07)' : 'rgba(148, 118, 92, 0.08)';
    this.ctx.fillStyle = inkColor;
    const cx = w * 0.84 + Math.sin(t * 0.35) * 10;
    const cy = h * 0.16 + Math.cos(t * 0.3) * 6;
    this.ctx.beginPath();
    this.ctx.arc(cx, cy, this.compact ? 38 : 96, 0, Math.PI * 2);
    this.ctx.fill();

    // 周期性自动生成静谧涟漪
    if (this.ripples.length < (this.compact ? 2 : 3) && Math.floor(t * 10) % 28 === 0) {
      this.ripples.push({
        x: w * (0.18 + ((t * 0.31) % 0.68)),
        y: h * (0.16 + ((t * 0.43) % 0.68)),
        radius: 6,
        maxRadius: this.compact ? 60 : 145,
        speed: 18,
        alpha: 0.34
      });
    }

    // 极细枯山水流纹线
    this.ctx.strokeStyle = this.darkMode ? 'rgba(240, 163, 132, 0.07)' : 'rgba(158, 62, 38, 0.07)';
    this.ctx.lineWidth = 1;
    const waveCount = this.compact ? 3 : 5;
    for (let k = 0; k < waveCount; k += 1) {
      const yBase = h * (0.76 + k * 0.045);
      this.ctx.beginPath();
      for (let x = 0; x <= w; x += 24) {
        const y = yBase + Math.sin(x * 0.015 + t * 0.45 + k * 0.7) * 5;
        if (x === 0) this.ctx.moveTo(x, y);
        else this.ctx.lineTo(x, y);
      }
      this.ctx.stroke();
    }
    this.ctx.restore();
    // dt 仅用于保持统一签名
    if (dt < 0) return;
  }

  // 8. 暮色鸢尾：星河星座连线 + 柔和星尘
  private drawTwilightConstellations(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    this.ctx.save();
    for (const p of this.particles) {
      p.x += p.vx * 0.45 * dt;
      p.y += Math.sin(t * 0.5 + p.phase) * 5 * dt;
      if (p.x < 0) p.x = w;
      if (p.x > w) p.x = 0;
    }

    const maxDist = this.compact ? 64 : 112;
    const lineRgb = this.darkMode ? '208, 184, 253' : '104, 69, 160';
    this.ctx.lineWidth = 0.8;
    for (let i = 0; i < this.particles.length; i += 1) {
      const a = this.particles[i];
      for (let j = i + 1; j < this.particles.length; j += 1) {
        const b = this.particles[j];
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < maxDist) {
          const alpha = (1 - dist / maxDist) * (this.darkMode ? 0.24 : 0.16) * (1 + this.energy * 0.7);
          this.ctx.strokeStyle = `rgba(${lineRgb}, ${alpha.toFixed(3)})`;
          this.ctx.beginPath();
          this.ctx.moveTo(a.x, a.y);
          this.ctx.lineTo(b.x, b.y);
          this.ctx.stroke();
        }
      }
      const pulse = 0.5 + 0.5 * Math.sin(t * 1.8 + a.phase);
      this.ctx.fillStyle = `rgba(${lineRgb}, ${(a.alpha * pulse).toFixed(3)})`;
      this.ctx.beginPath();
      this.ctx.arc(a.x, a.y, Math.max(1.2, a.size * 0.45), 0, Math.PI * 2);
      this.ctx.fill();
    }

    this.drawShootingStars(dt);
    this.ctx.restore();
  }

  // 9. 焦糖拿铁：袅袅暖汽 + 温暖炉火浮光
  private drawCafeWarmEmbers(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    this.ctx.save();

    // 右下角缓慢升腾的咖啡热气丝
    const steamColor = this.darkMode ? 'rgba(246, 200, 138, 0.10)' : 'rgba(166, 112, 48, 0.10)';
    this.ctx.strokeStyle = steamColor;
    this.ctx.lineWidth = this.compact ? 2.5 : 4;
    this.ctx.lineCap = 'round';
    for (let s = 0; s < 3; s += 1) {
      const baseX = w * (0.68 + s * 0.08);
      this.ctx.beginPath();
      for (let step = 0; step <= 14; step += 1) {
        const p = step / 14;
        const y = h - p * h * 0.45;
        const x = baseX + Math.sin(t * 1.1 + p * 4.5 + s * 1.6) * (8 + p * 14);
        if (step === 0) this.ctx.moveTo(x, y);
        else this.ctx.lineTo(x, y);
      }
      this.ctx.stroke();
    }

    // 温暖上升的金色余烬光尘
    for (const p of this.particles) {
      p.y += p.vy * (0.75 + this.energy * 0.8) * dt;
      p.x += Math.sin(t * 1.2 + p.phase) * 10 * dt;
      if (p.y < -12) {
        p.y = h + 12;
        p.x = (p.x + w * 0.31) % w;
      }
      const glow = 0.45 + 0.55 * Math.sin(t * 2.4 + p.phase);
      const r = p.size * 1.6;
      const grad = this.ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, r);
      const rgb = this.darkMode ? '255, 206, 138' : '196, 126, 36';
      grad.addColorStop(0, `rgba(${rgb}, ${(p.alpha * glow).toFixed(3)})`);
      grad.addColorStop(1, `rgba(${rgb}, 0)`);
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
  }

  // 10. 朱砂丹霞：温暖孔明灯火点 + 鎏金星火上升
  private drawCrimsonLanterns(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    this.ctx.save();
    for (let i = 0; i < this.particles.length; i += 1) {
      const p = this.particles[i];
      p.y += p.vy * (0.65 + this.energy * 0.9) * dt;
      p.x += Math.sin(t * 0.9 + p.phase) * 9 * dt;
      if (p.y < -20) {
        p.y = h + 18;
        p.x = (p.x + w * 0.29) % w;
      }
      const flicker = 0.65 + 0.35 * Math.sin(t * 2.6 + p.phase);
      if (i % 4 === 0) {
        // 温暖柔和的孔明灯剪影与灯晕
        const r = p.size * (this.compact ? 2.4 : 3.4);
        const halo = this.ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, r);
        halo.addColorStop(0, this.darkMode
          ? `rgba(255, 206, 138, ${(p.alpha * flicker * 0.72).toFixed(3)})`
          : `rgba(226, 92, 68, ${(p.alpha * flicker * 0.36).toFixed(3)})`);
        halo.addColorStop(1, 'rgba(255, 148, 96, 0)');
        this.ctx.fillStyle = halo;
        this.ctx.beginPath();
        this.ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
        this.ctx.fill();

        const lw = p.size * (this.compact ? 1.0 : 1.45);
        const lh = lw * 1.25;
        this.ctx.fillStyle = this.darkMode
          ? `rgba(255, 224, 168, ${(p.alpha * flicker * 0.85).toFixed(3)})`
          : `rgba(206, 74, 54, ${(p.alpha * flicker * 0.48).toFixed(3)})`;
        this.ctx.fillRect(p.x - lw * 0.5, p.y - lh * 0.5, lw, lh);
      } else {
        // 细碎鎏金星火
        this.ctx.fillStyle = this.darkMode
          ? `rgba(255, 186, 152, ${(p.alpha * flicker * 0.7).toFixed(3)})`
          : `rgba(181, 53, 44, ${(p.alpha * flicker * 0.34).toFixed(3)})`;
        this.ctx.beginPath();
        this.ctx.arc(p.x, p.y, Math.max(1.2, p.size * 0.45), 0, Math.PI * 2);
        this.ctx.fill();
      }
    }
    this.ctx.restore();
  }

  private drawRipples(dt: number): void {
    if (!this.ripples.length) return;
    const next: RippleRing[] = [];
    const rgb = this.themeId === 'terminal'
      ? (this.darkMode ? '92, 230, 153' : '18, 107, 63')
      : this.themeId === 'tokyo'
        ? (this.darkMode ? '154, 168, 255' : '67, 82, 181')
        : this.themeId === 'ocean'
          ? (this.darkMode ? '158, 198, 255' : '34, 91, 158')
          : (this.darkMode ? '240, 163, 132' : '158, 62, 38');

    this.ctx.save();
    this.ctx.lineWidth = 1.1;
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

  private drawShootingStars(dt: number): void {
    if (!this.shootingStars.length) return;
    const next: ShootingStar[] = [];
    this.ctx.save();
    this.ctx.lineWidth = 1.6;
    for (const s of this.shootingStars) {
      s.life += dt;
      if (s.life >= s.maxLife) continue;
      s.x += s.vx * dt;
      s.y += s.vy * dt;
      const a = (1 - s.life / s.maxLife) * (this.darkMode ? 0.85 : 0.55);
      const tailX = s.x - s.vx * 0.16;
      const tailY = s.y - s.vy * 0.16;
      const grad = this.ctx.createLinearGradient(s.x, s.y, tailX, tailY);
      grad.addColorStop(0, `rgba(255, 255, 255, ${a.toFixed(3)})`);
      grad.addColorStop(1, 'rgba(255, 255, 255, 0)');
      this.ctx.strokeStyle = grad;
      this.ctx.beginPath();
      this.ctx.moveTo(s.x, s.y);
      this.ctx.lineTo(tailX, tailY);
      this.ctx.stroke();
      next.push(s);
    }
    this.ctx.restore();
    this.shootingStars = next;
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .opacity(this.compact ? 0.92 : (this.dimmed ? 0.42 : 0.88))
      .animation({ duration: 300, curve: Curve.EaseOut })
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => {
        this.canvasReady = true;
        this.ensureLoop();
      })
  }
}
