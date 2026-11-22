import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { stripTypeScriptTypes } from 'node:module';

const source = readFileSync(new URL('../harmony/entry/src/main/ets/AccountSync.ets', import.meta.url), 'utf8')
  .replace(/^import .*\n/gm, '')
  .replace(/^export /gm, '');
const loadSync = new Function('relationalStore', 'cryptoFramework', 'util',
  stripTypeScriptTypes(source) + '\nreturn { AccountSync, computerSyncRow };');

function fixture(t) {
  const databases = new Map();
  t.after(() => { for (const db of databases.values()) db.close(); });
  const configurations = [];
  let cloudCode = 0;
  const rdb = {
    SecurityLevel: { S1: 1 },
    DistributedType: { DISTRIBUTED_CLOUD: 1 },
    SyncMode: { SYNC_MODE_TIME_FIRST: 1 },
    Progress: { SYNC_FINISH: 2 },
    getRdbStore: async (_context, config) => {
      configurations.push(config);
      if (!databases.has(config.customDir)) databases.set(config.customDir, new DatabaseSync(':memory:'));
      const db = databases.get(config.customDir);
      return {
        executeSql: async (sql, params = []) => db.prepare(sql).run(...params),
        querySql: async (sql) => {
          const rows = db.prepare(sql).all().map(Object.values);
          let at = -1;
          return {
            goToFirstRow: () => { at = 0; return at < rows.length; },
            goToNextRow: () => ++at < rows.length,
            getString: (column) => rows[at][column],
            close: () => {}
          };
        },
        setDistributedTables: async (tables, type, options) => {
          assert.deepEqual(tables, ['accountsettings']);
          assert.equal(type, rdb.DistributedType.DISTRIBUTED_CLOUD);
          assert.equal(options.autoSync, false);
        },
        cloudSync: async (mode, tables, progress) => {
          assert.equal(mode, rdb.SyncMode.SYNC_MODE_TIME_FIRST);
          assert.deepEqual(tables, ['accountsettings']);
          progress({ schedule: 1, code: 0 });
          const emptyPayload = db.prepare("SELECT 1 FROM accountsettings WHERE payload = '' LIMIT 1").get();
          if (emptyPayload) throw new Error('Cloud rejects an empty encrypted payload');
          progress({ schedule: rdb.Progress.SYNC_FINISH, code: cloudCode });
        }
      };
    }
  };
  const crypto = { createMd: () => {
    const hash = createHash('sha256');
    return {
      updateSync: ({ data }) => hash.update(data),
      digestSync: () => ({ data: hash.digest() })
    };
  } };
  const util = { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } };
  return {
    ...loadSync(rdb, crypto, util),
    configurations,
    database: () => databases.get(configurations.at(-1).customDir),
    setCloudCode: (code) => { cloudCode = code; }
  };
}

test('migration preserves cloud preferences and removed computers while adding missing settings', async (t) => {
  const { AccountSync, computerSyncRow } = fixture(t);
  const store = await AccountSync.open({}, 'account-one');
  const removed = 'https://192.168.5.2:18981';
  const kept = 'http://127.0.0.1:18977';
  await store.save({ key: 'theme_style', payload: 'iris' });
  await store.save(computerSyncRow(removed, ''));
  const legacy = [
    { key: 'theme_style', payload: 'mint' },
    { key: 'appearance_mode', payload: 'system' },
    computerSyncRow(removed, 'lan'),
    computerSyncRow(kept, 'usb')
  ];
  assert.equal(await store.seed(legacy), true);
  assert.equal(await store.seed(legacy), false);
  assert.deepEqual(await store.read(), {
    computers: [{ address: kept, mode: 'usb' }], theme: 'iris', mode: 'system'
  });
});

test('account databases have distinct local paths and only computer metadata is restored', async (t) => {
  const { AccountSync, computerSyncRow, configurations } = fixture(t);
  const first = await AccountSync.open({}, 'account-one');
  const second = await AccountSync.open({}, 'account-two');
  const row = computerSyncRow('https://192.168.5.2:18981', 'lan');
  assert.deepEqual(JSON.parse(row.payload), { address: 'https://192.168.5.2:18981', mode: 'lan' });
  await first.save({ ...row, payload: JSON.stringify({ ...JSON.parse(row.payload), token: 'ignored' }) });
  await first.save(computerSyncRow('http://127.0.0.1:99999', 'usb'));
  assert.deepEqual((await first.read()).computers, [{ address: 'https://192.168.5.2:18981', mode: 'lan' }]);
  assert.deepEqual((await second.read()).computers, []);
  assert.equal(configurations[0].name, configurations[1].name);
  assert.notEqual(configurations[0].customDir, configurations[1].customDir);
});

test('sync reports the cloud completion status from the progress callback', async (t) => {
  const { AccountSync, setCloudCode } = fixture(t);
  const store = await AccountSync.open({}, 'account-one');
  setCloudCode(3);
  assert.equal(await store.synchronize(), 3);
  setCloudCode(0);
  assert.equal(await store.synchronize(), 0);
});

test('sync uploads new and legacy computer removals and keeps them out of the restored list', async (t) => {
  const { AccountSync, computerSyncRow, database } = fixture(t);
  const store = await AccountSync.open({}, 'account-one');
  const legacy = computerSyncRow('https://192.168.5.2:18981', 'lan');
  const removed = computerSyncRow('http://127.0.0.1:18977', 'usb');
  await store.save(removed);
  await store.save(computerSyncRow('http://127.0.0.1:18977', ''));
  assert.notEqual(database().prepare('SELECT payload FROM accountsettings WHERE recordkey = ?').get(removed.key).payload, '');
  database().prepare("INSERT INTO accountsettings (recordkey, payload) VALUES (?, '')").run(legacy.key);
  await store.save({ key: 'theme_style', payload: 'iris' });

  assert.equal(await store.synchronize(), 0);
  await store.seed([legacy, removed]);
  assert.deepEqual(await store.read(), { computers: [], theme: 'iris', mode: '' });

  await store.save(legacy);
  assert.equal(await store.synchronize(), 0);
  assert.deepEqual((await store.read()).computers, [{ address: 'https://192.168.5.2:18981', mode: 'lan' }]);
});
