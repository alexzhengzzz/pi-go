interface InkLeaf {
  x: number;
  y: number;
  vx: number;
  vy: number;
  length: number;
  angle: number;
  vAngle: number;
  flip: number;
  vFlip: number;
  swayAmp: number;
  swayFreq: number;
  phase: number;
  alpha: number;
  gold: boolean;
  ambient: boolean;
}

interface InkRipple {
  x: number;
  y: number;
  radius: number;
  maxRadius: number;
  speed: number;
  alpha: number;
  ring: number;
}

interface MistBand {
  x: number;
  yRatio: number;
  rx: number;
  ry: number;
  speed: number;
  alpha: number;
  phase: number;
}

interface InkCrane {
  x: number;
  y: number;
  vx: number;
  vy: number;
  scale: number;
  wingPhase: number;
  alpha: number;
}

@Component
export struct InkScene {
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
  private initialized: boolean = false;

  private windGust: number = 0;
  private leaves: InkLeaf[] = [];
  private ripples: InkRipple[] = [];
  private mists: MistBand[] = [];
  private cranes: InkCrane[] = [];

  aboutToDisappear(): void {
    this.stopLoop();
  }

  private onBurstChange(): void {
    if (this.compact || this.burstSeq <= 0) return;
    const celebrate = this.burstKind === 'celebrate';
    this.windGust = Math.max(this.windGust, celebrate ? 1.0 : 0.65);
    const w = this.canvasW > 0 ? this.canvasW : 390;
    const h = this.canvasH > 0 ? this.canvasH : 840;
    const count = celebrate ? 12 : 5;
    for (let i = 0; i < count; i += 1) {
      const ratio = count > 1 ? i / (count - 1) : 0.5;
      this.leaves.push({
        x: w * (0.48 + ratio * 0.50),
        y: 12 + (i % 4) * 34,
        vx: -(24 + (i % 4) * 9),
        vy: celebrate ? (74 + (i % 4) * 14) : (60 + (i % 3) * 12),
        length: 8 + (i % 4) * 2.4,
        angle: i * 0.7,
        vAngle: (i % 2 === 0 ? 1 : -1) * (1.2 + (i % 3) * 0.4),
        flip: i * 0.8,
        vFlip: 1.9 + (i % 3) * 0.5,
        swayAmp: 16 + (i % 3) * 7,
        swayFreq: 1.3 + (i % 3) * 0.3,
        phase: i * 1.1,
        alpha: celebrate ? 0.68 : 0.55,
        gold: i % 3 === 0,
        ambient: false
      });
    }
    this.ripples.push({
      x: w * 0.72, y: h * 0.78, radius: 8, maxRadius: celebrate ? 150 : 100, speed: 40, alpha: 0.38, ring: 0
    });
    if (celebrate) {
      this.cranes.push({
        x: w + 24, y: h * 0.34, vx: -42, vy: -8, scale: 1.0, wingPhase: 0, alpha: 0.65
      });
    }
  }

  private onTapChange(): void {
    if (this.compact || this.tapSeq <= 0) return;
    this.windGust = Math.max(this.windGust, 0.55);
    const x = this.tapX > 0 ? this.tapX : (this.canvasW || 390) * 0.5;
    const y = this.tapY > 0 ? this.tapY : (this.canvasH || 840) * 0.5;
    // 点墨成双圈水墨涟漪
    this.ripples.push(
      { x: x, y: y, radius: 5, maxRadius: 118, speed: 56, alpha: 0.46, ring: 0 },
      { x: x, y: y, radius: 2, maxRadius: 82, speed: 42, alpha: 0.32, ring: 1 }
    );
    const vxList: number[] = [-34, -14, 8, 28];
    for (let i = 0; i < 4; i += 1) {
      this.leaves.push({
        x: x,
        y: y,
        vx: vxList[i] - 8,
        vy: 54 + (i % 3) * 14,
        length: 8.5 + (i % 3) * 2.0,
        angle: i * 1.1,
        vAngle: (i % 2 === 0 ? 1 : -1) * 1.6,
        flip: i * 0.9,
        vFlip: 2.2,
        swayAmp: 15,
        swayFreq: 1.5,
        phase: i * 1.2,
        alpha: 0.62,
        gold: i === 1,
        ambient: false
      });
    }
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

  private initElements(w: number, h: number): void {
    if (this.initialized && this.canvasW > 0) return;
    this.initialized = true;
    this.mists = [
      { x: w * 0.25, yRatio: 0.72, rx: w * 0.55, ry: h * 0.08, speed: 7, alpha: 0.22, phase: 0.5 },
      { x: w * 0.75, yRatio: 0.80, rx: w * 0.62, ry: h * 0.09, speed: -5.5, alpha: 0.26, phase: 2.1 },
      { x: w * 0.50, yRatio: 0.88, rx: w * 0.70, ry: h * 0.08, speed: 4.2, alpha: 0.20, phase: 4.0 }
    ];
    this.leaves = [];
    const leafCount = this.compact ? 4 : 9;
    for (let i = 0; i < leafCount; i += 1) {
      this.leaves.push({
        x: w * (0.28 + ((i * 0.21) % 0.76)),
        y: (i / leafCount) * (h + 30) - 20,
        vx: -(10 + (i % 3) * 5),
        vy: (this.compact ? 26 : 36) + (i % 4) * 8,
        length: (this.compact ? 6.5 : 9.5) + (i % 3) * 2.5,
        angle: i * 0.9,
        vAngle: (i % 2 === 0 ? 1 : -1) * (0.7 + (i % 3) * 0.35),
        flip: i * 1.1,
        vFlip: 1.4 + (i % 3) * 0.45,
        swayAmp: 11 + (i % 3) * 5,
        swayFreq: 1.0 + (i % 3) * 0.25,
        phase: i * 1.4,
        alpha: 0.36 + (i % 3) * 0.12,
        gold: i % 4 === 0,
        ambient: true
      });
    }
    this.cranes = this.compact ? [] : [
      { x: w * 0.82, y: h * 0.46, vx: -11, vy: -1.8, scale: 0.85, wingPhase: 0.3, alpha: 0.45 },
      { x: w * 0.92, y: h * 0.50, vx: -9.5, vy: -1.4, scale: 0.62, wingPhase: 1.9, alpha: 0.34 }
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
    if (this.windGust > 0) this.windGust = Math.max(0, this.windGust - dt * 0.5);

    this.ctx.clearRect(0, 0, w, h);

    // 1. 远景胧月与柔和天色晕染（右上角，左中部大面积素净留白）
    this.drawInkMoon(w, h);

    // 2. 三层写意水墨远山（远山如黛，自带微妙层叠景深）
    this.drawInkMountains(w, h);

    // 3. 缓慢游动的山间水墨云岚
    this.drawMistBands(w, h, dt);

    // 4. 远山间振翅滑翔的水墨飞鹤
    this.updateAndDrawCranes(w, h, dt);

    // 5. 右上角随风轻摇的写意墨竹枝叶
    this.drawInkBamboo(w, h);

    // 6. 右下角精致朱砂小印（国风画卷点睛）
    this.drawCinnabarSeal(w, h);

    // 7. 飘落墨竹叶与细碎金箔微尘（完整落出底部）
    this.updateAndDrawLeaves(w, h, dt);

    // 8. 点墨同心水墨涟漪
    this.updateAndDrawRipples(dt);
  }

  private drawInkMoon(w: number, h: number): void {
    const mx = w * 0.78;
    const my = h * (this.compact ? 0.28 : 0.17);
    const mr = this.compact ? 16 : 36;
    const pulse = 0.94 + 0.06 * Math.sin(this.elapsed * 0.8);

    this.ctx.save();
    const halo = this.ctx.createRadialGradient(mx, my, mr * 0.25, mx, my, mr * 3.1 * pulse);
    if (this.darkMode) {
      halo.addColorStop(0, 'rgba(222, 232, 242, 0.28)');
      halo.addColorStop(0.45, 'rgba(168, 184, 202, 0.10)');
      halo.addColorStop(1, 'rgba(168, 184, 202, 0)');
    } else {
      halo.addColorStop(0, 'rgba(214, 210, 198, 0.42)');
      halo.addColorStop(0.5, 'rgba(182, 184, 178, 0.14)');
      halo.addColorStop(1, 'rgba(182, 184, 178, 0)');
    }
    this.ctx.fillStyle = halo;
    this.ctx.beginPath();
    this.ctx.arc(mx, my, mr * 3.1 * pulse, 0, Math.PI * 2);
    this.ctx.fill();

    this.ctx.fillStyle = this.darkMode ? 'rgba(232, 240, 248, 0.42)' : 'rgba(255, 253, 246, 0.78)';
    this.ctx.beginPath();
    this.ctx.arc(mx, my, mr, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.restore();
  }

  private drawInkMountains(w: number, h: number): void {
    const t = this.elapsed;
    const drift1 = Math.sin(t * 0.25) * 3;
    const drift2 = Math.cos(t * 0.20) * 4;

    this.ctx.save();
    // 第一层：极淡远山（偏右侧起伏，左侧渐隐入留白）
    const grad1 = this.ctx.createLinearGradient(0, h * 0.62, 0, h);
    if (this.darkMode) {
      grad1.addColorStop(0, 'rgba(130, 145, 162, 0.16)');
      grad1.addColorStop(1, 'rgba(17, 19, 22, 0.02)');
    } else {
      grad1.addColorStop(0, 'rgba(72, 86, 98, 0.12)');
      grad1.addColorStop(1, 'rgba(246, 245, 240, 0.01)');
    }
    this.ctx.fillStyle = grad1;
    this.ctx.beginPath();
    this.ctx.moveTo(0, h);
    this.ctx.lineTo(0, h * 0.84);
    this.ctx.bezierCurveTo(w * 0.24, h * 0.81, w * 0.42, h * 0.74, w * 0.62 + drift1, h * 0.67);
    this.ctx.bezierCurveTo(w * 0.76 + drift1, h * 0.61, w * 0.88, h * 0.65, w, h * 0.59);
    this.ctx.lineTo(w, h);
    this.ctx.closePath();
    this.ctx.fill();

    // 第二层：中景水墨山峦
    const grad2 = this.ctx.createLinearGradient(0, h * 0.72, 0, h);
    if (this.darkMode) {
      grad2.addColorStop(0, 'rgba(92, 108, 124, 0.26)');
      grad2.addColorStop(1, 'rgba(17, 19, 22, 0.06)');
    } else {
      grad2.addColorStop(0, 'rgba(54, 66, 78, 0.20)');
      grad2.addColorStop(1, 'rgba(246, 245, 240, 0.03)');
    }
    this.ctx.fillStyle = grad2;
    this.ctx.beginPath();
    this.ctx.moveTo(0, h);
    this.ctx.lineTo(0, h * 0.90);
    this.ctx.bezierCurveTo(w * 0.22, h * 0.88, w * 0.48, h * 0.83, w * 0.68 + drift2, h * 0.75);
    this.ctx.bezierCurveTo(w * 0.82 + drift2, h * 0.70, w * 0.92, h * 0.73, w, h * 0.69);
    this.ctx.lineTo(w, h);
    this.ctx.closePath();
    this.ctx.fill();

    // 第三层：近景浓墨山脚与右下角孤舟剪影
    const grad3 = this.ctx.createLinearGradient(0, h * 0.84, 0, h);
    if (this.darkMode) {
      grad3.addColorStop(0, 'rgba(64, 76, 90, 0.34)');
      grad3.addColorStop(1, 'rgba(14, 16, 20, 0.14)');
    } else {
      grad3.addColorStop(0, 'rgba(38, 48, 58, 0.26)');
      grad3.addColorStop(1, 'rgba(38, 48, 58, 0.05)');
    }
    this.ctx.fillStyle = grad3;
    this.ctx.beginPath();
    this.ctx.moveTo(w * 0.32, h);
    this.ctx.quadraticCurveTo(w * 0.64, h * 0.87, w, h * 0.80);
    this.ctx.lineTo(w, h);
    this.ctx.closePath();
    this.ctx.fill();

    // 极简水墨孤舟（右下水域轻缓起伏）
    if (!this.compact) {
      const bx = w * 0.56 + Math.sin(t * 0.4) * 5;
      const by = h * 0.895 + Math.cos(t * 0.9) * 1.4;
      this.ctx.fillStyle = this.darkMode ? 'rgba(186, 198, 212, 0.34)' : 'rgba(38, 48, 58, 0.42)';
      this.ctx.beginPath();
      this.ctx.moveTo(bx - 16, by);
      this.ctx.quadraticCurveTo(bx, by + 5.5, bx + 18, by - 1.5);
      this.ctx.lineTo(bx + 12, by + 2.5);
      this.ctx.quadraticCurveTo(bx, by + 6, bx - 12, by + 2);
      this.ctx.closePath();
      this.ctx.fill();
      // 舟上蓑笠客微影
      this.ctx.beginPath();
      this.ctx.arc(bx - 1, by - 3.5, 2.2, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
  }

  private drawMistBands(w: number, h: number, dt: number): void {
    this.ctx.save();
    for (const m of this.mists) {
      m.x += m.speed * dt;
      if (m.x > w + m.rx * 0.6) m.x = -m.rx * 0.5;
      if (m.x < -m.rx * 0.6) m.x = w + m.rx * 0.5;
      const cy = h * m.yRatio + Math.sin(this.elapsed * 0.5 + m.phase) * 5;
      const grad = this.ctx.createRadialGradient(m.x, cy, m.ry * 0.2, m.x, cy, m.rx);
      if (this.darkMode) {
        grad.addColorStop(0, `rgba(180, 194, 210, ${(m.alpha * 0.32).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(180, 194, 210, 0)');
      } else {
        grad.addColorStop(0, `rgba(255, 254, 250, ${(m.alpha * 1.9).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(255, 254, 250, 0)');
      }
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.ellipse(m.x, cy, m.rx, m.ry, 0, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
  }

  private drawInkBamboo(w: number, h: number): void {
    const t = this.elapsed;
    const boost = 1 + this.windGust * 0.7;
    const sway1 = Math.sin(t * 1.05) * (this.compact ? 4 : 9) * boost;
    const sway2 = Math.sin(t * 1.25 + 1.1) * (this.compact ? 5 : 11) * boost;

    const stalkColor = this.darkMode ? 'rgba(188, 200, 214, 0.36)' : 'rgba(42, 54, 64, 0.38)';
    const leafDark = this.darkMode ? 'rgba(202, 214, 226, 0.42)' : 'rgba(34, 46, 56, 0.44)';
    const leafLight = this.darkMode ? 'rgba(164, 178, 194, 0.24)' : 'rgba(72, 86, 98, 0.24)';

    this.ctx.save();
    this.ctx.lineCap = 'round';

    // 主竹枝（从右上角优雅垂弧探入）
    const bx0 = w + 4;
    const by0 = h * 0.04;
    const bx1 = w * 0.78 + sway1 * 0.45;
    const by1 = h * (this.compact ? 0.28 : 0.17);
    const bx2 = w * 0.62 + sway1;
    const by2 = h * (this.compact ? 0.44 : 0.29);

    this.ctx.strokeStyle = stalkColor;
    this.ctx.lineWidth = this.compact ? 2.0 : 3.2;
    this.ctx.beginPath();
    this.ctx.moveTo(bx0, by0);
    this.ctx.quadraticCurveTo(w * 0.88, h * 0.08, bx1, by1);
    this.ctx.stroke();

    this.ctx.lineWidth = this.compact ? 1.3 : 2.1;
    this.ctx.beginPath();
    this.ctx.moveTo(bx1, by1);
    this.ctx.quadraticCurveTo(w * 0.70 + sway1 * 0.7, h * (this.compact ? 0.36 : 0.22), bx2, by2);
    this.ctx.stroke();

    // 副竹枝（右侧中上探出）
    const sx0 = w + 4;
    const sy0 = h * (this.compact ? 0.24 : 0.16);
    const sx1 = w * 0.74 + sway2;
    const sy1 = h * (this.compact ? 0.48 : 0.36);
    this.ctx.lineWidth = this.compact ? 1.2 : 2.0;
    this.ctx.beginPath();
    this.ctx.moveTo(sx0, sy0);
    this.ctx.quadraticCurveTo(w * 0.86 + sway2 * 0.5, h * (this.compact ? 0.34 : 0.25), sx1, sy1);
    this.ctx.stroke();

    // 写意墨竹叶簇（尖锐飘逸的国画撇捺叶形）
    const leafScale = this.compact ? 0.52 : 1.0;
    this.drawBambooLeafCluster(bx1, by1, 2.5 + sway1 * 0.015, leafScale, leafDark);
    this.drawBambooLeafCluster(bx2, by2, 2.25 + sway1 * 0.02, leafScale * 0.92, leafLight);
    this.drawBambooLeafCluster(sx1, sy1, 2.45 + sway2 * 0.02, leafScale * 0.88, leafDark);
    this.drawBambooLeafCluster(w * 0.89 + sway2 * 0.3, h * (this.compact ? 0.36 : 0.26), 2.15 + sway2 * 0.015, leafScale * 0.85, leafLight);
    this.ctx.restore();
  }

  private drawBambooLeafCluster(x: number, y: number, baseAngle: number, scale: number, color: string): void {
    const offsets: number[] = [-0.42, -0.14, 0.18, 0.48];
    const lengths: number[] = [28, 36, 32, 22];
    this.ctx.fillStyle = color;
    for (let i = 0; i < offsets.length; i += 1) {
      const a = baseAngle + offsets[i];
      const len = lengths[i] * scale;
      const wid = 4.6 * scale;
      this.ctx.save();
      this.ctx.translate(x, y);
      this.ctx.rotate(a);
      this.ctx.beginPath();
      this.ctx.moveTo(0, 0);
      this.ctx.quadraticCurveTo(len * 0.38, -wid, len, 0);
      this.ctx.quadraticCurveTo(len * 0.38, wid, 0, 0);
      this.ctx.closePath();
      this.ctx.fill();
      this.ctx.restore();
    }
  }

  private drawCinnabarSeal(w: number, h: number): void {
    const size = this.compact ? 14 : 22;
    const x = w - size - (this.compact ? 10 : 20);
    const y = h * (this.compact ? 0.72 : 0.80);
    const sealColor = this.darkMode ? 'rgba(218, 92, 72, 0.56)' : 'rgba(182, 54, 40, 0.62)';

    this.ctx.save();
    this.ctx.strokeStyle = sealColor;
    this.ctx.lineWidth = this.compact ? 1.1 : 1.5;
    this.ctx.strokeRect(x, y, size, size);
    this.ctx.fillStyle = sealColor;
    this.ctx.font = `${Math.round(size * 0.64)}vp serif`;
    this.ctx.textAlign = 'center';
    this.ctx.textBaseline = 'middle';
    this.ctx.fillText('墨', x + size * 0.5, y + size * 0.53);
    this.ctx.restore();
  }

  private updateAndDrawCranes(w: number, h: number, dt: number): void {
    if (!this.cranes.length) return;
    const color = this.darkMode ? 'rgba(212, 224, 236, 0.52)' : 'rgba(42, 54, 64, 0.46)';
    this.ctx.save();
    this.ctx.strokeStyle = color;
    this.ctx.lineCap = 'round';
    const next: InkCrane[] = [];
    for (const c of this.cranes) {
      c.x += c.vx * dt;
      c.y += c.vy * dt;
      c.wingPhase += dt * 3.4;
      if (c.x < -40 || c.y < -30) {
        if (c.vx > -20) {
          c.x = w + 30;
          c.y = h * (0.42 + ((this.elapsed * 0.07) % 0.16));
          next.push(c);
        }
        continue;
      }
      next.push(c);
      const wing = Math.sin(c.wingPhase) * 6 * c.scale;
      const span = 12 * c.scale;
      this.ctx.globalAlpha = c.alpha;
      this.ctx.lineWidth = 1.4 * c.scale;
      this.ctx.beginPath();
      this.ctx.moveTo(c.x - span, c.y - wing);
      this.ctx.quadraticCurveTo(c.x - span * 0.4, c.y - 3 * c.scale - wing * 0.4, c.x, c.y);
      this.ctx.quadraticCurveTo(c.x + span * 0.4, c.y - 3 * c.scale - wing * 0.4, c.x + span, c.y - wing);
      this.ctx.stroke();
    }
    this.ctx.restore();
    this.cranes = next;
  }

  private updateAndDrawLeaves(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    const gustX = -this.windGust * 34;
    const kept: InkLeaf[] = [];

    for (let i = 0; i < this.leaves.length; i += 1) {
      const leaf = this.leaves[i];
      const flutter = Math.sin(t * leaf.swayFreq + leaf.phase) * leaf.swayAmp;
      leaf.x += (leaf.vx + flutter + gustX) * dt;
      leaf.y += leaf.vy * dt;
      leaf.angle += leaf.vAngle * dt;
      leaf.flip += leaf.vFlip * dt;

      if (leaf.y > h + 26) {
        if (leaf.ambient) {
          leaf.y = -18 - (i % 4) * 14;
          leaf.x = w * (0.20 + ((i * 0.23 + t * 0.05) % 0.88));
          kept.push(leaf);
        }
        continue;
      }
      if (leaf.x < -30 && leaf.ambient) leaf.x = w + 20;
      kept.push(leaf);

      this.ctx.save();
      this.ctx.translate(leaf.x, leaf.y);
      this.ctx.rotate(leaf.angle);
      this.ctx.scale(1, 0.35 + 0.65 * Math.abs(Math.cos(leaf.flip)));
      this.ctx.globalAlpha = leaf.alpha;
      if (leaf.gold) {
        // 细碎鎏金点缀
        this.ctx.fillStyle = this.darkMode ? '#E8C684' : '#B88A3E';
        this.ctx.beginPath();
        this.ctx.arc(0, 0, Math.max(1.4, leaf.length * 0.22), 0, Math.PI * 2);
        this.ctx.fill();
      } else {
        // 飘落水墨竹叶
        const len = leaf.length;
        const wid = len * 0.22;
        this.ctx.fillStyle = this.darkMode ? '#BAC7D4' : '#3C4B58';
        this.ctx.beginPath();
        this.ctx.moveTo(-len * 0.5, 0);
        this.ctx.quadraticCurveTo(0, -wid, len * 0.5, 0);
        this.ctx.quadraticCurveTo(0, wid, -len * 0.5, 0);
        this.ctx.closePath();
        this.ctx.fill();
      }
      this.ctx.restore();
    }
    this.leaves = kept;
  }

  private updateAndDrawRipples(dt: number): void {
    if (!this.ripples.length) return;
    const next: InkRipple[] = [];
    const rgb = this.darkMode ? '200, 214, 228' : '48, 60, 72';
    this.ctx.save();
    for (const r of this.ripples) {
      r.radius += r.speed * dt;
      if (r.radius >= r.maxRadius) continue;
      const a = r.alpha * (1 - r.radius / r.maxRadius);
      this.ctx.strokeStyle = `rgba(${rgb}, ${a.toFixed(3)})`;
      this.ctx.lineWidth = r.ring === 0 ? 1.4 : 0.9;
      this.ctx.beginPath();
      this.ctx.arc(r.x, r.y, r.radius, 0, Math.PI * 2);
      this.ctx.stroke();
      next.push(r);
    }
    this.ctx.restore();
    this.ripples = next;
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
