import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const chat = readFileSync(new URL('../harmony/entry/src/main/ets/ChatContent.ets', import.meta.url), 'utf8');
const { contentBlocks, inlineParts, replySpeechText } = new Function(stripTypeScriptTypes(
  chat.slice(chat.indexOf('interface'), chat.indexOf('@Component')).replace('export function replySpeechText', 'function replySpeechText')) +
  '; return { contentBlocks, inlineParts, replySpeechText };')();

test('reply narration reads rendered content and omits Markdown syntax and link destinations', () => {
  const markdown = '# 标题\n\n- [x] **完成**\n- [文档](https://example.com)\n\n| 名称 | 数值 |\n| --- | --- |\n| A | `42` |';
  assert.equal(replySpeechText(markdown), '标题\n完成\n文档\n名称，数值\nA，42');
});

test('chat Markdown keeps code and escaped images literal and resolves image destinations', () => {
  const blocks = contentBlocks([
    '# C#', 'See ![项目图](<images/项目 图.png> "截图") here.',
    '\\![字面量](literal.jpg) and `![代码](code.jpg)`', '',
    '~~~~ts', '![不是图](never.png)', '~~~', '~~~~',
    '```js', 'const partial = true;'
  ].join('\r\n'));
  assert.deepEqual(blocks.map(({ kind }) => kind), ['heading', 'paragraph', 'image', 'paragraph', 'code', 'code']);
  assert.equal(blocks[0].text, 'C#');
  assert.equal(blocks[2].target, 'images/项目 图.png');
  assert.equal(blocks[4].language, 'ts');
  assert.equal(blocks[4].text, '![不是图](never.png)\n~~~');
  assert.equal(blocks[5].text, 'const partial = true;');
});

test('chat Markdown recognizes tables, quotes, tasks, and inline formatting', () => {
  const blocks = contentBlocks('> 说明\n> 第二行\n\n| Name | Value |\n| :--- | ---: |\n| A\\|B | **42** |\n\n- [x] done\n- [ ] pending\n1. ordered\n+ bullet');
  assert.deepEqual(blocks.map(({ kind }) => kind), ['quote', 'table', 'paragraph']);
  assert.equal(blocks[0].text, '说明\n第二行');
  assert.deepEqual(blocks[1].rows, [['Name', 'Value'], ['A\\|B', '**42**']]);
  assert.equal(blocks[2].text, '☑ done\n☐ pending\n1. ordered\n• bullet');
  assert.deepEqual(inlineParts('**粗体** *斜体* ~~删除~~ `a_b` [链接](a(b).md)').filter(({ kind }) => kind !== 'text'), [
    { kind: 'bold', text: '粗体' }, { kind: 'italic', text: '斜体' }, { kind: 'strike', text: '删除' },
    { kind: 'code', text: 'a_b' }, { kind: 'link', text: '链接', target: 'a(b).md' }
  ]);
});

test('landscape reader opens the selected table with its original Markdown syntax', () => {
  const table = '| 名称 | 值 | 链接 | 说明 |\n| --- | --- | --- | --- |\n| A\\|B | `42` | [文档](docs/a.md) | 保留 |';
  const source = `前面的回复\n\n${table}\n\n后面的回复`;
  const selected = contentBlocks(source).find(({ kind }) => kind === 'table');
  assert.equal(selected.text, table);
  assert.deepEqual(contentBlocks(selected.text)[0].rows, selected.rows);
});

import './harmony-modules.mjs';
const { WorkspaceFileController } = await import('../harmony/entry/src/main/ets/model/WorkspaceFileController.ets');

function rotationHarness(mainWindow) {
  globalThis.pigoTestLastWindow = async () => mainWindow;
  return new WorkspaceFileController({
    getUIContext: () => ({ getHostContext: () => ({}) }),
    dismissKeyboard() {}
  });
}

test('closing a table during rotation restores the original window orientation', async () => {
  const requests = [];
  const rotating = Promise.withResolvers();
  const finishRotation = Promise.withResolvers();
  const reader = rotationHarness({
    getPreferredOrientation: () => 0,
    async setPreferredOrientation(orientation) {
      requests.push(orientation);
      if (orientation === 2) {
        rotating.resolve();
        await finishRotation.promise;
      }
    }
  });
  reader.openMarkdownTableReader('table', '/workspace', '');
  await rotating.promise;
  reader.closeMarkdownTableReader();
  assert.equal(reader.state.markdownTableReader, undefined);
  finishRotation.resolve();
  await reader.markdownRotation;
  assert.deepEqual(requests, [2, 0]);
});
