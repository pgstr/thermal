#!/bin/zsh
# Builds Thermal.app (app + privileged fan helper) into build/ from the SwiftPM products.
#
#   scripts/bundle-app.sh              build and sign build/Thermal.app
#   scripts/bundle-app.sh --run        …and (re)launch it from build/
#   scripts/bundle-app.sh --install    …copy to /Applications/Thermal.app and launch from there
#                                      (use this for fan control: the helper registration
#                                      remembers where the app lives)
#
# Signing: the first valid "Apple Development" identity. Without one the app is signed ad-hoc;
# monitoring works, but the helper refuses ad-hoc callers, so fan control will not.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=0.3.0
APP=build/Thermal.app
HELPER_ID=dev.streller.thermal.fanhelper

swift build -c release --product ThermalApp
swift build -c release --product ThermalFanHelper
BIN_DIR=$(swift build -c release --show-bin-path)

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Library/LaunchDaemons
cp $BIN_DIR/ThermalApp $APP/Contents/MacOS/Thermal
cp $BIN_DIR/ThermalFanHelper $APP/Contents/MacOS/ThermalFanHelper
cp Resources/$HELPER_ID.plist $APP/Contents/Library/LaunchDaemons/

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
if [[ -z $IDENTITY ]]; then
  echo "WARNING: no valid Apple Development identity; signing ad-hoc. Fan control will NOT work." >&2
fi
SIGN=(codesign --force --options runtime --timestamp=none --sign "${IDENTITY:--}")
# Inner code first, then the app.
$SIGN[@] --identifier $HELPER_ID $APP/Contents/MacOS/ThermalFanHelper
$SIGN[@] $APP
codesign --verify --strict --deep $APP
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

case ${1:-} in
  --run)
    pkill -x Thermal 2>/dev/null && sleep 1 || true
    open $APP
    echo "Launched from build/."
    ;;
  --install)
    pkill -x Thermal 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Thermal.app
    ditto $APP /Applications/Thermal.app
    open /Applications/Thermal.app
    echo "Installed to /Applications/Thermal.app and launched."
    ;;
esac
