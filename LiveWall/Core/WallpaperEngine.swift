import AppKit
import Combine

/// A snapshot of one connected display's state, for the settings UI to render.
struct DisplayState: Identifiable, Equatable {
    let id: String
    let name: String
    let resolutionText: String
    var videoURL: URL?
    var scaling: ScalingMode
    var isMuted: Bool
    var volume: Float
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
}

/// The brain of the app. Owns one WallpaperScreenController per connected
/// display, saves and restores assignments, and pauses/resumes playback
/// when a display gets covered, the Mac sleeps, or the power source changes.
final class WallpaperEngine: ObservableObject {
    @Published private(set) var displayStates: [DisplayState] = []
    private var manuallyPaused = false
    @Published var pauseOnBattery: Bool {
        didSet {
            persist()
            updatePlaybackStates()
        }
    }
    @Published var pauseOnLowPower: Bool {
        didSet {
            persist()
            updatePlaybackStates()
        }
    }
    @Published var saveEnergyOnBattery: Bool {
        didSet {
            persist()
            updatePlaybackStates()
        }
    }
    @Published var reduceScenesBehindApps: Bool {
        didSet {
            persist()
            updatePlaybackStates()
        }
    }

    private let store = SettingsStore()
    private var settings: StoredSettings
    private var controllers: [String: WallpaperScreenController] = [:]

    private let powerMonitor = PowerMonitor()
    private var isSystemSleeping = false
    private var areScreensSleeping = false
    private var isSessionInactive = false
    private var isOnBattery = false
    private var isLowPowerMode = false
    private var reconcileWorkItem: DispatchWorkItem?
    private var persistWorkItem: DispatchWorkItem?
    private var foregroundTimer: Timer?

    init() {
        settings = store.load()
        pauseOnBattery = settings.pauseOnBattery
        pauseOnLowPower = settings.pauseOnLowPower
        saveEnergyOnBattery = settings.saveEnergyOnBattery
        reduceScenesBehindApps = settings.reduceScenesBehindApps
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceCenter.addObserver(self, selector: #selector(foregroundChanged), name: name, object: nil)
        }
        workspaceCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )
        // Fast user switching: the desktop window doesn't count as occluded
        // while another user's session is up, so without these the video
        // would keep decoding for a desktop nobody can see.
        workspaceCenter.addObserver(
            self, selector: #selector(sessionResignedActive),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(sessionBecameActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil
        )

        isOnBattery = PowerMonitor.isOnBattery()
        powerMonitor.onPowerSourceChanged = { [weak self] onBattery in
            guard let self else { return }
            self.isOnBattery = onBattery
            self.updatePlaybackStates()
        }
        powerMonitor.start()

        migrateWallpaperScaling()
        reconcile()
    }

    deinit {
        foregroundTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API (called from the UI)

    func assignVideo(url: URL, to displayKey: String) {
        guard let bookmark = try? Self.makeBookmark(for: url) else { return }
        var assignment = settings.assignments[displayKey]
            ?? StoredAssignment(bookmark: bookmark, scaling: .fill, muted: true, volume: 1.0)
        assignment.bookmark = bookmark
        assignment.scaling = scaling(for: url)
        // A trim only makes sense for the clip it was made on, so a new
        // video starts untrimmed.
        assignment.trimStart = nil
        assignment.trimEnd = nil
        settings.assignments[displayKey] = assignment
        persist()

        controllers[displayKey]?.load(
            url: url,
            scaling: assignment.scaling,
            position: fillPosition(for: url),
            frameRate: frameRate(for: url),
            muted: assignment.muted,
            volume: assignment.volume
        )
        updatePlaybackStates()
        rebuildDisplayStates()

        // If the screen saver or the native aerial trick is turned on,
        // keep their copies of the video in sync with whatever's now
        // assigned.
        if SaverInstaller.isInstalled, let saverURL = saverVideoURL {
            SaverInstaller.syncVideoInBackground(saverURL)
        }
        if AerialInstaller.isInstalled, let saverURL = saverVideoURL {
            let name = saverURL.deletingPathExtension().lastPathComponent
            Task {
                try? await AerialInstaller.install(videoURL: saverURL, displayName: name)
            }
        }
    }

    /// The video the screen saver should play: the main display's, falling
    /// back to any assigned video.
    var saverVideoURL: URL? {
        if let mainKey = NSScreen.main?.displayKey,
           let url = controllers[mainKey]?.videoURL, let file = MediaKind.videoFile(for: url) {
            return file
        }
        return controllers.values.compactMap { $0.videoURL.flatMap(MediaKind.videoFile(for:)) }.first
    }

    func removeVideo(from displayKey: String) {
        settings.assignments.removeValue(forKey: displayKey)
        persist()
        controllers[displayKey]?.clear()
        updatePlaybackStates()
        rebuildDisplayStates()
    }

    func scaling(for url: URL) -> ScalingMode {
        settings.wallpaperScaling?[Self.wallpaperKey(for: url)] ?? .fill
    }

    func fillPosition(for url: URL) -> FillPosition {
        settings.wallpaperPositions[Self.wallpaperKey(for: url)] ?? .center
    }

    static let availableFrameRates = [12, 15, 24, 30, 45, 60]

    func frameRate(for url: URL) -> Int {
        settings.wallpaperFrameRates[Self.wallpaperKey(for: url)] ?? 0
    }

    func setFrameRate(_ fps: Int, for url: URL) {
        setFrameRate(fps, for: [url])
    }

    @discardableResult
    func setFrameRate(_ fps: Int, for urls: [URL]) -> Int {
        guard fps == 0 || Self.availableFrameRates.contains(fps) else { return 0 }
        let keys = Set(urls.map(Self.wallpaperKey(for:)))
        let changed = keys.filter { (settings.wallpaperFrameRates[$0] ?? 0) != fps }
        guard !changed.isEmpty else { return keys.count }
        objectWillChange.send()
        for key in changed { settings.wallpaperFrameRates[key] = fps == 0 ? nil : fps }
        for controller in controllers.values {
            guard let current = controller.videoURL, changed.contains(Self.wallpaperKey(for: current)) else { continue }
            controller.setFrameRate(fps)
        }
        persist()
        return keys.count
    }

    func setFillPosition(_ position: FillPosition, for url: URL) {
        let key = Self.wallpaperKey(for: url)
        guard fillPosition(for: url) != position else { return }
        objectWillChange.send()
        settings.wallpaperPositions[key] = position == .center ? nil : position
        for controller in controllers.values {
            guard let current = controller.videoURL, Self.wallpaperKey(for: current) == key else { continue }
            controller.setFillPosition(position)
        }
        schedulePersist()
    }

    func setScaling(_ scaling: ScalingMode, for url: URL) {
        let wallpaperKey = Self.wallpaperKey(for: url)
        guard self.scaling(for: url) != scaling else { return }
        objectWillChange.send()
        settings.wallpaperScaling?[wallpaperKey] = scaling
        for (displayKey, controller) in controllers {
            guard let current = controller.videoURL, Self.wallpaperKey(for: current) == wallpaperKey else { continue }
            settings.assignments[displayKey]?.scaling = scaling
            controller.setScaling(scaling)
        }
        persist()
        rebuildDisplayStates()
    }

    private static func wallpaperKey(for url: URL) -> String {
        let file = url.standardizedFileURL
        if file.lastPathComponent.lowercased() == "scene.pkg" {
            return file.deletingLastPathComponent().appendingPathComponent("project.json").path
        }
        return file.path
    }

    private func migrateWallpaperScaling() {
        guard settings.wallpaperScaling == nil else { return }
        var modes: [String: ScalingMode] = [:]
        let mainDisplay = NSScreen.main?.displayKey
        for displayKey in settings.assignments.keys.sorted() {
            guard let assignment = settings.assignments[displayKey],
                  let url = resolveBookmark(assignment.bookmark, forKey: displayKey) else { continue }
            let key = Self.wallpaperKey(for: url)
            if modes[key] == nil || displayKey == mainDisplay { modes[key] = assignment.scaling }
        }
        settings.wallpaperScaling = modes
        persist()
    }

    func setMuted(_ muted: Bool, for displayKey: String) {
        guard settings.assignments[displayKey] != nil else { return }
        settings.assignments[displayKey]?.muted = muted
        persist()
        controllers[displayKey]?.setMuted(muted)
        rebuildDisplayStates()
    }

    private var audioDisplays: [DisplayState] {
        displayStates.filter {
            guard let url = $0.videoURL, let kind = MediaKind(url: url) else { return false }
            return kind.isVideo || kind == .scene
        }
    }

    var wallpaperAudioMuted: Bool? {
        let displays = audioDisplays
        return displays.isEmpty ? nil : displays.allSatisfy(\.isMuted)
    }

    func toggleWallpaperMute() {
        guard let muted = wallpaperAudioMuted else { return }
        for display in audioDisplays { setMuted(!muted, for: display.id) }
    }

    func setManuallyPaused(_ paused: Bool) {
        manuallyPaused = paused
        updatePlaybackStates()
    }

    func setTrim(start: Double?, end: Double?, for displayKey: String) {
        guard settings.assignments[displayKey] != nil else { return }
        settings.assignments[displayKey]?.trimStart = start
        settings.assignments[displayKey]?.trimEnd = end
        persist()
        controllers[displayKey]?.setTrim(start: start, end: end)
        updatePlaybackStates()
        rebuildDisplayStates()
    }

    func setVolume(_ volume: Float, for displayKey: String) {
        guard settings.assignments[displayKey] != nil else { return }
        settings.assignments[displayKey]?.volume = volume
        // Dragging the volume slider fires this many times a second, and
        // each save means JSON-encoding everything and writing to disk.
        // The player gets the new volume immediately; the save can wait
        // until the slider settles.
        schedulePersist()
        controllers[displayKey]?.setVolume(volume)
        rebuildDisplayStates()
    }

    func shutdown() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
        // Flush any save that's still sitting in the debounce window.
        persist()
        for controller in controllers.values {
            controller.tearDown()
        }
        controllers.removeAll()
    }

    // MARK: - Display reconciliation

    @objc private func screenParametersChanged() {
        // Display-change notifications tend to arrive in a burst, so wait a
        // beat and coalesce them before actually reconciling anything.
        reconcileWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func reconcile() {
        var seen = Set<String>()
        for screen in NSScreen.screens {
            guard let key = screen.displayKey, !seen.contains(key) else { continue }
            seen.insert(key)

            if let controller = controllers[key] {
                controller.update(screen: screen)
            } else {
                let controller = WallpaperScreenController(screen: screen, displayKey: key)
                controller.setSceneEnergySaving(saveEnergyOnBattery && isOnBattery)
                controller.onOcclusionChanged = { [weak self] in
                    self?.updatePlaybackStates()
                }
                controllers[key] = controller
                if let assignment = settings.assignments[key] {
                    applyStoredAssignment(assignment, to: controller, key: key)
                }
            }
        }

        // Tear down windows for disconnected displays but keep their stored
        // assignment so the wallpaper returns when the display is replugged.
        for (key, controller) in controllers where !seen.contains(key) {
            controller.tearDown()
            controllers.removeValue(forKey: key)
        }

        updatePlaybackStates()
        rebuildDisplayStates()
    }

    private func applyStoredAssignment(
        _ assignment: StoredAssignment,
        to controller: WallpaperScreenController,
        key: String
    ) {
        guard let url = resolveBookmark(assignment.bookmark, forKey: key) else { return }
        controller.load(
            url: url,
            scaling: scaling(for: url),
            position: fillPosition(for: url),
            frameRate: frameRate(for: url),
            muted: assignment.muted,
            volume: assignment.volume,
            trimStart: assignment.trimStart,
            trimEnd: assignment.trimEnd
        )
    }

    // MARK: - Playback gating

    @objc private func systemWillSleep() {
        isSystemSleeping = true
        updatePlaybackStates()
    }

    @objc private func systemDidWake() {
        isSystemSleeping = false
        updatePlaybackStates()
    }

    @objc private func screensDidSleep() {
        areScreensSleeping = true
        updatePlaybackStates()
    }

    @objc private func screensDidWake() {
        areScreensSleeping = false
        updatePlaybackStates()
    }

    @objc private func sessionResignedActive() {
        isSessionInactive = true
        updatePlaybackStates()
    }

    @objc private func sessionBecameActive() {
        isSessionInactive = false
        updatePlaybackStates()
    }

    @objc private func powerStateChanged() {
        // This notification can arrive on any thread; everything in the
        // engine assumes main.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.updatePlaybackStates()
        }
    }

    private func updatePlaybackStates() {
        let globallyPaused = manuallyPaused || isSystemSleeping || areScreensSleeping || isSessionInactive
            || (pauseOnBattery && isOnBattery)
            || (pauseOnLowPower && isLowPowerMode)
        for controller in controllers.values {
            controller.setSceneEnergySaving(saveEnergyOnBattery && isOnBattery)
            if controller.hasVideo && !globallyPaused && !controller.isOccluded {
                controller.play()
            } else {
                controller.pause()
            }
        }
        updateForegroundMonitoring(running: reduceScenesBehindApps && !globallyPaused
            && controllers.values.contains { $0.hasScene && !$0.isOccluded })
    }

    @objc private func foregroundChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.foregroundTimer != nil else { return }
            self.refreshForegroundSceneMode()
        }
    }

    private func updateForegroundMonitoring(running: Bool) {
        if running {
            guard foregroundTimer == nil else { return }
            refreshForegroundSceneMode()
            // Show Desktop can move windows without activating a different app.
            // A single low-frequency scan covers that case and all displays.
            let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
                self?.refreshForegroundSceneMode()
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            foregroundTimer = timer
        } else {
            foregroundTimer?.invalidate()
            foregroundTimer = nil
            for controller in controllers.values { controller.setSceneBehindApp(false) }
        }
    }

    private func refreshForegroundSceneMode() {
        var visibleWindows: [CGRect] = []
        let workspace = NSWorkspace.shared
        if let front = workspace.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
               as? [[String: Any]] {
            visibleWindows = Self.foregroundWindowBounds(windows, owner: front.processIdentifier)
        }

        for controller in controllers.values where controller.hasScene {
            let display = controller.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let behindApp = display.map { screen in
                let bounds = CGDisplayBounds(screen.uint32Value)
                return visibleWindows.contains { window in
                    let visible = bounds.intersection(window)
                    // Ignore the narrow slivers left by Show Desktop.
                    return !visible.isNull && visible.width >= 100 && visible.height >= 75
                }
            } ?? false
            controller.setSceneBehindApp(behindApp)
        }
    }

    static func foregroundWindowBounds(_ windows: [[String: Any]], owner: pid_t) -> [CGRect] {
        windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0.05,
                  let value = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: value as CFDictionary)
        }
    }

    // MARK: - Persistence

    private func persist() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        settings.pauseOnBattery = pauseOnBattery
        settings.pauseOnLowPower = pauseOnLowPower
        settings.saveEnergyOnBattery = saveEnergyOnBattery
        settings.reduceScenesBehindApps = reduceScenesBehindApps
        store.save(settings)
    }

    /// A save that waits half a second before hitting the disk, for values
    /// that change in rapid bursts. Any direct persist() call in the
    /// meantime writes everything anyway, so nothing can get lost — the
    /// only way to skip a pending save entirely is quitting, and
    /// shutdown() flushes for that.
    private func schedulePersist() {
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.persist() }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Non-sandboxed fallback: a plain bookmark still survives renames/moves.
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    private func resolveBookmark(_ data: Data, forKey key: String) -> URL? {
        var stale = false
        let url = (try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )) ?? (try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ))
        guard let url else { return nil }
        if stale, let fresh = try? Self.makeBookmark(for: url) {
            settings.assignments[key]?.bookmark = fresh
            persist()
        }
        return url
    }

    private func rebuildDisplayStates() {
        var states: [DisplayState] = []
        var seen = Set<String>()
        for screen in NSScreen.screens {
            guard let key = screen.displayKey, !seen.contains(key),
                  let controller = controllers[key] else { continue }
            seen.insert(key)
            let assignment = settings.assignments[key]
            let scale = screen.backingScaleFactor
            let pixels = "\(Int(screen.frame.width * scale)) × \(Int(screen.frame.height * scale))"
            states.append(DisplayState(
                id: key,
                name: screen.localizedName,
                resolutionText: pixels,
                videoURL: controller.videoURL,
                scaling: controller.videoURL.map { scaling(for: $0) } ?? .fill,
                isMuted: assignment?.muted ?? true,
                volume: assignment?.volume ?? 1.0,
                trimStart: assignment?.trimStart,
                trimEnd: assignment?.trimEnd
            ))
        }
        // Reconciles fire on every screen-parameter notification, and most
        // of the time nothing user-visible changed. Publishing only real
        // changes saves SwiftUI from re-rendering the panel for nothing.
        if states != displayStates {
            displayStates = states
        }
    }
}
