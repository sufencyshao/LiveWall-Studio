import AppKit
import ImageIO

/// Shows a still image (or an animated GIF) as wallpaper, honoring the same
/// fill / fit / stretch modes the video player uses. Stills are drawn by a
/// plain CALayer so "fill" really crops instead of distorting; GIFs need
/// NSImageView to animate.
final class ImageWallpaperView: NSView {
    private let image: NSImage
    private let isAnimated: Bool
    private var imageView: NSImageView?
    private let stillLayer = CALayer()
    private let sourceURL: URL?
    private var gifSource: CGImageSource?
    private var frameEnds: [TimeInterval] = []
    private var gifTimer: Timer?
    private var frameRate = 0
    private var shownFrame: Int?
    private var paused = false
    private var elapsed: TimeInterval = 0
    private var startedAt: TimeInterval?
    private var scaling: ScalingMode
    var fillPosition: FillPosition = .center { didSet { needsLayout = true } }

    init(frame: NSRect, image: NSImage, animated: Bool, scaling: ScalingMode, sourceURL: URL? = nil) {
        self.image = image
        self.isAnimated = animated
        self.scaling = scaling
        self.sourceURL = sourceURL
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]

        if animated {
            let view = NSImageView(frame: bounds)
            view.animates = true
            view.image = image
            addSubview(view)
            imageView = view
        } else {
            stillLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? image
            layer?.addSublayer(stillLayer)
        }
        apply(scaling)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ scaling: ScalingMode) {
        self.scaling = scaling
        imageView?.imageScaling = scaling == .stretch ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
        switch scaling {
        case .fill: stillLayer.contentsGravity = .resizeAspectFill
        case .fit: stillLayer.contentsGravity = .resizeAspect
        case .stretch: stillLayer.contentsGravity = .resize
        }
        needsLayout = true
    }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        if gifSource == nil {
            imageView?.animates = !paused
        } else if paused {
            if let startedAt { elapsed += ProcessInfo.processInfo.systemUptime - startedAt }
            startedAt = nil
            gifTimer?.invalidate()
            gifTimer = nil
        } else {
            startedAt = ProcessInfo.processInfo.systemUptime
            updateGIF()
        }
    }

    func setFrameRate(_ fps: Int) {
        guard isAnimated, frameRate != fps else { return }
        frameRate = fps
        gifTimer?.invalidate()
        gifTimer = nil
        if fps == 0 {
            gifSource = nil
            stillLayer.removeFromSuperlayer()
            stillLayer.contents = nil
            imageView?.isHidden = false
            imageView?.animates = !paused
            return
        }
        if gifSource == nil {
            guard let sourceURL, let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  CGImageSourceGetCount(source) > 1 else { return }
            var total: TimeInterval = 0
            frameEnds = (0..<CGImageSourceGetCount(source)).map { index in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Double]
                let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime] ?? 0.1
                total += delay < 0.011 || !delay.isFinite ? 0.1 : delay
                return total
            }
            gifSource = source
            elapsed = 0
            startedAt = paused ? nil : ProcessInfo.processInfo.systemUptime
            shownFrame = nil
            imageView?.animates = false
            imageView?.isHidden = true
            layer?.addSublayer(stillLayer)
            needsLayout = true
        }
        updateGIF()
    }

    private func updateGIF() {
        guard let gifSource, let duration = frameEnds.last else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let position = (elapsed + (startedAt.map { now - $0 } ?? 0)).truncatingRemainder(dividingBy: duration)
        var lower = 0
        var upper = frameEnds.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if frameEnds[middle] > position { upper = middle }
            else { lower = middle + 1 }
        }
        let frame = lower
        if shownFrame != frame, let image = CGImageSourceCreateImageAtIndex(gifSource, frame, nil) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillLayer.contents = image
            CATransaction.commit()
            shownFrame = frame
        }
        guard !paused else { return }
        let interval = max(1.0 / Double(frameRate), frameEnds[frame] - position)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.updateGIF() }
        timer.tolerance = min(0.01, interval / 8)
        RunLoop.main.add(timer, forMode: .common)
        gifTimer = timer
    }

    deinit { gifTimer?.invalidate() }

    override func layout() {
        super.layout()
        let frame = scaling == .fill
            ? fillPosition.cropFrame(for: image.size, in: bounds, flipped: isFlipped)
            : bounds
        imageView?.frame = frame
        if imageView == nil || gifSource != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillLayer.frame = frame
            CATransaction.commit()
        }
    }
}
