import AVFoundation
import Foundation

enum AudioExtractor {
    /// Decode any audio or video file to 16 kHz mono Float32, which is what Parakeet expects.
    static func samples16k(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "Subtitles", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file has no audio track."])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Subtitles", code: 2) }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            data.withUnsafeMutableBytes { ptr in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!) }
            samples.append(contentsOf: data)
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "Subtitles", code: 3) }
        return samples
    }

    static func duration(of url: URL) async -> TimeInterval {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    static func hasVideo(_ url: URL) async -> Bool {
        ((try? await AVURLAsset(url: url).loadTracks(withMediaType: .video))?.isEmpty == false)
    }
}
