import assert from 'node:assert/strict';
import { test } from 'node:test';
import './harmony-modules.mjs';
import { harmonyFile } from './harmony-source.mjs';

const { CommandState, skillCommands, skillDraft } = await import('../harmony/entry/src/main/ets/model/CommandState.ets');
const { BridgeFailure } = await import('../harmony/entry/src/main/ets/model/PiGoTypes.ets');

function fixture(request) {
  const commands = new CommandState();
  return {
    commands, request, currentId: 'one', commandsLoading: false, commandRows: [], commandError: '',
    loadCommands() {
      return commands.load(this.currentId, () => this.request(), list => {
        this.commandsLoading = list.loading;
        this.commandError = list.error;
        if (list.rows) this.commandRows = list.rows;
      });
    }
  };
}

const page = harmonyFile('pages/Index.ets');

test('a failed command request clears the rendered loading state and can be retried', async () => {
  const state = fixture(async () => { throw new BridgeFailure(404, 'not_found'); });
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
  assert.equal(state.commands.stale(), true);
});

test('a response from the previous session cannot overwrite the new session or stop its spinner', async () => {
  const old = Promise.withResolvers();
  const next = Promise.withResolvers();
  const state = fixture(() => old.promise);
  const oldLoad = state.loadCommands();
  state.commands.reset();
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
  const skill = { name: 'skill:summarize', source: 'skill' };
  const rows = [{ name: 'review', source: 'prompt' }, skill, { name: 'help', source: 'extension' }];
  assert.deepEqual(skillCommands(rows), [skill]);
});

test('selecting a skill preserves the prompt and replaces an existing skill command', () => {
  const skill = { name: 'skill:summarize', invoke: '/skill:summarize' };
  for (const [draft, prompt] of [
    ['', ''],
    ['/tmp/notes.md', '/tmp/notes.md'],
    ['总结这一段\n保留细节', '总结这一段\n保留细节'],
    ['/skill:previous 总结这一段\n保留细节', '总结这一段\n保留细节']
  ]) {
    assert.equal(skillDraft(skill, draft), `/skill:summarize ${prompt}`);
  }
});
