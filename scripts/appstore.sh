#!/bin/bash
# Mac App Store に出す .pkg を作る。Apple とは通信しない（アップロードは別。README の「App Store に出す」）
#
#   ./scripts/appstore.sh --check-only   # ビルドして検査だけ（証明書もプロファイルも要らない）
#   ./scripts/appstore.sh                # 検査 → Apple Distribution で署名 → dist/appstore/Nanodot-<版>.pkg
#
# 署名に要るもの（どれも Apple Developer で作ってこの Mac に入れておく）:
#   - 証明書 "Apple Distribution: ..."（アプリの署名）
#   - 証明書 "3rd Party Mac Developer Installer: ..."（.pkg の署名。Apple Developer では Mac Installer Distribution）
#   - Mac App Store 用のプロビジョニングプロファイル（App ID com.hashrock.nanodot）
#
# 環境変数:
#   PROFILE            プロファイルの場所（既定: Resources/Nanodot_AppStore.provisionprofile。リポジトリには入れない）
#   APP_IDENTITY       アプリの署名に使う証明書の名前（既定: キーチェーンから探す）
#   INSTALLER_IDENTITY .pkg の署名に使う証明書の名前（既定: キーチェーンから探す）
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK_ONLY=
if [ "${1-}" = "--check-only" ]; then
    CHECK_ONLY=1
elif [ $# -gt 0 ]; then
    echo "usage: $0 [--check-only]" >&2
    exit 2
fi

APP=build/appstore/Nanodot.app
BIN="$APP/Contents/MacOS/Nanodot"
BUNDLE_ID=com.hashrock.nanodot
PROFILE="${PROFILE-Resources/Nanodot_AppStore.provisionprofile}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "error: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# 署名されているものの entitlements を plist で取り出す
entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null > "$2"; }

# App Store 用として満たすべきこと。Apple と通信せずに確かめられるものを全部見る
check_app() {
    local info="$APP/Contents/Info.plist" ent="$WORK/ent.plist"

    # MCP の文字列・シンボルが残っていない（memcpy は "mcp" を含むので除く）。arch ごとに見る
    local arch left
    for arch in arm64 x86_64; do
        lipo "$BIN" -verify_arch "$arch" || fail "バイナリに $arch が入っていません"
        left="$( { strings -a -arch "$arch" "$BIN"; nm -arch "$arch" "$BIN" 2>/dev/null; } | grep -i mcp | grep -vi memcpy || true)"
        [ -z "$left" ] || fail "バイナリ（${arch}）に MCP が残っています: $(echo "$left" | head -5)"
    done
    # 通信しない: Network.framework をリンクしていない
    ! otool -arch all -L "$BIN" | grep -q Network.framework || fail "Network.framework をリンクしています"

    # Info.plist
    [ "$(plist "$info" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "CFBundleIdentifier が $BUNDLE_ID ではありません"
    [ "$(plist "$info" ITSAppUsesNonExemptEncryption)" = "false" ] || fail "ITSAppUsesNonExemptEncryption が false ではありません"
    local key
    for key in CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion LSApplicationCategoryType \
               CFBundleSupportedPlatforms DTSDKName DTXcode DTPlatformName; do
        [ -n "$(plist "$info" "$key")" ] || fail "Info.plist に $key がありません"
    done
    plutil -lint "$info" >/dev/null || fail "Info.plist が壊れています"

    # 表示言語: ja・en を申告していて、訳の表が入っている。MCP の文言は入っていない
    local res="$APP/Contents/Resources" lang
    [ "$(plist "$info" CFBundleDevelopmentRegion)" = "ja" ] || fail "CFBundleDevelopmentRegion が ja ではありません"
    for lang in ja en; do
        plist "$info" CFBundleLocalizations | grep -qx "    $lang" || fail "CFBundleLocalizations に $lang がありません"
        plutil -lint "$res/$lang.lproj/Localizable.strings" >/dev/null || fail "$lang.lproj/Localizable.strings がないか、壊れています"
        plutil -lint "$res/$lang.lproj/InfoPlist.strings" >/dev/null || fail "$lang.lproj/InfoPlist.strings がないか、壊れています"
    done
    [ "$(plutil -convert json -o - "$res/en.lproj/Localizable.strings" | /usr/bin/python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')" -gt 100 ] \
        || fail "en.lproj/Localizable.strings に訳が入っていません"
    [ -z "$(find "$res" -name 'MCP.strings*')" ] || fail "MCP の訳の表が入っています"
    left="$(find "$res" -name '*.strings' -exec plutil -convert json -o - {} \; | grep -i mcp || true)"
    [ -z "$left" ] || fail "訳の表に MCP が残っています: $(echo "$left" | head -c 200)"

    # プライバシーマニフェスト
    local privacy="$APP/Contents/Resources/PrivacyInfo.xcprivacy"
    plutil -lint "$privacy" >/dev/null || fail "PrivacyInfo.xcprivacy がないか、壊れています"
    [ "$(plist "$privacy" NSPrivacyTracking)" = "false" ] || fail "PrivacyInfo.xcprivacy の NSPrivacyTracking が false ではありません"

    # アイコン: 1024×1024（512@2x）まで入っている
    local iconset="$WORK/AppIcon.iconset"
    rm -rf "$iconset"
    iconutil -c iconset "$APP/Contents/Resources/AppIcon.icns" -o "$iconset" || fail "AppIcon.icns を読めません"
    [ "$(sips -g pixelWidth "$iconset/icon_512x512@2x.png" 2>/dev/null | awk '/pixelWidth/ { print $2 }')" = "1024" ] \
        || fail "AppIcon.icns に 1024×1024 が入っていません"

    # 署名と entitlements: Sandbox あり、ネットワークなし、余計なものなし
    codesign --verify --deep --strict "$APP" || fail "署名を検証できません"
    entitlements "$APP" "$ent"
    [ "$(plist "$ent" com.apple.security.app-sandbox)" = "true" ] || fail "App Sandbox が有効ではありません"
    ! grep -q "com.apple.security.network" "$ent" || fail "network の entitlement が付いています"
    local allowed="com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write
com.apple.security.files.bookmarks.app-scope com.apple.application-identifier com.apple.developer.team-identifier"
    local k
    for k in $(plutil -convert json -o - "$ent" | /usr/bin/python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin)))'); do
        echo "$allowed" | tr ' ' '\n' | grep -qx "$k" || fail "想定していない entitlement が付いています: $k"
    done
    for k in com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope; do
        [ "$(plist "$ent" "$k")" = "true" ] || fail "entitlement $k がありません"
    done

    # 隔離の印（ダウンロードしたものを混ぜると付く）が付いたまま出さない
    ! xattr -lr "$APP" 2>/dev/null | grep -q "com.apple.quarantine" || fail "アプリに隔離の印が付いています（xattr -dr com.apple.quarantine ${APP}）"
}

./scripts/build-app.sh --appstore
check_app
echo "OK: 検査を通りました（ad-hoc 署名 + App Sandbox）: $APP"
[ -z "$CHECK_ONLY" ] || exit 0

# ---- ここから先は証明書とプロファイルが要る ----

# 名前の頭が合う証明書をキーチェーンから 1 つ探す
find_identity() {
    local kind
    for kind in "$@"; do
        security find-identity -v 2>/dev/null | sed -n "s/.*\"\($kind: .*\)\"/\1/p" | head -1 | grep . && return 0
    done
    return 1
}

MISSING=()
APP_IDENTITY="${APP_IDENTITY-$(find_identity "Apple Distribution" "3rd Party Mac Developer Application" || true)}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY-$(find_identity "3rd Party Mac Developer Installer" "Mac Installer Distribution" || true)}"
[ -n "$APP_IDENTITY" ] || MISSING+=("アプリの署名の証明書（Apple Distribution）がキーチェーンにありません")
[ -n "$INSTALLER_IDENTITY" ] || MISSING+=(".pkg の署名の証明書（3rd Party Mac Developer Installer = Mac Installer Distribution）がキーチェーンにありません")
[ -f "$PROFILE" ] || MISSING+=("プロビジョニングプロファイルがありません: $PROFILE")
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "error: .pkg を作るのに足りないものがあります（README の「App Store に出す」を参照）:" >&2
    printf '  - %s\n' "${MISSING[@]}" >&2
    exit 1
fi

# プロファイルの中身を確かめる（署名は CMS なので手元で開ける）
security cms -D -i "$PROFILE" > "$WORK/profile.plist" 2>/dev/null || fail "プロファイルを読めません: $PROFILE"
APP_ID="$(plist "$WORK/profile.plist" "Entitlements:com.apple.application-identifier")"
TEAM_ID="$(plist "$WORK/profile.plist" "Entitlements:com.apple.developer.team-identifier")"
[ -n "$TEAM_ID" ] || fail "プロファイルにチーム ID がありません"
[ "$APP_ID" = "$TEAM_ID.$BUNDLE_ID" ] || fail "プロファイルの App ID が $TEAM_ID.$BUNDLE_ID ではありません: $APP_ID"
! plist "$WORK/profile.plist" ProvisionedDevices >/dev/null || fail "開発用のプロファイルです（Mac App Store 用のものを使ってください）"
EXPIRES="$(plist "$WORK/profile.plist" ExpirationDate)"
echo "プロファイル: $(plist "$WORK/profile.plist" Name)（${APP_ID}、期限 ${EXPIRES}）"

# entitlements にアプリの ID とチーム ID を足して署名し直す
cp Resources/AppStore.entitlements "$WORK/signing.entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" \
                        -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$WORK/signing.entitlements"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
xattr -cr "$APP"
codesign --force --timestamp=none --sign "$APP_IDENTITY" --entitlements "$WORK/signing.entitlements" "$APP"
check_app
entitlements "$APP" "$WORK/signed.plist"
[ "$(plist "$WORK/signed.plist" com.apple.application-identifier)" = "$APP_ID" ] || fail "署名に App ID が入っていません"

VERSION="$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)"
PKG="dist/appstore/Nanodot-$VERSION.pkg"
mkdir -p dist/appstore
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" --timestamp=none "$PKG"
pkgutil --check-signature "$PKG" >/dev/null || fail ".pkg の署名を検証できません"
# ビルドしたターミナルによっては、ファイルに com.apple.provenance が付き、.pkg の中に "._*" として入る（外せない。インストール時に属性へ戻る）
DOTS="$(pkgutil --payload-files "$PKG" | grep -c '/\._' || true)"
[ "$DOTS" = "0" ] || echo "note: .pkg に拡張属性のファイル（._*）が $DOTS 個入っています。アップロードの検査で指摘されたら、Terminal.app でビルドし直してください"
echo "Built $PKG ($(du -h "$PKG" | cut -f1))"
echo "アップロードは Transporter か xcrun altool で（README の「App Store に出す」）"
