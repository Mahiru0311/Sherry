import Foundation

/// LRCLIB (https://lrclib.net) 匿名兜底：无 key，酷狗搜不到或候选全不匹配时用。
/// 机制参考 LyricsIsland (MIT) 的 LRCLIBClient，按 Sherry 模型改写。
enum SherryLRCLIB {
    private static let baseURL = URL(string: "https://lrclib.net")!
    private static let userAgent = "Sherry/2.2.2 (personal project)"
    private static let timeout: TimeInterval = 15

    struct Response: Decodable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        /// 秒。
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// 兜底链：/api/get（带专辑）→ /api/get（不带专辑）→ /api/search
    /// （标题+歌手）→ /api/search（仅标题，无歌手串）。
    /// 404 = 无结果（继续下一环），其他错误直接抛给调用方记日志。
    /// P1-3：/api/get 失败时（歌手串对不上是常见原因）补一次仅标题搜索。
    static func fetchLyrics(
        title: String,
        artist: String,
        album: String?,
        durationMs: Int?
    ) async -> SherryLyricDocument? {
        let normTitle = SherryLyricsMatcher.normalizeTitle(title)
        let normArtist = SherryLyricsMatcher.normalizeArtist(artist)
        let normAlbum = album.map { SherryLyricsMatcher.normalizeTitle($0) }
        let durationSec = durationMs.map { Int((Double($0) / 1000).rounded()) }
        do {
            if let hit = try await get(track: normTitle, artist: normArtist, album: normAlbum, duration: durationSec) {
                return document(from: hit, title: title, artists: [artist])
            }
            if normAlbum != nil,
               let hit = try await get(track: normTitle, artist: normArtist, album: nil, duration: durationSec) {
                return document(from: hit, title: title, artists: [artist])
            }
            if let doc = try await searchBest(
                track: normTitle, artist: normArtist,
                title: title, artists: [artist], durationMs: durationMs
            ) {
                return doc
            }
            // 标题-only 搜索：歌手串对不上时 /api/get 与带歌手搜索都空，
            // 仅标题常能命中（再按标题 + 时长挑最好的）。
            if !normArtist.isEmpty,
               let doc = try await searchBest(
                   track: normTitle, artist: "",
                   title: title, artists: [artist], durationMs: durationMs
               ) {
                CoLogger.shared.log("歌词兜底：LRCLIB 标题-only 搜索命中 \(title)", level: .debug)
                return doc
            }
            CoLogger.shared.log("歌词兜底：LRCLIB 无匹配：\(title) - \(artist)", level: .debug)
            return nil
        } catch {
            CoLogger.shared.log("歌词兜底失败：LRCLIB \(error.localizedDescription)", level: .debug)
            return nil
        }
    }

    /// /api/search 一次：搜 → 按标题与时长挑最好的，命中返回文档。
    private static func searchBest(
        track: String,
        artist: String,
        title: String,
        artists: [String],
        durationMs: Int?
    ) async throws -> SherryLyricDocument? {
        let candidates = try await search(track: track, artist: artist)
        let tuples = candidates.map { (
            trackName: $0.trackName,
            durationSeconds: $0.duration,
            hasSyncedLyrics: $0.syncedLyrics?.isEmpty == false
        ) }
        if let bestIndex = SherryLyricsMatcher.bestLRCLIBMatch(from: tuples, title: title, durationMs: durationMs) {
            CoLogger.shared.log("歌词兜底：LRCLIB /api/search 命中 \(candidates[bestIndex].trackName ?? title)", level: .debug)
            return document(from: candidates[bestIndex], title: title, artists: artists)
        }
        return nil
    }

    private static func document(
        from response: Response,
        title: String,
        artists: [String]
    ) -> SherryLyricDocument? {
        if response.instrumental == true {
            // 纯音乐：有歌词行但无内容 —— 返回空行文档，调用方按"无歌词"处理，
            // 不再反复请求（由负缓存兜底 24 小时）。
            return SherryLyricDocument(
                source: .lrclib, timing: .plain, lines: [],
                title: response.trackName ?? title, artists: artists,
                album: response.albumName,
                durationMs: response.duration.map { Int(($0 * 1000).rounded()) },
                rawLRC: "", rawKRC: nil
            )
        }
        if let synced = response.syncedLyrics, !synced.isEmpty {
            let lines = LyricParser.parse(synced)
            guard !lines.isEmpty else { return nil }
            return SherryLyricDocument(
                source: .lrclib, timing: .synced, lines: lines,
                title: response.trackName ?? title,
                artists: response.artistName.map { SherryLyricsMatcher.splitArtists($0) } ?? artists,
                album: response.albumName,
                durationMs: response.duration.map { Int(($0 * 1000).rounded()) },
                rawLRC: synced, rawKRC: nil
            )
        }
        if let plain = response.plainLyrics, !plain.isEmpty {
            let lines = LyricParser.parse(plain)
            guard !lines.isEmpty else { return nil }
            return SherryLyricDocument(
                source: .lrclib, timing: .plain, lines: lines,
                title: response.trackName ?? title,
                artists: response.artistName.map { SherryLyricsMatcher.splitArtists($0) } ?? artists,
                album: response.albumName,
                durationMs: response.duration.map { Int(($0 * 1000).rounded()) },
                rawLRC: plain, rawKRC: nil
            )
        }
        return nil
    }

    private static func get(track: String, artist: String, album: String?, duration: Int?) async throws -> Response? {
        var items = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration { items.append(URLQueryItem(name: "duration", value: String(duration))) }
        guard let data = try await perform(path: "/api/get", queryItems: items) else { return nil }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func search(track: String, artist: String) async throws -> [Response] {
        var items = [URLQueryItem(name: "track_name", value: track)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard let data = try await perform(path: "/api/search", queryItems: items) else { return [] }
        return try JSONDecoder().decode([Response].self, from: data)
    }

    /// 404 返回 nil（驱动兜底链），其他非 200 抛错。
    private static func perform(path: String, queryItems: [URLQueryItem]) async throws -> Data? {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200: return data
        case 404: return nil
        default:
            CoLogger.shared.log("歌词兜底失败：LRCLIB \(path) HTTP \(http.statusCode)", level: .debug)
            throw URLError(.badServerResponse)
        }
    }
}
