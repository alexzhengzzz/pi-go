#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
checkout="${1:?Pass a dedicated Pi Desktop v0.2.2-alpha source checkout}"
revision=74d9623c218e69469fd61207c5955e247ad8356b
patch="$root/desktop/pi-desktop-v0.2.2-alpha.patch"
[[ "$(git -C "$checkout" rev-parse HEAD)" == "$revision" ]] || { print -u2 'Incompatible Pi Desktop checkout'; exit 1; }
if git -C "$checkout" apply --check "$patch" 2>/dev/null; then
  git -C "$checkout" apply "$patch"
elif ! git -C "$checkout" apply --reverse --check "$patch"; then
  print -u2 'Cannot apply the Pi Go Desktop adapter to this checkout'
  exit 1
fi
[[ ! -L "$checkout/src/main/pi-go-host.ts" ]] || { print -u2 'Refusing to overwrite a symlink'; exit 1; }
cp "$root/desktop/pi-go-host.ts" "$checkout/src/main/pi-go-host.ts"
