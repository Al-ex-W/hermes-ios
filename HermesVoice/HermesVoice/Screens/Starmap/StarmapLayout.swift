import Foundation

/// The star map's geometry (`app/starmap/{time-axis,simulation,geometry}.ts`): time is radial, oldest at the core.
/// Every populated calendar bucket (days, weeks or months, picked so there are about 5–12) gets an equal-width
/// ring; a node sits inside its bucket's band at an angle seeded by its id, and a short relaxation pass keeps nodes
/// from overlapping (the desktop runs d3-force; this settles once, off the main thread). `reveal` (0…1) is the
/// timeline: a node shows once the reveal passes its ignite point, a ring once it passes the ring's.
struct StarmapLayout: Equatable {
    static let ringInner: Double = 58
    static let ringOuter: Double = 340
    static let ringSteps = 4
    /// The oldest node sits a little off the core, so a play-through opens on a beat of emptiness.
    static let leadIn = 0.06
    static let clusterSize = 5
    static let day: Double = 86_400

    struct Ring: Equatable {
        var label: String?
        var radius: Double
        /// The reveal it lights at.
        var ratio: Double
    }

    struct Star: Equatable, Identifiable {
        var node: LearningNode
        var x: Double
        var y: Double
        /// When it ignites on the timeline (0…1).
        var reveal: Double
        /// Its ring index.
        var ring: Int
        var radius: Double
        /// Ink strength by age: old quiet, new bright.
        var ink: Double

        var id: String { node.id }
    }

    struct Bucket: Equatable {
        var skills = 0
        var memories = 0
        var total: Int { skills + memories }
    }

    var rings: [Ring] = []
    var stars: [Star] = []
    var edges: [LearningGraph.Edge] = []
    /// The timeline's histogram over recency (48 bars), skills and memories apart.
    var buckets: [Bucket] = []
    var minTimestamp: Double?
    var maxTimestamp: Double?

    var timed: Bool {
        guard let minTimestamp, let maxTimestamp else { return false }
        return maxTimestamp > minTimestamp
    }

    /// The disk's outer radius (the newest ring).
    var extent: Double { rings.last?.radius ?? Self.ringOuter }

    init() {}

    init(graph: LearningGraph, relax iterations: Int = 80, labels: (Double, Unit) -> String = StarmapLayout.label) {
        let recency = Self.recency(graph.nodes)
        minTimestamp = recency.min
        maxTimestamp = recency.max
        let layout = Self.layout(graph.nodes, recency: recency, labels: labels)
        rings = layout.rings
        stars = graph.nodes.map { node in
            let radius = layout.place(node)
            let angle = Double(Self.hash(node.id) % 3600) / 3600 * 2 * .pi
            return Star(node: node, x: cos(angle) * radius, y: sin(angle) * radius, reveal: layout.reveal(node),
                        ring: layout.index(node), radius: Self.nodeRadius(node),
                        ink: Self.recencyInk(recency.rec[node.id] ?? 0))
        }
        edges = graph.edges
        buckets = Self.histogram(graph.nodes, recency: recency.rec)
        relax(iterations, targets: graph.nodes.map(layout.place))
    }

    /// Stars and rings lit at `reveal`.
    func visibleStars(_ reveal: Double) -> [Star] { stars.filter { $0.reveal <= reveal + 1e-6 } }
    func visibleRings(_ reveal: Double) -> [Ring] {
        let lit = rings.filter { $0.ratio <= reveal + 1e-6 }
        return lit.isEmpty ? Array(rings.prefix(1)) : lit
    }

    /// The date the timeline reads at `reveal`, or "n / total" for an undated graph.
    func revealLabel(_ reveal: Double) -> String {
        if timed, let minTimestamp, let maxTimestamp {
            return LearningGraph.formatDate(minTimestamp + min(1, max(0, reveal)) * (maxTimestamp - minTimestamp))
        }
        return "\(Int((reveal * Double(stars.count)).rounded())) / \(stars.count)"
    }

    /// The star under a point in map space, within `slop` of its edge.
    func star(at x: Double, _ y: Double, slop: Double, reveal: Double = 1) -> Star? {
        visibleStars(reveal)
            .map { ($0, hypot($0.x - x, $0.y - y) - $0.radius) }
            .filter { $0.1 <= slop }
            .min { $0.1 < $1.1 }?.0
    }

    /// Ids linked to `id`.
    func neighbors(of id: String) -> Set<String> {
        Set(edges.compactMap { $0.source == id ? $0.target : $0.target == id ? $0.source : nil })
    }

    // MARK: Recency (`computeRecency`)

    struct Recency {
        var min: Double?
        var max: Double?
        var rec: [String: Double]
    }

    static func recForRatio(_ ratio: Double) -> Double { leadIn + (1 - leadIn) * Swift.min(1, Swift.max(0, ratio)) }

    /// Each node's recency 0…1: linear in time when the graph spans time, else by order.
    static func recency(_ nodes: [LearningNode]) -> Recency {
        let known = nodes.compactMap(\.timestamp)
        let low = known.min(), high = known.max()
        let timed = low != nil && high != nil && high! > low!
        let ordered = nodes.sorted { a, b in
            let at = a.timestamp ?? .infinity, bt = b.timestamp ?? .infinity
            return at == bt ? a.id < b.id : at < bt
        }
        var ordinal: [String: Double] = [:]
        for (index, node) in ordered.enumerated() {
            ordinal[node.id] = ordered.count > 1 ? Double(index) / Double(ordered.count - 1) : 0
        }
        var rec: [String: Double] = [:]
        for node in nodes {
            let ratio: Double
            if timed, let timestamp = node.timestamp, let low, let high {
                ratio = (timestamp - low) / (high - low)
            } else {
                ratio = ordinal[node.id] ?? 0
            }
            rec[node.id] = recForRatio(ratio)
        }
        return Recency(min: low, max: high, rec: rec)
    }

    static func histogram(_ nodes: [LearningNode], recency: [String: Double], count: Int = 48) -> [Bucket] {
        var buckets = Array(repeating: Bucket(), count: count)
        for node in nodes {
            let index = Swift.min(count - 1, Swift.max(0, Int((recency[node.id] ?? 0) * Double(count))))
            if node.kind == .memory { buckets[index].memories += 1 } else { buckets[index].skills += 1 }
        }
        return buckets
    }

    // MARK: Rings (`buildLayout`)

    /// A calendar step: days or months.
    struct Unit: Equatable {
        enum Kind { case day, month }
        var kind: Kind
        var step: Int
    }

    static let units: [Unit] = [
        Unit(kind: .day, step: 1), Unit(kind: .day, step: 2), Unit(kind: .day, step: 7), Unit(kind: .day, step: 14),
        Unit(kind: .month, step: 1), Unit(kind: .month, step: 2), Unit(kind: .month, step: 3),
        Unit(kind: .month, step: 6), Unit(kind: .month, step: 12),
    ]

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The start of `timestamp`'s bucket (UTC; month steps align across years).
    static func bucketStart(_ timestamp: Double, _ unit: Unit) -> Double {
        switch unit.kind {
        case .day:
            let period = Double(unit.step) * day
            return (timestamp / period).rounded(.down) * period
        case .month:
            let parts = utc.dateComponents([.year, .month], from: Date(timeIntervalSince1970: timestamp))
            let absolute = ((parts.year ?? 1970) * 12 + (parts.month ?? 1) - 1) / unit.step * unit.step
            let start = utc.date(from: DateComponents(year: absolute / 12, month: absolute % 12 + 1, day: 1))
            return start?.timeIntervalSince1970 ?? timestamp
        }
    }

    static func populated(_ stamps: [Double], _ unit: Unit) -> [Double] {
        Array(Set(stamps.map { bucketStart($0, unit) })).sorted()
    }

    /// The unit whose populated bucket count lands nearest a target that grows with the span (5…12), ties and
    /// overshoot toward fewer.
    static func chooseUnit(_ stamps: [Double], spanDays: Double) -> Unit {
        let target = Double(Swift.min(12, Swift.max(5, Int((4 + log2(Swift.max(1, spanDays / 60))).rounded()))))
        var best = units[0]
        var bestScore = Double.infinity
        for unit in units {
            let count = Double(populated(stamps, unit).count)
            guard count > 0 else { continue }
            let score = abs(count - target) + (count > target ? 0.5 : 0)
            if score < bestScore {
                bestScore = score
                best = unit
            }
        }
        return best
    }

    /// A ring's date: the day for day steps, "Mar 2026" for months, the year for a 12-month step.
    static func label(_ start: Double, _ unit: Unit) -> String {
        let date = Date(timeIntervalSince1970: start)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch (unit.kind, unit.step) {
        case (.day, _): return LearningGraph.formatDate(start)
        case (.month, 12...): formatter.dateFormat = "yyyy"
        case (.month, _): formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
        }
        return formatter.string(from: date)
    }

    private static var ringCore: Double { radius(forRecency: recForRatio(0)) }
    private static var ringBand: Double { (radius(forRecency: recForRatio(1)) - ringCore) / Double(ringSteps) }
    static func ringRadius(_ index: Int) -> Double { ringCore + Double(index) * ringBand }
    static func radius(forRecency rec: Double) -> Double { ringInner + rec * (ringOuter - ringInner) }

    /// Inside its ring's band, biased to mid-band.
    static func placeRadius(_ index: Int, _ id: String) -> Double {
        let outer = ringRadius(index)
        let inner = index > 0 ? ringRadius(index - 1) : ringCore - ringBand * 0.5
        let h = Double(hash(id) % 1000) / 1000
        return outer - (0.15 + 0.7 * h) * (outer - inner)
    }

    private struct Placement {
        var rings: [Ring]
        var index: (LearningNode) -> Int
        var reveal: (LearningNode) -> Double
        var place: (LearningNode) -> Double
    }

    private static func layout(_ nodes: [LearningNode], recency: Recency, labels: (Double, Unit) -> String) -> Placement {
        let stamps = nodes.compactMap(\.timestamp)
        guard let low = recency.min, let high = recency.max, high > low, !stamps.isEmpty else {
            return even(recency)
        }
        let unit = chooseUnit(stamps, spanDays: (high - low) / day)
        let starts = populated(stamps, unit)
        guard starts.count >= 2 else { return even(recency) }
        let indexOfStart = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($0.element, $0.offset) })
        let last = Double(Swift.max(1, starts.count - 1))
        let rings = starts.enumerated().map { index, start in
            Ring(label: labels(start, unit), radius: ringRadius(index), ratio: recForRatio(Double(index) / last))
        }
        let indexFor: (LearningNode) -> Int = { node in
            guard let timestamp = node.timestamp else { return starts.count - 1 }
            return indexOfStart[bucketStart(timestamp, unit)] ?? starts.count - 1
        }
        var buckets = Array(repeating: [LearningNode](), count: starts.count)
        for node in nodes { buckets[indexFor(node)].append(node) }
        var reveal: [String: Double] = [:]
        for (index, bucket) in buckets.enumerated() {
            let sorted = bucket.sorted { a, b in
                let at = a.timestamp ?? .infinity, bt = b.timestamp ?? .infinity
                return at == bt ? a.id < b.id : at < bt
            }
            let hi = rings[index].ratio, lo = index > 0 ? rings[index - 1].ratio : 0
            let clusters = Swift.max(1, Int((Double(sorted.count) / Double(clusterSize)).rounded()))
            for (k, node) in sorted.enumerated() {
                let cluster = Swift.min(clusters - 1, Int(Double(k) / Double(sorted.count) * Double(clusters)))
                let jitter = (Double(hash(node.id) % 100) / 100 - 0.5) * (0.5 / Double(clusters))
                let f = Swift.min(1, Swift.max(0.02, Double(cluster + 1) / Double(clusters) + jitter))
                reveal[node.id] = lo + f * (hi - lo)
            }
        }
        return Placement(rings: rings, index: indexFor, reveal: { reveal[$0.id] ?? 0 },
                         place: { placeRadius(indexFor($0), $0.id) })
    }

    /// No usable time span: evenly spaced rings over the ordinal recency.
    private static func even(_ recency: Recency) -> Placement {
        let timed = recency.min != nil && recency.max != nil && recency.max! > recency.min!
        let rings = (0...ringSteps).map { index -> Ring in
            let fraction = Double(index) / Double(ringSteps)
            var label: String?
            if timed, let low = recency.min, let high = recency.max {
                label = LearningGraph.formatDate((low + (high - low) * fraction).rounded())
            }
            return Ring(label: label, radius: ringRadius(index), ratio: recForRatio(fraction))
        }
        let cap: (Double) -> Int = { rec in
            rings.firstIndex { $0.ratio >= rec - 1e-3 } ?? rings.count - 1
        }
        return Placement(rings: rings, index: { cap(recency.rec[$0.id] ?? 0) }, reveal: { recency.rec[$0.id] ?? 0 },
                         place: { radius(forRecency: recency.rec[$0.id] ?? 0) })
    }

    // MARK: Relaxation

    /// Pushes overlapping stars apart and pulls each back toward its ring, so a busy band reads as a populated
    /// ring rather than a pile (the desktop's collide + radial forces, settled once).
    private mutating func relax(_ iterations: Int, targets: [Double]) {
        guard stars.count > 1, iterations > 0 else { return }
        var xs = stars.map(\.x), ys = stars.map(\.y)
        let radii = stars.map(\.radius)
        for _ in 0..<iterations {
            for i in 0..<xs.count {
                for j in (i + 1)..<xs.count {
                    let dx = xs[j] - xs[i], dy = ys[j] - ys[i]
                    let minimum = radii[i] + radii[j] + 2
                    let distanceSquared = dx * dx + dy * dy
                    guard distanceSquared < minimum * minimum else { continue }
                    let distance = Swift.max(0.01, distanceSquared.squareRoot())
                    let push = (minimum - distance) / distance * 0.5
                    // Coincident stars part along a seeded direction.
                    let ux = distanceSquared < 1e-6 ? cos(Double(i)) : dx, uy = distanceSquared < 1e-6 ? sin(Double(i)) : dy
                    xs[i] -= ux * push
                    ys[i] -= uy * push
                    xs[j] += ux * push
                    ys[j] += uy * push
                }
            }
            for i in 0..<xs.count {
                let distance = Swift.max(0.01, hypot(xs[i], ys[i]))
                let pulled = distance + (targets[i] - distance) * 0.9
                xs[i] *= pulled / distance
                ys[i] *= pulled / distance
            }
        }
        for i in stars.indices {
            stars[i].x = xs[i]
            stars[i].y = ys[i]
        }
    }

    // MARK: Glyphs

    /// A memory is a fixed diamond; a skill grows with use, shrinks when archived or stale, and swells when pinned.
    static func nodeRadius(_ node: LearningNode) -> Double {
        if node.kind == .memory { return 4.4 }
        let base = node.state == "archived" || node.state == "stale" ? 2.4 : 3
        return base + Double(Swift.max(0, node.useCount)).squareRoot() * 0.55 + (node.pinned ? 0.8 : 0)
    }

    /// Smoothstep from old (quiet) to new (bright) ink.
    static func recencyInk(_ rec: Double) -> Double {
        let mid = 0.52, oldInk = 0.42, midInk = 0.74, newInk = 0.95
        let t = Swift.min(1, Swift.max(0, rec))
        if t <= mid {
            let p = t / mid
            return oldInk + (midInk - oldInk) * (p * p * (3 - 2 * p))
        }
        let p = (t - mid) / (1 - mid)
        return midInk + (newInk - midInk) * (p * p * (3 - 2 * p))
    }

    /// FNV-1a over UTF-16 units, as the desktop seeds angles (`hash`).
    static func hash(_ input: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for unit in input.utf16 {
            h ^= UInt32(unit)
            h = h &* 16_777_619
        }
        return h
    }
}
