import SwiftUI

/// A capability row's text (the catalog card's name, description and pills): the title with its tags, then up to
/// two lines of description.
struct CapabilityRowLabel: View {
    let title: String
    var subtitle: String?
    var tags: [CapabilityTag] = []
    var meta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            CapabilityFlow(spacing: Theme.Spacing.sm, lineSpacing: Theme.Spacing.xxs) {
                Text(title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                ForEach(tags) { tag in
                    StatusTag(tag.text, tone: tag.tone, systemImage: tag.systemImage)
                }
                if let meta {
                    Text(meta).hermesText(.meta).foregroundStyle(Theme.Text.quaternary).lineLimit(1)
                }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Lays views out in rows, wrapping at the container's width (the desktop's `flex-wrap` pill rows). A view
/// wider than the row is offered the row's width, so a long title truncates instead of overflowing.
struct CapabilityFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat?

    /// The bounds a row is placed in can come back rounded to the pixel grid, a hair narrower than the width it
    /// measured: without some slack the last pill would wrap onto a line the measured height has no room for.
    private static let slack: CGFloat = 0.5

    private func sizes(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard let width, ideal.width > width else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for size in sizes(subviews, width: limit) {
            if x > 0, let limit, x + size.width > limit + Self.slack {
                y += rowHeight + (lineSpacing ?? spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: limit.map { min(widest, $0) } ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for (subview, size) in zip(subviews, sizes(subviews, width: bounds.width)) {
            if x > bounds.minX, x + size.width > bounds.maxX + Self.slack {
                y += rowHeight + (lineSpacing ?? spacing)
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One pill beside a row title.
struct CapabilityTag: Identifiable, Hashable {
    var text: String
    var tone: StatusTag.Tone = .muted
    var systemImage: String?

    var id: String { text }
}

/// A row that opens its page with a tap and keeps a trailing control (a switch, an add button) tappable on its
/// own: list rows can't nest a control inside a navigation link.
struct CapabilityRow<Trailing: View>: View {
    let label: CapabilityRowLabel
    let open: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Button(action: open) { label }
                .buttonStyle(.plain)
            trailing()
        }
    }
}

/// A tailed background-action log (skill installs, post-setup runs).
struct CapabilityActionLog: View {
    let lines: [String]
    var placeholder = "Starting…"

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? placeholder : lines.joined(separator: "\n"))
                .font(Theme.TextStyle.code.font)
                .foregroundStyle(Theme.Text.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
        }
        .frame(maxHeight: 180)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
        .defaultScrollAnchor(.bottom)
    }
}

/// A full-width loader for a list that hasn't loaded yet.
struct CapabilityLoader: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xxl)
            .listRowBackground(Color.clear)
    }
}

/// A list that failed to load, with a retry (`CatalogAlert`).
struct CapabilityLoadFailure: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: Theme.Icon.error)
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry)
        }
        .listRowBackground(Color.clear)
    }
}

/// The empty state (`CapabilityEmpty`): query-aware, spanning the list.
struct CapabilityEmpty: View {
    let noun: String
    let query: String

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        ContentUnavailableView("No \(noun) found", systemImage: Theme.Icon.search,
                               description: Text(trimmed.isEmpty ? "No \(noun) available yet." : "Nothing matches “\(trimmed)”."))
            .listRowBackground(Color.clear)
    }
}

/// A short confirmation that fades out (the desktop's success toasts).
struct CapabilityNotice: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        .hermesFloating(radius: Theme.Radius.widget)
                        .padding(.horizontal, Theme.Spacing.page)
                        .padding(.bottom, Theme.Spacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onTapGesture { self.message = nil }
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(4))
                            withAnimation { self.message = nil }
                        }
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.easeOut(duration: 0.2), value: message)
    }
}

extension View {
    /// Shows `message` briefly at the bottom; nil hides it.
    func capabilityNotice(_ message: Binding<String?>) -> some View {
        modifier(CapabilityNotice(message: message))
    }

    /// The Capabilities list look: rows on the page background over the sidebar tone.
    func capabilityList() -> some View {
        listStyle(.insetGrouped)
            .hermesForm()
            .scrollDismissesKeyboard(.immediately)
    }
}

/// A destructive or consequential action waiting for a yes.
struct CapabilityConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: String
    var destructive = true
    let run: () async -> Void
}

extension View {
    /// Asks before `pending` runs (delete, uninstall, update, …).
    func capabilityConfirmation(_ pending: Binding<CapabilityConfirmation?>) -> some View {
        confirmationDialog(pending.wrappedValue?.title ?? "", isPresented: Binding(get: { pending.wrappedValue != nil },
                                                                                 set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: pending.wrappedValue) { confirmation in
            Button(confirmation.action, role: confirmation.destructive ? .destructive : nil) {
                Task { await confirmation.run() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
