import AVFoundation
import os

private let speechLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesVoice", category: "CallAudio")

/// The books on Hermes' speech on the player: what is queued and not yet played (so that an engine rebuild can
/// schedule it again), and for each line what arrived, what has played and where playback ran dry.
///
/// "Played" is what the clock says: a player node plays what it is given back to back, so a chunk scheduled at
/// `t` behind a queue that ends at `e` plays from `max(t, e)` for its length. A marker's own played-back callback
/// (the truth) settles everything before it. Time is the caller's clock, in seconds, so tests script it.
struct PlaybackLedger {
    /// The player ran dry for at least this long while more of the line was still to come: a stall.
    static let minStall: TimeInterval = 0.1
    /// Taken off what the clock says has played when the engine is torn down under a line: what the hardware
    /// still held goes with the engine, and hearing a moment twice beats losing it.
    static let rebuildBackoff: TimeInterval = 0.12
    /// Audio this far behind the clock has certainly played: its buffers are let go.
    static let settleAfter: TimeInterval = 0.5
    /// How many lines the books are kept for.
    static let lineLimit = 8

    /// One thing on the player's queue: a chunk of a line's audio, or a marker (a played-back callback waiting).
    struct Item: Equatable {
        let id: UInt64
        let line: String?
        /// Frames still to play; 0 for a marker.
        var frames: Int
        let isMarker: Bool
        /// When it starts playing; nil while it is on no player (the engine is being rebuilt).
        var startsAt: TimeInterval?
    }

    /// One line's numbers, in frames.
    struct Stats: Equatable {
        var received = 0
        var played = 0
        var stalls = 0
        var stallSeconds: TimeInterval = 0
        var rebuilds = 0
        var routeChanges = 0
    }

    private(set) var rate: Double
    private(set) var items: [Item] = []
    /// The line whose audio is arriving.
    private(set) var line: String?
    private var stats: [String: Stats] = [:]
    private var order: [String] = []
    private var queueEnd: TimeInterval?
    private var nextID: UInt64 = 0

    init(rate: Double) {
        self.rate = rate > 0 ? rate : 24_000
    }

    /// When everything on the player finishes playing; nil when nothing is on it.
    var queuedUntil: TimeInterval? { queueEnd }

    /// Something waits for a player (the engine is being rebuilt).
    var hasUnscheduled: Bool { items.contains { $0.startsAt == nil } }

    /// A new sample rate; only between lines, with nothing queued.
    mutating func setRate(_ rate: Double) {
        if rate > 0 { self.rate = rate }
    }

    /// What is queued from here on belongs to `line`. A line that is begun again (the plugin repeats its start
    /// after a reconnect) keeps its numbers.
    mutating func begin(line id: String) {
        line = id
        guard stats[id] == nil else { return }
        stats[id] = Stats()
        order.append(id)
        while order.count > Self.lineLimit { stats[order.removeFirst()] = nil }
    }

    /// A chunk of the current line. `onPlayer`: it was handed to a player now (else it waits for one).
    @discardableResult
    mutating func enqueue(frames: Int, now: TimeInterval, onPlayer: Bool) -> UInt64 {
        nextID += 1
        var item = Item(id: nextID, line: line, frames: frames, isMarker: false, startsAt: nil)
        if let line, var numbers = stats[line] {
            // More of the line arrives after the player ran out of it: the user heard a gap.
            if onPlayer, numbers.received > 0, !hasUnscheduled, let end = queueEnd, now - end >= Self.minStall {
                numbers.stalls += 1
                numbers.stallSeconds += now - end
            }
            numbers.received += frames
            stats[line] = numbers
        }
        if onPlayer {
            let start = max(queueEnd ?? now, now)
            item.startsAt = start
            queueEnd = start + Double(frames) / rate
        }
        items.append(item)
        return item.id
    }

    /// A marker behind everything queued so far, for the current line.
    mutating func mark(now: TimeInterval, onPlayer: Bool) -> UInt64 {
        nextID += 1
        items.append(Item(id: nextID, line: line, frames: 0, isMarker: true,
                          startsAt: onPlayer ? max(queueEnd ?? now, now) : nil))
        return nextID
    }

    /// The marker's played-back callback came: everything before it has played. Returns the items that are done
    /// with (the marker among them); empty when the marker is not on the books.
    mutating func markerPlayed(_ id: UInt64) -> [Item] {
        guard let index = items.firstIndex(where: { $0.id == id && $0.isMarker }) else { return [] }
        let done = Array(items[...index])
        for item in done where !item.isMarker { credit(item.line, item.frames) }
        items.removeFirst(index + 1)
        if items.isEmpty { queueEnd = nil }
        return done
    }

    /// Lets go of leading audio that has certainly played. Returns those items.
    mutating func settle(now: TimeInterval) -> [Item] {
        var done: [Item] = []
        while let first = items.first, !first.isMarker, let start = first.startsAt,
              start + Double(first.frames) / rate <= now - Self.settleAfter {
            credit(first.line, first.frames)
            done.append(items.removeFirst())
        }
        return done
    }

    /// Everything queued is dropped (the line was cancelled, or the engine is gone for good): what had played by
    /// the clock counts as played. Returns the markers that were waiting, in order.
    mutating func flush(now: TimeInterval) -> [UInt64] {
        for item in items where !item.isMarker { credit(item.line, playedFrames(item, now)) }
        let markers = items.filter(\.isMarker).map(\.id)
        items.removeAll()
        queueEnd = nil
        return markers
    }

    /// The engine is torn down to be rebuilt: what has not played stays, to be scheduled again. Returns, for each
    /// audio item, how many frames to cut off its head (all of them: it is done with).
    mutating func unschedule(now: TimeInterval) -> [(id: UInt64, frames: Int)] {
        guard items.contains(where: { $0.startsAt != nil }) || line.map({ stats[$0] != nil }) == true else { return [] }
        var cuts: [(id: UInt64, frames: Int)] = []
        var kept: [Item] = []
        for var item in items {
            if !item.isMarker {
                let played = playedFrames(item, now - Self.rebuildBackoff)
                credit(item.line, played)
                if played > 0 { cuts.append((item.id, played)) }
                item.frames -= played
                if item.frames == 0 { continue }
            }
            item.startsAt = nil
            kept.append(item)
        }
        items = kept
        queueEnd = nil
        for line in openLines { stats[line]?.rebuilds += 1 }
        return cuts
    }

    /// A player is there: what waited goes onto it, in order, from now. Returns those items.
    mutating func schedule(now: TimeInterval) -> [Item] {
        var cursor = max(queueEnd ?? now, now)
        var scheduled: [Item] = []
        for index in items.indices where items[index].startsAt == nil {
            items[index].startsAt = cursor
            cursor += Double(items[index].frames) / rate
            scheduled.append(items[index])
        }
        if !scheduled.isEmpty { queueEnd = cursor }
        return scheduled
    }

    /// The output route changed under the lines that are open.
    mutating func routeChanged() {
        for line in openLines { stats[line]?.routeChanges += 1 }
    }

    /// The line's numbers as of `now`.
    func facts(for line: String, now: TimeInterval) -> Stats? {
        guard var numbers = stats[line] else { return nil }
        for item in items where !item.isMarker && item.line == line { numbers.played += playedFrames(item, now) }
        return numbers
    }

    /// The line's numbers as of `now`, closing its books.
    mutating func take(line id: String, now: TimeInterval) -> Stats? {
        let numbers = facts(for: id, now: now)
        // What is still queued of it plays on, but no longer counts for anything.
        stats[id] = nil
        order.removeAll { $0 == id }
        if line == id { line = nil }
        return numbers
    }

    /// Lines with something still queued, and the one arriving.
    private var openLines: Set<String> {
        var open = Set(items.compactMap(\.line))
        if let line { open.insert(line) }
        return open
    }

    private func playedFrames(_ item: Item, _ now: TimeInterval) -> Int {
        guard let start = item.startsAt, now > start else { return 0 }
        return min(item.frames, Int(((now - start) * rate).rounded()))
    }

    /// Audio behind the last marker has not all played by `now`: no pending callback speaks for it.
    func hasUnplayedTail(now: TimeInterval) -> Bool {
        let tail = items.suffix(from: (items.lastIndex(where: \.isMarker) ?? -1) + 1)
        return tail.contains { playedFrames($0, now) < $0.frames }
    }

    private mutating func credit(_ line: String?, _ frames: Int) {
        if let line, frames > 0 { stats[line]?.played += frames }
    }
}

/// Bounds how often the call's audio engine is rebuilt, so that configuration changes that keep coming can't
/// spin it: a few rebuilds are free, more of them wait until a window has passed, and a call gets only so many.
struct RebuildBudget: Equatable {
    static let window: TimeInterval = 10
    static let freeInWindow = 4
    static let perCall = 40

    enum Verdict: Equatable {
        case now
        /// Too many lately: try again after this long.
        case after(TimeInterval)
        /// The call has used up its rebuilds.
        case never
    }

    /// Rebuilds granted on this call.
    private(set) var count = 0
    private var recent: [TimeInterval] = []

    mutating func next(at now: TimeInterval) -> Verdict {
        guard count < Self.perCall else { return .never }
        recent.removeAll { now - $0 >= Self.window }
        if recent.count >= Self.freeInWindow, let oldest = recent.first {
            return .after(max(0.05, Self.window - (now - oldest)))
        }
        recent.append(now)
        count += 1
        return .now
    }
}

/// The player node as `SpeechQueue` uses it: `AVAudioPlayerNode` in the app, a script in tests.
@MainActor
protocol SpeechPlayer: AnyObject {
    /// Queues `buffer` behind what is queued and plays. `played`, when given, is called (on any thread) once the
    /// buffer has played back; a player also calls it when it is stopped with the buffer still queued.
    func schedule(_ buffer: AVAudioPCMBuffer, played: (@Sendable () -> Void)?)
    /// Drops what is queued and gets ready to play again.
    func reset()
}

/// Hermes' speech between the link and the player node: turns PCM into levelled buffers, queues them, calls back
/// when a line has played, keeps the books (`PlaybackLedger`), and carries what has not played over an engine
/// rebuild onto the next player.
@MainActor
final class SpeechQueue {
    private(set) var ledger: PlaybackLedger
    private(set) var format: AVAudioFormat
    /// Audio that arrives while no player is attached waits for the next one (the engine is being rebuilt). Else
    /// it is dropped, and the line it belongs to is reported as not heard.
    var holds = false

    private var player: SpeechPlayer?
    private var buffers: [UInt64: AVAudioPCMBuffer] = [:]
    /// Played-back callbacks still waiting, by marker; each is told whether its audio was heard.
    private var markers: [UInt64: (Bool) -> Void] = [:]
    private var leveler: SpeechLeveler
    /// Each line's level as it arrived and the gain it ended on.
    private var levels: [String: (level: Double?, gain: Double)] = [:]
    /// Audio was lost since the last marker: dropped with no player to take it, or queued on an engine that went
    /// away for good. The next marker reports its audio as not heard.
    private var lostAudio = false
    /// Bumped whenever what is on the player is dropped or the player goes: callbacks from before don't count.
    private var epoch = 0
    private let clock: () -> TimeInterval
    /// Slack past the scheduled audio before a played-back callback is forced.
    private let drainGrace: TimeInterval

    init(sampleRate: Double = 24_000, drainGrace: TimeInterval = 10,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        ledger = PlaybackLedger(rate: sampleRate)
        format = Self.format(sampleRate)
        leveler = SpeechLeveler(sampleRate: sampleRate)
        self.clock = clock
        self.drainGrace = drainGrace
    }

    private static func format(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    var hasPlayer: Bool { player != nil }

    /// A new sample rate for the lines to come. True when it changed: what was queued in the old one is dropped,
    /// and the caller connects the player node in the new format.
    func setSampleRate(_ rate: Double) -> Bool {
        guard rate > 0, rate != format.sampleRate,
              let next = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return false }
        flush()
        format = next
        ledger.setRate(rate)
        leveler = SpeechLeveler(sampleRate: rate)
        return true
    }

    /// What is queued from here on is the line `id`.
    func beginLine(_ id: String) {
        ledger.begin(line: id)
        leveler = SpeechLeveler(sampleRate: format.sampleRate)
    }

    /// A player is there (the engine started): what waited for one goes onto it, in order.
    func attach(_ player: SpeechPlayer) {
        epoch += 1
        self.player = player
        for item in ledger.schedule(now: clock()) {
            if item.isMarker {
                scheduleMarker(item.id, on: player)
            } else if let buffer = buffers[item.id] {
                player.schedule(buffer, played: nil)
            }
        }
    }

    /// The player is gone. `keeping`: the engine is being rebuilt, so what has not played stays for the next
    /// player, played-back callbacks included. Else everything is dropped and the callbacks complete, as not heard.
    func detach(keeping: Bool) {
        epoch += 1
        let had = player != nil
        player = nil
        guard keeping else { return drop() }
        guard had else { return }
        for cut in ledger.unschedule(now: clock()) { trim(cut.id, by: cut.frames) }
    }

    /// Queues little-endian Int16 samples of the current line. False when they were dropped: no player, and none
    /// expected.
    @discardableResult
    func enqueue(pcm16 data: Data) -> Bool {
        let frames = data.count / 2
        guard frames > 0 else { return true }
        guard player != nil || holds else {
            lostAudio = true
            return false
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else {
            lostAudio = true
            return false
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        // Copied out first: a frame's bytes need not be aligned for Int16.
        var samples = [Int16](repeating: 0, count: frames)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0, count: frames * 2) }
        samples.withUnsafeBufferPointer { leveler.process($0, into: out) }
        if let line = ledger.line { levels[line] = (leveler.levelDB, leveler.gainDB) }
        let now = clock()
        for item in ledger.settle(now: now) { buffers[item.id] = nil }
        let id = ledger.enqueue(frames: frames, now: now, onPlayer: player != nil)
        buffers[id] = buffer
        player?.schedule(buffer, played: nil)
        return true
    }

    /// Calls `done` on the main actor once everything queued so far has been heard (`true`), or dropped (`false`:
    /// flush, the engine gone for good, or audio lost before it). If playback stalls, the queue is dropped after
    /// its length plus a grace.
    func whenPlayedBack(_ done: @escaping (_ heard: Bool) -> Void) {
        let lost = lostAudio
        lostAudio = false
        guard player != nil || holds else { return done(false) }
        let id = ledger.mark(now: clock(), onPlayer: player != nil)
        markers[id] = { heard in done(heard && !lost) }
        if let player { scheduleMarker(id, on: player) }
        watch(id)
    }

    /// Drops anything still queued (the speech was cancelled, or the link went away) and completes every pending
    /// played-back callback, as not heard. What is queued next starts clean.
    func flush() {
        epoch += 1
        let waiting = ledger.flush(now: clock())
        buffers.removeAll()
        player?.reset()
        lostAudio = false
        complete(waiting, heard: false)
    }

    /// The output route changed.
    func routeChanged() {
        ledger.routeChanged()
    }

    /// What happened to the line so far; nil for a line that isn't on the books.
    func facts(for line: String) -> PlaybackFacts? {
        ledger.facts(for: line, now: clock()).map { facts($0, line) }
    }

    /// The same, closing the line's books.
    func takeFacts(for line: String) -> PlaybackFacts? {
        let taken = ledger.take(line: line, now: clock()).map { facts($0, line) }
        levels[line] = nil
        return taken
    }

    private func facts(_ numbers: PlaybackLedger.Stats, _ line: String) -> PlaybackFacts {
        let rate = ledger.rate
        return PlaybackFacts(
            audioSeconds: Double(numbers.received) / rate, playedSeconds: Double(numbers.played) / rate,
            stalls: numbers.stalls, stallSeconds: numbers.stallSeconds, rebuilds: numbers.rebuilds,
            routeChanges: numbers.routeChanges, levelDB: levels[line]?.level, gainDB: levels[line]?.gain)
    }

    /// The engine is gone and none is coming: everything queued is lost.
    private func drop() {
        let now = clock()
        // What a pending callback covers is reported by it (as not heard); audio of a line that is still
        // arriving is reported by that line's callback, once it comes.
        lostAudio = lostAudio || ledger.hasUnplayedTail(now: now)
        let waiting = ledger.flush(now: now)
        buffers.removeAll()
        complete(waiting, heard: false)
    }

    private func scheduleMarker(_ id: UInt64, on player: SpeechPlayer) {
        guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return flush() }
        marker.frameLength = 1
        marker.floatChannelData?[0][0] = 0
        let epoch = epoch
        player.schedule(marker) { [weak self] in
            Task { @MainActor in self?.markerPlayed(id, epoch: epoch) }
        }
    }

    /// A marker's audio played back (unless the callback is a stopped player's).
    private func markerPlayed(_ id: UInt64, epoch: Int) {
        guard epoch == self.epoch else { return }
        let done = ledger.markerPlayed(id)
        for item in done { buffers[item.id] = nil }
        // Markers before it on the queue have played too.
        complete(done.filter(\.isMarker).map(\.id), heard: true)
    }

    private func complete(_ ids: [UInt64], heard: Bool) {
        for id in ids { markers.removeValue(forKey: id)?(heard) }
    }

    /// Cuts `frames` off the head of an item's buffer: they played before the engine was torn down.
    private func trim(_ id: UInt64, by frames: Int) {
        guard let buffer = buffers[id], frames > 0 else { return }
        let rest = Int(buffer.frameLength) - frames
        guard rest > 0, let cut = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(rest)),
              let from = buffer.floatChannelData?[0], let to = cut.floatChannelData?[0] else {
            buffers[id] = nil
            return
        }
        cut.frameLength = AVAudioFrameCount(rest)
        to.update(from: from + frames, count: rest)
        buffers[id] = cut
    }

    /// Playback that never finishes (the engine died without telling us) must not hold the line for ever: once the
    /// queue should have played, plus the grace, it is dropped.
    private func watch(_ id: UInt64) {
        let began = clock()
        Task { [weak self] in
            while let wait = self?.overdue(id, since: began) {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// How long the marker may still take; nil once it is done with (played, or dropped here as overdue). With
    /// nothing on a player (a rebuild holds the queue) the wait counts from when it began.
    private func overdue(_ id: UInt64, since began: TimeInterval) -> TimeInterval? {
        guard markers[id] != nil else { return nil }
        let now = clock()
        let due = (ledger.queuedUntil ?? began) + drainGrace
        guard now >= due else { return max(0.05, due - now) }
        speechLog.notice("call audio: playback never finished; dropping the queue")
        flush()
        return nil
    }
}
