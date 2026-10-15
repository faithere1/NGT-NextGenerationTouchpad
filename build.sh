#!/bin/sh
# Builds NGT.app next to this script.
set -e
cd "$(dirname "$0")"

APP=NGT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

clang -O2 -fobjc-arc -framework Cocoa -framework ApplicationServices -framework Carbon \
      -o "$APP/Contents/MacOS/NGT" ngt.m

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ngt.touchpad</string>
  <key>CFBundleName</key><string>NGT</string>
  <key>CFBundleExecutable</key><string>NGT</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict></plist>
EOF

xattr -cr "$APP"
codesign --force -s - "$APP"

# Each rebuild gets a new ad-hoc signature, which silently invalidates the old
# Accessibility grant (toggling it in Settings doesn't help). Clear it so macOS
# prompts again on next launch.
tccutil reset Accessibility com.ngt.touchpad >/dev/null 2>&1 || true
echo "Built $APP — run: open $APP"
