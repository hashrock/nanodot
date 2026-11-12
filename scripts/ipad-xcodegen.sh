#!/bin/zsh
# iPad 版の Xcode プロジェクトを project.yml から作り直す（brew install xcodegen）。
# XcodeGen はパッケージ（..）の参照にフォルダー名を入れるので、worktree などフォルダー名が nanodot でないところで
# 作っても差分が出ないよう、名前を nanodot にそろえる
set -euo pipefail
cd "$(dirname "$0")/../iPad"
xcodegen --quiet
dir=$(basename "$(cd .. && pwd)")
if [ "$dir" != nanodot ]; then
    sed -i '' "s|/\* $dir \*/|/* nanodot */|g; s|name = $dir; path = \.\.;|name = nanodot; path = ..;|" NanodotPad.xcodeproj/project.pbxproj
fi
