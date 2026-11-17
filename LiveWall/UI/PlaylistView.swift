import AppKit
import SwiftUI

/// One playlist: a header with a live cover and playback controls, then
/// every wallpaper in it with its own preview, as a list or a grid.
struct PlaylistView: View {
    @ObservedObject var model: LibraryModel
    let listID: UUID
    var goToLibrary: () -> Void = {}

    @AppStorage("LiveWallPlaylistGrid") private var gridMode = false
    @State private var preview: PreviewTarget?
    @State private var dropTargeted = false
    @State private var bulkMinutes: Double = 60

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
            ScrollView { header(width: geometry.size.width) }
                .frame(height: min(300, geometry.size.height * 0.55))
            Divider()
            if list.wrappedValue.items.isEmpty {
                EmptyStateView(
                    symbol: "rectangle.stack.badge.plus",
                    title: "这个播放列表还是空的",
                    detail: "把壁纸从「全部壁纸」拖到这里（或拖到左侧的列表名上），也可以在壁纸上右键 › 加入播放列表。Finder 里的文件也能直接拖进来。",
                    button: "去壁纸库挑选",
                    action: goToLibrary
                )
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
            model.add(urls, to: listID) > 0
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $preview) { target in
            WallpaperPreviewSheet(url: target.url) {
                if let item = list.wrappedValue.items.first(where: { $0.path == target.url.path }) {
                    model.playItem(listID: listID, itemID: item.id)
                } else {
                    model.use(target.url)
                }
            }
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

    private func header(width: CGFloat) -> some View {
        let compact = width < 720
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
        return layout {
            Group {
                if let coverURL {
                    MediaThumbnail(url: coverURL, cornerRadius: 10)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                        .overlay(Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.secondary))
                }
            }
            .frame(width: compact ? min(180, max(100, width - 36)) : 240, height: compact ? 90 : 135)
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 8) {
                Text("播放列表").font(.caption).foregroundStyle(.secondary)
                TextField("播放列表名称", text: list.name)
                    .textFieldStyle(.plain)
                    .font(.title.bold())
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isActive { statusLine }

                HStack(spacing: 8) {
                    if isActive {
                        Button { model.stop() } label: { Label("停止轮换", systemImage: "stop.fill") }
                        Button { model.previous() } label: { Image(systemName: "backward.fill") }.help("上一个")
                        Button { model.next() } label: { Image(systemName: "forward.fill") }.help("下一个")
                    } else {
                        Button { model.start(listID) } label: { Label("播放", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(list.wrappedValue.items.isEmpty)
                    }
                    Divider().frame(height: 18)
                    Toggle(isOn: list.random) { Label("随机", systemImage: "shuffle") }
                        .toggleStyle(.button)
                    Toggle(isOn: Binding(
                        get: { list.wrappedValue.repeatOne },
                        set: { list.wrappedValue.repeatOne = $0; model.playbackOptionsChanged(for: listID) }
                    )) { Label("单个循环", systemImage: "repeat.1") }
                        .toggleStyle(.button)
                        .help("一直使用当前壁纸，不自动切换")
                }
                HStack {
                    Picker("布局", selection: $gridMode) {
                        Image(systemName: "list.bullet").tag(false)
                        Image(systemName: "square.grid.2x2").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("列表 / 网格")
                }
                .controlSize(.regular)

                HStack(spacing: 6) {
                    Text("每个壁纸显示")
                    TextField("", value: $bulkMinutes, format: .number)
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)
                    Text("分钟")
                    Button("应用到全部") { model.setAllDurations(minutes: bulkMinutes, in: listID) }
                        .disabled(list.wrappedValue.items.isEmpty)
                }
                .font(.callout)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
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
                if let next = model.nextSwitch {
                    let minutes = max(0, Int(ceil(next.timeIntervalSince(context.date) / 60)))
                    Text("· \(minutes) 分钟后切换")
                } else if list.wrappedValue.repeatOne {
                    Text("· 单个循环中")
                }
            }
            .font(.callout)
        }
    }

    // MARK: Items

    private var rows: some View {
        List {
            ForEach(list.items) { $item in
                PlaylistRow(
                    item: $item,
                    number: (list.wrappedValue.items.firstIndex { $0.id == item.id } ?? 0) + 1,
                    isPlaying: model.isPlaying(listID: listID, itemID: item.id),
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
    }

    private func grid(width: CGFloat) -> some View {
        let count = max(1, Int(max(1, width - 20) / 216))
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: count), alignment: .leading, spacing: 18) {
                ForEach(Array(list.wrappedValue.items.enumerated()), id: \.element.id) { offset, item in
                    WallpaperCard(
                        url: item.url,
                        isCurrent: model.isPlaying(listID: listID, itemID: item.id),
                        caption: "#\(offset + 1) · \(formatMinutes(item.seconds))",
                        onUse: { model.playItem(listID: listID, itemID: item.id) },
                        onPreview: { preview = PreviewTarget(url: item.url) }
                    ) {
                        Button("从这里开始播放") { model.playItem(listID: listID, itemID: item.id) }
                        Button("大图预览") { preview = PreviewTarget(url: item.url) }
                        Button("在 Finder 中显示") { model.revealInFinder(item.url) }
                        Divider()
                        Button("从播放列表移除") { model.removeItem(item.id, from: listID) }
                    }
                }
            }
            .padding(18)
        }
    }
}

struct PlaylistRow: View {
    @Binding var item: PlaylistItem
    let number: Int
    let isPlaying: Bool
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
                Text(item.url.deletingPathExtension().lastPathComponent)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if exists {
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
