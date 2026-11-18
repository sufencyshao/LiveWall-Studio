import AppKit
import AVFoundation

/// Keeps the video layer clipped to the display while allowing it to pan in Fill.
class PlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var currentItemObserver: NSKeyValueObservation?
    private var sizeObserver: NSKeyValueObservation?

    var gravity: AVLayerVideoGravity = .resizeAspectFill { didSet { needsLayout = true } }
    var fillPosition: FillPosition = .center { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ player: AVPlayer?) {
        currentItemObserver = nil
        sizeObserver = nil
        playerLayer.player = player
        currentItemObserver = player?.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playerLayer.player === player else { return }
                self.sizeObserver = player.currentItem?.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
                }
                self.needsLayout = true
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = playerLayer.player?.currentItem?.presentationSize ?? .zero
        let frame = gravity == .resizeAspectFill
            ? fillPosition.cropFrame(for: size, in: bounds, flipped: isFlipped)
            : bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = gravity
        playerLayer.frame = frame
        CATransaction.commit()
    }
}
