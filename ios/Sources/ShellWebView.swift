import LocalAuthentication
import os
import SwiftUI
import UIKit
import WebKit

/// WKWebView wrapper with the native side of bridge contract v1.
///
/// The shared shim (Resources/native-bridge.js, copy of /bridge/native-bridge.js)
/// is injected as a WKUserScript; calls arrive via the "a2u5Bridge" message
/// handler and are settled through window.__a2u5BridgeResolve(id, result, error).
///
/// Only the main frame of a page from the configured endpoint's origin may use
/// the bridge. IdP login pages and sites an app links to load in the same
/// WebView; the user script reaches them too, but every call they make is
/// rejected with "forbidden". Calls from frames inside a page are ignored.
struct ShellWebView: UIViewRepresentable {
    let url: URL
    /// The configured endpoint (not a deep link): its origin is the one the
    /// bridge serves.
    var bridgeEndpoint: URL?
    /// Increment to force a reload (session-expiry handling, see RootView).
    var reloadToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        if let shimURL = Bundle.main.url(forResource: "native-bridge", withExtension: "js"),
           let shim = try? String(contentsOf: shimURL) {
            controller.addUserScript(WKUserScript(
                source: shim,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
        }
        controller.add(context.coordinator, name: "a2u5Bridge")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        // Debug builds only: lets Safari's Web Inspector attach, so the bridge
        // methods without a framework control can be called from the console
        // (docs/TESTING.md section 1). Before 16.4 debug builds are inspectable
        // without asking.
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        context.coordinator.webView = webView
        context.coordinator.allowedOrigin = Coordinator.origin(of: bridgeEndpoint)
        // what is loaded here is not loaded again by the first updateUIView
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastRequestedURL = url.absoluteString
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedOrigin = Coordinator.origin(of: bridgeEndpoint)
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.lastRequestedURL = url.absoluteString
            webView.load(URLRequest(url: url))
            return
        }
        if context.coordinator.lastRequestedURL != url.absoluteString {
            context.coordinator.lastRequestedURL = url.absoluteString
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var lastReloadToken = 0
        var lastRequestedURL: String?
        /// `scheme://host:port` of the configured endpoint; nil allows nothing.
        var allowedOrigin: String?

        static func origin(of url: URL?) -> String? {
            guard let url, let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }

        /// WKSecurityOrigin reports port 0 for the scheme's default port.
        static func origin(of frame: WKFrameInfo) -> String {
            let origin = frame.securityOrigin
            let scheme = origin.protocol.lowercased()
            let port = origin.port != 0 ? origin.port : (scheme == "https" ? 443 : 80)
            return "\(scheme)://\(origin.host.lowercased()):\(port)"
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "a2u5Bridge",
                  let body = message.body as? [String: Any],
                  let id = body["id"] as? String,
                  let method = body["method"] as? String else { return }

            // A frame inside the page gets no answer: it would land in the
            // main frame and could settle one of that page's own calls.
            guard message.frameInfo.isMainFrame else { return }
            // The answer goes back only to a main frame of this origin (see
            // resolve): a scan or a biometric prompt can outlast the page.
            let callOrigin = Self.origin(of: message.frameInfo)
            let answer: (String, String?) -> Void = { [weak self] resultJSON, error in
                self?.resolve(id: id, callOrigin: callOrigin, resultJSON: resultJSON, error: error)
            }
            guard let allowedOrigin, callOrigin == allowedOrigin else {
                answer("null", "forbidden")
                return
            }

            switch method {
            case "getDeviceInfo":
                let device = UIDevice.current
                let info: [String: String] = [
                    "platform": "ios",
                    "model": device.model,
                    "osVersion": device.systemVersion,
                    "appVersion": Bundle.main
                        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                ]
                answer(jsonString(info), nil)

            case "showToast":
                let text = body["text"] as? String ?? ""
                showToast(text)
                answer("null", nil)

            case "scanBarcode":
                BarcodeScanner.present { [weak self] value, error in
                    if let value {
                        answer(self?.jsonString(value) ?? "null", nil)
                    } else {
                        answer("null", error ?? "cancelled")
                    }
                }

            case "getPushToken":
                if let token = UserDefaults.standard.string(forKey: "push_token") {
                    answer(jsonString(token), nil)
                } else {
                    answer("null", "unavailable")
                }

            case "biometricConfirm":
                let reason = (body["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Confirm action"
                let context = LAContext()
                var laError: NSError?
                guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &laError) else {
                    answer("null", "unavailable")
                    return
                }
                context.evaluatePolicy(.deviceOwnerAuthentication,
                                       localizedReason: reason) { success, _ in
                    answer(success ? "true" : "false", nil)
                }

            default:
                answer("null", "unknown method \(method)")
            }
        }

        /// Settles a call through `__a2u5BridgeResolve` — only while the main
        /// frame still has [callOrigin], the origin it had when the call was
        /// made. A late answer (a scan, a biometric prompt) after the main
        /// frame navigated elsewhere would otherwise reach a page that never
        /// asked, through a function that page can overwrite: it is dropped.
        private func resolve(id: String, callOrigin: String, resultJSON: String, error: String?) {
            let errorJSON = error.map { jsonString($0) } ?? "null"
            let js = "window.__a2u5BridgeResolve(\(jsonString(id)), \(resultJSON), \(errorJSON))"
            DispatchQueue.main.async { [weak self] in
                guard let webView = self?.webView else { return }
                guard Coordinator.origin(of: webView.url) == callOrigin else {
                    Coordinator.log.warning(
                        "Bridge answer \(id, privacy: .public) dropped: the main frame left \(callOrigin, privacy: .public)")
                    return
                }
                webView.evaluateJavaScript(js)
            }
        }

        private static let log = Logger(subsystem: "org.abap2ui5.mobileshell", category: "bridge")

        private func jsonString(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject([value]),
                  let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let wrapped = String(data: data, encoding: .utf8) else { return "null" }
            // Strip the wrapping array brackets to get a bare JSON literal.
            return String(wrapped.dropFirst().dropLast())
        }

        /// Minimal toast: transient label overlay on the key window.
        private func showToast(_ text: String) {
            DispatchQueue.main.async {
                guard let window = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
                let label = UILabel()
                label.text = text
                label.textAlignment = .center
                label.textColor = .white
                label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
                label.font = .preferredFont(forTextStyle: .callout)
                label.numberOfLines = 0
                label.layer.cornerRadius = 12
                label.clipsToBounds = true
                label.alpha = 0
                let maxWidth = window.bounds.width - 48
                let size = label.sizeThatFits(CGSize(width: maxWidth - 32, height: .greatestFiniteMagnitude))
                label.frame = CGRect(
                    x: (window.bounds.width - size.width - 32) / 2,
                    y: window.bounds.height - size.height - 120,
                    width: size.width + 32,
                    height: size.height + 20)
                window.addSubview(label)
                UIView.animate(withDuration: 0.2) { label.alpha = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    UIView.animate(withDuration: 0.3, animations: { label.alpha = 0 }) { _ in
                        label.removeFromSuperview()
                    }
                }
            }
        }
    }
}
