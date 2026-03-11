import Foundation

enum AppVersion {
    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? buildVersion
    // Updated by scripts/bundle.sh — fallback for swift run
    static let buildVersion = "0.1.0"
}
