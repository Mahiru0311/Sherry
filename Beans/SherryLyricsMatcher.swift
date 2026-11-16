import Foundation

/// 歌词候选匹配：按标题 → 歌手 → 专辑 → 时长 → 逐字 的字典序打分。
/// 机制参考 LyricsIsland (MIT) 的 LyricsMatcher，按 Sherry 的文档模型改写。
/// 关键规则（R2）：逐字绝不压倒标题不匹配；版本词（live / DJ / 伴奏等）要从
/// 原始标题里读，括号去掉之后再读就分不清 "晴天 (DJ 阿若版)" 和 "晴天" 了。

struct SherryLyricNeed: Hashable {
    var title: String
    var artist: String
    var durationMs: Int?
    var album: String?
    var plainTitle: String { SherryLyricsMatcher.normalizeTitle(title)}
    var plainArtist: String { SherryLyricsMatcher.normalizeArtist(artist)}

    /// 供缓存与去重用的稳定键：标题 | 歌手 | 5 秒时长桶 | 版本词。
    var signature: String {
        SherryLyricsMatcher.signature(title: title, artist: artist, durationMs: durationMs, album: album)
    }
}

struct SherryLyricMatchEvaluation: Comparable, Equatable {
    /// 去版本词后的标题是否相等（Live/DJ/伴奏等后缀不计）：这是准入门槛，
    /// 不是排序项 —— 2.2.1 之前版本词不一致会直接判死刑，导致带版本后缀
    /// 的歌在酷狗和 LRCLIB 两边都拿不到歌词。
    var baseTitleMatches: Bool
    /// 严格标题匹配（含版本词一致）：排序时优先，不再是准入门槛。
    var titleMatches: Bool
    var artistsMatch: Bool
    var albumMatches: Bool
    var durationErrorMs: Int
    var isWordSynced: Bool

    /// 字典序：基础标题 → 严格标题（含版本）→ 歌手 → 专辑 → 时长 → 逐字。越 "小" 越好。
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.baseTitleMatches != rhs.baseTitleMatches { return lhs.baseTitleMatches }
        if lhs.titleMatches != rhs.titleMatches { return lhs.titleMatches }
        if lhs.artistsMatch != rhs.artistsMatch { return lhs.artistsMatch }
        if lhs.albumMatches != rhs.albumMatches { return lhs.albumMatches }
        let lhsDurationRank = lhs.durationErrorMs <= SherryLyricsMatcher.perfectDurationToleranceMs
            ? 0 : lhs.durationErrorMs
        let rhsDurationRank = rhs.durationErrorMs <= SherryLyricsMatcher.perfectDurationToleranceMs
            ? 0 : rhs.durationErrorMs
        if lhsDurationRank != rhsDurationRank { return lhsDurationRank < rhsDurationRank }
        if lhs.isWordSynced != rhs.isWordSynced { return lhs.isWordSynced }
        return false
    }

    /// 只有标题、歌手、专辑全对、时长误差 ≤ 3 秒且逐字才算完美匹配。
    var isPerfect: Bool {
        titleMatches && artistsMatch && albumMatches
        && durationErrorMs <= SherryLyricsMatcher.perfectDurationToleranceMs
        && isWordSynced
    }

    /// Service 的统一打分入口：按"想要的"与"候选的"元数据打分。
    /// 歌手数组按 "|" 拼回字符串，复用 artistsMatch 的拆分逻辑。
    static func evaluate(
        wantedTitle: String, wantedArtists: [String],
        wantedAlbum: String?, wantedDurationMs: Int?,
        candidateTitle: String, candidateArtists: [String],
        candidateAlbum: String?, candidateDurationMs: Int?,
        isWordSynced: Bool
    ) -> SherryLyricMatchEvaluation {
        let need = SherryLyricNeed(
            title: wantedTitle,
            artist: wantedArtists.joined(separator: "|"),
            durationMs: wantedDurationMs,
            album: wantedAlbum
        )
        return SherryLyricsMatcher.evaluateCandidate(
            title: candidateTitle,
            artist: candidateArtists.joined(separator: "|"),
            album: candidateAlbum,
            durationMs: candidateDurationMs,
            need: need,
            hasWordTimings: isWordSynced
        )
    }
}

enum SherryLyricsMatcher {
    static let perfectDurationToleranceMs = 3000
    static let durationBucketMs = 5000

    // MARK: - 2.2.4 时长 / 覆盖率拒收门
    //
    // 探针结论（2026-11-16，/tmp/sherry224-bulk/results5_final.json）：
    // 健康歌的歌词覆盖率（末行时间 / 音频时长）最低 80.5%（海阔天空
    // 257.5/320s），起风了 83%、稻香 85%；错版歌词 慌啥子嘛 165/260s
    // = 63.5%，消愁片段 87/294s = 29.6%。门槛取 75%，两边都有余量。
    // 时长误差门要宽松：酷狗候选 duration 是该版本的时长，不同剪辑版
    // 本来就差一截（稻香 203s 候选 vs 223s 音频，覆盖率 85% 是对的），
    // 只拦误差 > max(30s, 音频 25%) 的；duration 为 0 / 缺失 = 未知，
    // 不拦（只靠覆盖率门）。
    static let minCoverageRatio = 0.75
    static let maxCoverageRatio = 1.20
    static let minLyricLines = 5

    /// 歌词覆盖率 = 最晚一行时间 / 音频时长；音频时长未知时返回 nil（不判）。
    static func coverageRatio(lines: [LyricLine], audioDurationMs: Int?) -> Double? {
        guard let audio = audioDurationMs, audio > 0,
              let last = lines.map(\.time).max() else { return nil }
        return last * 1000.0 / Double(audio)
    }

    static func coverageRatio(of document: SherryLyricDocument, audioDurationMs: Int?) -> Double? {
        coverageRatio(lines: document.lines, audioDurationMs: audioDurationMs)
    }

    /// 只看行时间与音频时长的覆盖率拒收（缓存复检用，不需要文档元数据）。
    static func coverageRejects(lines: [LyricLine], audioDurationMs: Int?) -> Bool {
        guard let ratio = coverageRatio(lines: lines, audioDurationMs: audioDurationMs) else { return false }
        return ratio < minCoverageRatio || ratio > maxCoverageRatio
    }

    /// 拒收原因；nil = 通过。durationMs <= 0 当作未知，不参与时长门。
    static func rejectionReason(for document: SherryLyricDocument, audioDurationMs: Int?) -> String? {
        if document.lines.isEmpty { return "0 行" }
        if document.lines.count < minLyricLines {
            return "行数过少（\(document.lines.count) 行 < \(minLyricLines) 行）"
        }
        if let audio = audioDurationMs, audio > 0 {
            if let ratio = coverageRatio(of: document, audioDurationMs: audio) {
                if ratio < minCoverageRatio {
                    return String(format: "覆盖率过低（%.0f%% < %.0f%%，末行 %.1fs / 音频 %.1fs）",
                                  ratio * 100, minCoverageRatio * 100,
                                  (document.lines.map(\.time).max() ?? 0), Double(audio) / 1000.0)
                }
                if ratio > maxCoverageRatio {
                    return String(format: "覆盖率过高（%.0f%% > %.0f%%，歌词比音频长太多）",
                                  ratio * 100, maxCoverageRatio * 100)
                }
            }
            if let docDuration = document.durationMs, docDuration > 0 {
                let error = abs(docDuration - audio)
                let threshold = max(30_000, audio / 4)
                if error > threshold {
                    return "版本时长差过大（歌词 \(docDuration / 1000)s / 音频 \(audio / 1000)s，差 \(error / 1000)s > \(threshold / 1000)s）"
                }
            }
        }
        return nil
    }

    // MARK: - 2.2.4 跨源固定偏移三角测量
    //
    // 探针结论：源间偏移是按歌固定的常数、几乎无漂移（小幸运酷我 −3.1s、
    // 稻香酷狗 −4.2s、海阔天空 −1.2s、晴天 +0.4s、起风了 −0.3s），是
    // 不同剪辑版（前奏长度不同），不是时钟漂移。只在至少 3 个源都
    // 通过拒收门、且其中两个源互相认同（中位偏移 ≤1.0s）、第三个源
    // 相对两个源同向偏离 >2.0s 时，才认定第三个源是离群者；否则不动。
    // 2 个源时无法判断谁错，保守不动。
    static let triangulationAgreementSeconds = 1.0
    static let triangulationOutlierSeconds = 2.0
    static let triangulationMinMatchedLines = 4

    struct Triangulation {
        let chosen: SherryLyricDocument
        /// 离群源（nil = 无离群者，首选文档未动）。
        let outlier: SherryLyricDocument?
        /// 对离群文档实际施加的修正（秒，>0 = 往后推）；换源时为 nil。
        let appliedOffsetSeconds: Double?
    }

    /// 跨源排序：逐字优先 → 覆盖率（封顶 1.0）→ 源优先级（酷狗 > 酷我 >
    /// LRCLIB）→ 时长误差。只排已通过拒收门的文档。
    static func ranked(documents: [SherryLyricDocument], audioDurationMs: Int?) -> [SherryLyricDocument] {
        let sourcePriority: [SherryLyricDocument.Source: Int] = [.kugou: 0, .kuwo: 1, .lrclib: 2]
        return documents.sorted { lhs, rhs in
            if lhs.isWordSynced != rhs.isWordSynced { return lhs.isWordSynced }
            let lhsCoverage = min(coverageRatio(of: lhs, audioDurationMs: audioDurationMs) ?? 0, 1.0)
            let rhsCoverage = min(coverageRatio(of: rhs, audioDurationMs: audioDurationMs) ?? 0, 1.0)
            if abs(lhsCoverage - rhsCoverage) > 0.001 { return lhsCoverage > rhsCoverage }
            if sourcePriority[lhs.source] != sourcePriority[rhs.source] {
                return (sourcePriority[lhs.source] ?? 99) < (sourcePriority[rhs.source] ?? 99)
            }
            let lhsError = durationError(of: lhs, audioDurationMs: audioDurationMs)
            let rhsError = durationError(of: rhs, audioDurationMs: audioDurationMs)
            return lhsError < rhsError
        }
    }

    private static func durationError(of document: SherryLyricDocument, audioDurationMs: Int?) -> Int {
        guard let doc = document.durationMs, doc > 0, let audio = audioDurationMs, audio > 0 else { return .max }
        return abs(doc - audio)
    }

    /// 两份文档同名行的中位时间差（A − B，秒）；配对行 <4 行时返回 nil。
    /// 同名行按出现顺序配对（副歌重复行不跨段错配）。
    static func medianOffsetSeconds(between a: SherryLyricDocument, and b: SherryLyricDocument) -> Double? {
        var aByText: [String: [Double]] = [:]
        var bByText: [String: [Double]] = [:]
        for line in a.lines { aByText[normalizedLineText(line.text), default: []].append(line.time) }
        for line in b.lines { bByText[normalizedLineText(line.text), default: []].append(line.time) }
        var diffs: [Double] = []
        for (text, aTimes) in aByText {
            guard let bTimes = bByText[text] else { continue }
            for (aTime, bTime) in zip(aTimes, bTimes) { diffs.append(aTime - bTime) }
        }
        guard diffs.count >= triangulationMinMatchedLines else { return nil }
        let sorted = diffs.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func normalizedLineText(_ text: String) -> String {
        text.lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// 三角测量：返回最终选用的文档。离群者是首选时，若有带逐字的共识
    /// 文档就换源；若共识文档只有行级、离群者带逐字，则把离群者的行与
    /// 词整体平移修正量后保留（逐字不丢）；其他情况不动。
    static func triangulate(documents: [SherryLyricDocument], audioDurationMs: Int?) -> Triangulation {
        let ordered = ranked(documents: documents, audioDurationMs: audioDurationMs)
        guard let winner = ordered.first else {
            fatalError("triangulate called with no documents")
        }
        guard documents.count >= 3 else { return Triangulation(chosen: winner, outlier: nil, appliedOffsetSeconds: nil) }
        // 每源最多一份文档：按下标取“其余两份”，不靠 source/title 比对。
        for outlierIndex in documents.indices {
            let outlier = documents[outlierIndex]
            let others = documents.enumerated().filter { $0.offset != outlierIndex }.map(\.element)
            guard others.count >= 2 else { continue }
            let first = others[0], second = others[1]
            guard let consensus = medianOffsetSeconds(between: first, and: second),
                  abs(consensus) <= triangulationAgreementSeconds,
                  let offFirst = medianOffsetSeconds(between: outlier, and: first),
                  let offSecond = medianOffsetSeconds(between: outlier, and: second),
                  abs(offFirst) > triangulationOutlierSeconds,
                  abs(offSecond) > triangulationOutlierSeconds,
                  (offFirst > 0) == (offSecond > 0) else { continue }
            // 离群者确认：只有首选是离群者时才换/修；否则首选本来就对。
            guard documents.firstIndex(of: winner) == outlierIndex else {
                return Triangulation(chosen: winner, outlier: outlier, appliedOffsetSeconds: nil)
            }
            let consensusDocs = others
            if let bestConsensus = ranked(documents: consensusDocs, audioDurationMs: audioDurationMs).first,
               bestConsensus.isWordSynced {
                return Triangulation(chosen: bestConsensus, outlier: outlier, appliedOffsetSeconds: nil)
            }
            // 共识只有行级：平移离群者的逐字文档，保留逐字时间。
            let correction = -(offFirst + offSecond) / 2
            return Triangulation(
                chosen: outlier.shifted(by: correction),
                outlier: outlier, appliedOffsetSeconds: correction
            )
        }
        return Triangulation(chosen: winner, outlier: nil, appliedOffsetSeconds: nil)
    }

    // MARK: - 归一化

    static func normalizeTitle(_ raw: String) -> String {
        collapseWhitespace(stripVersionSuffix(stripFeatClause(stripBracketed(raw)))).lowercased()
            .applyingSimplifiedMapping()
    }

    static func normalizeArtist(_ raw: String) -> String {
        collapseWhitespace(stripBracketed(raw)).lowercased().applyingSimplifiedMapping()
    }

    static func normalizeAlbum(_ raw: String) -> String {
        collapseWhitespace(stripBracketed(raw)).lowercased().applyingSimplifiedMapping()
    }

    static func splitArtists(_ raw: String) -> [String] {
        let artists = raw.split(separator: "|")
        .map { collapseWhitespace(stripBracketed(String($0)))}
        .filter {!$0.isEmpty}
        return artists.isEmpty ? [normalizeArtist(raw)] : artists
    }

    static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        baseTitlesMatch(lhs, rhs)
        && versionTerms(in: lhs) == versionTerms(in: rhs)
    }

    /// 去版本词后的标题是否相等：准入门槛用这个，版本词只参与排序。
    static func baseTitlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeTitle(lhs) == normalizeTitle(rhs)
    }

    static func artistsMatch(_ wanted: String, _ actual: String) -> Bool {
        let wantedArtists = splitArtists(wanted).map { normalizeArtist($0)}
        let actualArtists = splitArtists(actual).map { normalizeArtist($0)}
        return wantedArtists.allSatisfy { wantedArtist in
            actualArtists.contains { actualArtist in
                actualArtist == wantedArtist
                || actualArtist.contains(wantedArtist)
                || wantedArtist.contains(actualArtist)
            }
        }
    }

    static func albumsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeAlbum(lhs) == normalizeAlbum(rhs)
    }

    /// 歌词正文是否含带时间轴的行（LX Music 的成功判定）：
    /// 只有含时间轴才算"有歌词"，否则继续下一源（P1-2 / 跨源链）。
    static func hasTimestampedLines(_ raw: String) -> Bool {
        raw.range(of: #"\[\d{1,2}:.*\d{1,4}\]"#, options: .regularExpression) != nil
    }

    /// Levenshtein 编辑距离（标准 DP）：跨源搜索的最后兜底——标题
    /// 基础匹配失败时，取距离最小的候选（思路参考 MusicFree 的
    /// searchSimilarLyric，AGPL-3.0，只借鉴思路，未复制代码）。
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func signature(title: String, artist: String, durationMs: Int?, album: String? = nil) -> String {
        let bucket = durationMs.map { Int((Double($0) / 5000.0).rounded()) } ?? -1
        var base = "\(normalizeTitle(title))|\(normalizeArtist(artist))|\(bucket)"
        if let album,!album.isEmpty {
            base += "|album:\(normalizeAlbum(album))"
        }
        let versions = versionTerms(in: title).sorted().joined(separator: ",")
        return versions.isEmpty ? base : "\(base)|\(versions)"
    }

    // MARK: - 候选打分

    static func evaluateCandidate(
    title: String, artist: String, album: String?, durationMs: Int?,
    need: SherryLyricNeed, hasWordTimings: Bool
) -> SherryLyricMatchEvaluation {
        let baseTitleMatches = baseTitlesMatch(title, need.title)
        let titleMatches = titlesMatch(title, need.title)
        // 酷狗第三方上传歌词的 singer 字段经常回显歌名（实测 "晴天" 的
        // singer 就是 "晴天"），不是歌手 —— 候选歌手与候选歌名相同时，
        // 歌手信息未知，不扣分（否则几乎所有第三方歌词都会排到后面）。
        let artistsMatchValue: Bool
        if artist.isEmpty || normalizeArtist(artist) == normalizeTitle(title) {
            artistsMatchValue = true
        } else {
            artistsMatchValue = artistsMatch(need.artist, artist)
        }
        let albumMatches: Bool
        if let album, let needAlbum = need.album,!needAlbum.isEmpty {
            albumMatches = albumsMatch(album, needAlbum)
        } else {
            albumMatches = true
        }
        let durationError: Int
        if let durationMs, let wantMs = need.durationMs {
            durationError = abs(durationMs - wantMs)
        } else {
            durationError = .max
        }
        return SherryLyricMatchEvaluation(
        baseTitleMatches: baseTitleMatches,
        titleMatches: titleMatches,
        artistsMatch: artistsMatchValue,
        albumMatches: albumMatches,
        durationErrorMs: durationError,
        isWordSynced: hasWordTimings
    )
    }

    /// LRCLIB /api/search 结果里挑最好的，返回下标；没有标题匹配的返回 nil。
    /// 搜索本身已按歌手过滤，这里只按标题与时长打分（逐字参与打分）。
    static func bestLRCLIBMatch(
        from tuples: [(trackName: String?, durationSeconds: Double?, hasSyncedLyrics: Bool)],
        title: String, durationMs: Int?
    ) -> Int? {
        let need = SherryLyricNeed(title: title, artist: "", durationMs: durationMs, album: nil)
        var bestIndex: Int?
        var bestEvaluation: SherryLyricMatchEvaluation?
        for (index, tuple) in tuples.enumerated() {
            guard let trackName = tuple.trackName, baseTitlesMatch(trackName, title) else { continue }
            let evaluation = evaluateCandidate(
                title: trackName,
                artist: "",
                album: nil,
                durationMs: tuple.durationSeconds.map { Int(($0 * 1000).rounded()) },
                need: need,
                hasWordTimings: tuple.hasSyncedLyrics
            )
            if bestEvaluation == nil || evaluation < bestEvaluation! {
                bestEvaluation = evaluation
                bestIndex = index
            }
        }
        return bestIndex
    }

    // MARK: - 内部工具

    /// 去掉所有 (…) 与 […] 片段（含全角括号）。括号嵌套按深度计。
    private static func stripBracketed(_ s: String) -> String {
        let opens: [Character] = ["(", "[", "（", "【"]
        let closes: [Character] = [")", "]", "）", "】"]
        var out = ""
        var depth = 0
        for ch in s {
            if opens.contains(ch) {
                depth += 1
            } else if closes.contains(ch) {
                if depth > 0 { depth -= 1}
            } else if depth == 0 {
                out.append(ch)
            }
        }
        return out
    }

    private static let featMarkers = [" feat. ", " feat ", " featuring ", " ft. ", " ft "]

    private static func stripFeatClause(_ s: String) -> String {
        let lower = s.lowercased()
        for marker in featMarkers {
            if let range = lower.range(of: marker) {
                return String(s[..<range.lowerBound])
            }
        }
        return s
    }

    /// 去掉无括号的版本后缀（"晴天 - Live"、"晴天 Live版"、"晴天 伴奏" 等）：
    /// 括号版已被 stripBracketed 去掉，这里处理后缀还留在标题里的情况。
    /// 只去尾部，循环直到稳定；版本词本身仍由 versionTerms 从原始标题读，
    /// 只参与排序，不影响准入（P1-2）。
    private static func stripVersionSuffix(_ s: String) -> String {
        var result = s
        // 尾部才算后缀：前面留空格或 "-" 分隔，避免误伤正标题。
        let suffixes = [
            " - live", " live", " live版", " live 版",
            " - dj", " dj", " dj版", " dj 版",
            " - remix", " remix", " remix版", " 混音版",
            " - acoustic", " acoustic", " 不插电",
            " 现场版", " 演唱会版", " 演唱会",
            " 伴奏", " 伴奏版", " 翻唱", " 翻唱版",
            " demo", " demo版", " 小样",
            " 原声版", " 重制版", " remaster",
            " cover", " instrumental", " karaoke", " 卡拉ok",
        ]
        var changed = true
        while changed {
            changed = false
            let lower = result.lowercased()
            for suffix in suffixes where lower.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return result
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace}).joined(separator: " ")
    }

    /// 从原始标题里读版本词（括号去掉之前读，否则分不清 DJ 版和原版）。
    /// 每个同义词组只留一个规范词，如 "live"、"dj"、"remix"、"伴奏"。
    static func versionTerms(in title: String) -> Set<String> {
        let text = title.lowercased()
        let groups: [(canonical: String, terms: [String])] = [
        ("live", ["live", "现场", "演唱会", "concert"]),
        ("acoustic", ["acoustic", "不插电", "原声"]),
        ("remix", ["remix", "混音", "remaster", "重制"]),
        ("dj", ["dj", "dj版", "dj 版"]),
        ("伴奏", ["伴奏", "instrumental", "karaoke", "卡拉ok", "纯音乐"]),
        ("翻唱", ["翻唱", "cover"]),
        ("demo", ["demo", "小样"]),
    ]
        return Set(groups.compactMap { canonical, terms in
            terms.contains(where: { text.contains($0) }) ? canonical : nil
    })
    }
}

/// 繁 → 简归一（仅用于匹配，不改显示）：歌名/歌手一繁一简时也算同一首。
/// 常用字对照表（未列出的字保持原样，不影响匹配）。
private extension String {
    func applyingSimplifiedMapping() -> String {
        guard contains(where: { SherryTraditionalSimplified.mapping[$0] != nil }) else { return self }
        return String(map { SherryTraditionalSimplified.mapping[$0] ?? $0 })
    }
}

private enum SherryTraditionalSimplified {
    /// "繁简" 对照串：每对两字，位置一一对应。
    static let mapping: [Character: Character] = {
        let traditional = "國學樂廣龍雲電話車馬門問間頭髮後從讓過還這個人來時會萬對點面愛親見覺說讀書畫聲聽風飛陽陰歲夢憶戀歡開關長東與為無盡實寶貴費買賣輕鐘鐵銀銅錢紙筆醫發華葉蕭陳張劉黃楊鄭謝鄧馮許盧羅蔣韓於裡處號離邊達進遠運連選遷鄰鄉響願顧顯觀觸護報擔擁據擴擾擺攝撫擊擇機檢臉興舉舊歸靈體鬱憂懷態應贊贈踐轉輪軟輛輩較輸辦辭農遙遺險隨隱雜雙難靜順須預頒頓領顏題顛餘駐驚驕驗灣藝蘇蘋蘭虧蟲"
        let simplified = "国学乐广龙云电话车马门问间头发后从让过还这个人来时会万对点面爱亲见觉说读书画声听风飞阳阴岁梦忆恋欢开关长东与为无尽实宝贵费买卖轻钟铁银铜钱纸笔医发华叶萧陈张刘黄杨郑谢邓冯许卢罗蒋韩于里处号离边达进远运连选迁邻乡响愿顾显观触护报担拥据扩扰摆摄抚击择机检脸兴举旧归灵体郁忧怀态应赞赠践转轮软辆辈较输办辞农遥遗险随隐杂双难静顺须预颁顿领颜题颠余驻惊骄验湾艺苏苹兰亏虫"
        var result: [Character: Character] = [:]
        for (t, s) in zip(traditional, simplified) where t != s {
            result[t] = s
        }
        return result
    }()
}
