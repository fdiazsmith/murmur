import Foundation

struct TranscriptionEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
    }

    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    var truncatedText: String {
        if text.count <= 60 { return text }
        return String(text.prefix(57)) + "..."
    }
}
