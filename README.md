# Nanodot

ゲーム用スプライトシートを描くための macOS 用ドット絵ツールです。DotPainter ALFAR の操作体系（ストックとメインの往復、右ボタンの一貫した使い方）を参考にしています。仕様は [SPEC.md](SPEC.md) を参照してください。

[サイト](https://hashrock.github.io/nanodot/) · [ダウンロード](https://github.com/hashrock/nanodot/releases/latest)

## ビルドと起動

```sh
./scripts/build-app.sh      # リリースビルドして build/Nanodot.app を生成
open build/Nanodot.app
./scripts/release.sh        # Developer ID で署名・公証して dist/Nanodot-<版>.zip を作る（配布用）
```

- 必要なもの: macOS 14 以降、Xcode 16 以降（Swift 5.10+）
- テスト: `swift test`

## 基本操作

| 操作 | メイン（拡大編集） | ストック（シート全体） |
|---|---|---|
| 左クリック／ドラッグ | ツールで描画 | マーク位置を指定 |
| 左ドラッグ（マーク内から） | — | 移動先と入れ替え |
| 左ドラッグ（マーク右下のつまみ） | — | ルーペサイズを変更 |
| 右クリック | スポイト | マーク大の範囲をコピー |
| 右ドラッグ | 範囲コピー → スタンプモード | コピー範囲を広げる |
| ダブルクリック | — | 貼り付け（⌥ で透明部分を抜く） |
| ホイール | 拡大縮小（ルーペサイズを 1/2・2 倍） | ホイールで拡大縮小（⌥ で縦・Shift で横に移動）。スクロールバーあり。トラックパッドは 2 本指で移動、ピンチで拡大縮小 |

| キー | 操作 |
|---|---|
| B (P) / E / G / L / R / O / T | ペン / 消しゴム / 塗りつぶし / 直線 / 矩形 / 楕円 / テキスト |
| 矢印（Shift） | マーク位置をスナップ単位（ルーペ単位）で移動 |
| ⌘C / ⌘V | マーク範囲をコピー / スタンプモード |
| Space + ドラッグ | メイン: マーク位置を動かす（セルの 1/8 単位）／ストック: 表示を動かす |
| Esc | スタンプモードを抜ける |
| Delete / ⌥Delete | マーク範囲を消去 / 描画色で塗りつぶし |
| ⌘Z / ⇧⌘Z | 取り消し / やり直し |
| ⌘' / ⌘0 | セルの格子の表示切替 / ストックを全体表示 |
| ⇧⌘A | アニメウィンドウ |
| ⇧⌘M | マップウィンドウ（仮組み） |

スナップ単位（既定はセルの 1/2）はメニュー「マーク > スナップ」で変えられます。

## MCP

AI エージェント（Claude Code など）から nanodot を操作できる MCP サーバーを内蔵しています。⚙ の設定で「MCP サーバー」をオンにし、`claude mcp add --transport http nanodot http://127.0.0.1:47621/mcp` で登録します。詳しくは [docs/MCP.md](docs/MCP.md) を参照してください。

## ファイル

画像は素の PNG で保存し、セル・スナップ・パレットスロット・アニメなどの設定は同じフォルダーの `<名前>.nanodot.json` に保存します。

## 構成

```
Sources/NanodotCore/   エンジン（UI 非依存、テスト可能）
  Pixel.swift          RGBA・矩形・画素バッファ（反転・回転・シフト・貼り付け）
  Raster.swift         直線・矩形・楕円・塗りつぶし
  Sheet.swift          スナップ、アニメ定義、サイドカーの設定
  Editor.swift         ドキュメント・マーク位置・履歴・ツール操作
  SheetFile.swift      PNG / JSON の読み書き、GIF・APNG・連番 PNG の書き出し
  TextRenderer.swift   文字をドットに描く
  TileMap.swift        マップの仮組み、セルの注釈
  MCP.swift / NanodotMCP.swift  MCP のメッセージ処理とツール
Sources/Nanodot/       macOS アプリ（SwiftUI パネル + AppKit のキャンバス）
  MainCanvasView.swift / StockView.swift / AnimPreviewView.swift
  Panels.swift (パレット・アニメ) / ContentView.swift / NanodotApp.swift
```
