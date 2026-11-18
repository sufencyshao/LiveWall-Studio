import AppKit
import SwiftUI

/// Menu bar icon plus the main LiveWall window. Left-click opens the
/// window; right-click gives a quick menu (next wallpaper, stop, quit).
/// The app shows a Dock icon only while the window is open, so it can be
/// found with ⌘-Tab, and goes back to being menu-bar-only when closed.
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let window: NSWindow
    private let library: LibraryModel
    private let engine: WallpaperEngine

    init(engine: WallpaperEngine, library: LibraryModel) {
        self.library = library
        self.engine = engine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let host = NSHostingController(rootView: SettingsView(engine: engine, library: library))
        host.sizingOptions = []
        host.view.autoresizingMask = [.width, .height]

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LiveWall"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        let container = NSViewController()
        container.view = NSView()
        container.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        window.contentViewController = container
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.contentMinSize = NSSize(width: 380, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LiveWallMainWindow")
        super.init()
        window.delegate = self

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "LiveWall")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Open the window on the very first launch (so people find the
        // library) or when asked to; after that, a login launch stays quiet
        // in the menu bar.
        let firstLaunchKey = "LiveWallHasOpenedWindowV2"
        if ProcessInfo.processInfo.arguments.contains("--show-settings")
            || !UserDefaults.standard.bool(forKey: firstLaunchKey) {
            UserDefaults.standard.set(true, forKey: firstLaunchKey)
            DispatchQueue.main.async { [weak self] in self?.showWindow() }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showQuickMenu()
        } else {
            showWindow()
        }
    }

    @objc func showWindow() {
        if ProcessInfo.processInfo.arguments.contains("--compact-layout-test") {
            window.setContentSize(NSSize(width: 380, height: 420))
            window.center()
        }
        if ProcessInfo.processInfo.arguments.contains("--sidebar-layout-test") {
            window.setContentSize(NSSize(width: 640, height: 500))
            window.center()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开 LiveWall", action: #selector(showWindow), keyEquivalent: "").target = self
        if library.canSwitchWallpaper || engine.displayStates.contains(where: { $0.videoURL != nil }) {
            menu.addItem(.separator())
            if library.canSwitchWallpaper {
                menu.addItem(withTitle: "上一个壁纸", action: #selector(previousWallpaper), keyEquivalent: "").target = self
                menu.addItem(withTitle: "下一个壁纸", action: #selector(nextWallpaper), keyEquivalent: "").target = self
                menu.addItem(withTitle: "随机一个", action: #selector(randomWallpaper), keyEquivalent: "").target = self
            }
            if engine.displayStates.contains(where: { $0.videoURL != nil }) {
                menu.addItem(withTitle: library.isPaused ? "继续播放" : "暂停播放",
                             action: #selector(togglePause), keyEquivalent: "").target = self
            }
            if let muted = engine.wallpaperAudioMuted {
                menu.addItem(withTitle: muted ? "取消静音" : "静音",
                             action: #selector(toggleMute), keyEquivalent: "").target = self
            }
            if library.data.active != nil {
                menu.addItem(withTitle: "停止轮换", action: #selector(stopRotation), keyEquivalent: "").target = self
            }
        }
        let availableLists = library.data.lists.filter { !$0.items.isEmpty }
        if !availableLists.isEmpty {
            menu.addItem(.separator())
            let playItem = NSMenuItem(title: "播放列表", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for list in availableLists {
                let item = NSMenuItem(title: list.name, action: #selector(startList(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = list.id
                sub.addItem(item)
            }
            playItem.submenu = sub
            menu.addItem(playItem)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 LiveWall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func nextWallpaper() { library.next() }
    @objc private func previousWallpaper() { library.previous() }
    @objc private func randomWallpaper() { library.switchWallpaper(.random) }
    @objc private func togglePause() { library.togglePause() }
    @objc private func toggleMute() { engine.toggleWallpaperMute() }
    @objc private func stopRotation() { library.stop() }
    @objc private func startList(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { library.start(id) }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app once the window's gone.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
