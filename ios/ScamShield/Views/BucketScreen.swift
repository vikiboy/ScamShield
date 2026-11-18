import SwiftUI

/// One tab's list (Attention, Review or Scams) with its navigation stack.
struct BucketScreen: View {
    let bucket: Bucket
    @Environment(InboxStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack(path: Binding(get: { router.path(for: bucket) },
                                      set: { router.setPath($0, for: bucket) })) {
            content
                .navigationTitle(bucket.title)
                .statusSubtitle(subtitle)
                .navigationDestination(for: ItemRoute.self) { route in
                    ItemDetailView(itemID: route.id)
                }
                .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder private var content: some View {
        switch bucket {
        case .attention: AttentionList(subtitle: subtitle)
        case .review: ReviewList(subtitle: subtitle)
        case .scam: ScamList(subtitle: subtitle)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if store.hasLoaded { parts.append("\(store.openCount(bucket)) open") }
        if let problem = store.problem {
            parts.append(problem.shortDescription)
        } else if store.isRefreshing, !store.hasLoaded {
            parts.append("Checking for calls…")
        } else if let checked = store.lastChecked {
            parts.append("Updated \(Format.ago(checked).lowercased())")
        }
        return parts.joined(separator: " · ")
    }
}

private extension View {
    /// The nav-bar subtitle exists from iOS 26; earlier systems show it at the top of the list.
    @ViewBuilder func statusSubtitle(_ text: String) -> some View {
        if #available(iOS 26, *) {
            navigationSubtitle(text)
        } else {
            self
        }
    }
}

/// Status line for systems without a navigation subtitle, plus any sync problem.
private struct ListStatus: View {
    let subtitle: String
    @Environment(InboxStore.self) private var store

    var body: some View {
        if #unavailable(iOS 26), !subtitle.isEmpty {
            Section {
            } header: {
                Text(subtitle).textCase(nil)
            }
        }
        // Without cached calls the full-screen FirstLoadView explains the problem instead.
        if let problem = store.problem, store.hasLoaded {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(problem.shortDescription, systemImage: problem.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(problem == .inboxDownloading ? Color.secondary : Color(.systemOrange))
                    Text(problemDetail(problem))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await store.refresh() } }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                        .disabled(store.isRefreshing)
                }
                .padding(.vertical, 2)
            }
        }
        if store.unsyncedCount > 0 {
            Section {
                Label("\(store.unsyncedCount) \(store.unsyncedCount == 1 ? "change is" : "changes are") waiting for iCloud Drive",
                      systemImage: "icloud.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func problemDetail(_ problem: SyncError) -> String {
        let message = problem.errorDescription ?? ""
        guard let checked = store.lastChecked else { return message }
        return message + " Showing calls from \(Format.ago(checked).lowercased())."
    }
}

extension SyncError {
    var symbol: String {
        switch self {
        case .inboxDownloading: "icloud.and.arrow.down"
        case .inboxMissing: "desktopcomputer"
        default: "exclamationmark.icloud"
        }
    }
}

/// Shown while there's no cached inbox yet: a spinner, or why the first read failed.
private struct FirstLoadView: View {
    @Environment(InboxStore.self) private var store

    var body: some View {
        if let problem = store.problem, !store.isRefreshing {
            ContentUnavailableView {
                Label(problem.shortDescription, systemImage: problem.symbol)
            } description: {
                Text(problem.errorDescription ?? "")
            } actions: {
                Button("Try Again") { Task { await store.refresh() } }
                    .buttonStyle(.bordered)
            }
        } else {
            ProgressView("Checking for calls…")
        }
    }
}

private struct CallLink: View {
    let item: Item

    var body: some View {
        NavigationLink(value: ItemRoute(id: item.id)) {
            CallRow(item: item)
        }
        .accessibilityIdentifier("callRow.\(item.id)")
        .modifier(DoneSwipe(item: item))
    }
}

// MARK: - Attention

private struct AttentionList: View {
    let subtitle: String
    private let bucketID = "attention"
    @Environment(InboxStore.self) private var store

    var body: some View {
        let items = store.openItems(in: .attention)
        List {
            ListStatus(subtitle: subtitle)
            ForEach(items.groupedByDay(), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { CallLink(item: $0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("list.\(bucketID)")
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Seen") { store.markAllAttentionSeen() }
                        .accessibilityLabel("Mark all as seen")
                        .accessibilityIdentifier("attention.seenAll")
                }
            }
        }
        .overlay {
            if !store.hasLoaded {
                FirstLoadView()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("You’re all caught up", systemImage: "checkmark.shield")
                } description: {
                    Text("Calls that need you, like appointments, deliveries and people you know, will show up here.")
                }
            }
        }
    }
}

// MARK: - Review

private struct ReviewList: View {
    let subtitle: String
    private let bucketID = "review"
    @Environment(InboxStore.self) private var store
    @State private var showNoMessage = false

    var body: some View {
        let open = store.openItems(in: .review)
        let withMessage = open.filter { $0.category != "no_message" }
            .sorted { lhs, rhs in
                if (lhs.voicemail != nil) != (rhs.voicemail != nil) { return lhs.voicemail != nil }
                return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
            }
        let noMessage = open.filter { $0.category == "no_message" }
        List {
            ListStatus(subtitle: subtitle)
            if !withMessage.isEmpty {
                Section("Left a message") {
                    ForEach(withMessage) { CallLink(item: $0) }
                }
            }
            if !noMessage.isEmpty {
                Section(isExpanded: $showNoMessage) {
                    ForEach(noMessage) { CallLink(item: $0) }
                } header: {
                    Button {
                        withAnimation { showNoMessage.toggle() }
                    } label: {
                        HStack {
                            Text("No message left")
                            Text("\(noMessage.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showNoMessage ? 90 : 0))
                                .foregroundStyle(.tint)
                                .imageScale(.small)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showNoMessage ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("review.noMessageToggle")
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("list.\(bucketID)")
        .overlay {
            if !store.hasLoaded {
                FirstLoadView()
            } else if open.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to review", systemImage: "checkmark.shield")
                } description: {
                    Text("Calls ScamShield isn’t sure about will wait here for a quick look.")
                }
            }
        }
    }
}

// MARK: - Scams

private struct ScamList: View {
    let subtitle: String
    @Environment(InboxStore.self) private var store
    @State private var showDone = false
    @State private var confirmArchive = false

    var body: some View {
        let all = store.items.filter { $0.bucket == .scam }
        let shown = all.filter { $0.done == showDone }
        let openCount = all.count(where: { !$0.done })
        let known = Bucket.scam.categories
        let order = known + Set(shown.map(\.category)).subtracting(known).sorted()
        List {
            Section {
                Picker("Show", selection: $showDone) {
                    Text("Open").tag(false)
                    Text("Done").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("scams.filter")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            ListStatus(subtitle: subtitle)
            ForEach(order, id: \.self) { category in
                let group = shown.filter { $0.category == category }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { CallLink(item: $0) }
                    } header: {
                        HStack(spacing: 4) {
                            Text(Category.label(category))
                            Text("· \(group.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .accessibilityIdentifier("list.scam")
        .overlay {
            if !store.hasLoaded {
                FirstLoadView()
            } else if shown.isEmpty {
                ContentUnavailableView {
                    Label(showDone ? "No archived scam calls" : "No scam calls", systemImage: "xmark.shield")
                } description: {
                    Text(showDone
                         ? "Scam calls you mark as done stay here for 30 days."
                         : "Fraud, robocalls and sales calls are filed here so they never interrupt you.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Archive All") { confirmArchive = true }
                    .disabled(openCount == 0)
                    .accessibilityIdentifier("scams.archiveAll")
            }
        }
        .confirmationDialog("Archive all scam calls?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive \(openCount) \(openCount == 1 ? "Call" : "Calls")", role: .destructive) {
                store.archiveAllScams()
            }
        } message: {
            Text("\(openCount) \(openCount == 1 ? "call" : "calls") will be marked as done. You can still find them under Done.")
        }
    }
}
