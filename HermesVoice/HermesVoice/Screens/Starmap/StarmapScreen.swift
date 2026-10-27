import SwiftUI

/// The desktop's star map ("Memory Graph", `app/starmap`), simplified for a phone: what Hermes learned for a profile
/// (skills as dots that grow with use, memories as diamonds) on a top-down disk where time is radial, oldest at the
/// core, with dated rings; related skills are linked. Drag to pan, pinch to zoom, double-tap to fit; tap a node for
/// its details, where it can be read, edited, archived (a skill) or deleted (a memory; both ask first). The timeline
/// above scrubs or plays the map building up. The desktop's share codes and hover tooltips are left out.
struct StarmapScreen: View {
    /// What the screen needs from the shell.
    struct Context {
        let client: DashboardClient
        /// The sidebar's profile, or `SidebarOptions.allProfiles` (then the dashboard's own profile).
        var profileScope: String = SidebarOptions.allProfiles
    }

    let context: Context
    @StateObject private var store: StarmapStore
    @StateObject private var profiles = ProfileScopeModel()
    @State private var viewing: StarmapNodeTarget?

    init(context: Context) {
        self.context = context
        let scope = context.profileScope == SidebarOptions.allProfiles ? nil : context.profileScope
        _store = StateObject(wrappedValue: StarmapStore(transport: context.client, profile: scope))
    }

    var body: some View {
        content
            .background(Theme.background)
            .navigationTitle("Memory Graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await store.load() } } label: { Image(systemName: Theme.Icon.retry) }
                        .accessibilityLabel("Refresh")
                }
                if profiles.profiles.count > 1 {
                    ToolbarItem(placement: .secondaryAction) {
                        Picker("Profile", selection: profileBinding) {
                            ForEach(profiles.profiles) { Text(ProfileScopeSection.label($0)).tag($0.name) }
                        }
                    }
                }
            }
            .task { if store.graph.nodes.isEmpty, store.phase == .loading { await store.load() } }
            .task { await profiles.load(context.client) }
            .onDisappear { store.stop() }
            .sheet(item: $viewing) { target in StarmapNodeSheet(store: store, star: target.star) }
            .capabilityNotice($store.notice)
    }

    private var profileBinding: Binding<String> {
        Binding(get: { store.profile ?? profiles.dashboardProfile },
                set: { name in Task { await store.setProfile(name == profiles.dashboardProfile ? nil : name) } })
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView()
                .accessibilityLabel("Loading memory graph")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Could not load memory graph", systemImage: Theme.Icon.warning)
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await store.load() } }
            }
        case .loaded where store.graph.nodes.isEmpty:
            ContentUnavailableView("Nothing learned yet", systemImage: "lightbulb",
                                   description: Text("As Hermes builds skills and memories for your work, they appear here."))
        case .loaded:
            VStack(spacing: 0) {
                StarmapTimeline(store: store)
                ZStack(alignment: .bottom) {
                    StarmapCanvas(store: store)
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if let star = store.selectedStar {
                            StarmapSelectionCard(star: star) { viewing = StarmapNodeTarget(star: star) }
                        }
                        StarmapLegend(graph: store.graph)
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
    }
}

struct StarmapNodeTarget: Identifiable {
    let star: StarmapLayout.Star
    var id: String { star.id }
}

// MARK: - Map

/// The disk: rings, links and nodes, with pan, pinch, tap to select and double-tap to fit.
private struct StarmapCanvas: View {
    @ObservedObject var store: StarmapStore
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = store.layout
            let reveal = store.reveal
            let selected = store.selected
            let neighbors = selected.map(layout.neighbors) ?? []
            let camera = camera(size)
            Canvas { context, _ in
                draw(layout, reveal: reveal, selected: selected, neighbors: neighbors, camera: camera, in: &context)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    offset.width += value.translation.width
                    offset.height += value.translation.height
                })
            .simultaneousGesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                .onEnded { value in zoom = min(Self.maxZoom, max(Self.minZoom, zoom * value)) })
            // A double tap fits the map again; a single tap (once it can't be a double) selects.
            .gesture(SpatialTapGesture(count: 2).onEnded { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    zoom = 1
                    offset = .zero
                }
            }.exclusively(before: SpatialTapGesture().onEnded { value in select(at: value.location, camera: camera) }))
            .accessibilityElement()
            .accessibilityLabel("Memory graph")
            .accessibilityValue("\(layout.visibleStars(reveal).count) of \(layout.stars.count) nodes shown")
        }
        .clipped()
    }

    /// Map space → screen: the disk centred (a touch low, under the timeline) at a fit scale, then panned and zoomed.
    private struct Camera {
        var centerX: Double
        var centerY: Double
        var scale: Double
        /// The user's zoom over the fit.
        var zoom: Double

        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: centerX + x * scale, y: centerY + y * scale) }
    }

    private func camera(_ size: CGSize) -> Camera {
        let live = min(Self.maxZoom, max(Self.minZoom, zoom * pinch))
        let fit = Self.fitScale(size, extent: store.layout.extent)
        return Camera(centerX: size.width / 2 + offset.width + drag.width,
                      centerY: size.height / 2 + offset.height + drag.height,
                      scale: fit * live, zoom: live)
    }

    /// The zoom that fits the disk with a margin, never zoomed out past the 5-ring extent (a bigger map pans).
    static func fitScale(_ size: CGSize, extent: Double) -> Double {
        guard size.width > 0, size.height > 0 else { return 1 }
        let padding = 16.0
        func fit(_ radius: Double) -> Double {
            let span = (radius + 30) * 2
            return min((size.width - padding * 2) / span, (size.height - padding * 2) / span, 2.2)
        }
        return min(5, max(0.3, max(fit(extent), fit(StarmapLayout.ringOuter))))
    }

    private func select(at location: CGPoint, camera: Camera) {
        let x = (location.x - camera.centerX) / camera.scale
        let y = (location.y - camera.centerY) / camera.scale
        let hit = store.layout.star(at: x, y, slop: 14 / camera.scale, reveal: store.reveal)
        store.selected = hit?.id == store.selected ? nil : hit?.id
    }

    private func draw(_ layout: StarmapLayout, reveal: Double, selected: String?, neighbors: Set<String>,
                      camera: Camera, in context: inout GraphicsContext) {
        let center = camera.point(0, 0)
        // Rings, dated.
        for ring in layout.visibleRings(reveal) {
            let radius = ring.radius * camera.scale
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(Theme.Hairline.secondary), lineWidth: 1)
            if let label = ring.label {
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(Theme.Text.quaternary),
                             at: CGPoint(x: center.x, y: center.y - radius - 2), anchor: .bottom)
            }
        }
        let stars = layout.visibleStars(reveal)
        let shown = Dictionary(uniqueKeysWithValues: stars.map { ($0.id, $0) })
        // Links.
        for edge in layout.edges {
            guard let a = shown[edge.source], let b = shown[edge.target] else { continue }
            let lit = selected != nil && (edge.source == selected || edge.target == selected)
            var path = Path()
            path.move(to: camera.point(a.x, a.y))
            path.addLine(to: camera.point(b.x, b.y))
            context.stroke(path, with: .color(lit ? Theme.primary.opacity(0.7) : Theme.Text.quaternary.opacity(0.5)),
                           style: StrokeStyle(lineWidth: lit ? 1 : 0.6, dash: lit ? [] : [2, 3]))
        }
        // Nodes: skills round, memories diamonds; with a selection, the rest recede.
        // Zoomed well in, every node is named.
        let showLabels = camera.zoom > 2.4
        for star in stars {
            let point = camera.point(star.x, star.y)
            let radius = star.radius * 1.15
            let focused = selected == nil || star.id == selected || neighbors.contains(star.id)
            let ink = star.ink * (focused ? 1 : 0.28)
            let color = star.node.kind == .memory ? Theme.Semantic.purple : Theme.primary
            context.fill(Self.glyph(star.node.kind, at: point, radius: radius), with: .color(color.opacity(ink)))
            if star.id == selected {
                let halo = radius + 4
                context.stroke(Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                               with: .color(Theme.primary), lineWidth: 1.5)
            }
            if star.id == selected || (selected != nil && neighbors.contains(star.id)) || (showLabels && selected == nil) {
                context.draw(Text(star.node.label).font(.system(size: 10, weight: star.id == selected ? .semibold : .regular))
                                .foregroundColor(Theme.Text.secondary),
                             at: CGPoint(x: point.x, y: point.y + radius + 3), anchor: .top)
            }
        }
    }

    static func glyph(_ kind: LearningNode.Kind, at point: CGPoint, radius: Double) -> Path {
        if kind == .skill {
            return Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        var path = Path()
        path.move(to: CGPoint(x: point.x, y: point.y - radius))
        path.addLine(to: CGPoint(x: point.x + radius, y: point.y))
        path.addLine(to: CGPoint(x: point.x, y: point.y + radius))
        path.addLine(to: CGPoint(x: point.x - radius, y: point.y))
        path.closeSubpath()
        return path
    }
}

// MARK: - Timeline

/// The scrubber over the map: play/pause, the date reached, and a histogram of when things were learned.
private struct StarmapTimeline: View {
    @ObservedObject var store: StarmapStore

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                store.playing ? store.stop() : store.play()
            } label: {
                Image(systemName: store.playing ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(store.playing ? "Pause" : "Play")
            VStack(spacing: 2) {
                StarmapHistogram(buckets: store.layout.buckets, reveal: store.reveal)
                    .frame(height: 18)
                Slider(value: Binding(get: { store.reveal }, set: { store.stop(); store.reveal = $0 }), in: 0...1)
                    .accessibilityLabel("Timeline")
                    .accessibilityValue(store.layout.revealLabel(store.reveal))
            }
            Text(store.layout.revealLabel(store.reveal))
                .hermesText(.meta)
                .monospacedDigit()
                .foregroundStyle(Theme.Text.secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.background)
        .hermesHairline()
    }
}

private struct StarmapHistogram: View {
    let buckets: [StarmapLayout.Bucket]
    let reveal: Double

    var body: some View {
        Canvas { context, size in
            guard !buckets.isEmpty else { return }
            let peak = Double(max(1, buckets.map(\.total).max() ?? 1))
            let width = size.width / Double(buckets.count)
            for (index, bucket) in buckets.enumerated() where bucket.total > 0 {
                let lit = (Double(index) + 0.5) / Double(buckets.count) <= reveal
                let skillHeight = size.height * Double(bucket.skills) / peak
                let memoryHeight = size.height * Double(bucket.memories) / peak
                let x = Double(index) * width + 0.5
                context.fill(Path(CGRect(x: x, y: size.height - skillHeight, width: max(1, width - 1), height: skillHeight)),
                             with: .color(Theme.primary.opacity(lit ? 0.7 : 0.2)))
                context.fill(Path(CGRect(x: x, y: size.height - skillHeight - memoryHeight, width: max(1, width - 1),
                                         height: memoryHeight)),
                             with: .color(Theme.Semantic.purple.opacity(lit ? 0.7 : 0.2)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Overlays

/// "● skill ◆ memory" and the counts.
private struct StarmapLegend: View {
    let graph: LearningGraph

    var body: some View {
        let categories = Set(graph.nodes.filter { $0.kind == .skill }.map(\.category)).count
        HStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.xs) {
                Circle().fill(Theme.primary).frame(width: 7, height: 7)
                Text("skill")
            }
            HStack(spacing: Theme.Spacing.xs) {
                Rectangle().fill(Theme.Semantic.purple).frame(width: 6, height: 6).rotationEffect(.degrees(45))
                Text("memory")
            }
            Text("\(graph.skillCount) skills across \(categories) categories · \(graph.memoryCount) memories")
                .lineLimit(1)
        }
        .hermesText(.meta)
        .foregroundStyle(Theme.Text.tertiary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .hermesFloating(radius: Theme.Radius.widget)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The selected node: its name, tags and use count, and a way into its details.
private struct StarmapSelectionCard: View {
    let star: StarmapLayout.Star
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(star.node.label)
                        .hermesText(.rowTitle)
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(star.node.badges().joined(separator: " · "))
                        .hermesText(.meta)
                        .foregroundStyle(Theme.Text.tertiary)
                }
                Spacer(minLength: 0)
                if let count = star.node.countLabel {
                    Text(count).hermesText(.meta).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                }
                Image(systemName: Theme.Icon.disclosure).font(.system(size: 11)).foregroundStyle(Theme.Text.tertiary)
            }
            .padding(Theme.Spacing.lg)
            .hermesFloating(radius: Theme.Radius.widget)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows its details")
    }
}

// MARK: - Node details

/// A node's text, with edit and archive/delete (`node-context-menu.tsx`).
private struct StarmapNodeSheet: View {
    @ObservedObject var store: StarmapStore
    let star: StarmapLayout.Star

    @Environment(\.dismiss) private var dismiss
    @State private var detail: LearningNodeDetail?
    @State private var failure: String?
    /// Why a save failed (the text stays in the editor).
    @State private var saveFailure: String?
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @State private var confirmation: CapabilityConfirmation?

    private var noun: String { star.node.kind == .memory ? "memory" : "skill" }

    var body: some View {
        NavigationStack {
            Group {
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Spacing.md)
                        .disabled(saving)
                } else if let detail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            Text(star.node.badges().joined(separator: " · ") + (star.node.countLabel.map { " · \($0)" } ?? ""))
                                .hermesText(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                            Text(detail.content)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.Text.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(Theme.Spacing.page)
                    }
                } else if let failure {
                    ContentUnavailableView {
                        Label("Could not open this \(noun)", systemImage: Theme.Icon.error)
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .navigationTitle(editing ? "Edit \(star.node.label)" : star.node.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await load() }
            .capabilityConfirmation($confirmation)
            .failureAlert($saveFailure)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { editing = false }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            if let detail {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            draft = detail.content
                            editing = true
                        } label: { Label("Edit \(noun)…", systemImage: Theme.Icon.rename) }
                        Button(role: .destructive) { confirmation = removal } label: {
                            Label(star.node.kind == .skill ? "Archive skill" : "Delete memory",
                                  systemImage: star.node.kind == .skill ? Theme.Icon.archive : Theme.Icon.delete)
                        }
                    } label: {
                        Image(systemName: Theme.Icon.more)
                    }
                    .accessibilityLabel("Actions")
                }
            }
        }
    }

    private var removal: CapabilityConfirmation {
        let star = star, store = store
        if star.node.kind == .skill {
            return CapabilityConfirmation(
                title: "Archive \(star.node.label)?",
                message: "The skill moves to the archive; `hermes curator restore \(star.node.label)` brings it back.",
                action: "Archive"
            ) {
                dismiss()
                await store.remove(star)
            }
        }
        return CapabilityConfirmation(title: "Delete this memory?", message: "This memory is removed permanently.",
                                      action: "Delete") {
            dismiss()
            await store.remove(star)
        }
    }

    private func load() async {
        failure = nil
        do {
            detail = try await store.detail(star.id)
        } catch {
            guard !error.isCancellation else { return }
            failure = error.dashboardMessage
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await store.save(star.id, content: draft)
            detail?.content = draft
            editing = false
        } catch {
            saveFailure = error.dashboardMessage
        }
    }
}
