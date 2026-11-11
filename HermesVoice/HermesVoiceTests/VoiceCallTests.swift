import AVFoundation
import XCTest
@testable import HermesVoice

/// Scripted call audio: runs once started (as CallAudio does when CallKit activates the session), drops what it is
/// given while it isn't running, and reports a line as heard only if none of it was dropped.
@MainActor
final class FakeAudio: CallAudioPlayback {
    var onEvent: ((CallAudio.Event) -> Void)?
    private(set) var running = false
    private(set) var starts = 0
    private var lost = false
    /// The lines begun, the audio queued and the flushes, in order.
    private(set) var lines: [String] = []
    private(set) var enqueued: [Data] = []
    private(set) var flushes = 0
    /// What each line reports about its playback (none: the audio keeps no such facts).
    var facts: [String: PlaybackFacts] = [:]
    /// Played-back callbacks wait for `finishPlayback` instead of completing at once (a line takes time to play).
    var holdsPlayback = false
    private var waiting: [(Bool) -> Void] = []

    func beginLine(_ id: String) {
        lines.append(id)
    }

    func takeFacts(for line: String) -> PlaybackFacts? {
        facts[line]
    }

    /// Everything queued has played (or, with `heard` false, never reached the speaker).
    func finishPlayback(heard: Bool = true) {
        let done = waiting
        waiting = []
        done.forEach { $0(heard) }
    }

    func start(onInput: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        guard !running else { return }
        running = true
        starts += 1
        onEvent?(.running)
    }

    func suspend() {
        running = false
    }

    func stop() {
        running = false
    }

    func setSampleRate(_ rate: Double) {}

    func enqueue(pcm16 data: Data) -> Bool {
        if !running { lost = true }
        if running { enqueued.append(data) }
        return running
    }

    func whenPlayedBack(_ done: @escaping (Bool) -> Void) {
        let heard = running && !lost
        lost = false
        if holdsPlayback, heard {
            waiting.append(done)
        } else {
            done(heard)
        }
    }

    func flush() {
        lost = false
        flushes += 1
        finishPlayback(heard: false)
    }
}

/// A scripted plugin link: records what the phone sends, and lets a test deliver plugin messages or drop it.
@MainActor
final class FakeLink: CallLink {
    var onEvent: ((VoiceLink.Event) -> Void)?
    let hello: PhoneHello
    private(set) var connects = 0
    private(set) var sent: [PhoneMessage] = []
    /// What `close(after:)` was given, once closed.
    private(set) var closedAfter: [PhoneMessage]?

    init(hello: PhoneHello) {
        self.hello = hello
    }

    func connect() async {
        connects += 1
    }

    func send(_ message: PhoneMessage, completion: ((Bool) -> Void)?) {
        sent.append(message)
        completion?(closedAfter == nil)
    }

    func close(after final: [PhoneMessage]) {
        if closedAfter == nil { closedAfter = final }
    }

    func deliver(_ message: PluginMessage) {
        onEvent?(.message(message))
    }

    func drop(_ reason: VoiceLink.Close = .dropped) {
        onEvent?(.closed(reason))
    }

    var turns: [UserTurn] {
        (sent + (closedAfter ?? [])).compactMap { if case let .userTurn(turn) = $0 { return turn } else { return nil } }
    }

    var types: [String] { sent.map(\.type) }
}

/// A scripted speech provider: a test sets what was heard and emits turns.
@MainActor
final class FakeSpeech: SpeechProvider {
    let id: SpeechProviderID
    let events: AsyncStream<SpeechEvent>
    private let continuation: AsyncStream<SpeechEvent>.Continuation
    private let callID: String
    private(set) var paused: [Bool] = []
    private(set) var flushed: [TurnEnding] = []
    private(set) var stopped = false
    var partial = ""
    var startError: Error?
    var hasPartial: Bool { !partial.isEmpty }

    init(id: SpeechProviderID, callID: String) {
        self.id = id
        self.callID = callID
        (events, continuation) = AsyncStream.makeStream(of: SpeechEvent.self)
    }

    func start(input: AudioInputTap) async throws {
        if let startError { throw startError }
    }

    func setPaused(_ value: Bool) {
        if paused.last != value { paused.append(value) }
    }

    func flush(_ ending: TurnEnding) -> UserTurn? {
        flushed.append(ending)
        guard hasPartial else { return nil }
        defer { partial = "" }
        return turn(partial, ending: ending)
    }

    func audioRestarted() {}

    func stop() {
        stopped = true
        continuation.finish()
    }

    func hear(_ text: String) {
        partial = text
        continuation.yield(.partial(text))
    }

    func finishTurn() {
        let text = partial
        partial = ""
        continuation.yield(.partial(""))
        continuation.yield(.turn(turn(text, ending: .endOfSpeech(detector: "test", detail: nil))))
    }

    func fail(_ error: Error) {
        continuation.yield(.failed(error))
    }

    func turn(_ text: String, ending: TurnEnding) -> UserTurn {
        UserTurn(callID: callID, text: text, ending: ending, provider: id, language: nil, startedAt: Date(), endedAt: Date())
    }
}

/// The call state machine against a scripted link: ringing, answering, declining, timeouts, the plugin's outcomes,
/// reconnects, and turns (outbox, half-duplex cut-off, hang-up flush).
@MainActor
final class VoiceCallTests: XCTestCase {
    private let callID = "00112233445566778899aabbccddeeff"
    private var links: [FakeLink] = []
    private var speech: [FakeSpeech] = []
    private var audio: [FakeAudio] = []
    private var attachError: Error?
    private var chat: ChatModel!
    private var ended: [VoiceCall.EndCause] = []
    private var gateway: ScriptedGateway!

    override func setUp() async throws {
        links = []
        speech = []
        audio = []
        ended = []
        attachError = nil
        gateway = ScriptedGateway()
        let client = try DashboardClient(settings: ConnectionSettings(dashboardURL: "http://127.0.0.1:9", username: "u", password: "p"))
        chat = ChatModel(client: client, connection: gateway.connection(),
                         summary: SessionSummary(id: "stored-1", title: "Groceries", lastActive: nil, profile: nil))
    }

    override func tearDown() async throws {
        chat = nil
        gateway = nil
    }

    private var link: FakeLink { links[links.count - 1] }

    private func environment(_ configure: (inout VoiceCall.Environment) -> Void = { _ in }) -> VoiceCall.Environment {
        var environment = VoiceCall.Environment(
            makeLink: { [unowned self] hello in
                let link = FakeLink(hello: hello)
                self.links.append(link)
                return link
            },
            makeSpeech: { [unowned self] id, callID in
                let provider = FakeSpeech(id: id, callID: callID)
                self.speech.append(provider)
                return provider
            },
            makeAudio: { [unowned self] in
                let audio = FakeAudio()
                self.audio.append(audio)
                return audio
            }
        )
        environment.attach = { [unowned self] _ in if let error = self.attachError { throw error } }
        environment.reconnectDelays = [0.01, 0.01]
        environment.cutOffGrace = 0.3
        environment.declineLinger = 1
        configure(&environment)
        return environment
    }

    private func pushCall(_ configure: (inout VoiceCall.Environment) -> Void = { _ in }) -> VoiceCall {
        let push = CallPush(callID: callID, sessionID: "stored-1", profile: nil, mode: "async", title: "Groceries")
        let call = VoiceCall(chat: chat, settings: CallSettings(provider: .apple, speechLocale: "", endOfSpeech: .normal),
                             initiatedBy: .push, callID: callID, push: push, environment: environment(configure))
        call.onEnded = { [unowned self] cause in self.ended.append(cause) }
        return call
    }

    private func userCall(_ configure: (inout VoiceCall.Environment) -> Void = { _ in }) -> VoiceCall {
        let call = VoiceCall(chat: chat, settings: CallSettings(provider: .apple, speechLocale: "", endOfSpeech: .normal),
                             initiatedBy: .user, callID: callID, environment: environment(configure))
        call.onEnded = { [unowned self] cause in self.ended.append(cause) }
        return call
    }

    /// A call the user started, live with its audio running, listening with a FakeSpeech.
    private func liveCall(_ configure: (inout VoiceCall.Environment) -> Void = { _ in }) async -> (VoiceCall, FakeSpeech) {
        let call = userCall(configure)
        call.begin()
        await waitUntil { self.links.count == 1 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        call.audioDidActivate()
        call.startSpeech(.apple)
        return (call, speech[speech.count - 1])
    }

    // MARK: Ringing

    func testPushCallRingsThenAnswers() async {
        let call = pushCall()
        XCTAssertEqual(call.state, .ringing)
        XCTAssertEqual(call.uuid, CallID.uuid(from: callID))
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        XCTAssertEqual(link.hello, PhoneHello(callID: callID, sessionID: "stored-1", title: "Groceries", initiatedBy: .push,
                                              appVersion: PhoneHello.currentAppVersion))

        link.deliver(.ready(callID: callID, ringing: true))
        XCTAssertEqual(link.types, ["ringing"])
        XCTAssertEqual(call.state, .ringing)

        call.answer()
        // CallKit brings the audio up after the answer; the plugin speaks the moment it hears `answered`.
        XCTAssertEqual(link.types, ["ringing"])
        XCTAssertEqual(call.state, .connecting)
        call.audioDidActivate()
        XCTAssertEqual(link.types, ["ringing", "answered"])
        XCTAssertEqual(call.state, .live)
        XCTAssertTrue(ended.isEmpty)
    }

    func testAnsweredBeforeTheLinkIsUp() async {
        let call = pushCall()
        call.begin()
        call.answer()
        call.audioDidActivate()
        XCTAssertEqual(call.state, .connecting)
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        XCTAssertEqual(link.types, ["ringing", "answered"])
        XCTAssertEqual(call.state, .live)
    }

    func testAnsweredGoesOutWithoutAudioAfterAWhile() async {
        // Long enough that the "not yet" check below can't race it on a slow scheduler.
        let call = pushCall { $0.answerAudioWait = 1.5 }
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        call.answer()
        await settle(0.05)
        XCTAssertEqual(link.types, ["ringing"])
        await waitUntil(timeout: 5) { self.link.types == ["ringing", "answered"] }
        XCTAssertEqual(call.state, .live)
        // The audio coming up later doesn't say it again.
        call.audioDidActivate()
        XCTAssertEqual(link.types, ["ringing", "answered"])
    }

    func testAnsweredIsSaidAgainWhenALinkDroppedWhileTheCallRang() async {
        let call = pushCall()
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        call.answer()
        call.audioDidActivate()
        link.drop()  // before it heard `answered`
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        XCTAssertEqual(link.types, ["ringing", "answered"])
        link.drop()  // after: the plugin's call is live now
        await waitUntil { self.links.count == 3 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertTrue(link.types.isEmpty)
        XCTAssertEqual(call.state, .live)
    }

    func testPushCallGoesOnWhenTheChatCantBeOpened() async {
        attachError = URLError(.notConnectedToInternet)
        let call = pushCall()
        call.begin()
        // Two attempts a second apart, then the push's session id is enough.
        await waitUntil(timeout: 3) { self.links.first?.connects == 1 }
        XCTAssertEqual(link.hello.sessionID, "stored-1")
        XCTAssertEqual(call.state, .ringing)
    }

    func testDeclineBeforeAnswer() async {
        let call = pushCall()
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        call.hangUp()
        XCTAssertEqual(link.closedAfter, [.declined, .bye("declined")])
        XCTAssertEqual(call.state, .ended(nil))
        XCTAssertTrue(ended.isEmpty, "a decline here isn't reported back")
    }

    func testDeclineBeforeTheLinkIsUpIsDeliveredOnReady() async {
        do {
            // CallController lets the call go as soon as it is declined.
            let call = pushCall()
            call.begin()
            call.hangUp()
            XCTAssertTrue(call.isEnded)
        }
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        XCTAssertEqual(link.closedAfter, [.declined, .bye("declined")])
        XCTAssertTrue(link.sent.isEmpty, "no ringing for a declined call")
    }

    func testRingTimeoutEndsUnanswered() async {
        // The ring timer counts from the push, so its budget must also cover the link's setup and `ready` on a busy
        // main actor: a second and a half does, where 0.2 s raced it.
        let call = pushCall { $0.ringTimeout = 1.5 }
        call.begin()
        await waitUntil(timeout: 5) { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        XCTAssertFalse(call.isEnded, "the link is ready before the ring times out")
        await waitUntil(timeout: 5) { call.isEnded }
        XCTAssertEqual(ended, [.unanswered])
        XCTAssertEqual(link.closedAfter, [.bye("no_answer")])
    }

    func testRingTimeoutCountsFromThePush() async {
        let call = pushCall { $0.ringTimeout = 30 }
        call.begin(ringingSince: Date().addingTimeInterval(-29.8))
        await waitUntil { call.isEnded }
        XCTAssertEqual(ended, [.unanswered])
    }

    func testAnswerStopsTheRingTimer() async {
        // As above: the budget covers the setup, so the answer comes before the ring would time out.
        let call = pushCall { $0.ringTimeout = 1 }
        call.begin()
        await waitUntil(timeout: 5) { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        XCTAssertFalse(call.isEnded)
        call.answer()
        call.audioDidActivate()
        await settle(1.3)
        XCTAssertEqual(call.state, .live)
        XCTAssertTrue(ended.isEmpty)
    }

    func testPluginCancelsTheRing() async {
        let call = pushCall()
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        link.deliver(.cancel("no_answer"))
        XCTAssertEqual(ended, [.unanswered])
        XCTAssertEqual(link.closedAfter, [])

        let other = pushCall()
        other.begin()
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        link.deliver(.cancel("ended_by_agent"))
        XCTAssertEqual(ended, [.unanswered, .remote(nil)])
    }

    // MARK: Calls the user starts

    func testUserCallGoesLiveOnReady() async {
        let call = userCall()
        var connected = 0
        call.onConnected = { connected += 1 }
        XCTAssertEqual(call.state, .connecting)
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        XCTAssertEqual(link.hello.initiatedBy, .user)
        XCTAssertEqual(link.hello.sessionID, "stored-1")
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertEqual(call.state, .live)
        XCTAssertTrue(link.sent.isEmpty, "a user call neither rings nor answers")
        XCTAssertEqual(connected, 1)
    }

    func testUserCallFailsWithoutTheChat() async {
        attachError = DashboardError.rpc("no such session")
        let call = userCall()
        call.begin()
        await waitUntil(timeout: 5) { call.isEnded }
        XCTAssertTrue(links.isEmpty)
        guard case .failed? = ended.first else { return XCTFail("\(ended)") }
    }

    func testBusySlot() async {
        let call = userCall()
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.drop(.busy)
        XCTAssertEqual(ended, [.failed(CallOutcome.busy.message!)])
        XCTAssertTrue(call.isEnded)
    }

    func testEndedOutcomes() async {
        let cases: [(CallOutcome, VoiceCall.EndCause)] = [
            (.endedByAgent, .remote(nil)), (.noAnswer, .unanswered), (.notAllowed, .failed(CallOutcome.notAllowed.message!)),
            (.ttsFailed, .failed(CallOutcome.ttsFailed.message!)), (.busy, .failed(CallOutcome.busy.message!)),
        ]
        for (outcome, cause) in cases {
            ended = []
            let call = userCall()
            call.begin()
            await waitUntil { self.links.first?.connects == 1 }
            link.deliver(.ready(callID: callID, ringing: false))
            link.deliver(.ended(outcome))
            XCTAssertEqual(ended, [cause], "\(outcome)")
            XCTAssertTrue(call.isEnded)
            links.removeAll()
        }
    }

    func testReconnectsAfterADropAndGivesUp() async {
        let call = userCall()
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        link.drop()
        XCTAssertEqual(call.statusNote, "Reconnecting to Hermes…")
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        // Each reconnect is a new link, which mints its own ticket.
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertNil(call.statusNote)
        XCTAssertEqual(call.state, .live)

        link.drop()
        await waitUntil { self.links.count == 3 }
        link.drop()
        await waitUntil { self.links.count == 4 }
        link.drop()
        XCTAssertEqual(ended, [.failed("Lost the connection to Hermes.")])
    }

    func testUnauthorizedEndsTheCall() async {
        let call = userCall()
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.drop(.unauthorized)
        guard case .failed? = ended.first else { return XCTFail("\(ended)") }
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(call.isEnded)
    }

    func testPlayedIsSentAndRepeatedAfterReconnect() async {
        let (call, _) = await liveCall()
        defer { withExtendedLifetime(call) {} }
        link.deliver(.speechStart(id: "u1", text: "Hello", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        link.deliver(.speechEnd(id: "u1", cancelled: false, error: nil))
        XCTAssertEqual(link.sent, [.played("u1")])
        link.drop()
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertEqual(link.sent, [.played("u1")])
    }

    func testALineThatDidntReachTheSpeakerIsNotAcked() async {
        // A user call whose audio isn't up yet (CallKit activates it after the call starts).
        let call = userCall()
        defer { withExtendedLifetime(call) {} }
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        link.deliver(.speechStart(id: "u1", text: "Hello", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        link.deliver(.speechEnd(id: "u1", cancelled: false, error: nil))
        XCTAssertEqual(link.sent, [.unplayed("u1", reason: "lost")],
                       "dropped audio is never confirmed as heard: the plugin is told it was lost")
        XCTAssertFalse(call.hermesSpeaking, "the microphone listens again")
        // Once the audio runs, lines are heard and acked.
        call.audioDidActivate()
        link.deliver(.speechStart(id: "u2", text: "Hi again", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        link.deliver(.speechEnd(id: "u2", cancelled: false, error: nil))
        XCTAssertEqual(link.sent, [.unplayed("u1", reason: "lost"), .played("u2")])
        // A reconnect repeats only the heard one.
        link.drop()
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertEqual(link.sent, [.played("u2")])
    }

    // MARK: Turns

    func testTurnsGoOutAsUserTurns() async {
        let (call, speech) = await liveCall()
        XCTAssertEqual(speech.paused.last, false)
        speech.hear("buy milk")
        await waitUntil { call.hearing == "buy milk" }
        speech.finishTurn()
        await waitUntil { !self.link.turns.isEmpty }
        XCTAssertEqual(link.turns.map(\.text), ["buy milk"])
        XCTAssertEqual(link.turns.first?.callID, callID)
        XCTAssertEqual(call.hearing, "")
    }

    func testTurnsWhileTheLinkIsDownWaitForTheNextOne() async {
        let (call, speech) = await liveCall()
        defer { withExtendedLifetime(call) {} }
        link.drop()
        speech.hear("are you there")
        speech.finishTurn()
        await settle()
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        XCTAssertTrue(link.turns.isEmpty)
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertEqual(link.turns.map(\.text), ["are you there"])
    }

    func testSpeechWaitsForTheSentenceThenCutsIn() async {
        let (call, speech) = await liveCall()
        speech.hear("I was just saying")
        link.deliver(.speechStart(id: "u1", text: "Sure", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        // Held while the user finishes: still listening.
        XCTAssertFalse(call.hermesSpeaking)
        XCTAssertEqual(speech.paused.last, false)
        await waitUntil { call.hermesSpeaking }
        XCTAssertEqual(link.turns.map(\.ending), [.cutOff])
        XCTAssertEqual(link.turns.map(\.text), ["I was just saying"])
        XCTAssertEqual(speech.paused.last, true)
    }

    func testSpeechPlaysAsSoonAsTheSentenceEnds() async {
        let (call, speech) = await liveCall()
        speech.hear("one more thing")
        link.deliver(.speechStart(id: "u1", text: "Sure", sampleRate: 24_000))
        speech.finishTurn()
        await waitUntil { call.hermesSpeaking }
        XCTAssertEqual(link.turns.map(\.ending), [.endOfSpeech(detector: "test", detail: nil)])
        // The speech that waited carries on normally.
        link.deliver(.speechEnd(id: "u1", cancelled: false, error: nil))
        XCTAssertEqual(link.sent.last, .played("u1"))
        XCTAssertFalse(call.hermesSpeaking)
    }

    func testSpeechWithNobodyTalkingPlaysAtOnce() async {
        let (call, speech) = await liveCall()
        link.deliver(.speechStart(id: "u1", text: "Hi", sampleRate: 24_000))
        XCTAssertTrue(call.hermesSpeaking)
        XCTAssertEqual(speech.paused.last, true)
        XCTAssertEqual(speech.flushed, [.cutOff])
        XCTAssertTrue(link.turns.isEmpty)
    }

    func testSpeechWaitsThroughAThinkingPause() async {
        // The grace outlasts the pause that ends a turn (`cutOffGrace(pause:)`), so a user who has stopped talking,
        // to think or because they are done, isn't cut off before that pause is over.
        let (call, speech) = await liveCall { $0.cutOffGrace = 5 }
        speech.hear("let me think")
        link.deliver(.speechStart(id: "u1", text: "Sure", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        await settle(0.6)
        XCTAssertFalse(call.hermesSpeaking)
        XCTAssertEqual(speech.paused.last, false, "still listening: the pause runs on")
        XCTAssertTrue(link.turns.isEmpty)
        // The pause passes: the turn ended by itself, and Hermes' line plays.
        speech.finishTurn()
        await waitUntil { call.hermesSpeaking }
        XCTAssertEqual(link.turns.map(\.ending), [.endOfSpeech(detector: "test", detail: nil)])
        XCTAssertEqual(speech.paused.last, true, "no pause is counted while Hermes speaks")
        link.deliver(.speechEnd(id: "u1", cancelled: false, error: nil))
        XCTAssertEqual(link.sent.last, .played("u1"))
        XCTAssertEqual(speech.paused.last, false)
    }

    // MARK: Send now

    func testSendNowEndsTheTurnAtOnce() async {
        let (call, speech) = await liveCall()
        XCTAssertFalse(call.canSendNow)
        speech.hear("that is all I wanted to say")
        await waitUntil { call.canSendNow }
        call.sendNow()
        XCTAssertEqual(link.turns.map(\.text), ["that is all I wanted to say"])
        XCTAssertEqual(link.turns.first?.ending, .endOfSpeech(detector: "send_now", detail: nil))
        XCTAssertEqual(link.turns.first?.callID, callID)
        XCTAssertEqual(call.hearing, "")
        XCTAssertFalse(call.canSendNow)
        XCTAssertEqual(speech.paused.last, false, "listening goes on")
        XCTAssertFalse(call.hermesSpeaking)
        // Nothing is left to send.
        call.sendNow()
        XCTAssertEqual(link.turns.count, 1)
        // What is said next is a turn of its own.
        speech.hear("one more thing")
        speech.finishTurn()
        await waitUntil { self.link.turns.count == 2 }
        XCTAssertEqual(link.turns.map(\.text), ["that is all I wanted to say", "one more thing"])
    }

    func testSendNowGoesOutAsAFinishedTurn() async throws {
        let (call, speech) = await liveCall()
        speech.hear("done")
        call.sendNow()
        let sent = try XCTUnwrap(link.sent.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try sent.encoded().utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "user_turn")
        XCTAssertEqual(json["text"] as? String, "done")
        // The plugin reads `kind`; a turn that ended normally is the reply a waiting start_call takes.
        XCTAssertEqual(json["ending"] as? NSDictionary, ["kind": "end_of_speech", "detector": "send_now"])
    }

    func testSendNowLetsHermesSpeechThatWaitedPlay() async {
        let (call, speech) = await liveCall { $0.cutOffGrace = 30 }
        speech.hear("I am done")
        link.deliver(.speechStart(id: "u1", text: "Sure", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        XCTAssertFalse(call.hermesSpeaking)
        call.sendNow()
        XCTAssertTrue(call.hermesSpeaking, "the line that waited for the turn plays at once")
        XCTAssertEqual(call.lastSpoken, "Sure")
        XCTAssertEqual(speech.paused.last, true)
        XCTAssertEqual(link.turns.map(\.ending), [.endOfSpeech(detector: "send_now", detail: nil)], "sent, not cut off")
        link.deliver(.speechEnd(id: "u1", cancelled: false, error: nil))
        XCTAssertEqual(link.sent.last, .played("u1"))
        XCTAssertFalse(call.hermesSpeaking)
    }

    func testSendNowWhileTheLinkIsDownWaitsForTheNextOne() async {
        let (call, speech) = await liveCall()
        link.drop()
        speech.hear("are you there")
        call.sendNow()
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        XCTAssertTrue(link.turns.isEmpty)
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertEqual(link.turns.map(\.text), ["are you there"])
        XCTAssertEqual(link.turns.first?.ending, .endOfSpeech(detector: "send_now", detail: nil))
    }

    func testNothingToSendNowWithoutWords() async {
        let (call, speech) = await liveCall()
        call.sendNow()
        XCTAssertTrue(link.turns.isEmpty)
        // While Hermes speaks (or the call is muted) nothing is heard, so there is nothing to send.
        link.deliver(.speechStart(id: "u1", text: "Hi", sampleRate: 24_000))
        XCTAssertFalse(call.canSendNow)
        call.sendNow()
        XCTAssertTrue(link.turns.isEmpty)
        XCTAssertEqual(speech.paused.last, true)
    }

    func testHangUpFlushesWhatWasHeard() async {
        let (call, speech) = await liveCall()
        speech.hear("and one more")
        call.hangUp()
        XCTAssertEqual(link.closedAfter?.map(\.type), ["user_turn", "bye"])
        XCTAssertEqual(link.turns.map(\.ending), [.hangUp])
        XCTAssertEqual(link.closedAfter?.last, .bye("hang_up"))
        XCTAssertTrue(speech.stopped)
        XCTAssertTrue(ended.isEmpty)
    }

    func testMuteFlushesWhatWasHeard() async {
        let (call, speech) = await liveCall()
        speech.hear("wait")
        call.setMuted(true)
        XCTAssertEqual(link.turns.map(\.ending), [.muted])
        XCTAssertEqual(speech.paused.last, true)
        call.setMuted(false)
        XCTAssertEqual(speech.paused.last, false)
    }

    func testScribeFailureFallsBackToApple() async {
        let call = userCall()
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        call.startSpeech(.scribe)
        XCTAssertEqual(call.speechProvider, .scribe)
        speech[0].fail(ScribeSpeechProvider.Failure.rejected("quota"))
        await waitUntil { call.speechProvider == .apple }
        XCTAssertTrue(speech[0].stopped)
        XCTAssertEqual(speech.map(\.id), [.scribe, .apple])
        XCTAssertNotNil(call.statusNote)
    }

    func testTypedTurn() async {
        let (call, _) = await liveCall()
        call.sayTyped("  typed words ")
        XCTAssertEqual(link.turns.map(\.text), ["typed words"])
        XCTAssertEqual(link.turns.first?.ending, .endOfSpeech(detector: "typed", detail: nil))
    }

    func testNoTurnsBeforeAnswer() async {
        let call = pushCall()
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        call.sayTyped("too early")
        XCTAssertTrue(link.turns.isEmpty)
    }

    // MARK: Playback facts

    /// Delivers one whole line of Hermes: its start, `frames` of audio, its end.
    private func speak(_ id: String, _ text: String = "Hello", frames: [Data] = [Data(count: 480)]) {
        link.deliver(.speechStart(id: id, text: text, sampleRate: 24_000))
        frames.forEach { link.deliver(.audio($0)) }
        link.deliver(.speechEnd(id: id, cancelled: false, error: nil))
    }

    func testPlayedCarriesWhatHappenedToTheLine() async {
        let (call, _) = await liveCall()
        defer { withExtendedLifetime(call) {} }
        let facts = PlaybackFacts(audioSeconds: 4, playedSeconds: 4, stalls: 2, stallSeconds: 1.8, route: .speaker, volume: 0.5)
        audio[0].facts["u1"] = facts
        speak("u1")
        XCTAssertEqual(audio[0].lines, ["u1"], "the audio is told which line its frames belong to")
        XCTAssertEqual(link.sent, [.played("u1", playback: facts)])
        // The repeat after a reconnect is the bare ack: the facts went with the first one.
        link.drop()
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertEqual(link.sent, [.played("u1")])
    }

    func testHangingUpMidLineSaysHowMuchOfItWasHeard() async {
        let (call, _) = await liveCall()
        audio[0].holdsPlayback = true
        let heard = PlaybackFacts(audioSeconds: 9, playedSeconds: 2.2, route: .receiver)
        audio[0].facts["u1"] = heard
        speak("u1")
        // A second line is still streaming when the user hangs up.
        link.deliver(.speechStart(id: "u2", text: "And", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        XCTAssertEqual(link.sent, [])
        call.hangUp()
        XCTAssertEqual(link.closedAfter, [
            .unplayed("u1", reason: "hang_up", playback: heard), .unplayed("u2", reason: "hang_up"), .bye("hang_up"),
        ])
    }

    func testACancelledLineIsReported() async {
        let (call, _) = await liveCall()
        audio[0].holdsPlayback = true
        let facts = PlaybackFacts(audioSeconds: 1, playedSeconds: 0.4)
        audio[0].facts["u1"] = facts
        link.deliver(.speechStart(id: "u1", text: "Hello", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        link.deliver(.speechEnd(id: "u1", cancelled: true, error: nil))
        XCTAssertEqual(link.sent, [.unplayed("u1", reason: "cancelled", playback: facts)])
        XCTAssertEqual(audio[0].flushes, 1)
        XCTAssertFalse(call.hermesSpeaking)
        XCTAssertFalse(call.canRepeat, "a line that never finished is not kept for Repeat")
    }

    func testALineTheLinkDroppedUnderIsReportedOnTheNextLink() async {
        let (call, _) = await liveCall()
        defer { withExtendedLifetime(call) {} }
        audio[0].holdsPlayback = true
        speak("u1")  // all of it arrived; it is still playing
        link.deliver(.speechStart(id: "u2", text: "And", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        link.drop()
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        XCTAssertEqual(link.sent, [])
        link.deliver(.ready(callID: callID, ringing: false))
        // The queue was dropped with the link: the first line won't come again, the plugin carries on with the second.
        XCTAssertEqual(link.sent, [.unplayed("u1", reason: "lost"), .unplayed("u2", reason: "dropped")])
        link.drop()
        await waitUntil { self.links.count == 3 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertEqual(link.sent, [], "told once")
    }

    // MARK: Repeat

    func testRepeatPlaysTheLastLineAgainFromWhatThePhoneKept() async {
        let (call, speech) = await liveCall()
        XCTAssertFalse(call.canRepeat, "nothing was said yet")
        call.repeatLast()
        XCTAssertEqual(link.sent, [])
        audio[0].holdsPlayback = true
        let frames = [Data([1, 0, 2, 0]), Data([3, 0, 4, 0, 5, 0])]
        speak("u1", "The meeting moved to three.", frames: frames)
        XCTAssertFalse(call.canRepeat, "not while Hermes is speaking")
        audio[0].finishPlayback()
        XCTAssertEqual(link.sent, [.played("u1")])
        XCTAssertFalse(call.hermesSpeaking)
        XCTAssertEqual(speech.paused.last, false)
        XCTAssertTrue(call.canRepeat)

        call.repeatLast()
        XCTAssertEqual(link.sent, [.played("u1"), .replayed("u1")], "the plugin hears of it; no new speech is asked for")
        XCTAssertEqual(audio[0].enqueued, frames + [frames[0] + frames[1]], "the same audio, from memory")
        XCTAssertEqual(audio[0].lines.count, 2)
        XCTAssertEqual(call.lastSpoken, "The meeting moved to three.")
        // Half duplex holds for a replay as for any line of Hermes: the microphone is off until it has played.
        XCTAssertTrue(call.hermesSpeaking)
        XCTAssertEqual(speech.paused.last, true)
        XCTAssertFalse(call.canRepeat)
        call.repeatLast()
        XCTAssertEqual(audio[0].enqueued.count, 3, "one at a time")
        audio[0].finishPlayback()
        XCTAssertFalse(call.hermesSpeaking)
        XCTAssertEqual(speech.paused.last, false)
        XCTAssertEqual(link.sent, [.played("u1"), .replayed("u1")], "a replay is not acked as a line")
        XCTAssertTrue(link.turns.isEmpty, "nobody was cut off")
        XCTAssertTrue(call.canRepeat, "and it can be played again")
    }

    func testRepeatMidSentenceSendsWhatWasHeardAsCutOff() async {
        let (call, speech) = await liveCall()
        speak("u1")
        speech.hear("sorry what")
        await waitUntil { call.hearing == "sorry what" }
        call.repeatLast()
        // The plugin learns of the replay before the turn, so that it can tell Hermes with it.
        XCTAssertEqual(link.types, ["played", "replayed", "user_turn"])
        XCTAssertEqual(link.turns.map(\.ending), [.cutOff])
        XCTAssertEqual(link.turns.map(\.text), ["sorry what"])
    }

    func testALineOfHermesDuringAReplayPlaysAfterItWithTheMicStillOff() async {
        let (call, speech) = await liveCall()
        speak("u1", "First.")
        audio[0].holdsPlayback = true
        call.repeatLast()
        speak("u2", "Second.")
        XCTAssertTrue(call.hermesSpeaking)
        audio[0].finishPlayback()
        XCTAssertEqual(link.sent, [.played("u1"), .replayed("u1"), .played("u2")])
        XCTAssertFalse(call.hermesSpeaking)
        XCTAssertEqual(speech.paused.last, false)
        // Repeat is always the newest line.
        call.repeatLast()
        XCTAssertEqual(link.sent.last, .replayed("u2"))
        XCTAssertEqual(call.lastSpoken, "Second.")
    }

    func testARepeatWhileTheLinkIsDownIsToldOnTheNextOne() async {
        let (call, _) = await liveCall()
        speak("u1")
        link.drop()
        call.repeatLast()
        XCTAssertEqual(audio[0].enqueued.count, 2, "it plays at once, without the host")
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        XCTAssertEqual(link.sent, [.played("u1"), .replayed("u1")])
    }

    func testTheKeptLineGoesWithTheCall() async {
        let (call, _) = await liveCall()
        speak("u1")
        XCTAssertTrue(call.hasLineToRepeat)
        call.hangUp()
        XCTAssertFalse(call.hasLineToRepeat)
        XCTAssertFalse(call.canRepeat)
        call.repeatLast()
        XCTAssertEqual(audio[0].enqueued.count, 1)
    }

    func testALineTheLinkDroppedUnderIsNotKeptForRepeat() async {
        let (call, _) = await liveCall()
        defer { withExtendedLifetime(call) {} }
        speak("u1", "Whole.")
        // The plugin carries on with a broken line where it was: what arrives after the drop is not all of it.
        link.deliver(.speechStart(id: "u2", text: "Broken.", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        link.drop()
        await waitUntil { self.links.count == 2 && self.link.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: false))
        speak("u2", "Broken.")
        XCTAssertTrue(link.sent.contains(.played("u2")))
        call.repeatLast()
        XCTAssertEqual(call.lastSpoken, "Whole.", "Repeat still plays the last line it has all of")
        XCTAssertEqual(link.sent.last, .replayed("u1"))
    }
}
