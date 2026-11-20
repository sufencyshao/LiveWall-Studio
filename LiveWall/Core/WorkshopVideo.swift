import Foundation

struct WorkshopVideo {
    private struct Manifest: Decodable {
        let type: String
        let file: String?
        let title: String?
        let preview: String?
    }

    let project: URL
    let file: URL
    let title: String
    let poster: URL?

    init?(_ project: URL) {
        guard project.lastPathComponent.lowercased() == "project.json",
              let data = try? Data(contentsOf: project),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.type.lowercased() == "video", let name = manifest.file else { return nil }
        let folder = project.deletingLastPathComponent()
        guard let file = WorkshopProjectFile.resolve(name, in: folder),
              MediaKind.videoExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        self.project = project
        self.file = file
        self.title = manifest.title.flatMap { $0.isEmpty ? nil : $0 } ?? file.deletingPathExtension().lastPathComponent
        self.poster = manifest.preview.flatMap { WorkshopProjectFile.resolve($0, in: folder) }
    }
}

enum WorkshopProjectFile {
    static func resolve(_ name: String, in folder: URL) -> URL? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else { return nil }
        let file = parts.reduce(folder) { $0.appendingPathComponent($1) }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base + "/"),
              (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return resolved
    }
}
