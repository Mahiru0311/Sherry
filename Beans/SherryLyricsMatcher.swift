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
