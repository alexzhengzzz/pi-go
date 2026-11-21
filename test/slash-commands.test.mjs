import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const page = readFileSync(new URL('../harmony/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const methods = ['resetCommands', 'loadCommands', 'availableSkills', 'pickCommand', 'pickSkill'].map((name) => {
  const start = page.search(new RegExp(`  private (?:async )?${name}\\(`));
  assert.ok(start >= 0);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
});
class BridgeFailure extends Error {}
const Page = new Function('BridgeFailure',
  stripTypeScriptTypes(`class Page { ${methods.join('\n')} }`) + '; return Page;')(BridgeFailure);

function fixture(request) {
  return Object.assign(new Page(), {
    currentId: 'one', reachable: true, commandsLoading: false,
    commandRows: [], commandError: '', commandRequest: 0, request
  });
}

test('a failed command request clears the rendered loading state and can be retried', async () => {
  const state = fixture(async () => { throw new BridgeFailure('not_found'); });
  const failed = state.loadCommands();
  assert.equal(state.commandsLoading, true);
  await failed;
  assert.equal(state.commandsLoading, false);
  assert.ok(/@State private commandsLoading:/.test(page), 'ArkUI must observe loading changes');
  assert.match(state.commandError, /电脑端/);
  state.request = async () => ({ session: { id: 'one' }, commands: [{ name: 'pi-go' }] });
  await state.loadCommands();
  assert.equal(state.commandError, '');
  assert.deepEqual(state.commandRows, [{ name: 'pi-go' }]);
});

test('a command list from a different desktop session is never cached for the active session', async () => {
  const state = fixture(async () => ({ session: { id: 'two' }, commands: [{ name: 'wrong' }] }));
  await state.loadCommands();
  assert.equal(state.commandsLoading, false);
  assert.deepEqual(state.commandRows, []);
  assert.equal(state.commandsLoadedAt, undefined);
});

test('a response from the previous session cannot overwrite the new session or stop its spinner', async () => {
  const old = Promise.withResolvers();
  const next = Promise.withResolvers();
  const state = fixture(() => old.promise);
  const oldLoad = state.loadCommands();
  state.resetCommands();
  state.currentId = 'two';
  state.request = () => next.promise;
  const nextLoad = state.loadCommands();

  old.resolve({ session: { id: 'one' }, commands: [{ name: 'old' }] });
  await oldLoad;
  assert.deepEqual(state.commandRows, []);
  assert.equal(state.commandsLoading, true);

  next.resolve({ session: { id: 'two' }, commands: [{ name: 'new' }] });
  await nextLoad;
  assert.deepEqual(state.commandRows, [{ name: 'new' }]);
  assert.equal(state.commandsLoading, false);
});

test('the composer skill picker only lists skill commands', () => {
  const state = fixture();
  const skill = { name: 'skill:summarize', source: 'skill' };
  state.commandRows = [{ name: 'review', source: 'prompt' }, skill, { name: 'help', source: 'extension' }];
  assert.deepEqual(state.availableSkills(), [skill]);
});

test('selecting a skill preserves the prompt and replaces an existing skill command', () => {
  const state = fixture();
  const skill = { name: 'skill:summarize', invoke: '/skill:summarize' };
  for (const [draft, prompt] of [
    ['', ''],
    ['/tmp/notes.md', '/tmp/notes.md'],
    ['总结这一段\n保留细节', '总结这一段\n保留细节'],
    ['/skill:previous 总结这一段\n保留细节', '总结这一段\n保留细节']
  ]) {
    Object.assign(state, { draft, showComposerMenu: true, commandPalette: true, voiceMode: true });
    state.pickSkill(skill);
    assert.equal(state.draft, `/skill:summarize ${prompt}`);
    assert.equal(state.showComposerMenu, false);
    assert.equal(state.commandPalette, false);
    assert.equal(state.voiceMode, false);
  }
});
