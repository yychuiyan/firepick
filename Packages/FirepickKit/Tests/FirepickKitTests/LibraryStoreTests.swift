import Foundation
import Testing
@testable import FirepickCore

struct LibraryStoreTests {
    @Test
    func historyAndFavoritesRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try LibraryStore(path: directory.appendingPathComponent("test.sqlite").path)
        let item = MediaItem(vodId: "movie-1", name: "示例影片")
        let history = HistoryEntry(
            sourceKey: "demo",
            item: item,
            episodeId: "ep-1",
            episodeName: "第1集",
            position: 42,
            duration: 120
        )
        try await store.saveHistory(history)
        try await store.saveFavorite(FavoriteEntry(sourceKey: "demo", item: item))

        let entries = try await store.history()
        let favorites = try await store.favorites()
        #expect(entries.first?.position == 42)
        #expect(favorites.first?.item.name == "示例影片")
    }

    @Test
    func historyUpdatesDeduplicateAndCanBeRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try LibraryStore(path: directory.appendingPathComponent("test.sqlite").path)
        let first = HistoryEntry(
            sourceKey: "demo",
            item: MediaItem(vodId: "1", name: "旧名称"),
            episodeId: "1",
            episodeName: "第1集",
            position: 10,
            duration: 100
        )
        var updated = first
        updated.item.name = "新名称"
        updated.position = 30
        try await store.saveHistory(first)
        try await store.saveHistory(updated)

        let entries = try await store.history()
        #expect(entries.count == 1)
        #expect(entries.first?.item.name == "新名称")
        #expect(entries.first?.position == 30)

        try await store.removeHistory(sourceKey: "demo", vodId: "1")
        #expect(try await store.history().isEmpty)
    }
}

