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
                Text(url.deletingPathExtension().lastPathComponent)
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
    var openPlaylist: (UUID) -> Void = { _ in }

    @AppStorage("LiveWallGridSize") private var tileWidth: Double = 220
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var preview: PreviewTarget?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", video = "视频", image = "图片"
        var id: String { rawValue }
    }

    private var shown: [URL] {
        model.files.filter { url in
            let kind = MediaKind(url: url)
            switch filter {
            case .all: break
            case .video: if kind?.isVideo != true { return false }
            case .image: if kind?.isVideo != false { return false }
            }
            return query.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            header
            Divider()
            if model.data.folder.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    title: "选择一个壁纸文件夹",
                    detail: "LiveWall 会读取文件夹里的视频（mp4、mov、m4v）和图片（jpg、png、heic、gif…），并生成预览。",
                    button: "选择文件夹…"
                ) { model.chooseFolder() }
            } else if model.files.isEmpty {
                EmptyStateView(
                    symbol: "photo.on.rectangle.angled",
                    title: "文件夹里没有可用的壁纸",
                    detail: model.data.folder,
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
                                AddToPlaylistMenu(model: model, urls: [url], onCreated: openPlaylist)
                                Divider()
                                Button("在 Finder 中显示") { model.revealInFinder(url) }
                                Button("从壁纸库移除") { model.hide(url) }
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
        .overlay(alignment: .bottom) { Toast(text: model.message) }
        .sheet(item: $preview) { target in
            WallpaperPreviewSheet(url: target.url) { model.use(target.url) }
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
        .frame(width: 150)
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
            Button("刷新") { model.refresh() }
            if !model.data.hiddenPaths.isEmpty {
                Button("恢复已移除的 \(model.data.hiddenPaths.count) 个壁纸") { model.restoreHidden() }
            }
            if !model.data.folder.isEmpty {
                Divider()
                Button("在 Finder 中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: model.data.folder)) }
            }
        } label: { Image(systemName: "folder") }
        .menuStyle(.borderlessButton).fixedSize().help("壁纸文件夹")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                heading.frame(minWidth: 140)
                typeFilter
                search.frame(width: 130)
                sizeSlider
                folderMenu
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { heading; sizeSlider; folderMenu }
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
