import SwiftUI
import WebKit

/// Cached WKWebViews so browser panes survive layout churn like terminals do.
@MainActor
final class WebViewCache {
    static let shared = WebViewCache()
    private var views: [UUID: WKWebView] = [:]

    func view(for pane: Pane) -> WKWebView {
        if let existing = views[pane.id] { return existing }
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        if let urlString = pane.url, let url = URL(string: urlString) {
            wv.load(URLRequest(url: url))
        }
        views[pane.id] = wv
        return wv
    }

    func remove(_ paneID: UUID) {
        views.removeValue(forKey: paneID)
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let pane: Pane

    func makeNSView(context: Context) -> WKWebView {
        WebViewCache.shared.view(for: pane)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserPaneView: View {
    @EnvironmentObject var app: AppState
    let pane: Pane
    @State private var addressText: String = ""

    private var webView: WKWebView { WebViewCache.shared.view(for: pane) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Button { webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                Button { webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                TextField("URL", text: $addressText, onCommit: navigate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
            .padding(6)
            WebViewRepresentable(pane: pane)
        }
        .onAppear { addressText = pane.url ?? "" }
    }

    private func navigate() {
        var raw = addressText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        if !raw.contains("://") {
            raw = raw.contains(".") && !raw.contains(" ") ? "https://\(raw)"
                : "https://www.google.com/search?q=\(raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)"
        }
        guard let url = URL(string: raw) else { return }
        webView.load(URLRequest(url: url))
        addressText = raw
        app.updateBrowserURL(paneID: pane.id, url: raw)
    }
}
