import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import './harmony-modules.mjs';
import { pageSource } from './harmony-source.mjs';

const {
  MAX_SYSTEM_SHARE_TEXT_BYTES,
  SHARED_SESSION_DIR,
  buildShareDescription,
  formatSessionMarkdown,
  normalizeShareTitle,
  safeShareFileName,
  shareSessionViaSystem
} = await import('../harmony/entry/src/main/ets/SessionShare.ets');

function createMemoryFiles() {
  const dirs = new Set();
  const files = new Map();
  let nextFd = 1;
  const openFds = new Map();

  const api = {
    OpenMode: { CREATE: 1, TRUNC: 2, WRITE_ONLY: 4 },
    accessSync: (path) => dirs.has(path) || files.has(path),
    mkdirSync: (path) => { dirs.add(path); },
    listFileSync: (dir) => {
      const prefix = `${dir}/`;
      const names = [];
      for (const key of files.keys()) {
        if (key.startsWith(prefix)) names.push(key.slice(prefix.length));
      }
      return names;
    },
    statSync: (path) => ({ mtime: files.get(path)?.mtime ?? Math.floor(Date.now() / 1000) }),
    unlinkSync: (path) => { files.delete(path); },
    openSync: (path) => {
      const fd = nextFd++;
      openFds.set(fd, { path, chunks: [] });
      return { fd };
    },
    writeSync: (fd, buffer) => {
      const entry = openFds.get(fd);
      const bytes = new Uint8Array(buffer);
      entry.chunks.push(bytes);
      return bytes.byteLength;
    },
    closeSync: (file) => {
      const entry = openFds.get(file.fd);
      if (!entry) return;
      const total = entry.chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
      const merged = new Uint8Array(total);
      let offset = 0;
      for (const chunk of entry.chunks) {
        merged.set(chunk, offset);
        offset += chunk.byteLength;
      }
      files.set(entry.path, { bytes: merged, mtime: Math.floor(Date.now() / 1000) });
      openFds.delete(file.fd);
    }
  };
  return { api, files };
}

test('formatSessionMarkdown formats user/assistant turns, process summary, images, and live text', () => {
  const messages = [
    { id: 'm1', role: 'user', text: '帮我看下登录问题', imageCount: 1 },
    {
      id: 'm2',
      role: 'assistant',
      text: '先检查 auth.ts',
      thinking: 'Checking auth module',
      thinkingMs: 1200,
      tools: [{ id: 't1', name: 'read', detail: 'src/auth.ts', state: 'ok', ms: 120 }]
    },
    {
      id: 'm3',
      role: 'assistant',
      text: '问题出在 token 过期判断，已定位。'
    }
  ];
  const markdown = formatSessionMarkdown(
    messages,
    {
      title: '排查登录问题',
      workspace: 'pi-go',
      computer: 'MacBook Pro',
      exportedAt: new Date(2026, 10, 23, 5, 30)
    }
  );
  assert.match(markdown, /^# 排查登录问题/);
  assert.match(markdown, /> 工作区：pi-go · 电脑：MacBook Pro · 导出时间：2026-11-23 05:30/);
  assert.match(markdown, /## 用户\n\n帮我看下登录问题\n\n（附 1 张图片）/);
  assert.match(markdown, /## 助手\n\n> 过程：思考 1\.2s · 1 项操作（读取 1）\n\n先检查 auth\.ts\n\n问题出在 token 过期判断，已定位。/);
});

test('formatSessionMarkdown handles empty sessions and fallback titles', () => {
  assert.equal(formatSessionMarkdown([], { title: '空会话' }), '');
  assert.equal(normalizeShareTitle('(no messages)'), '未命名会话');
  assert.equal(normalizeShareTitle('   '), '未命名会话');

  const liveOnly = formatSessionMarkdown([], { title: '(no messages)' }, { liveText: '正在生成的回复' });
  assert.match(liveOnly, /^# 未命名会话/);
  assert.match(liveOnly, /## 助手\n\n正在生成的回复/);
});

test('safeShareFileName preserves readable Unicode and strips forbidden path characters', () => {
  assert.equal(safeShareFileName('重构会话过程展示'), '重构会话过程展示');
  assert.equal(safeShareFileName('../a/b:c*d?e"f<g>h|i.md'), 'a_b_c_d_e_f_g_h_i.md');
  assert.equal(safeShareFileName('///...---'), 'pi-go-session');
  assert.ok(safeShareFileName('a'.repeat(120)).length <= 60);
});

test('shareSessionViaSystem shares Markdown file via HarmonyOS ShareKit', async () => {
  const { api, files } = createMemoryFiles();
  globalThis.pigoTestFiles = api;
  const calls = [];
  globalThis.pigoTestShareShow = async (data, context, options) => {
    calls.push({ records: data.getRecords(), context, options });
  };
  try {
    const context = { cacheDir: '/data/cache' };
    const result = await shareSessionViaSystem(
      context,
      '# 测试会话\n\n内容',
      { title: '测试会话', workspace: 'pi-go' },
      2,
      'markdown',
      'session-settings'
    );
    assert.equal(result.mode, 'markdown');
    assert.equal(result.fallbackToFile, false);
    assert.equal(result.filePath, `/data/cache/${SHARED_SESSION_DIR}/测试会话.md`);
    assert.ok(files.has(result.filePath));
    assert.equal(new TextDecoder().decode(files.get(result.filePath).bytes), '# 测试会话\n\n内容');

    assert.equal(calls.length, 1);
    const [record] = calls[0].records;
    assert.equal(record.utd, 'general.markdown');
    assert.equal(record.uri, `file://com.example.pigo/data/cache/${SHARED_SESSION_DIR}/测试会话.md`);
    assert.equal(record.title, '测试会话.md');
    assert.equal(record.description, buildShareDescription({ title: '测试会话', workspace: 'pi-go' }, 2));
    assert.equal(calls[0].options.anchor, 'session-settings');
  } finally {
    delete globalThis.pigoTestFiles;
    delete globalThis.pigoTestShareShow;
  }
});

test('shareSessionViaSystem shares plain text directly and falls back to file when oversized', async () => {
  const { api, files } = createMemoryFiles();
  globalThis.pigoTestFiles = api;
  const calls = [];
  globalThis.pigoTestShareShow = async (data, context, options) => {
    calls.push({ records: data.getRecords(), context, options });
  };
  try {
    const context = { cacheDir: '/data/cache' };
    const shortResult = await shareSessionViaSystem(
      context,
      '# 短会话\n\n你好',
      { title: '短会话' },
      1,
      'text'
    );
    assert.equal(shortResult.mode, 'text');
    assert.equal(shortResult.fallbackToFile, false);
    assert.equal(files.size, 0);
    assert.equal(calls[0].records[0].utd, 'general.plain-text');
    assert.equal(calls[0].records[0].content, '# 短会话\n\n你好');

    const huge = '中'.repeat(Math.ceil(MAX_SYSTEM_SHARE_TEXT_BYTES / 3) + 100);
    const longResult = await shareSessionViaSystem(
      context,
      huge,
      { title: '超长会话' },
      10,
      'text'
    );
    assert.equal(longResult.mode, 'markdown');
    assert.equal(longResult.fallbackToFile, true);
    assert.equal(calls[1].records[0].utd, 'general.markdown');
    assert.ok(calls[1].records[0].uri.endsWith('/超长会话.md'));
  } finally {
    delete globalThis.pigoTestFiles;
    delete globalThis.pigoTestShareShow;
  }
});

test('Index page collects paginated history and full truncated replies before invoking system share', async () => {
  const page = pageSource();
  function method(name) {
    const start = page.search(new RegExp(`  private (?:async )?${name}\\(`));
    assert.ok(start >= 0, `Missing page method: ${name}`);
    const end = page.indexOf('\n  }', start) + 4;
    return page.slice(start, end);
  }
  const shareCalls = [];
  const Harness = new Function(
    'formatSessionMarkdown',
    'shareSessionViaSystem',
    stripTypeScriptTypes(`class Harness {\n${['fetchFullMessageText', 'collectCurrentSessionMessages', 'shareCurrentSession', 'chatHeaderMenu'].map(method).join('\n')}\n}`) + '; return Harness;'
  )(
    formatSessionMarkdown,
    async (context, content, meta, count, mode, anchor) => {
      shareCalls.push({ context, content, meta, count, mode, anchor });
      return { mode, fallbackToFile: false };
    }
  );

  const state = new Harness();
  const requests = [];
  Object.assign(state, {
    epoch: 1,
    currentId: 'sess-1',
    noSession: '',
    activeTab: 'tasks',
    reachable: true,
    syncMode: 'sequenced',
    sharingSession: false,
    historyCursor: 'cursor-1',
    project: 'pi-go',
    liveText: '',
    messages: [
      { id: 'm2', role: 'assistant', text: '截断片段…', textTruncated: true }
    ],
    chatTitle: () => '完整会话',
    computerTitle: () => 'My Mac',
    openShareMenu: () => {},
    openComputers: () => {},
    requestAction: async () => true,
    copyText: async () => {},
    getUIContext: () => ({
      getHostContext: () => ({ cacheDir: '/cache' }),
      getPromptAction: () => ({ showToast: () => {} })
    }),
    request: async (path) => {
      requests.push(path);
      if (path.startsWith('/history?')) {
        return {
          session: { id: 'sess-1' },
          messages: [{ id: 'm1', role: 'user', text: '最早的一条提问' }],
          historyCursor: undefined
        };
      }
      if (path.startsWith('/message-text?')) {
        return { text: '这是完整的助手回复内容。' };
      }
      throw new Error(`Unexpected request: ${path}`);
    }
  });

  const menu = state.chatHeaderMenu();
  assert.equal(menu[0].value, '分享会话');

  await state.shareCurrentSession('markdown', 'session-settings');
  assert.equal(requests.length, 2);
  assert.equal(shareCalls.length, 1);
  assert.equal(shareCalls[0].count, 2);
  assert.match(shareCalls[0].content, /最早的一条提问/);
  assert.match(shareCalls[0].content, /这是完整的助手回复内容。/);
  assert.equal(shareCalls[0].anchor, 'session-settings');
});
