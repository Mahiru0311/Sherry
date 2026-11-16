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
    /// 2.2.4：缓存条目也要过覆盖率门 —— 2.2.3 及之前已把错版歌词（如
    /// 189s 的慌啥子嘛）写进缓存，不过门就删条目、重新走网络，不再
    /// 把错版歌词当命中返回。
    /// 2.2.6 F3：复检不符不再删条目 —— 删了之后若重抓失败，好歌词就没了；
    /// 旧条目留着，重抓成功时 store() 覆盖、失败时负缓存也不覆盖它
    /// （见 fetchAndCache 收尾的 hasKeptPositiveEntry 守卫）。
    static func cachedLinesSync(for song: Song, cache: SherryLyricsCache = .shared) -> [LyricLine]? {
        let key = cacheKey(for: song)
        let audioDurationMs = song.duration > 0 ? Int((song.duration * 1000).rounded()) : nil
        if let hit = cache.lookup(key: key) {
            if hit.isNegative {
                CoLogger.shared.log("歌词结果：\(song.name) 分类=负缓存命中 时长=\(audioDurationMs.map { "\($0)ms" } ?? "-")", level: .debug)
                return []
            }
            let lines = parseCached(lrc: hit.lrc, krc: hit.krc, source: hit.source)
            if !lines.isEmpty {
                if SherryLyricsMatcher.coverageRejects(lines: lines, audioDurationMs: audioDurationMs) {
                    CoLogger.shared.log("歌词缓存过期：\(song.name) 缓存歌词覆盖率不符音频时长，保留旧条目重抓", level: .info)
                } else {
                    CoLogger.shared.log("歌词缓存命中：\(song.name) 来源=\(hit.source) 行数=\(lines.count)", level: .debug)
                    return finalize(lines: lines, timing: SherryLyricDocument.Timing(rawValue: hit.timing) ?? .synced)
                }
            } else {
                // 磁盘里有条目但解析出 0 行：当作投毒条目删掉，重新走网络。
                CoLogger.shared.log("歌词缓存投毒：\(song.name) 磁盘条目解析 0 行，已删除", level: .debug)
                cache.remove(key: key)
            }
        }
        // 一次性迁移：旧版 UserDefaults 缓存（co.lyrics.cache.v1.*，14 天）里
        // 的有效条目搬进磁盘缓存，老用户升级后已缓存的歌词不用重新请求。
        if let lines = migrateLegacyCache(for: song, key: key) {
            return lines
        }
        return nil
    }

    /// 2.2.4：行级歌词不再合成假逐字扫掠 —— 用户规则：没有逐字时间
    /// 就干净地按行级显示，绝不伪造词时间。逐字文档原样返回；
    /// LyricParser.withSynthesizedWords 保留给单测，不再参与链路。
    static func finalize(lines: [LyricLine], timing: SherryLyricDocument.Timing) -> [LyricLine] {
        lines
    }

    /// 缓存重载按来源分发（2.2.3）：酷我条目的 lrc 是去标签的行级文本、
    /// krc 是带 <起,长> 标签的逐字原文，走 .kuwo 分支合并逐字时间；
    /// 酷狗 KRC 条目走 .kugouKRC；其余（酷狗备用端点 / LRCLIB）走纯 LRC，
    /// parseCore 的去标签防线兜底。2.2.2 的毒缓存靠 formatVersion 4 失效。
    static func parseCached(lrc: String, krc: String?, source: String) -> [LyricLine] {
        if source == SherryLyricDocument.Source.kuwo.rawValue, let krc, !krc.isEmpty {
            return LyricParser.parse(lrc, wordRaw: krc, wordFormat: .kuwo)
        }
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
        // 2.2.4：迁移的旧缓存同样过覆盖率门，错版歌词不搬进新缓存。
        let audioDurationMs = song.duration > 0 ? Int((song.duration * 1000).rounded()) : nil
        if SherryLyricsMatcher.coverageRejects(lines: lines, audioDurationMs: audioDurationMs) {
            CoLogger.shared.log("歌词缓存迁移跳过：\(song.name) 旧缓存歌词覆盖率不符音频时长", level: .info)
            return nil
        }
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

    /// 2.2.6 F5：抓取结果分类（日志里的 `分类=` 取值，供单测的纯函数）。
    enum LyricsFetchOutcome: String {
        case selected = "已选"
        case gateRejectedAll = "全部拒收"
        case noCandidates = "无候选"
        case networkFailure = "网络失败"
    }

    /// 负缓存写不写（2.2.6 F1/F3，供单测的纯函数）。
    enum NegativeCacheDecision {
        case skip
        case transient
    }

    /// 2.2.6：结果分类只看“拿到过什么”，不猜原因 ——
    /// 候选一个都没拿到 = 全源网络层失败；拿到候选但没下到正文 = 无候选；
    /// 下到正文但全被拒收门拦掉 = 全部拒收；有 survivors = 已选。
    static func classifyOutcome(hasSurvivors: Bool, sawCandidate: Bool, sawDocument: Bool) -> LyricsFetchOutcome {
        if hasSurvivors { return .selected }
        if !sawCandidate { return .networkFailure }
        if !sawDocument { return .noCandidates }
        return .gateRejectedAll
    }

    /// 2.2.6：5 分钟暂存负缓存只在“确实取到过候选”时写 ——
    /// 网络失败（一个候选都没拿到）不写，一次断网不能黑掉接下来 5 分钟的歌；
    /// 复检保留下来的旧正缓存条目还在时不写，不能用负缓存覆盖好歌词（F3）。
    static func negativeCacheDecision(outcome: LyricsFetchOutcome, hasKeptPositiveEntry: Bool) -> NegativeCacheDecision {
        if outcome == .networkFailure || hasKeptPositiveEntry { return .skip }
        return .transient
    }

    private func fetchAndCache(song: Song, key: String, isPrefetch: Bool = false) async -> [LyricLine] {
        let durationMs = song.duration > 0 ? Int((song.duration * 1000).rounded()) : nil
        CoLogger.shared.log(
            "歌词抓取开始：\(song.name) - \(song.artists) 时长=\(durationMs.map { "\($0)ms" } ?? "-")",
            level: .info
        )
        // 2.2.4：不再“首源命中即返回”—— 各源过拒收门的正文都进候选池，
        // 最后由三角测量定夺（离群源只有多源比对才能发现；错版/片段歌词
        // 被拒收后由下一源顶上，全部拒收则诚实降级为无歌词）。
        var survivors: [SherryLyricDocument] = []
        // 2.2.6 F1/F5：只记“拿到过什么”，收尾时再分类 ——
        // sawCandidate = 任一源返回过候选/文档；sawDocument = 任一源下到过正文。
        var sawCandidate = false
        var sawDocument = false
        // 1) 酷狗匿名：先按标题基础匹配过滤，再取前 5 个下正文（并行）。
        // 旧版先取前 5 再过滤：标题不对的前 5 个会挤掉后面真正匹配的候选（P1-2）。
        let candidates = await SherryKugouLyrics.search(
            title: song.name, artists: [song.artists], album: song.album.isEmpty ? nil : song.album,
            durationMs: durationMs
        )
        if !candidates.isEmpty {
            sawCandidate = true
            let first = await kugouSurvivors(candidates: candidates, song: song, audioDurationMs: durationMs)
            sawDocument = sawDocument || first.downloaded > 0
            survivors += first.survivors
            if survivors.isEmpty {
                // 2.2.6 F2(b)：首轮候选全被拒收（常是带时长搜回的短版/错版），
                // 不停在第一组非空候选上 —— 再试不带时长的搜索（剩余关键词组合），
                // 已试过的候选 id 不再重复下载；仍全拒则继续走酷我/LRCLIB。
                // 注意：重试只换搜索参数，拒收门仍用原始音频时长判（传 nil
                // 会让覆盖率/版本门全跳过、碎片反而放行）。
                let retryCandidates = await SherryKugouLyrics.search(
                    title: song.name, artists: [song.artists], album: song.album.isEmpty ? nil : song.album,
                    durationMs: nil
                )
                let fresh = retryCandidates.filter { retry in
                    !candidates.contains { $0.id == retry.id }
                }
                if !fresh.isEmpty {
                    let second = await kugouSurvivors(candidates: fresh, song: song, audioDurationMs: durationMs)
                    sawDocument = sawDocument || second.downloaded > 0
                    survivors += second.survivors
                }
            }
        } else {
            CoLogger.shared.log("歌词搜索无候选：酷狗 \(song.name)", level: .debug)
            // 1b) 酷狗备用端点：主搜索 0 候选（常是限流）时直接取 LRC 正文。
            if let doc = await SherryKugouLyrics.backupDocument(
                title: song.name, artists: [song.artists], durationMs: durationMs
            ), !doc.lines.isEmpty {
                sawCandidate = true
                sawDocument = true
                let evaluation = SherryLyricMatchEvaluation.evaluate(
                    wantedTitle: song.name, wantedArtists: [song.artists],
                    wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                    candidateTitle: doc.title ?? song.name,
                    candidateArtists: doc.artists.isEmpty ? [song.artists] : doc.artists,
                    candidateAlbum: doc.album, candidateDurationMs: doc.durationMs,
                    isWordSynced: doc.isWordSynced
                )
                if evaluation.baseTitleMatches {
                    if let kept = gated(doc, song: song, durationMs: durationMs) {
                        survivors.append(kept)
                    }
                } else {
                    CoLogger.shared.log("歌词候选弃用：酷狗备用端点标题不匹配：\(song.name)", level: .debug)
                }
            }
        }
        // 2) 酷我跨源兜底（LX Music 机制移植）：搜"歌名 歌手" → 数字 rid →
        // 二进制歌词解码；单源失败只记日志，继续下一源。
        // 2.2.6 F2(a)：此处无提前返回 —— 酷狗候选全被拒收也照常走酷我/LRCLIB，
        // 酷我/LRCLIB 在时长未知时同样照常跑（±5s 门只在时长已知时生效）。
        if let doc = await SherryKuwoLyrics.fetchLyrics(
            title: song.name, artist: song.artists, durationMs: durationMs
        ), !doc.lines.isEmpty {
            sawCandidate = true
            sawDocument = true
            if let kept = gated(doc, song: song, durationMs: durationMs) {
                survivors.append(kept)
            }
        }
        // 3) LRCLIB 兜底：/api/get（带/不带专辑）→ /api/search（带/不带歌手）。
        if let doc = await SherryLRCLIB.fetchLyrics(
            title: song.name, artist: song.artists,
            album: song.album.isEmpty ? nil : song.album, durationMs: durationMs
        ), !doc.lines.isEmpty {
            sawCandidate = true
            sawDocument = true
            if let kept = gated(doc, song: song, durationMs: durationMs) {
                survivors.append(kept)
            }
        }
        // 2.2.4 收尾：多源排序 + 固定偏移三角测量；无源通过时诚实降级
        // （无歌词），绝不放错版/片段歌词。
        if !survivors.isEmpty {
            let result = SherryLyricsMatcher.triangulate(documents: survivors, audioDurationMs: durationMs)
            if let outlier = result.outlier {
                CoLogger.shared.log(
                    "歌词三角测量：\(song.name) 离群源=\(outlier.source.rawValue) 修正=\(result.appliedOffsetSeconds.map { String(format: "%+.2fs", $0) } ?? "换源") 选用=\(result.chosen.source.rawValue)",
                    level: .info
                )
            }
            let evaluation = SherryLyricMatchEvaluation.evaluate(
                wantedTitle: song.name, wantedArtists: [song.artists],
                wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: durationMs,
                candidateTitle: result.chosen.title ?? song.name,
                candidateArtists: result.chosen.artists.isEmpty ? [song.artists] : result.chosen.artists,
                candidateAlbum: result.chosen.album, candidateDurationMs: result.chosen.durationMs,
                isWordSynced: result.chosen.isWordSynced
            )
            let lines = accept(
                document: result.chosen, evaluation: evaluation, song: song, key: key,
                cacheable: result.appliedOffsetSeconds == nil
            )
            CoLogger.shared.log("歌词结果：\(song.name) 分类=已选 来源=\(result.chosen.source.rawValue) 时长=\(durationMs.map { "\($0)ms" } ?? "-")", level: .info)
            return lines
        }
        // 4) 全部源都无结果：先分类，再决定负缓存写不写（2.2.6 F1/F3）。
        // 候选已取到但被拒收/无正文 → 只写 5 分钟负缓存（P0-2 + 限流语义 D）；
        // 一个候选都没拿到（断网/限流/超时）→ 不写负缓存，下次播放直接重抓，
        // 一次抖动不能黑掉 5 分钟的歌；复检保留的旧正缓存还在 → 也不写。
        // 预取失败不写负缓存：只是提前试一次，真正播放时再查（P0-2）。
        let outcome = Self.classifyOutcome(hasSurvivors: false, sawCandidate: sawCandidate, sawDocument: sawDocument)
        let durationText = durationMs.map { "\($0)ms" } ?? "-"
        if isPrefetch {
            CoLogger.shared.log("歌词结果：\(song.name) 分类=\(outcome.rawValue)（预取，不写负缓存）时长=\(durationText)", level: .info)
            return []
        }
        let hasKeptPositiveEntry = cache.lookup(key: key)?.isNegative == false
        switch Self.negativeCacheDecision(outcome: outcome, hasKeptPositiveEntry: hasKeptPositiveEntry) {
        case .transient:
            cache.storeNegative(key: key, transient: true, identityKey: song.identityKey)
            CoLogger.shared.log("歌词结果：\(song.name) 分类=\(outcome.rawValue) 时长=\(durationText) 负缓存=5分钟", level: .info)
        case .skip:
            CoLogger.shared.log("歌词结果：\(song.name) 分类=\(outcome.rawValue) 时长=\(durationText) 负缓存=不写", level: .info)
        }
        return []
    }

    /// 2.2.6：酷狗候选下载 + 逐个过拒收门（首轮与无时长重试共用）。
    /// 返回（下载到的正文数， 过门的 survivors）。任一候选下载失败/标题不匹配/
    /// 被拒收只丢该候选，不中断其余候选与后续源 —— 全拒不等于全源失败（F2）。
    /// audioDurationMs 是原始音频时长（拒收门用）；搜索用的时长参数不在此处。
    private func kugouSurvivors(
        candidates: [SherryKugouLyrics.Candidate],
        song: Song,
        audioDurationMs: Int?
    ) async -> (downloaded: Int, survivors: [SherryLyricDocument]) {
        let scored = candidates.map { candidate in
            (candidate, SherryLyricMatchEvaluation.evaluate(
                wantedTitle: song.name, wantedArtists: [song.artists],
                wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: audioDurationMs,
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
            return (0, [])
        }
        // 前 5 个候选并行下载正文（旧版串行：3 个候选最坏多等 2 倍下载
        // 时间，首屏歌词来得更晚）。TaskGroup 内不写共享状态，只返回
        // 结果，收齐后再挑最优。
        let downloaded = await withTaskGroup(of: (SherryLyricDocument, SherryLyricMatchEvaluation)?.self) { group in
            for (candidate, _) in eligible.prefix(5) {
                group.addTask {
                    guard let doc = await SherryKugouLyrics.document(for: candidate),
                          !doc.lines.isEmpty else { return nil }
                    let evaluation = SherryLyricMatchEvaluation.evaluate(
                        wantedTitle: song.name, wantedArtists: [song.artists],
                        wantedAlbum: song.album.isEmpty ? nil : song.album, wantedDurationMs: audioDurationMs,
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
        // 2.2.4：所有标题匹配且过拒收门的正文都进候选池，不再只取
        // 最佳一份 —— 离群源要靠多源比对才能发现。
        var survivors: [SherryLyricDocument] = []
        for (doc, evaluation) in downloaded {
            CoLogger.shared.log(
                "歌词候选：酷狗 标题=\(doc.title ?? song.name) 歌手=\(doc.artists.joined(separator: "/")) 时长差=\(evaluation.durationErrorMs == .max ? -1 : evaluation.durationErrorMs)ms 逐字=\(evaluation.isWordSynced ? "是" : "否") 标题匹配=\(evaluation.titleMatches ? "是" : "否")",
                level: .debug
            )
            guard evaluation.baseTitleMatches else {
                CoLogger.shared.log("歌词候选弃用：酷狗标题不匹配：\(song.name)", level: .debug)
                continue
            }
            if let kept = gated(doc, song: song, durationMs: audioDurationMs) {
                survivors.append(kept)
            }
        }
        if survivors.isEmpty, downloaded.isEmpty {
            CoLogger.shared.log("歌词候选为空：酷狗 \(candidates.count) 个候选均未取到正文", level: .debug)
        }
        return (downloaded.count, survivors)
    }

    /// 拒收门：不过门的文档记日志后丢弃，调用方继续下一源（2.2.4）。
    /// internal：单测直接断言“酷狗碎片全拒后酷我/LRCLIB 仍能顶上”（F2）。
    func gated(_ document: SherryLyricDocument, song: Song, durationMs: Int?) -> SherryLyricDocument? {
        if let reason = SherryLyricsMatcher.rejectionReason(for: document, audioDurationMs: durationMs) {
            CoLogger.shared.log("歌词拒收：\(song.name) 来源=\(document.source.rawValue) \(reason)", level: .info)
            return nil
        }
        return document
    }

    private func accept(
        document: SherryLyricDocument,
        evaluation: SherryLyricMatchEvaluation,
        song: Song,
        key: String,
        cacheable: Bool = true
    ) -> [LyricLine] {
        if cacheable {
            cache.store(document: document, key: key, identityKey: song.identityKey)
        } else {
            // 三角测量平移过的文档不写磁盘缓存：缓存存的是源文件原文，
            // 重载会回到未修正的时间；下次播放重新比对、重新修正。
            CoLogger.shared.log("歌词已选（不写缓存，平移修正仅本次生效）：\(song.name) 来源=\(document.source.rawValue)", level: .info)
        }
        CoLogger.shared.log(
            "歌词已选：\(song.name) 来源=\(document.source.rawValue) 标题匹配=\(evaluation.titleMatches ? "是" : "否") 歌手匹配=\(evaluation.artistsMatch ? "是" : "否") 时长差=\(evaluation.durationErrorMs == .max ? -1 : evaluation.durationErrorMs)ms 逐字=\(evaluation.isWordSynced ? "是" : "否") 行数=\(document.lines.count)",
            level: .info
        )
        return Self.finalize(lines: document.lines, timing: document.timing)
    }
}
