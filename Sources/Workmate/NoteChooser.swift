import SwiftUI
import WorkmateCore

struct NoteChooser: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var query = ""
    @ViewState<String?> private var selection: String?
    var choose: (String) -> Void

    private var notes: [Note] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.workspace.notes.filter { search.isEmpty || ($0.title + " " + $0.body).localizedStandardContains(search) }
    }
    private func openSelection() {
        if let id = notes.first(where: { $0.id == selection })?.id ?? notes.first?.id { choose(id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Your notes").font(.headline); Spacer(); PopoverCloseButton { dismiss() } }.padding(.horizontal, 4)
            NativeSearchField(text: $query, placeholder: "Find a note", onSubmit: openSelection)
            if notes.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 140)
            } else {
                List(selection: $selection) {
                    ForEach(notes) { note in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text").font(.system(size: 18, weight: .light))
                                .foregroundStyle(.secondary).frame(width: 23)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty note" : note.body.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 5)
                            if store.columns.contains(note.id) {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.accent).accessibilityLabel("Open in workspace")
                            }
                        }.padding(.vertical, 7).contentShape(Rectangle())
                            .tag(note.id).onTapGesture { choose(note.id) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { choose(note.id) }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .frame(height: min(CGFloat(notes.count) * 61 + 8, 280))
                    .onKeyPress(.return) { openSelection(); return .handled }
            }
            Divider()
            Button { store.newNote(); choose(store.activeColumn) } label: {
                Label("New note", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
            }.modernButtonStyle().padding(.horizontal, 4)
        }.padding(16).frame(width: 330).popoverSurface()
            .onChange(of: query) { _, _ in selection = notes.first?.id }
    }
}
