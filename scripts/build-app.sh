#!/bin/bash
# リリースビルドして build/Nanodot.app を作る
#
#   ./scripts/build-app.sh             # 直接配布（Developer ID）用。MCP サーバーあり
#   ./scripts/build-app.sh --appstore  # App Store 用。MCP をコンパイルから外し、build/appstore/Nanodot.app に作る
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=(swift build -c release)
APP=build/Nanodot.app
if [ "${1-}" = "--appstore" ]; then
    # Package.swift が NANODOT_APPSTORE=1 を見て APPSTORE を定義する。成果物が混ざらないよう別の場所でビルドする
    export NANODOT_APPSTORE=1
    BUILD+=(--scratch-path .build/appstore)
    APP=build/appstore/Nanodot.app
elif [ $# -gt 0 ]; then
    echo "usage: $0 [--appstore]" >&2
    exit 2
fi
"${BUILD[@]}"
BIN="$("${BUILD[@]}" --show-bin-path)/Nanodot"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nanodot"
swift scripts/make-icon.swift Resources/AppIcon.svg "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Nanodot</string>
    <key>CFBundleDisplayName</key><string>Nanodot</string>
    <key>CFBundleIdentifier</key><string>dev.hashrock.nanodot</string>
    <key>CFBundleExecutable</key><string>Nanodot</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PNG Image</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.png</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
if [ -n "${NANODOT_APPSTORE-}" ]; then
    # MCP の文字列・シンボルが残っていないことを確かめる（memcpy は "mcp" を含むので除く）
    LEFT="$( { strings -a "$APP/Contents/MacOS/Nanodot"; nm "$APP/Contents/MacOS/Nanodot" 2>/dev/null; } | grep -i mcp | grep -vi memcpy || true)"
    if [ -n "$LEFT" ]; then
        echo "error: App Store 用のバイナリに MCP が残っています:" >&2
        echo "$LEFT" | head -20 >&2
        exit 1
    fi
    if otool -L "$APP/Contents/MacOS/Nanodot" | grep -q Network.framework; then
        echo "error: App Store 用のバイナリが Network.framework をリンクしています" >&2
        exit 1
    fi
fi
echo "Built $APP"
