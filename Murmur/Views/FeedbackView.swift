import SwiftUI

struct FeedbackView: View {
    @ObservedObject var appState: AppState
    let onDismiss: () -> Void

    @State private var issueType: IssueType

    init(appState: AppState, onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.onDismiss = onDismiss
        self._issueType = State(initialValue: appState.feedbackType)
    }
    @State private var title = ""
    @State private var description = ""
    @State private var isSubmitting = false
    @State private var submitResult: SubmitResult?

    enum SubmitResult: Equatable {
        case success(URL)
        case error(String)

        static func == (lhs: SubmitResult, rhs: SubmitResult) -> Bool {
            switch (lhs, rhs) {
            case (.success(let a), .success(let b)): a == b
            case (.error(let a), .error(let b)): a == b
            default: false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Type", selection: $issueType) {
                ForEach(IssueType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            Text("Description")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $description)
                .frame(minHeight: 120)
                .font(.body)
                .border(Color.secondary.opacity(0.3))

            if let result = submitResult {
                switch result {
                case .success:
                    Text("Submitted successfully!")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .error(let msg):
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSubmitting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Button("Submit") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.isEmpty || isSubmitting)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func submit() {
        isSubmitting = true
        submitResult = nil

        Task {
            do {
                let url = try await GitHubIssueService.submit(
                    type: issueType,
                    title: title,
                    description: description
                )
                submitResult = .success(url)
                try? await Task.sleep(for: .seconds(1.5))
                onDismiss()
            } catch {
                submitResult = .error(error.localizedDescription)
            }
            isSubmitting = false
        }
    }
}
