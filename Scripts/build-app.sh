#!/bin/zsh
# Builds AetherFeed.app without Xcode: SPM build + manual app bundle + ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

# Xcode installed but license not accepted? Then use the Command Line Tools.
if ! swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

CONFIG="${1:-release}"
# The default SwiftPM build system (swiftbuild) stamps the deployment target
# as the SDK version into LC_BUILD_VERSION (sdk 15.0). AppKit keys its
# appearance on that stamp, so the app would run in the pre-macOS-26
# compatibility look (no Liquid Glass) despite being built against a newer
# SDK. Restate the platform version with the real SDK version.
SDK_VERSION="$(xcrun --show-sdk-version)"
swift build -c "$CONFIG" \
  -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$SDK_VERSION"

APP="build/AetherFeed.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/AetherFeed" "$APP/Contents/MacOS/AetherFeed"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Empty .lproj folders: macOS detects the supported languages from these, so
# system menus (File/Ablage …) follow the language set via AppleLanguages.
for lang in de en it fr es; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
done
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi
codesign --force --sign - "$APP"
echo "OK: $APP  →  open $APP"
