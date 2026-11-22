import { readdirSync, readFileSync } from 'node:fs';

// The Index page is split across pages/Index.ets, model/*.ets and components/*.ets.
// Source-level tests read the page as one text so checks keep working when code
// moves between those files.
const root = new URL('../harmony/entry/src/main/ets/', import.meta.url);

export function harmonyFile(path) {
  return readFileSync(new URL(path, root), 'utf8');
}

function directory(name) {
  try {
    return readdirSync(new URL(`${name}/`, root)).filter((file) => file.endsWith('.ets')).sort()
      .map((file) => harmonyFile(`${name}/${file}`));
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

export function pageSource() {
  return [harmonyFile('pages/Index.ets'), ...directory('model'), ...directory('components')].join('\n');
}
