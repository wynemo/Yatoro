import Foundation
import MusicKit

struct PersistedQueue: Codable {
    var songs: [MusicItemID]
}

enum QueuePersistence {
    static let queueURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("Yatoro", isDirectory: true)
            .appendingPathComponent("queue.json", isDirectory: false)
    }()

    static func save(songs: [Song]) async {
        do {
            try FileManager.default.createDirectory(
                at: queueURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let persistedQueue = PersistedQueue(songs: songs.map(\.id))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(persistedQueue)
            try data.write(to: queueURL, options: .atomic)
            await logger?.debug("Saved queue to \(queueURL.path).")
        } catch {
            await logger?.error("Unable to save queue: \(error.localizedDescription)")
        }
    }

    static func load() async -> MusicItemCollection<Song>? {
        guard FileManager.default.fileExists(atPath: queueURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: queueURL)
            let persistedQueue = try JSONDecoder().decode(PersistedQueue.self, from: data)
            guard !persistedQueue.songs.isEmpty else {
                return nil
            }

            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                memberOf: persistedQueue.songs
            )
            request.limit = persistedQueue.songs.count
            let response = try await request.response()

            let songsByID = Dictionary(uniqueKeysWithValues: response.items.map { ($0.id, $0) })
            let songs = persistedQueue.songs.compactMap { songsByID[$0] }
            guard !songs.isEmpty else {
                await logger?.debug("Queue file did not contain restorable songs.")
                return nil
            }

            if songs.count != persistedQueue.songs.count {
                await logger?.warning(
                    "Restored \(songs.count) of \(persistedQueue.songs.count) queued songs."
                )
            }
            return MusicItemCollection(songs)
        } catch {
            await logger?.error("Unable to load queue: \(error.localizedDescription)")
            return nil
        }
    }
}
