import Foundation

/// 表示する文言の訳をどこから引くか。
///
/// 訳は `Resources/Localizable.xcstrings`（元の言語は日本語。コード上の文言がそのままキー）にあり、
/// `scripts/build-app.sh` が `.lproj` にして `.app` の Resources に入れる。だから引く先はメインバンドル。
/// `swift run` や `swift test` のようにバンドルがないときは、訳が見つからずキー（日本語）がそのまま出る。
public enum Localization {
    /// テストが英語の表を差し込めるように変えられる
    public static var bundle: Bundle = .main
}

/// SwiftUI を通らない文言（`String` を返す表示名、NSAlert、エラーの文面、取り消しの名前）を訳す。
///
/// `Text("保存")` のように SwiftUI の部品へじかに書いたリテラルは、そのままキーとして引かれるので要らない。
/// 補間も書ける。`L("レイヤー \(n)")` のキーは `レイヤー %lld`、文字列の補間は `%@` になる。
/// 包み忘れと訳の抜けは `scripts/check-localization.py` が見張る。
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: Localization.bundle)
}

/// 保存してある名前（同梱パレットの名前など）を、表示のときだけ訳す。
/// 保存する値は言語によらず同じにしておく。表にない名前（ユーザーが付けた名前）はそのまま返る。
public func LName(_ stored: String) -> String {
    guard !stored.isEmpty else { return stored }
    return Localization.bundle.localizedString(forKey: stored, value: stored, table: nil)
}

#if !APPSTORE
/// MCP まわりの文言（設定の MCP の欄、MCP の操作に付く取り消しの名前）。
/// 表が別（Resources/MCP.xcstrings）で、App Store 用の `.app` には表ごと入れない
public func LM(_ value: String.LocalizationValue) -> String {
    String(localized: value, table: "MCP", bundle: Localization.bundle)
}
#endif
