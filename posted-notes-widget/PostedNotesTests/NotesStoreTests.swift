import XCTest
import Foundation

// Shared sources are compiled directly into this bundle, so no import of an
// app module is needed — Note, NotesStore, StickyStyle are in scope.

final class NotesStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostedNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("notes.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    // ISO8601 encoding drops fractional seconds, so round-trip fixtures use
    // whole-second dates to stay Equatable.
    private func makeNotes() -> [Note] {
        [
            Note(text: "buy milk",
                 postedAt: Date(timeIntervalSince1970: 1_752_900_000),
                 colorIndex: 0, x: 120, y: 80),
            Note(text: "ship the widget",
                 postedAt: Date(timeIntervalSince1970: 1_752_903_600),
                 colorIndex: 3, x: 300.5, y: 210.25),
        ]
    }

    func testSaveThenLoadRoundTripsAllFields() {
        let original = makeNotes()
        NotesStore.save(original, to: tempURL)
        let loaded = NotesStore.load(from: tempURL)
        XCTAssertEqual(loaded, original)
    }

    func testLoadMissingFileReturnsEmpty() {
        XCTAssertEqual(NotesStore.load(from: tempURL), [])
    }

    func testLoadCorruptFileReturnsEmpty() throws {
        try Data("not json {{{".utf8).write(to: tempURL)
        XCTAssertEqual(NotesStore.load(from: tempURL), [])
    }

    func testLoadsLegacyJSONWithoutPositions() throws {
        // Format written before the free board existed: no x/y keys.
        let legacy = """
        [{"id":"11111111-2222-3333-4444-555555555555",
          "text":"pre-board note",
          "postedAt":"2026-07-19T12:00:00Z",
          "colorIndex":1}]
        """
        try Data(legacy.utf8).write(to: tempURL)

        let loaded = NotesStore.load(from: tempURL)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].text, "pre-board note")
        XCTAssertEqual(loaded[0].colorIndex, 1)
        XCTAssertNil(loaded[0].x)
        XCTAssertNil(loaded[0].y)
    }

    func testSaveOverwritesPreviousContents() {
        NotesStore.save(makeNotes(), to: tempURL)
        let single = [Note(text: "only one",
                           postedAt: Date(timeIntervalSince1970: 1_752_900_000),
                           colorIndex: 2)]
        NotesStore.save(single, to: tempURL)
        XCTAssertEqual(NotesStore.load(from: tempURL), single)
    }

    func testPostedFiltersEmptyAndWhitespaceNotes() {
        let notes = [
            Note(text: "keep me", colorIndex: 0),
            Note(text: "", colorIndex: 1),
            Note(text: "   \n\t ", colorIndex: 2),
            Note(text: " also kept ", colorIndex: 3),
        ]
        let posted = NotesStore.posted(notes)
        XCTAssertEqual(posted.map(\.text), ["keep me", " also kept "])
    }

    func testPostedPreservesOrder() {
        let notes = (0..<5).map { Note(text: "n\($0)", colorIndex: $0) }
        XCTAssertEqual(NotesStore.posted(notes), notes)
    }
}
