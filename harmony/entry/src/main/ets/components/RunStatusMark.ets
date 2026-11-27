import { headerSymbol } from './HeaderSymbol';

export function runStatusInk(status: string, accent: string): ResourceColor {
  if (status === 'failed') return $r('app.color.pigo_error');
  if (status === 'waiting') return $r('app.color.pigo_warning');
  if (status === 'stopped') return $r('app.color.pigo_muted');
  return accent;
}

function statusIcon(status: string): Resource {
  if (status === 'failed') return $r('sys.symbol.exclamationmark_circle');
  if (status === 'alert') return $r('sys.symbol.bell');
  if (status === 'waiting' || status === 'stopped') return $r('sys.symbol.clock');
  return $r('sys.symbol.checkmark_circle');
}

@Builder
export function runStatusMark(status: string, accent: string, tint: string, size: number) {
  Stack() {
    headerSymbol(statusIcon(status), runStatusInk(status, accent), size * 0.52)
  }.width(size).height(size).borderRadius(size * 0.3)
    .backgroundColor(status === 'waiting' ? $r('app.color.pigo_warning_panel') :
      status === 'failed' ? $r('app.color.pigo_error_panel') : tint)
}
