import { fileIo, picker } from '@kit.CoreFileKit';

export interface PromptFile {
  name: string;
  size: number;
  bytes: Uint8Array;
}

export const MAX_FILE_BYTES = 8 * 1024 * 1024;
export const MAX_FILES = 3;

function safeName(name: string): string {
  return name.replace(/[\\/\u0000-\u001f\u007f]/g, '').replace(/^\.+/, '').trim().replace(/\s+/g, ' ').slice(0, 80);
}

function nameFromUri(uri: string): string {
  const raw = uri.split('?')[0].split('/').pop() ?? '';
  let decoded = raw;
  try { decoded = decodeURIComponent(raw); } catch { decoded = raw; }
  return safeName(decoded);
}

// Pick up to `max` arbitrary documents and read their bytes locally, so the
// draft keeps them until the send pipeline uploads them to the bridge.
export async function choosePromptFiles(max: number): Promise<PromptFile[]> {
  const options = new picker.DocumentSelectOptions();
  options.selectMode = picker.DocumentSelectMode.FILE;
  options.maxSelectNumber = Math.max(1, Math.min(max, MAX_FILES));
  const uris = await new picker.DocumentViewPicker().select(options);
  const files: PromptFile[] = [];
  for (const uri of uris) {
    if (nameFromUri(uri)) files.push(await loadPromptFile(uri));
  }
  return files;
}

export async function loadPromptFile(uri: string, title: string = ''): Promise<PromptFile> {
  const name = safeName(title) || nameFromUri(uri) || 'shared.txt';
  const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const size = (await fileIo.stat(file.fd)).size;
    if (size <= 0 || size > MAX_FILE_BYTES) throw new Error('file_limit');
    const buffer = new ArrayBuffer(size);
    if (fileIo.readSync(file.fd, buffer) !== size) throw new Error('file_limit');
    return { name: name, size: size, bytes: new Uint8Array(buffer) };
  } finally {
    await fileIo.close(file).catch((): void => {});
  }
}
