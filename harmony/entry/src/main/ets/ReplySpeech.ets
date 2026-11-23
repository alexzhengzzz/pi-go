import { textToSpeech } from '@kit.CoreSpeechKit';

const CHUNK_LENGTH = 2500;

export function replySpeechSupported(): boolean {
  return canIUse('SystemCapability.AI.TextToSpeech');
}

function splitReplySpeech(text: string): string[] {
  const chunks: string[] = [];
  let start = 0;
  while (start < text.length) {
    let end = Math.min(start + CHUNK_LENGTH, text.length);
    if (end < text.length) {
      const window = text.slice(start, end);
      const boundary = Math.max(window.lastIndexOf('\n'), window.lastIndexOf('。'), window.lastIndexOf('！'),
        window.lastIndexOf('？'), window.lastIndexOf('. '), window.lastIndexOf('! '), window.lastIndexOf('? '));
      if (boundary > CHUNK_LENGTH / 2) end = start + boundary + 1;
      else if (/[\uDC00-\uDFFF]/.test(text.charAt(end))) end -= 1;
    }
    const chunk = text.slice(start, end).trim();
    if (chunk) chunks.push(chunk);
    start = end;
  }
  return chunks;
}

export class ReplySpeech {
  private engine?: textToSpeech.TextToSpeechEngine = undefined;
  private initializing?: Promise<textToSpeech.TextToSpeechEngine> = undefined;
  private engineRevision: number = 0;
  private generation: number = 0;
  private sequence: number = 0;
  private requestId: string = '';
  private chunks: string[] = [];
  private next: number = 0;
  private finished?: (failed: boolean) => void = undefined;

  async play(text: string, finished: (failed: boolean) => void): Promise<void> {
    this.stop();
    const generation = this.generation;
    this.chunks = splitReplySpeech(text);
    this.next = 0;
    this.finished = finished;
    try {
      const engine = await this.getEngine();
      if (generation === this.generation) this.playNext(engine);
    } catch {
      if (generation === this.generation) this.finish(true);
    }
  }

  stop(): void {
    this.generation += 1;
    const active = !!this.requestId;
    this.reset();
    if (active) {
      try { this.engine?.stop(); } catch { this.dispose(); }
    }
  }

  dispose(): void {
    this.generation += 1;
    this.engineRevision += 1;
    this.reset();
    this.initializing = undefined;
    const engine = this.engine;
    this.engine = undefined;
    try { engine?.shutdown(); } catch { /* The native engine may already be closed. */ }
  }

  private getEngine(): Promise<textToSpeech.TextToSpeechEngine> {
    if (this.engine) return Promise.resolve(this.engine);
    if (!this.initializing) {
      const revision = this.engineRevision;
      this.initializing = this.initializeEngine(revision).finally((): void => {
        if (revision === this.engineRevision) this.initializing = undefined;
      });
    }
    return this.initializing;
  }

  private async initializeEngine(revision: number): Promise<textToSpeech.TextToSpeechEngine> {
    const engine = await textToSpeech.createEngine({ language: 'zh-CN', person: 13, online: 1 });
    if (revision !== this.engineRevision) {
      engine.shutdown();
      throw new Error('speech_disposed');
    }
    try {
      engine.setListener({
        onStart: (_id: string, _response: textToSpeech.StartResponse): void => {},
        onComplete: (id: string, response: textToSpeech.CompleteResponse): void => {
          if (id === this.requestId && response.type === 1) this.playNext(engine);
        },
        onStop: (id: string, _response: textToSpeech.StopResponse): void => {
          if (id === this.requestId) this.finish(false);
        },
        onError: (id: string, _code: number, _message: string): void => {
          if (id === this.requestId) this.finish(true);
        }
      });
    } catch {
      engine.shutdown();
      throw new Error('speech_listener_failed');
    }
    this.engine = engine;
    return engine;
  }

  private playNext(engine: textToSpeech.TextToSpeechEngine): void {
    if (this.next === this.chunks.length) {
      this.finish(false);
      return;
    }
    this.requestId = `pigo${++this.sequence}`;
    try {
      engine.speak(this.chunks[this.next++], { requestId: this.requestId });
    } catch { this.finish(true); }
  }

  private reset(): void {
    this.requestId = '';
    this.chunks = [];
    this.finished = undefined;
  }

  private finish(failed: boolean): void {
    const callback = this.finished;
    this.reset();
    callback?.(failed);
  }
}
