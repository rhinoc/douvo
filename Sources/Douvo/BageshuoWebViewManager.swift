import AppKit
import WebKit

@MainActor
final class BageshuoWebViewManager: NSObject {
    private let appState: AppState
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loginMonitorTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func showLoginWindow() {
        AppLog.info("Showing Bage Shuo login window")
        ensureWebView()
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startLoginMonitor()
    }

    func extractAndSaveASRParams() async -> Bool {
        guard webView != nil, window?.isVisible == true else {
            AppLog.info("Extract Bage Shuo params deferred until login window is visible")
            return false
        }

        guard let params = await currentASRParams() else {
            AppLog.error("Extract Bage Shuo params failed: official login page has no usable Youdao session")
            return false
        }

        BageshuoASRParamsStore.save(params)
        appState.loginStatus = .loggedIn
        teardownWebView()
        AppLog.info("Bage Shuo params extracted and saved")
        return true
    }

    func logOut() {
        AppLog.info("Logging out of Bage Shuo")
        loginMonitorTask?.cancel()
        loginMonitorTask = nil
        BageshuoASRParamsStore.clear()
        BageshuoVocabularyStore.clear()
        appState.loginStatus = .notLoggedIn
        window?.orderOut(nil)
        webView?.loadHTMLString("", baseURL: nil)

        let dataStore = WKWebsiteDataStore.default()
        dataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where Self.isYoudaoDomain(cookie.domain) {
                dataStore.httpCookieStore.delete(cookie)
            }
        }
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let youdaoRecords = records.filter {
                $0.displayName.localizedCaseInsensitiveContains("youdao")
            }
            guard !youdaoRecords.isEmpty else { return }
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: youdaoRecords
            ) {
                AppLog.info("Bage Shuo website data cleared records=\(youdaoRecords.count)")
            }
        }
        teardownWebView()
    }

    private func ensureWebView() {
        if webView != nil { return }
        AppLog.info("Creating Bage Shuo WKWebView")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 760),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.customUserAgent = DoubaoClient.userAgent
        self.webView = webView

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text(en: "Login to Bage Shuo", zh: "登录叭哥说")
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let url = URL(string: "https://shared.youdao.com/dict/application/bageshuo-login-h5/index.html")!
        AppLog.info("Loading Bage Shuo login URL \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    private func startLoginMonitor() {
        loginMonitorTask?.cancel()
        loginMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.window?.isVisible == true else { return }
                if await self.extractAndSaveASRParams() {
                    return
                }
            }
        }
    }

    private func currentASRParams() async -> BageshuoASRParams? {
        guard let webView, window?.isVisible == true else {
            return nil
        }
        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let youdaoCookies = cookies.filter { Self.isYoudaoDomain($0.domain) }
        let params = BageshuoASRParams(httpCookies: youdaoCookies)
        guard !youdaoCookies.isEmpty, params.hasRequiredAuthCookies else {
            return nil
        }
        return params
    }

    private func teardownWebView() {
        loginMonitorTask?.cancel()
        loginMonitorTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        webView = nil
        AppLog.info("Bage Shuo WebView torn down")
    }

    private static func isYoudaoDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "youdao.com" || normalized.hasSuffix(".youdao.com")
    }
}

extension BageshuoWebViewManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        teardownWebView()
    }
}

extension BageshuoWebViewManager: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.request.url?.scheme == "bageshuo-login" {
            decisionHandler(.cancel)
            Task { @MainActor in
                _ = await self.extractAndSaveASRParams()
            }
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            AppLog.info("Bage Shuo WebView navigation finished")
        }
    }
}
