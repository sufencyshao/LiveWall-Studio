import AppKit
import Combine

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

    enum CodingKeys: String, CodingKey { case folder, lists, active, hiddenPaths }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        lists = try c.decodeIfPresent([WallpaperList].self, forKey: .lists) ?? []
        active = try c.decodeIfPresent(UUID.self, forKey: .active)
        hiddenPaths = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenPaths) ?? []
    }
}

/// The wallpaper folder, the playlists, and the timer that rotates through
/// the active playlist. Owned by the app delegate so a playlist keeps
/// rotating even when the settings window has never been opened.
final class LibraryModel: ObservableObject {
    @Published var data: LibraryData { didSet { save() } }
    @Published private(set) var files: [URL] = []
    @Published private(set) var message = ""
    /// The file currently on the desktop (as far as the library knows).
    @Published private(set) var nowPlayingPath: String?
    /// Position inside the active playlist.
    @Published private(set) var playingIndex = 0
    /// When the active playlist will switch to its next item.
    @Published private(set) var nextSwitch: Date?

    private var timer: Timer?
    private var messageClear: DispatchWorkItem?
    private weak var engine: WallpaperEngine?

    private let key = "LiveWallLibraryV1"
    private let indexKey = "LiveWallPlaylistIndexV1"

    init(engine: WallpaperEngine) {
        self.engine = engine
        data = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(LibraryData.self, from: $0) } ?? LibraryData()

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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择存放壁纸（视频或图片）的文件夹"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            data.folder = url.path
            refresh()
        }
    }

    func refresh() {
        guard !data.folder.isEmpty else { files = []; return }
        let extensions = MediaKind.allExtensions
        do {
            let found = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: data.folder),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            files = found
                .filter { url in
                    !data.hiddenPaths.contains(url.path)
                        && extensions.contains(url.pathExtension.lowercased())
                        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            files = []
            flash("无法读取壁纸文件夹：\(error.localizedDescription)")
        }
    }

    func hide(_ url: URL) {
        data.hiddenPaths.insert(url.path)
        refresh()
        flash("已从壁纸库移除「\(url.lastPathComponent)」，原文件仍保留。")
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

    /// Adds media files to a playlist, skipping anything that isn't a
    /// supported image or video. Returns how many were added.
    @discardableResult
    func add(_ urls: [URL], to listID: UUID) -> Int {
        guard let i = index(of: listID) else { return 0 }
        let usable = urls.filter { MediaKind(url: $0) != nil }
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
        if data.active == listID { rescheduleTimer() }
    }

    // MARK: - Playback

    func use(_ url: URL) {
        stop()
        apply(url)
    }

    func start(_ id: UUID, at position: Int = 0) {
        guard let list = list(id), !list.items.isEmpty else {
            flash("请先向播放列表添加壁纸。")
            return
        }
        data.active = id
        playingIndex = min(max(0, position), list.items.count - 1)
        playCurrent()
    }

    func playItem(listID: UUID, itemID: UUID) {
        guard let list = list(listID),
              let position = list.items.firstIndex(where: { $0.id == itemID }) else { return }
        start(listID, at: position)
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    func stop() {
        timer?.invalidate()
        timer = nil
        nextSwitch = nil
        data.active = nil
    }

    func isPlaying(listID: UUID, itemID: UUID) -> Bool {
        guard data.active == listID, let list = list(listID),
              list.items.indices.contains(playingIndex) else { return false }
        return list.items[playingIndex].id == itemID
    }

    private func step(by delta: Int) {
        guard let id = data.active, let list = list(id), !list.items.isEmpty else { return }
        if list.random && delta > 0 {
            playingIndex = randomIndex(count: list.items.count)
        } else {
            playingIndex = (playingIndex + delta + list.items.count) % list.items.count
        }
        playCurrent()
    }

    private func randomIndex(count: Int) -> Int {
        guard count > 1 else { return 0 }
        var candidate = playingIndex
        while candidate == playingIndex { candidate = Int.random(in: 0..<count) }
        return candidate
    }

    private func playCurrent() {
        timer?.invalidate()
        timer = nil
        guard let id = data.active, let list = list(id), !list.items.isEmpty else {
            stop()
            return
        }
        playingIndex = min(playingIndex, list.items.count - 1)
        UserDefaults.standard.set(playingIndex, forKey: indexKey)
        apply(list.items[playingIndex].url)
        rescheduleTimer()
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        nextSwitch = nil
        guard let id = data.active, let list = list(id),
              list.items.indices.contains(playingIndex), !list.repeatOne else { return }
        let interval = max(60, list.items[playingIndex].seconds)
        let fire = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.next()
        }
        // .common so the switch still happens while a menu is open.
        RunLoop.main.add(fire, forMode: .common)
        timer = fire
        nextSwitch = Date().addingTimeInterval(interval)
    }

    /// Call after toggling "repeat one" so the timer matches.
    func playbackOptionsChanged(for listID: UUID) {
        if data.active == listID { rescheduleTimer() }
    }

    private func apply(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            flash("找不到文件：\(url.lastPathComponent)")
            return
        }
        guard let engine else { return }
        for display in engine.displayStates {
            engine.assignVideo(url: url, to: display.id)
        }
        nowPlayingPath = url.path
    }

    private func flash(_ text: String) {
        message = text
        messageClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.message = "" }
        messageClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
