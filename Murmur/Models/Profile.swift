import Foundation

struct Profile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var prompt: String

    /// 3-4 letter abbreviation for the pill display
    var abbreviation: String {
        String(name.prefix(3)).lowercased()
    }

    static let general = Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "General", prompt: "")

    // MARK: - Persistence

    private static let profilesKey = "profiles"
    private static let selectedKey = "selectedProfileId"

    static func loadAll() -> [Profile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data),
              !profiles.isEmpty
        else { return [.general] }
        return profiles
    }

    static func saveAll(_ profiles: [Profile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    static func loadSelectedId() -> UUID {
        guard let str = UserDefaults.standard.string(forKey: selectedKey),
              let id = UUID(uuidString: str)
        else { return Profile.general.id }
        return id
    }

    static func saveSelectedId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: selectedKey)
    }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.removeObject(forKey: selectedKey)
    }
}
