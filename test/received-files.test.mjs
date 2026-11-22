import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { pageSource } from './harmony-source.mjs';

import './harmony-modules.mjs';
const { isImageFile, markdownWorkspacePath, messageFileChips, normalizeWorkspacePath, safeLocalFileName, textPreviewFormat } = await import('../harmony/entry/src/main/ets/ChatPaths.ets');
const { PiGoClient } = await import('../harmony/entry/src/main/ets/model/PiGoClient.ets');
const { BridgeFailure } = await import('../harmony/entry/src/main/ets/model/PiGoTypes.ets');

const page = pageSource();

test('chat file cards preserve root filenames, quoted spaces and Markdown destinations', () => {
  assert.deepEqual(messageFileChips('请下载 `report.pdf`。 已生成 `exports/项目 报告.pdf`。', '/workspace'),
    ['report.pdf', 'exports/项目 报告.pdf']);
  assert.deepEqual(messageFileChips('保存到了 ./report.pdf.', '/workspace'), ['report.pdf']);
  assert.deepEqual(messageFileChips('[报告](exports/%E6%8A%A5%E5%91%8A%20A.pdf)', '/workspace'),
    ['exports/报告 A.pdf']);
  assert.deepEqual(messageFileChips('[报告](<exports/项目 报告.pdf>) 和 [链接](https://example.com/report.pdf)', '/workspace'),
    ['exports/项目 报告.pdf']);
});

test('file cards reject external and traversal paths and cap the deduplicated results', () => {
  assert.deepEqual(messageFileChips(
    '`/other/a.pdf` `../b.pdf` [越界](%2e%2e/c.pdf) https://example.com/d.pdf `/workspace/a.pdf` ./a.pdf b.pdf c.pdf d.pdf e.pdf',
    '/workspace'), ['a.pdf', 'b.pdf', 'c.pdf', 'd.pdf']);
  assert.deepEqual(messageFileChips('`/report.pdf`', '/'), ['report.pdf']);
  assert.equal(normalizeWorkspacePath('/workspace', './exports/report!.pdf'), 'exports/report!.pdf');
  assert.equal(normalizeWorkspacePath('/workspace', '/workspace-other/report.pdf'), '');
});

test('Markdown resolves local images relative to the document and stays within the workspace', () => {
  assert.equal(markdownWorkspacePath('../images/项目%20图.png', '/workspace', 'docs/guide.md'), 'images/项目 图.png');
  assert.equal(markdownWorkspacePath('%2e%2e/%2e%2e/image.png', '/workspace', 'docs/guide.md'), '');
  assert.equal(markdownWorkspacePath('%2F%2Fhost/image.png', '/workspace', 'docs/guide.md'), '');
  assert.deepEqual(messageFileChips('![图片](images/test.png) [文档](report.pdf)', '/workspace'), ['report.pdf']);
});

function method(name) {
  const start = page.search(new RegExp(`  private (?:async )?${name}\\(`));
  assert.ok(start >= 0);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
}

function receiveFixture(respond, pickDestination = async () => []) {
  const files = new Map([['/cache/pigo-files/source-report.pdf', [99]]]);
  const listeners = new Map();
  const previews = [];
  const fileIo = {
    OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4, READ_ONLY: 0 },
    accessSync: () => true,
    openSync(path, mode) {
      if (mode === this.OpenMode.READ_ONLY) return { fd: { path, offset: 0 } };
      files.set(path, []);
      return { fd: path };
    },
    statSync(fd) { return { size: files.get(fd.path).length }; },
    lseek(fd, start) { fd.offset = start; },
    readSync(fd, buffer) {
      const bytes = files.get(fd.path).slice(fd.offset, fd.offset + Math.min(buffer.byteLength, 7));
      new Uint8Array(buffer).set(bytes);
      fd.offset += bytes.length;
      return bytes.length;
    },
    writeSync(path, bytes) {
      const data = new Uint8Array(bytes);
      const written = Math.min(2, data.length);
      files.get(path).push(...data.subarray(0, written));
      return written;
    },
    closeSync() {},
    renameSync(from, to) {
      files.set(to, files.get(from));
      files.delete(from);
    },
    unlinkSync(path) { files.delete(path); },
    async open(uri) { files.set(uri, []); return { fd: uri }; },
    async close() {},
    async copyFile(from, to) { files.set(to, [...files.get(from)]); }
  };
  const http = {
    RequestMethod: { GET: 'GET' },
    createHttp: () => ({
      on: (event, listener) => listeners.set(event, listener),
      requestInStream: (url, options) => respond({
        url, options,
        header: (length) => listeners.get('headersReceive')({ 'Content-Length': String(length) }),
        chunk: (...bytes) => listeners.get('dataReceive')(Uint8Array.from(bytes).buffer)
      }),
      destroy() {}
    })
  };
  globalThis.pigoTestHttp = http;
  globalThis.pigoTestFiles = fileIo;
  const source = `class Harness {
    ${['openWorkspaceFile', 'downloadFailure', 'readTextFilePreview', 'savePreviewLocally',
      'openReferencedFile', 'openFile', 'showTextPreview', 'editPreview', 'saveFile', 'fileFailure',
      'returnToFilePreview', 'closeFileEditor'].map(method).join('\n')}
  }`;
  const Harness = new Function('fileIo', 'util', 'fileUri', 'filePreview', 'picker', 'BridgeFailure',
    'RECEIVED_FILE_DIR', 'MAX_TEXT_PREVIEW_BYTES', 'isImageFile', 'safeLocalFileName', 'textPreviewFormat',
    stripTypeScriptTypes(source) + '; return Harness;')(
    fileIo, {
      generateRandomUUID: () => 'temporary',
      TextDecoder: {
        create: (encoding, options) => ({
          decodeToString: (bytes, decodeOptions) => new TextDecoder(encoding, options).decode(bytes, decodeOptions)
        })
      }
    },
    { getUriFromPath: (path) => `file://app${path}` },
    { canPreview: async () => true, openPreview: async (_, info) => { previews.push(info); } },
    { DocumentSaveOptions: class {}, DocumentViewPicker: class { save(options) { return pickDestination(options); } } },
    BridgeFailure, 'pigo-files', 128 * 1024, isImageFile, safeLocalFileName, textPreviewFormat
  );
  const client = new PiGoClient();
  const state = Object.assign(new Harness(), {
    downloadFile(cwd, path, temporary, lookupName, limit) {
      return client.downloadFile({ address: this.base, token: this.token, ca: this.ca, pin: this.pin },
        cwd, path, temporary, lookupName, limit);
    },
    reachable: true, epoch: 1, base: 'http://localhost', token: 'test',
    getUIContext: () => ({ getHostContext: () => ({ cacheDir: '/cache' }) }),
    localFilePrefix: () => 'source', pruneReceivedFiles() {}, dismissKeyboard() {}, closeToolDetails() {},
    downloadFailure(error) {
      this.failure = error;
      Harness.prototype.downloadFailure.call(this, error);
    }
  });
  return { state, previews, files };
}

test('a complete streamed download handles short writes and previews the sandbox URI', async () => {
  const { state, files, previews } = receiveFixture(async ({ url, options, header, chunk }) => {
    assert.equal(new URL(url).searchParams.get('path'), 'exports/report.pdf');
    assert.equal(options.maxLimit, 64 * 1024 * 1024);
    header(5);
    chunk(1, 2, 3);
    chunk(4, 5);
    return 200;
  });
  await state.openWorkspaceFile('/workspace', 'exports/report.pdf');
  assert.deepEqual([...files.values()], [[1, 2, 3, 4, 5]]);
  assert.equal(previews[0]?.uri, 'file://app/cache/pigo-files/source-report.pdf');
});

test('downloaded images use the in-app preview and retain their original file', async () => {
  const { state, files, previews } = receiveFixture(async ({ header, chunk }) => {
    header(4);
    chunk(0xff, 0xd8, 0xff, 0xd9);
    return 200;
  });
  await state.openWorkspaceFile('/workspace', 'exports/image.jpg');
  const localPath = '/cache/pigo-files/source-image.jpg';
  assert.equal(state.textFilePreview?.localPath, localPath);
  assert.equal(state.textFilePreview?.imageUri, `file://app${localPath}`);
  assert.deepEqual(files.get(localPath), [0xff, 0xd8, 0xff, 0xd9]);
  assert.deepEqual(previews, []);
});

test('a truncated download removes its temporary file and preserves the previous copy', async () => {
  const { state, files, previews } = receiveFixture(async ({ header, chunk }) => {
    header(5);
    chunk(1, 2, 3);
    return 200;
  });
  await state.openWorkspaceFile('/workspace', 'exports/report.pdf');
  assert.equal(state.failure?.message, 'incomplete_download');
  assert.deepEqual([...files.values()], [[99]]);
  assert.deepEqual(previews, []);
});

test('an older bridge without the download endpoint prompts for an update', async () => {
  const { state, files, previews } = receiveFixture(async ({ chunk }) => {
    chunk(...new TextEncoder().encode('{"error":"not_found"}'));
    return 404;
  });
  await state.openWorkspaceFile('/workspace', 'exports/report.pdf');
  assert.match(state.status, /Pi Go 服务缺少文件下载接口/);
  assert.deepEqual([...files.values()], [[99]]);
  assert.deepEqual(previews, []);
});

test('chat references request filename lookup only for a bare name', async () => {
  const paths = [];
  const { state } = receiveFixture(async ({ url, header }) => {
    const params = new URL(url).searchParams;
    paths.push([params.get('path'), params.get('lookup')]);
    header(0);
    return 200;
  });
  await state.openWorkspaceFile('/workspace', 'report.pdf', true);
  await state.openWorkspaceFile('/workspace', 'exports/report.pdf', true);
  await state.openWorkspaceFile('/workspace', 'report.pdf');
  assert.deepEqual(paths, [['report.pdf', 'name'], ['exports/report.pdf', null], ['report.pdf', null]]);
});

test('downloaded Markdown and CSV open directly in the app', async () => {
  for (const [name, text, markdown] of [
    ['aa.md', '# 预览测试\n\n**内容** 🚀', true],
    ['prices.csv', '名称,价格\n样例,5\n', false],
    ['empty.txt', '', false]
  ]) {
    const { state, previews } = receiveFixture(async ({ header, chunk }) => {
      const bytes = new TextEncoder().encode(text);
      header(bytes.length);
      if (bytes.length) chunk(...bytes);
      return 200;
    });
    await state.openWorkspaceFile('/workspace', name);
    assert.equal(state.textFilePreview?.name, name);
    assert.equal(state.textFilePreview?.text, text);
    assert.equal(state.textFilePreview?.markdown, markdown);
    assert.equal(state.textFilePreview?.nextOffset, undefined);
    assert.deepEqual(previews, []);
  }
});

test('an editable preview saves the resolved path and shows the new text on return', async () => {
  const { state } = receiveFixture(async () => assert.fail('editable text should use the text API'));
  const requests = [];
  state.request = async (route, input) => {
    requests.push([route, input]);
    if (route === '/files/read') return { path: 'notes/todo.md', text: '', version: 'original' };
    return { version: 'saved' };
  };
  await state.openReferencedFile('/workspace', 'todo.md', true);
  assert.equal(state.textFilePreview.text, '');
  assert.equal(state.editingPath, undefined);
  state.editPreview(state.textFilePreview);
  state.fileRoot = '/other';
  state.fileText = '# 更新';
  state.returnToFilePreview();
  assert.equal(state.textFilePreview, undefined);
  assert.equal(state.fileText, '# 更新');
  await state.saveFile();
  state.returnToFilePreview();
  assert.deepEqual(requests, [
    ['/files/read', { cwd: '/workspace', path: 'todo.md', lookup: 'name' }],
    ['/files/save', { cwd: '/workspace', path: 'notes/todo.md', text: '# 更新', version: 'original' }]
  ]);
  assert.equal(state.textFilePreview.text, '# 更新');
  assert.equal(state.textFilePreview.version, 'saved');
});

test('a save conflict preserves the draft and the original version', async () => {
  const { state } = receiveFixture(async () => assert.fail('editable text should use the text API'));
  state.showTextPreview('/workspace', 'todo.md', '# original', 'original');
  state.editPreview(state.textFilePreview);
  state.fileText = '# draft';
  state.request = async () => { throw new Error('file_conflict'); };
  await state.saveFile();
  assert.equal(state.fileText, '# draft');
  assert.equal(state.fileOriginal, '# original');
  assert.equal(state.fileVersion, 'original');
  assert.match(state.editorNotice, /电脑上的文件已变化/);
  state.returnToFilePreview(true);
  assert.equal(state.textFilePreview.text, '# original');
});

test('binary bytes with a text filename are left to the system preview', async () => {
  const { state, previews } = receiveFixture(async ({ header, chunk }) => {
    header(3);
    chunk(0x61, 0, 0xff);
    return 200;
  });
  state.request = async () => { throw new Error('not_text_file'); };
  await state.openFile('/workspace', 'wrong.txt');
  assert.equal(state.textFilePreview?.text, undefined);
  assert.equal(state.textFilePreview?.version, undefined);
  assert.equal(previews[0]?.title, 'wrong.txt');
});

test('large text preview pages preserve every character across a multibyte boundary', () => {
  const { state, files } = receiveFixture(async () => 200);
  const prefix = 'a'.repeat(128 * 1024 - 1);
  files.set('/large.md', new TextEncoder().encode(`${prefix}🚀 remaining text`));
  const first = state.readTextFilePreview('/large.md', 'large.md');
  assert.equal(first.text, prefix);
  assert.equal(first.nextOffset, prefix.length);
  const second = state.readTextFilePreview('/large.md', 'large.md', first.nextOffset);
  assert.equal(second.text, '🚀 remaining text');
  assert.equal(second.nextOffset, undefined);
});

test('local save exports the full downloaded bytes independently of the displayed page', async () => {
  const destination = 'file://docs/report.md';
  const { state, files } = receiveFixture(async () => 200, async (options) => {
    assert.deepEqual(options.newFileNames, ['report.md']);
    return [destination];
  });
  const bytes = [0xef, 0xbb, 0xbf, 65, 13, 10, 66];
  files.set('/cache/report.md', bytes);
  await state.savePreviewLocally({ name: 'report.md', localPath: '/cache/report.md', text: 'A' });
  assert.deepEqual(files.get(destination), bytes);
  assert.equal(state.previewNotice, '已保存到本机。');
});
