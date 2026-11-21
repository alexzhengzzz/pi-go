import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Exercise the actual page methods without requiring an ArkUI device runtime.
const page = readFileSync(new URL('../harmony/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
function method(name) {
  const start = page.search(new RegExp(`  private (?:async )?${name}\\(`));
  assert.ok(start >= 0, `Missing page method: ${name}`);
  const end = page.indexOf('\n  }', start) + 4;
  return page.slice(start, end);
}
const methods = ['setDrawer', 'loadSessions', 'requestAction', 'positionTranscript', 'poll', 'loadSessionStatus', 'applyRunningStatus', 'backgroundRunning', 'backgroundActive', 'sessionState', 'sessionRunning'];
methods.push('cacheChat', 'presentChat', 'send', 'mergeTranscript', 'sameMessage', 'applyLiveSnapshot',
  'handleFrame', 'queueStreamPaint', 'flushStreamDeltas', 'finishSend', 'reconcileSteering');
methods.push('chooseComputer', 'leaveComputer', 'persistComputers', 'pair', 'resetFileTree');
methods.push('appendFileTreeRows', 'updateFileTree', 'toggleFileDirectory', 'loadFileDirectory');
const Page = new Function('Curve', 'BridgeFailure', 'CachePaintFrame', 'validUsb', 'MAX_COMPUTERS', stripTypeScriptTypes(`const STREAM_PAINT_INTERVAL_MS = 32;\nconst MAX_LIVE_TEXT_LENGTH = 16000;\nclass Harness {\n${methods.map(method).join('\n')}\n}`) + '; return Harness;')(
  { EaseOut: 0 },
  class BridgeFailure extends Error {},
  class CachePaintFrame { constructor(at) { this.at = at; } },
  (address) => address === 'http://127.0.0.1:18977',
  12
);
function fixture() {
  const state = new Page();
  Object.assign(state, {
    resetVoice: () => {}, resetCommands: () => {}, syncCommandPalette: () => {},
    fileDirectories: new Map(),
    busy: false, sessionLoading: false, epoch: 1, reachable: true,
    runningSessionIds: [], runningSessions: [], sessionStatusAt: 0, runningCatalogAt: 0, currentId: '', idle: true, queued: false,
    liveText: '', liveThinking: '', liveThinkSeq: 0, liveThinkingOpen: false, thinkingOpenIds: [],
    liveTools: [], liveSeq: 0, liveRevision: 0, streamAlive: false, queuedSteering: [],
    deltaPaintTimer: -1, pendingLiveText: '', pendingLiveThinking: '',
    sessionCatalogLoaded: true, sessionCatalogUpdatedAt: Date.now(), sessionCatalogVersion: 0,
    sessions: [{ id: 'one', cwd: '/project', name: 'Cached task' }], projects: ['/project'],
    sessionQuery: '', loadedQuery: '', sessionView: 'all', loadedView: 'all',
    showSessions: false, sessionCursor: 30, chatCache: new Map(),
    draftKey: id => id, loadSessionStatus: async () => {}, dismissKeyboard: () => {},
    getUIContext: () => ({ animateTo: (_options, change) => change(), postFrameCallback: () => {} })
  });
  return state;
}
const historyHandler = page.match(/\.id\('history'\)[\s\S]*?\.onClick\(\(\) => \{([^}]+)\}\)/)[1];
const clickHistory = new Function(historyHandler);

test('adding a USB computer does not use or replace the active TLS connection when pairing fails', async () => {
  const state = fixture();
  const active = { address: 'https://192.168.1.99:18981', ca: 'active-ca', pin: 'active-pin', token: 'active-token' };
  const usbAddress = 'http://127.0.0.1:18977';
  const requests = [];
  Object.assign(state, {
    base: active.address, ca: active.ca, pin: active.pin, token: active.token, isPaired: true,
    computers: [active], address: usbAddress, pairingMode: 'usb', ticket: '12345678',
    request: async (...args) => { requests.push(args); throw new Error('offline'); },
    leaveComputer: () => assert.fail('A failed pairing must preserve the active computer')
  });
  await state.pair();
  assert.deepEqual(requests, [['/pair', { ticket: '12345678' },
    { address: usbAddress, token: '', ca: undefined, pin: undefined }]]);
  assert.deepEqual([state.base, state.ca, state.pin, state.token],
    [active.address, active.ca, active.pin, active.token]);
  assert.deepEqual(state.computers, [active]);
  assert.equal(state.busy, false);
});

test('selecting a saved computer while connected switches once and retains both credentials', async () => {
  const state = fixture();
  const lan = { address: 'https://192.168.1.99:18981', token: 'lan' };
  const remote = { address: 'https://93.184.216.34:8443', token: 'remote' };
  const remembered = [], saves = [];
  Object.assign(state, {
    base: remote.address, isPaired: true, computers: [remote, lan], currentId: 'remote-session',
    rememberDraft: (id) => remembered.push([state.base, id]),
    cancelSchedule: () => {}, stopStream: () => {}, closeToolDetails: () => {}, flushSidebarSave: () => {},
    setInteraction: () => {},
    activateComputer: (record) => {
      assert.equal(state.currentId, '');
      state.base = record.address;
      state.isPaired = true;
    },
    vault: { save: async (book) => { saves.push(book); } }
  });
  state.chooseComputer(lan);
  assert.equal(state.base, lan.address);
  assert.deepEqual(remembered, [[remote.address, 'remote-session']]);
  assert.deepEqual(saves, [{ version: 2, active: lan.address, computers: [remote, lan] }]);
});

test('reopening the sidebar uses the fresh catalog without another request', () => {
  const state = fixture();
  let requests = 0;
  state.request = async () => { requests++; return { sessions: [] }; };
  clickHistory.call(state);
  assert.equal(state.showSessions, true);
  assert.equal(requests, 0);
  assert.equal(state.busy, false);
  assert.equal(state.sessions[0].id, 'one');
});

test('the workspace tree fetches folders on demand and paginates within a branch', async () => {
  const state = fixture();
  state.fileRoot = '/project';
  const requests = [];
  const entry = (path, kind = 'file') => ({ path, name: path.split('/').at(-1), kind });
  state.request = async (_endpoint, { path, cursor }) => {
    requests.push([path, cursor]);
    if (!path) return { entries: [entry('src', 'directory'), entry('README.md')] };
    if (path === 'src/empty') return { entries: [] };
    if (cursor === 100) return { entries: [entry('src/index.ts'), entry('src/utils.ts')] };
    return { entries: [entry('src/empty', 'directory'), entry('src/index.ts')], nextCursor: 100 };
  };
  const rows = () => state.fileTreeRows.map(({ path, kind, depth }) => [path, kind, depth]);
  const rootRows = [['src', 'directory', 0], ['README.md', 'file', 0]];
  await state.loadFileDirectory('');
  assert.deepEqual(rows(), rootRows);
  await state.toggleFileDirectory('src');
  assert.deepEqual(rows(), [rootRows[0], ['src/empty', 'directory', 1], ['src/index.ts', 'file', 1],
    ['src', 'more', 1], rootRows[1]]);
  await state.loadFileDirectory('src', true);
  await state.toggleFileDirectory('src/empty');
  const expandedRows = [rootRows[0], ['src/empty', 'directory', 1], ['src/empty', 'empty', 2],
    ['src/index.ts', 'file', 1], ['src/utils.ts', 'file', 1], rootRows[1]];
  assert.deepEqual(rows(), expandedRows);
  await state.toggleFileDirectory('src');
  assert.deepEqual(rows(), rootRows);
  await state.toggleFileDirectory('src');
  assert.deepEqual(rows(), expandedRows);
  assert.deepEqual(requests, [['', 0], ['src', 0], ['src', 100], ['src/empty', 0]]);
  await state.loadFileDirectory('');
  assert.deepEqual(rows(), rootRows);
  await state.toggleFileDirectory('src');
  assert.deepEqual(requests.slice(-2), [['', 0], ['src', 0]]);
});

test('stale catalog refresh keeps cached rows interactive and respects closing the drawer', async () => {
  const state = fixture();
  state.sessionCatalogUpdatedAt = 0;
  let finish;
  state.request = () => new Promise(resolve => { finish = resolve; });
  const pending = state.loadSessions();
  assert.equal(state.busy, false, 'catalog reads must not disable task actions');
  assert.equal(state.sessions[0].id, 'one');
  state.setDrawer(false);
  finish({ sessions: [{ id: 'two' }], projects: ['/new'] });
  await pending;
  assert.equal(state.showSessions, false);
  assert.equal(state.sessions[0].id, 'two');
  assert.ok(state.sessionCatalogUpdatedAt > 0);
});


test('repeated opens share one stale refresh and preserve cached pagination', async () => {
  const state = fixture();
  state.sessionCatalogUpdatedAt = 0;
  let requests = 0;
  let finish;
  state.request = () => { requests++; return new Promise(resolve => { finish = resolve; }); };
  clickHistory.call(state);
  state.setDrawer(false);
  clickHistory.call(state);
  assert.equal(requests, 1);
  assert.equal(state.busy, false);
  finish({ sessions: [{ id: 'one' }], nextCursor: 30 });
  await new Promise(resolve => setImmediate(resolve));
  state.sessions.push({ id: 'page-two' });
  state.setDrawer(false);
  clickHistory.call(state);
  assert.equal(requests, 1);
  assert.equal(state.sessions.length, 2);
});

test('refresh failure keeps the cached spaces and tasks', async () => {
  const state = fixture();
  state.request = async () => { throw new Error('offline'); };
  await state.loadSessions();
  assert.equal(state.sessions[0].id, 'one');
  assert.deepEqual(state.projects, ['/project']);
  assert.equal(state.busy, false);
  assert.equal(state.sessionLoading, false);
});

test('results from before a computer switch or catalog mutation are discarded', async () => {
  for (const field of ['epoch', 'sessionCatalogVersion']) {
    const state = fixture();
    let finish;
    state.request = () => new Promise(resolve => { finish = resolve; });
    const pending = state.loadSessions();
    state[field]++;
    finish({ sessions: [{ id: 'outdated' }] });
    await pending;
    assert.equal(state.sessions[0].id, 'one');
    assert.equal(state.sessionLoading, false);
  }
});

test('explicit search bypasses a fresh cache', async () => {
  const state = fixture();
  state.sessionQuery = 'new query';
  let path;
  state.request = async value => { path = value; return { sessions: [{ id: 'found' }] }; };
  await state.loadSessions();
  assert.ok(path.includes('query=new%20query'));
  assert.equal(state.sessions[0].id, 'found');
  assert.equal(state.loadedQuery, 'new query');
});


function navigationFixture() {
  const state = fixture();
  Object.assign(state, {
    showSessions: true, currentId: 'one', messages: [{ id: 'old' }], liveText: '',
    openingSession: false, pendingSessionReveal: '', pendingBottom: false,
    applySession: session => {
      if (state.currentId !== session.id) { state.messages = []; state.pendingBottom = true; }
      state.currentId = session.id; state.idle = session.idle ?? true;
    },
    schedule: () => {}, cancelSchedule: () => {}, setInteraction: () => {}, resetVoice: () => {}
  });
  return state;
}

test('opening a task keeps sidebar controls bright and prevents duplicate opens', async () => {
  const state = navigationFixture();
  let finish;
  let requests = 0;
  state.request = () => { requests++; return new Promise(resolve => { finish = resolve; }); };
  const pending = state.requestAction('/open', { id: 'two' });
  const stayedInteractive = !state.busy;
  await state.requestAction('/open', { id: 'three' });
  assert.equal(requests, 1);
  finish({ session: { id: 'two' } });
  // A successful open must fetch the initial transcript before exposing the new session.
  state.request = async () => ({ session: { id: 'two' }, messages: [{ id: 'latest' }] });
  await pending;
  assert.equal(stayedInteractive, true, 'opening a task must not gray out the sidebar');
});

test('navigation loads the transcript before dismissing the sidebar', async () => {
  const state = navigationFixture();
  const calls = [];
  let nextPoll;
  state.schedule = delay => { nextPoll = delay; };
  state.request = async path => {
    calls.push(path);
    return path === '/open' ? { session: { id: 'two' } } :
      { session: { id: 'two' }, messages: [{ id: 'latest' }], liveText: 'stream', historyCursor: 'older' };
  };
  assert.equal(await state.requestAction('/open', { id: 'two' }), true);
  assert.deepEqual(calls, ['/open', '/chat']);
  assert.equal(state.showSessions, true, 'keep the drawer until transcript layout is at the bottom');
  assert.equal(state.messages[0].id, 'latest');
  assert.equal(state.liveText, 'stream');
  assert.equal(state.historyCursor, 'older');
  assert.equal(state.pendingSessionReveal, 'two');
  assert.ok(nextPoll >= 650, 'avoid an immediate duplicate chat request');
});


test('initial positioning jumps without animation before revealing the conversation', () => {
  const state = navigationFixture();
  state.currentId = 'two';
  state.pendingBottom = true;
  state.pendingSessionReveal = 'two';
  const events = [];
  state.transcript = { scrollTo: options => {
    assert.equal(state.showSessions, true, 'position before exposing the conversation');
    events.push(['position', options]);
  } };
  state.setDrawer = () => { assert.fail('automatic reveal must not animate the drawer'); };
  state.positionTranscript('one', 5000);
  assert.equal(events.length, 0, 'ignore callbacks from the previous transcript');
  state.positionTranscript('two', 5000);
  assert.deepEqual(events, [
    ['position', { xOffset: 0, yOffset: 5000, animation: false }]
  ]);
  assert.equal(state.showSessions, false);
  assert.equal(state.pendingSessionReveal, '');
  assert.equal(state.pendingBottom, false);
  state.positionTranscript('two', 5000);
  assert.equal(events.length, 1, 'later layout must not reset the reading position');
});

test('polling does not race the initial navigation snapshot', async () => {
  const state = navigationFixture();
  state.openingSession = true;
  state.request = async () => { assert.fail('poll must wait for navigation'); };
  await state.poll();
});

test('failed initial transcript leaves the drawer available for retry', async () => {
  const state = navigationFixture();
  state.request = async path => {
    if (path === '/open') return { session: { id: 'two' } };
    throw new Error('network');
  };
  assert.equal(await state.requestAction('/open', { id: 'two' }), false);
  assert.equal(state.showSessions, true);
  assert.equal(state.openingSession, false);
  assert.equal(state.busy, false);
  assert.equal(state.currentId, 'one');
});

test('returning to a cached conversation renders before the open request finishes', async () => {
  const state = navigationFixture();
  state.chatCache = new Map([['two', {
    session: { id: 'two', cwd: '/project', idle: true },
    messages: [{ id: 'cached-latest', text: 'Already read' }], liveText: ''
  }]]);
  state.draftKey = id => id;
  let finishOpen;
  state.request = path => path === '/open' ? new Promise(resolve => { finishOpen = resolve; }) :
    Promise.resolve({ session: { id: 'two', cwd: '/project', idle: true }, messages: [{ id: 'fresh-latest' }] });
  const pending = state.requestAction('/open', { id: 'two' });
  const renderedBeforeOpen = state.currentId === 'two' && state.messages[0]?.id === 'cached-latest';
  if (renderedBeforeOpen) {
    state.transcript = { scrollTo: () => {} };
    state.positionTranscript('two', 5000);
    assert.equal(state.showSessions, false);
    assert.equal(state.openingSession, true, 'sending stays blocked until the remote switch is confirmed');
    state.draft = 'Must wait';
    await state.send();
    assert.equal(state.pendingSend, undefined);
  }
  finishOpen({ session: { id: 'two', cwd: '/project', idle: true } });
  await pending;
  assert.equal(renderedBeforeOpen, true, 'cached conversation must not wait for the network');
  assert.equal(state.messages[0].id, 'fresh-latest');
  assert.equal(state.openingSession, false);
});


test('running status refresh updates all tasks without replacing cached pages', async () => {
  const state = fixture();
  state.loadSessionStatus = Page.prototype.loadSessionStatus;
  state.sessions.push({ id: 'page-two' });
  let calls = 0;
  state.request = async path => {
    assert.equal(path, '/sessions/status');
    calls++;
    return { runningSessionIds: calls === 1 ? ['page-two'] : [] };
  };
  await state.loadSessionStatus();
  assert.equal(state.sessionRunning('page-two'), true);
  assert.equal(state.sessionRunning('one'), false);
  assert.equal(state.sessions.length, 2);
  assert.equal(state.sessionCursor, 30);
  await state.loadSessionStatus();
  assert.equal(state.sessionRunning('page-two'), false);
});

test('running badges use current chat state and disappear when disconnected', () => {
  const state = fixture();
  state.currentId = 'one';
  state.runningSessionIds = ['one', 'other'];
  assert.equal(state.sessionRunning('one'), false);
  state.idle = false;
  assert.equal(state.sessionRunning('one'), true);
  state.idle = true;
  state.queued = true;
  assert.equal(state.sessionRunning('one'), true);
  state.reachable = false;
  assert.equal(state.sessionRunning('one'), false);
  assert.equal(state.sessionRunning('other'), false);
});

test('status requests deduplicate and discard results from the previous computer', async () => {
  const state = fixture();
  state.loadSessionStatus = Page.prototype.loadSessionStatus;
  let finish;
  let requests = 0;
  state.request = () => { requests++; return new Promise(resolve => { finish = resolve; }); };
  const pending = state.loadSessionStatus();
  await state.loadSessionStatus();
  assert.equal(requests, 1);
  state.epoch++;
  finish({ runningSessionIds: ['old-computer'] });
  await pending;
  assert.deepEqual(state.runningSessionIds, []);
  assert.equal(state.sessionStatusLoading, false);
});

test('failed status refresh clears old badges and preserves the catalog', async () => {
  const state = fixture();
  state.runningSessionIds = ['one'];
  state.request = async () => { throw new Error('offline'); };
  await Page.prototype.loadSessionStatus.call(state);
  assert.deepEqual(state.runningSessionIds, []);
  assert.equal(state.sessions[0].id, 'one');
});

test('running status carries session names for header capsules and merges legacy ids', () => {
  const state = fixture();
  state.applyRunningStatus({ runningSessions: [
    { id: 'one', name: 'Refactor tests', cwd: '/a' },
    { id: 'two', name: 'Deploy site', cwd: '/b' },
    { id: undefined, name: 'broken row' },
  ], runningSessionIds: ['one', 'two', 'three'] });
  assert.deepEqual(state.runningSessions.map(row => row.id), ['one', 'two']);
  assert.deepEqual(state.runningSessionIds, ['one', 'two', 'three']);
  // Only legacy bridge without runningSessions: rows stay empty but ids still feed list badges.
  state.applyRunningStatus({ runningSessionIds: ['legacy'] });
  assert.deepEqual(state.runningSessions, []);
  assert.deepEqual(state.runningSessionIds, ['legacy']);
  state.applyRunningStatus(undefined);
  assert.deepEqual(state.runningSessionIds, []);
  assert.deepEqual(state.runningSessions, []);
});

test('background running rows exclude the open conversation so the header shows the others', () => {
  const state = fixture();
  state.currentId = 'one';
  state.runningSessions = [
    { id: 'one', name: 'Current chat' },
    { id: 'two', name: 'Deploy site' },
    { id: 'three', name: 'Refactor tests' },
  ];
  assert.deepEqual(state.backgroundRunning().map(row => row.id), ['two', 'three']);
  assert.equal(state.backgroundRunning()[0].name, 'Deploy site');
});

test('unnamed running rows fall back to the cached catalog name', () => {
  const state = fixture();
  state.currentId = 'one';
  state.sessions = [{ id: 'two', cwd: '/project', name: 'Cached task' }];
  state.runningSessions = [{ id: 'two' }];
  const [row] = state.backgroundRunning();
  assert.equal(row.name, 'Cached task');
  state.sessions = [];
  assert.equal(state.backgroundRunning()[0].name, undefined, 'no catalog rows still leave the pill usable');
});

test('session states distinguish streaming, waiting and queued for both pills and badges', () => {
  const state = fixture();
  state.currentId = 'one';
  state.runningSessions = [
    { id: 'two', state: 'waiting' },
    { id: 'three', state: 'queued' },
    { id: 'four', state: 'streaming' },
  ];
  state.runningSessionIds = ['one', 'two', 'three', 'four', 'legacy-raw'];
  assert.equal(state.sessionState('two'), 'waiting');
  assert.equal(state.sessionState('three'), 'queued');
  assert.equal(state.sessionState('four'), 'streaming');
  assert.equal(state.sessionState('legacy-raw'), 'streaming', 'legacy rows default to streaming');
  assert.equal(state.sessionState('idle-task'), '');
  // The open conversation prefers live local state: a pending interaction outranks streaming.
  state.idle = false;
  assert.equal(state.sessionState('one'), 'streaming');
  state.interaction = { id: 'q', method: 'input' };
  assert.equal(state.sessionState('one'), 'waiting');
  state.interaction = undefined;
  state.idle = true;
  state.queued = true;
  assert.equal(state.sessionState('one'), 'queued');
  state.reachable = false;
  assert.equal(state.sessionState('one'), '');
});

test('legacy bridges without runningSessions still produce header pills from raw ids', () => {
  const state = fixture();
  state.currentId = 'one';
  state.sessions = [{ id: 'two', cwd: '/project', name: 'Cached task' }, { id: 'three', cwd: '/project', name: 'Deploy site' }];
  state.runningSessionIds = ['one', 'two', 'three'];
  state.runningSessions = [];
  assert.deepEqual(state.backgroundRunning().map(row => [row.id, row.name]),
    [['two', 'Cached task'], ['three', 'Deploy site']]);
  assert.equal(state.backgroundActive(), true);
  // A merged mix keeps named rows and only synthesizes the missing ones.
  state.runningSessions = [{ id: 'two', name: 'Live name', cwd: '/project' }];
  assert.deepEqual(state.backgroundRunning().map(row => [row.id, row.name]),
    [['two', 'Live name'], ['three', 'Deploy site']]);
});

test('an unknown background task triggers a catalog refresh at most every 30 seconds', async () => {
  const state = fixture();
  state.currentId = 'one';
  state.sessions = [];
  let catalogLoads = 0;
  state.loadSessions = async () => { catalogLoads++; };
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  assert.equal(state.backgroundActive(), true);
  await new Promise(resolve => setImmediate(resolve));
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(catalogLoads, 1, 'second status update within 30s must not reload the catalog');
  state.runningCatalogAt -= 31000;
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(catalogLoads, 2);
  state.sessions = [{ id: 'two', name: 'Known now' }];
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(catalogLoads, 2, 'known tasks never trigger a catalog reload');
});

test('chat polling keeps watching background tasks with the drawer closed', async () => {
  const state = navigationFixture();
  state.showSessions = false;
  state.currentId = 'one';
  state.runningSessions = [];
  let statusRequests = 0;
  state.request = async path => {
    if (path === '/sessions/status') {
      statusRequests++;
      return statusRequests === 1 ?
        { runningSessions: [{ id: 'two', name: 'Deploy site' }], runningSessionIds: ['one', 'two'] } :
        { runningSessions: [{ id: 'two', name: 'Deploy site' }], runningSessionIds: ['two'] };
    }
    return { session: { id: 'one', idle: false }, messages: [] };
  };
  state.loadSessionStatus = Page.prototype.loadSessionStatus;
  state.sessionStatusAt = 0;
  await state.poll();
  assert.equal(statusRequests, 1, 'first poll probes desktop-started tasks');
  await state.poll();
  assert.equal(statusRequests, 2, 'background tasks keep refreshing while the chat stays open');
  assert.deepEqual(state.backgroundRunning().map(row => row.id), ['two']);
});

test('idle chats only probe running status on a slow schedule', async () => {
  const state = navigationFixture();
  state.showSessions = false;
  state.currentId = 'one';
  state.runningSessions = [];
  let statusRequests = 0;
  state.request = async path => {
    if (path === '/sessions/status') { statusRequests++; return { runningSessionIds: [] }; }
    return { session: { id: 'one', idle: true }, messages: [] };
  };
  state.loadSessionStatus = Page.prototype.loadSessionStatus;
  state.sessionStatusAt = Date.now();
  await state.poll();
  await state.poll();
  assert.equal(statusRequests, 0, 'fresh probe suppresses extra requests while nothing runs');
  state.sessionStatusAt -= 6000;
  await state.poll();
  assert.equal(statusRequests, 1, 'a slow probe still discovers tasks started later');
});


test('a failed remote switch restores the previous conversation and offers retry', async () => {
  const state = navigationFixture();
  state.chatCache.set('one', { session: { id: 'one' }, messages: [{ id: 'old' }] });
  state.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
  state.request = async () => { throw new Error('desktop unavailable'); };
  assert.equal(await state.requestAction('/open', { id: 'two' }), false);
  assert.equal(state.currentId, 'one');
  assert.equal(state.messages[0].id, 'old');
  assert.equal(state.showSessions, true);
  assert.equal(state.pendingSessionReveal, '');
  assert.equal(state.openingSession, false);
});

test('a failed refresh after a confirmed switch preserves the cached conversation', async () => {
  const state = navigationFixture();
  state.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
  state.request = async path => {
    if (path === '/open') return { session: { id: 'two' } };
    throw new Error('temporary chat failure');
  };
  await state.requestAction('/open', { id: 'two' });
  assert.equal(state.currentId, 'two');
  assert.equal(state.messages[0].id, 'cached');
  assert.equal(state.openingSession, false);
});

test('background refresh does not scroll again after the cached conversation is positioned', async () => {
  const state = navigationFixture();
  state.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
  let finish;
  state.request = path => path === '/open' ? new Promise(resolve => { finish = resolve; }) :
    Promise.resolve({ session: { id: 'two' }, messages: [{ id: 'fresh' }] });
  const pending = state.requestAction('/open', { id: 'two' });
  let scrolls = 0;
  state.transcript = { scrollTo: () => { scrolls++; } };
  state.positionTranscript('two', 3000);
  finish({ session: { id: 'two' } });
  await pending;
  state.positionTranscript('two', 4000);
  assert.equal(scrolls, 1);
  assert.equal(state.showSessions, false);
});

test('chat cache is bounded and retains a usable history cursor', () => {
  const state = navigationFixture();
  state.messages = Array.from({ length: 120 }, (_, index) => ({ id: String(index) }));
  for (let index = 0; index < 10; index++) state.cacheChat({ id: String(index) });
  assert.equal(state.chatCache.size, 8);
  assert.equal(state.chatCache.has('0'), false);
  const cached = state.chatCache.get('9');
  assert.equal(cached.messages.length, 60);
  assert.equal(cached.historyCursor, '60');
});

test('the same session id on a different computer cannot use another computer cache', async () => {
  const state = navigationFixture();
  state.draftKey = id => 'new-computer|' + id;
  state.chatCache.set('old-computer|two', { session: { id: 'two' }, messages: [{ id: 'private-old' }] });
  let finish;
  state.request = path => path === '/open' ? new Promise(resolve => { finish = resolve; }) :
    Promise.resolve({ session: { id: 'two' }, messages: [{ id: 'new' }] });
  const pending = state.requestAction('/open', { id: 'two' });
  assert.equal(state.currentId, 'one');
  finish({ session: { id: 'two' } });
  await pending;
  assert.equal(state.messages[0].id, 'new');
});

test('identical transcript polls reuse the existing array and preserve earlier history', () => {
  const state = navigationFixture();
  const recent = { id: 'latest', text: 'Answer', tools: [{ id: 'read', state: 'run' }] };
  const history = [{ id: 'older' }, recent];
  state.messages = history;
  state.historyCursor = 'oldest';

  state.mergeTranscript([structuredClone(recent)], 'latest');
  assert.equal(state.messages, history);

  const completed = { ...recent, tools: [{ id: 'read', state: 'ok' }] };
  state.mergeTranscript([completed], 'latest');
  assert.deepEqual(state.messages, [history[0], completed]);
  assert.equal(state.historyCursor, 'oldest');
});

test('confirmed steering is visible before transcript refresh and repeated messages reconcile individually', () => {
  const state = navigationFixture();
  Object.assign(state, { idle: false, unconfirmed: new Map(), draftAttachments: new Map(), draft: 'Change direction' });
  const original = { id: 'original', role: 'user', text: state.draft };
  state.messages = [original];
  const pending = id => ({ requestId: id, text: original.text, attachments: [], steeringAfter: original.id });
  state.finishSend('one', pending('first'));
  assert.deepEqual(state.queuedSteering.map(item => item.id), ['first']);
  assert.deepEqual(state.messages, [original]);
  assert.equal(state.draft, '');
  assert.equal(state.pendingBottom, true);

  state.pendingSend = pending('second');
  state.messages.push({ ...original, id: 'delivered-first' });
  state.reconcileSteering(false);
  state.finishSend('one', state.pendingSend);
  assert.deepEqual(state.queuedSteering.map(item => item.id), ['second']);
  state.reconcileSteering(false);
  assert.deepEqual(state.queuedSteering.map(item => item.id), ['second']);

  state.messages.push({ ...original, id: 'delivered-second' });
  state.reconcileSteering(false);
  assert.deepEqual(state.queuedSteering, []);
});

test('queued attachment previews stay scoped to the conversation and clear when it settles', () => {
  const state = navigationFixture();
  Object.assign(state, { idle: false, unconfirmed: new Map(), draftAttachments: new Map(), draft: '', messages: [] });
  state.finishSend('one', { requestId: 'file', text: '', steeringAfter: '', attachments: [{ kind: 'file', name: 'note.md' }] });
  assert.deepEqual(state.queuedSteering[0].files, ['note.md']);
  state.currentId = 'other';
  state.reconcileSteering(true);
  assert.equal(state.queuedSteering.length, 1);
  state.currentId = 'one';
  state.reconcileSteering(true);
  assert.deepEqual(state.queuedSteering, []);
});

test('stream paints combine text and thinking and discard duplicate and finalized deltas', () => {
  const state = navigationFixture();
  const frame = payload => state.handleFrame(JSON.stringify({ sessionId: 'one', ...payload }));
  frame({ type: 'message/delta', text: 'Hello', seq: 1 });
  const timer = state.deltaPaintTimer;
  frame({ type: 'message/delta', text: ' duplicate', seq: 1 });
  frame({ type: 'message/delta', text: ' world', seq: 2 });
  frame({ type: 'message/thinking', text: 'Planning', seq: 1 });
  assert.equal(state.deltaPaintTimer, timer);
  assert.equal(state.liveText, '');
  state.flushStreamDeltas();
  assert.equal(state.liveText, 'Hello world');
  assert.equal(state.liveThinking, 'Planning');
  assert.equal(state.pendingBottom, true);

  frame({ type: 'message/delta', text: '!', seq: 3 });
  frame({ type: 'message/final', seq: 4, thinkingSeq: 2 });
  state.flushStreamDeltas();
  assert.equal(state.liveText, '');
  assert.equal(state.liveThinking, '');
});

test('an idle poll started before a new run preserves its buffered stream', async () => {
  const state = navigationFixture();
  let finish;
  state.request = () => new Promise(resolve => { finish = resolve; });
  const polling = state.poll();
  state.handleFrame(JSON.stringify({ type: 'session/status', sessionId: 'one', idle: false }));
  state.handleFrame(JSON.stringify({ type: 'message/delta', sessionId: 'one', seq: 1, text: 'New run' }));
  finish({ session: { id: 'one', idle: true }, messages: [] });
  await polling;
  state.flushStreamDeltas();
  assert.equal(state.idle, false);
  assert.equal(state.liveText, 'New run');
});
