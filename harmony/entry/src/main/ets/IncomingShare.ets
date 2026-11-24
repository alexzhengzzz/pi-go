import type { Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { loadPromptImage } from './PromptImage';
import { loadPromptFile } from './PromptFile';
import type { DraftAttachment } from './model/PiGoTypes';
import { MAX_IMAGE_ATTACHMENTS } from './model/PiGoConstants';

export const MAX_SHARED_DRAFT_BYTES = 12000;

export interface IncomingShare {
  text: string;
  attachments: DraftAttachment[];
  skipped: boolean;
}

export function sharedDraftSize(text: string): number {
  return new util.TextEncoder().encodeInto(text).byteLength;
}

export function releaseIncomingShare(share?: IncomingShare): void {
  for (const item of share?.attachments ?? []) {
    void item.image?.preview.release().catch((): void => {});
  }
}

export async function readIncomingShare(want: Want, ownBundle: string): Promise<IncomingShare> {
  const share: IncomingShare = { text: '', attachments: [], skipped: false };
  const data = await systemShare.getSharedData(want);
  let images = 0;
  let textFiles = 0;
  for (const record of data.getRecords()) {
    try {
      const type = utd.getTypeDescriptor(record.utd);
      const isImage = record.utd === utd.UniformDataType.IMAGE || type.belongsTo(utd.UniformDataType.IMAGE);
      const isText = record.utd === utd.UniformDataType.TEXT || type.belongsTo(utd.UniformDataType.TEXT);
      const isLink = record.utd === utd.UniformDataType.HYPERLINK;
      if (record.content && (isText || isLink)) {
        const text = [share.text, record.content.trim()].filter((value: string): boolean => !!value).join('\n\n');
        if (sharedDraftSize(text) <= MAX_SHARED_DRAFT_BYTES) share.text = text;
        else share.skipped = true;
        continue;
      }
      // Only open system file URIs owned by a different app or a system provider.
      const uri = record.uri ?? '';
      const authority = /^file:\/\/([a-zA-Z0-9_.-]+)\/(?!\/)/.exec(uri)?.[1];
      if (!authority || authority.toLowerCase() === ownBundle.toLowerCase()) {
        share.skipped = true;
      } else if (isImage && images < MAX_IMAGE_ATTACHMENTS) {
        const image = await loadPromptImage(uri);
        share.attachments.push({ kind: 'image', name: 'photo.jpg', size: image.jpeg.length, image: image });
        images += 1;
      } else if (isText && textFiles < 1) {
        const file = await loadPromptFile(uri, record.title);
        share.attachments.push({ kind: 'file', name: file.name, size: file.size, file: file });
        textFiles += 1;
      } else {
        share.skipped = true;
      }
    } catch { share.skipped = true; }
  }
  return share;
}
