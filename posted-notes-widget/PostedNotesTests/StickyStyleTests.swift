import XCTest

final class StickyStyleTests: XCTestCase {
    func testPaletteOffersFiveColors() {
        XCTAssertEqual(StickyStyle.colors.count, 5)
    }

    func testColorWrapsForAnyIndex() {
        let count = StickyStyle.colors.count
        for idx in [-7, -1, 0, 4, 5, 123] {
            let note = Note(text: "x", colorIndex: idx)
            XCTAssertEqual(StickyStyle.color(for: note),
                           StickyStyle.colors[abs(idx) % count],
                           "colorIndex \(idx) should wrap into the palette")
        }
    }

    func testRotationIsStableForTheSameNoteID() {
        let id = UUID()
        let a = Note(id: id, text: "a", colorIndex: 0)
        let b = Note(id: id, text: "completely different text", colorIndex: 4)
        XCTAssertEqual(StickyStyle.rotationDegrees(for: a),
                       StickyStyle.rotationDegrees(for: b),
                       "tilt must depend only on the note ID")
    }

    func testRotationStaysWithinThreeDegrees() {
        for _ in 0..<200 {
            let tilt = StickyStyle.rotationDegrees(for: Note(text: "x", colorIndex: 0))
            XCTAssertGreaterThanOrEqual(tilt, -3.0)
            XCTAssertLessThanOrEqual(tilt, 3.0)
        }
    }

    func testRotationVariesAcrossNotes() {
        let tilts = Set((0..<50).map {
            _ in StickyStyle.rotationDegrees(for: Note(text: "x", colorIndex: 0))
        })
        XCTAssertGreaterThan(tilts.count, 1, "different notes should not all share one tilt")
    }
}
