import SwiftUI

/// One collapsible group of the status stack (the desktop's `StatusSection`): an icon, a label and an optional
/// accessory in the header; a spinner stands in for the rows while it is collapsed and something runs.
struct StatusSection<Content: View, Accessory: View>: View {
    let icon: String
    var tint: Color = Theme.Text.tertiary
    let label: String
    var running = false
    @State var expanded: Bool
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(icon: String, tint: Color = Theme.Text.tertiary, label: String, running: Bool = false, expanded: Bool = false,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.tint = tint
        self.label = label
        self.running = running
        _expanded = State(initialValue: expanded)
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: icon)
                            .font(.system(size: Theme.IconSize.xs))
                            .foregroundStyle(tint)
                            .frame(width: Theme.IconSize.sm)
                        Text(label)
                            .hermesText(.label)
                            .foregroundStyle(Theme.Text.secondary)
                        if running, !expanded {
                            ProgressView().controlSize(.mini)
                        }
                        Image(systemName: Theme.Icon.disclosure)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Text.quaternary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint(expanded ? "Collapses the group" : "Expands the group")
                accessory()
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            if expanded {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.bottom, Theme.Spacing.xs)
            }
        }
    }
}

/// A row inside a status section: a leading glyph, the body, and trailing controls.
struct StatusRow<Leading: View, Content: View, Trailing: View>: View {
    var depth = 0
    var highlighted = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            // As tall as a first caption line, so a glyph or spinner sits beside it.
            leading()
                .frame(width: Theme.IconSize.sm, height: 18)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.leading, Theme.Spacing.lg + CGFloat(depth) * Theme.Spacing.lg)
        .padding(.trailing, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(highlighted ? Theme.Fill.rowActive : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
    }
}

/// A small icon button for status rows.
struct StatusRowButton: View {
    let systemImage: String
    let label: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.IconSize.xs, weight: .medium))
                .foregroundStyle(role == .destructive ? Theme.destructive : Theme.Text.tertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
