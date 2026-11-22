@Builder
export function headerSymbol(symbol: Resource, color: ResourceColor, size: number) {
  SymbolGlyph(symbol).fontSize(size).fontColor([color]).accessibilityLevel('no')
}
