import Foundation

/// Bundle ID を変えたときの設定（UserDefaults）の引き継ぎ。
/// 古いドメインにある値を、新しいドメインにまだない鍵についてだけ写す。一度済ませたら二度としない。
/// App Sandbox ではほかのドメインを読めないので、何も写らない（直接配布版のための処理）
public enum SettingsMigration {
    /// 以前の Bundle ID（0.4.0 まで）
    public static let legacyDomains = ["dev.hashrock.nanodot"]
    static let doneKey = "settingsMigratedFrom"

    /// 新しいドメインに足す値。済んでいれば nil。新しい側にすでにある鍵は上書きしない（古いドメインが複数なら先のものを優先）
    public static func additions(current: [String: Any], legacy: [[String: Any]]) -> [String: Any]? {
        guard current[doneKey] == nil else { return nil }
        var out: [String: Any] = [:]
        for old in legacy {
            for (key, value) in old where current[key] == nil && out[key] == nil { out[key] = value }
        }
        return out
    }

    /// 写した鍵の数を返す。済んでいれば（写すものがなくても）0
    @discardableResult
    public static func run(into defaults: UserDefaults = .standard, from domains: [String] = legacyDomains,
                           currentDomain: String? = Bundle.main.bundleIdentifier) -> Int {
        // バンドルなしで動かしたとき（swift run）は自分のドメインが分からないので、印は defaults からも見る
        guard defaults.object(forKey: doneKey) == nil else { return 0 }
        // persistentDomain はそのドメインだけを見る（登録済みの既定値やグローバルは含まない）
        let current = currentDomain.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let legacy = domains.filter { $0 != currentDomain }.compactMap { defaults.persistentDomain(forName: $0) }
        guard let add = additions(current: current, legacy: legacy) else { return 0 }
        for (key, value) in add { defaults.set(value, forKey: key) }
        defaults.set(domains, forKey: doneKey)
        return add.count
    }
}
