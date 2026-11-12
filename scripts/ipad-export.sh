#!/bin/zsh
# iPad 版の提出用 .ipa を作る（アップロードはしない）。
#
#   ./scripts/ipad-export.sh               Archive（自動署名）→ クラウド署名で dist/appstore/ipad/Nanodot-<版>-<ビルド>.ipa
#   ./scripts/ipad-export.sh --check-only  署名なしで Archive して、中身だけ検査する（Apple と通信しない）
#   NO_ICLOUD=1 ./scripts/ipad-export.sh   iCloud の entitlement を外して作る（App ID に iCloud を付けたくないとき）
#
# Apple と通信するのは、Archive の自動署名（開発用のプロファイル）と、xcodebuild -exportArchive -allowProvisioningUpdates
# （Cloud Managed Apple Distribution での署名と App Store 用のプロファイルの作成）だけ。iCloud 入りで初めて作るときは、
# このとき App ID com.hashrock.nanodot に iCloud が付き、container iCloud.com.hashrock.nanodot が登録される。
# 要るもの: Xcode の Settings > Accounts に、チーム 5WLLZHK49R の Apple ID でサインインしていること
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TEAM_ID=${TEAM_ID:-5WLLZHK49R}
CHECK_ONLY=
[ "${1:-}" = --check-only ] && CHECK_ONLY=1

OUT=build/ipad
DIST=dist/appstore/ipad
mkdir -p "$OUT" "$DIST"

fail() { echo "NG: $*" >&2; exit 1; }

VERSION=$(grep 'MARKETING_VERSION:' iPad/project.yml | sed 's/.*"\(.*\)".*/\1/')
BUILD=$(grep 'CURRENT_PROJECT_VERSION:' iPad/project.yml | sed 's/.*"\(.*\)".*/\1/')
ARCHIVE="$OUT/NanodotPad-$VERSION-$BUILD.xcarchive"
rm -rf "$ARCHIVE"

ARGS=(-project iPad/NanodotPad.xcodeproj -scheme NanodotPad -destination 'generic/platform=iOS'
      -archivePath "$ARCHIVE" -derivedDataPath "$OUT/dd")
if [ -n "${NO_ICLOUD:-}" ]; then
    # iCloud を外した entitlements（空）で署名する
    plutil -create xml1 "$OUT/NoICloud.entitlements"
    ARGS+=(CODE_SIGN_ENTITLEMENTS="$ROOT/$OUT/NoICloud.entitlements")
fi

echo "Archive: $VERSION ($BUILD)"
if [ -n "$CHECK_ONLY" ]; then
    xcodebuild archive "${ARGS[@]}" CODE_SIGNING_ALLOWED=NO > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; fail "Archive に失敗（$OUT/archive.log）"; }
else
    xcodebuild archive "${ARGS[@]}" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; fail "Archive に失敗（$OUT/archive.log）"; }
fi

# アプリの中身の検査（署名の前後で同じものを見る）
PLIST=
v() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }
check_app() {
    local app=$1
    PLIST="$app/Info.plist"
    [ "$(v CFBundleIdentifier)" = com.hashrock.nanodot ] || fail "Bundle ID が違う: $(v CFBundleIdentifier)"
    [ "$(v CFBundleShortVersionString)" = "$VERSION" ] || fail "版が違う"
    [ "$(v CFBundleVersion)" = "$BUILD" ] || fail "ビルド番号が違う"
    [ "$(v ITSAppUsesNonExemptEncryption)" = false ] || fail "ITSAppUsesNonExemptEncryption が false でない"
    [ "$(v UIFileSharingEnabled)" = true ] || fail "UIFileSharingEnabled がない"
    [ "$(v LSSupportsOpeningDocumentsInPlace)" = true ] || fail "LSSupportsOpeningDocumentsInPlace がない"
    [ "$(v UIDeviceFamily:0)" = 2 ] && ! v UIDeviceFamily:1 >/dev/null || fail "iPad だけ（UIDeviceFamily = [2]）になっていない"
    [ "$(v MinimumOSVersion)" = 17.0 ] || fail "MinimumOSVersion が 17.0 でない"
    local locs=$(v CFBundleLocalizations)
    [[ "$locs" == *ja* && "$locs" == *en* ]] || fail "CFBundleLocalizations に ja・en がない"
    [ -d "$app/ja.lproj" ] && [ -d "$app/en.lproj" ] || fail "ja.lproj・en.lproj がない"
    [[ "$(ls "$app/en.lproj")" == *Localizable* ]] || fail "英語の訳の表がない"
    [ -f "$app/PrivacyInfo.xcprivacy" ] || fail "PrivacyInfo.xcprivacy がない"
    [ -f "$app/Assets.car" ] || fail "アイコン（Assets.car）がない"
    [[ "$(v CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName)" == AppIcon ]] || fail "アイコンの宣言がない"
    # MCP（直接配布版だけの機能）が入っていない
    local strs=$(strings "$app/Nanodot")
    [[ "${strs:l}" != *mcp* ]] || fail "MCP の文字列が入っている"
    [[ "$(otool -L "$app/Nanodot")" != *Network.framework* ]] || fail "Network.framework をリンクしている"
    # シミュレーター用の検証の入口が入っていない
    [[ "$strs" != *selftest* ]] || fail "検証用の入口が入っている"
    echo "OK: $app"
}

check_app "$ARCHIVE/Products/Applications/Nanodot.app"
[ -n "$CHECK_ONLY" ] && { echo "検査だけ（署名なし）: $ARCHIVE"; exit 0; }

# クラウド署名で書き出す（アップロードはしない: destination = export）
OPTIONS="$OUT/ExportOptions.plist"
cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
EXPORT="$OUT/export"
rm -rf "$EXPORT"
echo "クラウド署名で書き出します（ログは $OUT/export.log）"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$EXPORT" \
    -allowProvisioningUpdates > "$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; fail "書き出しに失敗（$OUT/export.log）"; }

IPA="$DIST/Nanodot-$VERSION-$BUILD.ipa"
cp "$EXPORT/Nanodot.ipa" "$IPA"
rm -rf "$DIST/NanodotPad-$VERSION-$BUILD.xcarchive"
cp -R "$ARCHIVE" "$DIST/"
[ -f "$EXPORT/DistributionSummary.plist" ] && cp "$EXPORT/DistributionSummary.plist" "$DIST/Nanodot-$VERSION-$BUILD.DistributionSummary.plist"

# できた .ipa を開いて、もう一度検査し、署名・プロファイル・entitlements を確かめる
CHECK="$OUT/ipa-check"
rm -rf "$CHECK"
mkdir -p "$CHECK"
ditto -x -k "$IPA" "$CHECK"
APP="$CHECK/Payload/Nanodot.app"
check_app "$APP"
codesign --verify --deep --strict "$APP" || fail "署名の検証に失敗"
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
[[ "$SIGN_INFO" == *"Authority=Apple Distribution"* ]] || fail "配布用の証明書で署名されていない"
security cms -D -i "$APP/embedded.mobileprovision" > "$OUT/profile.plist"
PROFILE_APPID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$OUT/profile.plist")
[ "$PROFILE_APPID" = "$TEAM_ID.com.hashrock.nanodot" ] || fail "プロファイルの App ID が違う: $PROFILE_APPID"
! /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$OUT/profile.plist" >/dev/null 2>&1 || fail "App Store 用のプロファイルでない（端末の一覧がある）"
codesign -d --entitlements :- "$APP" > "$OUT/entitlements.plist" 2>/dev/null
if [ -z "${NO_ICLOUD:-}" ]; then
    [[ "$(cat "$OUT/entitlements.plist")" == *iCloud.com.hashrock.nanodot* ]] || fail "iCloud container が entitlements にない"
fi
[ "$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$OUT/entitlements.plist" 2>/dev/null)" != true ] || fail "get-task-allow が true"
echo "プロファイル: $(/usr/libexec/PlistBuddy -c 'Print :Name' "$OUT/profile.plist")"
echo "できた: $IPA"
