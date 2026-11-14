import Foundation

/// 歌词候选匹配：标题 / 歌手 / 专辑 / 时长按字典序比较，
///
/// 后面的属性永远不能压过前面的 —— 逐字同步再好，也不能胜过标题不匹配的候选。
/// 机制参考 LyricsIsland (MIT) 的 LyricsMatcher，按酷狗单源 + Sherry 模型改写。
enum SherryLyricsMatcher {
/// 词级同步视为完美匹配的时长误差上限。
static let perfectDurationToleranceMs = 3_000

/// "Song (feat. X) - Remix" → "song"
static func normalizeTitle(_ raw: String) -> String {
var s = raw.lowercased()
s = stripBracketed(s)
if let dash = s.range(of: " - ") {
s = String(s[..<dash.lowerBound])
}
s = stripFeatClause(s)
return collapseWhitespace(s)
}

/// "Rihanna feat. JAY-Z" → "rihanna"
static func normalizeArtist(_ raw: String) -> String {
var s = raw.lowercased()
s = stripBracketed(s)
s = stripFeatClause(s)
return collapseWhitespace(s)
}

static func normalizeAlbum(_ raw: String) -> String {
collapseWhitespace(stripBracketed(raw.lowercased()))
}

/// "周杰伦、DJ阿若" → ["周杰伦", "dj阿若"]
static func splitArtists(_ raw: String) -> [String] {
var value = raw.lowercased()
for marker in [" featuring ", " feat. ", " feat ", " ft. ", " ft ", " with ", " & ", "、", ";", ",", "/", "／"] {
value = value.replacingOccurrences(of: marker, with: "|")
}
let artists = value.split(separator: "|")
.map { collapseWhitespace(stripBracketed(String($0)))}
.filter {!$0.isEmpty}
return artists.isEmpty ? [normalizeArtist(raw)] : artists
}

/// 标题相等（归一化后）且版本词一致：live / 伴奏 / 翻唱 / DJ / remix
/// 等不同版本绝不能互相冒充。版本词取自原始标题（括号内容已 strip，
/// 但版本词要在 strip 之前看 —— "晴天 (DJ 阿若版)" 的 DJ 藏在括号里）。
static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
normalizeTitle(lhs) == normalizeTitle(rhs)
&& versionTerms(in: lhs) == versionTerms(in: rhs)
}

static func artistsMatch(_ lhs: [String], _ rhs: [String]) -> Bool {
let wanted = Set(lhs.flatMap { splitArtists($0)}.map { normalizeArtist($0)}.filter {!$0.isEmpty})
let actual = Set(rhs.flatMap { splitArtists($0)}.map { normalizeArtist($0)}.filter {!$0.isEmpty})
if wanted.isEmpty { return true}
if actual.isEmpty { return false}
// 候选多一个合作者（如 DJ 阿若）不算同一版本；但候选缺省不全时，
// 只要想要的歌手都在候选里就放行（有的源只写主唱）。
return wanted.isSubset(of: actual)
}

static func albumsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
guard let lhs,!lhs.isEmpty else { return true}
guard let rhs,!rhs.isEmpty else { return false}
return normalizeAlbum(lhs) == normalizeAlbum(rhs)
}

/// 缓存键用签名：时长按 5 秒分桶，同一首歌的不同上报时长共用一个缓存项。
static func signature(title: String, artist: String, durationMs: Int?, album: String? = nil) -> String {
let bucket = durationMs.map { Int((Double($0) / 5000.0).rounded()) } ?? -1
var base = "\(normalizeTitle(title))|\(normalizeArtist(artist))|\(bucket)"
if let album,!album.isEmpty {
base += "|album:\(normalizeAlbum(album))"
}
let versions = versionTerms(in: title).sorted().joined(separator: ",")
return versions.isEmpty ? base : "\(base)|\(versions)"
}

/// LRCLIB /api/search 的最佳匹配：标题归一化相等且时长 ±3 秒，优先有同步歌词的。
static func bestLRCLIBMatch(
from candidates: [(trackName: String?, durationSeconds: Double?, hasSyncedLyrics: Bool)],
title: String,
durationMs: Int?
) -> Int? {
let wantedTitle = normalizeTitle(title)
let matches = candidates.enumerated().filter { _, candidate in
guard let name = candidate.trackName, normalizeTitle(name) == wantedTitle else { return false}
guard let durationMs else { return true}
guard let duration = candidate.durationSeconds else { return false}
return abs(duration * 1000 - Double(durationMs)) <= 3000
}
return matches.first { $0.element.hasSyncedLyrics }?.offset ?? matches.first?.offset
}

// MARK: - Helpers

/// 去掉所有 (…) 与 […] 片段。
private static func stripBracketed(_ s: String) -> String {
var out = ""
var depth = 0
for ch in s {
if ch == "(" || ch == "[" || ch == "（" || ch == "" {
if depth > 0 { depth -= 1}
} else if depth == 0 {
out.append(ch)
}
}
return out
}

private static let featMarkers = [" feat. ", " feat ", " featuring ", " ft. ", " ft "]

private static func stripFeatClause(_ s: String) -> String {
var s = s
for marker in featMarkers {
if let r = s.range(of: marker) {
s = String(s[..<r.lowerBound])
}
}
return s
}

private static func collapseWhitespace(_ s: String) -> String {
s.split(whereSeparator: { $0.isWhitespace}).joined(separator: " ")
}

/// 实质不同的发行版本：live / 伴奏 / 翻唱 / 重制 / 不插电 / 卡拉 OK /
/// DJ / remix。括号 strip 之后标题看起来一样时，靠它拦住错版。
private static func versionTerms(in raw: String) -> Set<String> {
let text = raw.lowercased()
let groups: [(String, [String])] = [
("live", ["live", "现场", "演唱会"]),
("instrumental", ["instrumental", "伴奏", "纯音乐"]),
("cover", ["cover", "翻唱"]),
("remaster", ["remaster", "remastered", "重制"]),
("acoustic", ["acoustic", "不插电"]),
("karaoke", ["karaoke", "卡拉ok"]),
("dj", ["dj", "dj版", "电音"]),
("remix", ["remix", "混音"]),
]
return Set(groups.compactMap { canonical, terms in
terms.contains(where: { text.contains($0) }) ? canonical : nil
})
}
}

/// 候选歌词的字典序评价：标题 → 歌手 → 专辑 → 时长 → 是否逐字同步。
struct SherryLyricMatchEvaluation: Comparable, Equatable {
let titleMatches: Bool
let artistsMatch: Bool
let albumMatches: Bool
let durationErrorMs: Int
let isWordSynced: Bool

var isPerfect: Bool {
titleMatches
&& artistsMatch
&& albumMatches
&& durationErrorMs <= SherryLyricsMatcher.perfectDurationToleranceMs
&& isWordSynced
}

/// 字典序：前面的属性不同时直接定胜负，绝不加权求和。
static func < (lhs: Self, rhs: Self) -> Bool {
if lhs.titleMatches != rhs.titleMatches { return !lhs.titleMatches }
if lhs.artistsMatch != rhs.artistsMatch { return !lhs.artistsMatch }
if lhs.albumMatches != rhs.albumMatches { return !lhs.albumMatches }
let lhsDurationRank = lhs.durationErrorMs <= SherryLyricsMatcher.perfectDurationToleranceMs
? 0: lhs.durationErrorMs
let rhsDurationRank = rhs.durationErrorMs <= SherryLyricsMatcher.perfectDurationToleranceMs
? 0: rhs.durationErrorMs
if lhsDurationRank != rhsDurationRank { return lhsDurationRank > rhsDurationRank }
if lhs.isWordSynced != rhs.isWordSynced { return !lhs.isWordSynced }
return false
}

static func evaluate(
wantedTitle: String,
wantedArtists: [String],
wantedAlbum: String?,
wantedDurationMs: Int?,
candidateTitle: String,
candidateArtists: [String],
candidateAlbum: String?,
candidateDurationMs: Int?,
isWordSynced: Bool
) -> SherryLyricMatchEvaluation {
let durationError: Int
if let wanted = wantedDurationMs, let actual = candidateDurationMs {
durationError = abs(wanted - actual)
} else if wantedDurationMs == nil {
durationError = 0
} else {
durationError = .max
}
return SherryLyricMatchEvaluation(
titleMatches: SherryLyricsMatcher.titlesMatch(wantedTitle, candidateTitle),
artistsMatch: SherryLyricsMatcher.artistsMatch(wantedArtists, candidateArtists),
albumMatches: SherryLyricsMatcher.albumsMatch(wantedAlbum, candidateAlbum),
durationErrorMs: durationError,
isWordSynced: isWordSynced
)
}
}
