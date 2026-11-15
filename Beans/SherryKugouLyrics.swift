import Compression
import Foundation

/// 一份抓到的歌词：来源、行级时间、逐字时间（如果有）、原始文本（供缓存）。
struct SherryLyricDocument {
    enum Source: String, Codable {
        case kugou
        case lrclib
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
}

/// 酷狗匿名歌词源（client=pc，无 token / cookie / dfid / 签名）。
///
/// 机制参考 LyricsIsland (MIT) 的 KugouLyricsProvider，KRC 解码逻辑源自
/// Lyricify Lyrics Helper (Apache-2.0)，按 Sherry 的模型与日志改写。
/// 实测结论（2026-11-15 curl 探针，见 CHANGELOG）：
/// - 搜索只带歌名 + 时长能命中；"歌手 歌名" + 时长经常返回 0 候选，
///   所以搜索顺序是：歌名+时长 → 歌名 → "歌名 歌手"。
/// - /download?fmt=krc 匿名可下，krc1 魔数 + 16 字节固定 XOR + zlib，
///   33/38 行带逐字标签 —— 匿名链本身是通的。
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
            let accessKey: String
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
                accessKey = try values.decode(String.self, forKey: .accessKey)
                singer = try values.decodeIfPresent(String.self, forKey: .singer)
                song = try values.decodeIfPresent(String.self, forKey: .song)
                duration = try values.decodeIfPresent(Int.self, forKey: .duration)
                krctype = try values.decodeIfPresent(Int.self, forKey: .krctype)
                contenttype = try values.decodeIfPresent(Int.self, forKey: .contenttype)
            }
        }

        let candidates: [Item]
    }

    private struct DownloadResponse: Decodable {
        let content: String
    }

    /// 搜索候选（只含元数据，不下载正文）。调用方按字典序排序后只取前 3 个下正文。
    static func search(
        title: String,
        artists: [String],
        album _: String?,
        durationMs: Int?
    ) async -> [Candidate] {
        // 探针结论："歌手 歌名" + 时长经常 0 候选；歌名 + 时长最稳。
        // 2.2.1：第三次尝试（"歌名 歌手"）实测基本查不到，还白白烧限流
        // 配额（连续查歌时搜索接口会限流，返回 200 空候选），直接去掉，
        // 只留两次：歌名+时长 → 歌名。
        let attempts: [(keyword: String, duration: Int?)] = [
            (title, durationMs),
            (title, nil),
        ]
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
                    guard seen.insert(item.id).inserted else { continue }
                    out.append(Candidate(
                        id: item.id,
                        accessKey: item.accessKey,
                        title: item.song ?? title,
                        artists: SherryLyricsMatcher.splitArtists(item.singer ?? ""),
                        album: nil,
                        durationMs: item.duration,
                        hasKRC: (item.krctype ?? 0) == 1 && (item.contenttype ?? 0) != 1
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
    static func document(for candidate: Candidate, wantedDurationMs: Int?) async -> SherryLyricDocument? {
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
            title: tags["ti"] ?? candidate.title,
            artists: tags["ar"].map { SherryLyricsMatcher.splitArtists($0) } ?? candidate.artists,
            album: tags["al"] ?? candidate.album,
            durationMs: candidate.durationMs ?? wantedDurationMs,
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
            title: tags["ti"] ?? candidate.title,
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
