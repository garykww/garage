import SwiftUI
import WidgetKit

/// The free board: sticky notes at arbitrary positions on a translucent
/// panel pinned to the desktop. Double-click empty space (or hit +) to
/// create a note, type directly into it, drag to arrange, hover-✕ to delete.
struct BoardView: View {
    @State private var notes: [Note] = NotesStore.load()
    @State private var dragAnchor: CGSize?
    @FocusState private var focusedNote: UUID?

    private static let cardWidth: CGFloat = 150

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.primary.opacity(0.12))
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    addNote(at: location)
                }

            header

            ForEach($notes) { $note in
                StickyCard(
                    note: $note,
                    focus: $focusedNote,
                    onDelete: { delete($note.wrappedValue) },
                    onRecolor: { persistAndReloadWidget() }
                )
                .position(x: note.x ?? 100, y: note.y ?? 100)
                .gesture(dragGesture($note))
            }
        }
        .coordinateSpace(name: "board")
        .contextMenu {
            Button("New Note") { addNote(at: nil) }
            Divider()
            Button("Quit Posted Notes") { NSApp.terminate(nil) }
        }
        .onAppear {
            placeLegacyNotes()
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: notes) {
            NotesStore.save(notes)
        }
        .onChange(of: focusedNote) { previous, _ in
            // Leaving a note commits it: drop it if it stayed empty,
            // then let the widget pick up the final text.
            if let previous,
               let idx = notes.firstIndex(where: { $0.id == previous }),
               notes[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notes.remove(at: idx)
            }
            persistAndReloadWidget()
        }
    }

    private var header: some View {
        HStack {
            Text("Posted Notes")
                .font(.caption.smallCaps().weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                addNote(at: nil)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New note (or double-click the board)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WindowDragHandle())
    }

    private func dragGesture(_ note: Binding<Note>) -> some Gesture {
        DragGesture(coordinateSpace: .named("board"))
            .onChanged { value in
                if dragAnchor == nil {
                    dragAnchor = CGSize(
                        width: (note.wrappedValue.x ?? 100) - value.startLocation.x,
                        height: (note.wrappedValue.y ?? 100) - value.startLocation.y
                    )
                }
                note.wrappedValue.x = value.location.x + (dragAnchor?.width ?? 0)
                note.wrappedValue.y = value.location.y + (dragAnchor?.height ?? 0)
            }
            .onEnded { _ in
                dragAnchor = nil
                persistAndReloadWidget()
            }
    }

    private func addNote(at point: CGPoint?) {
        let position = point ?? CGPoint(
            x: 130 + .random(in: -40...40),
            y: 140 + .random(in: -40...40)
        )
        let note = Note(
            text: "",
            colorIndex: Int.random(in: 0..<StickyStyle.colors.count),
            x: position.x,
            y: position.y
        )
        notes.insert(note, at: 0)
        focusedNote = note.id
    }

    private func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        persistAndReloadWidget()
    }

    /// Notes posted before the board existed have no position — lay them
    /// out in a cascade once so they don't stack at a single point.
    private func placeLegacyNotes() {
        var placed = 0
        for idx in notes.indices where notes[idx].x == nil || notes[idx].y == nil {
            notes[idx].x = 95 + Double(placed % 3) * 145
            notes[idx].y = 120 + Double(placed / 3) * 165 + Double(placed % 3) * 12
            placed += 1
        }
    }

    private func persistAndReloadWidget() {
        NotesStore.save(notes)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Mouse-down on the (otherwise inert) header area hands the event to
/// AppKit's window-drag machinery, so the header moves the whole board.
struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct StickyCard: View {
    @Binding var note: Note
    var focus: FocusState<UUID?>.Binding
    let onDelete: () -> Void
    let onRecolor: () -> Void
    @State private var hovering = false

    var body: some View {
        PostIt(
            color: StickyStyle.color(for: note),
            rotation: StickyStyle.rotationDegrees(for: note)
        ) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("New note…", text: $note.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(StickyStyle.handFont(size: 15))
                    .foregroundStyle(StickyStyle.ink)
                    .lineLimit(1...6)
                    .focused(focus, equals: note.id)
                Spacer(minLength: 0)
                Text(note.postedAt, format: .relative(presentation: .named))
                    .font(StickyStyle.handFont(size: 10))
                    .foregroundStyle(StickyStyle.fadedInk)
            }
            .padding(12)
            .frame(width: 150, height: 150, alignment: .topLeading)
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.black.opacity(0.45))
                        .background(Circle().fill(.white.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
        }
        .overlay(alignment: .bottom) {
            if hovering {
                palette
                    .padding(.bottom, 5)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Five swatches to recolor the note; the current color gets a ring.
    private var palette: some View {
        HStack(spacing: 5) {
            ForEach(0..<StickyStyle.colors.count, id: \.self) { idx in
                Button {
                    note.colorIndex = idx
                    onRecolor()
                } label: {
                    Circle()
                        .fill(StickyStyle.colors[idx])
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle().strokeBorder(
                                .black.opacity(idx == abs(note.colorIndex) % StickyStyle.colors.count ? 0.55 : 0.18),
                                lineWidth: idx == abs(note.colorIndex) % StickyStyle.colors.count ? 1.5 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.white.opacity(0.65), in: Capsule())
    }
}

#Preview {
    BoardView()
        .frame(width: 460, height: 560)
}
