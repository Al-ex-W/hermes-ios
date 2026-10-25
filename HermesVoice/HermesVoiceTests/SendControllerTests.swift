import XCTest
@testable import HermesVoice

/// A chat that records what the send decision tree asked of it.
@MainActor
private class FakeChat: ChatSending {
    var runtimeSessionID: String? = "r1"
    var isBusy = false
    var hasPendingClarify = false
    var hasBlockingPrompt = false
    var redirectOutcome: RedirectOutcome = .redirected
    var acceptsSubmit = true
    var slashRuns = true
    var stageError: Error?
    /// A turn starts when a prompt is accepted.
    var busyAfterSubmit = true
    /// Runs as a redirect is answered (the turn ending meanwhile).
    var onRedirect: (() -> Void)?
    private(set) var log: [String] = []
    private(set) var submitted: [(text: String, attachments: [StagedAttachment], queued: Bool, display: String?)] = []
    private(set) var unstaged: [StagedAttachment] = []
    private var stagings = 0

    func skipPendingClarify() async {
        log.append("skip")
        hasPendingClarify = false
    }

    func submit(_ text: String, attachments: [StagedAttachment], queued: Bool, display: String?) async -> Bool {
        log.append("submit:\(text)")
        submitted.append((text, attachments, queued, display))
        if acceptsSubmit, busyAfterSubmit { isBusy = true }
        return acceptsSubmit
    }

    func redirect(_ text: String) async -> RedirectOutcome {
        log.append("redirect:\(text)")
        onRedirect?()
        return redirectOutcome
    }

    func interrupt() async {
        log.append("interrupt")
    }

    func runSlash(_ command: String) async -> Bool {
        log.append("slash:\(command)")
        return slashRuns
    }

    func stage(_ attachment: PendingAttachment) async throws -> StagedAttachment {
        log.append("stage:\(attachment.filename)")
        if let stageError { throw stageError }
        stagings += 1
        return StagedAttachment(kind: attachment.isImage ? .image : .file, name: attachment.filename,
                                refText: attachment.isImage ? nil : "@file:\(attachment.filename)",
                                path: "/staged/\(stagings)-\(attachment.filename)", sessionID: runtimeSessionID)
    }

    func unstage(_ staged: StagedAttachment) async {
        log.append("unstage:\(staged.name)")
        unstaged.append(staged)
    }
}

/// The same chat, published, so the controller drains on its own when the turn settles.
@MainActor
private final class ObservableFakeChat: FakeChat, ObservableObject {
    override var isBusy: Bool {
        willSet { objectWillChange.send() }
    }
}

@MainActor
final class SendControllerTests: XCTestCase {
    private var chat: FakeChat!
    private var sender: SendController!

    override func setUp() async throws {
        chat = FakeChat()
        sender = SendController(chat: chat, retryDelay: 0.01)
    }

    override func tearDown() async throws {
        sender = nil
        chat = nil
    }

    private let photo = ComposerAttachment(pending: .image(Data([1, 2, 3]), filename: "photo.jpg"))
    private let notes = ComposerAttachment(pending: .file(Data("notes".utf8), filename: "notes.txt", mime: "text/plain"))

    /// Waits for spawned drain tasks.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: Ownership

    func testAControllerItsChatOwnsDoesntKeepTheChat() async {
        var owner: FakeChat? = FakeChat()
        let sender = SendController(chat: owner!, ownedByChat: true)
        XCTAssertTrue(sender.chat === owner)
        weak let released = owner
        owner = nil
        XCTAssertNil(released)
        let result = await sender.send("hello")
        XCTAssertEqual(result, .kept, "with the chat gone nothing is sent")
    }

    // MARK: Idle

    func testIdleSubmits() async {
        let result = await sender.send("hello")
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(chat.log, ["submit:hello"])
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testIdleStagesAttachmentsBeforeSubmitting() async {
        let result = await sender.send("look", attachments: [photo, notes])
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(chat.log, ["stage:photo.jpg", "stage:notes.txt", "submit:look"])
        let staged = chat.submitted.first?.attachments ?? []
        XCTAssertEqual(staged.map(\.kind), [.image, .file])
        XCTAssertEqual(StagedAttachment.promptText("look", staged), "@file:notes.txt\n\nlook")
    }

    func testFailedStagingKeepsTheDraft() async {
        chat.stageError = AttachmentError(message: "too large")
        let result = await sender.send("look", attachments: [photo])
        XCTAssertEqual(result, .kept)
        XCTAssertEqual(chat.log, ["stage:photo.jpg"])
        XCTAssertEqual(sender.notice, "too large")
    }

    func testRefusedSubmitKeepsTheDraft() async {
        chat.acceptsSubmit = false
        let result = await sender.send("hello")
        XCTAssertEqual(result, .kept)
        XCTAssertFalse(result.consumesDraft)
    }

    func testIdleSlashRuns() async {
        let result = await sender.send("/status")
        XCTAssertEqual(result, .ranSlash)
        XCTAssertEqual(chat.log, ["slash:/status"])
    }

    func testFailedSlashKeepsTheDraft() async {
        chat.slashRuns = false
        let result = await sender.send("/status")
        XCTAssertEqual(result, .kept)
    }

    func testSlashWithAttachmentsIsRefused() async {
        let result = await sender.send("/status", attachments: [photo])
        XCTAssertEqual(result, .kept)
        XCTAssertTrue(chat.log.isEmpty)
        XCTAssertEqual(sender.notice, SendController.slashWithAttachments)
    }

    func testEmptyIdleSendWithoutQueueDoesNothing() async {
        let result = await sender.send("   ")
        XCTAssertEqual(result, .kept)
        XCTAssertTrue(chat.log.isEmpty)
    }

    // MARK: Pending clarify

    func testPendingClarifyIsSkippedBeforeSubmitting() async {
        chat.hasPendingClarify = true
        let result = await sender.send("neither")
        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(chat.log, ["skip", "submit:neither"])
    }

    func testPendingClarifyIsSkippedBeforeRedirecting() async {
        chat.isBusy = true
        chat.hasPendingClarify = true
        let result = await sender.send("use the other file")
        XCTAssertEqual(result, .redirected)
        XCTAssertEqual(chat.log, ["skip", "redirect:use the other file"])
    }

    func testSideQuestionLeavesTheClarifyAlone() async {
        chat.isBusy = true
        chat.hasPendingClarify = true
        let result = await sender.send("/btw what is this?")
        XCTAssertEqual(result, .ranSlash)
        XCTAssertEqual(chat.log, ["slash:/btw what is this?"])
        XCTAssertTrue(chat.hasPendingClarify)
    }

    func testEmptySendLeavesTheClarifyAlone() async {
        chat.isBusy = true
        chat.hasPendingClarify = true
        let result = await sender.send("")
        XCTAssertEqual(result, .interrupted)
        XCTAssertEqual(chat.log, ["interrupt"])
    }

    // MARK: Busy

    func testBusySlashRunsNow() async {
        chat.isBusy = true
        let result = await sender.send("/compress")
        XCTAssertEqual(result, .ranSlash)
        XCTAssertEqual(chat.log, ["slash:/compress"])
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testBusySlashWithAttachmentsIsRefused() async {
        chat.isBusy = true
        let result = await sender.send("/compress", attachments: [notes])
        XCTAssertEqual(result, .kept)
        XCTAssertTrue(chat.log.isEmpty)
        XCTAssertTrue(sender.queue.isEmpty)
        XCTAssertEqual(sender.notice, SendController.slashWithAttachments)
    }

    func testBusyTextRedirects() async {
        chat.isBusy = true
        let result = await sender.send("actually, stop at step 2")
        XCTAssertEqual(result, .redirected)
        XCTAssertEqual(chat.log, ["redirect:actually, stop at step 2"])
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testRedirectHeldByHermesIsDone() async {
        chat.isBusy = true
        chat.redirectOutcome = .queued
        let result = await sender.send("also check tests")
        XCTAssertEqual(result, .redirected)
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testRejectedRedirectJoinsTheQueue() async {
        chat.isBusy = true
        chat.redirectOutcome = .rejected
        let result = await sender.send("next thing")
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(sender.queue.map(\.text), ["next thing"])
        XCTAssertEqual(chat.log, ["redirect:next thing"])

        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log, ["redirect:next thing", "submit:next thing"])
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testFailedRedirectJoinsTheQueue() async {
        chat.isBusy = true
        chat.redirectOutcome = .failed
        let result = await sender.send("next thing")
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(sender.queue.map(\.text), ["next thing"])
    }

    func testRedirectRejectedBecauseTheTurnEndedIsSentAtOnce() async {
        chat.isBusy = true
        chat.redirectOutcome = .rejected
        let chat = self.chat!
        chat.onRedirect = { [unowned chat] in chat.isBusy = false }
        let result = await sender.send("next thing")
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(chat.log, ["redirect:next thing", "submit:next thing"])
        XCTAssertEqual(chat.submitted.map(\.queued), [true], "a turn still settling runs it next, never as a correction")
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testBusyAttachmentsQueue() async {
        chat.isBusy = true
        let result = await sender.send("see this", attachments: [photo])
        XCTAssertEqual(result, .queued)
        XCTAssertTrue(chat.log.isEmpty)
        XCTAssertEqual(sender.queue.first?.attachments, [photo])
    }

    func testBusyAttachmentWithoutTextQueues() async {
        chat.isBusy = true
        let result = await sender.send("", attachments: [notes])
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(sender.queue.count, 1)
    }

    func testBlockingPromptQueuesText() async {
        chat.isBusy = true
        chat.hasBlockingPrompt = true
        let result = await sender.send("after that, run the tests")
        XCTAssertEqual(result, .queued)
        XCTAssertTrue(chat.log.isEmpty)
        XCTAssertEqual(sender.queue.map(\.text), ["after that, run the tests"])
    }

    func testBlockingPromptStillRunsSlash() async {
        chat.isBusy = true
        chat.hasBlockingPrompt = true
        let result = await sender.send("/status")
        XCTAssertEqual(result, .ranSlash)
    }

    func testEmptyBusySendInterrupts() async {
        chat.isBusy = true
        let result = await sender.send("")
        XCTAssertEqual(result, .interrupted)
        XCTAssertEqual(chat.log, ["interrupt"])
        XCTAssertFalse(sender.parked)
    }

    func testQueueButtonHoldsTheDraft() async {
        chat.isBusy = true
        XCTAssertEqual(sender.queueDraft("later"), .queued)
        XCTAssertEqual(sender.queue.map(\.text), ["later"])
        XCTAssertEqual(sender.queueDraft(" "), .kept)
        XCTAssertEqual(sender.queueDraft("/status", attachments: [photo]), .kept)
        chat.isBusy = false
        XCTAssertEqual(sender.queueDraft("now"), .kept)
        XCTAssertTrue(chat.log.isEmpty)
    }

    // MARK: Draining

    func testQueueDrainsOnePromptPerIdleTurn() async {
        chat.isBusy = true
        _ = await sender.send("one", attachments: [photo])
        _ = await sender.send("two", attachments: [notes])
        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log, ["stage:photo.jpg", "submit:one"])
        XCTAssertEqual(sender.queue.map(\.text), ["two"])
        XCTAssertTrue(chat.isBusy)

        await sender.drainIfIdle()
        XCTAssertEqual(sender.queue.count, 1)

        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log, ["stage:photo.jpg", "submit:one", "stage:notes.txt", "submit:two"])
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testDrainedPromptsGoOutQueuedAndDraftsDont() async {
        _ = await sender.send("now")
        chat.isBusy = true
        _ = sender.queueDraft("later")
        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.submitted.map(\.text), ["now", "later"])
        XCTAssertEqual(chat.submitted.map(\.queued), [false, true])
    }

    func testSendNowAndAQueuedSkillGoOutQueuedWithTheirDisplay() async {
        chat.isBusy = true
        _ = sender.queuePrompt("SKILL BODY", display: "/work fix it")
        _ = sender.queueDraft("plain")
        chat.isBusy = false
        await sender.sendNow(sender.queue[1].id)
        await sender.drainIfIdle()
        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.submitted.map(\.text), ["plain", "SKILL BODY"])
        XCTAssertEqual(chat.submitted.map(\.queued), [true, true])
        XCTAssertEqual(chat.submitted.map(\.display), [nil, "/work fix it"], "the bubble shows the invocation")
    }

    // MARK: Staged attachments

    func testAnAttachmentIsStagedOncePerSession() async {
        chat.acceptsSubmit = false
        _ = await sender.send("look", attachments: [photo])
        chat.acceptsSubmit = true
        _ = await sender.send("look", attachments: [photo])
        XCTAssertEqual(chat.log, ["stage:photo.jpg", "submit:look", "submit:look"], "a retry doesn't upload it again")
        XCTAssertEqual(chat.submitted.last?.attachments.first?.path, "/staged/1-photo.jpg")

        chat.isBusy = false
        _ = await sender.send("again", attachments: [photo])
        XCTAssertEqual(chat.log.suffix(2), ["stage:photo.jpg", "submit:again"], "a turn took it, so it is staged anew")
    }

    func testAnAttachmentIsStagedAgainOnANewSession() async {
        chat.acceptsSubmit = false
        _ = await sender.send("look", attachments: [photo])
        chat.runtimeSessionID = "r2"
        _ = await sender.send("look", attachments: [photo])
        XCTAssertEqual(chat.log, ["stage:photo.jpg", "submit:look", "stage:photo.jpg", "submit:look"])
    }

    func testARemovedAttachmentIsTakenBackOffTheSession() async {
        chat.acceptsSubmit = false
        _ = await sender.send("look", attachments: [photo, notes])
        await sender.discard(photo)
        await sender.discard(notes)
        XCTAssertEqual(chat.unstaged.map(\.path), ["/staged/1-photo.jpg"], "only an image is held apart from the prompt")
    }

    func testImagesStagedForAnotherPromptAreTakenBackBeforeSending() async {
        chat.acceptsSubmit = false
        _ = await sender.send("look", attachments: [photo])
        chat.acceptsSubmit = true
        _ = await sender.send("never mind, just text")
        XCTAssertEqual(chat.log, ["stage:photo.jpg", "submit:look", "unstage:photo.jpg", "submit:never mind, just text"])
    }

    func testRemovingAQueuedPromptTakesBackItsImage() async {
        chat.isBusy = true
        _ = await sender.send("see this", attachments: [photo])
        chat.isBusy = false
        chat.acceptsSubmit = false
        await sender.drainIfIdle()
        sender.remove(sender.queue[0].id)
        await waitUntil { !self.chat.unstaged.isEmpty }
        XCTAssertEqual(chat.unstaged.map(\.name), ["photo.jpg"])
    }

    func testQueuedSlashDrainsThroughSlash() async {
        chat.isBusy = true
        chat.hasBlockingPrompt = true
        _ = await sender.send("tell me more")
        XCTAssertEqual(sender.queueDraft("/usage"), .queued)
        chat.isBusy = false
        chat.hasBlockingPrompt = false
        chat.busyAfterSubmit = false
        await sender.drainIfIdle()
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log, ["submit:tell me more", "slash:/usage"])
    }

    func testEmptyIdleSendDrainsTheNextQueued() async {
        chat.isBusy = true
        _ = sender.queueDraft("queued one")
        await sender.stop()
        XCTAssertTrue(sender.parked)
        chat.isBusy = false
        let result = await sender.send("")
        XCTAssertEqual(result, .drained)
        XCTAssertEqual(chat.log, ["interrupt", "submit:queued one"])
        XCTAssertFalse(sender.parked)
    }

    func testStopParksTheQueue() async {
        chat.isBusy = true
        _ = sender.queueDraft("queued")
        let result = await sender.send("")
        XCTAssertEqual(result, .interrupted)
        XCTAssertTrue(sender.parked)

        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log, ["interrupt"])
        XCTAssertEqual(sender.queue.count, 1)

        await sender.resume()
        XCTAssertEqual(chat.log, ["interrupt", "submit:queued"])
        XCTAssertFalse(sender.parked)
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testQueueingAgainLiftsThePark() async {
        chat.isBusy = true
        _ = sender.queueDraft("first")
        await sender.stop()
        XCTAssertTrue(sender.parked)
        _ = sender.queueDraft("second")
        XCTAssertFalse(sender.parked)
    }

    func testRemovingTheLastQueuedLiftsThePark() async {
        chat.isBusy = true
        _ = sender.queueDraft("only")
        await sender.stop()
        sender.remove(sender.queue[0].id)
        XCTAssertTrue(sender.queue.isEmpty)
        XCTAssertFalse(sender.parked)
    }

    func testFailedDrainRetriesThenReportsStuck() async {
        chat.isBusy = true
        _ = sender.queueDraft("stubborn")
        chat.isBusy = false
        chat.acceptsSubmit = false
        await sender.drainIfIdle()
        await waitUntil { self.sender.notice != nil }
        XCTAssertEqual(sender.notice, SendController.queueStuck)
        XCTAssertEqual(chat.log.filter { $0 == "submit:stubborn" }.count, SendController.maxDrainAttempts)
        XCTAssertEqual(sender.queue.map(\.text), ["stubborn"])

        // Spent: no more automatic attempts.
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log.count, SendController.maxDrainAttempts)

        // A manual send is fresh intent.
        chat.acceptsSubmit = true
        await sender.sendNow(sender.queue[0].id)
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testSettledChatDrainsByItself() async {
        let chat = ObservableFakeChat()
        let sender = SendController(chat: chat, retryDelay: 0.01)
        chat.isBusy = true
        chat.redirectOutcome = .rejected
        _ = await sender.send("when you're done")
        XCTAssertEqual(sender.queue.count, 1)
        chat.isBusy = false
        await waitUntil { sender.queue.isEmpty }
        XCTAssertEqual(chat.log, ["redirect:when you're done", "submit:when you're done"])
    }

    // MARK: Queue rows

    func testSendNowWhileBusyPromotesAndInterrupts() async {
        chat.isBusy = true
        _ = sender.queueDraft("first")
        _ = sender.queueDraft("second")
        await sender.stop()
        XCTAssertTrue(sender.parked)

        await sender.sendNow(sender.queue[1].id)
        XCTAssertEqual(sender.queue.map(\.text), ["second", "first"])
        XCTAssertFalse(sender.parked)
        XCTAssertEqual(chat.log, ["interrupt", "interrupt"])

        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log.last, "submit:second")
    }

    func testSendNowWhileIdleSendsThatPrompt() async {
        chat.isBusy = true
        _ = sender.queueDraft("first")
        _ = sender.queueDraft("second")
        await sender.stop()
        chat.isBusy = false
        await sender.sendNow(sender.queue[1].id)
        XCTAssertEqual(chat.log, ["interrupt", "submit:second"])
        XCTAssertEqual(sender.queue.map(\.text), ["first"])
    }

    func testSteerNowRedirectsATextPrompt() async {
        chat.isBusy = true
        _ = sender.queueDraft("steer me")
        let steered = await sender.steerNow(sender.queue[0].id)
        XCTAssertTrue(steered)
        XCTAssertTrue(sender.queue.isEmpty)
        XCTAssertEqual(chat.log, ["redirect:steer me"])
    }

    func testRefusedSteerNowKeepsThePrompt() async {
        chat.isBusy = true
        chat.redirectOutcome = .rejected
        _ = sender.queueDraft("steer me")
        let steered = await sender.steerNow(sender.queue[0].id)
        XCTAssertFalse(steered)
        XCTAssertEqual(sender.queue.map(\.text), ["steer me"])
    }

    func testSteerNowSkipsWhatARedirectCantCarry() async {
        chat.isBusy = true
        _ = sender.queueDraft("with photo", attachments: [photo])
        _ = sender.queueDraft("/usage")
        let first = await sender.steerNow(sender.queue[0].id)
        let second = await sender.steerNow(sender.queue[1].id)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertFalse(sender.queue[0].isSteerable)
        XCTAssertTrue(chat.log.isEmpty)
    }

    // MARK: Editing

    func testEditingAQueuedPromptSavesInPlace() async {
        chat.isBusy = true
        _ = sender.queueDraft("first")
        _ = sender.queueDraft("second")
        let entry = sender.beginEdit(sender.queue[0].id)
        XCTAssertEqual(entry?.text, "first")
        XCTAssertNil(sender.beginEdit(sender.queue[1].id))

        let result = await sender.send("first, edited", attachments: [notes])
        XCTAssertEqual(result, .savedEdit)
        XCTAssertNil(sender.editingID)
        XCTAssertEqual(sender.queue.map(\.text), ["first, edited", "second"])
        XCTAssertEqual(sender.queue[0].attachments, [notes])
        XCTAssertTrue(chat.log.isEmpty)
    }

    func testEmptiedEditIsNotSaved() async {
        chat.isBusy = true
        _ = sender.queueDraft("first")
        _ = sender.beginEdit(sender.queue[0].id)
        let result = await sender.send("  ")
        XCTAssertEqual(result, .kept)
        XCTAssertNotNil(sender.editingID)
        sender.cancelEdit()
        XCTAssertNil(sender.editingID)
        XCTAssertEqual(sender.queue.map(\.text), ["first"])
    }

    func testDrainPassesOverTheEditedPrompt() async {
        chat.isBusy = true
        _ = sender.queueDraft("being edited")
        _ = sender.queueDraft("ready")
        _ = sender.beginEdit(sender.queue[0].id)
        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log, ["submit:ready"])
        XCTAssertEqual(sender.queue.map(\.text), ["being edited"])
    }

    func testRemovingTheEditedPromptEndsTheEdit() async {
        chat.isBusy = true
        _ = sender.queueDraft("going")
        let id = sender.queue[0].id
        _ = sender.beginEdit(id)
        sender.remove(id)
        XCTAssertNil(sender.editingID)
        XCTAssertTrue(sender.queue.isEmpty)
    }

    func testGeneratedPromptQueuesWithItsDisplay() async {
        chat.isBusy = true
        XCTAssertTrue(sender.queuePrompt("SKILL BODY", display: "/work fix it"))
        XCTAssertFalse(sender.queuePrompt("  ", display: nil))
        XCTAssertEqual(sender.queue.first?.display, "/work fix it")
        XCTAssertFalse(sender.queue[0].isSteerable)

        // Editing it edits the invocation, which then runs as a command again.
        _ = sender.beginEdit(sender.queue[0].id)
        _ = await sender.send("/work fix it properly")
        XCTAssertNil(sender.queue[0].display)
        chat.isBusy = false
        await sender.drainIfIdle()
        XCTAssertEqual(chat.log, ["slash:/work fix it properly"])
    }

    // MARK: Text

    func testSlashCommandDetection() {
        XCTAssertTrue(SendController.isSlashCommand("/help"))
        XCTAssertTrue(SendController.isSlashCommand("  /model gpt"))
        XCTAssertTrue(SendController.isSlashCommand("/"))
        XCTAssertTrue(SendController.isSlashCommand("/title new\nname"))
        XCTAssertFalse(SendController.isSlashCommand("/usr/bin/env"))
        XCTAssertFalse(SendController.isSlashCommand("see /help"))
        XCTAssertFalse(SendController.isSlashCommand("hello"))
        XCTAssertTrue(SendController.isSideTask("/btw why?"))
        XCTAssertTrue(SendController.isSideTask("/bg run it"))
        XCTAssertTrue(SendController.isSideTask("/background"))
        XCTAssertFalse(SendController.isSideTask("/btwx"))
        XCTAssertFalse(SendController.isSideTask("btw"))
    }

    func testPromptText() {
        let image = StagedAttachment(kind: .image, name: "a.png", refText: nil)
        let file = StagedAttachment(kind: .file, name: "b.txt", refText: "@file:b.txt")
        XCTAssertEqual(StagedAttachment.promptText("  hi ", []), "hi")
        XCTAssertEqual(StagedAttachment.promptText("", [image]), "What do you see in this image?")
        XCTAssertEqual(StagedAttachment.promptText("what is it", [image]), "what is it")
        XCTAssertEqual(StagedAttachment.promptText("", [file, image]), "@file:b.txt")
        XCTAssertEqual(StagedAttachment.promptText("read", [file, file]), "@file:b.txt\n@file:b.txt\n\nread")
    }

    func testRedirectOutcomeFromStatus() {
        XCTAssertEqual(RedirectOutcome(.redirected), .redirected)
        XCTAssertEqual(RedirectOutcome(.queued), .queued)
        XCTAssertEqual(RedirectOutcome(.rejected), .rejected)
        XCTAssertEqual(RedirectOutcome(.unknown("later")), .rejected)
        XCTAssertTrue(RedirectOutcome.queued.delivered)
        XCTAssertFalse(RedirectOutcome.failed.delivered)
    }
}
