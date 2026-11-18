import SwiftUI

/// The main window: a sidebar (library, playlists, settings) and a detail
/// pane, like Music or Photos.
struct SettingsView: View {
    @ObservedObject var engine: WallpaperEngine
    @ObservedObject var library: LibraryModel

    enum Pane: Hashable {
        case library
        case trash
        case playlist(UUID)
        case displays
        case preferences

        var storage: String {
            switch self {
            case .library: return "library"
            case .trash: return "trash"
            case .playlist(let id): return "playlist:" + id.uuidString
            case .displays: return "displays"
            case .preferences: return "preferences"
            }
        }

        init(storage: String) {
            if storage.hasPrefix("playlist:"), let id = UUID(uuidString: String(storage.dropFirst(9))) {
                self = .playlist(id)
            } else if storage == "displays" {
                self = .displays
            } else if storage == "preferences" {
                self = .preferences
            } else if storage == "trash" {
                self = .trash
            } else {
                self = .library
            }
        }
    }

    /// Remembered across tab switches, window close and relaunch.
    @AppStorage("LiveWallSidebarSelection") private var storedSelection = "library"

    private var selection: Pane? {
        get { Pane(storage: storedSelection) }
        nonmutating set { storedSelection = (newValue ?? .library).storage }
    }

    private var selectionBinding: Binding<Pane?> {
        Binding(get: { selection }, set: { selection = $0 })
    }
    @State private var dropTarget: UUID?
    @State private var sidebarShown = true

    var body: some View {
        GeometryReader { geometry in
        if geometry.size.width < 500 {
            VStack(spacing: 0) {
                HStack {
                    Menu {
                        Button("全部壁纸") { selection = .library }
                        Button("垃圾桶") { selection = .trash }
                        Divider()
                        ForEach(library.data.lists) { list in
                            Button(list.name) { selection = .playlist(list.id) }
                        }
                        Button("新建播放列表") { selection = .playlist(library.createList()) }
                        Divider()
                        Button("显示器") { selection = .displays }
                        Button("偏好设置") { selection = .preferences }
                    } label: { Label("导航", systemImage: "sidebar.left") }
                    .menuStyle(.borderlessButton)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        } else {
        HStack(spacing: 0) {
            if sidebarShown {
                sidebar.frame(width: geometry.size.width < 720 ? 170 : 220)
                Divider()
            }
            VStack(spacing: 0) {
                HStack {
                    Button { sidebarShown.toggle() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.borderless).help("显示或隐藏侧边栏")
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 6)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)

        }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: selectionBinding) {
            SwiftUI.Section("资料库") {
                Label("全部壁纸", systemImage: "photo.on.rectangle.angled")
                    .badge(library.files.count)
                    .tag(Pane.library)
                Label("垃圾桶", systemImage: "trash")
                    .badge(library.data.trash.count)
                    .tag(Pane.trash)
            }

            SwiftUI.Section("播放列表") {
                ForEach(library.data.lists) { list in
                    Label {
                        Text(list.name.isEmpty ? "未命名" : list.name)
                    } icon: {
                        Image(systemName: library.data.active == list.id ? "speaker.wave.2.fill" : "music.note.list")
                            .foregroundStyle(library.data.active == list.id ? Color.accentColor : Color.secondary)
                    }
                    .badge(list.items.count)
                    .tag(Pane.playlist(list.id))
                    .listRowBackground(
                        dropTarget == list.id
                            ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25)).padding(.horizontal, 8)
                            : nil
                    )
                    .dropDestination(for: URL.self) { urls, _ in
                        library.importDroppedFiles(urls, intoPlaylist: list.id)
                    } isTargeted: { targeted in
                        if targeted { dropTarget = list.id } else if dropTarget == list.id { dropTarget = nil }
                    }
                    .contextMenu {
                        if library.data.active == list.id {
                            Button("停止轮换") { library.stop() }
                        } else {
                            Button("播放") { library.start(list.id) }
                        }
                        Divider()
                        Button("删除播放列表", role: .destructive) {
                            if selection == .playlist(list.id) { selection = .library }
                            library.deleteList(list.id)
                        }
                    }
                }

                Button {
                    selection = .playlist(library.createList())
                } label: {
                    Label("新建播放列表", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            SwiftUI.Section("设置") {
                Label("显示器", systemImage: "display.2").tag(Pane.displays)
                Label("偏好设置", systemImage: "gearshape").tag(Pane.preferences)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBar(library: library)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .library {
        case .library:
            LibraryView(model: library, engine: engine, openPlaylist: { selection = .playlist($0) })
        case .trash:
            LibraryTrashView(model: library)
        case .playlist(let id):
            if library.list(id) != nil {
                PlaylistView(model: library, engine: engine, listID: id)
                    .id(id)
            } else {
                LibraryView(model: library, engine: engine, openPlaylist: { selection = .playlist($0) })
            }
        case .displays:
            DisplaysView(engine: engine)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .preferences:
            PreferencesView(engine: engine)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// What's on the desktop right now, pinned to the bottom of the sidebar.
struct NowPlayingBar: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        if let path = library.nowPlayingPath {
            let url = URL(fileURLWithPath: path)
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                MediaThumbnail(url: url, cornerRadius: 8)
                    .frame(height: 100)
                    .clipped()
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("当前壁纸").font(.caption2).foregroundStyle(.secondary)
                        Text(WorkshopScene(url)?.title ?? url.deletingPathExtension().lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if library.data.active != nil {
                        Button { library.next() } label: { Image(systemName: "forward.fill") }
                            .buttonStyle(.borderless)
                            .help("下一个")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}
