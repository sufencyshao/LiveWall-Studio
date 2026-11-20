import Foundation
import Darwin

struct LibraryTrashEntry: Codable, Identifiable {
    struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        init?(_ url: URL, directory: Bool) {
            var file = stat()
            guard lstat(url.path, &file) == 0,
                  file.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { return nil }
            device = file.st_dev
            inode = file.st_ino
            birthSeconds = Int64(file.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(file.st_birthtimespec.tv_nsec)
        }
    }

    let path: String
    let rootPath: String
    let isScene: Bool
    let title: String
    let identity: Identity
    let scenePackageIdentity: Identity?
    let projectVideoIdentity: Identity?
    let projectWebIdentity: Identity?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    private var isProject: Bool { isScene || projectVideoIdentity != nil || projectWebIdentity != nil }
    private var target: URL { isProject ? url.deletingLastPathComponent() : url }

    init?(url: URL, root: URL) {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let scene = WorkshopScene(url)
        let video = WorkshopVideo(url)
        let web = WorkshopWeb(url)
        let source = scene?.project ?? video?.project ?? web?.project ?? url
        let isProject = scene != nil || video != nil || web != nil
        let candidate = (isProject ? source.deletingLastPathComponent() : source).standardizedFileURL
        guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == canonicalRoot.path,
              let identity = Identity(candidate, directory: isProject) else { return nil }
        let canonicalTarget = canonicalRoot.appendingPathComponent(candidate.lastPathComponent)
        path = (isProject ? canonicalTarget.appendingPathComponent(source.lastPathComponent) : canonicalTarget).path
        rootPath = canonicalRoot.path
        isScene = scene != nil
        title = scene?.title ?? video?.title ?? web?.title ?? source.lastPathComponent
        self.identity = identity
        scenePackageIdentity = scene.flatMap { _ in
            Identity(candidate.appendingPathComponent("scene.pkg"), directory: false)
        }
        projectVideoIdentity = video.flatMap { Identity($0.file, directory: false) }
        projectWebIdentity = web.flatMap { Identity($0.entry, directory: false) }
        if isScene && scenePackageIdentity == nil { return nil }
        if video != nil && projectVideoIdentity == nil { return nil }
        if web != nil && projectWebIdentity == nil { return nil }
    }

    func deleteOriginal() throws {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard Identity(root, directory: true) != nil,
              root.resolvingSymlinksInPath().path == rootPath,
              target.deletingLastPathComponent().path == rootPath,
              !isProject || url.lastPathComponent.lowercased() == "project.json" else {
            throw LibraryFileError.changedOriginal
        }

        var current = stat()
        if lstat(target.path, &current) != 0 {
            if errno == ENOENT { return }
            throw LibraryFileError.changedOriginal
        }
        guard Identity(target, directory: isProject) == identity else { throw LibraryFileError.changedOriginal }
        if isScene, Identity(target.appendingPathComponent("scene.pkg"), directory: false) != scenePackageIdentity {
            throw LibraryFileError.changedOriginal
        }
        if let projectVideoIdentity {
            guard let file = WorkshopVideo(url)?.file, Identity(file, directory: false) == projectVideoIdentity else {
                throw LibraryFileError.changedOriginal
            }
        }
        if let projectWebIdentity {
            guard let entry = WorkshopWeb(url)?.entry, Identity(entry, directory: false) == projectWebIdentity else {
                throw LibraryFileError.changedOriginal
            }
        }
        try FileManager.default.removeItem(at: target)
    }
}

enum LibraryFileError: LocalizedError {
    case changedOriginal
    case missingFolder
    case unsupported

    var errorDescription: String? {
        switch self {
        case .changedOriginal: "原文件位置或内容已更换"
        case .missingFolder: "壁纸文件夹不存在"
        case .unsupported: "不支持此文件，或壁纸项目不完整"
        }
    }
}

enum LibraryFiles {
    struct ImportResult {
        var urls: [URL] = []
        var failed = 0
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWall", isDirectory: true)
    }

    static func key(for url: URL) -> String {
        let source = url.lastPathComponent.lowercased() == "scene.pkg"
            ? url.deletingLastPathComponent().appendingPathComponent("project.json") : url
        return source.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func projectTitle(for url: URL) -> String? {
        WorkshopScene(url)?.title ?? WorkshopVideo(url)?.title ?? WorkshopWeb(url)?.title
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func importFiles(_ urls: [URL], into folder: URL) async -> ImportResult {
        var result = ImportResult()
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        var seen: Set<String> = []
        for input in urls where input.isFileURL {
            do {
                guard isDirectory(root) else { throw LibraryFileError.missingFolder }
                let source = input.resolvingSymlinksInPath()
                let project = isDirectory(source) ? source.appendingPathComponent("project.json") : source
                if let manifest = WorkshopScene(project)?.project ?? WorkshopVideo(project)?.project ?? WorkshopWeb(project)?.project {
                    let projectFolder = manifest.deletingLastPathComponent()
                    guard seen.insert(projectFolder.path).inserted else { continue }
                    if projectFolder.deletingLastPathComponent().path == root.path {
                        result.urls.append(manifest)
                    } else {
                        guard projectFolder.path != root.path,
                              !root.path.hasPrefix(projectFolder.path + "/") else { throw LibraryFileError.unsupported }
                        let newFolder = uniqueDestination(for: projectFolder, in: root)
                        try copy(projectFolder, to: newFolder, in: root)
                        result.urls.append(newFolder.appendingPathComponent(manifest.lastPathComponent))
                    }
                } else if source.pathExtension.lowercased() == "pkg", source.lastPathComponent.lowercased() != "scene.pkg" {
                    guard seen.insert(source.path).inserted else { continue }
                    result.urls += try await PackageWallpaperImporter.importMedia(from: source, into: root)
                } else if MediaKind(url: source) != nil,
                          (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    guard seen.insert(source.path).inserted else { continue }
                    if source.deletingLastPathComponent().path == root.path {
                        result.urls.append(source)
                    } else {
                        let destination = uniqueDestination(for: source, in: root)
                        try copy(source, to: destination, in: root)
                        result.urls.append(destination)
                    }
                } else {
                    throw LibraryFileError.unsupported
                }
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    private static func copy(_ input: URL, to destination: URL, in root: URL) throws {
        let staging = root.appendingPathComponent(".livewall-import-\(UUID().uuidString)")
        let manager = FileManager.default
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: input, to: staging)
        try manager.moveItem(at: staging, to: destination)
    }

    private static func uniqueDestination(for input: URL, in root: URL) -> URL {
        var result = root.appendingPathComponent(input.lastPathComponent)
        let isFolder = isDirectory(input)
        let base = isFolder ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent
        let ext = isFolder || input.pathExtension.isEmpty ? "" : "." + input.pathExtension
        var number = 2
        while (try? result.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil {
            result = root.appendingPathComponent("\(base) \(number)\(ext)")
            number += 1
        }
        return result
    }
}
