import AppKit

/// Shows a still image (or an animated GIF) as wallpaper, honoring the same
/// fill / fit / stretch modes the video player uses. Stills are drawn by a
/// plain CALayer so "fill" really crops instead of distorting; GIFs need
/// NSImageView to animate.
final class ImageWallpaperView: NSView {
    private let image: NSImage
    private let isAnimated: Bool
    private var imageView: NSImageView?
    private let stillLayer = CALayer()
    private var scaling: ScalingMode
    var fillPosition: FillPosition = .center { didSet { needsLayout = true } }

    init(frame: NSRect, image: NSImage, animated: Bool, scaling: ScalingMode) {
        self.image = image
        self.isAnimated = animated
        self.scaling = scaling
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
        imageView?.animates = !paused
    }

    override func layout() {
        super.layout()
        let frame = scaling == .fill
            ? fillPosition.cropFrame(for: image.size, in: bounds, flipped: isFlipped)
            : bounds
        if let imageView {
            imageView.frame = frame
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillLayer.frame = frame
            CATransaction.commit()
        }
    }
}
