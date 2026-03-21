import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var appState: AppState
    let profile: Profile?
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""

    private var isEditing: Bool { profile != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Profile" : "New Profile")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Context prompt (helps Whisper with vocabulary)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.3))

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
        .frame(width: 320)
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
