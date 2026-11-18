import AVFoundation

/// The three ways a video can be scaled to fill its display.
enum ScalingMode: String, Codable, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fill: return "填充"
        case .fit: return "适应"
        case .stretch: return "拉伸"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        }
    }
}

/// Position within the excess image, with Y measured from the top.
struct FillPosition: Codable, Equatable {
    var x: Double = 0.5
    var y: Double = 0.5

    static let center = Self()

    func cropFrame(for content: CGSize, in bounds: CGRect, flipped: Bool = false) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = max(bounds.width / content.width, bounds.height / content.height)
        let width = content.width * scale
        let height = content.height * scale
        return CGRect(x: bounds.minX + (bounds.width - width) * x,
                      y: bounds.minY + (bounds.height - height) * (flipped ? y : 1 - y),
                      width: width, height: height)
    }
}
