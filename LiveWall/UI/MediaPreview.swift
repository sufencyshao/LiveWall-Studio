import AppKit
import AVFoundation
import SwiftUI

// MARK: - Live preview views (AppKit)

/// A muted, looping video preview. Only ever alive while it's on screen
/// and hovered (or in the preview sheet), so it doesn't cost anything for
/// the rest of the library.
final class PreviewPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var url: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspectFill
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer { playerLayer }

    /// Purely visual: let clicks and hover fall through to the SwiftUI
    /// card underneath, otherwise the card loses its hover state the
    /// moment the preview appears.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var gravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    func load(_ url: URL, muted: Bool = true) {
        stop()
        self.url = url
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = muted
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        playerLayer.player = queuePlayer
        queuePlayer.play()
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
        player = nil
        url = nil
    }
}

struct LiveVideoPreview: NSViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var muted = true

    func makeNSView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView(frame: .zero)
        view.gravity = gravity
        view.load(url, muted: muted)
        return view
    }

    func updateNSView(_ view: PreviewPlayerView, context: Context) {
        view.gravity = gravity
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

struct WallpaperPreviewSheet: View {
    let url: URL
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var muted = true
    @State private var info = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    switch MediaKind(url: url) {
                    case .video:
                        LiveVideoPreview(url: url, gravity: .resizeAspect, muted: muted)
                    case .animatedImage:
                        AnimatedImagePreview(url: url)
                    default:
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFit()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
        .frame(width: 760)
        .task(id: url) { info = await Self.describe(url) }
    }

    private static func describe(_ url: URL) async -> String {
        var parts: [String] = []
        if MediaKind(url: url)?.isVideo == true {
            let asset = AVURLAsset(url: url)
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
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}
