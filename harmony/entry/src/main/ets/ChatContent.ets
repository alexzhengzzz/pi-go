import { ChatImage } from './ChatImage';

const TABLE_COLUMN_WIDTH = 144;

interface ContentBlock {
  kind: string;
  text: string;
  level?: number;
  language?: string;
  target?: string;
  rows?: string[][];
}

interface InlinePart {
  kind: string;
  text: string;
  target?: string;
}

// Shared destinations for links and images, including quoted titles and paths with spaces in angle brackets.
const DESTINATION = /!?\[([^\[\]\n]*)\]\(\s*(?:<([^>\n]+)>|((?:[^()\s]|\([^()\n]*\))+))(?:\s+["'][^\n]*?["'])?\s*\)/;
const INLINE = new RegExp('\\\\[\\\\`*_~!\\[\\]#|>+.-]|(`+)([^\\n]+?)\\1(?!`)|' +
  DESTINATION.source + '|\\*\\*([^*\\n]+)\\*\\*|__([^_\\n]+)__|~~([^~\\n]+)~~|\\*([^*\\n]+)\\*|\\b_([^_\\n]+)_\\b', 'g');

function inlineParts(value: string): InlinePart[] {
  const parts: InlinePart[] = [];
  const matcher = new RegExp(INLINE.source, 'g');
  let cursor = 0;
  let match = matcher.exec(value);
  while (match) {
    if (match.index > cursor) parts.push({ kind: 'text', text: value.slice(cursor, match.index) });
    if (match[0].startsWith('\\')) parts.push({ kind: 'text', text: match[0].slice(1) });
    else if (match[1]) parts.push({ kind: 'code', text: match[2] });
    else if (match[4] || match[5]) {
      parts.push({ kind: match[0].startsWith('!') ? 'image' : 'link', text: match[3], target: match[4] ?? match[5] });
    } else if (match[6] || match[7]) parts.push({ kind: 'bold', text: match[6] ?? match[7] });
    else if (match[8]) parts.push({ kind: 'strike', text: match[8] });
    else parts.push({ kind: 'italic', text: match[9] ?? match[10] });
    cursor = matcher.lastIndex;
    match = matcher.exec(value);
  }
  if (cursor < value.length) parts.push({ kind: 'text', text: value.slice(cursor) });
  return parts;
}

function tableCells(line: string): string[] {
  return line.trim().replace(/^\|/, '').replace(/(?<!\\)\|$/, '').split(/(?<!\\)\|/)
    .map((cell: string): string => cell.trim());
}

function appendParagraph(blocks: ContentBlock[], text: string): void {
  if (!text) return;
  // Keep inline code and escaped image syntax literal.
  const matcher = new RegExp(INLINE.source, 'g');
  let cursor = 0;
  let match = matcher.exec(text);
  while (match) {
    if (match[0].startsWith('![') && (match[4] || match[5])) {
      if (match.index > cursor && text.slice(cursor, match.index).trim()) {
        blocks.push({ kind: 'paragraph', text: text.slice(cursor, match.index).trimEnd() });
      }
      blocks.push({ kind: 'image', text: match[3] || '图片', target: match[4] ?? match[5] });
      cursor = matcher.lastIndex;
    }
    match = matcher.exec(text);
  }
  if (text.slice(cursor).trim()) blocks.push({ kind: 'paragraph', text: cursor ? text.slice(cursor).trimStart() : text });
}

// Parse presentation syntax into native ArkUI views. HTML remains plain text.
function contentBlocks(source: string): ContentBlock[] {
  const blocks: ContentBlock[] = [];
  const lines = source.replace(/\r\n?/g, '\n').split('\n');
  let paragraph: string[] = [];
  let fence = '';
  let language = '';
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (fence) {
      const close = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line);
      if (close && close[1][0] === fence[0] && close[1].length >= fence.length) {
        blocks.push({ kind: 'code', text: paragraph.join('\n'), language: language });
        paragraph = [];
        fence = '';
      } else paragraph.push(line);
      continue;
    }
    const start = /^ {0,3}(`{3,}|~{3,})\s*([^\s`~]*).*$/.exec(line);
    const heading = /^ {0,3}(#{1,6})[ \t]+(.+)$/.exec(line);
    const quote = /^ {0,3}>\s?(.*)$/.exec(line);
    const divider = /^ {0,3}(?:(?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,})$/.test(line);
    const header = line.includes('|') ? tableCells(line) : [];
    const separator = header.length > 1 && index + 1 < lines.length ? tableCells(lines[index + 1]) : [];
    const table = separator.length === header.length && header.length > 1 &&
      separator.every((cell: string): boolean => /^:?-{3,}:?$/.test(cell));
    if (start || heading || quote || divider || table || !line.trim()) {
      appendParagraph(blocks, paragraph.join('\n'));
      paragraph = [];
      if (start) {
        fence = start[1];
        language = start[2];
      } else if (heading) blocks.push({
        kind: 'heading',
        level: heading[1].length,
        text: heading[2].replace(/[ \t]+#+[ \t]*$/, '').trimEnd()
      });
      else if (quote) {
        const quoted = [quote[1]];
        while (index + 1 < lines.length) {
          const next = /^ {0,3}>\s?(.*)$/.exec(lines[index + 1]);
          if (!next) break;
          quoted.push(next[1]);
          index++;
        }
        blocks.push({ kind: 'quote', text: quoted.join('\n') });
      } else if (divider) blocks.push({ kind: 'divider', text: '' });
      else if (table) {
        const tableStart = index;
        const rows = [header];
        index++;
        while (index + 1 < lines.length && lines[index + 1].includes('|')) {
          const cells = tableCells(lines[index + 1]);
          if (cells.length !== header.length) break;
          rows.push(cells);
          index++;
        }
        blocks.push({ kind: 'table', text: lines.slice(tableStart, index + 1).join('\n'), rows: rows });
      }
      continue;
    }
    paragraph.push(line.replace(/^(\s*)[-*+]\s+\[([ xX])\]\s+/, (_match: string, indent: string, checked: string): string =>
      `${indent}${checked === ' ' ? '☐' : '☑'} `).replace(/^(\s*)[-*+]\s+/, '$1• '));
  }
  if (fence) blocks.push({ kind: 'code', text: paragraph.join('\n'), language: language });
  else appendParagraph(blocks, paragraph.join('\n'));
  return blocks;
}

@Component
export struct ChatContent {
  @Prop text: string = '';
  @Prop accent: string = '#9EE2CE';
  @Prop codeBg: string = '';
  @Prop codeBorder: string = '';
  @Prop codeHeaderBg: string = '';
  @Prop codeRadius: number = 12;
  @Prop allowLandscape: boolean = false;
  @State private contentWidth: number = 0;
  loadImage: (target: string) => Promise<string> = async (): Promise<string> => '';
  openImage: (source: string, label: string) => void = () => {};
  openLink: (target: string) => void = () => {};
  openLandscape: (source: string) => void = () => {};
  copyCode?: (value: string) => void;

  @Builder
  inlineText(value: string, heading: boolean, tableCell: boolean = false, headingLevel: number = 0) {
    Text() {
      ForEach(inlineParts(value), (part: InlinePart) => {
        if (part.kind === 'code') {
          Span(part.text).fontFamily('monospace').fontSize(14)
            .textBackgroundStyle({ color: $r('app.color.pigo_control'), radius: 4 })
        } else if (part.kind === 'link' || part.kind === 'image') {
          Span(part.text || part.target || '').fontColor(this.accent).decoration({ type: TextDecorationType.Underline })
            .onClick(() => { if (part.target) this.openLink(part.target); })
        } else {
          Span(part.text).fontWeight(heading || part.kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(part.kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
            .decoration({ type: part.kind === 'strike' ? TextDecorationType.LineThrough : TextDecorationType.None })
        }
      }, (part: InlinePart, index: number) => `${index}-${part.kind}-${part.text}-${part.target ?? ''}`)
    }.fontSize(heading ? (headingLevel === 1 ? 21 : headingLevel === 2 ? 19 : 17) : 16)
      .fontColor($r('app.color.pigo_text'))
      .lineHeight(heading ? (headingLevel === 1 ? 29 : headingLevel === 2 ? 27 : 25) : 27)
      .wordBreak(tableCell ? WordBreak.BREAK_ALL : WordBreak.BREAK_WORD).copyOption(CopyOptions.LocalDevice).width('100%')
  }

  @Builder
  table(rows: string[][], source: string) {
    Column({ space: 6 }) {
      if (this.allowLandscape && this.contentWidth > 0 && rows[0].length * TABLE_COLUMN_WIDTH > this.contentWidth) {
        Row() {
          Button('横屏查看', { type: ButtonType.Normal }).fontSize(13).height(34).borderRadius(8)
            .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
            .onClick(() => { this.openLandscape(source); })
        }.width('100%').justifyContent(FlexAlign.End)
      }
      Scroll() {
        Column() {
          ForEach(rows, (row: string[], rowIndex: number) => {
            Row() {
              ForEach(row, (cell: string) => {
                Column() {
                  this.inlineText(cell, rowIndex === 0, true)
                }.width(TABLE_COLUMN_WIDTH).flexShrink(0).padding({ left: 8, right: 8, top: 4, bottom: 4 })
              }, (cell: string, index: number) => `${index}-${cell}`)
            }.width('100%').backgroundColor(rowIndex === 0 ? $r('app.color.pigo_control') : $r('app.color.pigo_panel'))
              .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
          }, (row: string[], index: number) => `${index}-${JSON.stringify(row)}`)
        }.width(rows[0].length * TABLE_COLUMN_WIDTH).alignItems(HorizontalAlign.Start)
          .padding({ bottom: 6 })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.On).width('100%').align(Alignment.TopStart)
    }.width('100%')
  }

  build() {
    Column({ space: 12 }) {
      ForEach(contentBlocks(this.text), (block: ContentBlock) => {
        if (block.kind === 'code') {
          Column() {
            if (block.language || this.copyCode) {
              Row() {
                Text(block.language || '代码').fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(block.language ? this.accent : $r('app.color.pigo_muted')).layoutWeight(1)
                if (this.copyCode && block.text) {
                  Button({ type: ButtonType.Normal }) {
                    SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(15)
                      .fontColor([$r('app.color.pigo_muted')])
                  }.width(30).height(28).padding(0).borderRadius(7).backgroundColor(Color.Transparent)
                    .accessibilityText('复制代码')
                    .onClick(() => { this.copyCode?.(block.text); })
                }
              }.width('100%').padding({ left: 12, right: 8, top: 6, bottom: 6 })
                .backgroundColor(this.codeHeaderBg || $r('app.color.pigo_control'))
                .border({ width: { bottom: 0.5 }, color: this.codeBorder || $r('app.color.pigo_line') })
            }
            Text(block.text).fontSize(14).fontFamily('monospace').lineHeight(22).fontColor($r('app.color.pigo_text'))
              .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice).width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 12 })
          }.alignItems(HorizontalAlign.Start).width('100%').clip(true)
            .backgroundColor(this.codeBg || $r('app.color.pigo_panel')).borderRadius(this.codeRadius)
            .border({ width: 1, radius: this.codeRadius, color: this.codeBorder || $r('app.color.pigo_line') })
        } else if (block.kind === 'image' && block.target) {
          ChatImage({
            label: block.text,
            remoteUrl: /^https?:\/\/[^\s]+$/i.test(block.target) ? block.target : '',
            load: (): Promise<string> => this.loadImage(block.target ?? ''),
            open: (source: string, label: string) => { this.openImage(source, label); }
          })
        } else if (block.kind === 'table' && block.rows) {
          this.table(block.rows, block.text)
        } else if (block.kind === 'divider') {
          Divider().color($r('app.color.pigo_line'))
        } else if (block.kind === 'quote') {
          Column() {
            this.inlineText(block.text, false)
          }.padding({ left: 12 }).width('100%')
            .border({ width: { left: 3 }, color: this.accent })
        } else {
          this.inlineText(block.text, block.kind === 'heading', false, block.level ?? 2)
        }
      }, (block: ContentBlock, index: number) =>
        `${index}-${block.kind}-${block.level ?? 0}-${block.text}-${block.language ?? ''}-${block.target ?? ''}`)
    }.width('100%').alignItems(HorizontalAlign.Start).onAreaChange((_: Area, area: Area) => {
      this.contentWidth = Number(area.width);
    })
  }
}
