import AppKit
import Combine
import QuartzCore
import Darwin

struct WorkshopScene {
    let project: URL
    let assets: URL
    let title: String
    let poster: URL?

    init?(_ url: URL) {
        let project = url.lastPathComponent.lowercased() == "scene.pkg"
            ? url.deletingLastPathComponent().appendingPathComponent("project.json")
            : url
        guard project.lastPathComponent == "project.json",
              let data = try? Data(contentsOf: project),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (manifest["type"] as? String)?.lowercased() == "scene" else { return nil }
        let folder = project.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) else { return nil }
        self.project = project
        let nearbyAssets = folder.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        if let bundledAssets = Bundle.main.resourceURL?.appendingPathComponent("SceneAssets", isDirectory: true),
           Self.isAssetRoot(bundledAssets) {
            self.assets = bundledAssets
        } else {
            self.assets = nearbyAssets
        }
        self.title = manifest["title"] as? String ?? folder.lastPathComponent
        if let name = manifest["preview"] as? String, !name.isEmpty, !name.contains("/"), !name.contains("\\"),
           name != ".", name != ".." {
            self.poster = folder.appendingPathComponent(name)
        } else {
            self.poster = nil
        }
    }

    var hasAssets: Bool {
        Self.isAssetRoot(assets)
    }

    private static func isAssetRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("shaders/genericimage2.frag").path)
    }
}

private final class WorkshopRenderer {
    typealias Open = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, Double, UInt32, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, Float, Bool, Int32) -> OpaquePointer?
    typealias Close = @convention(c) (OpaquePointer) -> Void
    typealias Pause = @convention(c) (OpaquePointer, Bool) -> Void
    typealias Audio = @convention(c) (OpaquePointer, Bool, Float) -> Void
    typealias Scaling = @convention(c) (OpaquePointer, Int32) -> Void
    typealias Framing = @convention(c) (OpaquePointer, Double, Double) -> Void
    typealias Pointer = @convention(c) (OpaquePointer, Double, Double) -> Void
    typealias Frames = @convention(c) (OpaquePointer) -> UInt64
    typealias AudioDemand = @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void
    typealias DropContext = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias ObserveAudio = @convention(c) (OpaquePointer, AudioDemand, UnsafeMutableRawPointer, DropContext) -> Int32
    typealias ReactiveAudio = @convention(c) (OpaquePointer, Bool) -> Void
    typealias RenderBudget = @convention(c) (OpaquePointer, UInt32, Double) -> Void
    typealias StartCapture = @convention(c) (UnsafeMutablePointer<Int32>) -> OpaquePointer?
    typealias StopCapture = @convention(c) (OpaquePointer) -> Void
    let open: Open
    let close: Close
    let pause: Pause
    let audio: Audio
    let scaling: Scaling
    let framing: Framing
    let pointer: Pointer
    let frames: Frames
    let observeAudio: ObserveAudio
    let reactiveAudio: ReactiveAudio
    let renderBudget: RenderBudget
    let startCapture: StartCapture
    let stopCapture: StopCapture
    static let shared: WorkshopRenderer? = WorkshopRenderer()

    private init?() {
        guard let folder = Bundle.main.privateFrameworksURL,
              let library = dlopen(folder.appendingPathComponent("libLiveWallScene.dylib").path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let open = dlsym(library, "lw_scene_open"),
              let close = dlsym(library, "lw_scene_close"),
              let pause = dlsym(library, "lw_scene_pause"),
              let audio = dlsym(library, "lw_scene_audio"),
              let scaling = dlsym(library, "lw_scene_scaling"),
              let framing = dlsym(library, "lw_scene_framing"),
              let pointer = dlsym(library, "lw_scene_pointer"),
              let frames = dlsym(library, "lw_scene_frames"),
              let observeAudio = dlsym(library, "lw_scene_observe_audio"),
              let reactiveAudio = dlsym(library, "lw_scene_audio_reactive"),
              let renderBudget = dlsym(library, "lw_scene_render_budget"),
              let startCapture = dlsym(library, "lw_system_audio_start"),
              let stopCapture = dlsym(library, "lw_system_audio_stop")
        else { dlclose(library); return nil }
        // The renderer runs until app exit. Keep the library loaded for all render threads.
        self.open = unsafeBitCast(open, to: Open.self)
        self.close = unsafeBitCast(close, to: Close.self)
        self.pause = unsafeBitCast(pause, to: Pause.self)
        self.audio = unsafeBitCast(audio, to: Audio.self)
        self.scaling = unsafeBitCast(scaling, to: Scaling.self)
        self.framing = unsafeBitCast(framing, to: Framing.self)
        self.pointer = unsafeBitCast(pointer, to: Pointer.self)
        self.frames = unsafeBitCast(frames, to: Frames.self)
        self.observeAudio = unsafeBitCast(observeAudio, to: ObserveAudio.self)
        self.reactiveAudio = unsafeBitCast(reactiveAudio, to: ReactiveAudio.self)
        self.renderBudget = unsafeBitCast(renderBudget, to: RenderBudget.self)
        self.startCapture = unsafeBitCast(startCapture, to: StartCapture.self)
        self.stopCapture = unsafeBitCast(stopCapture, to: StopCapture.self)
    }
}

final class WorkshopAudioCapture: ObservableObject {
    static let shared = WorkshopAudioCapture()
    private static let preferenceKey = "LiveWallSystemAudioResponse"
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: preferenceKey)
    @Published private(set) var status = ""

    private let queue = DispatchQueue(label: "com.livewall.audio-capture")
    private var listeners: Set<UUID> = []
    private var capture: OpaquePointer?
    private var starting = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        reconcile()
    }

    func setDemand(_ wantsAudio: Bool, for id: UUID) {
        if wantsAudio { listeners.insert(id) } else { listeners.remove(id) }
        reconcile()
    }

    private func reconcile() {
        guard enabled, !listeners.isEmpty else {
            if let capture {
                self.capture = nil
                let pointer = UInt(bitPattern: capture)
                queue.async { WorkshopRenderer.shared?.stopCapture(OpaquePointer(bitPattern: pointer)!) }
            }
            status = enabled ? "等待支持频谱的场景壁纸播放" : ""
            return
        }
        guard !starting, capture == nil, let renderer = WorkshopRenderer.shared else { return }
        starting = true
        status = "正在连接系统音频…"
        queue.async {
            var error: Int32 = 0
            let pointer = UInt(bitPattern: renderer.startCapture(&error))
            DispatchQueue.main.async {
                self.starting = false
                self.capture = OpaquePointer(bitPattern: pointer)
                if !self.enabled || self.listeners.isEmpty {
                    self.reconcile()
                } else {
                    self.status = pointer == 0
                        ? "无法读取系统音频。请在系统设置的「隐私与安全性」中检查系统音频录制权限，然后重新开启此选项。"
                        : "已连接系统音频"
                }
            }
        }
    }
}

private final class SceneAudioObserver {
    weak var view: SceneWallpaperView?
    init(_ view: SceneWallpaperView) { self.view = view }
}

final class SceneWallpaperView: NSView {
    private let surface = CAMetalLayer()
    private let renderer: WorkshopRenderer
    private var handle: OpaquePointer?
    private var pointerTimer: Timer?
    private var lastPointer: CGPoint?
    private var lastPointerMovement = ProcessInfo.processInfo.systemUptime
    private var readinessTimer: Timer?
    private var readinessDeadline = ProcessInfo.processInfo.systemUptime + 25
    private var pausedAt: TimeInterval?
    private var saveEnergy = false
    private var audioReactive = false
    private var frameRate = 0
    private var renderScale: Double = 1
    private var appliedScaling: ScalingMode
    private var appliedFillPosition = FillPosition.center
    private let isPreview: Bool
    private let audioID = UUID()
    private var needsAudio = false
    private var audioPreference: AnyCancellable?
    var muted: Bool { didSet { updateAudio() } }
    var volume: Float { didSet { updateAudio() } }

    static var rendererAvailable: Bool { WorkshopRenderer.shared != nil }

    init?(scene: WorkshopScene, screen: NSScreen, scaling: ScalingMode, position: FillPosition,
          muted: Bool, volume: Float, frameRate: Int = 0, saveEnergy: Bool = false, previewSize: CGSize? = nil,
          onReady: (() -> Void)? = nil, onLoadFailure: @escaping () -> Void) {
        guard scene.hasAssets, let renderer = WorkshopRenderer.shared else { return nil }
        self.renderer = renderer
        self.muted = muted
        self.volume = volume
        self.isPreview = previewSize != nil
        self.frameRate = frameRate
        self.saveEnergy = saveEnergy
        self.appliedScaling = scaling
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWall/Workshop", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let size = previewSize ?? screen.frame.size
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer = surface
        surface.contentsScale = screen.backingScaleFactor
        surface.backgroundColor = NSColor.black.cgColor
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        handle = renderer.open(Unmanaged.passUnretained(surface).toOpaque(),
                               UInt32(size.width.rounded()), UInt32(size.height.rounded()),
                               screen.backingScaleFactor, display, scene.project.path,
                               scene.assets.path, cache.path, volume, muted, scaling.workshopValue)
        guard let handle else { return nil }
        updateRenderBudget()
        setFillPosition(scaling == .fill ? position : .center)
        let context = Unmanaged.passRetained(SceneAudioObserver(self))
        let result = renderer.observeAudio(handle, { opaque, needed in
            guard let opaque else { return }
            let observer = Unmanaged<SceneAudioObserver>.fromOpaque(opaque).takeUnretainedValue()
            DispatchQueue.main.async { observer.view?.setAudioDemand(needed) }
        }, context.toOpaque(), { opaque in
            if let opaque { Unmanaged<SceneAudioObserver>.fromOpaque(opaque).release() }
        })
        if result != 0 { context.release() }
        audioPreference = WorkshopAudioCapture.shared.$enabled.sink { [weak self] enabled in
            guard let self else { return }
            self.setAudioReactive(enabled && self.needsAudio)
        }
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, let handle = self.handle else { timer.invalidate(); return }
            if self.renderer.frames(handle) > 0 {
                timer.invalidate()
                self.readinessTimer = nil
                if let onReady {
                    onReady()
                } else {
                    NSLog("LiveWall scene ready: %@", scene.project.deletingLastPathComponent().lastPathComponent)
                }
            } else if ProcessInfo.processInfo.systemUptime >= self.readinessDeadline {
                timer.invalidate()
                self.readinessTimer = nil
                onLoadFailure()
            }
        }
        readinessTimer?.tolerance = 0.1
        startPointerTimer()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        pointerTimer?.invalidate()
        readinessTimer?.invalidate()
        audioPreference?.cancel()
        WorkshopAudioCapture.shared.setDemand(false, for: audioID)
        if let handle { renderer.close(handle) }
    }

    func setPaused(_ paused: Bool) {
        guard (pausedAt != nil) != paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if paused {
            pausedAt = now
            readinessTimer?.fireDate = .distantFuture
            pointerTimer?.invalidate()
            pointerTimer = nil
            lastPointer = nil
        } else if let pausedAt {
            self.pausedAt = nil
            readinessDeadline += now - pausedAt
            readinessTimer?.fireDate = Date().addingTimeInterval(0.5)
            startPointerTimer()
        }
        if let handle { renderer.pause(handle, paused) }
        updateAudioDemand()
    }

    private func startPointerTimer(idle: Bool = false) {
        let interval = 1.0 / (idle ? 8 : (saveEnergy ? 20 : 30))
        pointerTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, let handle = self.handle, let window = self.window else { return }
            let area = self.bounds
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let now = ProcessInfo.processInfo.systemUptime
            if area.contains(point) {
                let y = self.isFlipped ? point.y - area.minY : area.maxY - point.y
                let normalized = CGPoint(x: (point.x - area.minX) / area.width, y: y / area.height)
                if normalized != self.lastPointer {
                    self.lastPointer = normalized
                    self.lastPointerMovement = now
                    self.renderer.pointer(handle, normalized.x, normalized.y)
                }
            }
            let shouldIdle = !area.contains(point) || now - self.lastPointerMovement > 0.5
            guard shouldIdle != idle else { return }
            self.pointerTimer?.invalidate()
            self.startPointerTimer(idle: shouldIdle)
        }
        pointerTimer?.tolerance = interval / 5
    }

    func setEnergySaving(_ enabled: Bool) {
        guard saveEnergy != enabled else { return }
        saveEnergy = enabled
        updateRenderBudget()
        if pausedAt == nil {
            pointerTimer?.invalidate()
            startPointerTimer()
        }
    }

    func setFrameRate(_ fps: Int) {
        guard frameRate != fps else { return }
        frameRate = fps
        updateRenderBudget()
    }

    private func updateRenderBudget() {
        guard let handle else { return }
        let automatic = saveEnergy ? (audioReactive ? 30 : 24) : (audioReactive ? 60 : 30)
        let fps = frameRate == 0 ? automatic : frameRate
        let scale = isPreview ? 0.5 : (saveEnergy ? 0.75 : 1)
        renderer.renderBudget(handle, UInt32(fps), scale == renderScale ? 0 : scale)
        renderScale = scale
    }

    private func setAudioReactive(_ enabled: Bool) {
        guard audioReactive != enabled, let handle else { return }
        audioReactive = enabled
        renderer.reactiveAudio(handle, enabled)
        updateRenderBudget()
    }

    fileprivate func setAudioDemand(_ needed: Bool) {
        guard needsAudio != needed else { return }
        needsAudio = needed
        setAudioReactive(needed && WorkshopAudioCapture.shared.enabled)
        updateAudioDemand()
    }

    private func updateAudioDemand() {
        WorkshopAudioCapture.shared.setDemand(needsAudio && pausedAt == nil, for: audioID)
    }

    func setScaling(_ scaling: ScalingMode) {
        guard appliedScaling != scaling else { return }
        appliedScaling = scaling
        if let handle { renderer.scaling(handle, scaling.workshopValue) }
    }

    func setFillPosition(_ position: FillPosition) {
        guard appliedFillPosition != position else { return }
        appliedFillPosition = position
        if let handle { renderer.framing(handle, position.x, position.y) }
    }

    private func updateAudio() {
        if let handle { renderer.audio(handle, muted, volume) }
    }
}

private extension ScalingMode {
    var workshopValue: Int32 {
        // WallpaperScalingMode values in the scene engine.
        switch self {
        case .stretch: return 1
        case .fit: return 2
        case .fill: return 3
        }
    }
}
