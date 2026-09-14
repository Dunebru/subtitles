import AVFoundation
import SwiftUI

struct SubtitlesApp: App {
    @StateObject private var model = ProjectModel()

    var body: some Scene {
        WindowGroup("Subtitles") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
                .task {
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--open"), args.count > i + 1 {
                        await model.open(URL(fileURLWithPath: args[i + 1]))
                        if args.contains("--transcribe") { await model.transcribe() }
                        if let t = args.firstIndex(of: "--translate"), args.count > t + 1 {
                            model.targetLanguage = Locale.Language(identifier: args[t + 1]); model.translationRequest += 1
                        }
                        if let e = args.firstIndex(of: "--export-srt"), args.count > e + 1 { model.write(format: .srt, to: URL(fileURLWithPath: args[e + 1])) }
                        if let e = args.firstIndex(of: "--burn"), args.count > e + 1 { await model.burn(to: URL(fileURLWithPath: args[e + 1])) }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video or Audio…") { model.openPanel() }.keyboardShortcut("o")
            }
        }
    }
}

enum ExportFormat: String, CaseIterable { case srt = "SRT", vtt = "WebVTT", txt = "Transcript" }

@MainActor
final class ProjectModel: ObservableObject {
    @Published var mediaURL: URL?
    @Published var hasVideo = false
    @Published var videoAspect: CGFloat = 16.0 / 9.0
    @Published var duration: TimeInterval = 0
    @Published var words: [Word] = []
    @Published var cues: [Cue] = []
    @Published var style = CaptionStyle()
    @Published var status: String = ""
    @Published var isWorking = false
    @Published var progress: Double? = nil
    @Published var error: String?
    @Published var targetLanguage: Locale.Language? = nil
    @Published var translationRequest: Int = 0     // bumps to trigger the SwiftUI translation task
    @Published var isTranslating = false { didSet { fputs("[subtitles] translating=\(isTranslating) translated=\(cues.filter { $0.translation != nil }.count) error=\(error ?? "")\n", stderr) } }
    @Published var player = AVPlayer()
    @Published var currentTime: TimeInterval = 0
    @Published var processingTime: TimeInterval = 0

    private let transcriber = Transcriber()
    private var timeObserver: Any?
    private let burner = BurnInExporter()

    static let mediaTypes: [String] = ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "aiff", "caf", "mkv", "webm", "flac"]

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff]
        panel.message = "Choose a video or audio file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func open(_ url: URL) async {
        mediaURL = url
        cues = []; words = []; status = ""; error = nil
        hasVideo = await AudioExtractor.hasVideo(url)
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(t)
            if r.height > 0 { videoAspect = abs(r.width) / abs(r.height) }
        }
        duration = await AudioExtractor.duration(of: url)
        if let o = timeObserver { player.removeTimeObserver(o) }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            self?.currentTime = t.seconds
        }
    }

    func transcribe() async {
        guard let url = mediaURL, !isWorking else { return }
        isWorking = true; progress = nil; error = nil
        defer { isWorking = false; progress = nil }
        do {
            let state = await transcriber.state
            if state != .ready { status = "Downloading the speech model (about 600 MB, once)…"; _ = await transcriber.prepare() }
            if case .failed(let m) = await transcriber.state { error = m; status = ""; return }
            status = "Reading audio…"
            let samples = try await AudioExtractor.samples16k(from: url)
            status = "Transcribing \(Int(duration / 60)) min of audio…"
            let out = try await transcriber.transcribe(samples: samples)
            words = out.words
            cues = CueBuilder.cues(from: out.words)
            processingTime = out.processingTime
            status = cues.isEmpty ? "No speech found." : "\(cues.count) cues · \(String(format: "%.1f", out.processingTime)) s"
        } catch {
            self.error = error.localizedDescription
            status = ""
        }
    }

    var currentCue: Cue? { cues.first { currentTime >= $0.start && currentTime < $0.end } }

    func seek(to cue: Cue) {
        player.seek(to: CMTime(seconds: cue.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func rebuildCues() { cues = CueBuilder.cues(from: words) }

    // MARK: export

    func write(format: ExportFormat, to url: URL, translated: Bool = false) {
        let text: String
        switch format {
        case .srt: text = SubtitleFormat.srt(cues, translated: translated)
        case .vtt: text = SubtitleFormat.vtt(cues, translated: translated)
        case .txt: text = SubtitleFormat.plainText(cues, translated: translated)
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }

    func exportPanel(format: ExportFormat, translated: Bool) {
        let panel = NSSavePanel()
        let ext = format == .srt ? "srt" : format == .vtt ? "vtt" : "txt"
        panel.nameFieldStringValue = (mediaURL?.deletingPathExtension().lastPathComponent ?? "subtitles") + (translated ? ".\(targetLanguage?.languageCode?.identifier ?? "translated")" : "") + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(format: format, to: url, translated: translated)
    }

    func burnPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (mediaURL?.deletingPathExtension().lastPathComponent ?? "video") + " subtitled.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await burn(to: url) }
    }

    func burn(to url: URL) async {
        guard let media = mediaURL, !cues.isEmpty else { return }
        isWorking = true; progress = 0; status = "Rendering subtitles into video…"
        defer { isWorking = false; progress = nil }
        do {
            try await burner.export(video: media, cues: cues, style: style, to: url) { [weak self] p in Task { @MainActor in self?.progress = p } }
            status = "Saved \(url.lastPathComponent)"
        } catch {
            self.error = error.localizedDescription; status = ""
        }
    }

    func cancelBurn() { burner.cancel() }
}
