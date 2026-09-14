import AVKit
import SwiftUI
import Translation

struct RootView: View {
    @EnvironmentObject private var model: ProjectModel
    @State private var dropTargeted = false
    @State private var editing: Int? = nil

    var body: some View {
        Group {
            if model.mediaURL == nil { emptyState } else { workspace }
        }
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in await model.open(url) } }
            }
            return true
        }
        .overlay { if dropTargeted { Color.accentColor.opacity(0.08).allowsHitTesting(false) } }
        .background(TranslationBridge())
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "captions.bubble").font(.system(size: 52, weight: .light)).foregroundStyle(.tertiary)
            Text("Drop a video or audio file").font(.title2.weight(.semibold))
            Text("Subtitles transcribes it on your Mac in 25 languages, lets you fix the text, translate it, and export SRT, VTT, or a video with the captions burned in.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button("Open File…") { model.openPanel() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspace: some View {
        HSplitView {
            VStack(spacing: 0) {
                ZStack(alignment: model.style.position == .bottom ? .bottom : .top) {
                    if model.hasVideo {
                        VideoPlayer(player: model.player)
                    } else {
                        ZStack { Color.black; Image(systemName: "waveform").font(.system(size: 60)).foregroundStyle(.white.opacity(0.4)); }
                            .overlay(alignment: .bottom) { AudioTransport().padding(12) }
                    }
                    if let c = model.currentCue { CaptionPreview(cue: c, style: model.style, aspect: model.videoAspect).allowsHitTesting(false) }
                }
                .background(Color.black)
                .frame(minHeight: 300)
                StylePanel()
            }
            .frame(minWidth: 480)
            CueList(editing: $editing)
                .frame(minWidth: 340, idealWidth: 420)
        }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isWorking { ProgressView(value: model.progress).frame(width: model.progress == nil ? 20 : 120).controlSize(.small) }
            Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.isWorking, model.progress != nil { Button("Cancel") { model.cancelBurn() } }
            if let url = model.mediaURL { Text(url.lastPathComponent).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8).background(.bar).overlay(alignment: .top) { Divider() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }
            Button { Task { await model.transcribe() } } label: { Label(model.cues.isEmpty ? "Transcribe" : "Transcribe Again", systemImage: "waveform.badge.mic") }
                .disabled(model.mediaURL == nil || model.isWorking)
                .buttonStyle(.borderedProminent)
            TranslateMenu()
            Menu {
                Section("Subtitle file") {
                    ForEach(ExportFormat.allCases, id: \.self) { f in Button(f.rawValue) { model.exportPanel(format: f, translated: false) } }
                }
                if model.cues.contains(where: { $0.translation != nil }) {
                    Section("Translated subtitle file") {
                        ForEach(ExportFormat.allCases, id: \.self) { f in Button(f.rawValue) { model.exportPanel(format: f, translated: true) } }
                    }
                }
                Divider()
                Button("Burn Into Video…") { model.burnPanel() }.disabled(!model.hasVideo)
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .disabled(model.cues.isEmpty || model.isWorking)
        }
    }
}

struct AudioTransport: View {
    @EnvironmentObject private var model: ProjectModel
    @State private var playing = false
    var body: some View {
        HStack {
            Button { if playing { model.player.pause() } else { model.player.play() }; playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
            Slider(value: Binding(get: { model.currentTime }, set: { t in model.player.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }), in: 0...max(1, model.duration))
            Text(SubtitleFormat.timestamp(model.currentTime, srt: false).dropLast(4)).font(.caption.monospacedDigit()).foregroundStyle(.white)
        }
        .padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CaptionPreview: View {
    let cue: Cue
    let style: CaptionStyle
    let aspect: CGFloat   // video width / height, so the preview matches the burned-in size
    var body: some View {
        GeometryReader { g in
            // The player letterboxes the video; size the caption against the video's drawn height.
            let fit = min(g.size.width / max(0.1, aspect), g.size.height)
            let videoW = fit * aspect, videoH = fit
            let text = (style.showTranslation ? cue.translation : nil) ?? cue.text
            let fs = videoH * style.fontScale
            VStack(spacing: 4) {
                Text(style.uppercase ? text.uppercased() : text)
                if style.both, let t = cue.translation { Text(t) }
            }
            .font(.system(size: fs, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, fs * 0.45).padding(.vertical, fs * 0.25)
            .background(style.box ? Color.black.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: fs * 0.25))
            .shadow(color: style.box ? .clear : .black, radius: 2)
            .frame(maxWidth: videoW * 0.86)
            .frame(width: videoW, height: videoH, alignment: style.position == .bottom ? .bottom : .top)
            .padding(.vertical, videoH * 0.07)
            .frame(width: videoW, height: videoH)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
    }
}

struct StylePanel: View {
    @EnvironmentObject private var model: ProjectModel
    var body: some View {
        HStack(spacing: 16) {
            Picker("Position", selection: $model.style.position) { Text("Bottom").tag(CaptionStyle.Position.bottom); Text("Top").tag(CaptionStyle.Position.top) }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
            HStack(spacing: 6) { Text("Size").font(.callout); Slider(value: $model.style.fontScale, in: 0.03...0.08).frame(width: 110) }
            Toggle("Box", isOn: $model.style.box).toggleStyle(.checkbox)
            Toggle("Caps", isOn: $model.style.uppercase).toggleStyle(.checkbox)
            if model.cues.contains(where: { $0.translation != nil }) {
                Picker("Show", selection: Binding(get: { model.style.both ? 2 : (model.style.showTranslation ? 1 : 0) }, set: { v in model.style.both = v == 2; model.style.showTranslation = v == 1 })) {
                    Text("Original").tag(0); Text("Translation").tag(1); Text("Both").tag(2)
                }.frame(width: 190)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct CueList: View {
    @EnvironmentObject private var model: ProjectModel
    @Binding var editing: Int?

    var body: some View {
        if model.cues.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                Text(model.isWorking ? model.status : "Press Transcribe to generate captions").font(.callout).foregroundStyle(.secondary)
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach($model.cues) { $cue in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(SubtitleFormat.timestamp(cue.start, srt: false).dropLast(4)) → \(SubtitleFormat.timestamp(cue.end, srt: false).dropLast(4))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f s", cue.duration)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            TextField("", text: $cue.text, axis: .vertical).textFieldStyle(.plain).font(.body)
                            if let t = cue.translation {
                                TextField("", text: Binding(get: { t }, set: { cue.translation = $0 }), axis: .vertical).textFieldStyle(.plain).font(.body).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(model.currentCue?.id == cue.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.seek(to: cue) }
                        .id(cue.id)
                    }
                }
                .onChange(of: model.currentCue?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            }
        }
    }
}

// MARK: - Translation (Apple Translation framework, macOS 15+)

struct TranslateMenu: View {
    @EnvironmentObject private var model: ProjectModel
    static let languages: [(String, String)] = [("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"), ("Polish", "pl"), ("Russian", "ru"), ("Ukrainian", "uk"), ("Turkish", "tr"), ("Arabic", "ar"), ("Hindi", "hi"), ("Japanese", "ja"), ("Korean", "ko"), ("Chinese (Simplified)", "zh-Hans"), ("Chinese (Traditional)", "zh-Hant"), ("Indonesian", "id"), ("Vietnamese", "vi"), ("Thai", "th")]

    var body: some View {
        if #available(macOS 15, *) {
            Menu {
                ForEach(Self.languages, id: \.1) { name, code in
                    Button(name) { model.targetLanguage = Locale.Language(identifier: code); model.translationRequest += 1 }
                }
            } label: { Label(model.isTranslating ? "Translating…" : "Translate", systemImage: "character.book.closed") }
            .disabled(model.cues.isEmpty || model.isWorking || model.isTranslating)
            .help("Translate captions on device with Apple's Translation framework. Language packs download once.")
        } else {
            Button { } label: { Label("Translate", systemImage: "character.book.closed") }.disabled(true).help("Translation needs macOS 15 or newer.")
        }
    }
}

/// Invisible view hosting the SwiftUI-only translation task.
struct TranslationBridge: View {
    @EnvironmentObject private var model: ProjectModel
    var body: some View {
        if #available(macOS 15, *) { TranslationHost() } else { EmptyView() }
    }
}

@available(macOS 15, *)
struct TranslationHost: View {
    @EnvironmentObject private var model: ProjectModel
    @State private var config: TranslationSession.Configuration? = nil

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: model.translationRequest) { _, _ in
                guard let target = model.targetLanguage else { return }
                if config?.target == target { config?.invalidate() } else { config = TranslationSession.Configuration(source: nil, target: target) }
            }
            .translationTask(config) { session in
                await translate(with: session)
            }
    }

    private func translate(with session: TranslationSession) async {
        model.isTranslating = true
        defer { model.isTranslating = false }
        do {
            try await session.prepareTranslation()
            let requests = model.cues.map { TranslationSession.Request(sourceText: $0.text.replacingOccurrences(of: "\n", with: " "), clientIdentifier: String($0.id)) }
            for try await response in session.translate(batch: requests) {
                if let id = response.clientIdentifier.flatMap(Int.init), let i = model.cues.firstIndex(where: { $0.id == id }) {
                    model.cues[i].translation = CueBuilder.wrap(response.targetText)
                }
            }
            model.style.showTranslation = true
            model.status = "Translated \(model.cues.count) cues"
        } catch {
            model.error = "Translation failed: \(error.localizedDescription)"
        }
    }
}
