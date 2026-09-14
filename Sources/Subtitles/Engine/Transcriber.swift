import FluidAudio
import Foundation

/// Parakeet TDT v3 (25 languages) on CoreML via FluidAudio.
actor Transcriber {
    enum State: Equatable { case idle, downloading, ready, failed(String) }

    private var manager: AsrManager?
    private(set) var state: State = .idle

    func prepare() async -> State {
        if state == .ready { return state }
        state = .downloading
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            manager = m
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            fputs("[subtitles] model load failed: \(error)\n", stderr)
        }
        return state
    }

    struct Output { var words: [Word]; var text: String; var duration: TimeInterval; var processingTime: TimeInterval }

    func transcribe(samples: [Float]) async throws -> Output {
        if state != .ready { _ = await prepare() }
        guard let manager else { throw NSError(domain: "Subtitles", code: 10, userInfo: [NSLocalizedDescriptionKey: "Speech model is not available."]) }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        let tokens: [(text: String, start: TimeInterval, end: TimeInterval)] = (result.tokenTimings ?? []).map { (text: $0.token, start: $0.startTime, end: $0.endTime) }
        var words = WordMerger.words(fromTokens: tokens)
        if words.isEmpty, !result.text.isEmpty {
            // No timings: spread words evenly so the user still gets a usable draft.
            let parts = result.text.split(separator: " ").map(String.init)
            let step = result.duration / Double(max(1, parts.count))
            words = parts.enumerated().map { Word(text: $1, start: Double($0) * step, end: Double($0 + 1) * step) }
        }
        return Output(words: words, text: result.text, duration: result.duration, processingTime: result.processingTime)
    }
}
