# nanodot website

ビルド不要の静的サイト。`index.html` をブラウザで開いて確認できます。

- `index.html`: ページ本文
- `privacy.html`: プライバシーポリシー（日本語のあとに `#en` の英語）。App Store Connect に書く URL は <https://hashrock.github.io/nanodot/privacy.html>
- `support.html`: サポート（同じく日本語・英語）。<https://hashrock.github.io/nanodot/support.html>
- `style.css`: レスポンシブスタイル（`.policy` は privacy / support の本文）
- `assets/`: ロゴ（`Resources/AppIcon.svg` の写し）とスクリーンショット

## GitHub Pages

リポジトリの Settings → Pages → Build and deployment → Source で **GitHub Actions** を選択してください。
`main` に push すると `.github/workflows/pages.yml` が `website/` を公開します。Actions から手動実行も可能です。

ダウンロードボタンは最新の GitHub Release にリンクしています。

アプリの挙動（保存するもの、Sandbox でできること、メニューの名前）を変えたら、`privacy.html` と `support.html` も合わせて直し、プライバシーポリシーは最終更新日を改めます。
