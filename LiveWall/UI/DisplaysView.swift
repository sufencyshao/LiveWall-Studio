import SwiftUI

struct DisplaysView: View {
    @ObservedObject var engine: WallpaperEngine
    @StateObject private var memoryMonitor = MemoryUsageMonitor()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if engine.displayStates.isEmpty {
                    Text("未检测到显示器。")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
                ForEach(engine.displayStates) { state in
                    DisplayCardView(state: state, engine: engine)
                }

                Text("内存占用：\(Int(memoryMonitor.usageMB.rounded())) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 17)
        }
    }
}
