import AppKit
import WebKit

@MainActor
final class WebViewManager: NSObject {
    private let appState: AppState
    private var webView: WKWebView?
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func showLoginWindow() {
        AppLog.info("Showing Doubao login window")
        ensureWebView()
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func logOut() {
        AppLog.info("Logging out")
        ASRParamsStore.clear()
        appState.loginStatus = .notLoggedIn
        window?.orderOut(nil)
        webView?.loadHTMLString("", baseURL: nil)

        let dataStore = WKWebsiteDataStore.default()
        dataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains("doubao.com") {
                dataStore.httpCookieStore.delete(cookie)
            }
        }
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let doubaoRecords = records.filter { $0.displayName.localizedCaseInsensitiveContains("doubao") }
            guard !doubaoRecords.isEmpty else { return }
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: doubaoRecords) {
                AppLog.info("Doubao website data cleared records=\(doubaoRecords.count)")
            }
        }
    }

    private func ensureWebView() {
        if webView != nil { return }
        AppLog.info("Creating Doubao WKWebView")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = DoubaoClient.userAgent
        self.webView = webView

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Login to Doubao"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        self.window = window

        let url = URL(string: "https://www.doubao.com/chat")!
        AppLog.info("Loading Doubao login URL \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    func extractAndSaveASRParams() async -> Bool {
        ensureWebView()
        guard let webView else {
            AppLog.error("Extract ASR params failed: webView missing")
            return false
        }
        AppLog.info("Extracting ASR params from WebView")

        let cookies = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let doubaoCookies = cookies.filter { $0.domain.contains("doubao.com") }
        let cookieNames = doubaoCookies.map(\.name).sorted().joined(separator: ",")
        AppLog.info("Doubao cookie candidates count=\(doubaoCookies.count) names=\(cookieNames)")

        var deviceId = ""
        if let raw = try? await webView.evaluateJavaScript("localStorage.getItem('samantha_web_web_id')") as? String,
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            deviceId = json["web_id"] as? String ?? ""
        }

        var webId = ""
        if let raw = try? await webView.evaluateJavaScript("localStorage.getItem('__tea_cache_tokens_497858')") as? String,
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            webId = json["web_id"] as? String ?? ""
        }

        let params = DoubaoASRParams(httpCookies: doubaoCookies, deviceId: deviceId, webId: webId)
        guard !doubaoCookies.isEmpty, !deviceId.isEmpty, !webId.isEmpty, params.hasRequiredAuthCookies else {
            AppLog.error("Extract ASR params failed cookieCount=\(doubaoCookies.count) hasAuthCookies=\(params.hasRequiredAuthCookies) deviceIdSet=\(!deviceId.isEmpty) webIdSet=\(!webId.isEmpty)")
            return false
        }

        ASRParamsStore.save(params)
        appState.loginStatus = .loggedIn
        teardownWebView()
        AppLog.info("ASR params extracted and saved")
        return true
    }

    private func teardownWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        webView = nil
        AppLog.info("Doubao WebView torn down to free resources")
    }
}

extension WebViewManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            AppLog.info("Doubao WebView navigation finished")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = await self.extractAndSaveASRParams()
        }
    }
}
