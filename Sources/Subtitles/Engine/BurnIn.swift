import AppKit
import AVFoundation
import Foundation

/// Renders cues into the video frames using Core Animation, then exports an H.264/AAC MP4.
final class BurnInExporter {
    private(set) var session: AVAssetExportSession?

    func export(video url: URL, cues: [Cue], style: CaptionStyle, to output: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Subtitles", code: 20, userInfo: [NSLocalizedDescriptionKey: "Burn-in needs a video file. For audio, export SRT or VTT instead."])
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        // account for rotation metadata (phone videos)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: abs(rect.width), height: abs(rect.height))

        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer(); videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        parent.isGeometryFlipped = false
        for cue in cues { parent.addSublayer(Self.layer(for: cue, style: style, size: renderSize)) }
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Subtitles", code: 21, userInfo: [NSLocalizedDescriptionKey: "Could not start the export."])
        }
        export.videoComposition = composition
        export.outputURL = output
        export.outputFileType = .mp4
        try? FileManager.default.removeItem(at: output)
        session = export
        let ticker = Task { while !Task.isCancelled { progress(Double(export.progress)); try? await Task.sleep(nanoseconds: 250_000_000) } }
        defer { ticker.cancel() }
        try await export.export(to: output, as: .mp4)
        progress(1)
    }

    func cancel() { session?.cancelExport() }

    /// One caption layer. The caption is rasterized once (text plus optional rounded box) and shown
    /// as layer contents, which renders reliably inside AVFoundation's offscreen Core Animation pass.
    static func layer(for cue: Cue, style: CaptionStyle, size: CGSize) -> CALayer {
        var text = (style.showTranslation ? cue.translation : nil) ?? cue.text
        if style.both, let t = cue.translation { text = cue.text + "\n" + t }
        if style.uppercase { text = text.uppercased() }
        let image = rasterize(text: text, style: style, videoSize: size)
        let margin = size.height * 0.07
        let y = style.position == .bottom ? margin : size.height - margin - image.size.height
        let layer = CALayer()
        layer.frame = CGRect(x: (size.width - image.size.width) / 2, y: y, width: image.size.width, height: image.size.height)
        layer.contents = image.cgImage
        layer.contentsScale = 2
        layer.opacity = 0
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 1, 1, 0]
        anim.keyTimes = [0, 0.001, 0.999, 1]
        anim.beginTime = max(AVCoreAnimationBeginTimeAtZero, cue.start)
        anim.duration = max(0.1, cue.duration)
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.add(anim, forKey: "visible")
        return layer
    }

    /// Draws the caption at 2x into a bitmap. Returns the image and its size in video points.
    static func rasterize(text: String, style: CaptionStyle, videoSize: CGSize) -> (cgImage: CGImage?, size: CGSize) {
        let fontSize = videoSize.height * style.fontScale
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        if !style.box { attrs[.strokeColor] = NSColor.black; attrs[.strokeWidth] = -3.5 }
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let maxWidth = videoSize.width * 0.86
        let bounds = attributed.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let pad = fontSize * 0.45
        let boxSize = CGSize(width: ceil(bounds.width) + pad * 2, height: ceil(bounds.height) + pad)
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(boxSize.width * scale), height: Int(boxSize.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, boxSize) }
        ctx.scaleBy(x: scale, y: scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        if style.box {
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: boxSize), xRadius: fontSize * 0.25, yRadius: fontSize * 0.25).fill()
        }
        attributed.draw(with: CGRect(x: pad, y: pad / 2, width: ceil(bounds.width), height: ceil(bounds.height)), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return (ctx.makeImage(), boxSize)
    }
}
