import { image } from '@kit.ImageKit';

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

@Component
export struct InkScene {
  @Prop @Watch('onDarkModeChange') darkMode: boolean = false;
  @Prop sceneOpacity: number = 0.92;
  @Prop @Watch('onLoopPolicyChange') dimmed: boolean = false;
  @Prop @Watch('onLoopPolicyChange') active: boolean = true;
  @Prop compact: boolean = false;
  @Prop @Watch('onBurstChange') burstSeq: number = 0;
  @Prop burstKind: string = 'send';
  @Prop @Watch('onTapChange') tapSeq: number = 0;
  @Prop tapX: number = 0;
  @Prop tapY: number = 0;

  @State private pixelsReady: boolean = false;

  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private paintMap?: image.PixelMap;
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

  private windGust: number = 0;
  private leaves: InkLeaf[] = [];
  private ripples: InkRipple[] = [];
  private mists: MistBand[] = [];

  aboutToAppear(): void {
    void this.loadBitmap();
  }

  aboutToDisappear(): void {
    this.loadGen += 1;
    this.stopLoop();
    this.releaseBitmap();
  }

  private releaseBitmap(): void {
    if (this.paintMap) {
      void this.paintMap.release();
      this.paintMap = undefined;
    }
    this.pixelsReady = false;
  }

  private onDarkModeChange(): void {
    void this.loadBitmap();
  }

  private async loadBitmap(): Promise<void> {
    const gen = ++this.loadGen;
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    const name = this.darkMode ? 'ink_dark.jpg' : 'ink_light.jpg';
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
      this.paintMap = loaded;
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
        alpha: celebrate ? 0.72 : 0.58,
        gold: i % 3 === 0,
        ambient: false
      });
    }
    this.ripples.push({
      x: w * 0.55, y: h * 0.87, radius: 6, maxRadius: celebrate ? 140 : 95, speed: 38, alpha: 0.40, ring: 0
    });
  }

  private onTapChange(): void {
    if (this.compact || this.tapSeq <= 0) return;
    this.windGust = Math.max(this.windGust, 0.55);
    const x = this.tapX > 0 ? this.tapX : (this.canvasW || 390) * 0.5;
    const y = this.tapY > 0 ? this.tapY : (this.canvasH || 840) * 0.5;
    this.ripples.push(
      { x: x, y: y, radius: 5, maxRadius: 118, speed: 54, alpha: 0.46, ring: 0 },
      { x: x, y: y, radius: 2, maxRadius: 80, speed: 40, alpha: 0.32, ring: 1 }
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
        alpha: 0.64,
        gold: i === 1,
        ambient: false
      });
    }
  }

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
    this.mists = [
      { x: w * 0.30, yRatio: 0.72, rx: w * 0.48, ry: h * 0.06, speed: 6, alpha: 0.16, phase: 0.5 },
      { x: w * 0.74, yRatio: 0.80, rx: w * 0.52, ry: h * 0.07, speed: -4.8, alpha: 0.18, phase: 2.1 }
    ];
    this.leaves = [];
    const leafCount = this.compact ? 4 : 8;
    for (let i = 0; i < leafCount; i += 1) {
      this.leaves.push({
        x: w * (0.32 + ((i * 0.21) % 0.72)),
        y: (i / leafCount) * (h + 30) - 20,
        vx: -(10 + (i % 3) * 5),
        vy: (this.compact ? 26 : 36) + (i % 4) * 8,
        length: (this.compact ? 6.5 : 9.0) + (i % 3) * 2.4,
        angle: i * 0.9,
        vAngle: (i % 2 === 0 ? 1 : -1) * (0.7 + (i % 3) * 0.35),
        flip: i * 1.1,
        vFlip: 1.4 + (i % 3) * 0.45,
        swayAmp: 11 + (i % 3) * 5,
        swayFreq: 1.0 + (i % 3) * 0.25,
        phase: i * 1.4,
        alpha: 0.34 + (i % 3) * 0.12,
        gold: i % 4 === 0,
        ambient: true
      });
    }
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

    // 1. 类 Wallpaper Engine 连续正弦网格形变渲染宋风宣纸/玄墨山水画
    if (this.paintMap && this.imgWidth > 0 && this.imgHeight > 0) {
      this.drawWarpedPainting(this.paintMap, w, h);
    }

    // 2. 轻柔流动的山间云岚
    this.drawMistBands(w, h, dt);

    // 3. 飘落墨竹叶与细碎鎏金微尘（完整落出屏幕底部）
    this.updateAndDrawLeaves(w, h, dt);

    // 4. 点墨同心水墨涟漪
    this.updateAndDrawRipples(dt);
  }

  private drawWarpedPainting(bitmap: image.PixelMap, w: number, h: number): void {
    const imgRatio = this.imgWidth / this.imgHeight;
    const viewRatio = w / h;
    const wideScreen = viewRatio > imgRatio;
    let drawW = w;
    let drawH = h;
    let drawX = 0;
    let drawY = 0;
    if (wideScreen) {
      // 折叠屏展开 / 平板 / 横屏：按高度完整适配并靠右对齐，保留完整松竹山水亭台不裁切，左侧延展宣纸/玄墨留白。
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

    const t = this.elapsed;
    const gustBoost = 1 + this.windGust * 0.6;
    const padX = 8;
    const clipX = wideScreen ? Math.max(0, drawX - 2) : 0;
    const clipW = wideScreen ? (w - clipX) : w;

    // 1. 静态宣纸留白、山体与亭台一次性绘制
    this.ctx.save();
    this.ctx.beginPath();
    this.ctx.rect(clipX, 0, clipW, h);
    this.ctx.clip();
    this.ctx.drawImage(bitmap, drawX, drawY, drawW, drawH);
    this.ctx.restore();

    // 2. 仅对上部苍松墨竹 (0 ~ 0.36) 做 8 条带微风轻摇
    const treeStrips = this.compact ? 5 : 8;
    const treeBandH = h * 0.36;
    const treeStepH = treeBandH / treeStrips;
    for (let i = 0; i < treeStrips; i += 1) {
      const local = (i + 0.5) / treeStrips;
      const v = local * 0.36;
      const treeWeight = Math.sin(local * Math.PI);
      const dx = Math.sin(t * 1.0 + v * 5.0) * 3.0 * treeWeight * gustBoost;
      const dy = Math.cos(t * 0.8 + v * 3.2) * 1.1 * treeWeight * gustBoost;
      this.ctx.save();
      this.ctx.beginPath();
      this.ctx.rect(clipX, i * treeStepH, clipW, treeStepH + 1.2);
      this.ctx.clip();
      this.ctx.drawImage(bitmap, drawX - padX + dx, drawY + dy, drawW + padX * 2, drawH);
      this.ctx.restore();
    }

    // 3. 仅对江面与孤舟区域 (0.60 ~ 0.74) 做 6 条带轻柔水波
    const waterStrips = this.compact ? 4 : 6;
    const waterTop = h * 0.60;
    const waterBandH = h * 0.14;
    const waterStepH = waterBandH / waterStrips;
    for (let i = 0; i < waterStrips; i += 1) {
      const local = (i + 0.5) / waterStrips;
      const waterEnv = Math.sin(local * Math.PI);
      const dx = Math.sin(t * 0.95 + local * 4.8) * 1.5 * waterEnv;
      this.ctx.save();
      this.ctx.beginPath();
      this.ctx.rect(clipX, waterTop + i * waterStepH, clipW, waterStepH + 1.2);
      this.ctx.clip();
      this.ctx.drawImage(bitmap, drawX - padX + dx, drawY, drawW + padX * 2, drawH);
      this.ctx.restore();
    }

    // 宽屏模式下在画作左边缘叠加柔和羽化过渡，使画作无缝融入左侧宣纸/玄墨底色
    if (wideScreen && drawX > 0) {
      const featherW = Math.min(88, drawW * 0.24);
      const edgeGrad = this.ctx.createLinearGradient(drawX, 0, drawX + featherW, 0);
      if (this.darkMode) {
        edgeGrad.addColorStop(0, 'rgba(17, 19, 23, 1)');
        edgeGrad.addColorStop(1, 'rgba(17, 19, 23, 0)');
      } else {
        edgeGrad.addColorStop(0, 'rgba(246, 245, 240, 1)');
        edgeGrad.addColorStop(1, 'rgba(246, 245, 240, 0)');
      }
      this.ctx.fillStyle = edgeGrad;
      this.ctx.fillRect(drawX - 1, 0, featherW + 2, h);
    }
  }

  private drawMistBands(w: number, h: number, dt: number): void {
    const dimFactor = this.dimmed ? 0.5 : 1;
    this.ctx.save();
    for (const m of this.mists) {
      m.x += m.speed * dt;
      if (m.x > w + m.rx * 0.6) m.x = -m.rx * 0.5;
      if (m.x < -m.rx * 0.6) m.x = w + m.rx * 0.5;
      const cy = h * m.yRatio + Math.sin(this.elapsed * 0.45 + m.phase) * 4;
      const grad = this.ctx.createRadialGradient(m.x, cy, m.ry * 0.2, m.x, cy, m.rx);
      if (this.darkMode) {
        grad.addColorStop(0, `rgba(186, 198, 214, ${(m.alpha * 0.28 * dimFactor).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(186, 198, 214, 0)');
      } else {
        grad.addColorStop(0, `rgba(255, 254, 248, ${(m.alpha * 1.6 * dimFactor).toFixed(3)})`);
        grad.addColorStop(1, 'rgba(255, 254, 248, 0)');
      }
      this.ctx.fillStyle = grad;
      this.ctx.beginPath();
      this.ctx.ellipse(m.x, cy, m.rx, m.ry, 0, 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.restore();
  }

  private updateAndDrawLeaves(w: number, h: number, dt: number): void {
    const t = this.elapsed;
    const gustX = -this.windGust * 34;
    const dimFactor = this.dimmed ? 0.65 : 1;
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
          leaf.x = w * (0.24 + ((i * 0.23 + t * 0.05) % 0.84));
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
      this.ctx.globalAlpha = leaf.alpha * dimFactor;
      if (leaf.gold) {
        this.ctx.fillStyle = this.darkMode ? '#E8C684' : '#B88A3E';
        this.ctx.beginPath();
        this.ctx.arc(0, 0, Math.max(1.4, leaf.length * 0.22), 0, Math.PI * 2);
        this.ctx.fill();
      } else {
        const len = leaf.length;
        const wid = len * 0.22;
        this.ctx.fillStyle = this.darkMode ? '#C2CEDB' : '#33404B';
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
    const rgb = this.darkMode ? '204, 218, 232' : '46, 58, 68';
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
    Stack() {
      if (!this.pixelsReady) {
        Image($rawfile(this.darkMode ? 'ink_dark.jpg' : 'ink_light.jpg'))
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
