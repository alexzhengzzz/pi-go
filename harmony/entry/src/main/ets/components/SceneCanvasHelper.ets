import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';

export interface DecodedSceneBitmap {
  pixelMap: image.PixelMap;
  width: number;
  height: number;
}

export async function decodeRawSceneBitmap(
  context: common.Context,
  rawfileName: string,
  compact: boolean = false,
  fallbackWidth: number = 768,
  fallbackHeight: number = 1376
): Promise<DecodedSceneBitmap | undefined> {
  let source: image.ImageSource | undefined;
  try {
    const bytes = await context.resourceManager.getRawFileContent(rawfileName);
    const buffer: ArrayBuffer = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength
      ? bytes.buffer as ArrayBuffer
      : bytes.slice().buffer as ArrayBuffer;
    source = image.createImageSource(buffer);
    let options: image.DecodingOptions | undefined;
    if (compact) {
      try {
        const info = await source.getImageInfo();
        const maxEdge = 540;
        const scale = Math.min(1, maxEdge / Math.max(info.size.width, info.size.height, 1));
        if (scale < 0.95) {
          options = {
            desiredSize: {
              width: Math.max(1, Math.round(info.size.width * scale)),
              height: Math.max(1, Math.round(info.size.height * scale))
            }
          };
        }
      } catch { /* Fall back to native size if metadata read fails. */ }
    }
    const pixelMap = options ? await source.createPixelMap(options) : await source.createPixelMap();
    let width = fallbackWidth;
    let height = fallbackHeight;
    try {
      const info = await pixelMap.getImageInfo();
      width = info.size.width;
      height = info.size.height;
    } catch { /* Keep fallback dimensions. */ }
    return { pixelMap, width, height };
  } catch {
    return undefined;
  } finally {
    if (source) {
      try { await source.release(); } catch { /* Ignore release failure. */ }
    }
  }
}
