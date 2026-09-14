import Foundation

struct Word: Hashable, Codable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct Cue: Identifiable, Hashable, Codable {
    var id: Int
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var translation: String? = nil

    var duration: TimeInterval { end - start }
}

/// Turns timed words into readable subtitle cues following the usual broadcast rules:
/// at most two lines of ~42 characters, 1 to 6 seconds on screen, breaks at punctuation and pauses.
enum CueBuilder {
    static let maxCharsPerLine = 42
    static let maxLines = 2
    static let maxDuration: TimeInterval = 6
    static let minDuration: TimeInterval = 1
    static let pauseBreak: TimeInterval = 0.7

    static func cues(from words: [Word]) -> [Cue] {
        var cues: [Cue] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            var end = max(last.end, first.start + minDuration)
            if end - first.start > maxDuration { end = first.start + maxDuration }
            cues.append(Cue(id: cues.count, start: first.start, end: end, text: wrap(current.map(\.text).joined(separator: " "))))
            current.removeAll()
        }

        for (i, w) in words.enumerated() {
            if let last = current.last {
                let candidate = (current.map(\.text) + [w.text]).joined(separator: " ")
                let tooLong = candidate.count > maxCharsPerLine * maxLines
                let tooSlow = w.end - current[0].start > maxDuration
                let pause = w.start - last.end > pauseBreak
                let sentenceEnd = last.text.last.map { ".!?".contains($0) } ?? false
                let clauseEnd = last.text.last.map { ",;:".contains($0) } ?? false
                let lineFull = candidate.count > maxCharsPerLine && (sentenceEnd || clauseEnd)
                if tooLong || tooSlow || pause || (sentenceEnd && Double(candidate.count) > Double(maxCharsPerLine) * 0.6) || lineFull {
                    flush()
                }
            }
            current.append(w)
            if i == words.count - 1 { flush() }
        }
        // keep cues from overlapping the next one
        for i in 0..<max(0, cues.count - 1) where cues[i].end > cues[i + 1].start {
            cues[i].end = max(cues[i].start + 0.3, cues[i + 1].start - 0.05)
        }
        return cues
    }

    /// Balance a cue into up to two lines, breaking near the middle at a space.
    static func wrap(_ text: String) -> String {
        guard text.count > maxCharsPerLine else { return text }
        let words = text.split(separator: " ").map(String.init)
        var best = text, bestScore = Int.max
        var first = ""
        for i in 0..<(words.count - 1) {
            first = words[0...i].joined(separator: " ")
            let second = words[(i + 1)...].joined(separator: " ")
            if first.count > maxCharsPerLine || second.count > maxCharsPerLine { continue }
            let score = abs(first.count - second.count) + (",.;:!?".contains(first.last ?? " ") ? -6 : 0)
            if score < bestScore { bestScore = score; best = first + "\n" + second }
        }
        return best
    }
}

/// Merge subword tokens from the recognizer into words. Parakeet uses SentencePiece: a token that
/// starts with "▁" begins a new word; punctuation tokens attach to the previous word.
enum WordMerger {
    static func words(fromTokens tokens: [(text: String, start: TimeInterval, end: TimeInterval)]) -> [Word] {
        var out: [Word] = []
        for t in tokens {
            var piece = t.text
            let startsWord = piece.hasPrefix("▁") || piece.hasPrefix(" ")
            piece = piece.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            let isPunct = piece.allSatisfy { $0.isPunctuation }
            // Numbers come out of text normalization without a word marker ("the" + "92"): treat a
            // digit run after a letter as its own word, but keep "92" + "nd" together.
            let numberAfterWord = (piece.first?.isNumber ?? false) && (out.last?.text.last?.isLetter ?? false)
            if out.isEmpty || (startsWord && !isPunct) || numberAfterWord {
                out.append(Word(text: piece, start: t.start, end: t.end))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = max(out[out.count - 1].end, t.end)
            }
        }
        return out
    }
}

enum SubtitleFormat {
    static func timestamp(_ t: TimeInterval, srt: Bool) -> String {
        let total = max(0, t)
        let h = Int(total / 3600), m = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let s = Int(total.truncatingRemainder(dividingBy: 60)), ms = Int((total - floor(total)) * 1000)
        return String(format: srt ? "%02d:%02d:%02d,%03d" : "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    static func srt(_ cues: [Cue], translated: Bool = false) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(timestamp(c.start, srt: true)) --> \(timestamp(c.end, srt: true))\n\((translated ? c.translation : nil) ?? c.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue], translated: Bool = false) -> String {
        "WEBVTT\n\n" + cues.map { c in
            "\(timestamp(c.start, srt: false)) --> \(timestamp(c.end, srt: false))\n\((translated ? c.translation : nil) ?? c.text)\n"
        }.joined(separator: "\n")
    }

    static func plainText(_ cues: [Cue], translated: Bool = false) -> String {
        cues.map { ((translated ? $0.translation : nil) ?? $0.text).replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ")
    }
}

struct CaptionStyle: Codable, Equatable {
    enum Position: String, Codable, CaseIterable { case bottom, top }
    var fontScale: Double = 0.045       // of video height
    var position: Position = .bottom
    var box: Bool = true
    var uppercase: Bool = false
    var showTranslation = false        // burn the translation instead of the original
    var both = false                   // burn both, translation under original
}
