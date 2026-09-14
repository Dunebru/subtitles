import XCTest
@testable import Subtitles

final class SubtitlesTests: XCTestCase {
    func testWordMergerJoinsSubwords() {
        let tokens: [(text: String, start: TimeInterval, end: TimeInterval)] = [("▁Hel", 0, 0.2), ("lo", 0.2, 0.3), (",", 0.3, 0.31), ("▁wor", 0.5, 0.6), ("ld", 0.6, 0.7), ("!", 0.7, 0.71)]
        let words = WordMerger.words(fromTokens: tokens)
        XCTAssertEqual(words.map(\.text), ["Hello,", "world!"])
        XCTAssertEqual(words[1].start, 0.5, accuracy: 0.001)
    }

    func testNumbersBecomeSeparateWords() {
        let tokens: [(text: String, start: TimeInterval, end: TimeInterval)] = [("▁the", 0, 0.1), ("9", 0.1, 0.2), ("2", 0.2, 0.3), ("▁steps", 0.4, 0.6), ("▁on", 0.7, 0.8), ("▁the", 0.8, 0.9), ("2", 0.9, 1.0), ("nd", 1.0, 1.1)]
        XCTAssertEqual(WordMerger.words(fromTokens: tokens).map(\.text), ["the", "92", "steps", "on", "the", "2nd"])
    }

    func testCueBuilderRespectsLimits() {
        var words: [Word] = []
        var t = 0.0
        for i in 0..<120 { words.append(Word(text: "word\(i)" + (i % 9 == 8 ? "." : ""), start: t, end: t + 0.3)); t += 0.35 }
        let cues = CueBuilder.cues(from: words)
        XCTAssertGreaterThan(cues.count, 5)
        for c in cues {
            XCTAssertLessThanOrEqual(c.duration, CueBuilder.maxDuration + 0.001)
            XCTAssertLessThanOrEqual(c.text.split(separator: "\n").count, 2)
            for line in c.text.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, CueBuilder.maxCharsPerLine) }
        }
        for i in 0..<(cues.count - 1) { XCTAssertLessThanOrEqual(cues[i].end, cues[i + 1].start + 0.001) }
    }

    func testPauseBreaksCue() {
        let words = [Word(text: "One", start: 0, end: 0.3), Word(text: "two", start: 0.4, end: 0.7), Word(text: "three", start: 3.0, end: 3.3)]
        let cues = CueBuilder.cues(from: words)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "One two")
    }

    func testSRTFormat() {
        let cues = [Cue(id: 0, start: 1.5, end: 3.25, text: "Hi there")]
        XCTAssertEqual(SubtitleFormat.srt(cues), "1\n00:00:01,500 --> 00:00:03,250\nHi there\n")
        XCTAssertTrue(SubtitleFormat.vtt(cues).hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:03.250"))
    }

    func testWrapBalancesLines() {
        let wrapped = CueBuilder.wrap("this is a fairly long subtitle line that needs to be split, into two balanced parts")
        let lines = wrapped.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.count <= CueBuilder.maxCharsPerLine })
    }
}
