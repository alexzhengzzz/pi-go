import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const source = readFileSync(new URL('../harmony/entry/src/main/ets/TranscriptTurns.ets', import.meta.url), 'utf8');
const body = source.replace(/^import .*$/gm, '').replace(/\bexport\s+/g, '');
const {
  buildTranscriptTurns,
  isReadOnlyTool,
  lastNonEmptyLine,
  toolActionTitle
} = new Function(stripTypeScriptTypes(body) + '; return { buildTranscriptTurns, isReadOnlyTool, lastNonEmptyLine, toolActionTitle };')();

test('plain Q&A produces no process summary card', () => {
  const turns = buildTranscriptTurns([
    { id: 'u1', role: 'user', text: '你好' },
    { id: 'a1', role: 'assistant', text: '你好，有什么可以帮你？' }
  ], [], '', '', true);

  assert.equal(turns.length, 2);
  assert.equal(turns[0].kind, 'user');
  assert.equal(turns[1].kind, 'assistant');
  assert.equal(turns[1].steps.length, 0);
  assert.equal(turns[1].summary, undefined);
  assert.equal(turns[1].message?.text, '你好，有什么可以帮你？');
});

test('multi-step assistant messages collapse into one process summary before final answer', () => {
  const turns = buildTranscriptTurns([
    { id: 'u1', role: 'user', text: '帮我总结一下项目进度' },
    {
      id: 'a1', role: 'assistant', text: '我先查看文档和目录。', thinking: '先读 PLAN.md', thinkingMs: 2400,
      tools: [
        { id: 't1', name: 'read', detail: 'PLAN.md', state: 'ok', ms: 120 },
        { id: 't2', name: 'grep', detail: 'TODO', state: 'ok', ms: 200 }
      ]
    },
    {
      id: 'a2', role: 'assistant', text: '', thinking: '再跑一下检查', thinkingMs: 3600, imageCount: 1,
      tools: [
        { id: 't3', name: 'bash', detail: 'git status', state: 'ok', ms: 500 },
        { id: 't4', name: 'read', detail: 'package.json', state: 'ok', ms: 90 }
      ]
    },
    {
      id: 'a3', role: 'assistant', text: '当前核心功能已经完成。', thinking: '整理最终结论', thinkingMs: 1000
    }
  ], [], '', '', true);

  assert.equal(turns.length, 2);
  const reply = turns[1];
  assert.equal(reply.kind, 'assistant');
  assert.equal(reply.message?.id, 'a3');
  assert.equal(reply.message?.text, '当前核心功能已经完成。');
  assert.equal(reply.extraImageMessages.length, 1);
  assert.equal(reply.extraImageMessages[0].id, 'a2');
  assert.equal(reply.steps.length, 8);
  assert.equal(reply.summary?.thinkingMs, 7000);
  assert.equal(reply.summary?.toolCount, 4);
  assert.equal(reply.summary?.hasFailure, false);
  assert.equal(reply.summary?.label, '思考 7.0s · 4 项操作（读取 2、搜索 1、命令 1）');
});

test('live turn merges committed steps with active tools and latest thinking line', () => {
  const turns = buildTranscriptTurns([
    { id: 'u1', role: 'user', text: '查一下最新进展' },
    {
      id: 'a1', role: 'assistant', text: '', thinking: '先查目录', thinkingMs: 1500,
      tools: [
        { id: 't1', name: 'read', detail: 'a.md', state: 'ok', ms: 100 },
        { id: 't2', name: 'read', detail: 'b.md', state: 'ok', ms: 100 }
      ]
    }
  ], [
    { id: 't3', name: 'web_search', detail: 'HarmonyOS LiveView', state: 'run' }
  ], '第一行思考\n第二行思考\n\n', '', false);

  assert.equal(turns.length, 2);
  const liveTurn = turns[1];
  assert.equal(liveTurn.isLive, true);
  assert.equal(liveTurn.processId, 'live');
  assert.equal(liveTurn.message, undefined);
  assert.equal(liveTurn.summary?.liveTitle, '正在网页搜索 · 第 3 步');
  assert.equal(liveTurn.summary?.latestThinking, '第二行思考');
  assert.deepEqual(liveTurn.summary?.recentTools.map(({ tool }) => tool.id), ['t2', 't3']);
});

test('streaming liveText keeps earlier assistant messages inside process steps', () => {
  const turns = buildTranscriptTurns([
    { id: 'u1', role: 'user', text: '写一份周报' },
    {
      id: 'a1', role: 'assistant', text: '正在整理素材',
      tools: [{ id: 't1', name: 'read', detail: 'notes.md', state: 'ok', ms: 150 }]
    }
  ], [], '', '## 本周进展\n1. 已完成信息流优化', false);

  assert.equal(turns.length, 2);
  const liveTurn = turns[1];
  assert.equal(liveTurn.message, undefined);
  assert.equal(liveTurn.liveText, '## 本周进展\n1. 已完成信息流优化');
  assert.equal(liveTurn.steps.length, 2);
  assert.equal(liveTurn.summary?.toolCount, 1);
});

test('aborted or failed tool-only turn still renders process summary with failure badge', () => {
  const turns = buildTranscriptTurns([
    { id: 'u1', role: 'user', text: '跑一下脚本' },
    {
      id: 'a1', role: 'assistant', text: '', thinking: '执行构建脚本', thinkingMs: 1200,
      tools: [{ id: 't1', name: 'bash', detail: 'npm run build', state: 'fail', ms: 800 }]
    }
  ], [], '', '', true);

  assert.equal(turns.length, 2);
  const aborted = turns[1];
  assert.equal(aborted.message, undefined);
  assert.equal(aborted.summary?.hasFailure, true);
  assert.equal(aborted.summary?.failCount, 1);
  assert.equal(aborted.summary?.label, '思考 1.2s · 1 项操作（命令 1） · 1 项失败');
});

test('active run between tool rounds stays live instead of flashing settled', () => {
  const turns = buildTranscriptTurns([
    { id: 'u1', role: 'user', text: '读两个文件' },
    {
      id: 'a1', role: 'assistant', text: '', thinking: '先读取', thinkingMs: 3000,
      tools: [
        { id: 't1', name: 'read', detail: 'package.json', state: 'ok', ms: 80 },
        { id: 't2', name: 'read', detail: 'docs/live-view.md', state: 'ok', ms: 60 }
      ]
    }
  ], [], '', '', false);

  assert.equal(turns.length, 2);
  const gapTurn = turns[1];
  assert.equal(gapTurn.isLive, true);
  assert.equal(gapTurn.processId, 'live');
  assert.equal(gapTurn.message, undefined);
  assert.equal(gapTurn.summary?.liveTitle, '正在整理结果… · 第 2 步');
});

test('helper classifications work as expected', () => {
  assert.equal(isReadOnlyTool('read'), true);
  assert.equal(isReadOnlyTool('web_search'), true);
  assert.equal(isReadOnlyTool('bash'), false);
  assert.equal(isReadOnlyTool('edit'), false);
  assert.equal(toolActionTitle('bash'), '执行命令');
  assert.equal(lastNonEmptyLine('a\n  b  \n\n'), 'b');
});
