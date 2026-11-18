import AppKit
import SwiftUI

/// One wallpaper in a grid: live-on-hover thumbnail, badges, and name.
struct WallpaperCard<Menu: View>: View {
    let url: URL
    let isCurrent: Bool
    var caption: String? = nil
    let onUse: () -> Void
    let onPreview: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaThumbnail(url: url, cornerRadius: 10)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    KindBadge(url: url).padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if isCurrent { NowPlayingTag().padding(6) }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Always visible (faint until hovered) so it's easy to find.
                    HStack(spacing: 6) {
                        if hovering {
                            CardIconButton(symbol: "checkmark", help: "设为壁纸", action: onUse)
                                .transition(.opacity)
                        }
                        CardIconButton(symbol: "eye", help: "大图预览", action: onPreview)
                            .opacity(hovering ? 1 : 0.75)
                    }
                    .padding(6)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isCurrent ? Color.accentColor : Color.primary.opacity(hovering ? 0.25 : 0.08),
                                      lineWidth: isCurrent ? 2.5 : 1)
                }
                .shadow(color: .black.opacity(hovering ? 0.25 : 0.1), radius: hovering ? 8 : 3, y: 2)
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)

            VStack(alignment: .leading, spacing: 1) {
                Text(WorkshopScene(url)?.title ?? url.deletingPathExtension().lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onUse)
        .contextMenu { menu() }
        .help("双击设为壁纸，悬停可预览")
    }
}

struct CardIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.black.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "Add to playlist" submenu shared by grid cards.
struct AddToPlaylistMenu: View {
    @ObservedObject var model: LibraryModel
    let urls: [URL]
    var onCreated: ((UUID) -> Void)? = nil

    var body: some View {
        Menu("加入播放列表") {
            ForEach(model.data.lists) { list in
                Button(list.name) { model.add(urls, to: list.id) }
            }
            if !model.data.lists.isEmpty { Divider() }
            Button("新建播放列表…") {
                let id = model.createList(with: urls)
                onCreated?(id)
            }
        }
    }
}

/// Everything in the wallpaper folder, as a grid of previews.
struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    let engine: WallpaperEngine
    var openPlaylist: (UUID) -> Void = { _ in }

    @AppStorage("LiveWallGridSize") private var tileWidth: Double = 220
    @AppStorage("LiveWallLibrarySort") private var sort: Sort = .nameAscending
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var preview: PreviewTarget?
    @State private var dropTargeted = false

    enum Sort: String, CaseIterable, Identifiable {
        case nameAscending = "名称（升序）"
        case nameDescending = "名称（降序）"
        case newestFirst = "修改时间（最新在前）"
        case oldestFirst = "修改时间（最早在前）"
        var id: String { rawValue }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", video = "视频", image = "图片", scene = "场景"
        var id: String { rawValue }
    }

    private var shown: [URL] {
        let sorted: [URL]
        switch sort {
        case .nameAscending: sorted = model.files
        case .nameDescending: sorted = Array(model.files.reversed())
        case .newestFirst: sorted = model.filesByModificationDate(newestFirst: true)
        case .oldestFirst: sorted = model.filesByModificationDate(newestFirst: false)
        }
        return sorted.filter { url in
            let kind = MediaKind(url: url)
            switch filter {
            case .all: break
            case .video: if kind?.isVideo != true { return false }
            case .image: if kind != .image && kind != .animatedImage { return false }
            case .scene: if kind != .scene { return false }
            }
            return query.isEmpty || (WorkshopScene(url)?.title ?? url.lastPathComponent).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            header
            Divider()
            if !model.folderAvailable {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.data.folder.isEmpty ? "请选择壁纸文件夹" : "找不到壁纸文件夹")
                        .font(.headline)
                    if !model.data.folder.isEmpty {
                        Text(model.data.folder).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    HStack {
                        Button("选择已有文件夹…") { model.chooseFolder() }
                        Button("创建文件夹…") { model.createFolder() }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.files.isEmpty {
                EmptyStateView(
                    symbol: "photo.on.rectangle.angled",
                    title: "文件夹里没有可用的壁纸",
                    detail: "将图片、视频或完整的场景项目拖到这里，即可复制到壁纸文件夹。",
                    button: "换一个文件夹…"
                ) { model.chooseFolder() }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: gridColumns(for: geometry.size.width),
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(shown, id: \.path) { url in
                            WallpaperCard(
                                url: url,
                                isCurrent: model.nowPlayingPath == url.path,
                                onUse: { model.use(url) },
                                onPreview: { preview = PreviewTarget(url: url) }
                            ) {
                                Button("设为壁纸") { model.use(url) }
                                Button("大图预览") { preview = PreviewTarget(url: url) }
                                WallpaperScalingMenu(engine: engine, url: url)
                                if WallpaperFrameRatePicker.supports(url) {
                                    WallpaperFrameRatePicker(engine: engine, url: url)
                                }
                                AddToPlaylistMenu(model: model, urls: [url], onCreated: openPlaylist)
                                Divider()
                                Button("在 Finder 中显示") { model.revealInFinder(url) }
                                Button("移入垃圾桶", role: .destructive) { model.moveToTrash(url) }
                            }
                            .draggable(url)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        .clipped()
        }
        .overlay {
            if dropTargeted && model.folderAvailable {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importDroppedFiles(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay(alignment: .bottom) { Toast(text: model.importingPackage ? "正在导入壁纸…" : model.message) }
        .sheet(item: $preview) { target in
            WallpaperPreviewSheet(engine: engine, url: target.url) { model.use(target.url) }
        }
        .onAppear { model.refresh() }
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let available = max(1, width - 36)
        let desired = max(150, min(360, tileWidth))
        let count = max(1, Int((available + 16) / (desired + 16)))
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: count)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("全部壁纸").font(.title2.bold()).lineLimit(1)
            Text(model.data.folder.isEmpty ? "尚未选择文件夹" : "\(model.files.count) 个 · \(model.data.folder)")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typeFilter: some View {
        Picker("类型", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(width: 190)
    }

    private var search: some View {
        TextField("搜索", text: $query)
            .textFieldStyle(.roundedBorder)
    }

    private var sizeSlider: some View {
        Slider(value: $tileWidth, in: 150...360)
            .frame(width: 80).help("缩略图大小")
    }

    private var folderMenu: some View {
        Menu {
            Button("选择文件夹…") { model.chooseFolder() }
            Button("创建文件夹…") { model.createFolder() }
            Button("导入 PKG 壁纸…") { model.choosePackage() }
                .disabled(model.importingPackage)
            if !model.data.hiddenPaths.isEmpty {
                Button("恢复已移除的 \(model.data.hiddenPaths.count) 个壁纸") { model.restoreHidden() }
            }
            if model.folderAvailable {
                Divider()
                Button("在 Finder 中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: model.data.folder)) }
            }
        } label: { Image(systemName: "folder") }
        .menuStyle(.borderlessButton).fixedSize().help("壁纸文件夹")
    }

    private var libraryActions: some View {
        HStack(spacing: 8) {
            Button { model.refresh(report: true) } label: {
                Label("刷新壁纸库", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("重新扫描壁纸文件夹")
            .keyboardShortcut("r", modifiers: .command)

            Menu {
                Picker("排序", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.inline)
            } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("按名称或修改时间排序")

            folderMenu
        }
        .fixedSize()
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                heading.frame(minWidth: 140)
                typeFilter
                search.frame(width: 130)
                sizeSlider
                libraryActions
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { heading; sizeSlider; libraryActions }
                HStack(spacing: 10) { typeFilter; search }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String
    let button: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let button {
                Button(button, action: action)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct Toast: View {
    let text: String

    var body: some View {
        ZStack {
            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: text)
        .allowsHitTesting(false)
    }
}
