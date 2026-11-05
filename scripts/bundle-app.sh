#!/bin/zsh
# Builds Thermal.app into build/ from the SwiftPM product.
#
#   scripts/bundle-app.sh            release build, signed for this Mac
#   scripts/bundle-app.sh --run      …and (re)launch it
#
# Signing: uses the first valid "Apple Development" identity if there is one, otherwise
# ad-hoc ("-"), which is enough for the read-only M2 app on this Mac. The M3 helper will
# need the real identity.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=0.2.0
APP=build/Thermal.app

swift build -c release --product ThermalApp
BIN=$(swift build -c release --product ThermalApp --show-bin-path)/ThermalApp

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Thermal

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.streller.thermal</string>
    <key>CFBundleName</key><string>Thermal</string>
    <key>CFBundleDisplayName</key><string>Thermal</string>
    <key>CFBundleExecutable</key><string>Thermal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal use</string>
</dict>
</plist>
EOF

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --options runtime --timestamp=none --sign "${IDENTITY:--}" $APP
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ ${1:-} == --run ]]; then
  pkill -x Thermal 2>/dev/null && sleep 1 || true
  open $APP
  echo "Launched."
fi
