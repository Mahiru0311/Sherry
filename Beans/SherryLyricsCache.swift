import CryptoKit
import Foundation

/// 歌词磁盘缓存：Caches/SherryLyricsCache 下的 JSON 文件，文件名是键的 SHA256。
///
/// 键 = lyrics-v<格式版本>|selection-v<算法版本>|<需求>|<曲目签名>，
/// 算法一变旧缓存自动失效，不用等 30 天过期。
/// 机制参考 LyricsIsland (MIT) 的 LyricsCache，按 Sherry 的文档模型改写。
/// 与旧版的区别（R3/R5）：
/// - 正缓存 30 天、负缓存（查不到）24 小时，失败会收敛，不再每播必查；
/// - 0 行的结果绝不写正缓存（旧版把空解析写进缓存造成缓存投毒）；
/// - 版本校验不再用 LRCLIB 行级歌词覆盖逐字歌词 —— 覆盖只发生在新抓到的
///   文档整体评价更好时，由 SherryLyricsService 决定。
final class SherryLyricsCache {
    static let shared = SherryLyricsCache()

    /// 磁盘文档格式版本：解析/存储形状一变就 +1，旧文件自然失效。
    static let formatVersion = 3
    /// 选择算法版本：匹配规则一变就 +1，旧的"赢家"不能再绕过新匹配器。
    static let selectionAlgorithmVersion = 1

    private struct Entry: Codable {
        let lrc: String
        let krc: String?
        let source: String
        let timing: String
        let isNegative: Bool
        let savedAt: Date
    }

    private static let maxAge: TimeInterval = 30 * 24 * 3600
    private static let notFoundMaxAge: TimeInterval = 24 * 3600

    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SherryLyricsCache", isDirectory: true)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    static func key(
        trackSignature: String,
        need: String = "none"
    ) -> String {
        "lyrics-v\(formatVersion)|selection-v\(selectionAlgorithmVersion)|\(need)|\(trackSignature)"
    }

    /// 命中返回原始文本（调用方再解析）；未命中 / 过期返回 nil。
    /// 返回 (lrc, krc, source, timing, isNegative)。
    func lookup(key: String) -> (lrc: String, krc: String?, source: String, timing: String, isNegative: Bool)? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        let age = Date().timeIntervalSince(entry.savedAt)
        let limit = entry.isNegative ? Self.notFoundMaxAge : Self.maxAge
        guard age >= 0, age < limit else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return (entry.lrc, entry.krc, entry.source, entry.timing, entry.isNegative)
    }

    /// 正缓存：只存非空文档。
    func store(document: SherryLyricDocument, key: String) {
        guard !document.lines.isEmpty, !document.rawLRC.isEmpty else { return }
        let entry = Entry(
            lrc: document.rawLRC,
            krc: document.rawKRC,
            source: document.source.rawValue,
            timing: document.timing.rawValue,
            isNegative: false,
            savedAt: Date()
        )
        store(entry: entry, key: key)
    }

    /// 负缓存：这首歌两个源都查不到，24 小时内不再请求。
    func storeNegative(key: String) {
        let entry = Entry(
            lrc: "", krc: nil, source: "", timing: "",
            isNegative: true, savedAt: Date()
        )
        store(entry: entry, key: key)
    }

    func remove(key: String) {
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    func clear() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func store(entry: Entry, key: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
}
