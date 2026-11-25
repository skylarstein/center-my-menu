#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Deliberately do not source .env or copy the project directory into the bundle.
case "${CONFIGURATION:-release}" in
    release|Release) APP_CONFIGURATION=Release ;;
    debug|Debug) APP_CONFIGURATION=Debug ;;
    *) echo "CONFIGURATION must be release or debug" >&2; exit 64 ;;
esac
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "Missing Resources/AppIcon.icns; preserve the supplied icon asset." >&2
    exit 1
fi

# Use the same project, packaging, ad-hoc signing, and product paths as Xcode.
# Disable the SDK stat cache to avoid clang-stat-cache hanging on cache validation.
xcodebuild -project "$ROOT/CenterMyMenu.xcodeproj" \
    -scheme CenterMyMenu -configuration "$APP_CONFIGURATION" \
    -derivedDataPath "$ROOT/build/xcode/DerivedData" SDK_STAT_CACHE_ENABLE=NO build
APP_NAME="Center My Menu"
if [[ "$APP_CONFIGURATION" == Debug ]]; then APP_NAME="Center My Menu (Debug)"; fi
APP="$ROOT/build/xcode/$APP_CONFIGURATION/$APP_NAME.app"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
/usr/bin/codesign --verify --strict "$APP"
printf 'Built: %s\n' "$APP"
