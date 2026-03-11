import Foundation

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct AvailableUpdate: Equatable {
    let version: String
    let downloadURL: URL
}

final class UpdateChecker {
    private static let repo = "fdiazsmith/murmur"
    private static let checkIntervalKey = "lastUpdateCheck"

    static func checkIfNeeded() async -> AvailableUpdate? {
        let lastCheck = UserDefaults.standard.object(forKey: checkIntervalKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) > 86400 else { return nil } // 24h
        return await check()
    }

    static func check() async -> AvailableUpdate? {
        UserDefaults.standard.set(Date(), forKey: checkIntervalKey)

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        else { return nil }

        let remoteVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let currentVersion = AppVersion.current

        guard compareVersions(remoteVersion, isNewerThan: currentVersion) else { return nil }

        let dmgAsset = release.assets.first { $0.name.hasSuffix(".dmg") }
        guard let downloadURLString = dmgAsset?.browserDownloadURL ?? URL(string: release.htmlURL)?.absoluteString,
              let downloadURL = URL(string: downloadURLString)
        else { return nil }

        return AvailableUpdate(version: remoteVersion, downloadURL: downloadURL)
    }

    private static func compareVersions(_ remote: String, isNewerThan current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, c.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}
