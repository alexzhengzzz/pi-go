import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const page = readFileSync(new URL('../harmony/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
function method(name) {
  const start = page.search(new RegExp(`  private (?:async )?${name}\\(`));
  assert.ok(start >= 0);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
}
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};
function fixture(permission = Promise.resolve(true), startup = Promise.resolve()) {
  const result = deferred();
  const sessions = [];
  class Session {
    constructor() { sessions.push(this); this.cancelled = false; this.hasFinalTranscript = true; }
    begin() { return startup; }
    async cancel() { this.cancelled = true; await startup; }
    finish() { return result.promise; }
  }
  const source = `class Harness { ${['stopRecordClock', 'resetVoice', 'holdTouch', 'beginRecording', 'endRecording'].map(method).join('\n')} }`;
  const Harness = new Function('VoiceInputSession', 'ensureMicrophone', 'voiceInputSupported', 'TouchType', 'MAX_VOICE_MS', 'MIN_HOLD_MS',
    stripTypeScriptTypes(source) + '; return Harness;')(Session, () => permission, () => true,
    { Down: 'down', Up: 'up', Move: 'move', Cancel: 'cancel' }, 60000, 400);
  const state = Object.assign(new Harness(), {
    currentId: 'one', epoch: 1, voiceAttempt: 0, visible: true, reachable: true, idle: true,
    draft: '', holdActive: true, recordTimer: -1, voiceHintTimer: -1,
    getUIContext: () => ({ getHostContext: () => ({}) }),
    showVoiceHint(text) { this.voiceHint = text; },
    syncCommandPalette() {},
    async send() { this.sent = this.draft; }
  });
  return { state, sessions, result };
}

test('release during permission request never starts recording later', async () => {
  const permission = deferred();
  const { state, sessions } = fixture(permission.promise);
  const begin = state.beginRecording();
  state.holdActive = false;
  await state.endRecording(false);
  permission.resolve(true);
  await begin;
  assert.equal(sessions.length, 0);
  assert.equal(state.voicePreparing, false);
});

test('release during engine startup cannot revive recording or start a timer', async () => {
  const startup = deferred();
  const { state, sessions } = fixture(Promise.resolve(true), startup.promise);
  const begin = state.beginRecording();
  await Promise.resolve();
  const end = state.endRecording(false);
  startup.resolve();
  await Promise.all([begin, end]);
  assert.equal(sessions[0].cancelled, true);
  assert.equal(state.recording, false);
  assert.equal(state.recordTimer, -1);
  assert.equal(state.voiceFinishing, false);
});

test('slide up cancels; sliding back restores sending using the same finger', async () => {
  const { state } = fixture();
  state.holdTouchId = 7;
  state.holdStartY = 500;
  state.holdTouch({ type: 'move', changedTouches: [{ id: 8, windowY: 100 }] });
  assert.ok(!state.holdCancel);
  state.holdTouch({ type: 'move', changedTouches: [{ id: 7, windowY: 400 }] });
  assert.equal(state.holdCancel, true);
  state.holdTouch({ type: 'move', changedTouches: [{ id: 7, windowY: 480 }] });
  assert.equal(state.holdCancel, false);
});

test('cancel closes feedback without sending or leaving a cancellation notice', async () => {
  const { state, sessions } = fixture();
  await state.beginRecording();
  state.holdStart = Date.now() - 1000;
  state.holdCancel = true;
  await state.endRecording(false);
  assert.equal(sessions[0].cancelled, true);
  assert.equal(state.sent, undefined);
  assert.equal(state.voiceHint, '');
  assert.equal(state.recording, false);
});

test('late recognition cannot write into another session draft', async () => {
  const { state, result } = fixture();
  await state.beginRecording();
  state.holdStart = Date.now() - 1000;
  const end = state.endRecording(false);
  state.resetVoice();
  state.currentId = 'two';
  state.draft = 'other draft';
  result.resolve('old speech');
  await end;
  assert.equal(state.draft, 'other draft');
  assert.equal(state.sent, undefined);
});

test('release sends once; busy session exposes recognized text for editing', async () => {
  for (const idle of [true, false]) {
    const { state, result } = fixture();
    state.idle = idle;
    state.voiceMode = true;
    await state.beginRecording();
    state.holdStart = Date.now() - 1000;
    const end = state.endRecording(false);
    await state.endRecording(false);
    result.resolve('hello');
    await end;
    assert.equal(state.draft, 'hello');
    assert.equal(state.sent, idle ? 'hello' : undefined);
    if (!idle) assert.equal(state.voiceMode, false);
  }
});

test('an incomplete transcript stays editable even in an idle session', async () => {
  const { state, sessions, result } = fixture();
  state.voiceMode = true;
  await state.beginRecording();
  sessions[0].hasFinalTranscript = false;
  state.holdStart = Date.now() - 1000;
  const end = state.endRecording(false);
  result.resolve('partial speech');
  await end;
  assert.equal(state.draft, 'partial speech');
  assert.equal(state.sent, undefined);
  assert.equal(state.voiceMode, false);
});

const voiceSource = readFileSync(new URL('../harmony/entry/src/main/ets/VoiceInput.ets', import.meta.url), 'utf8');
const lexiconStart = voiceSource.indexOf('const DEFAULT_SESSION_LEXICON');
const lexiconEnd = voiceSource.indexOf('export function voiceInputSupported');
assert.ok(lexiconStart >= 0 && lexiconEnd > lexiconStart);
const { normalizeLexicon, DEFAULT_SESSION_LEXICON } = new Function(
  `${stripTypeScriptTypes(voiceSource.slice(lexiconStart, lexiconEnd))}; ` +
  'return { normalizeLexicon, DEFAULT_SESSION_LEXICON };'
)();

test('default session lexicon satisfies Core Speech Kit constraints', () => {
  assert.ok(DEFAULT_SESSION_LEXICON.length > 30, 'lexicon covers common coding vocabulary');
  assert.ok(DEFAULT_SESSION_LEXICON.length <= 200);
  for (const word of DEFAULT_SESSION_LEXICON) {
    assert.ok(word.length >= 2 && word.length <= 20, `bad hot word length: ${word}`);
  }
  assert.equal(new Set(DEFAULT_SESSION_LEXICON).size, DEFAULT_SESSION_LEXICON.length, 'no duplicates');
  // vocabulary that the offline engine garbles most in this app's context
  for (const key of ['会话', '智能体', '提交', 'ArkTS', 'WebSocket', '鸿蒙']) {
    assert.ok(DEFAULT_SESSION_LEXICON.includes(key), `missing key hot word: ${key}`);
  }
});

test('normalizeLexicon validates, dedupes and falls back to defaults', () => {
  assert.deepEqual(normalizeLexicon(undefined), DEFAULT_SESSION_LEXICON);
  assert.deepEqual(normalizeLexicon([]), DEFAULT_SESSION_LEXICON);
  assert.deepEqual(normalizeLexicon([' 智能体 ', '智能体', 'x', '超过二十个字符的超长词汇一定不行'.repeat(2),
    'Pi Go', 'Core Speech Kit', 'DevEco Studio', '自定义词']),
    ['智能体', '自定义词']);
  const many = Array.from({ length: 300 }, (_, i) => `词条${String.fromCharCode(0x4e00 + i)}`);
  assert.equal(normalizeLexicon(many).length, 200);
});

function engineFixture() {
  const engine = {
    setListener(listener) { this.listener = listener; },
    startListening(params) { this.startParams = params; },
    finish() { this.finishing = true; },
    shutdown() {},
  };
  const speechRecognizer = {
    async createEngine(params) { engine.createParams = params; return engine; },
  };
  const VoiceInputSession = new Function('speechRecognizer', 'util',
    stripTypeScriptTypes(voiceSource.replace(/^import .*;\n|^export /gm, '')) +
      '; return VoiceInputSession;')(speechRecognizer, { generateRandomUUID: () => 'press-1' });
  const session = new VoiceInputSession();
  const previews = [];
  return {
    engine, session, previews,
    begin: () => session.begin(text => previews.push(text)),
    result: (result, isFinal = false, isLast = false, id = 'press-1') =>
      engine.listener.onResult(id, { result, isFinal, isLast }),
    complete: () => engine.listener.onComplete('press-1', ''),
  };
}

test('continuous dictation uses long mode, microphone input and session hot words', async () => {
  const { engine, begin } = engineFixture();
  await begin();
  assert.equal(engine.createParams.extraParams.recognizerMode, 'long');
  assert.equal(engine.startParams.extraParams.recognitionMode, 0);
  assert.equal(engine.startParams.extraParams.maxAudioDuration, 60000);
  assert.equal(engine.startParams.extraParams.vadEnd, undefined);
  assert.deepEqual(engine.startParams.extraParams.sessionGeneralLexicon, normalizeLexicon());
  assert.ok(engine.startParams.extraParams.sessionGeneralLexicon.every(word => /^[\u4e00-\u9fffA-Za-z]+$/.test(word)));
});

test('preview spans finalized clauses and shows the latest revision of the current clause', async () => {
  const { begin, result, previews, session, complete, engine } = engineFixture();
  await begin();
  result('先检查构建。', true);
  result('再提交');
  result('再提交代码');
  result('其他会话。', true, true, 'press-2');
  assert.deepEqual(previews, ['先检查构建。', '先检查构建。再提交', '先检查构建。再提交代码']);
  const finishing = session.finish();
  await Promise.resolve();
  assert.equal(engine.finishing, true);
  result('再提交代码。', true, true);
  complete();
  assert.equal(await finishing, '先检查构建。再提交代码。');
  assert.equal(session.hasFinalTranscript, true);
});

test('recognizer errors preserve the unfinished tail for review', async () => {
  const { begin, result, session, engine } = engineFixture();
  await begin();
  result('先构建。', true);
  result('再运行测试');
  engine.listener.onError('press-1', 1002200011, '');
  assert.equal(await session.finish(), '先构建。再运行测试');
  assert.equal(session.hasFinalTranscript, false);
});
