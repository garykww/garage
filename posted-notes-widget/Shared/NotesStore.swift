import Foundation

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var postedAt: Date
    var colorIndex: Int
    /// Free-board position (board-local coordinates). nil until placed.
    var x: Double?
    var y: Double?

    init(id: UUID = UUID(), text: String, postedAt: Date = .now, colorIndex: Int,
         x: Double? = nil, y: Double? = nil) {
        self.id = id
        self.text = text
        self.postedAt = postedAt
        self.colorIndex = colorIndex
        self.x = x
        self.y = y
    }
}

/// Reads/writes notes as JSON in the shared App Group container so the app
/// and the widget extension see the same data. Falls back to Application
/// Support when the group container is unavailable (e.g. unsigned CI builds).
enum NotesStore {
    // Must be team-prefixed (TEAMID.name) and match the entitlements in
    // project.yml — non-prefixed groups are denied to sandboxed extensions.
    static let appGroupID = "6PU94W2HBX.dev.garage.posted-notes"

    static var fileURL: URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PostedNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("notes.json")
    }

    static func load() -> [Note] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Note].self, from: data)) ?? []
    }

    static func save(_ notes: [Note]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
