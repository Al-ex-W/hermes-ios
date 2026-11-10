import AVFoundation
import Speech

/// Turns what the user says into utterances: Apple speech recognition (on-device when the language
/// has a model on the iPhone), ended by a pause of `pause` seconds. AppleSpeechProvider makes them user turns.
///
/// Only that pause ends an utterance (or a flush: Send now, Hermes cutting in, mute, hang-up). The recognizer's own
/// segment ends, and a request that finishes by itself, don't: AppleUtteranceAssembler keeps what was heard, and
/// listening goes on with a fresh request while the pause keeps counting.
final class SpeechListener: NSObject, SFSpeechRecognizerDelegate {
    /// One finished utterance.
    struct Utterance {
        let text: String
        let startedAt: Date
        let endedAt: Date
        /// How it ended: "apple_silence" (the pause), "apple_error" (recognition failed mid-sentence), "" (flushed).
        let detector: String
        /// Recognition failed with words heard: they are passed on, with the error.
        let error: String?
    }

    /// Called on the main queue with each finished utterance.
    var onUtterance: ((Utterance) -> Void)?
    /// Called on the main queue with the words heard so far ("" once they are sent or dropped).
    var onPartial: ((String) -> Void)?
    /// Called on the main queue with a notice for the user (recognition unavailable, using Apple's
    /// servers, failing), or nil when there is nothing to say.
    var onStatus: ((String?) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let languageName: String
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// The utterance in progress, across the recognizer's segments and requests.
    private var utterance = AppleUtteranceAssembler()
    /// Fires when `pause` has passed since the utterance's words last changed.
    private var silenceTimer: Timer?
    private var retry: DispatchWorkItem?
    private var requestStarted = Date()
    private var requestHeardSomething = false
    /// Requests in a row that failed soon after starting.
    private var failures = 0
    private var lastError: String?
    /// Attempts in a row that found the recognizer unavailable.
    private var waits = 0
    private var usesServer = false
    private var status: String?
    private var paused = false
    private var running = false
    /// Silence that ends an utterance.
    let pause: TimeInterval
    /// The locale recognition runs in.
    let localeIdentifier: String

    /// `localeIdentifier` nil or "" picks the language automatically from the user's preferred languages.
    init(localeIdentifier: String?, pause: TimeInterval = EndOfSpeech.normal.pause) {
        self.pause = pause
        var locale = Self.automaticLocale()
        if let localeIdentifier, !localeIdentifier.isEmpty, SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) != nil {
            locale = Locale(identifier: localeIdentifier)
        }
        recognizer = SFSpeechRecognizer(locale: locale)
        self.localeIdentifier = locale.identifier
        languageName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        usesServer = recognizer?.supportsOnDeviceRecognition == false
        super.init()
        recognizer?.delegate = self
    }

    /// Every language Apple's recognizer supports, for the Settings picker.
    static func supportedLocaleIdentifiers() -> [String] {
        SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
    }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }

    func start() {
        running = true
        beginRequest()
        updateStatus()
    }

    func stop() {
        running = false
        cancelRetry()
        endRequest()
        dropUtterance()
    }

    /// Starts over with a fresh request (the microphone format may have changed). What was heard so far stays.
    func restart() {
        guard running, !paused else { return }
        beginRequest(keepingUtterance: true)
    }

    /// Ends the utterance in progress now (Hermes cut in, the user tapped Send now, or the call is ending) and
    /// returns it, or nil when nothing was heard. Listening goes on with a fresh request.
    func takePartial() -> Utterance? {
        guard let taken = takeUtterance() else { return nil }
        if running, !paused { beginRequest() }
        return Utterance(text: taken.text, startedAt: taken.startedAt, endedAt: Date(), detector: "", error: nil)
    }

    /// While paused (Hermes is speaking, or the call is muted) audio is dropped and any half-heard words discarded.
    /// The pause that ends an utterance isn't counted meanwhile: its timer stops here, and starts again only with
    /// the first words heard after listening resumes.
    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        guard running else { return }
        if value {
            cancelRetry()
            endRequest()
            dropUtterance()
        } else {
            beginRequest()
        }
    }

    /// From the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, available, self.running, !self.paused, self.request == nil else { return }
            self.beginRequest(keepingUtterance: true)
        }
    }

    // MARK: Requests

    /// Starts a fresh recognition request. `keepingUtterance`: what was heard so far stays in the utterance (the
    /// request before finished or failed under it) and its pause keeps counting; otherwise the utterance is dropped.
    private func beginRequest(keepingUtterance: Bool = false) {
        endRequest()
        if keepingUtterance {
            // The new request starts from nothing: what the old one heard is a finished segment.
            utterance.requestEnded()
        } else {
            dropUtterance()
        }
        cancelRetry()
        guard running, !paused, let recognizer else { return }
        let onDevice = recognizer.supportsOnDeviceRecognition
        // An on-device model works offline even while the recognizer reports itself unavailable.
        guard recognizer.isAvailable || onDevice else {
            waits += 1
            updateStatus()
            return scheduleRetry(after: min(10, pow(2, Double(waits - 1))))
        }
        waits = 0
        usesServer = !onDevice
        updateStatus()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = onDevice
        lock.lock()
        self.request = request
        lock.unlock()
        requestStarted = Date()
        requestHeardSomething = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.request === request else { return }
                if let result {
                    self.requestHeardSomething = true
                    if self.failures > 0 {
                        self.failures = 0
                        self.updateStatus()
                    }
                    self.heard(result.bestTranscription.formattedString, closesSegment: result.speechRecognitionMetadata != nil)
                    // The request finished by itself (the recognizer's own end of speech, or the one-minute limit
                    // of Apple's servers). That doesn't end the utterance: the pause does.
                    if result.isFinal { self.beginRequest(keepingUtterance: true) }
                } else if let error {
                    self.recognitionFailed(error)
                }
            }
        }
    }

    /// A result of the current request: the recognizer's text for its open segment.
    private func heard(_ text: String, closesSegment: Bool) {
        let wordsAt = utterance.lastWordsAt
        if utterance.result(text, closesSegment: closesSegment, at: Date()) { onPartial?(utterance.text) }
        // The pause counts from the last new words, not from the recognizer tidying up a segment it closes.
        if utterance.lastWordsAt != wordsAt { armSilenceTimer() }
    }

    /// Ends the recognition request. The utterance in progress, and its pause, are untouched.
    private func endRequest() {
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
    }

    /// Recognition gave up. A request that heard something or ran a while (no speech, the server's time
    /// limit) just starts over; one that fails straight away backs off, so a persistent error can't spin.
    /// Words the failed request was still working on are passed on at once, with the error and everything heard
    /// before them. A request that failed with no words of its own (no speech in it, say, while the user pauses)
    /// leaves the utterance as it is: its pause ends it.
    private func recognitionFailed(_ error: Error) {
        let taken = utterance.current.isEmpty ? nil : takeUtterance()
        if requestHeardSomething || Date().timeIntervalSince(requestStarted) >= 3 {
            failures = 0
            beginRequest(keepingUtterance: true)
        } else {
            failures += 1
            lastError = error.localizedDescription
            endRequest()
            scheduleRetry(after: min(4, 0.5 * pow(2, Double(failures - 1))))
        }
        updateStatus()
        if let taken {
            onUtterance?(Utterance(text: taken.text, startedAt: taken.startedAt, endedAt: Date(), detector: "apple_error",
                                   error: error.localizedDescription))
        }
    }

    /// (Re)starts the timer for `pause` after the utterance's words last changed.
    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard let due = utterance.silenceDue(pause: pause) else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: max(0, due.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            self?.finishUtterance(detector: "apple_silence")
        }
    }

    private func finishUtterance(detector: String) {
        let taken = takeUtterance()
        beginRequest()
        if let taken {
            onUtterance?(Utterance(text: taken.text, startedAt: taken.startedAt, endedAt: Date(), detector: detector, error: nil))
        }
    }

    /// Ends the utterance in progress: its words, cleared from the screen, or nil when nothing was heard.
    private func takeUtterance() -> (text: String, startedAt: Date)? {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard let taken = utterance.take() else { return nil }
        onPartial?("")
        return (taken.text, taken.startedAt ?? Date())
    }

    /// Drops the utterance in progress and stops its pause.
    private func dropUtterance() {
        _ = takeUtterance()
    }

    private func scheduleRetry(after delay: TimeInterval) {
        cancelRetry()
        let work = DispatchWorkItem { [weak self] in
            self?.retry = nil
            // What was heard before the recognizer went away waits for its pause.
            self?.beginRequest(keepingUtterance: true)
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }

    private func updateStatus() {
        let next: String?
        if recognizer == nil {
            next = "Speech recognition doesn't support \(languageName)."
        } else if waits > 0 {
            next = "Speech recognition is unavailable right now. Retrying…"
        } else if failures >= 3 {
            next = "Speech recognition keeps failing\(lastError.map { " (\($0))" } ?? ""). Retrying…"
        } else if usesServer {
            next = "On-device speech recognition for \(languageName) isn't available on this iPhone, so Apple's servers transcribe the call."
        } else {
            next = nil
        }
        guard next != status else { return }
        status = next
        onStatus?(next)
    }

    // MARK: Language

    /// The first of the user's preferred languages Apple's recognizer supports, then the app's own
    /// locale. Within a language an on-device locale wins, so audio stays on the iPhone. (The app ships
    /// only English, so `Locale.current` alone would hear Swedish speech as English.)
    static func automaticLocale(preferredLanguages: [String] = Locale.preferredLanguages, current: Locale = .current) -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        for wanted in preferredLanguages.map(Locale.init(identifier:)) + [current] {
            let candidates = matches(for: wanted, current: current, supported: supported)
            if let match = candidates.first(where: { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }) ?? candidates.first {
                return match
            }
        }
        return current
    }

    /// Supported locales of the same language and script, best region first: the wanted one, the
    /// device's, then the language's home region (sv → sv-SE).
    private static func matches(for wanted: Locale, current: Locale, supported: Set<Locale>) -> [Locale] {
        guard let language = wanted.language.languageCode else { return [] }
        let script = maximal(wanted).script
        let candidates = supported
            .filter { candidate in
                candidate.language.languageCode == language
                    && (script == nil || maximal(candidate).script == nil || maximal(candidate).script == script)
            }
            .sorted { $0.identifier < $1.identifier }
        let home = Locale(identifier: script.map { "\(language.identifier)-\($0.identifier)" } ?? language.identifier)
        var ordered: [Locale] = []
        for region in [wanted.region, current.region, maximal(home).region].compactMap({ $0 }) + [nil] {
            for candidate in candidates where (region == nil || candidate.region == region) && !ordered.contains(candidate) {
                ordered.append(candidate)
            }
        }
        return ordered
    }

    private static func maximal(_ locale: Locale) -> Locale.Language {
        Locale.Language(identifier: locale.language.maximalIdentifier)
    }
}
