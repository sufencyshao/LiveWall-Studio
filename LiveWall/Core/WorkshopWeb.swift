import Foundation

struct WorkshopWeb {
    let project: URL
    let entry: URL
    let folder: URL
    let title: String
    let poster: URL?
    let properties: [String: Any]

    init?(_ project: URL) {
        guard project.lastPathComponent.lowercased() == "project.json",
              let data = try? Data(contentsOf: project),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (manifest["type"] as? String)?.lowercased() == "web",
              let file = manifest["file"] as? String else { return nil }
        let folder = project.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard let entry = WorkshopProjectFile.resolve(file, in: folder),
              ["html", "htm"].contains(entry.pathExtension.lowercased()) else { return nil }
        self.project = project
        self.entry = entry
        self.folder = folder
        self.title = manifest["title"] as? String ?? folder.lastPathComponent
        self.poster = (manifest["preview"] as? String).flatMap { WorkshopProjectFile.resolve($0, in: folder) }
        self.properties = (manifest["general"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    }
}
