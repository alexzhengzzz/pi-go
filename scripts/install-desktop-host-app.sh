#!/bin/zsh
set -euo pipefail
umask 077
project_root="${0:A:h:h}"
source_app="${1:-$project_root/build/desktop-host/mac-arm64/Pi Desktop.app}"
target='/Applications/Pi Desktop.app'
[[ -f "$source_app/Contents/Resources/pi-go-host-enabled" ]] || { print -u2 'Build the Pi Go Desktop host app first'; exit 1; }
if pgrep -f '^/Applications/Pi Desktop.app/Contents/MacOS/Pi Desktop$' >/dev/null; then
  print -u2 'Quit Pi Desktop before installing this update'
  exit 1
fi
codesign --verify --deep --strict "$source_app"
staging="$(mktemp -d /Applications/.pigo-update.XXXXXX)"
ditto "$source_app" "$staging/Pi Desktop.app"
codesign --verify --deep --strict "$staging/Pi Desktop.app"
backup_root="$HOME/Library/Application Support/PiGo/backups"
mkdir -p "$backup_root"
backup="$(mktemp -d "$backup_root/desktop.XXXXXX")"
if [[ -d "$target" ]]; then mv "$target" "$backup/Pi Desktop.app"; fi
if ! mv "$staging/Pi Desktop.app" "$target"; then
  [[ ! -d "$backup/Pi Desktop.app" ]] || mv "$backup/Pi Desktop.app" "$target"
  exit 1
fi
rmdir "$staging"
print -r -- "Installed $target"
print -r -- "Previous app: $backup/Pi Desktop.app"
