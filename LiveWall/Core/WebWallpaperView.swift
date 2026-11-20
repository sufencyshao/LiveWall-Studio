import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

private final class WebWallpaperFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "livewall-resource"
    let folder: URL

    init(folder: URL) { self.folder = folder }

    func url(for file: URL) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "wallpaper"
        components.path = String(file.path.dropFirst(folder.path.count))
        return components.url!
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "wallpaper",
              let file = WorkshopProjectFile.resolve(String(url.path.dropFirst()), in: folder),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let policy = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' data: blob:; connect-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Security-Policy": policy]) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

final class WebWallpaperView: NSView, WKNavigationDelegate {
    let webView: WKWebView
    private let viewport = NSView()
    private let canvasSize = CGSize(width: 16, height: 9)
    private let entryURL: URL
    private let properties: [String: Any]
    private let audioID = UUID()
    private var audioPreference: AnyCancellable?
    private var audioTimer: Timer?
    private var generation: UInt64?
    private var needsAudio = false
    private var paused = false
    private var loaded = false
    private var muted: Bool
    private var volume: Float
    private var scaling: ScalingMode
    private var position: FillPosition
    private let onFailure: () -> Void

    init(project: WorkshopWeb, frame: NSRect, muted: Bool, volume: Float,
         scaling: ScalingMode = .fill, position: FillPosition = .center, onFailure: @escaping () -> Void) {
        let files = WebWallpaperFiles(folder: project.folder)
        entryURL = files.url(for: project.entry)
        properties = project.properties
        self.onFailure = onFailure
        self.muted = muted
        self.volume = volume
        self.scaling = scaling
        self.position = position
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(files, forURLScheme: WebWallpaperFiles.scheme)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: Self.runtime, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        viewport.autoresizesSubviews = false
        addSubview(viewport)
        viewport.addSubview(webView)
        needsLayout = true
        audioPreference = WorkshopAudioCapture.shared.$enabled.combineLatest(WorkshopAudioCapture.shared.$webEnabled)
            .sink { [weak self] enabled, webEnabled in self?.updateAudio(active: enabled && webEnabled) }

        // Local-only mode blocks external loads before any wallpaper script runs.
        let rules = """
            [
              {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^file://"},"action":{"type":"block"}}
            ]
            """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LiveWallOffline-v1", encodedContentRuleList: rules) { [weak self] rules, _ in
            guard let self else { return }
            guard let rules else { self.onFailure(); return }
            self.webView.configuration.userContentController.add(rules)
            self.webView.load(URLRequest(url: self.entryURL))
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        audioTimer?.invalidate()
        WorkshopAudioCapture.shared.setDemand(false, for: audioID)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
        let fitSize = CGSize(width: canvasSize.width * fit, height: canvasSize.height * fit)
        let destination: CGRect
        let logicalSize: CGSize
        switch scaling {
        case .fill:
            destination = position.cropFrame(for: canvasSize, in: bounds, flipped: isFlipped)
            logicalSize = destination.size
        case .fit:
            destination = CGRect(x: bounds.midX - fitSize.width / 2, y: bounds.midY - fitSize.height / 2,
                                 width: fitSize.width, height: fitSize.height)
            logicalSize = fitSize
        case .stretch:
            destination = bounds
            logicalSize = fitSize
        }
        viewport.frame = destination
        viewport.bounds = CGRect(origin: .zero, size: logicalSize)
        webView.frame = viewport.bounds
    }

    func setFraming(_ scaling: ScalingMode, position: FillPosition) {
        guard self.scaling != scaling || self.position != position else { return }
        self.scaling = scaling
        self.position = position
        needsLayout = true
    }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        applyPlayback()
        updateAudio()
    }

    func setSound(muted: Bool, volume: Float) {
        self.muted = muted
        self.volume = volume
        applyPlayback()
    }

    private func applyPlayback() {
        guard loaded else { return }
        webView.setAllMediaPlaybackSuspended(paused, completionHandler: nil)
        webView.callAsyncJavaScript("window.__livewallPlayback(paused, muted, volume)", arguments: [
            "paused": paused, "muted": muted, "volume": volume
        ], in: nil, in: .page, completionHandler: nil)
    }

    private func updateAudio(active: Bool? = nil) {
        let capture = WorkshopAudioCapture.shared
        let wantsAudio = needsAudio && !paused && (active ?? (capture.enabled && capture.webEnabled))
        capture.setDemand(wantsAudio, for: audioID)
        if wantsAudio, audioTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.sendAudio() }
            timer.tolerance = 0.005
            RunLoop.main.add(timer, forMode: .common)
            audioTimer = timer
        } else if !wantsAudio {
            audioTimer?.invalidate()
            audioTimer = nil
            generation = nil
        }
    }

    private func sendAudio() {
        guard let sample = WorkshopAudioCapture.shared.spectrum(), sample.generation != generation else { return }
        generation = sample.generation
        webView.callAsyncJavaScript("window.__livewallAudio(bands)", arguments: ["bands": sample.bands],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == entryURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        applyPlayback()
        webView.callAsyncJavaScript("""
            window.wallpaperPropertyListener?.applyUserProperties?.(properties);
            return window.__livewallHasAudio();
            """, arguments: ["properties": properties], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.needsAudio = (try? result.get()) as? Bool == true
            self.updateAudio()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }

    private static let runtime = """
        (() => {
            let audioListener;
            window.wallpaperRegisterAudioListener = callback => { audioListener = callback };
            window.__livewallHasAudio = () => typeof audioListener === 'function';
            window.__livewallAudio = bands => audioListener?.(bands);
            window.RTCPeerConnection = undefined;
            window.webkitRTCPeerConnection = undefined;
            const request = window.requestAnimationFrame.bind(window);
            const cancel = window.cancelAnimationFrame.bind(window);
            let native = null, counter = 0, paused = false;
            const callbacks = new Map();
            const tick = time => {
                native = null;
                if (paused) return;
                for (const id of Array.from(callbacks.keys())) {
                    const callback = callbacks.get(id);
                    callbacks.delete(id);
                    try { callback?.(time) } catch(error) { console.error(error) }
                }
                schedule();
            };
            const schedule = () => {
                if (!paused && native === null && callbacks.size) native = request(tick);
            };
            window.requestAnimationFrame = callback => {
                callbacks.set(++counter, callback);
                schedule();
                return counter;
            };
            window.cancelAnimationFrame = id => callbacks.delete(id);
            let muted = true, volume = 0;
            const audio = element => {
                element.muted = muted;
                element.volume = volume;
            };
            document.addEventListener('play', event => {
                if (event.target instanceof HTMLMediaElement) audio(event.target);
            }, true);
            window.__livewallPlayback = (pause, silence, level) => {
                paused = pause;
                muted = silence;
                volume = level;
                document.querySelectorAll('video,audio').forEach(audio);
                if (paused && native !== null) { cancel(native); native = null; }
                schedule();
            };
        })();
        """
}
