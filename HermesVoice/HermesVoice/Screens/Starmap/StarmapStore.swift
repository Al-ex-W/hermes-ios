import Foundation

/// The star map's data and timeline (`store/starmap.ts` and the map's reveal state): the profile's learning graph,
/// laid out off the main thread, the reveal the scrubber sets or playback eases through, and the node actions.
@MainActor
final class StarmapStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase = Phase.loading
    @Published private(set) var graph = LearningGraph()
    @Published private(set) var layout = StarmapLayout()
    /// The profile mapped; nil is the dashboard's own.
    @Published private(set) var profile: String?
    /// 1 shows the whole map; lower hides what the timeline hasn't reached.
    @Published var reveal: Double = 1
    @Published private(set) var playing = false
    @Published var selected: String?
    @Published var notice: String?

    /// A full play-through, start to end.
    static let playDuration: TimeInterval = 9

    private let transport: CapabilitiesTransport
    private var loadGeneration = 0
    private var playback: Task<Void, Never>?

    init(transport: CapabilitiesTransport, profile: String?) {
        self.transport = transport
        self.profile = profile
    }

    var api: LearningAPI { LearningAPI(transport: transport, profile: profile) }

    var selectedStar: StarmapLayout.Star? {
        selected.flatMap { id in layout.stars.first { $0.id == id } }
    }

    // MARK: Loading

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if graph.nodes.isEmpty { phase = .loading }
        do {
            let graph = try await api.graph()
            let layout = await Task.detached(priority: .userInitiated) { StarmapLayout(graph: graph) }.value
            guard generation == loadGeneration else { return }
            self.graph = graph
            self.layout = layout
            if let selected, !graph.nodes.contains(where: { $0.id == selected }) { self.selected = nil }
            phase = .loaded
        } catch {
            guard generation == loadGeneration, !error.isCancellation else { return }
            if graph.nodes.isEmpty {
                phase = .failed(error.dashboardMessage)
            } else {
                notice = "Could not load memory graph. \(error.dashboardMessage)"
            }
        }
    }

    /// Another profile's map.
    func setProfile(_ next: String?) async {
        guard next != profile else { return }
        profile = next
        stop()
        graph = LearningGraph()
        layout = StarmapLayout()
        selected = nil
        reveal = 1
        await load()
    }

    // MARK: Timeline

    /// Plays the map building up from the core (from the current point when part-way, else from the start).
    func play() {
        stop()
        let start = reveal >= 0.999 ? 0 : reveal
        reveal = start
        playing = true
        playback = Task { [weak self] in
            let from = Self.invEase(start)
            let began = Date()
            let duration = Self.playDuration * (1 - from)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self, !Task.isCancelled else { return }
                let progress = duration > 0 ? min(1, from + Date().timeIntervalSince(began) / Self.playDuration) : 1
                self.reveal = Self.ease(progress)
                if progress >= 1 {
                    self.reveal = 1
                    self.playing = false
                    self.playback = nil
                    return
                }
            }
        }
    }

    func stop() {
        playback?.cancel()
        playback = nil
        playing = false
    }

    /// Smoothstep relaxed toward linear, so the middle never rushes (`cineEase`).
    nonisolated static func ease(_ t: Double) -> Double {
        let u = min(1, max(0, t))
        let gentle = 0.45
        return gentle * u + (1 - gentle) * (u * u * (3 - 2 * u))
    }

    nonisolated static func invEase(_ y: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if ease(mid) < y { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    // MARK: Node actions

    func detail(_ id: String) async throws -> LearningNodeDetail {
        try await api.node(id)
    }

    /// Saves new text and reads the map again.
    func save(_ id: String, content: String) async throws {
        let message = try await api.edit(id, content: content)
        notice = message.isEmpty ? "Saved." : message
        await load()
    }

    /// Archives a skill or deletes a memory: it leaves the map at once and comes back if Hermes refuses.
    func remove(_ star: StarmapLayout.Star) async {
        let previousGraph = graph, previousLayout = layout
        evict(star.id)
        do {
            let message = try await api.delete(star.id)
            notice = message.isEmpty ? nil : message
            await load()
        } catch {
            graph = previousGraph
            layout = previousLayout
            notice = error.dashboardMessage
        }
    }

    private func evict(_ id: String) {
        graph.nodes.removeAll { $0.id == id }
        graph.edges.removeAll { $0.source == id || $0.target == id }
        layout.stars.removeAll { $0.id == id }
        layout.edges.removeAll { $0.source == id || $0.target == id }
        if selected == id { selected = nil }
    }
}
