import AppKit
import SwiftUI

/// One playlist: a header with a live cover and playback controls, then
/// every wallpaper in it with its own preview, as a list or a grid.
struct PlaylistView: View {
    @ObservedObject var model: LibraryModel
    let engine: WallpaperEngine
    let listID: UUID

    @AppStorage("LiveWallPlaylistGrid") private var gridMode = false
    @State private var preview: PreviewTarget?
    @State private var addingWallpapers = false
    @State private var dropTargeted = false
    @State private var bulkMinutes: Double = 60
    @State private var editingBulkDuration = false

    /// Bound by id rather than index, so deleting the list while this view
    /// is still on screen can't crash on a stale index.
    private var list: Binding<WallpaperList> {
        Binding(
            get: { model.list(listID) ?? WallpaperList(id: listID, name: "") },
            set: { newValue in
                if let i = model.index(of: listID) { model.data.lists[i] = newValue }
            }
        )
    }

    private var isActive: Bool { model.data.active == listID }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            header
            Divider()
            if list.wrappedValue.items.isEmpty {
                EmptyStateView(
                    symbol: "rectangle.stack.badge.plus",
                    title: "这个播放列表还是空的",
                    detail: "点击「添加壁纸」，从壁纸库选择要加入的壁纸。",
                    button: nil
                ) {}
            } else if gridMode {
                grid(width: geometry.size.width)
            } else {
                rows
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        .clipped()
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) { Toast(text: model.message) }
        .dropDestination(for: URL.self) { urls, _ in
            model.importDroppedFiles(urls, intoPlaylist: listID)
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $preview) { target in
            WallpaperPreviewSheet(engine: engine, url: target.url) {
                if let item = list.wrappedValue.items.first(where: { $0.path == target.url.path }) {
                    model.playItem(listID: listID, itemID: item.id)
                } else {
                    model.use(target.url)
                }
            }
        }
        .sheet(isPresented: $addingWallpapers) {
            PlaylistWallpaperPicker(model: model, listID: listID)
        }
        .onAppear {
            if let first = list.wrappedValue.items.first { bulkMinutes = (first.seconds / 60).rounded() }
        }
    }

    // MARK: Header

    private var coverURL: URL? {
        let items = list.wrappedValue.items
        if isActive, items.indices.contains(model.playingIndex) { return items[model.playingIndex].url }
        return items.first?.url
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if let coverURL {
                        MediaThumbnail(url: coverURL, cornerRadius: 7)
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.quaternary)
                            .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 82, height: 48)
                .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    TextField("播放列表名称", text: list.name)
                        .textFieldStyle(.plain)
                        .font(.title3.bold())
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if isActive { statusLine }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    playbackControls
                    Spacer(minLength: 4)
                    libraryControls
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        playbackControls.fixedSize(horizontal: true, vertical: false)
                        playbackControls.labelStyle(.iconOnly)
                    }
                    libraryControls
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var playbackControls: some View {
        HStack(spacing: 6) {
            if isActive {
                Button { model.stop() } label: { Label("停止轮换", systemImage: "stop.fill") }
                    .help("停止轮换")
            } else {
                Button { model.start(listID) } label: { Label("播放", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(list.wrappedValue.items.isEmpty)
                    .help("播放")
            }
            Group {
                Button { model.switchWallpaper(.previous, in: listID) } label: {
                    Label("上一个壁纸", systemImage: "backward.end.fill")
                }.help("上一个壁纸")
                Button { model.switchWallpaper(.next, in: listID) } label: {
                    Label("下一个壁纸", systemImage: "forward.end.fill")
                }.help("下一个壁纸")
                Button { model.switchWallpaper(.random, in: listID) } label: {
                    Label("随机一个", systemImage: "die.face.5")
                }.help("随机一个")
            }
            .labelStyle(.iconOnly)
            .disabled(list.wrappedValue.items.isEmpty)
            Button { model.togglePause() } label: {
                Label(model.isPaused ? "继续播放" : "暂停播放",
                      systemImage: model.isPaused ? "play.circle" : "pause.circle")
            }
            .labelStyle(.iconOnly)
            .help(model.isPaused ? "继续播放" : "暂停播放并停在当前画面")
            .disabled(engine.displayStates.allSatisfy { $0.videoURL == nil })
            Toggle(isOn: list.random) { Label("随机", systemImage: "shuffle") }
                .toggleStyle(.button)
                .help("随机")
            Toggle(isOn: Binding(
                get: { list.wrappedValue.repeatOne },
                set: { list.wrappedValue.repeatOne = $0; model.playbackOptionsChanged(for: listID) }
            )) { Label("单个循环", systemImage: "repeat.1") }
                .toggleStyle(.button)
                .help("一直使用当前壁纸，不自动切换")
        }
    }

    private var libraryControls: some View {
        HStack(spacing: 6) {
            Picker("布局", selection: $gridMode) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("列表 / 网格")

            Button {
                model.refresh()
                addingWallpapers = true
            } label: {
                Label("添加壁纸", systemImage: "plus")
            }

            Button { editingBulkDuration = true } label: {
                Label("批量设置时长", systemImage: "clock")
                    .labelStyle(.iconOnly)
            }
            .help("批量设置时长")
            .disabled(list.wrappedValue.items.isEmpty)
            .popover(isPresented: $editingBulkDuration) {
                HStack(spacing: 6) {
                    Text("每张壁纸")
                    TextField("分钟", value: $bulkMinutes, format: .number)
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)
                    Text("分钟")
                    Button("应用到全部") {
                        model.setAllDurations(minutes: bulkMinutes, in: listID)
                        editingBulkDuration = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
    }

    private var summary: String {
        let items = list.wrappedValue.items
        let total = items.reduce(0) { $0 + $1.seconds }
        return items.isEmpty ? "0 个壁纸" : "\(items.count) 个壁纸 · 一轮约 \(formatMinutes(total))"
    }

    private var statusLine: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                Text("正在使用第 \(model.playingIndex + 1) 个")
                if model.isPaused {
                    Text("· 已暂停")
                } else if let next = model.nextSwitch {
                    let minutes = max(0, Int(ceil(next.timeIntervalSince(context.date) / 60)))
                    Text("· \(minutes) 分钟后切换")
                } else if list.wrappedValue.repeatOne {
                    Text("· 单个循环中")
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    // MARK: Items

    private var rows: some View {
        List {
            ForEach(list.items) { $item in
                PlaylistRow(
                    item: $item,
                    engine: engine,
                    number: (list.wrappedValue.items.firstIndex { $0.id == item.id } ?? 0) + 1,
                    isPlaying: model.isPlaying(listID: listID, itemID: item.id),
                    inTrash: model.isInTrash(item.url),
                    onPlay: { model.playItem(listID: listID, itemID: item.id) },
                    onPreview: { preview = PreviewTarget(url: item.url) },
                    onRemove: { model.removeItem(item.id, from: listID) },
                    onReveal: { model.revealInFinder(item.url) },
                    onDurationChanged: { model.playbackOptionsChanged(for: listID) }
                )
            }
            .onMove { source, destination in
                list.wrappedValue.items.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollIndicators(.hidden)
    }

    private func grid(width: CGFloat) -> some View {
        let count = max(1, Int(max(1, width - 20) / 216))
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: count), alignment: .leading, spacing: 18) {
                ForEach(Array(list.wrappedValue.items.enumerated()), id: \.element.id) { offset, item in
                    WallpaperCard(
                        url: item.url,
                        isCurrent: model.isPlaying(listID: listID, itemID: item.id),
                        caption: model.isInTrash(item.url) ? "在垃圾桶中" : "#\(offset + 1) · \(formatMinutes(item.seconds))",
                        onUse: { model.playItem(listID: listID, itemID: item.id) },
                        onPreview: { preview = PreviewTarget(url: item.url) }
                    ) {
                        Button("从这里开始播放") { model.playItem(listID: listID, itemID: item.id) }
                        Button("大图预览") { preview = PreviewTarget(url: item.url) }
                        WallpaperScalingMenu(engine: engine, url: item.url)
                        Button("在 Finder 中显示") { model.revealInFinder(item.url) }
                        Divider()
                        Button("从播放列表移除") { model.removeItem(item.id, from: listID) }
                    }
                }
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
    }
}

private struct PlaylistWallpaperPicker: View {
    @ObservedObject var model: LibraryModel
    let listID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<URL> = []
    @State private var query = ""

    var body: some View {
        let alreadyAdded = Set(model.list(listID)?.items.map(\.path) ?? [])
        let shown = model.files.filter {
            query.isEmpty || title($0).localizedCaseInsensitiveContains(query)
        }
        let toAdd = model.files.filter { selected.contains($0) && !alreadyAdded.contains($0.path) }
        VStack(alignment: .leading, spacing: 12) {
            Text("添加壁纸").font(.title2.bold())
            TextField("搜索壁纸", text: $query)
                .textFieldStyle(.roundedBorder)

            if shown.isEmpty {
                Text(query.isEmpty ? "壁纸库中没有可选壁纸。" : "没有找到匹配的壁纸。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 14) {
                        ForEach(shown, id: \.self) { url in
                            tile(url, alreadyAdded: alreadyAdded.contains(url.path))
                        }
                    }
                    .padding(3)
                    .padding(.trailing, 14)
                }
            }

            HStack {
                Text("已选择 \(toAdd.count) 张").foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("加入播放列表") {
                    model.add(toAdd, to: listID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(toAdd.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 620, height: 480)
    }

    private func title(_ url: URL) -> String {
        WorkshopScene(url)?.title ?? url.deletingPathExtension().lastPathComponent
    }

    private func tile(_ url: URL, alreadyAdded: Bool) -> some View {
        let checked = selected.contains(url)
        return Button {
            if checked { selected.remove(url) } else { selected.insert(url) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                MediaThumbnail(url: url, cornerRadius: 7)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: alreadyAdded || checked ? "checkmark.circle.fill" : "circle")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, checked ? Color.accentColor : .black.opacity(0.65))
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(checked ? Color.accentColor : .clear, lineWidth: 2)
                    }
                Text(title(url)).lineLimit(1).truncationMode(.middle)
                if alreadyAdded {
                    Text("已在播放列表中").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
        .accessibilityLabel(title(url))
        .accessibilityValue(alreadyAdded ? "已添加" : checked ? "已选择" : "未选择")
    }
}

struct PlaylistRow: View {
    @Binding var item: PlaylistItem
    let engine: WallpaperEngine
    let number: Int
    let isPlaying: Bool
    let inTrash: Bool
    let onPlay: () -> Void
    let onPreview: () -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void
    let onDurationChanged: () -> Void

    @State private var hovering = false

    private var exists: Bool { FileManager.default.fileExists(atPath: item.path) }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                } else if hovering {
                    Button(action: onPlay) { Image(systemName: "play.fill") }
                        .buttonStyle(.plain)
                        .help("从这项开始播放")
                } else {
                    Text("\(number)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 26)

            MediaThumbnail(url: item.url, cornerRadius: 6)
                .frame(width: 72, height: 48)
                .onTapGesture(count: 2, perform: onPlay)
                .overlay(alignment: .bottomLeading) { KindBadge(url: item.url).padding(4) }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isPlaying ? Color.accentColor : .clear, lineWidth: 2)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(WorkshopScene(item.url)?.title ?? item.url.deletingPathExtension().lastPathComponent)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if inTrash {
                    Label("在垃圾桶中", systemImage: "trash")
                        .font(.caption).foregroundStyle(.secondary)
                } else if exists {
                    Text(item.url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Label("找不到文件", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                DurationMinutesField(seconds: $item.seconds, onCommit: onDurationChanged)
                Text("分钟").foregroundStyle(.secondary)
            }
            .font(.callout)
            .help("这张壁纸显示多久后切换")

            HStack(spacing: 2) {
                Button(action: onPreview) { Image(systemName: "eye") }.help("大图预览")
                Button(action: onRemove) { Image(systemName: "xmark") }.help("从播放列表移除")
            }
            .buttonStyle(.borderless)
            .font(.body)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("从这里开始播放", action: onPlay)
            Button("大图预览", action: onPreview)
            WallpaperScalingMenu(engine: engine, url: item.url)
            Button("在 Finder 中显示", action: onReveal)
            Divider()
            Button("从播放列表移除", action: onRemove)
        }
    }
}

/// Keep a text draft while editing so partial input is not replaced by
/// numeric formatting or by the row's playback gesture.
struct DurationMinutesField: View {
    @Binding var seconds: Double
    var onCommit: () -> Void
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField("分钟", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
            .focused($editing)
            .accessibilityLabel("播放时长（分钟）")
            .onAppear { refresh() }
            .onChange(of: seconds) { _, _ in if !editing { refresh() } }
            .onChange(of: editing) { _, focused in if !focused { commit() } }
            .onSubmit { commit(); editing = false }
    }
    private func refresh() { draft = String(Int(max(1, (seconds / 60).rounded()))) }
    private func commit() {
        if let minutes = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)), minutes.isFinite, minutes >= 1, minutes <= 525600 {
            let value = minutes.rounded() * 60
            if seconds != value { seconds = value; onCommit() }
        }
        refresh()
    }
}
