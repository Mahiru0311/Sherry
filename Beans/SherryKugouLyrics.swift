import Compression
import Foundation

/// 一份抓到的歌词：来源、行级时间、逐字时间（如果有）、原始文本（供缓存）。
/// Equatable：三角测量用 firstIndex 定位首选文档（2.2.4）。
struct SherryLyricDocument: Equatable {
    enum Source: String, Codable {
        case kugou
        case lrclib
        case kuwo
    }

    enum Timing: String, Codable {
        case wordSynced
        case synced
        case plain
    }

    let source: Source
    let timing: Timing
    /// 已解析的行（逐字时间在 LyricLine.words 里）。
    let lines: [LyricLine]
    /// KRC/LRC 标签里的歌名 / 歌手 / 专辑（候选校验用；没有时回退候选元数据）。
    let title: String?
    let artists: [String]
    let album: String?
    let durationMs: Int?
    /// 原始 LRC/KRC 文本（写磁盘缓存用）。
    let rawLRC: String
    let rawKRC: String?

    var isWordSynced: Bool {
        timing == .wordSynced && lines.contains { $0.hasWordTimings }
    }

    /// 整体平移时间轴（2.2.4 三角测量：离群文档保留逐字、按共识修正）：
    /// 行时间与词时间同移同量，钳制 ≥0；其余字段不动。注意缓存写的是
    /// 平移后的行，但 rawLRC/rawKRC 仍是源文件原文 —— 重载后解析出的
    /// 行时间会回到原文时间；因此平移只用于本次播放的内存文档，不直接
    /// 写缓存（见 Service.accept：平移过的文档不进磁盘缓存，下次仍以
    /// 原文重算，避免缓存里的时间与原文对不上）。
    func shifted(by seconds: Double) -> SherryLyricDocument {
        guard seconds != 0 else { return self }
        let shiftedLines = lines.map { line in
            var shifted = LyricLine(
                time: max(0, line.time + seconds),
                text: line.text,
                translation: line.translation,
                words: line.words?.map {
                    LyricWord(text: $0.text, start: max(0, $0.start + seconds), duration: $0.duration)
                }
            )
            shifted.synthesizedWords = line.synthesizedWords
            return shifted
        }
        return SherryLyricDocument(
            source: source, timing: timing, lines: shiftedLines,
            title: title, artists: artists, album: album, durationMs: durationMs,
            rawLRC: rawLRC, rawKRC: rawKRC
        )
    }
}

/// 酷狗匿名歌词源（client=pc，无 token / cookie / dfid / 签名）。
///
/// 机制参考 LyricsIsland (MIT) 的 KugouLyricsProvider，KRC 解码逻辑源自
/// Lyricify Lyrics Helper (Apache-2.0)，按 Sherry 的模型与日志改写。
/// 实测结论（2026-11-16 curl 探针，见 CHANGELOG）：
/// - 决定候选数的是 keyword 里带不带歌手：裸歌名对海阔天空/光辉岁月/
///   小幸运返回 0 候选，"歌名 歌手" 返回 10；晴天两种都返回 10。
///   所以搜索顺序是：歌名+歌手+时长 → 歌名+时长 → 歌名 → 歌名+歌手。
/// - timelength（秒）/ lrctxt=1 / KG-RC / KG-THash 头 / KuGou UA 与
///   现行 duration（毫秒）参数 A/B 对照无差异（10 vs 10、0 vs 0），
///   主搜索不采用；只在备用端点上用 LX 同款头。
/// - 全部探针候选的 krctype 都是 2，KRC 照常可下可解，所以 hasKRC
///   的门改为 krctype==1 || krctype==2。
/// - /download?fmt=krc 匿名可下，krc1 魔数 + 16 字节固定 XOR + zlib，
///   33/38 行带逐字标签 —— 匿名链本身是通的。
/// - 备用端点 m.kugou.com/app/i/krc.php?cmd=100（机制参考 LX Music
///   mobile，Apache-2.0）直接返回 LRC 正文：晴天裸歌名可取，海阔天空
///   需带歌手才返回；主搜索 0 候选时用它兜底。
enum SherryKugouLyrics {
    private static let searchBase = "https://lyrics.kugou.com"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15"
    private static let timeout: TimeInterval = 15
    private static let searchLimit = 20

    struct Candidate {
        let id: String
        let accessKey: String
        let title: String
        let artists: [String]
        let album: String?
        let durationMs: Int?
        let hasKRC: Bool
    }

    struct SearchResponse: Decodable {
        struct Item: Decodable {
            let id: String
            /// 缺 accesskey 的候选下不了正文：解码为 nil，调用方直接跳过，
            /// 不让一个坏候选毁掉整批搜索结果（P2-1）。
            let accessKey: String?
            let singer: String?
            let song: String?
            let duration: Int?
            let krctype: Int?
            let contenttype: Int?

            enum CodingKeys: String, CodingKey {
                case id, singer, song, duration, krctype, contenttype
                case accessKey = "accesskey"
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if let string = try? values.decode(String.self, forKey: .id) {
                    id = string
                } else {
                    id = String(try values.decode(Int64.self, forKey: .id))
                }
                accessKey = try values.decodeIfPresent(String.self, forKey: .accessKey)
                singer = try values.decodeIfPresent(String.self, forKey: .singer)
                song = try values.decodeIfPresent(String.self, forKey: .song)
                duration = Self.tolerantInt(values, .duration)
                krctype = Self.tolerantInt(values, .krctype)
                contenttype = Self.tolerantInt(values, .contenttype)
            }

            /// duration / krctype 可能是 Int、Double 或 String：都接受，
            /// 全失败才当缺失（P2-1）。
            private static func tolerantInt(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
                if let int = try? values.decode(Int.self, forKey: key) { return int }
                if let double = try? values.decode(Double.self, forKey: key) { return Int(double.rounded()) }
                if let string = try? values.decode(String.self, forKey: key) {
                    if let int = Int(string) { return int }
                    if let double = Double(string) { return Int(double.rounded()) }
                }
                return nil
            }
        }

        let candidates: [Item]

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // 逐个容错解码：一个坏候选（缺字段 / 类型错）只丢自己，
            // 不让整批 candidates 解码失败（P2-1）。
            var items: [Item] = []
            if var array = try? values.nestedUnkeyedContainer(forKey: .candidates) {
                while !array.isAtEnd {
                    if let item = try? array.decode(Item.self) {
                        items.append(item)
                    } else {
                        _ = try? array.decode(IgnoredValue.self)
                    }
                }
            }
            candidates = items
        }

        private enum CodingKeys: String, CodingKey { case candidates }

        /// 解码时跳过的占位类型：只为消耗掉坏元素，不保留任何数据。
        private struct IgnoredValue: Decodable {}
    }

    private struct DownloadResponse: Decodable {
        let content: String
    }

    /// 搜索候选（只含元数据，不下载正文）。调用方按字典序排序后只取前 3 个下正文。
    /// 2.2.6 F2(a)：尝试表抽成纯函数（供单测）—— 时长未知（durationMs == nil）
    /// 时所有尝试都不带 duration 参数，绝不拿假时长去搜；时长已知时前两次
    /// 尝试带时长（酷狗排名完全由 duration 参数决定，带时长才返回全版）。
    static func searchAttempts(
        title: String,
        artists: [String],
        durationMs: Int?
    ) -> [(keyword: String, duration: Int?)] {
        // 只取第一位歌手（song.artists 可能是 "A|B" 的拼接串）。
        let firstArtist = artists.flatMap { $0.split(separator: "|").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        let titleAndArtist = firstArtist.map { "\(title) \($0)" }
        var attempts: [(keyword: String, duration: Int?)] = []
        if let titleAndArtist { attempts.append((titleAndArtist, durationMs)) }
        attempts.append((title, durationMs))
        attempts.append((title, nil))
        if let titleAndArtist { attempts.append((titleAndArtist, nil)) }
        return attempts
    }

    static func search(
        title: String,
        artists: [String],
        album _: String?,
        durationMs: Int?
    ) async -> [Candidate] {
        // 2.2.2 探针结论（2026-11-16，4 首歌 × 6 组参数）：
        // 裸歌名对一半歌返回 0 候选，"歌名 歌手" 全部返回 10 ——
        // 2.2.1 删掉的第三次尝试正是回归根因，恢复并提到第一位。
        // 顺序：歌名+歌手+时长 → 歌名+时长 → 歌名 → 歌名+歌手；
        // 一组出候选就停，最多 4 次，不烧限流配额。
        // 2.2.6：首轮候选全被拒收时，Service 会再调一次 durationMs: nil
        // 的搜索补试剩余组合（见 SherryLyricsService.fetchAndCache F2(b)）。
        let attempts = searchAttempts(title: title, artists: artists, durationMs: durationMs)
        var seen: Set<String> = []
        var out: [Candidate] = []
        for attempt in attempts {
            do {
                let items = try await searchOnce(keyword: attempt.keyword, durationMs: attempt.duration)
                CoLogger.shared.log(
                    "歌词搜索：酷狗 keyword=\(attempt.keyword) duration=\(attempt.duration.map(String.init) ?? "-") 候选=\(items.count)",
                    level: .debug
                )
                for item in items {
                    // 没 accesskey 的候选下不了正文，直接跳过（P2-1）。
                    guard let accessKey = item.accessKey, !accessKey.isEmpty else { continue }
                    guard seen.insert(item.id).inserted else { continue }
                    out.append(Candidate(
                        id: item.id,
                        accessKey: accessKey,
                        title: item.song ?? title,
                        artists: SherryLyricsMatcher.splitArtists(item.singer ?? ""),
                        album: nil,
                        durationMs: item.duration,
                        // P1-1：实测全部候选 krctype 都是 2 且 KRC 照常可下；
                        // LX 同款判定是 krctype==1 && contenttype!=1，但 2 也能下，
                        // 所以 1 和 2 都算有 KRC（contenttype==1 时宁取 LRC）。
                        hasKRC: ((item.krctype ?? 0) == 1 || (item.krctype ?? 0) == 2)
                            && (item.contenttype ?? 0) != 1
                    ))
                    if out.count >= searchLimit { return out }
                }
                if !out.isEmpty { return out }
            } catch {
                CoLogger.shared.log("歌词搜索失败：酷狗 keyword=\(attempt.keyword) \(error.localizedDescription)", level: .debug)
            }
        }
        return out
    }

    /// 备用酷狗端点（m.kugou.com/app/i/krc.php?cmd=100，机制参考 LX Music
    /// mobile，Apache-2.0）：主搜索 0 候选时用。直接返回 LRC 正文（不是
    /// JSON），无 hash 也可用；先试"歌名 歌手"，再试裸歌名。
    /// 探针：晴天裸歌名返回 2379 字节真词；海阔天空裸歌名返回空，
    /// 带 Beyond 返回 354 字节真词（2026-11-16）。
    static func backupDocument(
        title: String,
        artists: [String],
        durationMs: Int?
    ) async -> SherryLyricDocument? {
        // 只取第一位歌手（artists 可能是 "A|B" 的拼接串）。
        let firstArtist = artists.flatMap { $0.split(separator: "|").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        let keywords: [String] = firstArtist.map { ["\(title) \($0)", title] } ?? [title]
        let seconds = durationMs.map { max(1, Int((Double($0) / 1000).rounded())) }
        for keyword in keywords {
            guard let text = await backupLyrics(keyword: keyword, seconds: seconds),
                  SherryLyricsMatcher.hasTimestampedLines(text) else { continue }
            let lines = LyricParser.parse(strippingWatermarkLines(text))
            guard !lines.isEmpty else { continue }
            let tags = krcMetadata(text)
            CoLogger.shared.log("歌词兜底：酷狗备用端点命中 keyword=\(keyword) 行数=\(lines.count)", level: .debug)
            return SherryLyricDocument(
                source: .kugou,
                timing: .synced,
                lines: lines,
                title: resolvedTitle(tagTitle: tags["ti"], candidateTitle: title),
                artists: tags["ar"].map { SherryLyricsMatcher.splitArtists($0) } ?? artists,
                album: tags["al"],
                // 2.2.4：备用端点不返回歌词版本时长，填 wanted 会让时长门
                // 永远通过；未知就是 nil，由覆盖率门（行时间）来判。
                durationMs: nil,
                rawLRC: text,
                rawKRC: nil
            )
        }
        return nil
    }

    /// 备用端点返回的水印行（如「此歌曲由 Vemus 未音 APP 制作」）不是歌词，
    /// 解析前去掉含 "APP制作" 的行。
    private static func strippingWatermarkLines(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.contains("APP制作") }
            .joined(separator: "\n")
    }

    private static func backupLyrics(keyword: String, seconds: Int?) async -> String? {
        var components = URLComponents(string: "http://m.kugou.com/app/i/krc.php")!
        var items = [
            URLQueryItem(name: "cmd", value: "100"),
            URLQueryItem(name: "keyword", value: keyword),
        ]
        if let seconds { items.append(URLQueryItem(name: "timelength", value: String(seconds))) }
        items.append(URLQueryItem(name: "d", value: String(Double.random(in: 0..<1))))
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("KuGou2012-9020-ExpandSearchManager", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "KG-RC")
        request.setValue("expand_search_manager.cpp:852736169:451", forHTTPHeaderField: "KG-THash")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
            return text
        } catch {
            CoLogger.shared.log("歌词兜底失败：酷狗备用端点 keyword=\(keyword) \(error.localizedDescription)", level: .debug)
            return nil
        }
    }

    /// KRC/LRC 头标签 [ti:] 只有与候选标题基础匹配时才采用；标签与候选
    /// 标题对不上时（第三方歌词标签常错），保留候选标题，不让标签把
    /// 一个本来匹配的候选推成"标题不匹配"而拒掉（P1-2）。
    static func resolvedTitle(tagTitle: String?, candidateTitle: String) -> String {
        guard let tagTitle, !tagTitle.isEmpty,
              SherryLyricsMatcher.baseTitlesMatch(tagTitle, candidateTitle) else {
            return candidateTitle
        }
        return tagTitle
    }

    private static func searchOnce(keyword: String, durationMs: Int?) async throws -> [SearchResponse.Item] {
        var components = URLComponents(string: searchBase + "/search")!
        var items = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: keyword),
        ]
        if let durationMs {
            items.append(URLQueryItem(name: "duration", value: String(durationMs)))
        }
        components.queryItems = items
        let data = try await get(url: components.url!)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.candidates
    }

    /// 下一个候选的正文：有 KRC 先下 KRC（逐字），失败再下 LRC（行级）。
    static func document(for candidate: Candidate) async -> SherryLyricDocument? {
        if candidate.hasKRC,
           let data = await download(id: candidate.id, accessKey: candidate.accessKey, format: "krc"),
           let decoded = decodeKRC(data, candidateID: candidate.id),
           let doc = document(fromKRC: decoded, candidate: candidate) {
            return doc
        }
        guard let data = await download(id: candidate.id, accessKey: candidate.accessKey, format: "lrc"),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            CoLogger.shared.log("歌词下载失败：酷狗 id=\(candidate.id) fmt=lrc 无正文", level: .debug)
            return nil
        }
        let lines = LyricParser.parse(text)
        guard !lines.isEmpty else {
            CoLogger.shared.log("歌词解析为空：酷狗 id=\(candidate.id) fmt=lrc 行数=0", level: .debug)
            return nil
        }
        let tags = krcMetadata(text)
        return SherryLyricDocument(
            source: .kugou,
            timing: .synced,
            lines: lines,
            title: resolvedTitle(tagTitle: tags["ti"], candidateTitle: candidate.title),
            artists: tags["ar"].map { SherryLyricsMatcher.splitArtists($0) } ?? candidate.artists,
            album: tags["al"] ?? candidate.album,
            // 2.2.4：不用 wantedDurationMs 兜底 —— 那会让时长门永远通过；
            // 候选没给时长就是未知（nil），由覆盖率门（行时间）来判。
            durationMs: candidate.durationMs,
            rawLRC: text,
            rawKRC: nil
        )
    }

    private static func document(fromKRC text: String, candidate: Candidate) -> SherryLyricDocument? {
        // KRC 文本本身就是行 + 逐字标签；LyricParser 按 KRC 相对偏移解析。
        var lines = LyricParser.parse(text, wordRaw: text, wordFormat: .kugouKRC)
        guard !lines.isEmpty else {
            CoLogger.shared.log("歌词解析为空：酷狗 id=\(candidate.id) fmt=krc 行数=0", level: .debug)
            return nil
        }
        // KRC 自带的 [language:] 翻译（base64 JSON），按行号贴到对应行。
        let translations = krcTranslations(text)
        if !translations.isEmpty {
            for index in lines.indices where index < translations.count {
                lines[index].translation = translations[index]
            }
        }
        let tags = krcMetadata(text)
        let wordSynced = lines.contains { $0.hasWordTimings }
        return SherryLyricDocument(
            source: .kugou,
            timing: wordSynced ? .wordSynced : .synced,
            lines: lines,
            title: resolvedTitle(tagTitle: tags["ti"], candidateTitle: candidate.title),
            artists: tags["ar"].map { SherryLyricsMatcher.splitArtists($0) } ?? candidate.artists,
            album: tags["al"] ?? candidate.album,
            durationMs: candidate.durationMs,
            rawLRC: text,
            rawKRC: text
        )
    }

    private static func download(id: String, accessKey: String, format: String) async -> Data? {
        var components = URLComponents(string: searchBase + "/download")!
        components.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "accesskey", value: accessKey),
            URLQueryItem(name: "fmt", value: format),
            URLQueryItem(name: "charset", value: "utf8"),
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await get(url: url)
            let response = try JSONDecoder().decode(DownloadResponse.self, from: data)
            guard let raw = Data(base64Encoded: response.content.replacingOccurrences(of: "\n", with: "")) else {
                CoLogger.shared.log("歌词下载失败：酷狗 id=\(id) fmt=\(format) content 不是 base64", level: .debug)
                return nil
            }
            return raw
        } catch {
            CoLogger.shared.log("歌词下载失败：酷狗 id=\(id) fmt=\(format) \(error.localizedDescription)", level: .debug)
            return nil
        }
    }

    private static func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            CoLogger.shared.log("歌词请求失败：\(url.host ?? "")\(url.path) HTTP \(http.statusCode)", level: .debug)
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// KRC 解码：krc1 魔数 → 16 字节固定 XOR → zlib 流。
    /// 解码逻辑源自 Lyricify Lyrics Helper (Apache-2.0)；每条失败路径都记日志，
    /// 不再静默吞掉（旧代码 try? / guard-return-empty 是 R1/R3 的一部分）。
    static func decodeKRC(_ data: Data, candidateID: String) -> String? {
        guard data.count > 4 else {
            CoLogger.shared.log("KRC 解码失败：id=\(candidateID) 数据过短（\(data.count) 字节）", level: .debug)
            return nil
        }
        guard data.prefix(4) == Data("krc1".utf8) else {
            CoLogger.shared.log("KRC 解码失败：id=\(candidateID) 缺少 krc1 魔数", level: .debug)
            return nil
        }
        let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
                            0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69]
        var encrypted = Array(data.dropFirst(4))
        for index in encrypted.indices { encrypted[index] ^= key[index % key.count] }
        // XOR 后是完整 RFC 1950 zlib 流；COMPRESSION_ZLIB 吃原始 DEFLATE，
        // 所以先剥 2 字节 zlib 头 + 4 字节 Adler 尾（失败时保留原流再试一次）。
        let payload = stripZlibWrapper(encrypted) ?? encrypted
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
        guard !output.isEmpty else {
            CoLogger.shared.log("KRC 解码失败：id=\(candidateID) zlib 解压 0 字节", level: .debug)
            return nil
        }
        guard let text = String(data: output, encoding: .utf8), !text.isEmpty else {
            CoLogger.shared.log("KRC 解码失败：id=\(candidateID) 解压后不是 UTF-8 文本", level: .debug)
            return nil
        }
        return text
    }

    private static func stripZlibWrapper(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 7 else { return nil }
        let cmf = bytes[0]
        let flg = bytes[1]
        guard (cmf & 0x0f) == 8, (Int(cmf) * 256 + Int(flg)) % 31 == 0 else { return nil }
        var payloadStart = 2
        if (flg & 0x20) != 0 { payloadStart += 4 }
        let payloadEnd = bytes.count - 4
        guard payloadStart < payloadEnd else { return nil }
        return Array(bytes[payloadStart..<payloadEnd])
    }

    /// KRC 头标签 [ti:]/[ar:]/[al:]。
    static func krcMetadata(_ raw: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            guard line.hasPrefix("["), let separator = line.firstIndex(of: ":"),
                  let end = line.lastIndex(of: "]"), separator < end else { continue }
            let keyStart = line.index(after: line.startIndex)
            let valueStart = line.index(after: separator)
            let key = String(line[keyStart..<separator]).lowercased()
            if ["ti", "ar", "al"].contains(key) {
                values[key] = String(line[valueStart..<end])
            }
        }
        return values
    }

    /// KRC [language:] 行：base64 JSON，type 1 是翻译、type 0 是罗马音。
    /// 按行号贴回对应行（翻译行数与原文行数一致时才贴）。
    static func krcTranslations(_ raw: String) -> [String] {
        struct Entry: Decodable { let type: Int; let lyricContent: [[String]] }
        struct Language: Decodable { let content: [Entry] }
        guard let languageLine = raw.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("[language:") }),
              let end = languageLine.lastIndex(of: "]") else { return [] }
        let start = languageLine.index(languageLine.startIndex, offsetBy: "[language:".count)
        let encoded = String(languageLine[start..<end])
        guard let data = Data(base64Encoded: encoded),
              let language = try? JSONDecoder().decode(Language.self, from: data) else {
            CoLogger.shared.log("KRC 翻译解析失败：[language:] 行解码失败", level: .debug)
            return []
        }
        return language.content.first(where: { $0.type == 1 })?
            .lyricContent.map { $0.joined() } ?? []
    }
}
