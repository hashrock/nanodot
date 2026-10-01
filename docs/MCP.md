# MCP で nanodot を操作する

nanodot は [Model Context Protocol](https://modelcontextprotocol.io/)（MCP）のサーバーを内蔵しています。Claude Code などの AI エージェントから、開いているシートを読んだり描いたりできます。たとえば「64×64 のセルに 4 方向の歩行チップのラフを描いて」「この行のスライムを色違いにして」「マップを仮組みして」といった指示を、エージェントがアプリの画面を見ながら実行します。

## 有効にする

1. ツールバー右端の ⚙（シートの設定）を開く
2. 「MCP サーバー」をオンにする（既定はオフ）
3. ステータスバーに `MCP :47621` と出れば待ち受け中

ポート番号は同じ設定で変えられます（既定 47621）。サーバーは nanodot を起動している間だけ動きます。

## エージェントから繋ぐ

接続先は `http://127.0.0.1:47621/mcp` です（ポートを変えた場合はその番号）。

### Claude Code

```sh
claude mcp add --transport http nanodot http://127.0.0.1:47621/mcp
```

設定のポップオーバーにある「Claude Code に登録するコマンドをコピー」でも同じコマンドをコピーできます。登録後、Claude Code で `/mcp` を開くと nanodot のツールが見えます。

### 設定ファイルで登録するクライアント

HTTP（Streamable HTTP）に対応したクライアントなら、次のように書きます。

```json
{
  "mcpServers": {
    "nanodot": { "type": "http", "url": "http://127.0.0.1:47621/mcp" }
  }
}
```

stdio にしか対応していないクライアントでは、[mcp-remote](https://www.npmjs.com/package/mcp-remote) などの中継を使います。

```json
{
  "mcpServers": {
    "nanodot": { "command": "npx", "args": ["mcp-remote", "http://127.0.0.1:47621/mcp"] }
  }
}
```

## 約束ごと

- **座標**: シートの左上が (0, 0)、単位はドット。範囲は `x, y, width, height`。
- **色**: `#rrggbb`、`#rrggbbaa`、`transparent`。描画は常に置き換え（下の色と混ぜない）。
- **セル**: シートは `cell_width × cell_height` のセルに区切られています。マップのタイルはセル番号で、`行 × sheet_columns + 列`（空は `-1`）。`sheet_columns` は `get_sheet_info` で分かります。
- **作業範囲**: アプリでの描画はマーク範囲の中に限られますが、MCP からの描画はシート全体に効きます。
- **取り消し**: 描画系のツール（`set_pixels` `draw_shape` `fill` `fill_rect` `draw_text` `copy_region` `replace_color`）は、1 回の呼び出しがアプリの取り消し 1 回分です。`undo` / `redo` ツールやアプリの ⌘Z で戻せます。注釈・アニメ・マップ・パレットの変更は取り消しの対象外です。
- **保存**: 自動では保存しません。`save_sheet` を呼ぶか、アプリで保存してください。`new_sheet` と `open_sheet` は、保存していない変更を確認なしで捨てます。

## ツール一覧

### シートを見る

| ツール | 内容 |
|---|---|
| `get_sheet_info` | 大きさ、セル、マーク範囲、描画色、パレット名、ファイル、未保存かどうか、取り消せるか |
| `get_image` | シートまたは範囲を拡大した PNG 画像（見た目の確認用）。`scale` 省略時は長辺 512px 前後 |
| `get_pixels` | 範囲の画素。`palette`（色の一覧）と `rows`（各行の palette 番号を空白区切り）。最大 128×128 |

### 描く

| ツール | 内容 |
|---|---|
| `set_pixels` | `pixels: [{x, y, color}]`、または `get_pixels` と同じ形式（`x, y, palette, rows`。`"."` はその画素を変えない） |
| `draw_shape` | `shape`（`line` / `rect` / `ellipse`）、`x1, y1, x2, y2`（両端を含む）、`color`、`filled` |
| `fill` | `(x, y)` とつながった同じ色の範囲を塗る。`region` で範囲を限れる |
| `fill_rect` | 範囲を 1 色で塗る（`transparent` で消去） |
| `draw_text` | 文字を描く。`(x, y)` が文字の左上。`size`（pt）、`font`（PostScript 名。既定 `system`）、`antialias`（既定 false） |
| `copy_region` | 範囲を `dest_x, dest_y` に写す。`transform`（`flip_h` / `flip_v` / `rotate_cw` / `rotate_ccw`）、`skip_transparent` |
| `replace_color` | シート全体で `from` の色を `to` に置き換える |
| `undo` / `redo` | 描画の取り消し・やり直し |

### アプリの状態

| ツール | 内容 |
|---|---|
| `set_mark` | メインに表示する範囲（マーク位置とルーペの大きさ）。描いている場所をユーザーに見せたいときに |
| `set_drawing_color` | アプリの描画色 |
| `get_palette` / `set_palette` | サンプルパレットの選択、スロット（64 色）の読み書き |

### 注釈・アニメ・マップ

| ツール | 内容 |
|---|---|
| `list_annotations` / `set_annotation` | セル `(col, row)` の名前・通行可否（`passable`）・重なり順（`z`） |
| `list_anims` / `set_anim` | アニメ。`grid`（起点から列×行に並んだコマ）か `list`（コマの座標の並び）。`delete: true` で削除 |
| `list_maps` / `get_map` / `create_map` / `set_map_tiles` | マップの仮組み。`set_map_tiles` は `tiles`（行ごとのセル番号の 2 次元配列。`-1` で消す、`null` で変えない） |

### ファイル

| ツール | 内容 |
|---|---|
| `new_sheet` | 空のシートにする（`width, height, cell_width, cell_height`） |
| `open_sheet` | 画像を開く（`path`。同じ名前の `.nanodot.json` も読む） |
| `save_sheet` | PNG と `.nanodot.json` に保存（`path` 省略時は今のファイルに上書き） |

## 頼み方の例

- 「`get_image` で今のシートを見て、2 行目のキャラを左右反転して 3 行目に写して」
- 「32×32 のセルを 4×4 並べた新しいシートを作って、PICO-8 のパレットで草・土・水・岩のタイルを描いて。描いたら注釈で水と岩を通行不可にして」
- 「1 行目の 3 コマで歩きアニメを作って、間隔は 150ms」
- 「草のタイルで 20×15 のマップを作って、外周を岩で囲んで」

エージェントは `get_image` で結果を確かめながら進めるとうまくいきます。描いている場所を見せたいときは `set_mark` でメインの表示範囲を動かしてもらいましょう。

## 仕組みと安全性

- 通信は MCP の Streamable HTTP です。`POST /mcp` に JSON-RPC 2.0 のメッセージを送ると、JSON で答えます。サーバーからの通知ストリーム（SSE）とセッション ID は使いません。
- 対応しているプロトコルの版は `2025-06-18`、`2025-03-26`、`2024-11-05` です。
- 待ち受けるのは `127.0.0.1` だけで、ほかのマシンからは繋がりません。
- ブラウザのページから localhost を狙う攻撃（DNS リバインディング）を防ぐため、`Origin` ヘッダーが localhost 以外のリクエストは 403 で断ります。
- 認証はありません。このマシンで動くプログラムなら誰でも操作できるので、使わないときはオフにしておいてください。

## curl で確かめる

```sh
curl -s http://127.0.0.1:47621/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_sheet_info","arguments":{}}}'
```

## 実装

- `Sources/NanodotCore/MCP.swift`: JSON-RPC と MCP のメッセージ処理（通信路とは独立）
- `Sources/NanodotCore/NanodotMCP.swift`: ツールの定義
- `Sources/Nanodot/MCPHTTPServer.swift`: HTTP の待ち受け（Network.framework）。ツールはメインスレッドで実行する
- テスト: `Tests/NanodotCoreTests/CoreTests.swift` の `MCPTests`
