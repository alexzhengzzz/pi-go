interface ContentBlock {
  kind: string;
  text: string;
  language: string;
}

// Parse only presentation syntax. Message contents never become executable HTML.
function contentBlocks(source: string): ContentBlock[] {
  const blocks: ContentBlock[] = [];
  let paragraph: string[] = [];
  let code: boolean = false;
  let language: string = '';
  source.split('\n').forEach((line: string) => {
    if (line.trim().startsWith('```')) {
      if (paragraph.length) blocks.push({ kind: code ? 'code' : 'paragraph', text: paragraph.join('\n'), language: language });
      paragraph = [];
      code = !code;
      language = code ? line.trim().slice(3).trim() : '';
    } else if (code) paragraph.push(line);
    else if (!line.trim()) {
      if (paragraph.length) blocks.push({ kind: 'paragraph', text: paragraph.join('\n'), language: '' });
      paragraph = [];
    } else if (/^#{1,6}\s/.test(line)) {
      if (paragraph.length) blocks.push({ kind: 'paragraph', text: paragraph.join('\n'), language: '' });
      paragraph = [];
      blocks.push({ kind: 'heading', text: line.replace(/^#{1,6}\s+/, ''), language: '' });
    } else paragraph.push(line.replace(/^\s*[-*]\s+/, '• '));
  });
  if (paragraph.length) blocks.push({ kind: code ? 'code' : 'paragraph', text: paragraph.join('\n'), language: language });
  return blocks;
}

@Component
export struct ChatContent {
  @Prop text: string = '';
  @Prop accent: string = '#9EE2CE';

  @Builder
  inlineText(value: string, heading: boolean) {
    Text() {
      ForEach(value.split(/(\*\*[^*]+\*\*|`[^`]+`)/g), (part: string) => {
        if (part.startsWith('**') && part.endsWith('**')) {
          Span(part.slice(2, -2)).fontWeight(FontWeight.Bold)
        } else if (part.startsWith('`') && part.endsWith('`')) {
          Span(part.slice(1, -1)).fontFamily('monospace').fontSize(15)
            .textBackgroundStyle({ color: $r('app.color.pigo_control'), radius: 4 })
        } else {
          Span(part)
        }
      }, (part: string, index: number) => `${index}-${part}`)
    }.fontSize(heading ? 19 : 16).fontWeight(heading ? FontWeight.Bold : FontWeight.Normal)
      .fontColor($r('app.color.pigo_text')).lineHeight(27).copyOption(CopyOptions.LocalDevice).width('100%')
  }

  build() {
    Column({ space: 12 }) {
      ForEach(contentBlocks(this.text), (block: ContentBlock) => {
        if (block.kind === 'code') {
          Column({ space: 8 }) {
            if (block.language) Text(block.language).fontSize(11).fontColor(this.accent)
            Text(block.text).fontSize(14).fontFamily('monospace').lineHeight(22).fontColor($r('app.color.pigo_text'))
              .copyOption(CopyOptions.LocalDevice).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%').padding(12).backgroundColor($r('app.color.pigo_panel')).borderRadius(12)
            .border({ width: 1, color: $r('app.color.pigo_line') })
        } else {
          this.inlineText(block.text, block.kind === 'heading')
        }
      }, (block: ContentBlock, index: number) => `${index}-${block.kind}-${block.text}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
