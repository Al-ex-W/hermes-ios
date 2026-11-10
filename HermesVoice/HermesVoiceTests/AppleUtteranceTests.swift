import XCTest
@testable import HermesVoice

/// How Apple speech recognition results become one utterance: across the recognizer's own segments and finished
/// requests, until the user's pause has passed.
final class AppleUtteranceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// An utterance that heard `text` at `seconds`.
    private func heard(_ text: String, at seconds: TimeInterval) -> AppleUtteranceAssembler {
        var utterance = AppleUtteranceAssembler()
        utterance.result(text, closesSegment: false, at: at(seconds))
        return utterance
    }

    func testResultsOfOneSegmentReplaceEachOther() {
        var utterance = AppleUtteranceAssembler()
        XCTAssertFalse(utterance.hasText)
        XCTAssertTrue(utterance.result("I", closesSegment: false, at: at(1)))
        XCTAssertTrue(utterance.result("I think we shoot", closesSegment: false, at: at(1.5)))
        // A revision of the same segment: the recognizer changes its mind about a word.
        XCTAssertTrue(utterance.result("I think we should go", closesSegment: false, at: at(2)))
        XCTAssertFalse(utterance.result("I think we should go", closesSegment: false, at: at(2.2)), "nothing changed")
        XCTAssertEqual(utterance.text, "I think we should go")
        XCTAssertEqual(utterance.segments, [])
        XCTAssertEqual(utterance.startedAt, at(1))
        XCTAssertEqual(utterance.lastWordsAt, at(2))
    }

    func testRevisionsAreNotTakenForANewSegment() {
        // Shorter, same beginning.
        var shorter = heard("I think we should go", at: 1)
        shorter.result("I think we should", closesSegment: false, at: at(2))
        XCTAssertEqual(shorter.text, "I think we should")
        // The first word changed, about as long.
        var first = heard("Hi think we", at: 1)
        first.result("I think", closesSegment: false, at: at(2))
        XCTAssertEqual(first.text, "I think")
        // One word for another.
        var word = heard("Yes", at: 1)
        word.result("Yeah", closesSegment: false, at: at(2))
        XCTAssertEqual(word.text, "Yeah")
        // Longer, different beginning.
        var longer = heard("Eye think", at: 1)
        longer.result("I think we should", closesSegment: false, at: at(2))
        XCTAssertEqual(longer.text, "I think we should")
    }

    func testNewWordsAfterAClosedSegmentJoinTheSentence() {
        var utterance = heard("I think we should", at: 2)
        // The recognizer closes the segment after its own short pause…
        XCTAssertFalse(utterance.result("I think we should", closesSegment: true, at: at(3.2)))
        XCTAssertEqual(utterance.text, "I think we should")
        // …and starts its text over with what is said next.
        XCTAssertTrue(utterance.result("go", closesSegment: false, at: at(5)))
        XCTAssertEqual(utterance.text, "I think we should go")
        utterance.result("go tomorrow", closesSegment: false, at: at(5.4))
        XCTAssertEqual(utterance.text, "I think we should go tomorrow")
        XCTAssertEqual(utterance.segments, ["I think we should"])
        XCTAssertEqual(utterance.startedAt, at(2))
        // A second pause in the same sentence.
        utterance.result("Go tomorrow.", closesSegment: true, at: at(6.5))
        utterance.result("if", closesSegment: false, at: at(8))
        utterance.result("if it is dry", closesSegment: false, at: at(8.6))
        XCTAssertEqual(utterance.text, "I think we should Go tomorrow. if it is dry")
        XCTAssertEqual(utterance.segments, ["I think we should", "Go tomorrow."])
    }

    func testNewWordsThatBeginLikeTheClosedSegmentAreStillNew() {
        var utterance = heard("I think", at: 1)
        utterance.result("I think", closesSegment: true, at: at(2.2))
        utterance.result("I guess tomorrow works", closesSegment: false, at: at(4))
        XCTAssertEqual(utterance.text, "I think I guess tomorrow works")
    }

    func testARecognizerThatKeepsItsTextIsNotDoubled() {
        var utterance = heard("i think we should", at: 2)
        utterance.result("I think we should.", closesSegment: true, at: at(3.2))
        // The recognizer goes on in the same text after closing the segment.
        utterance.result("I think we should go", closesSegment: false, at: at(5))
        XCTAssertEqual(utterance.text, "I think we should go")
        XCTAssertEqual(utterance.segments, [])
        utterance.result("I think we should go tomorrow", closesSegment: false, at: at(5.5))
        XCTAssertEqual(utterance.text, "I think we should go tomorrow")
    }

    func testATextThatStartsOverWithoutASignIsKept() {
        var utterance = heard("I think we should", at: 2)
        utterance.result("go", closesSegment: false, at: at(5))
        XCTAssertEqual(utterance.text, "I think we should go")
        utterance.result("go tomorrow", closesSegment: false, at: at(5.5))
        XCTAssertEqual(utterance.text, "I think we should go tomorrow")
        // Two words then one.
        var short = heard("Sounds good", at: 1)
        short.result("and", closesSegment: false, at: at(4))
        XCTAssertEqual(short.text, "Sounds good and")
    }

    func testARequestThatFinishesMidSentenceKeepsTheWords() {
        var utterance = heard("I think we should", at: 2)
        // isFinal: the request is over; the listener starts a fresh one.
        utterance.result("I think we should", closesSegment: true, at: at(3.5))
        utterance.requestEnded()
        XCTAssertTrue(utterance.hasText)
        XCTAssertEqual(utterance.text, "I think we should")
        XCTAssertEqual(utterance.current, "")
        XCTAssertEqual(utterance.silenceDue(pause: 3.5), at(5.5), "the pause went on counting")
        // The new request hears the rest.
        utterance.result("go tomorrow", closesSegment: false, at: at(4.5))
        XCTAssertEqual(utterance.text, "I think we should go tomorrow")
        XCTAssertEqual(utterance.startedAt, at(2))
        XCTAssertEqual(utterance.silenceDue(pause: 3.5), at(8))
        // A new request that begins with the very same words is still new speech.
        utterance.requestEnded()
        utterance.result("go tomorrow", closesSegment: false, at: at(9))
        XCTAssertEqual(utterance.text, "I think we should go tomorrow go tomorrow")

        var nothing = AppleUtteranceAssembler()
        nothing.requestEnded()
        XCTAssertFalse(nothing.hasText)
        XCTAssertNil(nothing.silenceDue(pause: 3.5))
    }

    func testEmptyResults() {
        var utterance = AppleUtteranceAssembler()
        XCTAssertFalse(utterance.result("", closesSegment: false, at: at(1)))
        XCTAssertFalse(utterance.result("  ", closesSegment: true, at: at(2)))
        XCTAssertFalse(utterance.hasText)
        XCTAssertNil(utterance.startedAt)
        XCTAssertNil(utterance.silenceDue(pause: 3.5))
        XCTAssertNil(utterance.take())

        // The recognizer going back to nothing doesn't take away what was heard.
        utterance.result("hello", closesSegment: false, at: at(3))
        XCTAssertFalse(utterance.result("", closesSegment: false, at: at(4)))
        XCTAssertEqual(utterance.text, "hello")
        XCTAssertEqual(utterance.lastWordsAt, at(3))
        utterance.result("again", closesSegment: false, at: at(5))
        XCTAssertEqual(utterance.text, "hello again")
    }

    // MARK: The pause

    func testThePauseCountsFromTheLastNewWords() {
        var utterance = AppleUtteranceAssembler()
        XCTAssertNil(utterance.silenceDue(pause: 3.5))
        utterance.result("I think", closesSegment: false, at: at(1))
        for level in EndOfSpeech.allCases {
            XCTAssertEqual(utterance.silenceDue(pause: level.pause), at(1 + level.pause), level.rawValue)
        }
        utterance.result("I think we should", closesSegment: false, at: at(2))
        XCTAssertEqual(utterance.silenceDue(pause: 3.5), at(5.5))
        // The recognizer closing the segment, with or without tidier text, is not the user talking.
        XCTAssertFalse(utterance.result("I think we should", closesSegment: true, at: at(3)))
        XCTAssertEqual(utterance.silenceDue(pause: 3.5), at(5.5))
        XCTAssertTrue(utterance.result("I think, we should.", closesSegment: true, at: at(3.3)), "the text on screen changed")
        XCTAssertEqual(utterance.silenceDue(pause: 3.5), at(5.5))
        // Nor is a request that ends.
        utterance.requestEnded()
        XCTAssertEqual(utterance.silenceDue(pause: 3.5), at(5.5))
        // 2.5 s after the last word the user goes on: the pause starts again.
        utterance.result("go", closesSegment: false, at: at(4.5))
        XCTAssertEqual(utterance.silenceDue(pause: 3.5), at(8))
        XCTAssertEqual(utterance.text, "I think, we should. go")
    }

    func testNoPauseIsCountedOnceListeningPaused() {
        var utterance = heard("I was saying", at: 1)
        utterance.result("I was saying", closesSegment: true, at: at(2))
        utterance.result("that", closesSegment: false, at: at(3))
        // Hermes speaks: the call flushed the words as cut off, and the listener drops the utterance.
        XCTAssertEqual(utterance.take()?.text, "I was saying that")
        utterance.discard()
        XCTAssertFalse(utterance.hasText)
        XCTAssertNil(utterance.lastWordsAt)
        XCTAssertNil(utterance.silenceDue(pause: 3.5))
        // What is said once Hermes is done is a new utterance, with its own pause.
        utterance.result("my answer", closesSegment: false, at: at(30))
        XCTAssertEqual(utterance.text, "my answer")
        XCTAssertEqual(utterance.startedAt, at(30))
        XCTAssertEqual(utterance.silenceDue(pause: 3.5), at(33.5))
    }

    func testTakeGivesEverySegmentAndTheOpenText() {
        var utterance = heard("I think we should", at: 2)
        utterance.result("I think we should", closesSegment: true, at: at(3))
        utterance.requestEnded()
        utterance.result("go tomorrow", closesSegment: true, at: at(5))
        utterance.result("if it", closesSegment: false, at: at(7))
        let taken = utterance.take()
        XCTAssertEqual(taken?.text, "I think we should go tomorrow if it")
        XCTAssertEqual(taken?.startedAt, at(2))
        XCTAssertFalse(utterance.hasText)
        XCTAssertNil(utterance.take())
        // The recognizer's next result belongs to a new utterance.
        utterance.result("is dry", closesSegment: false, at: at(8))
        XCTAssertEqual(utterance.text, "is dry")
    }
}
