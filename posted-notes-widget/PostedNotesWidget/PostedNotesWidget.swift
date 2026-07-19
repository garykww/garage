import WidgetKit
import SwiftUI

struct NotesEntry: TimelineEntry {
    let date: Date
    let notes: [Note]
}

struct NotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> NotesEntry {
        NotesEntry(date: .now, notes: NotesEntry.sample)
    }

    /// Notes being typed on the board are saved keystroke-by-keystroke;
    /// hide ones that are still empty.
    private func postedNotes() -> [Note] {
        NotesStore.load().filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func getSnapshot(in context: Context, completion: @escaping (NotesEntry) -> Void) {
        let notes = postedNotes()
        completion(NotesEntry(date: .now, notes: notes.isEmpty ? NotesEntry.sample : notes))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NotesEntry>) -> Void) {
        let entry = NotesEntry(date: .now, notes: postedNotes())
        // The app reloads timelines on every post; hourly refresh keeps
        // relative timestamps from going stale in between.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

extension NotesEntry {
    static let sample = [
        Note(text: "Pick up dry cleaning", colorIndex: 0),
        Note(text: "Ship the garage widget", colorIndex: 2),
        Note(text: "Call mom", colorIndex: 1),
    ]
}

struct PostedNotesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NotesEntry

    private var visibleCount: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 2
        default: 5
        }
    }

    var body: some View {
        if entry.notes.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No notes posted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(entry.notes.prefix(visibleCount)) { note in
                    StickyNoteCard(note: note, compact: family == .systemSmall)
                }
                if entry.notes.count > visibleCount {
                    Text("+\(entry.notes.count - visibleCount) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

struct StickyNoteCard: View {
    let note: Note
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.text)
                .font(compact ? .footnote : .callout)
                .lineLimit(compact ? 4 : 2)
                .foregroundStyle(.black.opacity(0.85))
            Text(note.postedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.black.opacity(0.45))
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .topLeading)
        .background(StickyStyle.color(for: note), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct PostedNotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PostedNotesWidget", provider: NotesProvider()) { entry in
            PostedNotesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Posted Notes")
        .description("Your latest sticky notes at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct PostedNotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        PostedNotesWidget()
    }
}
