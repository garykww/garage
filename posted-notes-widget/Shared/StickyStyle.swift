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

    static func color(for note: Note) -> Color {
        colors[abs(note.colorIndex) % colors.count]
    }
}
