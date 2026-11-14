import Foundation

/// 歌词唯一入口：缓存优先 → 酷狗匿名 → LRCLIB 兜底，全部带日志。
///
/// 替换掉旧的 PlayerManager.fetchLyrics + KugouMusicAPI.lyricPayload +
/// lyricByKeyword + fetchLyricsFromLRCLIB（R1–R5 的根因都在那几处）：
/// - R1：匿名链无 token、18s 超时、失败静默 —— 现在 15s 超时、每次搜索/
///   下载/解码/选择都记日志，音频与歌词并行但歌词不再"静默失败"；
/// - R2：candidates.first 不校验 —— 现在字典序匹配（标题→歌手→专辑→
///   时长 ±3s→逐字），标题不匹配的候选直接不要；
/// - R3：KRC 解码失败重下 LRC 丢逐字、0 行缓存投毒 —— 解码失败只记日志
///   并走 LRC，0 行结果绝不写正缓存；
/// - R4：预取与 PlayerView 各发一组请求 —— 在途去重，同一首歌同时只
///   有一组搜索+下载在跑；
/// - R5：版本校验用行级歌词覆盖逐字歌词 14 天 —— 没有"版本校验"覆盖了，
///   只有新抓到的文档整体更好时才替换（且只替换内存与缓存的同一份）。
actor SherryLyricsService {
    static let shared = SherryLyricsService()

    private struct LegacyCacheEntry: Decodable {
        let lyric: String
        let translation: String?
        let wordTiming: String?
        let wordFormat: String?
        let savedAt: Date
    }

    private let cache = SherryLyricsCache.shared
    private var inFlight: [String: Task<[LyricLine], Never>] = [:]

    /// 歌词缓存键（与旧版不同：新键含归一化签名 + 算法版本）。
    /// static：不带 actor 隔离，供 PlayerManager.cachedLyrics 同步调用。
    static func cacheKey(for song: Song) -> String {
        SherryLyricsCache.key(trackSignature: SherryLyricsMatcher.signature(
            title: song.name,
            artist: song.artists,
            durationMs: song.duration > 0 ? Int((song.duration * 1000).rounded()) : nil,
            album: song.album.isEmpty ? nil : song.album
        ))
    }

    /// 同步读缓存（磁盘 + 旧 UserDefaults 迁移），不发网。
    /// nonisolated：磁盘读与解析都不需要 actor 隔离，供 PlayerView 先渲染用。
    /// 返回 nil = 未命中（需要再调 lyrics(for:)）；返回 [] = 已知无歌词。
    static func cachedLinesSync(for song: Song) -> [LyricLine]? {
        let key = cacheKey(for: song)
        let cache = SherryLyricsCache.shared
        if let hit = cache.lookup(key: key) {
            if hit.isNegative {
                CoLogger.shared.log("歌词缓存命中（负缓存）：\(song.name)", level: .debug)
                return []
            }
            let lines = parseCached(lrc: hit.lrc, krc: hit.krc)
            if !lines.isEmpty {
                CoLogger.shared.log("歌词缓存命中：\(song.name) 来源=\(hit.source) 行数=\(lines.count)", level: .debug)
                return finalize(lines: lines, timing: SherryLyricDocument.Timing(rawValue: hit.timing) ?? .synced)
            }
            // 磁盘里有条目但解析出 0 行：当作投毒条目删掉，重新走网络。
            CoLogger.shared.log("歌词缓存投毒：\(song.name) 磁盘条目解析 0 行，已删除", level: .debug)
            cache.remove(key: key)
        }
        // 一次性迁移：旧版 UserDefaults 缓存（co.lyrics.cache.v1.*，14 天）里
        // 的有效条目搬进磁盘缓存，老用户升级后已缓存的歌词不用重新请求。
        if let lines = migrateLegacyCache(for: song, key: key) {
            return lines
        }
        return nil
    }

    /// 行级歌词（只有 LRC、无逐字）合成逐字扫掠，让高亮能逐词走；
    /// 逐字歌词与无时间轴的纯文本不合成。
    static func finalize(lines: [LyricLine], timing: SherryLyricDocument.Timing) -> [LyricLine] {
        guard timing == .synced, !lines.contains(where: { $0.hasWordTimings }) else {
            return lines
        }
        CoLogger.shared.log("歌词逐字合成：行级歌词 \(lines.count) 行已合成逐字扫掠", level: .debug)
        return LyricParser.withSynthesizedWords(lines)
    }

    private static func parseCached(lrc: String, krc: String?) -> [LyricLine] {
        if let krc, !krc.isEmpty {
            return LyricParser.parse(lrc, wordRaw: krc, wordFormat: .kugouKRC)
        }
        return LyricParser.parse(lrc)
    }

    private static func migrateLegacyCache(for song: Song, key: String) -> [LyricLine]? {
        let legacyKey = "kugou:\(song.kugouHash ?? song.identityKey)"
        let safeKey = legacyKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? legacyKey
        guard let data = UserDefaults.standard.data(forKey: "co.lyrics.cache.v1." + safeKey),
              let entry = try? JSONDecoder().decode(LegacyCacheEntry.self, from: data),
              Date().timeIntervalSince(entry.savedAt) < 14 * 24 * 3600,
              !entry.lyric.isEmpty else {
            return nil
        }
        let lines: [LyricLine]
        if let wordTiming = entry.wordTiming, entry.wordFormat == "kugouKRC" {
            lines = LyricParser.parse(entry.lyric, translationRaw: entry.translation, wordRaw: wordTiming, wordFormat: .kugouKRC)
        } else {
            lines = LyricParser.parse(entry.lyric, translationRaw: entry.translation)
        }
        guard !lines.isEmpty else { return nil }
        let doc = SherryLyricDocument(
            source: .kugou, timing: lines.contains { $0.hasWordTimings } ? .wordSynced : .synced,
            lines: lines, title: song.name, artists: [song.artists],
            album: song.album.isEmpty ? nil : song.album,
            durationMs: song.duration > 0 ? Int((song.duration * 1000).rounded()) : nil,
            rawLRC: entry.lyric, rawKRC: entry.wordTiming
        )
        SherryLyricsCache.shared.store(document: doc, key: key)
        CoLogger.shared.log("歌词缓存迁移：\(song.name) 旧 UserDefaults 缓存已搬进磁盘缓存", level: .debug)
        return finalize(lines: lines, timing: doc.timing)
    }

    /// 播放器与 PlayerView 共用的唯一歌词入口。
    func lyrics(for song: Song) async -> [LyricLine] {
        let key = Self.cacheKey(for: song)
        if let cached = Self.cachedLinesSync(for: song) {
            return cached
        }
        if let task = inFlight[key] {
            CoLogger.shared.log("歌词在途去重：\(song.name) 复用进行中的请求", level: .debug)
            return await task.value
        }
        let task = Task { await self.fetchAndCache(song: song, key: key) }
        inFlight[key] = task
        let lines = await task.value
        inFlight[key] = nil
        return lines
    }

    /// 下一首预取：与音频预取同一批触发，走同一条 lyrics(for:)（含去重与缓存）。
    func prefetch(for song: Song) async {
        _ = await lyrics(for: song)
    }

    // MARK: - 抓取链路

    private func fetchAndCache(song: Song, key: String) async -> [LyricLine] {
        let durationMs = song.duration > 0 ? Int((song.duration * 1000).rounded()) : nil
        CoLogger.shared.log(
            "歌词抓取开始：\(song.name) - \(song.artists) 时长=\(durationMs.map { "\($0)ms" } ?? "-")",
            level: .info
        )
        // 1) 酷狗匿名：元数据排序后只取前 3 个下正文（lazy）。
        let candidates = await SherryKugouLyrics.search(
            title: song.name, artists: [song.artists], album: song.album.isEmpty ? nil : song.album,
            durationMs: durationMs
        )
        var best: (document: SherryLyricDocument, evaluation: SherryLyricMatchEvaluation)?
        if !candidates.isEmpty {
            let ranked = candidates.sorted { lhs, rhs in
                let left = SherryLyricMatchEvaluation.evaluate(
                    wantedTitle: song.name, wantedArtists: [song.artists],
                    wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                    candidateTitle: lhs.title, candidateArtists: lhs.artists,
                    candidateAlbum: lhs.album, candidateDurationMs: lhs.durationMs, isWordSynced: lhs.hasKRC
                )
                let right = SherryLyricMatchEvaluation.evaluate(
                    wantedTitle: song.name, wantedArtists: [song.artists],
                    wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                    candidateTitle: rhs.title, candidateArtists: rhs.artists,
                    candidateAlbum: rhs.album, candidateDurationMs: rhs.durationMs, isWordSynced: rhs.hasKRC
                )
                return left == right ? false : left < right
            }
            for candidate in ranked.prefix(3) {
                guard let doc = await SherryKugouLyrics.document(for: candidate, wantedDurationMs: durationMs),
                      !doc.lines.isEmpty else { continue }
                let evaluation = SherryLyricMatchEvaluation.evaluate(
                    wantedTitle: song.name, wantedArtists: [song.artists],
                    wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                    candidateTitle: doc.title ?? candidate.title,
                    candidateArtists: doc.artists.isEmpty ? candidate.artists : doc.artists,
                    candidateAlbum: doc.album ?? candidate.album,
                    candidateDurationMs: doc.durationMs ?? candidate.durationMs,
                    isWordSynced: doc.isWordSynced
                )
                CoLogger.shared.log(
                    "歌词候选：酷狗 id=\(candidate.id) 标题=\(doc.title ?? candidate.title) 歌手=\(doc.artists.joined(separator: "/")) 时长差=\(evaluation.durationErrorMs == .max ? -1 : evaluation.durationErrorMs)ms 逐字=\(evaluation.isWordSynced ? "是" : "否") 标题匹配=\(evaluation.titleMatches ? "是" : "否")",
                    level: .debug
                )
                if best == nil || evaluation < best!.evaluation {
                    best = (doc, evaluation)
                }
                if evaluation.isPerfect { break }
            }
            if let best, best.evaluation.titleMatches {
                return accept(document: best.document, evaluation: best.evaluation, song: song, key: key)
            }
            if let best {
                CoLogger.shared.log("歌词候选弃用：酷狗最佳候选标题不匹配：\(song.name)", level: .debug)
            } else {
                CoLogger.shared.log("歌词候选为空：酷狗 \(candidates.count) 个候选均未取到正文", level: .debug)
            }
        } else {
            CoLogger.shared.log("歌词搜索无候选：酷狗 \(song.name)", level: .debug)
        }
        // 2) LRCLIB 兜底：/api/get（带/不带专辑）→ /api/search。
        if let doc = await SherryLRCLIB.fetchLyrics(
            title: song.name, artist: song.artists,
            album: song.album.isEmpty ? nil : song.album, durationMs: durationMs
        ), !doc.lines.isEmpty {
            let evaluation = SherryLyricMatchEvaluation.evaluate(
                wantedTitle: song.name, wantedArtists: [song.artists],
                wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                candidateTitle: doc.title ?? song.name,
                candidateArtists: doc.artists.isEmpty ? [song.artists] : doc.artists,
                candidateAlbum: doc.album, candidateDurationMs: doc.durationMs,
                isWordSynced: doc.isWordSynced
            )
            return accept(document: doc, evaluation: evaluation, song: song, key: key)
        }
        // 3) 两个源都无结果：写负缓存，24 小时内不再请求。
        cache.storeNegative(key: key)
        CoLogger.shared.log("歌词无结果：\(song.name) - \(song.artists)（已写负缓存 24h）", level: .info)
        return []
    }

    private func accept(
        document: SherryLyricDocument,
        evaluation: SherryLyricMatchEvaluation,
        song: Song,
        key: String
    ) -> [LyricLine] {
        cache.store(document: document, key: key)
        CoLogger.shared.log(
            "歌词已选：\(song.name) 来源=\(document.source.rawValue) 标题匹配=\(evaluation.titleMatches ? "是" : "否") 歌手匹配=\(evaluation.artistsMatch ? "是" : "否") 时长差=\(evaluation.durationErrorMs == .max ? -1 : evaluation.durationErrorMs)ms 逐字=\(evaluation.isWordSynced ? "是" : "否") 行数=\(document.lines.count)",
            level: .info
        )
        return Self.finalize(lines: document.lines, timing: document.timing)
    }
}
