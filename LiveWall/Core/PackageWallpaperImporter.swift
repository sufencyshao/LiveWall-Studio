import AVFoundation
import Foundation
import ImageIO

enum PackageWallpaperImporter {
    enum ImportError: LocalizedError {
        case cannotExpand
        case noMedia

        var errorDescription: String? {
            switch self {
            case .cannotExpand: return "无法解包。请选择可读取的 macOS PKG 安装包。"
            case .noMedia: return "安装包内没有找到可用的壁纸图片或视频。"
            }
        }
    }

    static func importMedia(from package: URL, into folder: URL) async throws -> [URL] {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }

        let expanded = temporary.appendingPathComponent("Package", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--expand-full", package.path, expanded.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.cannotExpand }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var candidates: [URL] = []
        var enumerationError: Error?
        let entries = manager.enumerator(at: expanded, includingPropertiesForKeys: Array(keys)) { _, error in
            enumerationError = error
            return false
        }
        while let url = entries?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                entries?.skipDescendants()
                continue
            }
            guard values.isDirectory == true, url.lastPathComponent == "Payload" else { continue }
            let payload = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) { _, error in
                enumerationError = error
                return false
            }
            while let file = payload?.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    payload?.skipDescendants()
                } else if values.isRegularFile == true, MediaKind(url: file) != nil {
                    candidates.append(file)
                }
            }
            entries?.skipDescendants()
        }
        if let enumerationError { throw enumerationError }

        var copied: [URL] = []
        do {
            for source in candidates.sorted(by: { $0.path < $1.path }) {
                guard await isWallpaper(source) else { continue }
                let stem = source.deletingPathExtension().lastPathComponent
                var number = 1
                var destination = folder.appendingPathComponent(source.lastPathComponent)
                while manager.fileExists(atPath: destination.path) {
                    number += 1
                    destination = folder.appendingPathComponent("\(stem) \(number).\(source.pathExtension)")
                }
                try manager.copyItem(at: source, to: destination)
                copied.append(destination)
            }
        } catch {
            for file in copied { try? manager.removeItem(at: file) }
            throw error
        }
        guard !copied.isEmpty else { throw ImportError.noMedia }
        return copied
    }

    private static func isWallpaper(_ url: URL) async -> Bool {
        if MediaKind(url: url)?.isVideo == true {
            let asset = AVURLAsset(url: url)
            guard (try? await asset.load(.isPlayable)) == true else { return false }
            return (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false
        }
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(image) > 0
    }
}
