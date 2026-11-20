#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
checkout="${1:?Pass a Pi Desktop v0.2.2-alpha source checkout with dependencies installed}"
zsh "$project_root/scripts/prepare-desktop-host.sh" "$checkout"
(cd "$checkout" && npm run typecheck && npm run build)
CSC_IDENTITY_AUTO_DISCOVERY=false node "$checkout/node_modules/electron-builder/cli.js" --mac --dir --projectDir "$checkout" \
  -c.electronDist="$checkout/node_modules/electron/dist" \
  -c.directories.output="$project_root/build/desktop-host" -c.npmRebuild=false -c.mac.icon="$checkout/resources/icons/icon.icns"
app_dir="$project_root/build/desktop-host/mac-arm64/Pi Desktop.app"
[[ -d "$app_dir" ]] || { print -u2 'The packaged macOS app was not produced'; exit 1; }
# Enable only this purpose-built Desktop, without requiring launch environment variables.
print -r -- 'pi-go-desktop-host/1' > "$app_dir/Contents/Resources/pi-go-host-enabled"
codesign --force --deep --sign - --preserve-metadata=entitlements,flags "$app_dir"
codesign --verify --deep --strict "$app_dir"
print -r -- "$app_dir"
