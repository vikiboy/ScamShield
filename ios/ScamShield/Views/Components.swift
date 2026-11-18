import SwiftUI

extension Bucket {
    var tint: Color {
        switch self {
        case .attention: .accentColor
        case .review: Color(.systemGray)
        case .scam: Color(.systemRed)
        }
    }

    var symbol: String {
        switch self {
        case .attention: "bell"
        case .review: "tray"
        case .scam: "xmark.shield"
        }
    }
}

/// Round caller badge: initials for named callers, a warning glyph for scams.
struct Avatar: View {
    let item: Item
    var large = false

    @ScaledMetric(relativeTo: .body) private var smallSize = 40
    @ScaledMetric(relativeTo: .largeTitle) private var largeSize = 84

    var body: some View {
        let size = large ? largeSize : smallSize
        ZStack {
            Circle().fill(background)
            content
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if item.bucket == .scam {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: (large ? largeSize : smallSize) * 0.42, weight: .semibold))
        } else if let initials = initials, !initials.isEmpty {
            Text(initials)
        } else {
            Image(systemName: "person.fill")
        }
    }

    private var initials: String? {
        guard let name = item.avatarName else { return nil }
        let words = name.split(whereSeparator: \.isWhitespace).filter { $0.first?.isLetter == true }
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    private var background: AnyShapeStyle {
        switch item.bucket {
        case .attention: AnyShapeStyle(Color.accentColor.gradient)
        case .review: AnyShapeStyle(Color(.systemGray4).gradient)
        case .scam: AnyShapeStyle(Color(.systemRed).opacity(0.16))
        }
    }

    private var foreground: Color {
        switch item.bucket {
        case .attention: .white
        case .review: .white
        case .scam: Color(.systemRed)
        }
    }
}

/// Small tinted capsule, e.g. "Medical" or "Attention · Medical".
struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Lays children out left to right, wrapping onto new lines (meta rows at large text sizes).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let current = rows.count - 1
            rows[current].width += rows[current].indices.isEmpty ? size.width : size.width + spacing
            rows[current].height = max(rows[current].height, size.height)
            rows[current].indices.append(index)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// One call in a list: avatar, name, time, summary and a meta line.
struct CallRow: View {
    let item: Item
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the time moves under the name so the name isn't truncated away.
        let stacked = typeSize.isAccessibilitySize
        let titleLayout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        HStack(alignment: .top, spacing: 12) {
            Avatar(item: item)
            VStack(alignment: .leading, spacing: 4) {
                titleLayout {
                    (Text(item.title).fontWeight(.semibold)
                        + Text(item.callCount > 1 ? " (\(item.callCount))" : "").foregroundStyle(.secondary))
                        .lineLimit(stacked ? 3 : 1)
                    if !stacked { Spacer(minLength: 4) }
                    Text(Format.rowTime(item.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                FlowLayout(spacing: 10) {
                    Chip(text: Category.label(item.category), tint: item.bucket.tint)
                    if item.done {
                        Chip(text: "Done", tint: Color(.systemGreen))
                    }
                    if let voicemail = item.voicemail {
                        Label(item.hasVoicemailDuration ? Format.duration(voicemail.durationSec) : "Voicemail",
                              systemImage: "recordingtape")
                            .labelStyle(MetaLabelStyle())
                            .foregroundStyle(.secondary)
                    }
                    if item.showsCallBack, item.callbackRecommended {
                        Label("Call back", systemImage: "phone.fill")
                            .labelStyle(MetaLabelStyle())
                            .foregroundStyle(Color(.systemGreen))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows call details")
    }
}

private struct MetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
    }
}

/// Trailing swipe that marks a call done (or reopens it).
struct DoneSwipe: ViewModifier {
    let item: Item
    @Environment(InboxStore.self) private var store

    func body(content: Content) -> some View {
        content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                store.setDone([item.id], done: !item.done)
            } label: {
                Label(item.done ? "Reopen" : "Done",
                      systemImage: item.done ? "arrow.uturn.backward" : "checkmark.circle")
            }
            .tint(item.done ? Color(.systemBlue) : Color(.systemGreen))
        }
    }
}

/// Floating capsule above the tab bar with an optional Undo button; hides itself.
struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let undo = toast.undo {
                Button("Undo") {
                    dismiss()
                    undo()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 24)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(toast.undo == nil ? 3 : 5))
            dismiss()
        }
        .accessibilityAddTraits(.isStaticText)
    }
}
