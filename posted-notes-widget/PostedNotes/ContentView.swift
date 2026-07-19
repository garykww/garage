import SwiftUI
import WidgetKit

struct ContentView: View {
    @State private var notes: [Note] = NotesStore.load()
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("Write a note…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                    .onSubmit(post)
                Button("Post", action: post)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.top, .horizontal])

            if notes.isEmpty {
                ContentUnavailableView(
                    "No notes yet",
                    systemImage: "note.text",
                    description: Text("Post a note above — it shows up in the Posted Notes widget.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(notes) { note in
                            StickyNoteRow(note: note) { delete(note) }
                        }
                    }
                    .padding([.horizontal, .bottom])
                }
            }
        }
        .onAppear { draftFocused = true }
    }

    private func post() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.insert(Note(text: text, colorIndex: Int.random(in: 0..<StickyStyle.colors.count)), at: 0)
        draft = ""
        persist()
    }

    private func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        persist()
    }

    private func persist() {
        NotesStore.save(notes)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct StickyNoteRow: View {
    let note: Note
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.text)
                    .font(.body)
                    .foregroundStyle(.black.opacity(0.85))
                Text(note.postedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.black.opacity(0.45))
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.black.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StickyStyle.color(for: note), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

#Preview {
    ContentView()
}
