#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Center My Menu Test Host.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .local/module-cache
install -m 644 LICENSE "$APP/Contents/Resources/LICENSE"
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path "$PWD/.local/module-cache" Tools/TestHost.swift -o "$APP/Contents/MacOS/CenterMyMenuTestHost"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.skylarstein.centermymenu.testhost</string>
<key>CFBundleName</key><string>Center My Menu Test Host</string>
<key>CFBundleExecutable</key><string>CenterMyMenuTestHost</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
