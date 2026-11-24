import type { UIContext } from '@kit.ArkUI';
import { ReplySpeech, replySpeechSupported } from '../ReplySpeech';
import { ensureMicrophone, VoiceInputSession, voiceInputSupported } from '../VoiceInput';
import { MAX_VOICE_MS, MIN_HOLD_MS } from './PiGoConstants';
import type { ChatMessage } from './PiGoTypes';

export interface VoiceComposerHost {
  currentId: () => string;
  epoch: () => number;
  busy: () => boolean;
  openingSession: () => boolean;
  reachable: () => boolean;
  idle: () => boolean;
  visible: () => boolean;
  hasPendingSend: () => boolean;
  draft: () => string;
  setDraft: (draft: string) => void;
  getUIContext: () => UIContext;
  fetchFullMessageText: (sessionId: string, messageId: string, epoch: number, current?: () => boolean) => Promise<string | undefined>;
  replySpeechText: (source: string) => string;
  syncCommandPalette: () => void;
  send: () => Promise<void>;
}

@ObservedV2
export class VoiceComposerState {
  @Trace voiceMode: boolean = false;
  @Trace recording: boolean = false;
  @Trace recordSeconds: number = 0;
  @Trace liveVoiceText: string = '';
  @Trace holdCancel: boolean = false;
  @Trace voicePreparing: boolean = false;
  @Trace voiceFinishing: boolean = false;
  @Trace voiceCancelling: boolean = false;
  @Trace voiceHint: string = '';
  @Trace speakingReply: string = '';
}

export class VoiceComposerController {
  readonly state: VoiceComposerState = new VoiceComposerState();
  private voiceHintTimer: number = -1;
  private voiceAttempt: number = 0;
  private holdTouchId: number = -1;
  private holdActive: boolean = false;
  private holdStartY: number = 0;
  private holdStart: number = 0;
  private recordTimer: number = -1;
  private voiceSession?: VoiceInputSession = undefined;
  private readonly replySpeech: ReplySpeech = new ReplySpeech();
  private replySpeechAttempt: number = 0;

  private readonly host: VoiceComposerHost;

  constructor(host: VoiceComposerHost) {
    this.host = host;
  }

  holding(): boolean {
    return this.holdActive;
  }

  disposeReplySpeech(): void {
    this.stopReplySpeech();
    this.replySpeech.dispose();
  }

  stopReplySpeech(): void {
    if (!this.state.speakingReply) return;
    this.replySpeechAttempt += 1;
    this.state.speakingReply = '';
    this.replySpeech.stop();
  }

  async toggleReplySpeech(message: ChatMessage): Promise<void> {
    const wasSpeaking = this.state.speakingReply === message.id;
    this.stopReplySpeech();
    if (wasSpeaking || !this.host.currentId()) return;
    const prompt = this.host.getUIContext().getPromptAction();
    if (!replySpeechSupported()) {
      prompt.showToast({ message: '此设备不支持本地朗读' });
      return;
    }
    const attempt = ++this.replySpeechAttempt;
    this.state.speakingReply = message.id;
    const current = (): boolean => attempt === this.replySpeechAttempt;
    const finish = (notice: string): void => {
      if (!current()) return;
      this.state.speakingReply = '';
      if (notice) prompt.showToast({ message: notice });
    };
    try {
      const source = message.textTruncated
        ? await this.host.fetchFullMessageText(this.host.currentId(), message.id, this.host.epoch(), current) : message.text;
      if (!current()) return;
      if (source === undefined) { finish('暂时无法加载完整回复，请重试'); return; }
      const text = this.host.replySpeechText(source);
      if (!text) { finish('这条回复没有可朗读的文字'); return; }
      await this.replySpeech.play(text, (failed: boolean): void => { finish(failed ? '暂时无法朗读，请重试' : ''); });
    } catch {
      finish('暂时无法朗读，请重试');
    }
  }

  private stopRecordClock(): void {
    if (this.recordTimer !== -1) {
      clearInterval(this.recordTimer);
      this.recordTimer = -1;
    }
  }

  private showVoiceHint(message: string): void {
    if (this.voiceHintTimer !== -1) clearTimeout(this.voiceHintTimer);
    this.state.voiceHint = message;
    this.voiceHintTimer = setTimeout(() => {
      this.state.voiceHint = '';
      this.voiceHintTimer = -1;
    }, 2200);
  }

  resetVoice(): void {
    this.voiceAttempt += 1;
    this.holdActive = false;
    this.holdTouchId = -1;
    this.state.recording = false;
    this.state.voicePreparing = false;
    this.state.voiceFinishing = false;
    this.state.voiceCancelling = false;
    this.state.holdCancel = false;
    this.state.liveVoiceText = '';
    this.state.voiceHint = '';
    if (this.voiceHintTimer !== -1) clearTimeout(this.voiceHintTimer);
    this.voiceHintTimer = -1;
    this.stopRecordClock();
    const session = this.voiceSession;
    this.voiceSession = undefined;
    if (session) void session.cancel();
  }

  holdTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (this.holdActive || this.state.voicePreparing || this.state.voiceFinishing || this.state.recording ||
        this.host.busy() || this.host.openingSession() || !this.host.reachable() || this.host.hasPendingSend()) return;
      const touch = event.changedTouches[0];
      if (!touch) return;
      this.holdActive = true;
      this.holdTouchId = touch.id;
      this.holdStartY = touch.windowY;
      this.state.holdCancel = false;
      void this.beginRecording();
      return;
    }
    if (!this.holdActive) return;
    if (event.type === TouchType.Cancel) {
      this.holdActive = false;
      void this.endRecording(true);
      return;
    }
    const touch = event.changedTouches.find((item: TouchObject): boolean => item.id === this.holdTouchId);
    if (!touch) return;
    if (event.type === TouchType.Up) {
      this.holdActive = false;
      void this.endRecording(false);
    } else if (event.type === TouchType.Move) {
      const rise = this.holdStartY - touch.windowY;
      if (rise > 80) this.state.holdCancel = true;
      else if (rise < 40) this.state.holdCancel = false;
    }
  }

  private async beginRecording(): Promise<void> {
    if (!this.host.currentId()) return;
    if (!voiceInputSupported()) { this.showVoiceHint('此设备不支持本地语音识别'); return; }
    const context = this.host.getUIContext().getHostContext();
    if (!context) return;
    this.stopReplySpeech();
    const attempt = ++this.voiceAttempt;
    const epoch = this.host.epoch();
    const id = this.host.currentId();
    this.state.voicePreparing = true;
    this.state.voiceHint = '';
    const allowed = await ensureMicrophone(context);
    if (attempt !== this.voiceAttempt || epoch !== this.host.epoch() || id !== this.host.currentId()) return;
    if (!allowed || !this.holdActive) {
      this.state.voicePreparing = false;
      if (!allowed) this.showVoiceHint('请在系统设置中允许麦克风权限');
      return;
    }
    const session = new VoiceInputSession();
    this.voiceSession = session;
    this.state.liveVoiceText = '';
    this.state.recordSeconds = 0;
    try {
      await session.begin((partial: string): void => {
        if (this.voiceSession === session) this.state.liveVoiceText = partial;
      });
      if (attempt !== this.voiceAttempt || this.voiceSession !== session) return;
      this.state.voicePreparing = false;
      this.state.recording = true;
      this.holdStart = Date.now();
      this.recordTimer = setInterval(() => {
        if (this.voiceSession !== session) return;
        this.state.recordSeconds = Math.floor((Date.now() - this.holdStart) / 1000);
        if (Date.now() - this.holdStart >= MAX_VOICE_MS) {
          this.holdActive = false;
          void this.endRecording(false);
        }
      }, 200);
    } catch {
      if (attempt === this.voiceAttempt) {
        this.resetVoice();
        this.showVoiceHint('无法启动语音识别，请重试');
      }
    }
  }

  private async endRecording(cancelled: boolean): Promise<void> {
    if (this.state.voiceFinishing) return;
    const session = this.voiceSession;
    const attempt = ++this.voiceAttempt;
    const epoch = this.host.epoch();
    const id = this.host.currentId();
    const cancel = cancelled || this.state.holdCancel;
    const tooShort = !this.state.recording || Date.now() - this.holdStart < MIN_HOLD_MS;
    this.state.recording = false;
    this.state.voicePreparing = false;
    this.state.holdCancel = false;
    this.stopRecordClock();
    if (!session) {
      this.voiceAttempt += 1;
      if (!cancel) this.showVoiceHint('说话时间太短');
      return;
    }
    this.state.voiceFinishing = true;
    this.state.voiceCancelling = cancel || tooShort;
    if (tooShort && !cancel) this.showVoiceHint('说话时间太短');
    try {
      if (cancel || tooShort) {
        await session.cancel();
        if (attempt === this.voiceAttempt && !cancel) this.showVoiceHint('说话时间太短');
        return;
      }
      const text = await session.finish();
      if (attempt !== this.voiceAttempt || epoch !== this.host.epoch() || id !== this.host.currentId() || !this.host.visible()) return;
      if (!text.trim()) {
        this.showVoiceHint(session.lastError === 'microphone_permission' ? '请在系统设置中允许麦克风权限' :
          session.lastError ? '语音识别失败，请重试' : '没有听清，请再说一次');
        return;
      }
      const draft = this.host.draft().trim();
      this.host.setDraft(draft ? `${draft}\n${text.trim()}` : text.trim());
      this.host.syncCommandPalette();
      if (session.hasFinalTranscript && this.host.idle() && this.host.reachable() && !this.host.busy() && !this.host.openingSession() &&
        !this.host.hasPendingSend()) {
        await this.host.send();
        if (attempt === this.voiceAttempt && this.host.draft().trim()) this.state.voiceMode = false;
      } else {
        this.state.voiceMode = false;
        this.showVoiceHint(session.hasFinalTranscript ? '已转为文字，可编辑后发送' : '识别未完成，请检查文字后发送');
      }
    } catch {
      if (attempt === this.voiceAttempt) this.showVoiceHint('语音识别失败，请重试');
    } finally {
      if (attempt === this.voiceAttempt) {
        this.voiceSession = undefined;
        this.state.voiceFinishing = false;
        this.state.voiceCancelling = false;
        this.state.liveVoiceText = '';
      }
    }
  }
}
