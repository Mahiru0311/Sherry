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
    var titleMatches: Bool
    var artistsMatch: Bool
    var albumMatches: Bool
    var durationErrorMs: Int
    var isWordSynced: Bool

    /// 字典序：标题 → 歌手 → 专辑 → 时长 → 逐字。越 "小" 越好。
    static func < (lhs: Self, rhs: Self) -> Bool {
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

    // MARK: - 归一化

    static func normalizeTitle(_ raw: String) -> String {
        collapseWhitespace(stripFeatClause(stripBracketed(raw))).lowercased()
    }

    static func normalizeArtist(_ raw: String) -> String {
        collapseWhitespace(stripBracketed(raw)).lowercased()
    }

    static func normalizeAlbum(_ raw: String) -> String {
        collapseWhitespace(stripBracketed(raw)).lowercased()
    }

    static func splitArtists(_ raw: String) -> [String] {
        let artists = raw.split(separator: "|")
        .map { collapseWhitespace(stripBracketed(String($0)))}
        .filter {!$0.isEmpty}
        return artists.isEmpty ? [normalizeArtist(raw)] : artists
    }

    static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeTitle(lhs) == normalizeTitle(rhs)
        && versionTerms(in: lhs) == versionTerms(in: rhs)
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
        let titleMatches = titlesMatch(title, need.title)
        let artistsMatch = artistsMatch(need.artist, artist)
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
        titleMatches: titleMatches,
        artistsMatch: artistsMatch,
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
            guard let trackName = tuple.trackName, titlesMatch(trackName, title) else { continue }
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
