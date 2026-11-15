import Foundation

/// Beans 服务器远程配置。只应用明确接入的安全配置项，不执行云端代码。
@MainActor
final class RemoteControlStore: ObservableObject {
    static let shared = RemoteControlStore()

    private let configURL = URL(string: "http://189.24.78.193/beans/config.json")!
    private let appliedKeysKey = "co.remoteControl.appliedKeys"
    private let originalPrefix = "co.remoteControl.original."
    private var isLoading = false
    private var lastRefresh = Date.distantPast

    private init() {}

    func refreshIfNeeded(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastRefresh) > 120 else { return }
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            lastRefresh = Date()
        }

        do {
            var request = URLRequest(url: configURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Sherry/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.0")", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let payload = try JSONDecoder.coSnakeCase.decode(RemoteConfig.self, from: data)
            apply(payload)
        } catch {
            CoLogger.shared.log("远程配置同步失败：\(error.localizedDescription)", level: .debug)
        }
    }

    private func apply(_ config: RemoteConfig) {
        // 旧版本曾支持 App 云控；服务端移除后启动时清理历史覆盖值。
        // 2.2.3：公告写入已删除（全仓库 0 处读取 co.remoteAnnouncement.*），
        // 远端配置拉取本身保留（服务端用途未确认）。
        clearRemoteOverrides()
    }

    private func clearRemoteOverrides() {
        let defaults = UserDefaults.standard
        for key in defaults.stringArray(forKey: appliedKeysKey) ?? [] {
            if let original = defaults.object(forKey: originalPrefix + key) {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            defaults.removeObject(forKey: originalPrefix + key)
        }
        defaults.removeObject(forKey: appliedKeysKey)
        defaults.synchronize()
    }
}

private struct RemoteConfig: Decodable {
    let enabled: Bool
    let announcement: String
    let announcementEnabled: Bool
    let announcementImageURL: String?
    let announcementMediaURL: String?
    let announcementMediaType: String?
    let announcementTextColor: String?
    let updatedAt: String?
}

private extension JSONDecoder {
    static var coSnakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
