import Foundation

/// Bundle ID を変えたときの設定（UserDefaults）の引き継ぎ。
/// 古いドメインにある値を、新しいドメインにまだない鍵についてだけ写す。一度済ませたら二度としない。
/// App Sandbox ではほかのドメインを読めないので、何も写らない（直接配布版のための処理）
public enum SettingsMigration {
    /// 以前の Bundle ID（0.4.0 まで）
    public static let legacyDomains = ["dev.hashrock.nanodot"]
    static let doneKey = "settingsMigratedFrom"

    /// 写した鍵の数を返す。済んでいれば（写すものがなくても）0
    @discardableResult
    public static func run(into defaults: UserDefaults = .standard, from domains: [String] = legacyDomains,
                           currentDomain: String? = Bundle.main.bundleIdentifier) -> Int {
        guard defaults.object(forKey: doneKey) == nil else { return 0 }
        var copied = 0
        // 新しいドメインにすでにある値は上書きしない（persistentDomain はこのアプリのドメインだけを見る。登録済みの既定値やグローバルは含まない）
        var existing = Set(currentDomain.flatMap { defaults.persistentDomain(forName: $0) }?.keys.map { $0 } ?? [])
        for domain in domains where domain != currentDomain {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where !existing.contains(key) {
                defaults.set(value, forKey: key)
                existing.insert(key)
                copied += 1
            }
        }
        defaults.set(domains, forKey: doneKey)
        return copied
    }
}
