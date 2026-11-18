import SwiftUI
import ServiceManagement

struct PreferencesView: View {
    @ObservedObject var engine: WallpaperEngine

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var saverInstalled = SaverInstaller.isInstalled
    @State private var saverError: String?
    @State private var aerialInstalled = AerialInstaller.isInstalled
    @State private var aerialError: String?
    @State private var aerialBusy = false
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var workshopAudio = WorkshopAudioCapture.shared

    var body: some View {
        ScrollView {
            content
                .padding(12)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            saverInstalled = SaverInstaller.isInstalled
            aerialInstalled = AerialInstaller.isInstalled
        }
        .onChange(of: aerialInstalled, handleAerialToggle)
        .onChange(of: saverInstalled, handleSaverToggle)
        .onChange(of: launchAtLogin, handleLaunchAtLoginToggle)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("通用") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("登录时自动启动", isOn: $launchAtLogin)
                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Toggle("使用电池时暂停", isOn: $engine.pauseOnBattery)
                    Toggle("低电量模式下暂停", isOn: $engine.pauseOnLowPower)
                    updateRow
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if #available(macOS 14.2, *) {
                GroupBox("场景音频") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("让场景壁纸跟随系统声音", isOn: Binding(
                            get: { workshopAudio.enabled },
                            set: { workshopAudio.setEnabled($0) }
                        ))
                        if !workshopAudio.status.isEmpty {
                            Text(workshopAudio.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("屏幕保护程序") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("将视频用作屏幕保护程序", isOn: $saverInstalled)
                    if let saverError {
                        Text(saverError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if AerialInstaller.isSupported {
                GroupBox("锁屏与系统壁纸") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("将视频添加到系统壁纸与锁屏", isOn: $aerialInstalled)
                            .disabled(aerialBusy)
                        if let aerialError {
                            Text(aerialError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("退出 LiveWall", systemImage: "power")
                }
            }
        }
    }

    private var updateRow: some View {
        HStack(spacing: 8) {
            switch updateChecker.status {
            case .idle:
                Button("检查更新…") { updateChecker.checkNow() }
                    .controlSize(.small)
                Spacer()
            case .checking:
                Text("正在检查更新…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            case .upToDate:
                Text("已是最新版本（\(updateChecker.currentVersion)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            case .updateAvailable(let version):
                Text("发现新版本 \(version)")
                    .font(.caption)
                Spacer()
                Button("下载") {
                    NSWorkspace.shared.open(UpdateChecker.releasesPageURL)
                }
                .controlSize(.small)
            case .failed:
                Text("无法检查更新")
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("重试") { updateChecker.checkNow() }
                    .controlSize(.small)
            }
        }
    }

    private func handleAerialToggle(_ oldValue: Bool, _ newValue: Bool) {
        guard newValue != AerialInstaller.isInstalled else { return }
        if newValue {
            guard let url = engine.saverVideoURL else {
                aerialInstalled = false
                aerialError = "请先为显示器选择视频。"
                return
            }
            aerialBusy = true
            Task {
                do {
                    try await AerialInstaller.install(
                        videoURL: url,
                        displayName: url.deletingPathExtension().lastPathComponent
                    )
                    aerialError = nil
                } catch {
                    aerialInstalled = false
                    aerialError = "无法注册视频：\(error.localizedDescription)"
                }
                aerialBusy = false
            }
        } else {
            do {
                try AerialInstaller.uninstall()
                aerialError = nil
            } catch {
                aerialInstalled = AerialInstaller.isInstalled
                aerialError = "无法移除：\(error.localizedDescription)"
            }
        }
    }

    private func handleSaverToggle(_ oldValue: Bool, _ newValue: Bool) {
        guard newValue != SaverInstaller.isInstalled else { return }
        do {
            if newValue {
                try SaverInstaller.install()
                if let url = engine.saverVideoURL {
                    SaverInstaller.syncVideoInBackground(url)
                }
            } else {
                try SaverInstaller.uninstall()
            }
            saverError = nil
        } catch {
            saverInstalled = SaverInstaller.isInstalled
            saverError = "无法更新屏幕保护程序：\(error.localizedDescription)"
        }
    }

    private func handleLaunchAtLoginToggle(_ oldValue: Bool, _ newValue: Bool) {
        let currentlyEnabled = SMAppService.mainApp.status == .enabled
        guard newValue != currentlyEnabled else { return }
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLogin = currentlyEnabled
            launchAtLoginError = "无法更新登录项：\(error.localizedDescription)"
        }
    }
}
