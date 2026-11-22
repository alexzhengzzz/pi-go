import assert from 'node:assert/strict';
import { test } from 'node:test';
import './harmony-modules.mjs';
import { harmonyFile } from './harmony-source.mjs';

const { SessionStore } = await import('../harmony/entry/src/main/ets/model/SessionStore.ets');
const { CredentialVault } = await import('../harmony/entry/src/main/ets/CredentialVault.ets');

function pageFixture(book = { version: 1, entries: [] }) {
  const store = new SessionStore();
  store.restoreSidebar(book);
  const state = {
    base: 'http://127.0.0.1:18977',
    expandedSpaces: [],
    sessionView: 'all',
    savedBooks: [],
    toggleSpace(path) {
      this.expandedSpaces = store.toggleSpace(this.expandedSpaces, path);
      store.saveSidebar(this.base, this, this.persist);
    },
    applySidebar(address) {
      Object.assign(this, store.sidebarFor(address));
    },
    flushSidebarSave() {
      store.flushSidebar(this.persist);
    }
  };
  state.persist = saved => state.savedBooks.push(saved);
  return state;
}

function vaultFixture(raw = '') {
  const store = {
    values: new Map([['sidebar', raw]]),
    flushes: 0,
    get: async (key, defaultValue) => (store.values.has(key) ? store.values.get(key) : defaultValue),
    put: async (key, value) => { store.values.set(key, value); },
    flush: async () => { store.flushes++; }
  };
  const instance = new CredentialVault(store);
  return { instance, store };
}

test('opening a space records it for persistence and closing it clears the fold', () => {
  const state = pageFixture();
  state.toggleSpace('/repo');
  assert.deepEqual(state.expandedSpaces, ['/repo']);
  assert.equal(state.savedBooks.length, 0, 'the save is debounced');
  state.flushSidebarSave();
  assert.equal(state.savedBooks.length, 1);
  assert.deepEqual(state.savedBooks[0].entries, [{
    address: 'http://127.0.0.1:18977',
    state: { expandedSpaces: ['/repo'], sessionView: 'all' }
  }]);
  state.toggleSpace('/repo');
  assert.deepEqual(state.expandedSpaces, []);
});

test('repeated toggles coalesce into one save', () => {
  const state = pageFixture();
  state.toggleSpace('/a');
  state.toggleSpace('/b');
  state.flushSidebarSave();
  assert.equal(state.savedBooks.length, 1);
  assert.deepEqual(state.savedBooks[0].entries[0].state.expandedSpaces, ['/a', '/b']);
});

test('connecting restores the remembered expanded folders and filter state per computer', () => {
  const state = pageFixture({ version: 1, entries: [
    { address: 'lan://desk', state: { expandedSpaces: ['/a', '/b'], sessionView: 'pinned' } }
  ]});
  state.applySidebar('lan://desk');
  assert.deepEqual(state.expandedSpaces, ['/a', '/b']);
  assert.equal(state.sessionView, 'pinned');
  state.applySidebar('usb://other');
  assert.deepEqual(state.expandedSpaces, []);
  assert.equal(state.sessionView, 'all');
});

test('folders stay collapsed on connect until the user opens them', () => {
  const state = pageFixture();
  state.applySidebar('lan://desk');
  state.base = 'lan://desk';
  assert.deepEqual(state.expandedSpaces, [], 'a computer without remembered state starts fully collapsed');
  state.toggleSpace('/repo');
  state.flushSidebarSave();
  state.applySidebar('lan://desk');
  assert.deepEqual(state.expandedSpaces, ['/repo'], 'only the folder the user opened stays open');
  state.toggleSpace('/new-space');
  state.flushSidebarSave();
  state.applySidebar('lan://desk');
  assert.deepEqual(state.expandedSpaces, ['/repo', '/new-space']);
  state.toggleSpace('/repo');
  state.flushSidebarSave();
  state.applySidebar('lan://desk');
  assert.deepEqual(state.expandedSpaces, ['/new-space'], 'closing a folder is remembered too');
});

test('switching computers keeps each computer folds independent', () => {
  const state = pageFixture();
  state.applySidebar('lan://desk');
  state.base = 'lan://desk';
  state.toggleSpace('/work');
  state.flushSidebarSave();
  state.applySidebar('http://127.0.0.1:18977');
  assert.deepEqual(state.expandedSpaces, []);
  state.applySidebar('lan://desk');
  assert.deepEqual(state.expandedSpaces, ['/work']);
});

test('toggles without a connected computer never enter the book', () => {
  const state = pageFixture();
  state.base = '';
  state.toggleSpace('/repo');
  assert.equal(state.savedBooks.length, 0);
  state.flushSidebarSave();
  assert.equal(state.savedBooks.length, 1);
  assert.deepEqual(state.savedBooks[0].entries, []);
});

test('the drawer connects the filter and virtualized rows to the session store', () => {
  const sidebar = harmonyFile('components/SessionSidebar.ets');
  const page = harmonyFile('pages/Index.ets');
  assert.doesNotMatch(sidebar, /\.id\('session-(query|search)'\)/);
  assert.match(page, /this\.sessionView = view;\s+this\.scheduleSidebarSave\(\);/);
  assert.match(page, /this\.applySidebar\(record\.address\);/);
  assert.match(sidebar, /view === 'recent' \? '最近'/);
  assert.match(sidebar, /this\.expandedSpaces\.includes\(path\) \? 0 : -90/);
  assert.match(sidebar, /LazyForEach\(this\.sidebarRows/);
});

test('the vault roundtrips sidebar state through the store', async () => {
  const { instance, store } = vaultFixture();
  const book = { version: 1, entries: [
    { address: 'lan://desk', state: { expandedSpaces: ['/a'], sessionView: 'recent' } }
  ]};
  await instance.saveSidebar(book);
  assert.equal(store.values.get('sidebar'), JSON.stringify(book));
  assert.ok(store.flushes >= 1, 'the store is flushed');
  assert.deepEqual(await instance.loadSidebar(), book);
});

test('a missing or corrupted cache falls back to fully collapsed defaults', async () => {
  for (const raw of ['', '{broken json', 'null', JSON.stringify({ version: 9, entries: [{ address: 'x', state: {} }] })]) {
    const { instance } = vaultFixture(raw);
    assert.deepEqual(await instance.loadSidebar(), { version: 1, entries: [] }, `raw=${raw}`);
  }
});

test('legacy collapsed-spaces cache loads as fully collapsed', async () => {
  const raw = JSON.stringify({ version: 1, entries: [
    { address: 'lan://old', state: { collapsedSpaces: ['/a'], tasksExpanded: true, sessionView: 'all' } }
  ]});
  const { instance } = vaultFixture(raw);
  const book = await instance.loadSidebar();
  assert.equal(book.entries.length, 1);
  assert.deepEqual(book.entries[0].state.expandedSpaces, [],
    'old records never silently expand folders on connect');
  assert.equal(book.entries[0].state.sessionView, 'all');
});

test('stored entries are validated, deduplicated and clamped', async () => {
  const raw = JSON.stringify({ version: 1, entries: [
    { address: 'lan://a', state: { expandedSpaces: ['/x', 42, null], tasksExpanded: false, sessionView: 'nonsense' } },
    { address: 'lan://a', state: { tasksExpanded: true } },
    { state: { tasksExpanded: true } },
    'garbage'
  ]});
  const { instance } = vaultFixture(raw);
  const book = await instance.loadSidebar();
  assert.equal(book.entries.length, 1);
  assert.deepEqual(book.entries[0].state.expandedSpaces, ['/x']);
  assert.equal(book.entries[0].state.tasksExpanded, undefined);
  assert.equal(book.entries[0].state.sessionView, 'all');
});

test('a failed sidebar write does not block later saves', async () => {
  const { instance, store } = vaultFixture();
  const originalPut = store.put;
  store.put = async () => { throw new Error('disk full'); };
  await assert.rejects(() => instance.saveSidebar({ version: 1, entries: [] }));
  store.put = originalPut;
  await instance.saveSidebar({ version: 1, entries: [
    { address: 'lan://ok', state: { expandedSpaces: [], sessionView: 'all' } }
  ]});
  const book = await instance.loadSidebar();
  assert.equal(book.entries[0].address, 'lan://ok');
});
