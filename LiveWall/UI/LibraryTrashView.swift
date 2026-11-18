import SwiftUI

struct LibraryTrashView: View {
    @ObservedObject var model: LibraryModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("垃圾桶").font(.title2.bold())
                    Text("\(model.data.trash.count) 个壁纸")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空垃圾桶…", role: .destructive) { confirming = true }
                    .disabled(model.data.trash.isEmpty || model.clearingTrash || model.importingPackage)
            }
            .padding(16)
            Divider()

            if model.data.trash.isEmpty {
                ContentUnavailableView("垃圾桶是空的", systemImage: "trash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.data.trash.reversed()) { entry in
                    HStack(spacing: 10) {
                        MediaThumbnail(url: entry.url, hoverToPlay: false, cornerRadius: 6)
                            .frame(width: 76, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).lineLimit(1).truncationMode(.middle)
                            Text(entry.rootPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        Button("恢复") { model.restoreFromTrash(entry) }
                            .disabled(model.clearingTrash)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .alert("永久删除垃圾桶中的壁纸？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { model.clearTrash() }
        } message: {
            Text("这会从原位置永久删除 \(model.data.trash.count) 个壁纸。场景壁纸会删除整个项目文件夹。此操作无法撤销。")
        }
        .overlay(alignment: .bottom) {
            Toast(text: model.clearingTrash ? "正在清空垃圾桶…" : model.message)
        }
    }
}
