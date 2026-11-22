#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app_dir="$project_root/build/Pi Go.app"
node_path="$(command -v node)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/"{desktop,daemon,scripts}
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" "$project_root/macos/PairingApp.swift" -o "$app_dir/Contents/MacOS/PiGoPairing"
cp "$project_root"/desktop/*.mjs "$app_dir/Contents/Resources/desktop/"
cp "$project_root"/daemon/*.mjs "$app_dir/Contents/Resources/daemon/"
cp "$project_root/scripts/run-remote-tunnel.py" "$app_dir/Contents/Resources/scripts/"
print -r -- "$node_path" > "$app_dir/Contents/Resources/node-path"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PiGoPairing</string>
<key>CFBundleIdentifier</key><string>com.alex.pigo.pairing</string>
<key>CFBundleName</key><string>Pi Go</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
print -r -- "$app_dir"
