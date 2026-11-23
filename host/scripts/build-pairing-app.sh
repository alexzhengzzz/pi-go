#!/bin/zsh
set -euo pipefail
host_root="${0:A:h:h}"
app_dir="${host_root:h}/build/Pi Go.app"
resources="$app_dir/Contents/Resources"
node_path="$(command -v node)"
mkdir -p "$app_dir/Contents/MacOS" "$resources/"{desktop,daemon,scripts}
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" \
  "$host_root/macos/PairingApp.swift" "$host_root/macos/ScreenCapture.swift" -o "$app_dir/Contents/MacOS/PiGoPairing"
touch "$resources/screen-capture-v1"
cp "$host_root/macos/AppIcon.icns" "$resources/AppIcon.icns"
cp "$host_root"/bridge/*.mjs "$resources/desktop/"
cp "$host_root"/daemon/*.mjs "$resources/daemon/"
cp "$host_root/scripts/run-remote-tunnel.py" "$resources/scripts/"
# Existing LaunchAgents use Resources/desktop, while daemon imports use ../bridge.
ln -sfn desktop "$resources/bridge"
print -r -- "$node_path" > "$resources/node-path"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PiGoPairing</string>
<key>CFBundleIdentifier</key><string>com.alex.pigo.pairing</string>
<key>CFBundleName</key><string>Pi Go</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
print -r -- "$app_dir"
