import SwiftUI

/// Sticky-note palette shared by the app and the widget.
enum StickyStyle {
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.93, blue: 0.55), // classic yellow
        Color(red: 1.00, green: 0.75, blue: 0.79), // pink
        Color(red: 0.72, green: 0.90, blue: 1.00), // blue
        Color(red: 0.76, green: 0.94, blue: 0.72), // green
        Color(red: 1.00, green: 0.84, blue: 0.63), // orange
    ]

    /// Handwriting "ink" on the paper.
    static let ink = Color.black.opacity(0.78)
    static let fadedInk = Color.black.opacity(0.42)

    static func color(for note: Note) -> Color {
        colors[abs(note.colorIndex) % colors.count]
    }

    static func handFont(size: CGFloat) -> Font {
        .custom("Noteworthy-Light", size: size)
    }

    /// Stable per-note tilt in −3°…+3°. Derived from the UUID string, not
    /// `hashValue`, so the same note tilts the same way across launches.
    static func rotationDegrees(for note: Note) -> Double {
        let seed = note.id.uuidString.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
        return Double(seed % 61) / 10.0 - 3.0
    }
}
