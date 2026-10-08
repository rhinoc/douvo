import AppKit
import WebKit

enum ChatterflyJavaScriptCallback {
    static func script(callback: String, json: String) -> String? {
        guard let callbackData = try? JSONEncoder().encode(callback),
              let callbackLiteral = String(data: callbackData, encoding: .utf8),
              !json.isEmpty else {
            return nil
        }
        return "window[\(callbackLiteral)](\(json));"
    }
}

@MainActor
final class ChatterflyAuthWebViewManager: NSObject {
    private let encryptWallClient = ChatterflyEncryptWallClient()
    private var webView: WKWebView?
    private var window: NSWindow?
    private var bridgeHandler: ChatterflyBridgeMessageHandler?
    private var restoresAccessoryActivationPolicy = false
    var onLoginWindowVisibilityChanged: ((Bool) -> Void)?

    func showLoginWindow() {
        AppLog.info("Showing Chatterfly login window")
        ensureWebView()
        guard let window else { return }
        if NSApp.activationPolicy() == .accessory {
            restoresAccessoryActivationPolicy = NSApp.setActivationPolicy(.regular)
            AppLog.info("Chatterfly login activation policy regular=\(restoresAccessoryActivationPolicy)")
        }
        window.center()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onLoginWindowVisibilityChanged?(true)
        AppLog.info(
            "Chatterfly login window state visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) active=\(NSApp.isActive) firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }))"
        )
    }

    func logOut() {
        AppLog.info("Logging out of Chatterfly")
        ChatterflyAuthTokenStore.clear()
        webView?.loadHTMLString("", baseURL: nil)
        teardownWebView()
        clearWebsiteData()
    }

    private func ensureWebView() {
        if webView != nil { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let bridgeHandler = ChatterflyBridgeMessageHandler()
        bridgeHandler.owner = self
        for name in ChatterflyAuthBridgeParser.bridgeNames {
            configuration.userContentController.add(bridgeHandler, name: name)
        }

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 720),
            configuration: configuration
        )
        webView.navigationDelegate = self
        self.webView = webView
        self.bridgeHandler = bridgeHandler

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text(en: "Login to Chatterfly", zh: "登录 Chatterfly")
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let url = URL(string: "https://account.chatterfly.tencent.com/h5/login?loginType=phone")!
        AppLog.info("Loading Chatterfly login URL")
        clearWebsiteData()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    fileprivate func receiveBridgeMessage(name: String, bodyData: Data?, bodyString: String?) {
        switch name {
        case "ime.common.encryptWallRequest":
            handleEncryptWallRequest(bodyData: bodyData, bodyString: bodyString)
        case "ime.login.notifyClientLoginSuccess":
            guard let token = ChatterflyAuthBridgeParser.token(bodyData: bodyData, bodyString: bodyString) else {
                AppLog.error("Chatterfly login success bridge message did not contain an access token")
                return
            }
            finishLogin(token)
        case "ime.login.notifyClientLoginFailed":
            AppLog.error(
                "Chatterfly login page reported failure \(loginFailureDetails(bodyData: bodyData, bodyString: bodyString))"
            )
        case "ime.common.goBack":
            webView?.goBack()
        case "ime.common.getImeHRV", "ime.common.getQ36":
            if let callback = callbackName(bodyData: bodyData, bodyString: bodyString) {
                reply(callback: callback, object: ["code": 0, "data": [:]])
            }
        case "ime.common.closeLoading", "ime.common.beaconReport":
            break
        default:
            break
        }
    }

    private func finishLogin(_ token: ChatterflyAuthToken) {
        AppLog.info("Chatterfly login exchange succeeded; fetching user info")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let userInfo = try await self.encryptWallClient.fetchUserInfo(accessToken: token.accessToken)
                ChatterflyAuthTokenStore.save(token.withUserID(userInfo.userID))
                AppLog.info("Chatterfly login succeeded \(token.withUserID(userInfo.userID).debugInfo)")
                self.teardownWebView()
            } catch {
                AppLog.error("Chatterfly user info request failed error=\(error.localizedDescription)")
            }
        }
    }

    private func handleEncryptWallRequest(bodyData: Data?, bodyString: String?) {
        guard let parameter = ChatterflyAuthBridgeParser.parameter(bodyData: bodyData, bodyString: bodyString),
              let callback = ChatterflyAuthBridgeParser.callback(bodyData: bodyData, bodyString: bodyString),
              let urlString = parameter["url"] as? String else {
            AppLog.error("Chatterfly EncryptWall bridge request was incomplete")
            return
        }

        let body = requestBody(parameter["body"])
        let headers = requestHeaders(parameter["header"] ?? parameter["headers"])
        let targetURL = URL(string: urlString)
        AppLog.info(
            "Chatterfly EncryptWall bridge request host=\(targetURL?.host ?? "none") path=\(targetURL?.path ?? "none") method=\(parameter["method"] as? String ?? "POST") bodyBytes=\(body?.count ?? 0) bodyFields=\(requestBodyDetails(body)) parameterKeys=\(parameter.keys.sorted().joined(separator: ",")) headerKeys=\(headers.keys.sorted().joined(separator: ","))"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await self.encryptWallClient.request(
                    urlString: urlString,
                    method: "POST",
                    body: body,
                    headers: headers
                )
                AppLog.info("Chatterfly EncryptWall decoded response \(self.encryptWallResponseDetails(response))")
                self.reply(callback: callback, data: response)
            } catch {
                AppLog.error("Chatterfly EncryptWall request failed error=\(error.localizedDescription)")
                self.reply(callback: callback, object: [
                    "code": -1,
                    "msg": "EncryptWall request failed"
                ])
            }
        }
    }

    private func requestBody(_ value: Any?) -> Data? {
        if let body = value as? String {
            return body.data(using: .utf8)
        }
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [])
    }

    private func requestHeaders(_ value: Any?) -> [String: String] {
        var result = [String: String]()
        if let dictionary = value as? [String: Any] {
            result = dictionary.reduce(into: result) { result, entry in
                if let value = entry.value as? String, !value.isEmpty {
                    result[entry.key] = value
                } else if let value = entry.value as? NSNumber {
                    result[entry.key] = value.stringValue
                }
            }
        }
        // The native login bridge always adds this header; the web page does not.
        result["Content-Type"] = "application/json"
        return result
    }

    private func requestBodyDetails(_ body: Data?) -> String {
        guard let body else { return "none" }
        if let object = try? JSONSerialization.jsonObject(with: body),
           let dictionary = object as? [String: Any] {
            return dictionary.keys.sorted().map { key in
                guard let value = dictionary[key] else { return "\(key)=missing" }
                if let string = value as? String {
                    return "\(key)=string(length:\(string.count),empty:\(string.isEmpty))"
                }
                if let number = value as? NSNumber {
                    return "\(key)=number(\(number.stringValue))"
                }
                return "\(key)=\(String(describing: type(of: value)))"
            }.joined(separator: ",")
        }
        if let string = String(data: body, encoding: .utf8) {
            return "text(length:\(string.count),empty:\(string.isEmpty))"
        }
        return "binary(length:\(body.count))"
    }

    private func loginFailureDetails(bodyData: Data?, bodyString: String?) -> String {
        guard let payload = ChatterflyAuthBridgeParser.dictionary(bodyData: bodyData, bodyString: bodyString) else {
            return "payload=unparseable"
        }

        return "\(businessObjectDetails(label: "root", object: payload)) \(nestedBusinessObjectDetails(from: payload))"
    }

    private func encryptWallResponseDetails(_ response: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: response),
              let dictionary = object as? [String: Any] else {
            return "payload=nonDictionaryJSON bytes=\(response.count)"
        }
        return "\(businessObjectDetails(label: "root", object: dictionary)) \(nestedBusinessObjectDetails(from: dictionary))"
    }

    private func nestedBusinessObjectDetails(from object: [String: Any]) -> String {
        let nestedKeys = ["param", "data", "result", "error"]
        let details = nestedKeys.compactMap { key -> String? in
            guard let nested = jsonDictionary(object[key]) else { return nil }
            return businessObjectDetails(label: key, object: nested)
        }
        return details.joined(separator: " ")
    }

    private func businessObjectDetails(label: String, object: [String: Any]) -> String {
        let fields = [
            "code", "errCode", "retCode", "status", "msg", "message",
            "error", "failCode", "failMessage", "reason"
        ]
        let values = fields.compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            return "\(key)=\(safeLogValue(value))"
        }
        let keys = object.keys.sorted().joined(separator: ",")
        let fieldText = values.isEmpty ? "none" : values.joined(separator: " ")
        return "\(label){fields=\(fieldText) keys=\(keys.isEmpty ? "none" : keys)}"
    }

    private func jsonDictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private func safeLogValue(_ value: Any) -> String {
        if let string = value as? String {
            return string.count > 200 ? "<string length=\(string.count)>" : string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return "<\(String(describing: type(of: value)))>"
    }

    private func callbackName(bodyData: Data?, bodyString: String?) -> String? {
        ChatterflyAuthBridgeParser.callback(bodyData: bodyData, bodyString: bodyString)
    }

    private func reply(callback: String, data: Data) {
        guard let responseObject = try? JSONSerialization.jsonObject(with: data),
              let responseData = try? JSONSerialization.data(withJSONObject: responseObject),
              let responseJSON = String(data: responseData, encoding: .utf8) else {
            reply(callback: callback, object: ["code": -1, "msg": "Invalid EncryptWall response"])
            return
        }
        evaluateJavaScriptCallback(callback: callback, json: responseJSON)
    }

    private func reply(callback: String, object: [String: Any]) {
        guard let objectData = try? JSONSerialization.data(withJSONObject: object),
              let objectJSON = String(data: objectData, encoding: .utf8) else {
            return
        }
        evaluateJavaScriptCallback(callback: callback, json: objectJSON)
    }

    private func evaluateJavaScriptCallback(callback: String, json: String) {
        guard let script = ChatterflyJavaScriptCallback.script(callback: callback, json: json) else { return }
        webView?.evaluateJavaScript(script)
    }

    private func teardownWebView() {
        let wasOpen = window != nil || webView != nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        if wasOpen {
            onLoginWindowVisibilityChanged?(false)
        }
        if restoresAccessoryActivationPolicy {
            NSApp.setActivationPolicy(.accessory)
            restoresAccessoryActivationPolicy = false
            AppLog.info("Chatterfly login activation policy restored accessory=true")
        }
        window = nil
        webView = nil
        bridgeHandler = nil
        if wasOpen { AppLog.info("Chatterfly login WebView torn down") }
    }

    private func clearWebsiteData() {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where Self.isChatterflyDomain(cookie.domain) {
                dataStore.httpCookieStore.delete(cookie)
            }
        }
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let chatterflyRecords = records.filter {
                Self.isChatterflyDomain($0.displayName)
            }
            guard !chatterflyRecords.isEmpty else { return }
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: chatterflyRecords
            ) {
                AppLog.info("Chatterfly website data cleared records=\(chatterflyRecords.count)")
            }
        }
    }

    private static func isChatterflyDomain(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("chatterfly.tencent.com") || normalized.contains("yb.local")
    }
}

@MainActor
private final class ChatterflyBridgeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ChatterflyAuthWebViewManager?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let name = message.name
        let bodyString = message.body as? String
        let bodyData: Data?
        if bodyString != nil {
            bodyData = nil
        } else if JSONSerialization.isValidJSONObject(message.body) {
            bodyData = try? JSONSerialization.data(withJSONObject: message.body, options: [])
        } else {
            bodyData = nil
        }

        Task { @MainActor [weak owner] in
            owner?.receiveBridgeMessage(name: name, bodyData: bodyData, bodyString: bodyString)
        }
    }
}

extension ChatterflyAuthWebViewManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        teardownWebView()
    }
}

extension ChatterflyAuthWebViewManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            AppLog.info("Chatterfly login WebView navigation started url=\(webView.url?.absoluteString ?? "none")")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            AppLog.info("Chatterfly login WebView navigation committed url=\(webView.url?.absoluteString ?? "none")")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            AppLog.info("Chatterfly login WebView navigation finished url=\(webView.url?.absoluteString ?? "none")")
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            AppLog.error(
                "Chatterfly login WebView navigation failed url=\(webView.url?.absoluteString ?? "none") error=\(error.localizedDescription)"
            )
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            AppLog.error(
                "Chatterfly login WebView provisional navigation failed url=\(webView.url?.absoluteString ?? "none") error=\(error.localizedDescription)"
            )
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            AppLog.error("Chatterfly login WebView content process terminated")
        }
    }
}
