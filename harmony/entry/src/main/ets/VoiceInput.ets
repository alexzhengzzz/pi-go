import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { util } from '@kit.ArkTS';

const FINISH_WAIT_MS = 2500;
const CANCEL_WAIT_MS = 600;
const MAX_RECORD_MS = 60000;

// Core Speech Kit accepts up to 200 session hot words, each 2–20 characters.
const DEFAULT_SESSION_LEXICON: string[] = [
  // Agent / app context
  '智能体', '会话', '提示词', '上下文', '令牌', '模型', '任务', '工作区',
  '恢复会话', '新建会话', '撤销', '配对', '扫码', '局域网', '证书', '密钥',
  '语音输入', '语音识别', '热词', '回归测试', '真机调试',
  '缓存', '日志', '同步', '断线', '重连', '离线', '在线',
  // Common developer actions
  '提交', '推送', '拉取', '分支', '合并', '回滚', '构建', '签名', '打包',
  '安装', '部署', '调试', '断点', '编译', '运行', '测试', '重构', '终端',
  '命令', '脚本', '仓库', '工作树', '代码审查',
  // Mixed zh/en vocabulary the offline engine tends to garble
  '鸿蒙', 'HarmonyOS', '方舟', 'ArkTS', 'ArkUI', 'TypeScript', 'JavaScript',
  'WebSocket', 'HTTP', 'HTTPS', 'JSON', 'API', 'SDK', 'RPC', 'ETS', 'Markdown',
  'Git', 'GitHub', 'Commit', 'Push', 'Diff', 'Token', 'TLS', 'UUID', 'npm', 'Node',
  'Codex', 'HAP',
  '组件', '页面', '路由', '回调', '异步', '并发', '线程', '进程',
  '权限', '麦克风', '通知栏', '真机', '模拟器'
];

const LEXICON_MAX_WORDS = 200;
const LEXICON_WORD_MIN_LEN = 2;
const LEXICON_WORD_MAX_LEN = 20;
const LEXICON_WORD_PATTERN = /^[\u4e00-\u9fffA-Za-z]+$/;

function normalizeLexicon(words?: string[]): string[] {
  const source: string[] = words && words.length > 0 ? words : DEFAULT_SESSION_LEXICON;
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (const word of source) {
    if (typeof word !== 'string') continue;
    const trimmed: string = word.trim();
    if (trimmed.length < LEXICON_WORD_MIN_LEN || trimmed.length > LEXICON_WORD_MAX_LEN) continue;
    if (!LEXICON_WORD_PATTERN.test(trimmed)) continue;
    if (seen.has(trimmed)) continue;
    seen.add(trimmed);
    if (result.length >= LEXICON_MAX_WORDS) break;
    result.push(trimmed);
  }
  return result;
}

export function voiceInputSupported(): boolean {
  return canIUse('SystemCapability.AI.SpeechRecognizer');
}

export async function ensureMicrophone(context: common.Context): Promise<boolean> {
  const manager = abilityAccessCtrl.createAtManager();
  try {
    const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
    for (const status of result.authResults) {
      if (status !== 0) return false;
    }
    return true;
  } catch { return false; }
}

// One instance per press-and-hold. The offline zh-CN engine records from the
// microphone itself (recognitionMode 0), so no AudioCapturer is required.
export class VoiceInputSession {
  private readonly sessionId: string = util.generateRandomUUID();
  private readonly hotwords: string[] = normalizeLexicon();
  private engine?: speechRecognizer.SpeechRecognitionEngine = undefined;
  private beginTask: Promise<void> = Promise.resolve();
  private releaseWaiter?: () => void = undefined;
  private readonly sentences: string[] = [];
  private partial: string = '';
  private lastClauseFinal: boolean = false;
  private released: boolean = false;
  private settleTask?: Promise<void> = undefined;
  public lastError: string = '';

  constructor(hotwords?: string[]) {
    if (hotwords) this.hotwords = normalizeLexicon(hotwords);
  }

  text(): string {
    return this.sentences.join('') + this.partial;
  }

  get hasFinalTranscript(): boolean {
    return this.released && this.lastClauseFinal && !this.partial && !this.lastError;
  }

  async begin(onPartial: (text: string) => void): Promise<void> {
    this.beginTask = this.launch(onPartial);
    await this.beginTask;
  }

  private async launch(onPartial: (text: string) => void): Promise<void> {
    const session = this;
    const engineParams: Record<string, Object> = { 'locate': 'CN', 'recognizerMode': 'long' };
    const createParams: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN', online: 1, extraParams: engineParams
    };
    try {
      session.engine = await speechRecognizer.createEngine(createParams);
      // In long mode a pause ends a clause. The hold ends the session via finish().
      const startParams: Record<string, Object> = {
        'recognitionMode': 0, 'maxAudioDuration': MAX_RECORD_MS
      };
      if (this.hotwords.length > 0) {
        startParams['sessionGeneralLexicon'] = this.hotwords;
      }
      session.engine.setListener({
        onStart: (_sessionId: string, _eventMessage: string) => {},
        onEvent: (_sessionId: string, _eventCode: number, _eventMessage: string) => {},
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
          if (sessionId !== session.sessionId || !session.engine || session.released) return;
          if (result.isFinal) {
            if (result.result.trim()) {
              session.sentences.push(result.result);
              session.partial = '';
            }
            session.lastClauseFinal = result.isLast;
          } else {
            session.partial = result.result;
            session.lastClauseFinal = false;
          }
          onPartial(session.text());
        },
        onComplete: (sessionId: string, _eventMessage: string) => {
          if (sessionId === session.sessionId && session.engine) session.markReleased();
        },
        onError: (sessionId: string, errorCode: number, _errorMessage: string) => {
          if (sessionId !== session.sessionId || !session.engine || session.released) return;
          if (errorCode === 1002200012) session.lastError = 'microphone_permission';
          else if (!session.lastError) session.lastError = 'recognizer_error';
          session.markReleased();
        }
      });
      session.engine.startListening({
        sessionId: session.sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
        extraParams: startParams
      });
    } catch (cause) {
      session.lastError = 'recognizer_error';
      throw cause instanceof Error ? cause : new Error('voice_engine_unavailable');
    }
  }

  async finish(): Promise<string> {
    await this.settle(true);
    return this.text();
  }

  async cancel(): Promise<void> {
    await this.settle(false);
  }

  private settle(finish: boolean): Promise<void> {
    if (!this.settleTask) this.settleTask = this.endRecognition(finish);
    return this.settleTask;
  }

  private async endRecognition(finish: boolean): Promise<void> {
    try { await this.beginTask; } catch { }
    const engine = this.engine;
    if (engine && !this.released) {
      try {
        if (finish) engine.finish(this.sessionId);
        else engine.cancel(this.sessionId);
      } catch { }
      await this.waitForRelease(finish ? FINISH_WAIT_MS : CANCEL_WAIT_MS);
    }
    this.closeEngine();
  }

  private waitForRelease(timeoutMs: number): Promise<void> {
    if (this.released) return Promise.resolve();
    return new Promise<void>((resolve: (value: void) => void) => {
      const timer: number = setTimeout(() => {
        this.releaseWaiter = undefined;
        resolve();
      }, timeoutMs);
      this.releaseWaiter = (): void => {
        clearTimeout(timer);
        this.releaseWaiter = undefined;
        resolve();
      };
    });
  }

  private markReleased(): void {
    this.released = true;
    if (this.releaseWaiter) this.releaseWaiter();
  }

  private closeEngine(): void {
    const engine = this.engine;
    this.engine = undefined;
    if (engine) {
      try { engine.shutdown(); } catch { }
    }
  }
}
