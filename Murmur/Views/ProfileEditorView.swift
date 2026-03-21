import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var appState: AppState
    let profile: Profile?
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""

    /// Whisper accepts ~224 tokens. ~4 chars/token = ~800 chars safe limit.
    private static let charLimit = 800

    private var isEditing: Bool { profile != nil }
    private var charCount: Int { prompt.count }
    private var isOverLimit: Bool { charCount > Self.charLimit }

    private var counterColor: Color {
        let ratio = Double(charCount) / Double(Self.charLimit)
        if ratio > 1.0 { return .red }
        if ratio > 0.8 { return .orange }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Profile" : "New Profile")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Context prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(charCount) / \(Self.charLimit)")
                    .font(.caption)
                    .foregroundStyle(counterColor)
            }

            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 80)
                .border(isOverLimit ? Color.red.opacity(0.5) : Color.secondary.opacity(0.3))

            if isOverLimit {
                Text("Prompt too long — Whisper will truncate beyond ~224 tokens")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                Text("Helps Whisper with domain vocabulary, e.g. technical terms, names")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") {
                    save()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            if let profile {
                name = profile.name
                prompt = profile.prompt
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if var existing = profile {
            existing.name = trimmedName
            existing.prompt = prompt
            appState.updateProfile(existing)
        } else {
            appState.addProfile(name: trimmedName, prompt: prompt)
        }
    }
}
