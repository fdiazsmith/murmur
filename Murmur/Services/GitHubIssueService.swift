import Foundation

enum IssueType: String, CaseIterable {
    case bug = "Bug Report"
    case feature = "Feature Request"

    var label: String {
        switch self {
        case .bug: "bug"
        case .feature: "enhancement"
        }
    }
}

enum GitHubIssueService {
    private static let repo = "fdiazsmith/murmur"

    static func submit(type: IssueType, title: String, description: String) async throws -> URL {
        let token = deobfuscateToken()
        guard !token.isEmpty else { throw IssueError.missingToken }

        let url = URL(string: "https://api.github.com/repos/\(repo)/issues")!

        let systemInfo = """
        ---
        **Murmur version:** \(AppVersion.current)
        **macOS:** \(ProcessInfo.processInfo.operatingSystemVersionString)
        """

        let body: [String: Any] = [
            "title": "[\(type.label)] \(title)",
            "body": "\(description)\n\n\(systemInfo)",
            "labels": [type.label],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw IssueError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw IssueError.apiError(statusCode: http.statusCode, message: msg)
        }

        // Parse issue URL from response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let htmlURL = json["html_url"] as? String,
           let issueURL = URL(string: htmlURL) {
            return issueURL
        }

        throw IssueError.invalidResponse
    }

    private static func deobfuscateToken() -> String {
        guard !GitHubToken.obfuscated.isEmpty else { return "" }
        let key = GitHubToken.key
        var result = [UInt8]()
        for (i, byte) in GitHubToken.obfuscated.enumerated() {
            result.append(byte ^ key[i % key.count])
        }
        return String(bytes: result, encoding: .utf8) ?? ""
    }

    enum IssueError: LocalizedError {
        case missingToken
        case invalidResponse
        case apiError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingToken: "GitHub token not configured"
            case .invalidResponse: "Invalid response from GitHub"
            case .apiError(let code, let msg): "GitHub API error (\(code)): \(msg)"
            }
        }
    }
}
