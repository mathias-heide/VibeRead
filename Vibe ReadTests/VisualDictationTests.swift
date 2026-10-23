import Foundation
import Testing
@testable import Vibe_Read

struct VisualDictationTests {
    @Test func imagesAreInterleavedWhereTheyWereMarked() {
        let parts = VisualDictation.parts(
            segmentTexts: ["So this looks wrong.", " Also this should be changed. ", ""],
            imageCount: 2
        )

        #expect(parts == [
            .text("So this looks wrong."),
            .image(index: 0),
            .text("Also this should be changed."),
            .image(index: 1)
        ])
        #expect(VisualDictation.plainText(parts: parts) { "[Image \($0 + 1)]" }
            == "So this looks wrong. [Image 1] Also this should be changed. [Image 2]")
    }

    private func words(_ entries: [(String, Double, Double)]) -> [TimedWord] {
        entries.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func markingDuringAPauseInsertsTheImageInThatPause() {
        // "So this looks wrong," [mark in silence] "also this should be changed." [mark]
        let pieces = VisualDictation.segmentTexts(
            transcript: "So this looks wrong, also this should be changed.",
            words: words([
                ("So", 0.0, 0.2), ("this", 0.25, 0.4), ("looks", 0.45, 0.6), ("wrong,", 0.65, 0.9),
                ("also", 2.5, 2.7), ("this", 2.75, 2.9), ("should", 2.95, 3.1),
                ("be", 3.15, 3.25), ("changed.", 3.3, 3.7)
            ]),
            anchors: [1.5, 4.5]
        )

        #expect(pieces == ["So this looks wrong,", " also this should be changed.", ""])
    }

    @Test func markingWhileTalkingSnapsToNearbyPunctuation() {
        // Ctrl is released while saying "misaligned".
        let pieces = VisualDictation.segmentTexts(
            transcript: "Fix the header. This button here is misaligned. Thanks.",
            words: words([
                ("Fix", 0.0, 0.2), ("the", 0.25, 0.35), ("header.", 0.4, 0.8),
                ("This", 1.0, 1.2), ("button", 1.25, 1.6), ("here", 1.65, 1.8),
                ("is", 1.85, 1.95), ("misaligned.", 2.0, 2.6), ("Thanks.", 2.7, 3.0)
            ]),
            anchors: [2.4]
        )

        #expect(pieces == ["Fix the header. This button here is misaligned.", " Thanks."])
    }

    @Test func runOnSpeechWithoutFullStopsKeepsImagesApart() {
        // Continuous talking with no full stop: each image stays where its
        // mark was finished instead of sliding to the end.
        let pieces = VisualDictation.segmentTexts(
            transcript: "And I'm still dictating and drawing again, and dictating and dictating and drawing",
            words: words([
                ("And", 4.0, 4.1), ("I'm", 4.15, 4.3), ("still", 4.35, 4.6), ("dictating", 4.65, 5.2),
                ("and", 5.25, 5.4), ("drawing", 5.45, 5.9), ("again,", 5.95, 6.4),
                ("and", 7.9, 8.0), ("dictating", 8.05, 8.5), ("and", 8.55, 8.65),
                ("dictating", 8.7, 9.2), ("and", 9.25, 9.35), ("drawing", 9.4, 9.8)
            ]),
            anchors: [7.0, 10.0]
        )

        #expect(pieces == [
            "And I'm still dictating and drawing again,",
            " and dictating and dictating and drawing",
            ""
        ])
    }

    @Test func whisperWordsWithoutPunctuationStillAlign() {
        let pieces = VisualDictation.segmentTexts(
            transcript: "This looks wrong. Also this.",
            words: words([
                ("This", 0.0, 0.2), ("looks", 0.25, 0.4), ("wrong", 0.45, 0.7),
                ("Also", 2.0, 2.2), ("this", 2.25, 2.5)
            ]),
            anchors: [1.2]
        )

        #expect(pieces == ["This looks wrong.", " Also this."])
    }

    @Test func multipleImagesNeverMoveBackwards() {
        let pieces = VisualDictation.segmentTexts(
            transcript: "One two three.",
            words: words([("One", 0.0, 0.2), ("two", 0.3, 0.5), ("three.", 0.6, 0.9)]),
            anchors: [0.1, 0.1]
        )

        #expect(pieces.count == 3)
        #expect(pieces.joined() == "One two three.")
    }

    @Test func estimatedTimingsCoverTheRecordingInOrder() {
        let estimated = VisualDictation.estimatedWords(transcript: "a bb ccc", duration: 9)

        #expect(estimated.map(\.text) == ["a", "bb", "ccc"])
        #expect(estimated.first?.start == 0)
        #expect(zip(estimated, estimated.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect((estimated.last?.end ?? 0) <= 9)
    }
}
