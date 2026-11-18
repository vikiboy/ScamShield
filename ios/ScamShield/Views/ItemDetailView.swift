import SwiftUI

struct ItemDetailView: View {
    let itemID: String
    @Environment(InboxStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        if let item = store.item(withID: itemID) {
            ItemDetailContent(item: item)
        } else if !store.hasLoaded || store.isRefreshing {
            ProgressView()
        } else {
            ContentUnavailableView("Call not found", systemImage: "phone.badge.waveform",
                                   description: Text("This call may have been removed from your history."))
        }
    }
}

private struct ItemDetailContent: View {
    let item: Item
    @Environment(InboxStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showMove = false
    @State private var confirmBlock = false

    var body: some View {
        List {
            header
            if let summary = item.summary, !summary.isEmpty {
                Section("What they wanted") {
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            Section("Voicemail") {
                if let voicemail = item.voicemail {
                    VoicemailSection(voicemail: voicemail)
                } else {
                    Text("No voicemail was left.")
                        .foregroundStyle(.secondary)
                }
            }
            reasonsSection
            if item.hasPhoneNumber {
                reputationSection
            }
            actionsSection
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("detail.list")
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMove) {
            MoveSheet(item: item)
        }
        .confirmationDialog(blockTitle, isPresented: $confirmBlock, titleVisibility: .visible) {
            Button(store.isBlocked(item) ? "Unblock Number" : "Block Number",
                   role: store.isBlocked(item) ? nil : .destructive) {
                store.setBlocked(item, block: !store.isBlocked(item))
            }
        } message: {
            Text(store.isBlocked(item)
                 ? "Calls from this number will be screened normally again."
                 : "Future calls from this number will be filed under Scams as blocked.")
        }
        .onAppear {
            if router.moveSheetItemID == item.id {
                router.moveSheetItemID = nil
                showMove = true
            }
        }
    }

    private var blockTitle: String {
        let who = item.shownNumber ?? item.number
        return store.isBlocked(item) ? "Unblock \(who)?" : "Block \(who)?"
    }

    // MARK: header

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                Avatar(item: item, large: true)
                    .padding(.bottom, 2)
                Text(item.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                Text(Format.longDate(item.date) + (item.callCount > 1 ? " · \(item.callCount) calls in 24h" : ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                FlowLayout(spacing: 6) {
                    Chip(text: "\(item.bucket.title) · \(Category.label(item.category))", tint: item.bucket.tint)
                    if item.done { Chip(text: "Done", tint: Color(.systemGreen)) }
                    if item.userLabeled { Chip(text: "Labeled by you") }
                }
                if item.showsCallBack, let url = item.callBackURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label(item.callBackLabel, systemImage: "phone.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color(.systemGreen))
                    .padding(.top, 8)
                    if item.callbackRecommended, let probability = item.callback?.probability {
                        Text("Worth a call back · \(Format.percent(probability)) likely")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
        }
    }

    // MARK: reasons

    private var reasonsSection: some View {
        Section("Why it’s here") {
            ForEach(Array(item.reasons.enumerated()), id: \.offset) { _, reason in
                Label {
                    Text(reason)
                } icon: {
                    Image(systemName: item.bucket == .scam ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(item.bucket == .scam ? Color(.systemRed) : item.bucket.tint)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Confidence", value: Format.percent(item.confidence))
                ProgressView(value: min(max(item.confidence ?? 0, 0), 1))
                    .tint(item.bucket.tint)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: reputation

    @ViewBuilder private var reputationSection: some View {
        let rep = item.reputation
        Section("Number reputation") {
            if let rep, (rep.complaints ?? 0) > 0 || (rep.score ?? 0) > 0 || (rep.robocallShare ?? 0) > 0 {
                LabeledContent("Spam score", value: Format.percent(rep.score))
                LabeledContent("Complaints", value: (rep.complaints ?? 0).formatted())
                LabeledContent("Last reported", value: rep.lastReported.map { Format.rowTime($0) } ?? "Never")
                LabeledContent("Robocall share", value: Format.percent(rep.robocallShare))
            } else {
                Text("No spam reports for this number")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: actions

    private var actionsSection: some View {
        Section {
            Button {
                if item.done {
                    store.setDone([item.id], done: false)
                } else {
                    store.setDone([item.id], done: true)
                    dismiss()
                }
            } label: {
                Label(item.done ? "Mark as Not Done" : "Mark as Done",
                      systemImage: item.done ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            .accessibilityIdentifier("detail.done")
            Button {
                showMove = true
            } label: {
                Label("Move to…", systemImage: "folder")
            }
            .accessibilityIdentifier("detail.move")
            if item.hasPhoneNumber {
                Button(role: store.isBlocked(item) ? nil : .destructive) {
                    confirmBlock = true
                } label: {
                    Label(store.isBlocked(item) ? "Unblock Number" : "Block Number", systemImage: "nosign")
                }
            }
        }
    }
}

// MARK: - Voicemail

private struct VoicemailSection: View {
    let voicemail: Item.Voicemail
    @State private var expanded = false

    var body: some View {
        if voicemail.hasAudio {
            if let path = voicemail.audioFile {
                VoicemailPlayerView(relativePath: path, durationHint: voicemail.durationSec)
            } else {
                Label("The recording is only on your Mac. Recent voicemails are copied to this iPhone.",
                      systemImage: "desktopcomputer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        let text = (voicemail.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            Text(text.isEmpty ? "No transcript available." : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .lineLimit(expanded ? nil : 6)
                .textSelection(.enabled)
            HStack {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if text.count > 180 {
                    Button(expanded ? "Show Less" : "Show More") {
                        withAnimation { expanded.toggle() }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("transcript.toggle")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: String {
        var parts: [String] = []
        if (voicemail.durationSec ?? 0) > 0 { parts.append(Format.duration(voicemail.durationSec)) }
        if let confidence = voicemail.transcriptConfidence {
            parts.append(confidence < 0.6 ? "low-confidence transcript" : "transcript \(Format.percent(confidence)) confident")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Move sheet

struct MoveSheet: View {
    let item: Item
    @Environment(InboxStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var bucket: Bucket
    @State private var category: String
    @State private var always = false

    init(item: Item) {
        self.item = item
        _bucket = State(initialValue: item.bucket)
        _category = State(initialValue: item.category)
    }

    private var changed: Bool { always || bucket != item.bucket || category != item.category }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Section", selection: $bucket) {
                        ForEach(Bucket.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section("Category") {
                    ForEach(bucket.categories, id: \.self) { option in
                        Button {
                            category = option
                        } label: {
                            HStack {
                                Text(Category.label(option))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if option == category {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(option == category ? .isSelected : [])
                    }
                }
                if !item.number.isEmpty {
                    Section {
                        Toggle(item.hasPhoneNumber ? "Always for this number" : "Always for this caller", isOn: $always)
                    } footer: {
                        Text("Future calls from \(item.shownNumber ?? item.number) will be filed here too, and ScamShield learns from it.")
                    }
                }
            }
            .accessibilityIdentifier("move.form")
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("move.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.move(item, to: bucket, category: category, applyToNumber: always)
                        dismiss()
                    }
                    .disabled(!changed)
                }
            }
            .onChange(of: bucket) { _, newBucket in
                if !newBucket.categories.contains(category) {
                    category = newBucket == item.bucket ? item.category : newBucket.defaultCategory
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
