import Testing
import Foundation
@testable import Buildwright

struct BookmarkTests {
    @Test func bookmarkRoundTrips() throws {
        let bm = Bookmark(title: "AWS Console", url: "https://console.aws.amazon.com")
        let data = try JSONEncoder().encode(bm)
        let decoded = try JSONDecoder().decode(Bookmark.self, from: data)
        #expect(decoded == bm)
    }

    @Test func workspaceWithoutBookmarksKeepsDecoding() throws {
        // A pre-bookmark state file: workspace persisted with no bookmarks key.
        let ws = Workspace(name: "docai", baseRepo: "/tmp")
        let data = try JSONEncoder().encode(ws) // bookmarks nil → key omitted
        #expect(!String(decoding: data, as: UTF8.self).contains("bookmarks"))
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded.bookmarks == nil)
    }

    @Test func workspaceBookmarksRoundTrip() throws {
        var ws = Workspace(name: "docai", baseRepo: "/tmp")
        ws.bookmarks = [
            Bookmark(title: "AWS", url: "https://console.aws.amazon.com"),
            Bookmark(title: "CI", url: "https://github.com/sealmindset/docai/actions")
        ]
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded.bookmarks == ws.bookmarks)
    }

    @Test func sharedBookmarksRoundTripInPersistedState() throws {
        let state = AppPersistedState(
            workspaces: [], activeWorkspaceID: nil, cvrPath: nil, sidebarVisible: nil,
            breakfixPrompt: nil, featurePrompt: nil, claudeSkipPermissions: nil,
            sharedBookmarks: [Bookmark(title: "GitHub", url: "https://github.com")]
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppPersistedState.self, from: data)
        #expect(decoded.sharedBookmarks?.count == 1)
        #expect(decoded.sharedBookmarks?.first?.title == "GitHub")
    }

    @Test func oldPersistedStateWithoutSharedBookmarksDecodes() throws {
        let json = #"{"workspaces":[]}"#
        let decoded = try JSONDecoder().decode(AppPersistedState.self, from: Data(json.utf8))
        #expect(decoded.sharedBookmarks == nil)
    }
}
