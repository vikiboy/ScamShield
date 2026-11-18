import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// First run (or lost access): explains the iCloud Drive folder and opens the Files picker.
struct OnboardingView: View {
    let problem: String?
    @Environment(InboxStore.self) private var store
    @State private var showPicker = false
    @State private var pendingURL: URL?
    @State private var pickError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.white, Color.accentColor.gradient)
                    .padding(.top, 48)
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Welcome to ScamShield")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Your Mac screens missed calls and voicemails. This iPhone shows you the ones that matter.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color(.systemOrange))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemOrange).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }

                VStack(alignment: .leading, spacing: 18) {
                    Step(number: 1, symbol: "desktopcomputer",
                         text: "ScamShield on your Mac creates a **ScamShield** folder in iCloud Drive.")
                    Step(number: 2, symbol: "folder",
                         text: "Tap **Choose Folder**, open **iCloud Drive**, select the **ScamShield** folder, then tap **Open**.")
                    Step(number: 3, symbol: "bell.badge",
                         text: "Allow notifications to hear about calls that need you.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    showPicker = true
                } label: {
                    Text("Choose Folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                Text("Only the ScamShield folder is shared with this app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .sheet(isPresented: $showPicker) {
            FolderPicker { url in
                if SyncFolder(url: url).looksLikeScamShieldFolder() {
                    use(url)
                } else {
                    pendingURL = url
                }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("This doesn’t look like the ScamShield folder", isPresented: Binding(
            get: { pendingURL != nil }, set: { if !$0 { pendingURL = nil } }), titleVisibility: .visible) {
            Button("Use “\(pendingURL?.lastPathComponent ?? "Folder")” Anyway") {
                if let url = pendingURL { use(url) }
            }
            Button("Choose Another Folder") { showPicker = true }
        } message: {
            Text("It has no calls from your Mac yet. If ScamShield on your Mac hasn’t synced yet, you can still use it.")
        }
        .alert("Couldn’t use that folder", isPresented: Binding(get: { pickError != nil },
                                                                set: { if !$0 { pickError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickError ?? "")
        }
    }

    private func use(_ url: URL) {
        do {
            try store.useFolder(url)
        } catch {
            pickError = error.localizedDescription
        }
    }
}

private struct Step: View {
    let number: Int
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number). ") + Text(text))
    }
}

/// The Files folder picker (UIDocumentPickerViewController for `.folder`).
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
