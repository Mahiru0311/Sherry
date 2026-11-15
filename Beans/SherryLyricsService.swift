import Foundation

/// 歌词唯一入口：缓存优先 → 酷狗匿名（+ 备用端点）→ 酷我跨源 → LRCLIB 兜底，全部带日志。
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
        SherryLyricsCache.shared.store(document: doc, key: key, identityKey: song.identityKey)
        CoLogger.shared.log("歌词缓存迁移：\(song.name) 旧 UserDefaults 缓存已搬进磁盘缓存", level: .debug)
        return finalize(lines: lines, timing: doc.timing)
    }

    /// 播放器与 PlayerView 共用的唯一歌词入口。
    /// isPrefetch = true（下一首预取）时失败不写负缓存：预取只是提前
    /// 试一次，不能让一次提前失败拦住用户真正播放这首歌时的请求（P0-2）。
    func lyrics(for song: Song, isPrefetch: Bool = false) async -> [LyricLine] {
        let key = Self.cacheKey(for: song)
        if let cached = Self.cachedLinesSync(for: song) {
            return cached
        }
        if let task = inFlight[key] {
            CoLogger.shared.log("歌词在途去重：\(song.name) 复用进行中的请求", level: .debug)
            return await task.value
        }
        let task = Task { await self.fetchAndCache(song: song, key: key, isPrefetch: isPrefetch) }
        inFlight[key] = task
        let lines = await task.value
        inFlight[key] = nil
        return lines
    }

    /// 下一首预取：与音频预取同一批触发，走同一条 lyrics(for:)（含去重与缓存）。
    func prefetch(for song: Song) async {
        _ = await lyrics(for: song, isPrefetch: true)
    }

    /// 手动重试：清掉这首歌的全部缓存（含负缓存），重新走网络抓一次。
    /// 供“暂无歌词”里的重试按钮用；正在进行的请求会被复用，不重复发。
    /// 按 song.identityKey 清：缓存键含专辑/时长桶/版本词，元数据稍一漂移
    /// 键就变，单键删除清不掉旧条目（P0-2）。
    func retryLyrics(for song: Song) async -> [LyricLine] {
        let key = Self.cacheKey(for: song)
        cache.removeAll(forIdentityKey: song.identityKey)
        cache.remove(key: key)
        CoLogger.shared.log("歌词手动重试：\(song.name) 已清除缓存，重新抓取", level: .info)
        return await lyrics(for: song)
    }

    // MARK: - 抓取链路

    private func fetchAndCache(song: Song, key: String, isPrefetch: Bool = false) async -> [LyricLine] {
        let durationMs = song.duration > 0 ? Int((song.duration * 1000).rounded()) : nil
        CoLogger.shared.log(
            "歌词抓取开始：\(song.name) - \(song.artists) 时长=\(durationMs.map { "\($0)ms" } ?? "-")",
            level: .info
        )
        // 1) 酷狗匿名：先按标题基础匹配过滤，再取前 5 个下正文（并行）。
        // 旧版先取前 5 再过滤：标题不对的前 5 个会挤掉后面真正匹配的候选（P1-2）。
        let candidates = await SherryKugouLyrics.search(
            title: song.name, artists: [song.artists], album: song.album.isEmpty ? nil : song.album,
            durationMs: durationMs
        )
        var best: (document: SherryLyricDocument, evaluation: SherryLyricMatchEvaluation)?
        if !candidates.isEmpty {
            let scored = candidates.map { candidate in
                (candidate, SherryLyricMatchEvaluation.evaluate(
                    wantedTitle: song.name, wantedArtists: [song.artists],
                    wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                    candidateTitle: candidate.title, candidateArtists: candidate.artists,
                    candidateAlbum: candidate.album, candidateDurationMs: candidate.durationMs,
                    isWordSynced: candidate.hasKRC
                ))
            }.sorted { lhs, rhs in
                lhs.1 == rhs.1 ? false : lhs.1 < rhs.1
            }
            let eligible = scored.filter { $0.1.baseTitleMatches }
            if eligible.isEmpty {
                CoLogger.shared.log("歌词候选弃用：酷狗 \(candidates.count) 个候选标题均不匹配：\(song.name)", level: .debug)
            }
            // 前 5 个候选并行下载正文（旧版串行：3 个候选最坏多等 2 倍下载
            // 时间，首屏歌词来得更晚）。TaskGroup 内不写共享状态，只返回
            // 结果，收齐后再挑最优。
            let downloaded = await withTaskGroup(of: (SherryLyricDocument, SherryLyricMatchEvaluation)?.self) { group in
                for (candidate, _) in eligible.prefix(5) {
                    group.addTask {
                        guard let doc = await SherryKugouLyrics.document(for: candidate, wantedDurationMs: durationMs),
                              !doc.lines.isEmpty else { return nil }
                        let evaluation = SherryLyricMatchEvaluation.evaluate(
                            wantedTitle: song.name, wantedArtists: [song.artists],
                            wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                            candidateTitle: doc.title ?? candidate.title,
                            candidateArtists: doc.artists.isEmpty ? candidate.artists : doc.artists,
                            candidateAlbum: doc.album ?? candidate.album,
                            candidateDurationMs: doc.durationMs ?? candidate.durationMs,
                            isWordSynced: doc.isWordSynced
                        )
                        return (doc, evaluation)
                    }
                }
                var collected: [(SherryLyricDocument, SherryLyricMatchEvaluation)] = []
                for await item in group {
                    if let item { collected.append(item) }
                }
                return collected
            }
            for (doc, evaluation) in downloaded {
                CoLogger.shared.log(
                    "歌词候选：酷狗 标题=\(doc.title ?? song.name) 歌手=\(doc.artists.joined(separator: "/")) 时长差=\(evaluation.durationErrorMs == .max ? -1 : evaluation.durationErrorMs)ms 逐字=\(evaluation.isWordSynced ? "是" : "否") 标题匹配=\(evaluation.titleMatches ? "是" : "否")",
                    level: .debug
                )
                if best == nil || evaluation < best!.evaluation {
                    best = (doc, evaluation)
                }
            }
            if let best, best.evaluation.baseTitleMatches {
                return accept(document: best.document, evaluation: best.evaluation, song: song, key: key)
            }
            if let best {
                CoLogger.shared.log("歌词候选弃用：酷狗最佳候选标题不匹配：\(song.name)", level: .debug)
            } else {
                CoLogger.shared.log("歌词候选为空：酷狗 \(candidates.count) 个候选均未取到正文", level: .debug)
            }
        } else {
            CoLogger.shared.log("歌词搜索无候选：酷狗 \(song.name)", level: .debug)
            // 1b) 酷狗备用端点：主搜索 0 候选（常是限流）时直接取 LRC 正文。
            if let doc = await SherryKugouLyrics.backupDocument(
                title: song.name, artists: [song.artists], durationMs: durationMs
            ), !doc.lines.isEmpty {
                let evaluation = SherryLyricMatchEvaluation.evaluate(
                    wantedTitle: song.name, wantedArtists: [song.artists],
                    wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                    candidateTitle: doc.title ?? song.name,
                    candidateArtists: doc.artists.isEmpty ? [song.artists] : doc.artists,
                    candidateAlbum: doc.album, candidateDurationMs: doc.durationMs,
                    isWordSynced: doc.isWordSynced
                )
                if evaluation.baseTitleMatches {
                    return accept(document: doc, evaluation: evaluation, song: song, key: key)
                }
                CoLogger.shared.log("歌词候选弃用：酷狗备用端点标题不匹配：\(song.name)", level: .debug)
            }
        }
        // 2) 酷我跨源兜底（LX Music 机制移植）：搜"歌名 歌手" → 数字 rid →
        // 二进制歌词解码；单源失败只记日志，继续下一源。
        if let doc = await SherryKuwoLyrics.fetchLyrics(
            title: song.name, artist: song.artists, durationMs: durationMs
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
        // 3) LRCLIB 兜底：/api/get（带/不带专辑）→ /api/search（带/不带歌手）。
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
        // 4) 全部源都无结果：只写 5 分钟负缓存（P0-2 + 限流语义 D）。
        // 搜不到任何候选（限流 / 超时 / 断网）是暂时失败；候选下载后被
        // 匹配否决也只拦 5 分钟——一次限流/误否不能让一堆歌一整天没歌词。
        // 预取失败不写负缓存：只是提前试一次，真正播放时再查（P0-2）。
        if isPrefetch {
            CoLogger.shared.log("歌词无结果（预取，不写负缓存）：\(song.name) - \(song.artists)", level: .info)
            return []
        }
        cache.storeNegative(key: key, transient: true, identityKey: song.identityKey)
        CoLogger.shared.log("歌词无结果：\(song.name) - \(song.artists)（已写负缓存 5 分钟）", level: .info)
        return []
    }

    private func accept(
        document: SherryLyricDocument,
        evaluation: SherryLyricMatchEvaluation,
        song: Song,
        key: String
    ) -> [LyricLine] {
        cache.store(document: document, key: key, identityKey: song.identityKey)
        CoLogger.shared.log(
            "歌词已选：\(song.name) 来源=\(document.source.rawValue) 标题匹配=\(evaluation.titleMatches ? "是" : "否") 歌手匹配=\(evaluation.artistsMatch ? "是" : "否") 时长差=\(evaluation.durationErrorMs == .max ? -1 : evaluation.durationErrorMs)ms 逐字=\(evaluation.isWordSynced ? "是" : "否") 行数=\(document.lines.count)",
            level: .info
        )
        return Self.finalize(lines: document.lines, timing: document.timing)
    }
}
