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
    /// 2.2.3：3 → 4：2.2.2 的酷我缓存条目 rawLRC 带逐字标签
    /// （<3780,-3780>…），升版后全部失效，不再命中。
    static let formatVersion = 4
    /// 选择算法版本：匹配规则一变就 +1，旧的"赢家"不能再绕过新匹配器。
    /// 2.2.2：1 → 2：2.2.0 的 24h 负缓存条目没有 transientNegative 字段，
    /// 在 2.2.1 里按 24h 解码（缓存投毒跨版本残留），升版后全部失效。
    static let selectionAlgorithmVersion = 2

    private struct Entry: Codable {
        let lrc: String
        let krc: String?
        let source: String
        let timing: String
        let isNegative: Bool
        /// 暂时的负缓存（网络错 / 搜索被限流 / 两边都没返回数据）：只拦 5 分钟。
        /// 老文件没有这个字段时按 false 解码，不会让旧缓存失效。
        let transientNegative: Bool?
        let savedAt: Date
    }

    private static let maxAge: TimeInterval = 30 * 24 * 3600
    private static let notFoundMaxAge: TimeInterval = 24 * 3600
    /// 暂时的失败（限流、超时、断网）只拦 5 分钟：2.2.1 之前一律写 24 小时，
    /// 一次被限流就让一堆歌一整天没歌词。
    private static let transientNotFoundMaxAge: TimeInterval = 5 * 60

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
        let limit: TimeInterval
        if entry.isNegative {
            limit = (entry.transientNegative ?? false) ? Self.transientNotFoundMaxAge : Self.notFoundMaxAge
        } else {
            limit = Self.maxAge
        }
        guard age >= 0, age < limit else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return (entry.lrc, entry.krc, entry.source, entry.timing, entry.isNegative)
    }

    /// 正缓存：只存非空文档。
    func store(document: SherryLyricDocument, key: String, identityKey: String? = nil) {
        guard !document.lines.isEmpty, !document.rawLRC.isEmpty else { return }
        let entry = Entry(
            lrc: document.rawLRC,
            krc: document.rawKRC,
            source: document.source.rawValue,
            timing: document.timing.rawValue,
            isNegative: false,
            transientNegative: false,
            savedAt: Date()
        )
        store(entry: entry, key: key)
        recordKey(key, forIdentityKey: identityKey)
    }

    /// 负缓存：这首歌两个源都查不到，24 小时内不再请求。
    /// transient = true 时只拦 5 分钟（限流 / 超时 / 断网等暂时失败，
    /// 不是“确实没歌词”，不能按 24 小时算）。
    /// 2.2.2：候选下载后被匹配否决也只写 5 分钟（见 Service），24h
    /// 只保留给明确确认无歌词的调用方；当前链路不再写 24h。
    func storeNegative(key: String, transient: Bool = false, identityKey: String? = nil) {
        let entry = Entry(
            lrc: "", krc: nil, source: "", timing: "",
            isNegative: true, transientNegative: transient, savedAt: Date()
        )
        store(entry: entry, key: key)
        recordKey(key, forIdentityKey: identityKey)
    }

    func remove(key: String) {
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    /// 按歌曲身份清除全部缓存条目：缓存键里含专辑/时长桶/版本词，
    /// 元数据稍一漂移键就变，单键删除清不掉旧条目；重试必须按
    /// song.identityKey 清（P0-2）。
    func removeAll(forIdentityKey identityKey: String) {
        let defaultsKey = Self.indexDefaultsKey(for: identityKey)
        let keys = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        for key in keys {
            try? fileManager.removeItem(at: fileURL(for: key))
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// 记下某首歌写过哪些缓存键（UserDefaults 索引，上限 8 个），
    /// 供 removeAll(forIdentityKey:) 用；索引本身不含歌词内容。
    private func recordKey(_ key: String, forIdentityKey identityKey: String?) {
        guard let identityKey, !identityKey.isEmpty else { return }
        let defaultsKey = Self.indexDefaultsKey(for: identityKey)
        var keys = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        keys.removeAll { $0 == key }
        keys.append(key)
        if keys.count > 8 { keys.removeFirst(keys.count - 8) }
        UserDefaults.standard.set(keys, forKey: defaultsKey)
    }

    private static func indexDefaultsKey(for identityKey: String) -> String {
        "co.lyrics.cache.keys." + identityKey
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
