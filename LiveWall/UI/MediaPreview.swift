import AppKit
import AVFoundation
import SwiftUI

// MARK: - Live preview views (AppKit)

/// A muted, looping video preview. Only ever alive while it's on screen
/// and hovered (or in the preview sheet), so it doesn't cost anything for
/// the rest of the library.
final class PreviewPlayerView: PlayerView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var url: URL?

    /// Purely visual: let clicks and hover fall through to the SwiftUI
    /// card underneath, otherwise the card loses its hover state the
    /// moment the preview appears.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func load(_ url: URL, muted: Bool = true) {
        stop()
        guard let file = MediaKind.videoFile(for: url) else { return }
        self.url = url
        let item = AVPlayerItem(url: file)
        item.preferredForwardBufferDuration = 2
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = muted
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        display(queuePlayer)
        queuePlayer.play()
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        display(nil)
        player = nil
        url = nil
    }
}

struct LiveVideoPreview: NSViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var muted = true
    var fillPosition: FillPosition = .center

    func makeNSView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView(frame: .zero)
        view.gravity = gravity
        view.fillPosition = fillPosition
        view.load(url, muted: muted)
        return view
    }

    func updateNSView(_ view: PreviewPlayerView, context: Context) {
        view.gravity = gravity
        view.fillPosition = fillPosition
        if view.url != url { view.load(url, muted: muted) }
        view.setMuted(muted)
    }

    static func dismantleNSView(_ view: PreviewPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Animated GIF preview.
struct AnimatedImagePreview: NSViewRepresentable {
    let url: URL
    var fill = true

    func makeNSView(context: Context) -> NSImageView {
        let view = PassthroughImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSImage(contentsOf: url)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

// MARK: - Thumbnail

/// Static thumbnail that turns into a live, looping preview while hovered.
/// Fills whatever frame the parent gives it (use `.aspectRatio` outside).
struct MediaThumbnail: View {
    let url: URL
    var hoverToPlay = true
    /// Force live playback regardless of hover (e.g. the big header cover).
    var forceLive = false
    var cornerRadius: CGFloat = 8

    @State private var image: NSImage?
    @State private var failed = false
    @State private var live = false
    @State private var hoverTask: Task<Void, Never>?

    private var kind: MediaKind? { MediaKind(url: url) }

    var body: some View {
        Color.black.opacity(0.35)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: kind?.isVideo == true ? "film" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay {
                if live || forceLive {
                    switch kind {
                    case .video:
                        LiveVideoPreview(url: url)
                            .transition(.opacity)
                    case .animatedImage:
                        AnimatedImagePreview(url: url)
                            .transition(.opacity)
                    default:
                        EmptyView()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { inside in
                guard hoverToPlay, kind == .video || kind == .animatedImage else { return }
                hoverTask?.cancel()
                if inside {
                    // A short delay so sweeping the mouse across the grid
                    // doesn't start a dozen players.
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeIn(duration: 0.2)) { live = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { live = false }
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                live = false
            }
            .task(id: url) {
                failed = false
                image = ThumbnailCache.shared.cachedThumbnail(for: url)
                if image == nil {
                    image = await ThumbnailCache.shared.thumbnail(for: url)
                    failed = image == nil
                }
            }
    }
}

// MARK: - Small helpers

struct KindBadge: View {
    let url: URL
    @State private var duration: Double?

    var body: some View {
        HStack(spacing: 3) {
            switch MediaKind(url: url) {
            case .video:
                Image(systemName: "play.fill")
                Text(duration.map(formatDuration) ?? "视频")
            case .animatedImage:
                Text("GIF")
            case .scene:
                Image(systemName: "sparkles")
                Text("场景")
            case .web:
                Image(systemName: "globe")
                Text("网页")
            case .image:
                Image(systemName: "photo")
                Text("图片")
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .task(id: url) {
            duration = await ThumbnailCache.shared.duration(for: url)
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatMinutes(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes >= 60 && minutes % 60 == 0 { return "\(minutes / 60) 小时" }
    if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分" }
    return "\(minutes) 分钟"
}

struct NowPlayingTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "speaker.wave.2.fill")
            Text("正在使用")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor, in: Capsule())
    }
}

// MARK: - Big preview sheet

struct PreviewTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct WallpaperScalingPicker: View {
    @ObservedObject var engine: WallpaperEngine
    let url: URL?

    var body: some View {
        Picker("缩放方式", selection: Binding(
            get: { url.map { engine.scaling(for: $0) } ?? .fill },
            set: { mode in
                if let url { engine.setScaling(mode, for: url) }
            }
        )) {
            ForEach(ScalingMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .disabled(url == nil)
    }
}

struct WallpaperScalingMenu: View {
    let engine: WallpaperEngine
    let url: URL

    var body: some View {
        Menu("缩放方式") {
            WallpaperScalingPicker(engine: engine, url: url)
                .pickerStyle(.inline)
        }
    }
}

struct WallpaperFrameRatePicker: View {
    @ObservedObject var engine: WallpaperEngine
    let url: URL

    static func supports(_ url: URL) -> Bool {
        guard let kind = MediaKind(url: url) else { return false }
        return kind == .animatedImage || kind == .scene
    }

    var body: some View {
        Picker("壁纸帧率", selection: Binding(
            get: { engine.frameRate(for: url) },
            set: { engine.setFrameRate($0, for: url) }
        )) {
            Text("自动").tag(0)
            ForEach(WallpaperEngine.availableFrameRates, id: \.self) { fps in
                Text("\(fps) 帧/秒").tag(fps)
            }
        }
    }
}

struct BulkFrameRateMenu: View {
    let hasTargets: Bool
    let help: String
    let apply: (Int) -> Void

    var body: some View {
        Menu {
            Button("全部设为自动") { apply(0) }
            ForEach(WallpaperEngine.availableFrameRates, id: \.self) { fps in
                Button("全部设为 \(fps) 帧/秒") { apply(fps) }
            }
        } label: {
            Label("批量设置帧率", systemImage: "speedometer")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(help)
        .disabled(!hasTargets)
    }
}

private struct FramedImagePreview: NSViewRepresentable {
    let url: URL?
    let animated: Bool
    let scaling: ScalingMode
    let position: FillPosition
    let frameRate: Int

    func makeNSView(context: Context) -> ImageWallpaperView {
        let image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 1, height: 1))
        let view = ImageWallpaperView(frame: .zero, image: image, animated: animated, scaling: scaling, sourceURL: url)
        view.fillPosition = position
        view.setFrameRate(frameRate)
        return view
    }

    func updateNSView(_ view: ImageWallpaperView, context: Context) {
        view.apply(scaling)
        view.fillPosition = position
        view.setFrameRate(frameRate)
    }
}

private struct LiveScenePreview: NSViewRepresentable {
    let scene: WorkshopScene
    let size: CGSize
    let scaling: ScalingMode
    let position: FillPosition
    let frameRate: Int
    let onReady: () -> Void
    let onFailure: () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let sceneView = SceneWallpaperView(scene: scene, screen: screen, scaling: scaling,
                                                  position: position, muted: true, volume: 0,
                                                  frameRate: frameRate, previewSize: size, onReady: onReady,
                                                  onLoadFailure: onFailure) else {
            DispatchQueue.main.async(execute: onFailure)
            return container
        }
        container.addSubview(sceneView)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let sceneView = view.subviews.first as? SceneWallpaperView else { return }
        sceneView.setScaling(scaling)
        sceneView.setFillPosition(scaling == .fill ? position : .center)
        sceneView.setFrameRate(frameRate)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        view.subviews.first?.removeFromSuperview()
    }
}

private struct LiveWebPreview: NSViewRepresentable {
    let project: WorkshopWeb
    let size: CGSize
    let scaling: ScalingMode
    let position: FillPosition
    let onFailure: () -> Void

    func makeNSView(context: Context) -> WebWallpaperView {
        WebWallpaperView(project: project, frame: CGRect(origin: .zero, size: size), muted: true,
                         volume: 0, scaling: scaling, position: position, onFailure: onFailure)
    }

    func updateNSView(_ view: WebWallpaperView, context: Context) {
        view.setFraming(scaling, position: position)
    }
}

struct WallpaperPreviewSheet: View {
    @ObservedObject var engine: WallpaperEngine
    let url: URL
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var muted = true
    @State private var info = ""
    @State private var sceneReady = false
    @State private var sceneFailed = false
    @State private var webFailed = false

    private var previewSize: CGSize {
        let screen = NSScreen.main
        let ratio = screen.map { $0.frame.width / $0.frame.height } ?? (16.0 / 9.0)
        let maxWidth = min(728, (screen?.visibleFrame.width ?? 800) - 64)
        let maxHeight = min(420, (screen?.visibleFrame.height ?? 800) * 0.54)
        let width = min(maxWidth, maxHeight * ratio).rounded(.down)
        return CGSize(width: width, height: (width / ratio).rounded())
    }

    var body: some View {
        let scaling = engine.scaling(for: url)
        let position = engine.fillPosition(for: url)
        let frameRate = engine.frameRate(for: url)
        let scene = WorkshopScene(url)
        let web = WorkshopWeb(url)
        let size = previewSize
        VStack(alignment: .leading, spacing: 12) {
            Color.black
                .frame(width: size.width, height: size.height)
                .overlay {
                    if let scene {
                        LiveScenePreview(scene: scene, size: size, scaling: scaling, position: position,
                                         frameRate: frameRate,
                                         onReady: { sceneReady = true }, onFailure: { sceneFailed = true })
                        if sceneFailed {
                            Label(scene.hasAssets ? "无法载入场景预览" : "缺少 Wallpaper Engine 的 assets 文件夹",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.white)
                        } else if !sceneReady {
                            ProgressView("正在渲染场景…")
                                .foregroundStyle(.white)
                                .colorScheme(.dark)
                        }
                    } else if let web {
                        LiveWebPreview(project: web, size: size, scaling: scaling, position: position,
                                       onFailure: { webFailed = true })
                        if webFailed {
                            Label("无法载入本地网页", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.white)
                        }
                    } else if MediaKind(url: url)?.isVideo == true {
                        LiveVideoPreview(url: url, gravity: scaling.videoGravity, muted: muted, fillPosition: position)
                    } else {
                        FramedImagePreview(url: url, animated: MediaKind(url: url) == .animatedImage,
                                           scaling: scaling, position: position, frameRate: frameRate)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if scaling == .fill {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("填充取景").font(.headline)
                        Spacer()
                        Button("恢复居中") { engine.setFillPosition(.center, for: url) }
                            .disabled(position == .center)
                    }
                    positionSlider("水平", start: "左", end: "右", axis: \.x)
                    positionSlider("垂直", start: "上", end: "下", axis: \.y)
                }
            }

            if WallpaperFrameRatePicker.supports(url) {
                WallpaperFrameRatePicker(engine: engine, url: url).fixedSize()
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LibraryFiles.projectTitle(for: url) ?? url.deletingPathExtension().lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                WallpaperScalingPicker(engine: engine, url: url).fixedSize()
                if MediaKind(url: url)?.isVideo == true {
                    Button {
                        muted.toggle()
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help(muted ? "试听声音" : "静音")
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("设为壁纸") {
                    onUse()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: max(440, size.width) + 32)
        .task(id: url) {
            if web != nil { info = "本地网页壁纸" }
            else { info = scene == nil ? await Self.describe(url) : "场景壁纸" }
        }
    }

    private func positionSlider(_ title: String, start: String, end: String,
                                axis: WritableKeyPath<FillPosition, Double>) -> some View {
        HStack(spacing: 10) {
            Text(start).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { engine.fillPosition(for: url)[keyPath: axis] },
                set: { value in
                    var position = engine.fillPosition(for: url)
                    position[keyPath: axis] = value
                    engine.setFillPosition(position, for: url)
                }
            ), in: 0...1) { Text(title) }
                .labelsHidden()
                .accessibilityLabel(title + "取景位置")
            Text(end).foregroundStyle(.secondary)
        }
    }

    private static func describe(_ url: URL) async -> String {
        var parts: [String] = []
        let file = MediaKind.videoFile(for: url) ?? url
        if MediaKind(url: url)?.isVideo == true {
            let asset = AVURLAsset(url: file)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                parts.append("\(Int(abs(size.width))) × \(Int(abs(size.height)))")
            }
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
                parts.append(formatDuration(seconds))
            }
        } else if let rep = NSImageRep(contentsOf: url) {
            parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
        }
        if let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}
