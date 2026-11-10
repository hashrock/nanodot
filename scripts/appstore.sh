#!/bin/bash
# Mac App Store に出す .pkg を作る。アップロードはしない（README の「App Store に出す」）
#
#   ./scripts/appstore.sh                # 検査 → クラウド署名 → dist/appstore/Nanodot-<版>.pkg（既定）
#   ./scripts/appstore.sh --local        # 検査 → 手元の証明書とプロファイルで署名 → 同じ場所に .pkg
#   ./scripts/appstore.sh --check-only   # ビルドして検査だけ（証明書もプロファイルも要らない。Apple と通信しない）
#
# クラウド署名（既定）: 手元に配布用の証明書がなくてよい。Xcode に Apple ID でサインインしてあれば、
#   xcodebuild -exportArchive -allowProvisioningUpdates が Apple の側にある証明書（Cloud Managed Apple Distribution）で
#   アプリに署名し、プロファイル（Mac Team Store Provisioning Profile）を作って入れ、.pkg にも署名する。
#   Apple と通信するのはこの署名とプロファイルの作成だけ。
#
# 手元の証明書で署名（--local）: 次の 3 つを Apple Developer で作ってこの Mac に入れておく。Apple と通信しない。
#   - 証明書 "Apple Distribution: ..."（アプリの署名）
#   - 証明書 "3rd Party Mac Developer Installer: ..."（.pkg の署名。Apple Developer では Mac Installer Distribution）
#   - Mac App Store 用のプロビジョニングプロファイル（App ID com.hashrock.nanodot）
#
# 環境変数:
#   TEAM_ID            チーム ID（既定: 5WLLZHK49R。クラウド署名で使う）
#   PROFILE            --local: プロファイルの場所（既定: Resources/Nanodot_AppStore.provisionprofile。リポジトリには入れない）
#   APP_IDENTITY       --local: アプリの署名に使う証明書の名前（既定: キーチェーンから探す）
#   INSTALLER_IDENTITY --local: .pkg の署名に使う証明書の名前（既定: キーチェーンから探す）
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=cloud
case "${1-}" in
    "") ;;
    --check-only) MODE=check ;;
    --local) MODE=local ;;
    *) echo "usage: $0 [--local | --check-only]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: $0 [--local | --check-only]" >&2; exit 2; }

APP=build/appstore/Nanodot.app
BUNDLE_ID=com.hashrock.nanodot
TEAM_ID="${TEAM_ID-5WLLZHK49R}"
PROFILE="${PROFILE-Resources/Nanodot_AppStore.provisionprofile}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "error: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# 署名されているものの entitlements を plist で取り出す
entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null > "$2"; }

# App Store 用として満たすべきこと。Apple と通信せずに確かめられるものを全部見る。
# ビルドした .app にも、できた .pkg から取り出した .app にも使う
check_app() {
    local APP="$1"
    local BIN="$APP/Contents/MacOS/Nanodot" info="$APP/Contents/Info.plist" ent="$WORK/ent.plist"

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

# 提出用に署名した .app が満たすべきこと: 配布用の証明書、App ID とチーム ID、Mac App Store 用のプロファイル
check_signed_app() {
    local app="$1" ent="$WORK/signed.plist" prof="$WORK/embedded.plist"
    # （grep -q を直接つなぐと、先に閉じたパイプで codesign が落ちて pipefail に掛かる）
    local authority
    authority="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    echo "$authority" | grep -qE "^(Apple Distribution|3rd Party Mac Developer Application): " \
        || fail "アプリが配布用の証明書（Apple Distribution）で署名されていません: $authority"
    entitlements "$app" "$ent"
    local app_id team
    app_id="$(plist "$ent" com.apple.application-identifier)"
    team="$(plist "$ent" com.apple.developer.team-identifier)"
    [ -n "$team" ] || fail "署名にチーム ID が入っていません"
    [ "$app_id" = "$team.$BUNDLE_ID" ] || fail "署名の App ID が $team.$BUNDLE_ID ではありません: $app_id"
    # プロファイルの中身（署名は CMS なので手元で開ける）
    security cms -D -i "$app/Contents/embedded.provisionprofile" > "$prof" 2>/dev/null || fail "アプリにプロファイルが入っていないか、読めません"
    [ "$(plist "$prof" "Entitlements:com.apple.application-identifier")" = "$app_id" ] \
        || fail "プロファイルの App ID が $app_id ではありません: $(plist "$prof" "Entitlements:com.apple.application-identifier")"
    ! plist "$prof" ProvisionedDevices >/dev/null || fail "開発用のプロファイルです（Mac App Store 用のものを使ってください）"
    echo "署名: $authority"
    echo "プロファイル: $(plist "$prof" Name)（${app_id}、期限 $(plist "$prof" ExpirationDate)）"
}

# できた .pkg を検査する: .pkg の署名を確かめ、中のアプリを取り出して、ビルドしたものと同じ検査にもう一度かける
check_pkg() {
    local pkg="$1" out="$WORK/pkg"
    pkgutil --check-signature "$pkg" > "$WORK/pkgsig.txt" || fail ".pkg の署名を検証できません"
    grep -qE "3rd Party Mac Developer Installer|Mac Installer Distribution" "$WORK/pkgsig.txt" \
        || fail ".pkg が Mac App Store 用のインストーラーの証明書で署名されていません"
    rm -rf "$out"
    pkgutil --expand-full "$pkg" "$out" || fail ".pkg を展開できません"
    local apps
    apps="$(find "$out" -name "*.app" -type d -prune)"
    [ "$(echo "$apps" | grep -c .)" = "1" ] || fail ".pkg の中のアプリが 1 つではありません: $apps"
    [ "$(basename "$apps")" = "Nanodot.app" ] || fail ".pkg の中のアプリが Nanodot.app ではありません: $apps"
    check_app "$apps"
    check_signed_app "$apps"
    echo ".pkg の署名: $(sed -n 's/^ *1\. //p' "$WORK/pkgsig.txt" | head -1)"
    # ビルドしたターミナルによっては、ファイルに com.apple.provenance が付き、.pkg の中に "._*" として入る（外せない。インストール時に属性へ戻る）
    local dots
    dots="$(pkgutil --payload-files "$pkg" | grep -c '/\._' || true)"
    [ "$dots" = "0" ] || echo "note: .pkg に拡張属性のファイル（._*）が $dots 個入っています。アップロードの検査で指摘されたら、Terminal.app でビルドし直してください"
}

./scripts/build-app.sh --appstore
check_app "$APP"
echo "OK: 検査を通りました（ad-hoc 署名 + App Sandbox）: $APP"
[ "$MODE" != check ] || exit 0

VERSION="$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)"
BUILD_NUMBER="$(plist "$APP/Contents/Info.plist" CFBundleVersion)"
PKG="dist/appstore/Nanodot-$VERSION.pkg"

# ---- クラウド署名（既定）: .app を .xcarchive の形に包み、xcodebuild -exportArchive に署名と .pkg 化を任せる ----
sign_cloud() {
    local archive=build/appstore/Nanodot.xcarchive out="$WORK/export" log=build/appstore/export.log
    rm -rf "$archive"
    mkdir -p "$archive/Products/Applications"
    ditto "$APP" "$archive/Products/Applications/Nanodot.app"
    # デバッグ情報があれば入れておく（なくても通る）
    local dsym
    dsym="$(NANODOT_APPSTORE=1 swift build -c release --scratch-path .build/appstore --arch arm64 --arch x86_64 --show-bin-path)/Nanodot.dSYM"
    if [ -d "$dsym" ]; then
        mkdir -p "$archive/dSYMs"
        ditto "$dsym" "$archive/dSYMs/Nanodot.app.dSYM"
    fi
    # Xcode の Archive が書くのと同じ項目。版・ビルド番号は .app の Info.plist から
    local info="$archive/Info.plist"
    plutil -create xml1 "$info"
    /usr/libexec/PlistBuddy \
        -c "Add :ApplicationProperties dict" \
        -c "Add :ApplicationProperties:ApplicationPath string Applications/Nanodot.app" \
        -c "Add :ApplicationProperties:Architectures array" \
        -c "Add :ApplicationProperties:Architectures:0 string arm64" \
        -c "Add :ApplicationProperties:Architectures:1 string x86_64" \
        -c "Add :ApplicationProperties:CFBundleIdentifier string $BUNDLE_ID" \
        -c "Add :ApplicationProperties:CFBundleShortVersionString string $VERSION" \
        -c "Add :ApplicationProperties:CFBundleVersion string $BUILD_NUMBER" \
        -c "Add :ApplicationProperties:SigningIdentity string -" \
        -c "Add :ApplicationProperties:Team string $TEAM_ID" \
        -c "Add :ArchiveVersion integer 2" \
        -c "Add :Name string Nanodot" \
        -c "Add :SchemeName string Nanodot" "$info" >/dev/null
    plutil -insert CreationDate -date "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$info"

    local options="$WORK/ExportOptions.plist"
    plutil -create xml1 "$options"
    /usr/libexec/PlistBuddy \
        -c "Add :method string app-store-connect" \
        -c "Add :destination string export" \
        -c "Add :signingStyle string automatic" \
        -c "Add :teamID string $TEAM_ID" \
        -c "Add :manageAppVersionAndBuildNumber bool false" \
        -c "Add :uploadSymbols bool false" "$options" >/dev/null

    echo "クラウド署名で .pkg を作ります（Apple と通信します: 署名とプロファイルの作成）..."
    if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
            -exportPath "$out" -allowProvisioningUpdates > "$log" 2>&1; then
        grep -E "^error:|error: " "$log" | head -10 >&2 || true
        fail "xcodebuild -exportArchive が失敗しました（ログ: ${log}）。Xcode の Settings > Accounts にチーム $TEAM_ID の Apple ID でサインインしているか確かめてください。手元の証明書で署名するなら --local"
    fi
    [ -f "$out/Nanodot.pkg" ] || fail "xcodebuild が .pkg を出しませんでした（ログ: ${log}）"
    mkdir -p dist/appstore
    rm -f "$PKG"
    cp "$out/Nanodot.pkg" "$PKG"
    # どの証明書・プロファイル・entitlements で署名されたかの記録
    cp "$out/DistributionSummary.plist" "dist/appstore/Nanodot-$VERSION.DistributionSummary.plist" 2>/dev/null || true
}

# ---- 手元の証明書で署名（--local）: 証明書とプロファイルが要る。Apple と通信しない ----

# 名前の頭が合う証明書をキーチェーンから 1 つ探す
find_identity() {
    local kind
    for kind in "$@"; do
        security find-identity -v 2>/dev/null | sed -n "s/.*\"\($kind: .*\)\"/\1/p" | head -1 | grep . && return 0
    done
    return 1
}

sign_local() {
    local missing=() app_identity installer_identity
    app_identity="${APP_IDENTITY-$(find_identity "Apple Distribution" "3rd Party Mac Developer Application" || true)}"
    installer_identity="${INSTALLER_IDENTITY-$(find_identity "3rd Party Mac Developer Installer" "Mac Installer Distribution" || true)}"
    [ -n "$app_identity" ] || missing+=("アプリの署名の証明書（Apple Distribution）がキーチェーンにありません")
    [ -n "$installer_identity" ] || missing+=(".pkg の署名の証明書（3rd Party Mac Developer Installer = Mac Installer Distribution）がキーチェーンにありません")
    [ -f "$PROFILE" ] || missing+=("プロビジョニングプロファイルがありません: $PROFILE")
    if [ ${#missing[@]} -gt 0 ]; then
        echo "error: 手元の証明書で .pkg を作るのに足りないものがあります（README の「手元の証明書で署名するとき」を参照。なくても、--local を付けなければクラウド署名で作れます）:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        exit 1
    fi

    # プロファイルの中身を確かめる（署名は CMS なので手元で開ける）
    security cms -D -i "$PROFILE" > "$WORK/profile.plist" 2>/dev/null || fail "プロファイルを読めません: $PROFILE"
    local app_id team
    app_id="$(plist "$WORK/profile.plist" "Entitlements:com.apple.application-identifier")"
    team="$(plist "$WORK/profile.plist" "Entitlements:com.apple.developer.team-identifier")"
    [ -n "$team" ] || fail "プロファイルにチーム ID がありません"
    [ "$app_id" = "$team.$BUNDLE_ID" ] || fail "プロファイルの App ID が $team.$BUNDLE_ID ではありません: $app_id"

    # entitlements にアプリの ID とチーム ID を足して署名し直す
    cp Resources/AppStore.entitlements "$WORK/signing.entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $app_id" \
                            -c "Add :com.apple.developer.team-identifier string $team" "$WORK/signing.entitlements"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    xattr -cr "$APP"
    codesign --force --timestamp=none --sign "$app_identity" --entitlements "$WORK/signing.entitlements" "$APP"

    mkdir -p dist/appstore
    rm -f "$PKG"
    productbuild --component "$APP" /Applications --sign "$installer_identity" --timestamp=none "$PKG"
}

if [ "$MODE" = local ]; then sign_local; else sign_cloud; fi
check_pkg "$PKG"
echo "OK: .pkg の中のアプリも検査を通りました"
echo "Built $PKG ($(du -h "$PKG" | cut -f1))"
echo "アップロードは Transporter か xcrun altool で（README の「App Store に出す」）"
