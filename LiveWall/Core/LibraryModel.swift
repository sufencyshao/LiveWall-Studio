import AppKit
import Combine
import UniformTypeIdentifiers

// Stored shapes are unchanged from the first library version, so existing
// playlists in UserDefaults ("LiveWallLibraryV1") keep loading.
struct PlaylistItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var seconds: Double = 3600

    var url: URL { URL(fileURLWithPath: path) }
}

struct WallpaperList: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [PlaylistItem] = []
    var random = false
    var repeatOne = false
}

struct LibraryData: Codable {
    var folder = ""
    var lists: [WallpaperList] = []
    var active: UUID? = nil
    var hiddenPaths: Set<String> = []
    var trash: [LibraryTrashEntry] = []

    enum CodingKeys: String, CodingKey { case folder, lists, active, hiddenPaths, trash }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        lists = try c.decodeIfPresent([WallpaperList].self, forKey: .lists) ?? []
        active = try c.decodeIfPresent(UUID.self, forKey: .active)
        hiddenPaths = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenPaths) ?? []
        trash = try c.decodeIfPresent([LibraryTrashEntry].self, forKey: .trash) ?? []
    }
}

/// The wallpaper folder, the playlists, and the timer that rotates through
/// the active playlist. Owned by the app delegate so a playlist keeps
/// rotating even when the settings window has never been opened.
final class LibraryModel: ObservableObject {
    @Published var data: LibraryData { didSet { save() } }
    @Published private(set) var files: [URL] = []
    @Published private(set) var message = ""
    @Published private(set) var importingPackage = false
    @Published private(set) var folderAvailable = false
    @Published private(set) var clearingTrash = false
    /// The file currently on the desktop (as far as the library knows).
    @Published private(set) var nowPlayingPath: String?
    /// Position inside the active playlist.
    @Published private(set) var playingIndex = 0
    /// When the active playlist will switch to its next item.
    @Published private(set) var nextSwitch: Date?
    @Published private(set) var isPaused = false

    enum WallpaperSwitch { case previous, next, random }

    private var timer: Timer?
    private var pausedRemaining: TimeInterval?
    private var messageClear: DispatchWorkItem?
    private weak var engine: WallpaperEngine?

    private let key = "LiveWallLibraryV1"
    private let indexKey = "LiveWallPlaylistIndexV1"
    private var modificationDates: [URL: Date] = [:]

    init(engine: WallpaperEngine) {
        self.engine = engine
        let savedLibrary = UserDefaults.standard.data(forKey: key)
        data = savedLibrary
            .flatMap { try? JSONDecoder().decode(LibraryData.self, from: $0) } ?? LibraryData()
        if savedLibrary == nil {
            let folder = LibraryFiles.defaultFolder
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                data.folder = folder.path
            } catch {
                flash("无法创建默认壁纸文件夹：\(error.localizedDescription)")
            }
            save()
        }

        if !UserDefaults.standard.bool(forKey: "LiveWallMinutesMigrationV1") {
            for i in data.lists.indices {
                for j in data.lists[i].items.indices where data.lists[i].items[j].seconds == 60 {
                    data.lists[i].items[j].seconds = 3600
                }
            }
            UserDefaults.standard.set(true, forKey: "LiveWallMinutesMigrationV1")
        }

        nowPlayingPath = engine.displayStates.first?.videoURL?.path
        refresh()

        if let active = data.active {
            let saved = UserDefaults.standard.integer(forKey: indexKey)
            DispatchQueue.main.async { [weak self] in self?.start(active, at: saved) }
        }
    }

    // MARK: - Folder

    func save() {
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    func chooseFolder() {
        guard !importingPackage, !clearingTrash else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择存放壁纸（视频或图片）的文件夹"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            data.folder = url.path
            refresh()
        }
    }

    func createFolder() {
        guard !importingPackage, !clearingTrash else { return }
        let panel = NSSavePanel()
        panel.prompt = "创建"
        panel.nameFieldStringValue = "LiveWall"
        panel.directoryURL = LibraryFiles.defaultFolder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            data.folder = url.path
            refresh()
        } catch {
            flash("无法创建文件夹：\(error.localizedDescription)")
        }
    }

    @MainActor
    func choosePackage() {
        guard !importingPackage else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg") ?? .package]
        panel.prompt = "导入"
        panel.message = "选择 PKG 安装包或创意工坊场景包"
        guard panel.runModal() == .OK, let package = panel.url else { return }
        if !folderAvailable { chooseFolder() }
        _ = importDroppedFiles([package])
    }

    @MainActor @discardableResult
    func importDroppedFiles(_ urls: [URL], intoPlaylist listID: UUID? = nil) -> Bool {
        guard !importingPackage, !clearingTrash, urls.contains(where: \.isFileURL) else { return false }
        guard folderAvailable else {
            flash("请先选择或创建壁纸文件夹。")
            return false
        }
        let folder = URL(fileURLWithPath: data.folder, isDirectory: true)
        importingPackage = true
        Task {
            defer { importingPackage = false }
            let result = await Task.detached(priority: .userInitiated) {
                await LibraryFiles.importFiles(urls, into: folder)
            }.value
            refresh()
            let available = result.urls.filter { !isInTrash($0) }
            if let listID { add(available, to: listID) }
            if result.failed > 0 {
                flash("已处理 \(available.count) 个壁纸，\(result.failed) 个文件无法导入。")
            } else if listID == nil {
                flash(available.isEmpty ? "没有可导入的壁纸。" : "已将 \(available.count) 个壁纸放入壁纸库。")
            }
        }
        return true
    }

    func refresh(report: Bool = false) {
        folderAvailable = !data.folder.isEmpty && LibraryFiles.isDirectory(URL(fileURLWithPath: data.folder))
        guard folderAvailable else {
            files = []
            modificationDates = [:]
            if report { flash("找不到壁纸文件夹，请选择已有文件夹或创建新的。") }
            return
        }
        let trashed = Set(data.trash.map(\.path))
        do {
            let found = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: data.folder),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let scenes = found.compactMap { folder -> URL? in
                let project = folder.appendingPathComponent("project.json")
                guard folder.lastPathComponent != "assets",
                      WorkshopScene(project) != nil, !data.hiddenPaths.contains(project.path),
                      !trashed.contains(LibraryFiles.key(for: project)) else { return nil }
                return project
            }
            let media = found
                .filter { url in
                    !data.hiddenPaths.contains(url.path)
                        && MediaKind.allExtensions.contains(url.pathExtension.lowercased())
                        && !trashed.contains(LibraryFiles.key(for: url))
                        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
            modificationDates = Dictionary(uniqueKeysWithValues: (media + scenes).map { url in
                let source = url.lastPathComponent == "project.json"
                    ? url.deletingLastPathComponent().appendingPathComponent("scene.pkg") : url
                let date = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return (url, date)
            })
            files = (media + scenes).sorted {
                let lhs = WorkshopScene($0)?.title ?? $0.lastPathComponent
                let rhs = WorkshopScene($1)?.title ?? $1.lastPathComponent
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            if report { flash("已刷新，共 \(files.count) 个壁纸。") }
        } catch {
            files = []
            flash("无法读取壁纸文件夹：\(error.localizedDescription)")
        }
    }

    func filesByModificationDate(newestFirst: Bool) -> [URL] {
        files.enumerated().sorted {
            let left = modificationDates[$0.element] ?? .distantPast
            let right = modificationDates[$1.element] ?? .distantPast
            if left == right { return $0.offset < $1.offset }
            return newestFirst ? left > right : left < right
        }.map(\.element)
    }

    func isInTrash(_ url: URL) -> Bool {
        guard !data.trash.isEmpty else { return false }
        let key = LibraryFiles.key(for: url)
        return data.trash.contains { $0.path == key }
    }

    func moveToTrash(_ url: URL) {
        guard !clearingTrash, files.contains(url), !isInTrash(url),
              let entry = LibraryTrashEntry(url: url, root: URL(fileURLWithPath: data.folder)) else {
            flash("无法将这个壁纸移入垃圾桶。")
            return
        }
        data.trash.append(entry)
        detachPlayingWallpapers([entry.path])
        refresh()
        flash("已移入垃圾桶，原文件仍保留。")
    }

    func restoreFromTrash(_ entry: LibraryTrashEntry) {
        guard !clearingTrash else { return }
        data.trash.removeAll { $0.id == entry.id }
        refresh()
        flash("已将「\(entry.title)」移出垃圾桶。")
    }

    @MainActor
    func clearTrash() {
        guard !clearingTrash, !importingPackage, !data.trash.isEmpty else { return }
        let entries = data.trash
        clearingTrash = true
        Task {
            let deleted = await Task.detached(priority: .userInitiated) {
                Set(entries.compactMap { entry in
                    do { try entry.deleteOriginal(); return entry.path }
                    catch { return nil }
                } as [String])
            }.value
            detachPlayingWallpapers(deleted)
            let playingItem = data.active.flatMap { list($0)?.items }
                .flatMap { $0.indices.contains(playingIndex) ? $0[playingIndex].id : nil }
            var updated = data
            for index in updated.lists.indices {
                updated.lists[index].items.removeAll { deleted.contains(LibraryFiles.key(for: $0.url)) }
            }
            updated.trash.removeAll { deleted.contains($0.path) }
            data = updated
            if let id = data.active, let playingItem,
               let index = list(id)?.items.firstIndex(where: { $0.id == playingItem }) {
                playingIndex = index
                UserDefaults.standard.set(index, forKey: indexKey)
            } else if data.active != nil {
                stop()
            }
            clearingTrash = false
            refresh()
            let skipped = entries.count - deleted.count
            flash(skipped == 0 ? "垃圾桶已清空。" : "已清理 \(deleted.count) 项，\(skipped) 项因原文件已更换、文件夹不可用或权限不足而保留。")
        }
    }

    private func detachPlayingWallpapers(_ paths: Set<String>) {
        guard let engine else { return }
        if let id = data.active, let items = list(id)?.items, items.indices.contains(playingIndex),
           paths.contains(LibraryFiles.key(for: items[playingIndex].url)) { stop() }
        for display in engine.displayStates {
            if let url = display.videoURL, paths.contains(LibraryFiles.key(for: url)) {
                engine.removeVideo(from: display.id)
            }
        }
        nowPlayingPath = engine.displayStates.compactMap(\.videoURL).first?.path
    }

    func restoreHidden() {
        data.hiddenPaths.removeAll()
        refresh()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Playlists

    @discardableResult
    func createList(named name: String? = nil, with urls: [URL] = []) -> UUID {
        var n = 1
        var candidate = name ?? "新播放列表"
        while data.lists.contains(where: { $0.name == candidate }) {
            n += 1
            candidate = "\(name ?? "新播放列表") \(n)"
        }
        let list = WallpaperList(name: candidate, items: urls.map { PlaylistItem(path: $0.path) })
        data.lists.append(list)
        return list.id
    }

    func deleteList(_ id: UUID) {
        if data.active == id { stop() }
        data.lists.removeAll { $0.id == id }
    }

    func list(_ id: UUID) -> WallpaperList? {
        data.lists.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        data.lists.firstIndex { $0.id == id }
    }

    /// Adds references to supported wallpapers and returns the number added.
    @discardableResult
    func add(_ urls: [URL], to listID: UUID) -> Int {
        guard let i = index(of: listID) else { return 0 }
        let usable = urls.filter { MediaKind(url: $0) != nil && !isInTrash($0) }
        let defaultSeconds = data.lists[i].items.last?.seconds ?? 3600
        data.lists[i].items.append(contentsOf: usable.map { PlaylistItem(path: $0.path, seconds: defaultSeconds) })
        if !usable.isEmpty {
            flash("已将 \(usable.count) 个壁纸加入「\(data.lists[i].name)」")
        }
        return usable.count
    }

    func removeItem(_ itemID: UUID, from listID: UUID) {
        guard let i = index(of: listID) else { return }
        let wasPlaying = data.active == listID && data.lists[i].items.indices.contains(playingIndex)
            && data.lists[i].items[playingIndex].id == itemID
        data.lists[i].items.removeAll { $0.id == itemID }
        if data.active == listID {
            if data.lists[i].items.isEmpty { stop() }
            else if wasPlaying { playCurrent() }
        }
    }

    /// Sets the same duration on every item of a playlist.
    func setAllDurations(minutes: Double, in listID: UUID) {
        guard let i = index(of: listID) else { return }
        for j in data.lists[i].items.indices {
            data.lists[i].items[j].seconds = max(60, minutes * 60)
        }
        playbackOptionsChanged(for: listID)
    }

    // MARK: - Playback

    func use(_ url: URL) {
        guard !isInTrash(url) else { flash("请先从垃圾桶恢复此壁纸。"); return }
        stop()
        apply(url)
        resumePlayback()
    }

    func start(_ id: UUID, at position: Int = 0) {
        guard let list = list(id), !list.items.isEmpty else {
            flash("请先向播放列表添加壁纸。")
            return
        }
        data.active = id
        playingIndex = min(max(0, position), list.items.count - 1)
        resumePlayback()
        playCurrent()
    }

    func playItem(listID: UUID, itemID: UUID) {
        guard let list = list(listID),
              let position = list.items.firstIndex(where: { $0.id == itemID }) else { return }
        guard !isInTrash(list.items[position].url) else { flash("请先从垃圾桶恢复此壁纸。"); return }
        start(listID, at: position)
    }

    func next() { switchWallpaper(.next) }
    func previous() { switchWallpaper(.previous) }

    func switchWallpaper(_ direction: WallpaperSwitch, in listID: UUID? = nil) {
        let id = listID ?? data.active
        let urls = id.flatMap { list($0)?.items.map(\.url) } ?? files
        let available = urls.indices.filter { canPlay(urls[$0]) }
        guard let first = available.first, let last = available.last else { return }
        let rotating = id != nil && id == data.active
        let currentPath = engine?.displayStates.first { $0.videoURL != nil }?.videoURL?.path ?? nowPlayingPath
        let current = rotating ? playingIndex : urls.firstIndex { $0.path == currentPath }
        let selected: Int
        switch direction {
        case .next:
            selected = current.flatMap { index in available.first { $0 > index } } ?? first
        case .previous:
            selected = current.flatMap { index in available.last { $0 < index } } ?? last
        case .random:
            selected = available.filter { urls[$0].path != currentPath }.randomElement() ?? first
        }
        if rotating {
            playingIndex = selected
            resumePlayback()
            playCurrent()
        } else {
            use(urls[selected])
        }
    }

    var canSwitchWallpaper: Bool {
        if let id = data.active { return list(id)?.items.contains { canPlay($0.url) } ?? false }
        return !files.isEmpty
    }

    func togglePause() {
        if isPaused {
            let remaining = pausedRemaining
            resumePlayback()
            rescheduleTimer(remaining: remaining)
        } else {
            pausedRemaining = nextSwitch.map { max(0, $0.timeIntervalSinceNow) }
            timer?.invalidate()
            timer = nil
            nextSwitch = nil
            isPaused = true
            engine?.setManuallyPaused(true)
        }
    }

    private func resumePlayback() {
        pausedRemaining = nil
        guard isPaused else { return }
        isPaused = false
        engine?.setManuallyPaused(false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        nextSwitch = nil
        pausedRemaining = nil
        data.active = nil
    }

    func isPlaying(listID: UUID, itemID: UUID) -> Bool {
        guard data.active == listID, let list = list(listID),
              list.items.indices.contains(playingIndex) else { return false }
        return list.items[playingIndex].id == itemID
    }

    private func playCurrent() {
        timer?.invalidate()
        timer = nil
        guard let id = data.active, let list = list(id), !list.items.isEmpty else {
            stop()
            return
        }
        let original = min(playingIndex, list.items.count - 1)
        let available = list.items.indices.filter { canPlay(list.items[$0].url) }
        guard let first = available.first else {
            stop()
            flash("播放列表里没有可播放的壁纸。")
            return
        }
        playingIndex = available.first(where: { $0 >= original }) ?? first
        UserDefaults.standard.set(playingIndex, forKey: indexKey)
        apply(list.items[playingIndex].url)
        rescheduleTimer()
    }

    private func rescheduleTimer(remaining: TimeInterval? = nil) {
        timer?.invalidate()
        timer = nil
        nextSwitch = nil
        guard !isPaused, let id = data.active, let list = list(id),
              list.items.indices.contains(playingIndex), !list.repeatOne else { return }
        let interval = remaining ?? max(60, list.items[playingIndex].seconds)
        let fire = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.data.active == id else { return }
            self.switchWallpaper(self.list(id)?.random == true ? .random : .next)
        }
        // .common so the switch still happens while a menu is open.
        RunLoop.main.add(fire, forMode: .common)
        timer = fire
        nextSwitch = Date().addingTimeInterval(interval)
    }

    /// Call after toggling "repeat one" so the timer matches.
    func playbackOptionsChanged(for listID: UUID) {
        if data.active == listID {
            pausedRemaining = nil
            rescheduleTimer()
        }
    }

    private func apply(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            flash("找不到文件：\(url.lastPathComponent)")
            return
        }
        if let scene = WorkshopScene(url) {
            guard scene.hasAssets else {
                flash("缺少场景资源。请把已购 Wallpaper Engine 的 assets 文件夹放进壁纸库根目录。")
                return
            }
            guard SceneWallpaperView.rendererAvailable else {
                flash("场景渲染引擎未能载入。")
                return
            }
        }
        guard let engine else { return }
        for display in engine.displayStates {
            engine.assignVideo(url: url, to: display.id)
        }
        nowPlayingPath = url.path
    }

    private func canPlay(_ url: URL) -> Bool {
        !isInTrash(url) && FileManager.default.fileExists(atPath: url.path)
    }

    private func flash(_ text: String) {
        message = text
        messageClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.message = "" }
        messageClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
