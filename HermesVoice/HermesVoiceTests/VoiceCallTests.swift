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
        return running
    }

    func whenPlayedBack(_ done: @escaping (Bool) -> Void) {
        let heard = running && !lost
        lost = false
        done(heard)
    }

    func flush() {
        lost = false
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
    private func liveCall() async -> (VoiceCall, FakeSpeech) {
        let call = userCall()
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
        let call = pushCall { $0.answerAudioWait = 0.2 }
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        call.answer()
        await settle(0.05)
        XCTAssertEqual(link.types, ["ringing"])
        await waitUntil { self.link.types == ["ringing", "answered"] }
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
        let call = pushCall { $0.ringTimeout = 0.2 }
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        await waitUntil { call.isEnded }
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
        let call = pushCall { $0.ringTimeout = 0.2 }
        call.begin()
        await waitUntil { self.links.first?.connects == 1 }
        link.deliver(.ready(callID: callID, ringing: true))
        call.answer()
        call.audioDidActivate()
        await settle(0.4)
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
        XCTAssertTrue(link.sent.isEmpty, "dropped audio is never confirmed as heard")
        XCTAssertFalse(call.hermesSpeaking, "the microphone listens again")
        // Once the audio runs, lines are heard and acked.
        call.audioDidActivate()
        link.deliver(.speechStart(id: "u2", text: "Hi again", sampleRate: 24_000))
        link.deliver(.audio(Data(count: 480)))
        link.deliver(.speechEnd(id: "u2", cancelled: false, error: nil))
        XCTAssertEqual(link.sent, [.played("u2")])
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
}
