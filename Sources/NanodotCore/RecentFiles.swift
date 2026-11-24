import Foundation

/// 最近開いた書類の 1 件（iPad 版が UserDefaults に持つ。Mac 版は NSDocumentController の標準の記録を使う）
public struct RecentFile: Codable, Hashable, Sendable {
    /// 記録したときの場所（重なりの判定と、見つからないときの表示に使う）
    public var path: String
    /// ファイルの場所のブックマーク。外の場所（ファイル App で選んだ場所）を開き直すためのアクセス権も入る
    public var bookmark: Data?
    /// アプリの書類フォルダーの中なら、そこからの相対パス（入れ直すと container の場所が変わるので、こちらでも探す）
    public var relativePath: String?

    public init(path: String, bookmark: Data? = nil, relativePath: String? = nil) {
        self.path = path
        self.bookmark = bookmark
        self.relativePath = relativePath
    }

    public var name: String { (path as NSString).lastPathComponent }
    /// 入っているフォルダーの名前
    public var folderName: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

/// 最近開いた書類の一覧（新しい順、重なりなし、上限つき）。端末の中だけに保存する（iCloud では同期しない）
public struct RecentFileList: Codable, Hashable, Sendable {
    public static let limit = 10
    public private(set) var items: [RecentFile] = []

    public init(items: [RecentFile] = []) {
        self.items = Array(items.prefix(Self.limit))
    }

    /// 先頭に足す（同じ場所のものは前のを消す）
    public mutating func add(_ f: RecentFile) {
        items.removeAll { $0.path == f.path }
        items.insert(f, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(path: String) {
        items.removeAll { $0.path == path }
    }

    public mutating func clear() { items.removeAll() }

    public var isEmpty: Bool { items.isEmpty }

    // MARK: - 保存（UserDefaults の Data）

    public static func decode(_ data: Data?) -> RecentFileList {
        guard let data, let l = try? JSONDecoder().decode(RecentFileList.self, from: data) else { return RecentFileList() }
        return RecentFileList(items: l.items)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
