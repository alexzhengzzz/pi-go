import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { camera, cameraPicker } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';

export interface PromptImage {
  jpeg: string;
  width: number;
  height: number;
  preview: image.PixelMap;
}

const JPEG_LIMIT = 512 * 1024;

// WeChat-style pipeline: pick or shoot, downsample to at most 1280px, pack a
// JPEG within the bridge limit, and keep a small thumbnail for the draft row.
export async function loadPromptImage(uri: string): Promise<PromptImage> {
  const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  let source: image.ImageSource | undefined;
  let pixels: image.PixelMap | undefined;
  let packer: image.ImagePacker | undefined;
  let previewSource: image.ImageSource | undefined;
  try {
    const size = (await fileIo.stat(file.fd)).size;
    if (size <= 0 || size > 32 * 1024 * 1024) throw new Error('source_limit');
    source = image.createImageSource(file.fd);
    const original = (await source.getImageInfo(0)).size;
    if (!original.width || !original.height || original.width * original.height > 48_000_000) throw new Error('dimensions_limit');
    const ratio = Math.min(1, 1280 / Math.max(original.width, original.height));
    const width = Math.max(1, Math.floor(original.width * ratio));
    const height = Math.max(1, Math.floor(original.height * ratio));
    pixels = await source.createPixelMap({ desiredSize: { width: width, height: height }, index: 0 });
    const normalized = (await pixels.getImageInfo()).size;
    if (normalized.width > 1280 || normalized.height > 1280) throw new Error('dimensions_limit');
    packer = image.createImagePacker();
    for (const quality of [82, 65, 45]) {
      const bytes = await packer.packToData(pixels, { format: 'image/jpeg', quality: quality, needsPackProperties: false });
      if (bytes.byteLength > 0 && bytes.byteLength <= JPEG_LIMIT) {
        previewSource = image.createImageSource(bytes);
        const previewRatio = Math.min(1, 128 / Math.max(normalized.width, normalized.height));
        const preview = await previewSource.createPixelMap({
          desiredSize: {
            width: Math.max(1, Math.round(normalized.width * previewRatio)),
            height: Math.max(1, Math.round(normalized.height * previewRatio))
          }, index: 0
        });
        return {
          jpeg: new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes)),
          width: normalized.width, height: normalized.height, preview: preview
        };
      }
    }
    throw new Error('image_limit');
  } finally {
    if (previewSource) await previewSource.release().catch((): void => {});
    if (packer) await packer.release().catch((): void => {});
    if (pixels) await pixels.release().catch((): void => {});
    if (source) await source.release().catch((): void => {});
    await fileIo.close(file).catch((): void => {});
  }
}

export async function choosePromptImage(max: number): Promise<PromptImage[]> {
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = Math.max(1, Math.min(max, 4));
  const result = await new photoAccessHelper.PhotoViewPicker().select(options);
  const images: PromptImage[] = [];
  for (const uri of result.photoUris) {
    const loaded = await loadPromptImage(uri);
    if (loaded) images.push(loaded);
  }
  return images;
}

export async function capturePromptImage(context: common.Context): Promise<PromptImage | undefined> {
  const profile: cameraPicker.PickerProfile = { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK };
  const result = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], profile);
  if (!result || result.resultCode !== 0 || !result.resultUri) return undefined;
  return await loadPromptImage(result.resultUri);
}
