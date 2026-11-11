import AVFoundation
import XCTest
@testable import HermesVoice

/// The books on Hermes' speech (`PlaybackLedger`) against a scripted clock: what has played, where the player ran
/// dry, and what an engine rebuild leaves to be scheduled again.
final class PlaybackLedgerTests: XCTestCase {
    /// 0.2 s at 24 kHz.
    private let chunk = 4800

    func testPlayedFollowsTheClock() {
        var ledger = PlaybackLedger(rate: 24_000)
        ledger.begin(line: "a")
        ledger.enqueue(frames: chunk, now: 0, onPlayer: true)
        ledger.enqueue(frames: chunk, now: 0.05, onPlayer: true)  // behind the first: plays from 0.2
        XCTAssertEqual(ledger.queuedUntil ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(ledger.facts(for: "a", now: 0)?.played, 0)
        XCTAssertEqual(ledger.facts(for: "a", now: 0.3)?.played, chunk + chunk / 2)
        XCTAssertEqual(ledger.facts(for: "a", now: 5), PlaybackLedger.Stats(received: 2 * chunk, played: 2 * chunk))
        XCTAssertNil(ledger.facts(for: "b", now: 0))
    }

    func testAStallIsThePlayerRunningDryWhileMoreIsComing() {
        var ledger = PlaybackLedger(rate: 24_000)
        ledger.begin(line: "a")
        ledger.enqueue(frames: chunk, now: 0, onPlayer: true)       // plays until 0.2
        ledger.enqueue(frames: chunk, now: 0.7, onPlayer: true)     // dry for 0.5 s
        ledger.enqueue(frames: chunk, now: 0.95, onPlayer: true)    // dry for 0.05 s: under the 0.1 s that counts
        ledger.enqueue(frames: chunk, now: 1.5, onPlayer: true)     // dry for 0.35 s
        let facts = ledger.facts(for: "a", now: 2)
        XCTAssertEqual(facts?.stalls, 2)
        XCTAssertEqual(facts?.stallSeconds ?? 0, 0.85, accuracy: 1e-9)
        XCTAssertEqual(facts?.played, 4 * chunk)
        // The next line starting late is no stall: nothing of it was playing.
        ledger.begin(line: "b")
        ledger.enqueue(frames: chunk, now: 9, onPlayer: true)
        XCTAssertEqual(ledger.facts(for: "b", now: 9)?.stalls, 0)
        // Audio that arrives faster than it plays never stalls.
        ledger.begin(line: "c")
        for index in 0..<10 { ledger.enqueue(frames: chunk, now: 9.3 + Double(index) * 0.01, onPlayer: true) }
        XCTAssertEqual(ledger.facts(for: "c", now: 20)?.stalls, 0)
    }

    func testAMarkerSettlesEverythingBeforeIt() {
        var ledger = PlaybackLedger(rate: 24_000)
        ledger.begin(line: "a")
        let first = ledger.enqueue(frames: chunk, now: 0, onPlayer: true)
        let marker = ledger.mark(now: 0, onPlayer: true)
        ledger.begin(line: "b")
        let next = ledger.enqueue(frames: chunk, now: 0, onPlayer: true)
        // The clock is behind (the test never moves it), the callback is the truth.
        XCTAssertEqual(ledger.markerPlayed(marker).map(\.id), [first, marker])
        XCTAssertEqual(ledger.take(line: "a", now: 0), PlaybackLedger.Stats(received: chunk, played: chunk))
        XCTAssertEqual(ledger.items.map(\.id), [next])
        XCTAssertEqual(ledger.markerPlayed(marker).count, 0, "a marker plays once")
        XCTAssertNil(ledger.take(line: "a", now: 0), "its books are closed")
    }

    func testARebuildKeepsWhatHasNotPlayed() {
        var ledger = PlaybackLedger(rate: 24_000)
        ledger.begin(line: "a")
        let ids = (0..<3).map { _ in ledger.enqueue(frames: chunk, now: 0, onPlayer: true) }  // 0–0.2, 0.2–0.4, 0.4–0.6
        let marker = ledger.mark(now: 0, onPlayer: true)
        // Torn down at 0.42: less the backoff, 0.30 s have played for sure.
        let cuts = ledger.unschedule(now: 0.42)
        XCTAssertEqual(cuts.map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(cuts.map(\.frames), [chunk, chunk / 2])
        XCTAssertEqual(ledger.items.map(\.id), [ids[1], ids[2], marker], "the played chunk is gone, the rest stays")
        XCTAssertEqual(ledger.items.map(\.frames), [chunk / 2, chunk, 0])
        XCTAssertTrue(ledger.hasUnscheduled)
        XCTAssertNil(ledger.queuedUntil)
        XCTAssertEqual(ledger.facts(for: "a", now: 0.9), PlaybackLedger.Stats(received: 3 * chunk, played: chunk + chunk / 2, rebuilds: 1),
                       "nothing plays while there is no engine")
        // More of the line arrives meanwhile, and waits.
        let late = ledger.enqueue(frames: chunk, now: 0.8, onPlayer: false)
        XCTAssertEqual(ledger.facts(for: "a", now: 0.9)?.stalls, 0, "the gap of a rebuild is not a stall")
        // The fresh engine takes it all, in order, from now.
        let scheduled = ledger.schedule(now: 1.0)
        XCTAssertEqual(scheduled.map(\.id), [ids[1], ids[2], marker, late])
        for (item, start) in zip(scheduled, [1.0, 1.1, 1.3, 1.3]) {
            XCTAssertEqual(item.startsAt ?? -1, start, accuracy: 1e-9)
        }
        XCTAssertEqual(ledger.queuedUntil ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertFalse(ledger.hasUnscheduled)
        XCTAssertEqual(ledger.facts(for: "a", now: 1.2)?.played, 2 * chunk + chunk / 2)
        XCTAssertEqual(ledger.schedule(now: 1.2).count, 0, "nothing is scheduled twice")
    }

    func testAFlushCountsWhatHadPlayed() {
        var ledger = PlaybackLedger(rate: 24_000)
        ledger.begin(line: "a")
        ledger.enqueue(frames: chunk, now: 0, onPlayer: true)
        ledger.enqueue(frames: chunk, now: 0, onPlayer: true)
        let marker = ledger.mark(now: 0, onPlayer: true)
        XCTAssertEqual(ledger.flush(now: 0.25), [marker])
        XCTAssertTrue(ledger.items.isEmpty)
        XCTAssertEqual(ledger.take(line: "a", now: 3), PlaybackLedger.Stats(received: 2 * chunk, played: chunk + chunk / 4))
    }

    func testOldAudioIsLetGoAndRouteChangesCountForOpenLines() {
        var ledger = PlaybackLedger(rate: 24_000)
        ledger.begin(line: "a")
        let first = ledger.enqueue(frames: chunk, now: 0, onPlayer: true)
        ledger.enqueue(frames: chunk, now: 0, onPlayer: true)
        XCTAssertEqual(ledger.settle(now: 0.6).count, 0, "not yet half a second behind")
        XCTAssertEqual(ledger.settle(now: 0.75).map(\.id), [first])
        ledger.routeChanged()
        XCTAssertEqual(ledger.facts(for: "a", now: 0.75), PlaybackLedger.Stats(received: 2 * chunk, played: 2 * chunk, routeChanges: 1))
        _ = ledger.take(line: "a", now: 1)
        ledger.routeChanged()
        ledger.begin(line: "b")
        XCTAssertEqual(ledger.facts(for: "b", now: 1)?.routeChanges, 0, "a route change before the line is not its")
    }

    func testTheBooksAreKeptForAFewLinesOnly() {
        var ledger = PlaybackLedger(rate: 24_000)
        for index in 0..<(PlaybackLedger.lineLimit + 2) { ledger.begin(line: "line-\(index)") }
        XCTAssertNil(ledger.facts(for: "line-0", now: 0))
        XCTAssertNotNil(ledger.facts(for: "line-2", now: 0))
        // A line begun again (the plugin repeats its start after a reconnect) keeps its numbers.
        ledger.enqueue(frames: chunk, now: 0, onPlayer: true)
        ledger.begin(line: "line-9")
        XCTAssertEqual(ledger.facts(for: "line-9", now: 0)?.received, chunk)
    }

    // MARK: The rebuild cap

    func testAFewRebuildsAreFreeThenTheyWait() {
        var budget = RebuildBudget()
        for index in 0..<RebuildBudget.freeInWindow {
            XCTAssertEqual(budget.next(at: Double(index)), .now)
        }
        XCTAssertEqual(budget.count, 4)
        // The fifth within ten seconds waits until the first has left the window.
        XCTAssertEqual(wait(budget.next(at: 4)), 6, accuracy: 1e-9)
        XCTAssertEqual(wait(budget.next(at: 9.5)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(budget.count, 4, "a rebuild that has to wait is not one yet")
        XCTAssertEqual(budget.next(at: 10), .now)
        XCTAssertEqual(wait(budget.next(at: 10.1)), 0.9, accuracy: 1e-9)
    }

    /// How long a verdict says to wait; -1 for one that doesn't.
    private func wait(_ verdict: RebuildBudget.Verdict) -> TimeInterval {
        if case let .after(delay) = verdict { return delay }
        return -1
    }

    func testACallGetsOnlySoManyRebuilds() {
        var budget = RebuildBudget()
        var now = 0.0
        var granted = 0
        // A loop of configuration changes: every rebuild is followed by the next at once.
        for _ in 0..<1000 {
            switch budget.next(at: now) {
            case .now: granted += 1
            case let .after(delay): now += delay
            case .never: break
            }
        }
        XCTAssertEqual(granted, RebuildBudget.perCall)
        XCTAssertEqual(budget.next(at: now + 3600), .never)
        // It could not spin: at most four every ten seconds.
        XCTAssertGreaterThanOrEqual(now, Double(RebuildBudget.perCall / RebuildBudget.freeInWindow - 1) * RebuildBudget.window)
    }
}

/// A scripted player node: records what is scheduled on it and plays or stops when the test says so.
@MainActor
final class ScriptedPlayer: SpeechPlayer {
    private(set) var scheduled: [AVAudioPCMBuffer] = []
    private(set) var resets = 0
    private var callbacks: [@Sendable () -> Void] = []

    var frames: [Int] { scheduled.map { Int($0.frameLength) } }

    func schedule(_ buffer: AVAudioPCMBuffer, played: (@Sendable () -> Void)?) {
        scheduled.append(buffer)
        if let played { callbacks.append(played) }
    }

    func reset() {
        resets += 1
        stop()
    }

    /// Everything queued has played back (or the node was stopped: it calls the same callbacks).
    func stop() {
        let done = callbacks
        callbacks = []
        done.forEach { $0() }
    }

    func samples(_ index: Int) -> [Float] {
        let buffer = scheduled[index]
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
    }
}

/// `SpeechQueue` against a scripted player and clock: played-back callbacks, the facts it keeps, and what happens to
/// queued speech when the engine is rebuilt or taken away.
@MainActor
final class SpeechQueueTests: XCTestCase {
    private var now: TimeInterval = 0
    private var heard: [Bool] = []

    override func setUp() async throws {
        now = 0
        heard = []
    }

    private func queue(drainGrace: TimeInterval = 10) -> SpeechQueue {
        SpeechQueue(drainGrace: drainGrace) { [unowned self] in self.now }
    }

    /// 0.2 s of a loud tone (too loud for the leveller to touch).
    private func tone(_ frames: Int = 4800, amplitude: Double = 12_000, from offset: Int = 0) -> Data {
        var data = Data(capacity: frames * 2)
        for index in 0..<frames {
            let value = Int16(amplitude * sin(2 * .pi * 300 * Double(index + offset) / 24_000))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testALineIsHeardOnceItsMarkerPlaysBack() async {
        let queue = queue()
        let player = ScriptedPlayer()
        queue.attach(player)
        queue.beginLine("a")
        XCTAssertTrue(queue.enqueue(pcm16: tone()))
        XCTAssertTrue(queue.enqueue(pcm16: tone()))
        queue.whenPlayedBack { self.heard.append($0) }
        XCTAssertEqual(player.frames, [4800, 4800, 1])
        XCTAssertEqual(heard, [])
        now = 0.3
        XCTAssertEqual(queue.facts(for: "a")?.playedSeconds ?? 0, 0.3, accuracy: 0.001)
        player.stop()
        await waitUntil { self.heard == [true] }
        let facts = queue.takeFacts(for: "a")
        XCTAssertEqual(facts?.audioSeconds ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(facts?.playedSeconds ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(facts?.stalls, 0)
        XCTAssertEqual(facts?.gainDB ?? -1, 0, accuracy: 0.001, "a normal line is not levelled")
        XCTAssertNil(queue.takeFacts(for: "a"))
    }

    func testARebuildSchedulesWhatHadNotPlayedOnTheFreshPlayer() async {
        let queue = queue()
        let old = ScriptedPlayer()
        queue.attach(old)
        queue.beginLine("a")
        let chunks = [tone(from: 0), tone(from: 4800), tone(from: 9600)]
        chunks.forEach { queue.enqueue(pcm16: $0) }
        queue.whenPlayedBack { self.heard.append($0) }
        // The engine is torn down 0.42 s in (the Speaker button, AirPods): the node's stop calls back for what was queued.
        now = 0.42
        queue.detach(keeping: true)
        old.stop()
        await settle()
        XCTAssertEqual(heard, [], "a stopped player's callback is not the line having played")
        // More of the line arrives while the engine is down.
        queue.holds = true
        XCTAssertTrue(queue.enqueue(pcm16: tone(from: 14_400)))
        now = 0.9
        let fresh = ScriptedPlayer()
        queue.attach(fresh)
        // The rest of the second chunk (0.30 s had played for sure), the third, the marker, and what came since.
        XCTAssertEqual(fresh.frames, [2400, 4800, 1, 4800])
        XCTAssertEqual(fresh.samples(0), Array(old.samples(1)[2400...]), "it carries on where it stopped")
        XCTAssertEqual(fresh.samples(1), old.samples(2))
        fresh.stop()
        await waitUntil { self.heard == [true] }
        let facts = queue.takeFacts(for: "a")
        XCTAssertEqual(facts?.rebuilds, 1)
        XCTAssertEqual(facts?.stalls, 0)
        XCTAssertEqual(facts?.audioSeconds ?? 0, 0.8, accuracy: 0.001)
    }

    func testAudioAndCallbacksWaitThroughARebuildOnlyWhenOneIsUnderWay() {
        let queue = queue()
        // No engine yet, and none promised (CallKit hasn't activated the audio): the line is lost.
        queue.beginLine("a")
        XCTAssertFalse(queue.enqueue(pcm16: tone()))
        queue.whenPlayedBack { self.heard.append($0) }
        XCTAssertEqual(heard, [false])
        // The same line, with a rebuild under way: it waits.
        queue.holds = true
        queue.beginLine("b")
        XCTAssertTrue(queue.enqueue(pcm16: tone()))
        queue.whenPlayedBack { self.heard.append($0) }
        XCTAssertEqual(heard, [false])
        let player = ScriptedPlayer()
        queue.attach(player)
        XCTAssertEqual(player.frames, [4800, 1])
    }

    func testAudioTakenAwayDropsTheQueueAsNotHeard() async {
        let queue = queue()
        let player = ScriptedPlayer()
        queue.attach(player)
        queue.beginLine("a")
        queue.enqueue(pcm16: tone())
        queue.whenPlayedBack { self.heard.append($0) }
        // An interruption, or CallKit deactivating the session: nobody knows when the audio comes back.
        now = 0.1
        queue.detach(keeping: false)
        XCTAssertEqual(heard, [false])
        player.stop()
        await settle()
        XCTAssertEqual(heard, [false])
        let fresh = ScriptedPlayer()
        queue.attach(fresh)
        XCTAssertEqual(fresh.frames, [], "nothing stale is played later")
        XCTAssertEqual(queue.takeFacts(for: "a")?.playedSeconds ?? 0, 0.1, accuracy: 0.001)
        // The line after it is not blamed: the lost audio was reported by that callback.
        queue.beginLine("b")
        queue.enqueue(pcm16: tone())
        queue.whenPlayedBack { self.heard.append($0) }
        fresh.stop()
        await waitUntil { self.heard == [false, true] }
    }

    func testAFlushDropsWhatIsQueuedAndIgnoresTheStoppedPlayersCallbacks() async {
        let queue = queue()
        let player = ScriptedPlayer()
        queue.attach(player)
        queue.beginLine("a")
        queue.enqueue(pcm16: tone())
        queue.whenPlayedBack { self.heard.append($0) }
        queue.flush()  // resets the player, whose stop calls the marker's callback
        XCTAssertEqual(player.resets, 1)
        await settle()
        XCTAssertEqual(heard, [false])
        queue.beginLine("b")
        queue.enqueue(pcm16: tone())
        queue.whenPlayedBack { self.heard.append($0) }
        player.stop()
        await waitUntil { self.heard == [false, true] }
    }

    func testAQueueThatNeverPlaysIsDroppedAfterItsLengthAndAGrace() async {
        let started = Date()
        let queue = SpeechQueue(drainGrace: 0.2) { Date().timeIntervalSince(started) }
        let player = ScriptedPlayer()
        queue.attach(player)
        queue.beginLine("a")
        queue.enqueue(pcm16: tone())
        queue.whenPlayedBack { self.heard.append($0) }
        await waitUntil(timeout: 5) { self.heard == [false] }
        XCTAssertEqual(player.resets, 1)
    }

    func testAQuietLineIsLevelledOnItsWayToThePlayer() {
        let queue = queue()
        let player = ScriptedPlayer()
        queue.attach(player)
        queue.beginLine("whisper")
        queue.enqueue(pcm16: tone(24_000, amplitude: 500))  // about -39 dBFS
        let peak = player.samples(0).map(abs).max() ?? 0
        XCTAssertEqual(Double(peak), 500.0 / 32768 * pow(10, 15.0 / 20), accuracy: 0.005, "raised by the most a line gets")
        let facts = queue.facts(for: "whisper")
        XCTAssertEqual(facts?.gainDB ?? 0, 15, accuracy: 0.1)
        XCTAssertEqual(facts?.levelDB ?? 0, -39.3, accuracy: 0.3)
        // The next line starts from scratch.
        queue.beginLine("normal")
        queue.enqueue(pcm16: tone(24_000, amplitude: 12_000))
        XCTAssertEqual(Double(player.samples(1).map(abs).max() ?? 0), 12_000.0 / 32768, accuracy: 0.001)
        XCTAssertEqual(queue.facts(for: "normal")?.gainDB ?? -1, 0, accuracy: 0.001)
    }

    func testANewSampleRateDropsWhatIsQueued() {
        let queue = queue()
        let player = ScriptedPlayer()
        queue.attach(player)
        queue.beginLine("a")
        queue.enqueue(pcm16: tone())
        queue.whenPlayedBack { self.heard.append($0) }
        XCTAssertFalse(queue.setSampleRate(24_000))
        XCTAssertTrue(queue.setSampleRate(16_000))
        XCTAssertEqual(heard, [false])
        XCTAssertEqual(queue.format.sampleRate, 16_000)
    }
}

/// The loudness leveller on synthetic PCM: quiet lines come up to the target, normal ones are not touched, nothing
/// clips and the gain does not pump.
final class SpeechLevelerTests: XCTestCase {
    private let rate = 24_000.0

    /// A tone at `db` dBFS RMS for `seconds`.
    private func tone(_ db: Double, seconds: Double, frequency: Double = 220, from offset: Int = 0) -> [Int16] {
        let amplitude = pow(10, db / 20) * 2.0.squareRoot() * 32768
        return (0..<Int(seconds * rate)).map { index in
            Int16(max(-32768, min(32767, amplitude * sin(2 * .pi * frequency * Double(index + offset) / rate))))
        }
    }

    /// Speech-like: syllables at four a second with a gap after each, and words of different loudness.
    private func speech(_ db: Double, seconds: Double) -> [Int16] {
        let carrier = tone(db + 3, seconds: seconds)
        return carrier.enumerated().map { index, sample in
            let time = Double(index) / rate
            let syllable = time.truncatingRemainder(dividingBy: 0.25)
            let envelope = syllable < 0.18 ? sin(.pi * syllable / 0.18) : 0
            let word = 0.75 + 0.25 * sin(2 * .pi * time / 1.7)
            return Int16(Double(sample) * envelope * word)
        }
    }

    private func level(_ samples: ArraySlice<Float>) -> Double {
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(max(energy / Double(max(samples.count, 1)), 1e-12))
    }

    private func plain(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32768 }
    }

    /// Feeds `samples` in frames of uneven sizes, as they come off the link.
    private func stream(_ samples: [Int16], sizes: [Int] = [3777, 480, 9600, 1201, 5000]) -> ([Float], SpeechLeveler) {
        var leveler = SpeechLeveler(sampleRate: rate)
        var out: [Float] = []
        var start = 0
        var turn = 0
        while start < samples.count {
            let end = min(samples.count, start + sizes[turn % sizes.count])
            out += leveler.process(Array(samples[start..<end]))
            start = end
            turn += 1
        }
        return (out, leveler)
    }

    func testAQuietLineComesUpToTheTarget() {
        let quiet = tone(-36, seconds: 3)
        let (out, leveler) = stream(quiet)
        XCTAssertEqual(level(out[...]), Double(SpeechLeveler.targetDB), accuracy: 0.3)
        XCTAssertEqual(leveler.gainDB, 12, accuracy: 0.3)
        XCTAssertEqual(leveler.levelDB ?? 0, -36, accuracy: 0.2)
        // From its first sample: the level of the first frame is known before any of it plays.
        XCTAssertEqual(level(out[0..<2400]), Double(SpeechLeveler.targetDB), accuracy: 0.5)
    }

    func testTheGainHasACeiling() {
        let (out, leveler) = stream(tone(-48, seconds: 2))
        XCTAssertEqual(leveler.gainDB, Double(SpeechLeveler.maxGainDB), accuracy: 0.01)
        XCTAssertEqual(level(out[...]), -48 + Double(SpeechLeveler.maxGainDB), accuracy: 0.3)
    }

    func testANormalLineIsNotTouched() {
        for db in [-23.8, -20, -14, -6] {
            let normal = tone(db, seconds: 2)
            let (out, leveler) = stream(normal)
            XCTAssertEqual(out, plain(normal), "\(db) dBFS")
            XCTAssertEqual(leveler.gainDB, 0, accuracy: 1e-9)
        }
        let talk = speech(-19, seconds: 4)
        XCTAssertEqual(stream(talk).0, plain(talk), "speech with its own ups and downs")
        // Silence, and a line that is only silence so far, pass as they are.
        let silence = [Int16](repeating: 0, count: 12_000)
        XCTAssertEqual(stream(silence).0, plain(silence))
    }

    func testNothingClipsWhenALoudPassageFollowsAQuietStart() {
        let line = tone(-40, seconds: 1) + tone(-4, seconds: 1, from: 24_000) + tone(-40, seconds: 0.5, from: 48_000)
        // However the frames fall: with 480 the loud passage starts exactly on a block, with the gain still up.
        for sizes in [[3777, 480, 9600, 1201, 5000], [480], [line.count]] {
            let (out, _) = stream(line, sizes: sizes)
            XCTAssertLessThanOrEqual(out.map(abs).max() ?? 1, SpeechLeveler.top, "\(sizes)")
            // The quiet start was raised.
            XCTAssertEqual(level(out[6000..<24_000]), -40 + Double(SpeechLeveler.maxGainDB), accuracy: 0.5, "\(sizes)")
            // The loud passage is back at its own level within a few milliseconds, not louder.
            XCTAssertEqual(level(out[24_480..<48_000]), -4, accuracy: 0.3, "\(sizes)")
        }
        // The first loud samples, with the gain still on its way down, are bent under full scale.
        let onset = stream(line, sizes: [480]).0[24_000..<24_120].map(abs).max() ?? 0
        XCTAssertGreaterThan(onset, 0.9)
        XCTAssertLessThanOrEqual(onset, SpeechLeveler.top)
    }

    func testTheGainDoesNotPump() {
        // Quiet speech: syllables, gaps between them, louder and softer words.
        let quiet = speech(-32, seconds: 6)
        let (out, leveler) = stream(quiet)
        let input = plain(quiet)
        XCTAssertLessThan(leveler.gainDB, Double(SpeechLeveler.maxGainDB) - 1, "the gain is free to move in this test")
        /// The gain a sample got, where there is signal to tell.
        func gain(_ index: Int) -> Double? {
            abs(input[index]) > 0.002 ? 20 * log10(Double(out[index] / input[index])) : nil
        }
        let all = (24_000..<input.count).compactMap(gain)
        XCTAssertGreaterThan(all.min() ?? 0, 7, "raised throughout")
        XCTAssertLessThan((all.max() ?? 0) - (all.min() ?? 0), 2.5, "one gain for the line, give or take")
        // It does not follow the syllables: within a syllable and its gap the gain hardly moves.
        var start = 24_000
        while start + 6000 <= input.count {
            let within = (start..<(start + 6000)).compactMap(gain)
            XCTAssertLessThan((within.max() ?? 0) - (within.min() ?? 0), 0.5, "at \(Double(start) / rate) s")
            start += 6000
        }
        // And it never rises faster than the release allows from one block to the next.
        var steps: [Double] = []
        var index = 24_000
        while index + 480 < input.count {
            if let here = gain(index), let next = gain(index + 480) { steps.append(next - here) }
            index += 480
        }
        XCTAssertLessThan(steps.max() ?? 0, Double(SpeechLeveler.releaseDBPerSecond) * SpeechLeveler.blockSeconds + 0.05)
    }

    func testTheResultDoesNotDependOnHowTheAudioIsCutIntoFrames() {
        let quiet = speech(-36, seconds: 3)
        let whole = stream(quiet, sizes: [quiet.count]).0
        let small = stream(quiet, sizes: [480]).0
        let odd = stream(quiet, sizes: [777, 1333, 55, 4096]).0
        // After the first moments (a single frame knows the whole line's level from the start), they agree.
        XCTAssertEqual(level(whole[24_000...]), level(small[24_000...]), accuracy: 0.5)
        XCTAssertEqual(level(whole[24_000...]), level(odd[24_000...]), accuracy: 0.5)
        XCTAssertEqual(level(small[...]), level(odd[...]), accuracy: 0.5)
    }

    func testAWhisperHalfWayThroughALineIsRaisedToo() {
        let normal = speech(-18, seconds: 2)
        let line = normal + speech(-40, seconds: 5)
        let (out, leveler) = stream(line)
        XCTAssertEqual(Array(out[0..<normal.count]), plain(normal), "the normal part is not touched")
        let before = level(plain(line)[(line.count - 24_000)...])
        let after = level(out[(out.count - 24_000)...])
        XCTAssertGreaterThan(after - before, 10, "the whisper's last second is \(after - before) dB up")
        XCTAssertGreaterThan(leveler.gainDB, 10)
        XCTAssertLessThanOrEqual(out.map(abs).max() ?? 1, SpeechLeveler.top)
    }

    func testTheLimiterBendsOnlyTheTop() {
        XCTAssertEqual(SpeechLeveler.limit(0.5), 0.5)
        XCTAssertEqual(SpeechLeveler.limit(-0.89), -0.89)
        XCTAssertLessThan(SpeechLeveler.limit(0.95), 0.95)
        XCTAssertGreaterThan(SpeechLeveler.limit(0.95), 0.89)
        XCTAssertLessThanOrEqual(SpeechLeveler.limit(8), SpeechLeveler.top)
        XCTAssertGreaterThan(SpeechLeveler.limit(8), 0.98)
        XCTAssertEqual(SpeechLeveler.limit(-8), -SpeechLeveler.limit(8))
    }
}

/// The wire shapes of the playback feedback, and what the chat shows of a turn that carries a playback note.
final class PlaybackProtocolTests: XCTestCase {
    private func object(_ message: PhoneMessage) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.encoded().utf8)) as? NSDictionary)
    }

    func testPlayedCarriesTheFactsWhenThereAreSome() throws {
        // As before for an audio path that keeps none (and all an older plugin reads).
        XCTAssertEqual(try object(.played("u1")), ["type": "played", "id": "u1"])
        let facts = PlaybackFacts(audioSeconds: 9.1234, playedSeconds: 2.006, stalls: 2, stallSeconds: 1.8049, rebuilds: 1,
                                  routeChanges: 1, route: .bluetooth, volume: 0.0625, levelDB: -37.26, gainDB: 13.26)
        XCTAssertEqual(try object(.played("u1", playback: facts)), [
            "type": "played", "id": "u1",
            "playback": ["audio_s": 9.12, "played_s": 2.01, "stalls": 2, "stall_s": 1.8, "rebuilds": 1, "route_changes": 1,
                         "route": "bluetooth", "volume": 0.06, "level_db": -37.3, "gain_db": 13.3],
        ])
        // What isn't known is left out.
        XCTAssertEqual(try object(.played("u1", playback: PlaybackFacts())), [
            "type": "played", "id": "u1",
            "playback": ["audio_s": 0, "played_s": 0, "stalls": 0, "stall_s": 0, "rebuilds": 0, "route_changes": 0],
        ])
    }

    func testUnplayedAndReplayed() throws {
        XCTAssertEqual(try object(.unplayed("u2", reason: "hang_up", playback: PlaybackFacts(audioSeconds: 9, playedSeconds: 2, route: .receiver))), [
            "type": "unplayed", "id": "u2", "reason": "hang_up",
            "playback": ["audio_s": 9, "played_s": 2, "stalls": 0, "stall_s": 0, "rebuilds": 0, "route_changes": 0, "route": "receiver"],
        ])
        XCTAssertEqual(try object(.unplayed("u2", reason: "lost")), ["type": "unplayed", "id": "u2", "reason": "lost"])
        XCTAssertEqual(try object(.replayed("u2")), ["type": "replayed", "id": "u2"])
        XCTAssertEqual(PhoneMessage.unplayed("u", reason: "lost").type, "unplayed")
        XCTAssertEqual(PhoneMessage.replayed("u").type, "replayed")
    }

    func testRoutesByOutputPort() {
        func route(_ port: AVAudioSession.Port) -> AudioRoute { AudioRoute(port: port.rawValue) }
        XCTAssertEqual(route(.builtInReceiver), .receiver)
        XCTAssertEqual(route(.builtInSpeaker), .speaker)
        XCTAssertEqual(route(.bluetoothHFP), .bluetooth)
        XCTAssertEqual(route(.bluetoothA2DP), .bluetooth)
        XCTAssertEqual(route(.bluetoothLE), .bluetooth)
        XCTAssertEqual(route(.headphones), .headphones)
        XCTAssertEqual(route(.usbAudio), .headphones)
        XCTAssertEqual(route(.carAudio), .car)
        XCTAssertEqual(route(.airPlay), .other)
        XCTAssertEqual(route(.HDMI), .other)
    }

    func testTheChatShowsOnlyWhatWasSaidOfATurnWithAPlaybackNote() {
        let hint = VoiceTranscript.hints[0]
        let note = "(HermesVoice playback note, not the user's words: Your last line may not have been heard well: "
            + "playback stalled twice (1.8 s of gaps). If it mattered, say it again shorter and plainer.)"
        XCTAssertEqual(VoiceTranscript.spoken("[Voice] what was that \(hint) \(note)"), "what was that")
        XCTAssertEqual(VoiceTranscript.spoken("[Voice, cut off] wait \(hint) \(note)"), "wait (cut off)")
        let delayed = "(Delayed by 12 s: this chat was open in another Hermes window, so nothing could be put into it. "
            + "The user is still on the call and was told this chat couldn't be reached.)"
        XCTAssertEqual(VoiceTranscript.spoken("[Voice] what was that \(hint) \(note) \(delayed)"), "what was that")
    }
}
