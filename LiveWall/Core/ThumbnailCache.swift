import AppKit
import AVFoundation
import CryptoKit
import ImageIO

/// What kind of file a wallpaper is.
enum MediaKind {
    case video, image, animatedImage, scene, web

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
    static var allExtensions: Set<String> { videoExtensions.union(imageExtensions) }

    init?(url: URL) {
        if WorkshopScene(url) != nil { self = .scene; return }
        if WorkshopVideo(url) != nil { self = .video; return }
        if WorkshopWeb(url) != nil { self = .web; return }
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) { self = .video }
        else if ext == "gif" { self = .animatedImage }
        else if Self.imageExtensions.contains(ext) { self = .image }
        else { return nil }
    }

    var isVideo: Bool { self == .video }

    static func videoFile(for url: URL) -> URL? {
        if videoExtensions.contains(url.pathExtension.lowercased()) { return url }
        return WorkshopVideo(url)?.file
    }
}

/// Grabs a preview frame from a video or downsamples an image, and caches it
/// both in memory and on disk (~/Library/Caches/LiveWall/Thumbnails), so a
/// library full of multi-hundred-MB videos only has to be decoded once.
/// Generation runs on a small background queue so opening a big folder
/// doesn't spin up dozens of decoders at once.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private var durations: [URL: Double] = [:]
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    /// Cached image only — never starts any work. Lets views draw instantly
    /// when scrolling back to something already seen.
    func cachedThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let running = inFlight[url] { return await running.value }

        let task = Task<NSImage?, Never> {
            await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                ThumbnailGenerator.workQueue.addOperation {
                    continuation.resume(returning: ThumbnailGenerator.generate(url: url))
                }
            }
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Video length in seconds, nil for images or unreadable files.
    func duration(for url: URL) async -> Double? {
        guard let file = MediaKind.videoFile(for: url) else { return nil }
        if let known = durations[url] { return known }
        let asset = AVURLAsset(url: file)
        guard let seconds = try? await asset.load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        durations[url] = seconds
        return seconds
    }

}

/// The actual decoding, kept off the main actor.
enum ThumbnailGenerator {
    static let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()

    static let diskDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LiveWall/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()


    static func diskKey(for url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let stamp = "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)|v2"
        let hash = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(hash).appendingPathExtension("jpg")
    }

    static func generate(url: URL) -> NSImage? {
        let diskURL = diskKey(for: url)
        if let diskURL, let image = NSImage(contentsOf: diskURL) { return image }

        let cgImage: CGImage?
        switch MediaKind(url: url) {
        case .video:
            cgImage = WorkshopVideo(url)?.poster.flatMap { imageThumbnail(url: $0) }
                ?? MediaKind.videoFile(for: url).flatMap { videoFrame(url: $0) }
        case .image, .animatedImage:
            cgImage = imageThumbnail(url: url)
        case .scene:
            cgImage = WorkshopScene(url)?.poster.flatMap { imageThumbnail(url: $0) }
        case .web:
            cgImage = WorkshopWeb(url)?.poster.flatMap { imageThumbnail(url: $0) }
        case nil:
            cgImage = nil
        }
        guard let cgImage else { return nil }

        if let diskURL {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpeg.write(to: diskURL, options: .atomic)
            }
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func videoFrame(url: URL) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        // Lots of videos fade in from black, so 1s in is often a black
        // frame. ~15% of the way in is much more representative.
        var candidates: [CMTime] = []
        let seconds = asset.duration.seconds
        if seconds.isFinite, seconds > 2 {
            candidates.append(CMTime(seconds: min(seconds * 0.15, 30), preferredTimescale: 600))
        }
        candidates += [CMTime(seconds: 1, preferredTimescale: 600), .zero]
        for time in candidates {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return cgImage
            }
        }
        return nil
    }

    static func imageThumbnail(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
