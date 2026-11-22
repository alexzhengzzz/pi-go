import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { captureWorkspace, describeChanges, referencedArtifacts } from '../host/bridge/run-results.mjs';

test('a review compares against the dirty worktree and accepts only local deliverables', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'pigo-result-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const workspace = join(directory, 'repo');
  mkdirSync(workspace);
  execFileSync('git', ['init', '-q'], { cwd: workspace });
  writeFileSync(join(workspace, '.gitignore'), 'dist/\n');
  writeFileSync(join(workspace, 'edited.txt'), 'index version\n');
  writeFileSync(join(workspace, 'unchanged.txt'), 'index version\n');
  execFileSync('git', ['add', '--', 'edited.txt', 'unchanged.txt'], { cwd: workspace });
  writeFileSync(join(workspace, 'edited.txt'), 'dirty version before the run\n');
  writeFileSync(join(workspace, 'unchanged.txt'), 'pre-existing edit\n');
  const before = captureWorkspace(workspace);

  writeFileSync(join(workspace, 'edited.txt'), 'new version after the run\n');
  mkdirSync(join(workspace, 'dist'));
  writeFileSync(join(workspace, 'dist', 'report.pdf'), 'local artifact');
  writeFileSync(join(directory, 'outside.pdf'), 'other workspace');
  symlinkSync(join(directory, 'outside.pdf'), join(workspace, 'outside.pdf'));

  const result = describeChanges(workspace, before);
  assert.deepEqual(result.files.map(({ path }) => path), ['edited.txt']);
  assert.match(result.patches['edited.txt'], /-dirty version before the run\n\+new version after the run/);
  assert.doesNotMatch(result.patches['edited.txt'], /index version|pre-existing edit/);
  assert.deepEqual(referencedArtifacts(workspace, ['dist/report.pdf', 'outside.pdf', '../outside.pdf',
    'https://example.com/dist/report.pdf']), ['dist/report.pdf']);
});
