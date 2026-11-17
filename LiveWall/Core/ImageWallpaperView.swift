import AppKit

/// Shows a still image (or an animated GIF) as wallpaper, honoring the same
/// fill / fit / stretch modes the video player uses. Stills are drawn by a
/// plain CALayer so "fill" really crops instead of distorting; GIFs need
/// NSImageView to animate.
final class ImageWallpaperView: NSView {
    private let image: NSImage
    private let isAnimated: Bool
    private var imageView: NSImageView?
    private var scaling: ScalingMode

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
            view.autoresizingMask = [.width, .height]
            view.animates = true
            view.image = image
            addSubview(view)
            imageView = view
        } else {
            layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? image
        }
        apply(scaling)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ scaling: ScalingMode) {
        self.scaling = scaling
        if let imageView {
            // NSImageView has no aspect-fill, so for "fill" the view is
            // grown past the window edges and the overflow gets clipped.
            imageView.imageScaling = scaling == .stretch ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
            layoutAnimatedView()
        } else {
            switch scaling {
            case .fill: layer?.contentsGravity = .resizeAspectFill
            case .fit: layer?.contentsGravity = .resizeAspect
            case .stretch: layer?.contentsGravity = .resize
            }
        }
    }

    override func layout() {
        super.layout()
        layoutAnimatedView()
    }

    private func layoutAnimatedView() {
        guard let imageView else { return }
        let size = image.size
        guard scaling == .fill, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            imageView.autoresizingMask = [.width, .height]
            imageView.frame = bounds
            return
        }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let filled = NSSize(width: size.width * scale, height: size.height * scale)
        imageView.autoresizingMask = []
        imageView.frame = NSRect(
            x: (bounds.width - filled.width) / 2,
            y: (bounds.height - filled.height) / 2,
            width: filled.width,
            height: filled.height
        )
    }
}
