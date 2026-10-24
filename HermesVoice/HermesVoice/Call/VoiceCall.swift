import AVFoundation
import Combine
import Foundation

/// A voice call inside one chat. Starting it announces the call to Hermes; the user's speech is
/// posted as "[Voice] …" messages; Hermes is heard only when it calls the `speak` tool.
@MainActor
final class VoiceCall: ObservableObject, Identifiable {
    enum State: Equatable { case connecting, live, ended(String?) }

    @Published private(set) var state: State = .connecting
    @Published private(set) var hermesSpeaking = false
    @Published private(set) var muted = false
    @Published private(set) var hearing = ""
    @Published private(set) var lastSpoken = ""
    @Published private(set) var speakerOn = true
    /// A notice shown under the call status (reconnecting, audio interrupted, speech recognition trouble).
    @Published private(set) var statusNote: String?

    let uuid = UUID()
    /// 32 lowercase hex characters; it appears only in the announcement to Hermes.
    let callID: String
    let chat: ChatModel
    let settings: ConnectionSettings
    /// The call can't go on; CallController hangs up the CallKit side.
    var onGiveUp: ((String) -> Void)?
    /// Hermes accepted the announcement and the voice server is connected.
    var onConnected: (() -> Void)?
    /// Whether hanging up posts "[Voice call ended]" to Hermes (not after signing out).
    var notifiesHermes = true

    private let audio: CallAudio
    private let listener: SpeechListener
    private var link: VoiceLink?
    private var began = false
    private var announced = false
    private var announcing = false
    private var reconnects = 0
    private var reconnectTask: Task<Void, Never>?
    /// Seconds before each reconnect attempt; the first ones land inside the server's 6 s grace for a drop.
    private static let reconnectDelays: [Double] = [0.5, 1, 2, 4, 8, 8]
    /// Utterances started by the server and not yet heard (or cancelled).
    private var pendingSpeech: Set<String> = []
    /// Pending utterances whose audio has all arrived (a normal speech_end), waiting to be played back.
    private var completeSpeech: Set<String> = []
    /// Pending utterances still streaming (no speech_end yet), with when the server last sent anything for them
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
    /// The announcement is waiting in Hermes' queue behind a running turn, so voice prompts queue behind it
    /// instead of steering a turn that hasn't seen the call_id yet. Cleared once that turn is over.
    private var voiceQueued = false
    private var idleWatch: AnyCancellable?
    /// Bumped when queued speech is dropped wholesale, so played-back callbacks from before are ignored.
    private var speechGeneration = 0
    /// The last few utterances confirmed as heard. Their `played` is sent again after a reconnect, in case
    /// it went out on a socket that was already dead; the server ignores ids it isn't waiting for.
    private var recentlyPlayed: [String] = []
    private var audioStarts = 0
    private var speakerChosen = false
    private var audioNote: String? { didSet { refreshNote() } }
    private var linkNote: String? { didSet { refreshNote() } }
    private var speechNote: String? { didSet { refreshNote() } }

    init(chat: ChatModel, settings: ConnectionSettings) {
        self.chat = chat
        self.settings = settings
        callID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        audio = CallAudio()
        listener = SpeechListener(localeIdentifier: settings.speechLocale)
        audio.onEvent = { [weak self] event in self?.audioEvent(event) }
        listener.onUtterance = { [weak self] text in self?.userSaid(text) }
        listener.onPartial = { [weak self] text in self?.hearing = text }
        listener.onStatus = { [weak self] note in self?.speechNote = note }
    }

    private var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// CallKit activated the audio session: start the mic and speaker. The first time it also
    /// connects the call; later activations (after an interruption) only bring the audio back.
    func audioDidActivate() {
        if isEnded { return }
        if !began {
            began = true
            chat.setInUse(useKey, true)
            updateListening()
            if CallAudio.usesMicrophone {
                listener.start()
            } else {
                speechNote = "Simulator: no microphone. Hermes can be heard; type [Voice] messages to talk."
            }
            Task { await connect() }
        }
        audio.start { [listener] buffer in listener.append(buffer) }
    }

    /// CallKit took the audio session away; the next `audioDidActivate` restarts it.
    func audioDidDeactivate() {
        if isEnded { return }
        audio.suspend()
        audioNote = "Call audio paused by iOS…"
    }

    func setMuted(_ value: Bool) {
        muted = value
        updateListening()
    }

    func toggleSpeaker() {
        guard audioStarts > 0 else { return speakerOn.toggle() }
        try? CallAudio.setSpeaker(!CallAudio.outputIsSpeaker)
        speakerOn = CallAudio.outputIsSpeaker
    }

    /// Hang-up from either side; tells Hermes the call is over.
    func stop(reason: String? = nil) {
        if isEnded { return }
        state = .ended(reason)
        speechGeneration += 1
        reconnectTask?.cancel()
        listener.stop()
        audio.stop()
        link?.close()
        link = nil
        pendingSpeech.removeAll()
        completeSpeech.removeAll()
        speechHeard.removeAll()
        streamingSpeech = nil
        speechWatch?.cancel()
        speechWatch = nil
        audioUntil = nil
        idleWatch = nil
        hermesSpeaking = false
        hearing = ""
        audioNote = nil
        linkNote = nil
        speechNote = nil
        // An announcement still in flight finishes this itself once it knows whether Hermes got it.
        if began, !announcing { finishWithHermes() }
    }

    /// This call's hold on the chat. Each call has its own, so a late release from an earlier call in the same
    /// chat (its end notice can take a while) can't end a newer call's hold.
    private var useKey: String { "call-\(callID)" }

    /// Ends the call's hold on the chat, first telling Hermes the call is over if it knew about it.
    private func finishWithHermes() {
        let notice = announced && notifiesHermes ? endNotice : nil
        let chat = chat, key = useKey
        Task {
            // Queued, so it never cuts into a turn that is still working; dropped if Hermes won't take it.
            if let notice { await chat.send(notice, queued: true) }
            chat.setInUse(key, false)
        }
    }

    /// Resumes the chat on the gateway first, so the hello carries its stored session id.
    private func connect() async {
        for attempt in 0..<3 {
            do {
                try await chat.ensureAttached()
                break
            } catch {
                if isEnded { return }
                if attempt == 2 { return giveUp("Couldn't open this chat in Hermes: \(error.localizedDescription)") }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        if isEnded { return }
        openLink()
    }

    private func openLink() {
        guard let base = settings.voiceBase else {
            return giveUp("Add the Hermes Voice server in Settings.")
        }
        link?.close(sendBye: false)
        let link = VoiceLink(base: base, token: settings.voiceToken, callID: callID, sessionID: chat.storedID, title: chat.title)
        // Only the current link counts: a replaced one can't trigger reconnects or play speech.
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link, self.link === link else { return }
            self.handle(message)
        }
        self.link = link
        link.connect()
    }

    private func handle(_ message: VoiceLink.Incoming) {
        switch message {
        case .ready:
            reconnects = 0
            linkNote = nil
            recentlyPlayed.forEach { link?.played($0) }
            announce()
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
            updateListening()
            watchSpeech()
        case let .audio(data):
            let now = Date()
            if let id = streamingSpeech, !pendingSpeech.contains(id) {
                // `watchSpeech` gave up on this utterance, but its audio came after all (a slow first byte from the
                // voice service, or a stalled link catching up): pause the mic again and wait for its speech_end.
                pendingSpeech.insert(id)
                speechHeard[id] = now
                hermesSpeaking = true
                updateListening()
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
            audio.whenPlayedBack { [weak self] in
                guard let self, generation == self.speechGeneration else { return }
                // Acked on whichever link is up now (the server carries pending acks across reconnects);
                // the next `ready` repeats it in case it is lost with a dying socket or sent while none is up.
                self.link?.played(id)
                self.recentlyPlayed = Array((self.recentlyPlayed + [id]).suffix(4))
                self.finishSpeech(id)
            }
        case let .closed(reason, _):
            link = nil
            // Audio on the next link follows a fresh speech_start.
            streamingSpeech = nil
            // Utterances that fully arrived play out with the mic still paused and are acked on the next link.
            // One cut off mid-stream would never get its played-back marker here (the server carries on with it
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
                giveUp("Wrong voice server token: the Hermes Voice server rejected it. Check the token in Settings.")
            case .badHello:
                giveUp("The Hermes Voice server didn't accept the call.")
            case .replaced:
                giveUp("Another connection took over this call.")
            case .dropped:
                scheduleReconnect()
            }
        }
    }

    /// Keeps the call up across short network drops (Tailscale switching paths, etc).
    private func scheduleReconnect() {
        reconnects += 1
        guard reconnects <= Self.reconnectDelays.count else { return giveUp("Lost the Hermes Voice server.") }
        linkNote = "Reconnecting to the voice server…"
        let delay = Self.reconnectDelays[reconnects - 1]
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isEnded else { return }
            self.openLink()
        }
    }

    /// Tells Hermes about the call on the first `ready`, retrying with backoff; the call goes live
    /// (and the mic opens) only once Hermes has the call_id and the speak-only rules.
    private func announce() {
        if announced {
            state = .live
            return
        }
        guard !announcing else { return }
        announcing = true
        let text = announcement
        Task {
            var delivered = false
            for attempt in 0..<3 where !isEnded {
                if attempt > 0 {
                    linkNote = "Hermes didn't get the call yet. Retrying…"
                    try? await Task.sleep(nanoseconds: UInt64(2 << attempt) * 500_000_000)
                    if isEnded { break }
                }
                if chat.busy { holdVoiceWhileBusy() }
                if await chat.send(text, queued: true) {
                    delivered = true
                    break
                }
            }
            announcing = false
            announced = delivered
            if isEnded { return finishWithHermes() }
            linkNote = nil
            guard delivered else {
                return giveUp("Couldn't tell Hermes about the call, so it wouldn't know to answer out loud. Check the connection to the Hermes dashboard.")
            }
            state = .live
            updateListening()
            onConnected?()
        }
    }

    /// Hermes is mid-turn, so the announcement waits in its queue: voice prompts are queued too (behind it, in
    /// order) until that turn is over, so they can't steer it before Hermes knows about the call.
    private func holdVoiceWhileBusy() {
        guard idleWatch == nil else { return }
        voiceQueued = true
        idleWatch = chat.$busy.dropFirst().sink { [weak self] busy in
            guard !busy, let self else { return }
            self.voiceQueued = false
            self.idleWatch = nil
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

    /// Drops streaming utterances the server has gone quiet on. Their final cancelled/error speech_end can be lost
    /// while the socket stays up (the server gives up on a send stuck behind a full buffer), which would otherwise
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

    private func audioEvent(_ event: CallAudio.Event) {
        switch event {
        case .running:
            audioNote = nil
            // A rebuilt engine may tap the mic in a new format; recognition starts a fresh request.
            if audioStarts > 0 { listener.restart() }
            audioStarts += 1
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
            giveUp("Lost the call audio: \(error.localizedDescription)")
        }
    }

    /// The call can't go on; CallController hangs up the CallKit side.
    private func giveUp(_ reason: String) {
        if isEnded { return }
        stop(reason: reason)
        onGiveUp?(reason)
    }

    private func updateListening() {
        listener.setPaused(muted || hermesSpeaking || state != .live)
    }

    private func refreshNote() {
        statusNote = audioNote ?? linkNote ?? speechNote
    }

    private func userSaid(_ text: String) {
        guard case .live = state else { return }
        let queued = voiceQueued
        Task { await chat.send("[Voice] \(text)", queued: queued) }
    }

    private var announcement: String {
        """
        [Voice call started] call_id: \(callID)
        I started a voice call in this conversation from the Hermes Voice app. While the call is on, your text replies are NOT read aloud: \
        the only way I hear you is the mcp__hermes_voice__speak tool, which plays your words in an ElevenLabs voice. \
        Every speak call must pass call_id "\(callID)". \
        What I say arrives as messages starting with "[Voice]". Answer those out loud with speak, short and conversational like a phone call \
        (no Markdown, lists, code or links), and put any detail in your text reply. Say a short hello with speak now.
        """
    }

    private var endNotice: String {
        "[Voice call ended] call_id: \(callID). The voice call is over, so stop using the speak tool. "
            + "Carry on with any work in progress and reply in text as usual."
    }
}
