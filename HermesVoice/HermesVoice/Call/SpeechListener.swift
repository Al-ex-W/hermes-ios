import AVFoundation
import Speech

/// Turns what the user says into utterances: Apple speech recognition (on-device when the language
/// has a model on the iPhone), ended by a short pause. AppleSpeechProvider makes them user turns.
final class SpeechListener: NSObject, SFSpeechRecognizerDelegate {
    /// One finished utterance.
    struct Utterance {
        let text: String
        let startedAt: Date
        let endedAt: Date
        /// How it ended: "apple_silence" (the pause), "apple_final" (the recognizer finished the request).
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
    private var heard = ""
    /// When the words in `heard` began.
    private var heardSince: Date?
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
    init(localeIdentifier: String?, pause: TimeInterval = 1.2) {
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
    }

    /// Starts over with a fresh request (the microphone format may have changed); half-heard words are dropped.
    func restart() {
        guard running, !paused else { return }
        beginRequest()
    }

    /// Ends the utterance in progress now (Hermes cut in, or the call is ending) and returns it, or nil when
    /// nothing was heard. Listening goes on with a fresh request.
    func takePartial() -> Utterance? {
        let since = heardSince
        let text = takeHeard()
        guard !text.isEmpty else { return nil }
        if running, !paused { beginRequest() }
        return Utterance(text: text, startedAt: since ?? Date(), endedAt: Date(), detector: "", error: nil)
    }

    /// While paused (Hermes is speaking, or the call is muted) audio is dropped and any half-heard words discarded.
    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        guard running else { return }
        if value {
            cancelRetry()
            endRequest()
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
            self.beginRequest()
        }
    }

    // MARK: Requests

    private func beginRequest() {
        endRequest()
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
                    let text = result.bestTranscription.formattedString
                    if text != self.heard {
                        if self.heard.isEmpty, !text.isEmpty { self.heardSince = Date() }
                        self.heard = text
                        self.onPartial?(text)
                        self.armSilenceTimer()
                    }
                    if result.isFinal { self.finishUtterance(detector: "apple_final") }
                } else if let error {
                    self.recognitionFailed(error)
                }
            }
        }
    }

    private func endRequest() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
        heardSince = nil
        if !heard.isEmpty {
            heard = ""
            onPartial?("")
        }
    }

    /// Recognition gave up. A request that heard something or ran a while (no speech, the server's time
    /// limit) just starts over; one that fails straight away backs off, so a persistent error can't spin.
    private func recognitionFailed(_ error: Error) {
        let since = heardSince
        let text = takeHeard()
        if requestHeardSomething || Date().timeIntervalSince(requestStarted) >= 3 {
            failures = 0
            beginRequest()
        } else {
            failures += 1
            lastError = error.localizedDescription
            endRequest()
            scheduleRetry(after: min(4, 0.5 * pow(2, Double(failures - 1))))
        }
        updateStatus()
        if !text.isEmpty {
            onUtterance?(Utterance(text: text, startedAt: since ?? Date(), endedAt: Date(), detector: "apple_error",
                                   error: error.localizedDescription))
        }
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: pause, repeats: false) { [weak self] _ in
            self?.finishUtterance(detector: "apple_silence")
        }
    }

    private func finishUtterance(detector: String) {
        let since = heardSince
        let text = takeHeard()
        beginRequest()
        if !text.isEmpty {
            onUtterance?(Utterance(text: text, startedAt: since ?? Date(), endedAt: Date(), detector: detector, error: nil))
        }
    }

    /// The words heard so far, cleared from the screen.
    private func takeHeard() -> String {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        heardSince = nil
        if !heard.isEmpty {
            heard = ""
            onPartial?("")
        }
        return text
    }

    private func scheduleRetry(after delay: TimeInterval) {
        cancelRetry()
        let work = DispatchWorkItem { [weak self] in
            self?.retry = nil
            self?.beginRequest()
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
