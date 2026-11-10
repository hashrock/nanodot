#!/bin/bash
# リリースビルドして build/Nanodot.app を作る
#
#   ./scripts/build-app.sh             # 直接配布（Developer ID）用。MCP サーバーあり
#   ./scripts/build-app.sh --appstore  # App Store 用。MCP をコンパイルから外し、build/appstore/Nanodot.app に作る
#
# App Store 用は arm64 + x86_64 のユニバーサルで、App Sandbox を付けて ad-hoc 署名する（手元で Sandbox 下の動作を確かめるため）。
# 提出用の署名と .pkg 化は scripts/appstore.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=(swift build -c release)
APP=build/Nanodot.app
APPSTORE=
if [ "${1-}" = "--appstore" ]; then
    # Package.swift が NANODOT_APPSTORE=1 を見て APPSTORE を定義する。成果物が混ざらないよう別の場所でビルドする
    export NANODOT_APPSTORE=1
    APPSTORE=1
    BUILD+=(--scratch-path .build/appstore --arch arm64 --arch x86_64)
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
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [ -n "$APPSTORE" ]; then
    # Xcode がビルドのときに入れる項目（App Store の検査が、どの SDK・Xcode で作ったかを見る）
    plist() { /usr/libexec/PlistBuddy -c "$1" "$APP/Contents/Info.plist"; }
    SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
    SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
    XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode/ { split($2, v, "."); printf "%02d%d%d", v[1], v[2] + 0, v[3] + 0 }')"
    XCODE_BUILD="$(xcodebuild -version | awk '/^Build version/ { print $3 }')"
    plist "Add :CFBundleSupportedPlatforms array"
    plist "Add :CFBundleSupportedPlatforms:0 string MacOSX"
    plist "Add :BuildMachineOSBuild string $(sw_vers -buildVersion)"
    plist "Add :DTCompiler string com.apple.compilers.llvm.clang.1_0"
    plist "Add :DTPlatformName string macosx"
    plist "Add :DTPlatformVersion string $SDK_VERSION"
    plist "Add :DTPlatformBuild string $SDK_BUILD"
    plist "Add :DTSDKName string macosx$SDK_VERSION"
    plist "Add :DTSDKBuild string $SDK_BUILD"
    plist "Add :DTXcode string $XCODE_VERSION"
    plist "Add :DTXcodeBuild string $XCODE_BUILD"
    # App Sandbox を有効にして ad-hoc 署名する
    codesign --force --sign - --entitlements Resources/AppStore.entitlements "$APP"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built $APP"
