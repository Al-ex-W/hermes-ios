import AVFoundation
import Foundation

/// A voice call in one chat, carried by the Hermes Voice plugin (`/api/plugins/hermes_voice/phone`). Hermes is heard
/// only through `start_call`, whose speech the plugin streams down the link; what the user says goes back as
/// `user_turn` messages, and the plugin hands each one to the waiting `start_call` or injects it into the session.
/// The plugin also posts the call's notices to Hermes, so the phone never sends prompts for the call.
///
/// A call the user starts goes live once the plugin is ready. A call Hermes rings (a VoIP push) rings until the
/// user answers, declines, or `ringTimeout` passes; the plugin speaks only after `answered`, which goes out once the
/// call's audio runs. A line is acknowledged as `played` only if all of it reached the speaker.
@MainActor
final class VoiceCall: ObservableObject, Identifiable {
    enum State: Equatable { case ringing, connecting, live, ended(String?) }

    /// Why a call ended.
    enum EndCause: Equatable {
        /// Hung up or declined on this phone.
        case local
        /// Hermes ended it, or stopped ringing; the message is for the user, when there is one.
        case remote(String?)
        /// Nobody answered in time.
        case unanswered
        /// Something went wrong; the message says what.
        case failed(String)
    }

    /// What the call needs from outside: the plugin socket, speech recognition and the chat's session. Tests script them.
    struct Environment {
        var makeLink: @MainActor (PhoneHello) -> CallLink
        /// A provider for (which recognizer, call id).
        var makeSpeech: @MainActor (SpeechProviderID, String) -> SpeechProvider
        /// The speaker and microphone.
        var makeAudio: @MainActor () -> CallAudioPlayback = { CallAudio() }
        /// Opens the chat's session on the gateway, so the hello can carry its stored id.
        var attach: @MainActor (ChatModel) async throws -> Void = { try await $0.ensureAttached() }
        /// Matches the plugin's ring timeout.
        var ringTimeout: TimeInterval = 45
        /// How long Hermes' speech waits for the user to finish a sentence before cutting in.
        var cutOffGrace: TimeInterval = 3
        /// Seconds before each reconnect attempt; together under the plugin's 60 s before a dropped call is lost.
        var reconnectDelays: [Double] = [0.5, 1, 2, 4, 8, 8, 15, 15]
        /// How long a call declined before its link was up keeps trying to tell the plugin.
        var declineLinger: TimeInterval = 10
        /// How long an answered call waits for CallKit to bring up its audio before it says `answered` anyway.
        var answerAudioWait: TimeInterval = 5

        static func live(client: DashboardClient, settings: CallSettings) -> Environment {
            Environment(
                makeLink: { hello in VoiceLink(client: client, hello: hello) },
                makeSpeech: { provider, callID in
                    switch provider {
                    case .apple:
                        return AppleSpeechProvider(callID: callID, localeIdentifier: settings.speechLocale,
                                                   pause: settings.endOfSpeech.appleSilence)
                    case .scribe:
                        return ScribeSpeechProvider(callID: callID, language: settings.languageCode,
                                                    silence: settings.endOfSpeech.scribeSilence) {
                            try await VoicePluginAPI.scribeToken(client)
                        }
                    }
                }
            )
        }
    }

    @Published private(set) var state: State
    @Published private(set) var hermesSpeaking = false
    @Published private(set) var muted = false
    @Published private(set) var hearing = ""
    @Published private(set) var lastSpoken = ""
    @Published private(set) var speakerOn = true
    /// The speech recognizer listening now (Scribe falls back to Apple when it can't go on).
    @Published private(set) var speechProvider: SpeechProviderID
    /// A notice shown under the call status (reconnecting, audio interrupted, speech recognition trouble).
    @Published private(set) var statusNote: String?

    /// 32 lowercase hex characters: the plugin's call id, and the CallKit UUID with the dashes taken out.
    let callID: String
    let uuid: UUID
    let chat: ChatModel
    let settings: CallSettings
    let initiatedBy: CallInitiator
    /// The push that rang, for a call Hermes started.
    let push: CallPush?
    /// The call ended by itself (not hung up here); CallController ends the CallKit side.
    var onEnded: ((EndCause) -> Void)?
    /// The call went live for the first time.
    var onConnected: (() -> Void)?

    private let environment: Environment
    private let audio: CallAudioPlayback
    private let input = AudioInputTap()
    private var speech: SpeechProvider?
    private var speechEvents: Task<Void, Never>?
    private var link: CallLink?
    /// The current link said `ready`.
    private var linkReady = false
    private var answered: Bool
    /// The user answered and the plugin, still ringing on the current link, hasn't been told (see `sendAnswer`).
    private var answerOwed = false
    private var answerAudioTimer: Task<Void, Never>?
    private var answerAudioWaitOver = false
    private var began = false
    private var audioBegan = false
    private var connected = false
    private var reconnects = 0
    private var reconnectTask: Task<Void, Never>?
    private var ringTimer: Task<Void, Never>?
    /// Declined before the link was up: `declined` goes out once it is (for at most `declineLinger`).
    private var declinePending = false
    /// Turns heard while no link was up, sent in order on the next `ready`.
    private var outbox: [UserTurn] = []
    /// Hermes' speech held back while the user finishes a sentence (see `holdSpeech`).
    private var deferred: [PluginMessage] = []
    private var deferTimer: Task<Void, Never>?
    private var replaying = false
    /// Utterances started by the plugin and not yet heard (or cancelled).
    private var pendingSpeech: Set<String> = []
    /// Pending utterances whose audio has all arrived (a normal speech_end), waiting to be played back.
    private var completeSpeech: Set<String> = []
    /// Pending utterances still streaming (no speech_end yet), with when the plugin last sent anything for them
    /// (speech_start, or any audio frame: one utterance streams at a time). See `watchSpeech`.
    private var speechHeard: [String: Date] = [:]
    /// The utterance whose audio is arriving now (binary frames carry no id: they belong to the last speech_start),
    /// until its speech_end. Lets audio that turns up after `watchSpeech` gave up on it bring it back.
    private var streamingSpeech: String?
    private var speechWatch: Task<Void, Never>?
    /// When the audio received so far should have been heard (it can arrive faster than it plays).
    private var audioUntil: Date?
    private var speechRate: Double = 24_000
    /// How long a streaming utterance may go without a frame, past the end of its queued audio, before it is dropped.
    private static let speechSilence: TimeInterval = 12
    /// Bumped when queued speech is dropped wholesale, so played-back callbacks from before are ignored.
    private var speechGeneration = 0
    /// The last few utterances confirmed as heard. Their `played` is sent again after a reconnect, in case
    /// it went out on a socket that was already dead; the plugin ignores ids it isn't waiting for.
    private var recentlyPlayed: [String] = []
    private var audioStarts = 0
    private var speakerChosen = false
    private var audioNote: String? { didSet { refreshNote() } }
    private var linkNote: String? { didSet { refreshNote() } }
    private var speechNote: String? { didSet { refreshNote() } }

    init(chat: ChatModel, settings: CallSettings, initiatedBy: CallInitiator, callID: String = CallID.make(),
         push: CallPush? = nil, environment: Environment) {
        self.chat = chat
        self.settings = settings
        self.initiatedBy = initiatedBy
        self.callID = CallID.normalize(callID) ?? CallID.make()
        uuid = CallID.uuid(from: self.callID) ?? UUID()
        self.push = push
        self.environment = environment
        audio = environment.makeAudio()
        speechProvider = settings.provider
        answered = initiatedBy == .user
        state = initiatedBy == .push ? .ringing : .connecting
        audio.onEvent = { [weak self] event in self?.audioEvent(event) }
    }

    var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// Opens the link to the plugin: at once for a call that rings, so the plugin hears `ringing`. `ringingSince`:
    /// when the push arrived, which the ring timeout counts from.
    func begin(ringingSince: Date = Date()) {
        guard !began, !isEnded else { return }
        began = true
        chat.setInUse(useKey, true)
        if !answered { startRingTimer(since: ringingSince) }
        Task { await connect() }
    }

    /// The user answered a call that rang. The plugin hears it once the call's audio runs (`sendAnswer`).
    func answer() {
        guard !answered, !isEnded else { return }
        answered = true
        ringTimer?.cancel()
        ringTimer = nil
        state = .connecting
        let wait = environment.answerAudioWait
        answerAudioTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.answerAudioWaitOver = true
            self.sendAnswer()
        }
        if linkReady {
            answerOwed = true
            sendAnswer()
        }
    }

    /// Tells the plugin the call was answered, once the call's audio runs. The plugin speaks Hermes' first line the
    /// moment it hears `answered`, and CallKit activates the audio only after the answer: told earlier, the line
    /// would arrive before there is an engine to play it. If the audio isn't up after `answerAudioWait`, it goes out
    /// anyway (what can't be played then isn't acknowledged as heard).
    private func sendAnswer() {
        guard answerOwed, linkReady, !isEnded else { return }
        guard audioStarts > 0 || answerAudioWaitOver else { return }
        answerOwed = false
        answerAudioTimer?.cancel()
        answerAudioTimer = nil
        link?.send(.answered)
        goLive()
    }

    /// Hung up (or declined) on this phone. What was heard of an unfinished sentence goes to Hermes first.
    func hangUp() {
        if isEnded { return }
        guard answered else { return decline() }
        if let turn = speech?.flush(.hangUp) { outbox.append(turn) }
        var final: [PhoneMessage] = []
        if linkReady {
            final = outbox.map(PhoneMessage.userTurn)
            outbox.removeAll()
        }
        final.append(.bye("hang_up"))
        link?.close(after: final)
        link = nil
        finish(.local)
    }

    /// CallKit's audio session is up: start the speaker and microphone. The first time it also starts listening;
    /// later activations (after an interruption) only bring the audio back.
    func audioDidActivate() {
        if isEnded { return }
        if !audioBegan {
            audioBegan = true
            if CallAudio.usesMicrophone {
                startSpeech(settings.provider)
            } else {
                speechNote = "Simulator: no microphone. Hermes can be heard; type below to answer."
            }
        }
        let input = input
        audio.start { buffer in input.feed(buffer) }
    }

    /// CallKit took the audio session away; the next `audioDidActivate` restarts it.
    func audioDidDeactivate() {
        if isEnded { return }
        audio.suspend()
        audioNote = "Call audio paused by iOS…"
    }

    func setMuted(_ value: Bool) {
        muted = value
        updateListening(flushing: value ? .muted : nil)
    }

    func toggleSpeaker() {
        guard audioStarts > 0 else { return speakerOn.toggle() }
        try? CallAudio.setSpeaker(!CallAudio.outputIsSpeaker)
        speakerOn = CallAudio.outputIsSpeaker
    }

    /// A turn typed instead of spoken (the Simulator has no microphone).
    func sayTyped(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = Date()
        deliver(UserTurn(callID: callID, text: text, ending: .endOfSpeech(detector: "typed", detail: nil),
                         provider: speechProvider, language: nil, startedAt: now, endedAt: now))
    }

    // MARK: Link

    /// This call's hold on the chat. Each call has its own, so a late release from an earlier call in the same
    /// chat can't end a newer call's hold.
    private var useKey: String { "call-\(callID)" }

    /// Resumes the chat on the gateway first, so the hello carries its stored session id. A call that rang knows its
    /// session from the push and goes on without it; one the user starts needs it.
    private func connect() async {
        let knowsSession = push?.sessionID != nil
        let attempts = knowsSession ? 2 : 3
        for attempt in 0..<attempts {
            do {
                try await environment.attach(chat)
                break
            } catch {
                if isEnded && !declinePending { return }
                if attempt == attempts - 1 {
                    guard knowsSession else { return fail("Couldn't open this chat in Hermes: \(error.localizedDescription)") }
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        // A call declined meanwhile still opens the link, to say so.
        if isEnded && !declinePending { return }
        openLink()
    }

    private func openLink() {
        link?.close(after: [])
        let hello = PhoneHello(callID: callID, sessionID: chat.storedID ?? push?.sessionID,
                               title: push?.title ?? chat.title, initiatedBy: initiatedBy)
        let link = environment.makeLink(hello)
        // Only the current link counts: a replaced one can't trigger reconnects or play speech.
        link.onEvent = { [weak self, weak link] event in
            guard let self, let link, self.link === link else { return }
            self.handle(event)
        }
        self.link = link
        linkReady = false
        Task { await link.connect() }
    }

    private func handle(_ event: VoiceLink.Event) {
        if isEnded {
            // Declined while the link was still coming up: it stays only to say so.
            if declinePending, case .message(.ready) = event { sendDecline() }
            if case .closed = event { link = nil }
            return
        }
        switch event {
        case let .message(message): handle(message)
        case let .closed(reason): linkClosed(reason)
        }
    }

    private func handle(_ message: PluginMessage) {
        switch message {
        case let .ready(_, ringing):
            linkReady = true
            reconnects = 0
            linkNote = nil
            recentlyPlayed.forEach { link?.send(.played($0)) }
            if ringing {
                if initiatedBy == .push { link?.send(.ringing) }
                if answered {
                    answerOwed = true
                    sendAnswer()
                }
            } else if answered {
                goLive()
            }
        case let .cancel(reason):
            link?.close(after: [])
            link = nil
            finish(reason == "no_answer" || reason == "timeout" ? .unanswered : .remote(nil))
        case let .ended(outcome):
            link?.close(after: [])
            link = nil
            finish(Self.cause(of: outcome))
        case .speechStart, .audio, .speechEnd:
            if deferTimer != nil {
                deferred.append(message)
            } else if !replaying, case .speechStart = message, speech?.hasPartial == true, state == .live, environment.cutOffGrace > 0 {
                holdSpeech(message)
            } else {
                play(message)
            }
        case .pong:
            break
        }
    }

    private static func cause(of outcome: CallOutcome) -> EndCause {
        switch outcome {
        case .noAnswer: return .unanswered
        case .answered, .declined, .endedByUser, .endedByAgent: return .remote(nil)
        default: return .failed(outcome.message ?? "The call ended.")
        }
    }

    private func goLive() {
        guard answered, !isEnded else { return }
        state = .live
        let turns = outbox
        outbox.removeAll()
        turns.forEach(deliver)
        updateListening()
        if !connected {
            connected = true
            onConnected?()
        }
    }

    private func linkClosed(_ reason: VoiceLink.Close) {
        link = nil
        linkReady = false
        answerOwed = false  // the next `ready` says whether the plugin still rings
        // Audio on the next link follows a fresh speech_start.
        streamingSpeech = nil
        deferTimer?.cancel()
        deferTimer = nil
        deferred.removeAll()
        // Utterances that fully arrived play out with the mic still paused and are acked on the next link.
        // One cut off mid-stream would never get its played-back marker here (the plugin carries on with it
        // on the next link), so its queued audio is dropped now and listening resumes.
        if !pendingSpeech.isSubset(of: completeSpeech) {
            speechGeneration += 1
            dropQueuedAudio()
            pendingSpeech.removeAll()
            completeSpeech.removeAll()
            speechHeard.removeAll()
            hermesSpeaking = false
            updateListening()
        }
        switch reason {
        case .unauthorized:
            fail("Hermes didn't accept this phone's sign-in for the call. Sign in to the dashboard again.")
        case .badHello:
            fail("Hermes didn't accept the call.")
        case .replaced:
            fail("Another connection took over this call.")
        case .busy:
            fail(CallOutcome.busy.message ?? "Hermes is busy.")
        case .dropped:
            scheduleReconnect()
        }
    }

    /// Keeps the call up across short network drops (Tailscale switching paths, a dashboard restart).
    private func scheduleReconnect() {
        reconnects += 1
        let delays = environment.reconnectDelays
        guard reconnects <= delays.count else { return fail("Lost the connection to Hermes.") }
        linkNote = "Reconnecting to Hermes…"
        let delay = delays[reconnects - 1]
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isEnded else { return }
            self.openLink()
        }
    }

    // MARK: Ringing

    private func startRingTimer(since: Date) {
        let wait = max(0, since.addingTimeInterval(environment.ringTimeout).timeIntervalSinceNow)
        ringTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.answered, !self.isEnded else { return }
            self.link?.close(after: self.linkReady ? [.bye("no_answer")] : [])
            self.link = nil
            self.finish(.unanswered)
        }
    }

    private func decline() {
        if linkReady {
            sendDecline()
        } else if began {
            // Tell the plugin once the link is up, so `start_call` hears "declined" rather than waiting out the ring.
            declinePending = true
            let linger = environment.declineLinger
            // Holds the call meanwhile: CallController has already let it go.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
                guard declinePending else { return }
                declinePending = false
                link?.close(after: [])
                link = nil
            }
        }
        finish(.local)
    }

    private func sendDecline() {
        declinePending = false
        link?.close(after: [.declined, .bye("declined")])
        link = nil
    }

    // MARK: Ending

    private func fail(_ reason: String) {
        if isEnded { return }
        link?.close(after: linkReady ? [.bye("error")] : [])
        link = nil
        finish(.failed(reason))
    }

    /// Ends the call here: stops the audio and listening, drops queued speech. The link was closed by the caller
    /// (or lingers to deliver a decline). Tells `onEnded` unless the user hung up here.
    private func finish(_ cause: EndCause) {
        if isEnded { return }
        switch cause {
        case .local, .unanswered: state = .ended(nil)
        case let .remote(message): state = .ended(message)
        case let .failed(message): state = .ended(message)
        }
        speechGeneration += 1
        reconnectTask?.cancel()
        ringTimer?.cancel()
        answerAudioTimer?.cancel()
        deferTimer?.cancel()
        deferTimer = nil
        deferred.removeAll()
        if !declinePending, link != nil {
            link?.close(after: [])
            link = nil
        }
        speechEvents?.cancel()
        speech?.stop()
        speech = nil
        audio.stop()
        outbox.removeAll()
        pendingSpeech.removeAll()
        completeSpeech.removeAll()
        speechHeard.removeAll()
        streamingSpeech = nil
        speechWatch?.cancel()
        speechWatch = nil
        audioUntil = nil
        hermesSpeaking = false
        hearing = ""
        audioNote = nil
        linkNote = nil
        speechNote = nil
        if began { chat.setInUse(useKey, false) }
        if cause != .local { onEnded?(cause) }
    }

    // MARK: Listening

    /// Starts (or switches to) a speech provider.
    func startSpeech(_ id: SpeechProviderID) {
        speechEvents?.cancel()
        speech?.stop()
        let provider = environment.makeSpeech(id, callID)
        speech = provider
        speechProvider = id
        speechEvents = Task { [weak self] in
            for await event in provider.events {
                guard let self, self.speech === provider else { return }
                self.speechEvent(event, from: provider)
            }
        }
        updateListening()
        let input = input
        Task { [weak self] in
            do {
                try await provider.start(input: input)
            } catch {
                guard let self, self.speech === provider, !self.isEnded else { return }
                self.speechFailed(error, from: provider)
            }
        }
    }

    private func speechEvent(_ event: SpeechEvent, from provider: SpeechProvider) {
        switch event {
        case let .partial(text):
            hearing = text
            if text.isEmpty, deferTimer != nil { releaseSpeech() }
        case let .turn(turn):
            hearing = ""
            deliver(turn)
            if deferTimer != nil { releaseSpeech() }
        case let .status(note):
            speechNote = note
        case let .failed(error):
            speechFailed(error, from: provider)
        }
    }

    /// Scribe can't go on: the call carries on with Apple speech recognition.
    private func speechFailed(_ error: Error, from provider: SpeechProvider) {
        hearing = ""
        guard provider.id != .apple else {
            speechNote = error.localizedDescription
            return
        }
        startSpeech(.apple)
        speechNote = "\(error.localizedDescription) Listening with Apple speech recognition instead."
    }

    /// Sends a turn, or keeps it for the next link. Only an answered call has turns.
    private func deliver(_ turn: UserTurn) {
        guard answered, !isEnded else { return }
        guard linkReady, let link else { return outbox.append(turn) }
        link.send(.userTurn(turn)) { [weak self] sent in
            guard let self, !sent, !self.isEnded else { return }
            // Never written: the link is going down, and the next one sends it.
            self.outbox.append(turn)
        }
    }

    /// The microphone listens only while the call is live, unmuted and Hermes is quiet. `flushing`: what is
    /// heard of an unfinished sentence goes to Hermes, with this ending, before listening pauses.
    private func updateListening(flushing ending: TurnEnding? = nil) {
        let paused = muted || hermesSpeaking || state != .live
        if paused, let ending, let turn = speech?.flush(ending) {
            hearing = ""
            deliver(turn)
        }
        speech?.setPaused(paused)
    }

    // MARK: Hermes' speech

    /// Hermes started speaking while the user is mid-sentence: its speech waits up to `cutOffGrace` for the sentence
    /// to end (the call is half-duplex: the microphone is off while Hermes speaks). Then the user is cut off.
    private func holdSpeech(_ message: PluginMessage) {
        deferred = [message]
        let grace = environment.cutOffGrace
        deferTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.releaseSpeech()
        }
    }

    private func releaseSpeech() {
        deferTimer?.cancel()
        deferTimer = nil
        let messages = deferred
        deferred.removeAll()
        replaying = true
        messages.forEach(play)
        replaying = false
    }

    private func play(_ message: PluginMessage) {
        switch message {
        case let .speechStart(id, text, rate):
            audio.setSampleRate(rate)
            if rate > 0 { speechRate = rate }
            lastSpoken = text
            pendingSpeech.insert(id)
            if completeSpeech.contains(id) {
                // A repeat after a reconnect of one whose audio all arrived already: no more frames, no deadline.
                streamingSpeech = nil
            } else {
                streamingSpeech = id
                speechHeard[id] = Date()
            }
            hermesSpeaking = true
            updateListening(flushing: .cutOff)
            watchSpeech()
        case let .audio(data):
            let now = Date()
            if let id = streamingSpeech, !pendingSpeech.contains(id) {
                // `watchSpeech` gave up on this utterance, but its audio came after all (a slow first byte from the
                // voice service, or a stalled link catching up): pause the mic again and wait for its speech_end.
                pendingSpeech.insert(id)
                speechHeard[id] = now
                hermesSpeaking = true
                updateListening(flushing: .cutOff)
                watchSpeech()
            }
            audio.enqueue(pcm16: data)
            audioUntil = max(audioUntil ?? now, now).addingTimeInterval(Double(data.count / 2) / speechRate)
            speechHeard = speechHeard.mapValues { _ in now }
        case let .speechEnd(id, cancelled, error):
            speechHeard[id] = nil
            if streamingSpeech == id { streamingSpeech = nil }
            if cancelled || error != nil {
                // The rest of this utterance will never come: drop what is queued at once.
                dropQueuedAudio()
                return finishSpeech(id)
            }
            completeSpeech.insert(id)
            let generation = speechGeneration
            audio.whenPlayedBack { [weak self] heard in
                guard let self, generation == self.speechGeneration else { return }
                // Only a line that all reached the speaker is acked: the plugin then takes what the user says next
                // as the reply to it. Unacked, it counts as unconfirmed (the user may not have heard it).
                if heard {
                    // Acked on whichever link is up now (the plugin carries pending acks across reconnects);
                    // the next `ready` repeats it in case it is lost with a dying socket or sent while none is up.
                    self.link?.send(.played(id))
                    self.recentlyPlayed = Array((self.recentlyPlayed + [id]).suffix(4))
                }
                self.finishSpeech(id)
            }
        default:
            break
        }
    }

    private func finishSpeech(_ id: String) {
        pendingSpeech.remove(id)
        completeSpeech.remove(id)
        speechHeard[id] = nil
        hermesSpeaking = !pendingSpeech.isEmpty
        updateListening()
    }

    private func dropQueuedAudio() {
        audio.flush()
        audioUntil = nil
    }

    /// Drops streaming utterances the plugin has gone quiet on. Their final cancelled/error speech_end can be lost
    /// while the socket stays up (the plugin gives up on a send stuck behind a full buffer), which would otherwise
    /// keep the mic paused for the rest of the call. One with no frame for `speechSilence`, counted from when the
    /// audio received so far should have been heard, is treated as cancelled; if its audio arrives after all,
    /// `.audio` brings it back (see `streamingSpeech`), so it never plays with the mic open.
    private func watchSpeech() {
        guard speechWatch == nil else { return }
        speechWatch = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard !self.speechHeard.isEmpty else {
                    self.speechWatch = nil
                    return
                }
                self.dropSilentSpeech()
            }
        }
    }

    private func dropSilentSpeech() {
        let now = Date()
        let silent = speechHeard.filter { _, heard in
            max(heard, audioUntil ?? heard).addingTimeInterval(Self.speechSilence) < now
        }.keys
        guard !silent.isEmpty else { return }
        // Everything received has been heard by now, so this only clears what the player still holds.
        dropQueuedAudio()
        silent.forEach(finishSpeech)
    }

    // MARK: Audio

    private func audioEvent(_ event: CallAudio.Event) {
        switch event {
        case .running:
            audioNote = nil
            // A rebuilt engine may tap the mic in a new format.
            if audioStarts > 0 { speech?.audioRestarted() }
            audioStarts += 1
            sendAnswer()
            if !speakerChosen {
                // Once per call: start on the loudspeaker unless a headset or car already has the call.
                speakerChosen = true
                if speakerOn, CallAudio.outputIsReceiver { try? CallAudio.setSpeaker(true) }
            }
            speakerOn = CallAudio.outputIsSpeaker
        case .interrupted:
            audioNote = "Call audio interrupted…"
        case .routeChanged:
            if audioStarts > 0 { speakerOn = CallAudio.outputIsSpeaker }
        case let .failed(error):
            fail("Lost the call audio: \(error.localizedDescription)")
        }
    }

    private func refreshNote() {
        statusNote = audioNote ?? linkNote ?? speechNote
    }
}
