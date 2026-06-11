import Testing
import Foundation
@testable import Buildwright

struct BrowserTabTests {
    func browserPane(url: String? = "https://example.com") -> Pane {
        Pane(kind: .browser, title: "browser", directory: "/tmp", url: url)
    }

    @Test func newBrowserPaneSeedsOneTab() {
        let p = browserPane()
        #expect(p.browserTabs?.count == 1)
        #expect(p.activeBrowserTab?.url == "https://example.com")
        #expect(p.activeBrowserTabID == p.browserTabs?.first?.id)
    }

    @Test func terminalPanesHaveNoTabs() {
        let p = Pane(kind: .shell, title: "shell", directory: "/tmp")
        #expect(p.browserTabs == nil)
        #expect(p.activeBrowserTab == nil)
    }

    @Test func addTabActivatesAndIsBlank() {
        var p = browserPane()
        let tab = p.addBrowserTab()
        #expect(p.browserTabs?.count == 2)
        #expect(p.activeBrowserTabID == tab.id)
        #expect(tab.url == nil)
    }

    @Test func closeActiveTabSelectsRightNeighbor() {
        var p = browserPane()
        let t2 = p.addBrowserTab(url: "https://two.test")
        let t3 = p.addBrowserTab(url: "https://three.test")
        p.selectBrowserTab(t2.id)
        let emptied = p.closeBrowserTab(t2.id)
        #expect(!emptied)
        #expect(p.activeBrowserTabID == t3.id)
        #expect(p.url == "https://three.test", "legacy url field follows the active tab")
    }

    @Test func closeLastRemainingTabReportsEmpty() {
        var p = browserPane()
        let only = p.browserTabs!.first!
        let emptied = p.closeBrowserTab(only.id)
        #expect(emptied)
        #expect(p.browserTabs?.isEmpty == true)
    }

    @Test func closeInactiveTabKeepsSelection() {
        var p = browserPane()
        let t2 = p.addBrowserTab(url: "https://two.test")
        let first = p.browserTabs!.first!
        _ = p.closeBrowserTab(first.id)
        #expect(p.activeBrowserTabID == t2.id)
        #expect(p.browserTabs?.count == 1)
    }

    @Test func updateTabSyncsLegacyURLOnlyWhenActive() {
        var p = browserPane()
        let t2 = p.addBrowserTab()
        p.updateBrowserTab(t2.id, url: "https://docs.test/page", title: "Docs")
        #expect(p.activeBrowserTab?.url == "https://docs.test/page")
        #expect(p.activeBrowserTab?.title == "Docs")
        #expect(p.url == "https://docs.test/page")

        let first = p.browserTabs!.first!
        p.updateBrowserTab(first.id, url: "https://other.test", title: nil)
        #expect(p.url == "https://docs.test/page", "inactive tab navigation must not steal the address bar")
    }

    @Test func selectUnknownTabIsIgnored() {
        var p = browserPane()
        let before = p.activeBrowserTabID
        p.selectBrowserTab(UUID())
        #expect(p.activeBrowserTabID == before)
    }

    @Test func normalizeSeedsTabFromLegacyStateFile() throws {
        // A pre-tab state file: browser pane persisted with just `url`.
        let json = """
        {"id":"\(UUID().uuidString)","kind":"browser","title":"browser","directory":"/tmp","url":"https://legacy.test"}
        """
        var p = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
        #expect(p.browserTabs == nil)
        p.normalizeBrowserTabs()
        #expect(p.browserTabs?.count == 1)
        #expect(p.activeBrowserTab?.url == "https://legacy.test")
        #expect(p.activeBrowserTabID == p.browserTabs?.first?.id)
    }

    @Test func normalizeLeavesExistingTabsAlone() {
        var p = browserPane()
        let t2 = p.addBrowserTab(url: "https://two.test")
        p.normalizeBrowserTabs()
        #expect(p.browserTabs?.count == 2)
        #expect(p.activeBrowserTabID == t2.id)
    }

    @Test func tabsRoundTripThroughPersistence() throws {
        var p = browserPane()
        let t2 = p.addBrowserTab(url: "https://two.test")
        p.updateBrowserTab(t2.id, url: nil, title: "Two")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Pane.self, from: data)
        #expect(decoded.browserTabs == p.browserTabs)
        #expect(decoded.activeBrowserTabID == t2.id)
    }
}
