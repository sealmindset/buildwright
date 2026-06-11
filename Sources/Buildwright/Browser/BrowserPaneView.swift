import SwiftUI
import WebKit

/// Cached WKWebViews keyed by browser tab so tabs survive layout churn and
/// pane re-renders, same as terminals do.
@MainActor
final class WebViewCache {
    static let shared = WebViewCache()
    private var views: [UUID: WKWebView] = [:]              // tab id → web view
    private var delegates: [UUID: BrowserTabDelegate] = [:] // retained here (WKWebView holds delegates weakly)

    func view(for tab: BrowserTab, in pane: Pane, app: AppState) -> WKWebView {
        if let existing = views[tab.id] { return existing }
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        adopt(wv, tabID: tab.id, paneID: pane.id, app: app)
        if let urlString = tab.url, let url = URL(string: urlString) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    /// Wire a web view to a tab — used both for views we create ourselves and
    /// for ones WebKit hands us when a page opens a new window (target=_blank).
    func adopt(_ wv: WKWebView, tabID: UUID, paneID: UUID, app: AppState) {
        wv.allowsBackForwardNavigationGestures = true
        let delegate = BrowserTabDelegate(paneID: paneID, tabID: tabID, app: app)
        wv.navigationDelegate = delegate
        wv.uiDelegate = delegate
        delegates[tabID] = delegate
        views[tabID] = wv
    }

    func removeTab(_ tabID: UUID) {
        views.removeValue(forKey: tabID)
        delegates.removeValue(forKey: tabID)
    }

    /// Drop every tab belonging to a closing pane.
    func remove(_ pane: Pane) {
        for tab in pane.browserTabs ?? [] { removeTab(tab.id) }
    }
}

/// Per-tab WebKit delegate: keeps the model in sync with navigation and turns
/// "open in new window" requests into new tabs.
@MainActor
final class BrowserTabDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let paneID: UUID
    private let tabID: UUID
    private weak var app: AppState?

    init(paneID: UUID, tabID: UUID, app: AppState) {
        self.paneID = paneID
        self.tabID = tabID
        self.app = app
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        app?.updateBrowserTab(paneID: paneID, tabID: tabID,
                              url: webView.url?.absoluteString, title: webView.title)
    }

    /// ⌘-click a link → open it in a new tab.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url, let app {
            app.addBrowserTab(paneID: paneID, url: url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// target=_blank / window.open → new tab (previously these silently did nothing).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let app, navigationAction.targetFrame == nil else { return nil }
        let tab = app.addBrowserTab(paneID: paneID,
                                    url: navigationAction.request.url?.absoluteString)
        // WebKit requires the returned view to use the configuration it gave us,
        // and loads the request into it itself.
        let wv = WKWebView(frame: .zero, configuration: configuration)
        WebViewCache.shared.adopt(wv, tabID: tab.id, paneID: paneID, app: app)
        return wv
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    @EnvironmentObject var app: AppState
    let tab: BrowserTab
    let pane: Pane

    func makeNSView(context: Context) -> WKWebView {
        WebViewCache.shared.view(for: tab, in: pane, app: app)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserPaneView: View {
    @EnvironmentObject var app: AppState
    let pane: Pane
    @State private var addressText: String = ""
    @FocusState private var addressFocused: Bool

    private var tabs: [BrowserTab] { pane.browserTabs ?? [] }
    private var activeTab: BrowserTab? { pane.activeBrowserTab }
    private var webView: WKWebView? {
        activeTab.map { WebViewCache.shared.view(for: $0, in: pane, app: app) }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            addressBar
            if let tab = activeTab {
                WebViewRepresentable(tab: tab, pane: pane)
                    .id(tab.id)
            } else {
                Spacer()
            }
        }
        .onAppear { syncToActiveTab() }
        .onChange(of: pane.activeBrowserTabID) { _, _ in syncToActiveTab() }
        .onChange(of: activeTab?.url) { _, newURL in
            if !addressFocused { addressText = newURL ?? "" }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        tabButton(tab)
                    }
                }
            }
            Button { app.addBrowserTab(paneID: pane.id) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("New tab")
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private func tabButton(_ tab: BrowserTab) -> some View {
        let isActive = tab.id == activeTab?.id
        return HStack(spacing: 5) {
            Text(label(for: tab))
                .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Button { app.closeBrowserTab(paneID: pane.id, tabID: tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: 160)
        .background(isActive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { app.selectBrowserTab(paneID: pane.id, tabID: tab.id) }
        .help(tab.url ?? "new tab")
    }

    private func label(for tab: BrowserTab) -> String {
        if let t = tab.title, !t.isEmpty { return t }
        if let u = tab.url, let host = URL(string: u)?.host { return host }
        return "new tab"
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
            Button { webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
            TextField("URL", text: $addressText, onCommit: navigate)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($addressFocused)
        }
        .padding(6)
    }

    private func syncToActiveTab() {
        addressText = activeTab?.url ?? ""
        // A fresh blank tab: put the cursor in the address bar so you can just type.
        if addressText.isEmpty { addressFocused = true }
    }

    private func navigate() {
        guard let tab = activeTab else { return }
        var raw = addressText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        if !raw.contains("://") {
            raw = raw.contains(".") && !raw.contains(" ") ? "https://\(raw)"
                : "https://www.google.com/search?q=\(raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)"
        }
        guard let url = URL(string: raw) else { return }
        webView?.load(URLRequest(url: url))
        addressText = raw
        app.updateBrowserTab(paneID: pane.id, tabID: tab.id, url: raw, title: nil)
    }
}
