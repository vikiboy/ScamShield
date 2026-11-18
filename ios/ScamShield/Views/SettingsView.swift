import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(InboxStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var showPicker = false
    @State private var pickError: String?

    var body: some View {
        NavigationStack {
            Form {
                folderSection
                macSection
                notificationsSection
                aboutSection
            }
            .accessibilityIdentifier("settings.form")
            .navigationTitle("Settings")
            .refreshable { await store.refresh() }
            .task { notificationStatus = await Notifier.authorizationStatus() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { notificationStatus = await Notifier.authorizationStatus() }
            }
            .sheet(isPresented: $showPicker) {
                FolderPicker { url in
                    do {
                        try store.useFolder(url)
                    } catch {
                        pickError = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Couldn’t use that folder", isPresented: Binding(get: { pickError != nil },
                                                                    set: { if !$0 { pickError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(pickError ?? "")
            }
        }
    }

    // MARK: sections

    private var folderSection: some View {
        Section {
            LabeledContent("Folder") {
                Text(store.folder?.url.lastPathComponent ?? "None")
            }
            LabeledContent("Status") {
                StatusDot(ok: store.problem == nil && store.hasLoaded,
                          text: store.problem?.shortDescription ?? (store.lastChecked.map { "Synced " + Format.ago($0).lowercased() } ?? "Waiting"))
            }
            LabeledContent("Last checked", value: Format.ago(store.lastChecked))
            LabeledContent("Calls updated by Mac", value: Format.ago(store.inbox?.generatedAt))
            if store.unsyncedCount > 0 {
                LabeledContent("Waiting to upload", value: "\(store.unsyncedCount)")
            }
            Button {
                Task { await store.refresh() }
            } label: {
                HStack {
                    Label("Check Now", systemImage: "arrow.clockwise")
                    if store.isRefreshing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(store.isRefreshing)
            Button {
                showPicker = true
            } label: {
                Label("Change Folder…", systemImage: "folder")
            }
        } header: {
            Text("iCloud Drive")
        } footer: {
            if store.folderSource == .debugOverride {
                Text("Using the folder from the -ScamShieldFolder launch argument (debug build).")
            } else if let problem = store.problem {
                Text(problem.errorDescription ?? "")
            } else {
                Text("Your Mac writes calls to this folder, and your changes go back the same way.")
            }
        }
    }

    @ViewBuilder private var macSection: some View {
        let mac = store.inbox?.mac
        Section {
            LabeledContent("Last check for calls", value: Format.ago(mac?.lastIngest))
            LabeledContent("Last call seen", value: Format.ago(mac?.lastCallSeen))
            if let voicemail = mac?.lastVoicemailSeen {
                LabeledContent("Last voicemail seen", value: Format.ago(voicemail))
            }
            LabeledContent("Classifier") {
                if let models = mac?.models {
                    StatusDot(ok: models.isOK, text: models.description)
                } else {
                    Text("Unknown")
                }
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("ScamShield on your Mac reads your synced call history and voicemails, sorts missed calls, and updates this iPhone through iCloud Drive.")
        }
    }

    private var notificationsSection: some View {
        Section {
            LabeledContent("Alerts") {
                switch notificationStatus {
                case .authorized, .provisional, .ephemeral: StatusDot(ok: true, text: "On")
                case .denied: StatusDot(ok: false, text: "Off")
                case .notDetermined: Text("Not set up")
                default: Text("…")
                }
            }
            switch notificationStatus {
            case .notDetermined:
                Button {
                    Task {
                        await Notifier.requestAuthorization()
                        notificationStatus = await Notifier.authorizationStatus()
                    }
                } label: {
                    Label("Turn On Notifications", systemImage: "bell.badge")
                }
            case .denied:
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                } label: {
                    Label("Open iPhone Settings", systemImage: "gear")
                }
            default:
                EmptyView()
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("You’ll get an alert when a missed call needs your attention. Alerts arrive when iOS lets ScamShield refresh in the background, usually within minutes to an hour; open the app to update instantly. Review and Scams never alert you.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
        } header: {
            Text("About")
        } footer: {
            Text("App expires: apps installed with a free Apple account stop opening after 7 days. Your Mac re-installs ScamShield automatically each week while this iPhone is connected or on the same Wi-Fi, so you shouldn’t need to do anything.")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }
}

private struct StatusDot: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color(.systemGreen) : Color(.systemOrange))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text)
        }
    }
}
