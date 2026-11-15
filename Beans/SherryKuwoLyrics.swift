import Compression
import Foundation

/// 酷我匿名歌词源：酷狗 + LRCLIB 都失败后的跨源兜底。
///
/// 机制参考 LX Music mobile（Apache-2.0，lys whut/lx-music-mobile，
/// `src/utils/musicSdk/kw/{musicSearch,lyric,decodeLyric}.js`），按 Sherry
/// 的模型与日志用 Swift 重写（未复制 JS 代码）：
/// - 搜索：`search.kuwo.cn/r.s?client=kt&all=<歌名 歌手>`，取 abslist
///   的 MUSICRID（去 "MUSIC_" 前缀得数字 rid）、SONGNAME、ARTIST、DURATION（秒）；
/// - 歌词：`mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1&rid=<数字>&encode=utf8`，
///   二进制返回：`TP=content\r\n\r\n` + zlib 流；解压后是 base64，再按
///   "yeelion" 循环 XOR，得到逐字 LRC（`[mm:ss.xxx]<起,长>字…`，`[kuwo:N]` 给变换参数）；
/// - 成功判定是内容判定：正文含时间轴才算有歌词（LX 的 existTimeExp）。
/// 实测（2026-11-16 curl 探针）：搜索"晴天 周杰伦"命中 MUSIC_228908
/// （269s），lrcx=1 解出 13168 字节逐字词，`[ti:晴天][ar:周杰伦]`。
/// 注意：rid 必须是不带 "MUSIC_" 前缀的数字，带前缀返回 `TP=none`。
enum SherryKuwoLyrics {
    private static let searchBase = "http://search.kuwo.cn/r.s"
    private static let lyricBase = "http://mlyric.kuwo.cn/mobi.s"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15"
    private static let searchTimeout: TimeInterval = 10
    private static let lyricTimeout: TimeInterval = 15
    private static let searchLimit = 5

    private struct SearchItem: Decodable {
        let rid: String?
        let name: String?
        let artist: String?
        /// 秒（可能是数字或字符串）。
        let durationSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case rid = "MUSICRID"
            case name = "SONGNAME"
            case artist = "ARTIST"
            case duration = "DURATION"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            rid = try values.decodeIfPresent(String.self, forKey: .rid)
            name = try values.decodeIfPresent(String.self, forKey: .name)
            artist = try values.decodeIfPresent(String.self, forKey: .artist)
            if let seconds = try? values.decode(Double.self, forKey: .duration) {
                durationSeconds = seconds
            } else if let string = try? values.decode(String.self, forKey: .duration),
                      let seconds = Double(string) {
                durationSeconds = seconds
            } else if let int = try? values.decode(Int.self, forKey: .duration) {
                durationSeconds = Double(int)
            } else {
                durationSeconds = nil
            }
        }
    }

    private struct SearchResponse: Decodable {
        let abslist: [SearchItem]?

        /// 坏元素只丢自己，不毁整批（与酷狗搜索同款容错）。
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            var items: [SearchItem] = []
            if var array = try? values.nestedUnkeyedContainer(forKey: .abslist) {
                while !array.isAtEnd {
                    if let item = try? array.decode(SearchItem.self) {
                        items.append(item)
                    } else {
                        _ = try? array.decode(IgnoredValue.self)
                    }
                }
            }
            abslist = items
        }

        private enum CodingKeys: String, CodingKey { case abslist }

        private struct IgnoredValue: Decodable {}
    }

    /// 跨源兜底入口：按"歌名 歌手"搜酷我，匹配后取词；任何一步失败返回 nil，
    /// 由调用方继续下一源（单源失败绝不拖垮整条链）。
    static func fetchLyrics(
        title: String,
        artist: String,
        durationMs: Int?
    ) async -> SherryLyricDocument? {
        // 只取第一位歌手（artist 可能是 "A|B" 的拼接串）。
        let firstArtist = artist.split(separator: "|").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        let keyword = firstArtist.isEmpty ? title : "\(title) \(firstArtist)"
        guard let items = await search(keyword: keyword), !items.isEmpty else {
            CoLogger.shared.log("歌词兜底：酷我无候选：\(title) - \(artist)", level: .debug)
            return nil
        }
        guard let chosen = choose(from: items, title: title, artist: artist, durationMs: durationMs) else {
            CoLogger.shared.log("歌词兜底：酷我候选均不匹配：\(title) - \(artist)", level: .debug)
            return nil
        }
        guard let rid = numericRID(chosen.rid) else { return nil }
        guard let raw = await downloadLyrics(rid: rid),
              SherryLyricsMatcher.hasTimestampedLines(raw) else {
            CoLogger.shared.log("歌词兜底失败：酷我 rid=\(rid) 无时间轴正文", level: .debug)
            return nil
        }
        // 行级文本去掉逐字标记再解析；逐字时间另走 .kuwo 分支合并。
        let plain = raw.replacingOccurrences(
            of: #"<-?\d+,-?\d+(?:,-?\d+)?>"#, with: "", options: .regularExpression
        )
        let lines = LyricParser.parse(plain, wordRaw: raw, wordFormat: .kuwo)
        guard !lines.isEmpty else {
            CoLogger.shared.log("歌词解析为空：酷我 rid=\(rid) 行数=0", level: .debug)
            return nil
        }
        let tags = SherryKugouLyrics.krcMetadata(raw)
        let wordSynced = lines.contains { $0.hasWordTimings }
        CoLogger.shared.log("歌词兜底：酷我命中 \(chosen.name ?? title) 逐字=\(wordSynced ? "是" : "否") 行数=\(lines.count)", level: .debug)
        return SherryLyricDocument(
            source: .kuwo,
            timing: wordSynced ? .wordSynced : .synced,
            lines: lines,
            title: SherryKugouLyrics.resolvedTitle(tagTitle: tags["ti"], candidateTitle: chosen.name ?? title),
            artists: tags["ar"].map { SherryLyricsMatcher.splitArtists($0) }
                ?? SherryLyricsMatcher.splitArtists(chosen.artist ?? artist),
            album: tags["al"],
            durationMs: chosen.durationSeconds.map { Int(($0 * 1000).rounded()) } ?? durationMs,
            rawLRC: raw,
            rawKRC: nil
        )
    }

    /// 候选选择：先按标题基础匹配 + 歌手 + 时长 ±5s（LX findMusic 同款
    /// 容差）打分；全不匹配时最后用编辑距离兜底（思路参考 MusicFree 的
    /// searchSimilarLyric，AGPL-3.0，只借鉴思路，未复制代码）：归一化
    /// 标题距离 ≤2 且歌手匹配才算命中。
    private static func choose(
        from items: [SearchItem],
        title: String,
        artist: String,
        durationMs: Int?
    ) -> SearchItem? {
        let need = SherryLyricNeed(title: title, artist: artist, durationMs: durationMs, album: nil)
        var best: (item: SearchItem, evaluation: SherryLyricMatchEvaluation)?
        for item in items {
            guard let name = item.name else { continue }
            let evaluation = SherryLyricsMatcher.evaluateCandidate(
                title: name,
                artist: item.artist ?? "",
                album: nil,
                durationMs: item.durationSeconds.map { Int(($0 * 1000).rounded()) },
                need: need,
                hasWordTimings: true
            )
            // 时长差超 5 秒直接排除（LX findMusic 的 isEqualsInterval）。
            if let wanted = durationMs, let got = item.durationSeconds,
               abs(Int(got * 1000) - wanted) > 5000 { continue }
            if evaluation.baseTitleMatches,
               best == nil || evaluation < best!.evaluation {
                best = (item, evaluation)
            }
        }
        if let best { return best.item }
        // 最后兜底：编辑距离。
        let normTitle = SherryLyricsMatcher.normalizeTitle(title)
        var closest: (item: SearchItem, distance: Int)?
        for item in items {
            guard let name = item.name else { continue }
            let distance = SherryLyricsMatcher.editDistance(
                SherryLyricsMatcher.normalizeTitle(name), normTitle
            )
            guard distance <= 2 else { continue }
            let artistOK = (item.artist ?? "").isEmpty
                || SherryLyricsMatcher.artistsMatch(artist, item.artist ?? "")
            guard artistOK else { continue }
            if closest == nil || distance < closest!.distance {
                closest = (item, distance)
            }
        }
        if let closest {
            CoLogger.shared.log("歌词兜底：酷我编辑距离命中 \(closest.item.name ?? title) 距离=\(closest.distance)", level: .debug)
        }
        return closest?.item
    }

    private static func numericRID(_ musicRID: String?) -> String? {
        guard var rid = musicRID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rid.isEmpty else { return nil }
        if rid.hasPrefix("MUSIC_") { rid = String(rid.dropFirst("MUSIC_".count)) }
        guard !rid.isEmpty, rid.allSatisfy({ $0.isNumber }) else { return nil }
        return rid
    }

    private static func search(keyword: String) async -> [SearchItem]? {
        var components = URLComponents(string: searchBase)!
        components.queryItems = [
            URLQueryItem(name: "client", value: "kt"),
            URLQueryItem(name: "all", value: keyword),
            URLQueryItem(name: "pn", value: "0"),
            URLQueryItem(name: "rn", value: String(searchLimit)),
            URLQueryItem(name: "uid", value: "794762570"),
            URLQueryItem(name: "ver", value: "kwplayer_ar_9.2.2.1"),
            URLQueryItem(name: "vipver", value: "1"),
            URLQueryItem(name: "show_copyright_off", value: "1"),
            URLQueryItem(name: "newver", value: "1"),
            URLQueryItem(name: "ft", value: "music"),
            URLQueryItem(name: "cluster", value: "0"),
            URLQueryItem(name: "strategy", value: "2012"),
            URLQueryItem(name: "encoding", value: "utf8"),
            URLQueryItem(name: "rformat", value: "json"),
            URLQueryItem(name: "vermerge", value: "1"),
            URLQueryItem(name: "mobi", value: "1"),
            URLQueryItem(name: "issubtitle", value: "1"),
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await get(url: url, timeout: searchTimeout)
            return try JSONDecoder().decode(SearchResponse.self, from: data).abslist
        } catch {
            CoLogger.shared.log("歌词兜底失败：酷我搜索 \(error.localizedDescription)", level: .debug)
            return nil
        }
    }

    /// 二进制歌词：`TP=content\r\n\r\n` + zlib 流 → base64 → "yeelion" 循环 XOR。
    /// 解码流程参考 LX Music mobile 的 kw/decodeLyric.js（Apache-2.0），
    /// 按 Sherry 的 Compression（COMPRESSION_ZLIB）模型重写。
    private static func downloadLyrics(rid: String) async -> String? {
        var components = URLComponents(string: lyricBase)!
        components.queryItems = [
            URLQueryItem(name: "f", value: "web"),
            URLQueryItem(name: "type", value: "lyric"),
            URLQueryItem(name: "lrcx", value: "1"),
            URLQueryItem(name: "rid", value: rid),
            URLQueryItem(name: "encode", value: "utf8"),
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await get(url: url, timeout: lyricTimeout)
            return decodeLyricPayload(data, rid: rid)
        } catch {
            CoLogger.shared.log("歌词兜底失败：酷我下载 rid=\(rid) \(error.localizedDescription)", level: .debug)
            return nil
        }
    }

    private static func decodeLyricPayload(_ data: Data, rid: String) -> String? {
        guard data.count > 10,
              String(data: data.prefix(10), encoding: .utf8)?.lowercased() == "tp=content" else {
            CoLogger.shared.log("歌词兜底失败：酷我 rid=\(rid) 返回 TP=none（无歌词）", level: .debug)
            return nil
        }
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let compressed = data.subdata(in: headerRange.upperBound..<data.count)
        guard let inflated = inflateZlib(compressed) else {
            CoLogger.shared.log("歌词兜底失败：酷我 rid=\(rid) zlib 解压失败", level: .debug)
            return nil
        }
        guard let base64Text = String(data: inflated, encoding: .utf8),
              let decoded = Data(base64Encoded: base64Text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            CoLogger.shared.log("歌词兜底失败：酷我 rid=\(rid) 解压后不是 base64", level: .debug)
            return nil
        }
        let key = Array("yeelion".utf8)
        var bytes = [UInt8](decoded)
        for index in bytes.indices { bytes[index] ^= key[index % key.count] }
        guard let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty else {
            CoLogger.shared.log("歌词兜底失败：酷我 rid=\(rid) XOR 解密后不是 UTF-8 文本", level: .debug)
            return nil
        }
        return text
    }

    /// zlib 流解压：剥 2 字节头 + 4 字节 Adler 尾，走原始 DEFLATE
    ///（与 SherryKugouLyrics.decodeKRC 同款做法）。
    private static func inflateZlib(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 7 else { return nil }
        let cmf = bytes[0]
        let flg = bytes[1]
        guard (cmf & 0x0f) == 8, (Int(cmf) * 256 + Int(flg)) % 31 == 0 else { return nil }
        var payloadStart = 2
        if (flg & 0x20) != 0 { payloadStart += 4 }
        let payloadEnd = bytes.count - 4
        guard payloadStart < payloadEnd else { return nil }
        let payload = Array(bytes[payloadStart..<payloadEnd])
        var output = Data()
        var capacity = max(payload.count * 4, 4096)
        for _ in 0..<8 {
            var buffer = [UInt8](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { destination in
                payload.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if count > 0 {
                output = Data(buffer.prefix(count))
                break
            }
            capacity *= 2
        }
        return output.isEmpty ? nil : output
    }

    private static func get(url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
