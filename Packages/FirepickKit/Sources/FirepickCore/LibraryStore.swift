import Foundation
import GRDB

public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(sourceKey)|\(item.vodId)|\(episodeId)" }
    public var sourceKey: String
    public var item: MediaItem
    public var episodeId: String
    public var episodeName: String
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public init(
        sourceKey: String,
        item: MediaItem,
        episodeId: String,
        episodeName: String,
        position: Double,
        duration: Double,
        updatedAt: Date = .now
    ) {
        self.sourceKey = sourceKey
        self.item = item
        self.episodeId = episodeId
        self.episodeName = episodeName
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

public struct FavoriteEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(sourceKey)|\(item.vodId)" }
    public var sourceKey: String
    public var item: MediaItem
    public var createdAt: Date

    public init(sourceKey: String, item: MediaItem, createdAt: Date = .now) {
        self.sourceKey = sourceKey
        self.item = item
        self.createdAt = createdAt
    }
}

public actor LibraryStore {
    private let dbQueue: DatabaseQueue

    public init(path: String? = nil) throws {
        let databasePath: String
        if let path {
            databasePath = path
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            databasePath = base.appendingPathComponent("Firepick.sqlite").path
        }

        dbQueue = try DatabaseQueue(path: databasePath)
        try Self.migrator.migrate(dbQueue)
    }

    public func saveHistory(_ entry: HistoryEntry) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO history
                    (source_key, vod_id, item_json, episode_id, episode_name, position, duration, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_key, vod_id, episode_id) DO UPDATE SET
                    item_json = excluded.item_json,
                    episode_name = excluded.episode_name,
                    position = excluded.position,
                    duration = excluded.duration,
                    updated_at = excluded.updated_at
                """, arguments: [
                    entry.sourceKey,
                    entry.item.vodId,
                    String(decoding: try JSONEncoder().encode(entry.item), as: UTF8.self),
                    entry.episodeId,
                    entry.episodeName,
                    entry.position,
                    entry.duration,
                    entry.updatedAt,
                ])
        }
    }

    public func history(limit: Int = 100) throws -> [HistoryEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM history ORDER BY updated_at DESC LIMIT ?",
                arguments: [limit]
            )
            return try rows.map { row in
                let itemData = Data((row["item_json"] as String).utf8)
                return HistoryEntry(
                    sourceKey: row["source_key"],
                    item: try JSONDecoder().decode(MediaItem.self, from: itemData),
                    episodeId: row["episode_id"],
                    episodeName: row["episode_name"],
                    position: row["position"],
                    duration: row["duration"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    public func saveFavorite(_ entry: FavoriteEntry) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO favorites
                    (source_key, vod_id, item_json, created_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [
                    entry.sourceKey,
                    entry.item.vodId,
                    String(decoding: try JSONEncoder().encode(entry.item), as: UTF8.self),
                    entry.createdAt,
                ])
        }
    }

    public func removeFavorite(sourceKey: String, vodId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM favorites WHERE source_key = ? AND vod_id = ?",
                arguments: [sourceKey, vodId]
            )
        }
    }

    public func removeHistory(sourceKey: String, vodId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM history WHERE source_key = ? AND vod_id = ?",
                arguments: [sourceKey, vodId]
            )
        }
    }

    public func favorites() throws -> [FavoriteEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM favorites ORDER BY created_at DESC"
            )
            return try rows.map { row in
                let data = Data((row["item_json"] as String).utf8)
                return FavoriteEntry(
                    sourceKey: row["source_key"],
                    item: try JSONDecoder().decode(MediaItem.self, from: data),
                    createdAt: row["created_at"]
                )
            }
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "history") { table in
                table.column("source_key", .text).notNull()
                table.column("item_json", .text).notNull()
                table.column("episode_id", .text).notNull()
                table.column("episode_name", .text).notNull()
                table.column("position", .double).notNull()
                table.column("duration", .double).notNull()
                table.column("updated_at", .datetime).notNull()
                table.primaryKey(["source_key", "item_json", "episode_id"])
            }
            try db.create(table: "favorites") { table in
                table.column("source_key", .text).notNull()
                table.column("vod_id", .text).notNull()
                table.column("item_json", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.primaryKey(["source_key", "vod_id"])
            }
        }
        migrator.registerMigration("v2-history-by-vod") { db in
            try db.create(table: "history_v2") { table in
                table.column("source_key", .text).notNull()
                table.column("vod_id", .text).notNull()
                table.column("item_json", .text).notNull()
                table.column("episode_id", .text).notNull()
                table.column("episode_name", .text).notNull()
                table.column("position", .double).notNull()
                table.column("duration", .double).notNull()
                table.column("updated_at", .datetime).notNull()
                table.primaryKey(["source_key", "vod_id", "episode_id"])
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO history_v2
                    (source_key, vod_id, item_json, episode_id, episode_name,
                     position, duration, updated_at)
                SELECT source_key,
                       json_extract(item_json, '$.vod_id'),
                       item_json,
                       episode_id,
                       episode_name,
                       position,
                       duration,
                       updated_at
                FROM history
                ORDER BY updated_at ASC
                """)
            try db.drop(table: "history")
            try db.rename(table: "history_v2", to: "history")
        }
        return migrator
    }
}

