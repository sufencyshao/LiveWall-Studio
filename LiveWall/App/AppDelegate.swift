import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication doesn't retain its delegate, so something has to hold
    // onto it — that's this static var.
    private static var shared: AppDelegate!

    private var engine: WallpaperEngine!
    private var library: LibraryModel!
    private var statusItemController: StatusItemController!

    static func main() {
        let app = NSApplication.shared
        shared = AppDelegate()
        app.delegate = shared
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already hides the Dock icon, but
        // setting this explicitly too means it also works right when run
        // straight from Xcode.
        NSApp.setActivationPolicy(.accessory)

        engine = WallpaperEngine()
        library = LibraryModel(engine: engine)
        statusItemController = StatusItemController(engine: engine, library: library)

        UpdateChecker.shared.checkIfDue()
    }

    /// Clicking the Dock icon (while the window is closed but the app is
    /// still "regular") brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { statusItemController.showWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
