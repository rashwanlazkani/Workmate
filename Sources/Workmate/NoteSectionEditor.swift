import SwiftUI
import WorkmateCore

struct NoteSectionEditor: View {
    @EnvironmentObject var store: WorkspaceStore
    let noteID: String
    let section: NoteSection
    let first: Bool
    let minimumHeight: CGFloat
    let autofocus: Bool
    @Binding var selected: String
    var added: (String?) -> Void
    @StateObject private var controller = NoteEditorController()
    @FocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first {
                TextField("Section heading", text: Binding(get: { section.title }, set: {
                    store.updateSection(noteID, sectionID: section.id, title: $0)
                }))
                .textFieldStyle(.plain).font(.system(size: 22, weight: .medium))
                .focused($headingFocused).focusOnEntry($headingFocused, when: autofocus)
                .accessibilityLabel("Section heading").padding(.bottom, 16)
            }
            HStack(alignment: .top, spacing: 4) {
                NoteFormattingToolbar(controller: controller)
                Menu {
                    Button("Split at cursor") {
                        added(store.addSection(noteID, after: section.id, splitAt: controller.editor?.selectedRange().location ?? (section.body as NSString).length))
                    }
                    Button("Add section below") { added(store.addSection(noteID, after: section.id)) }
                    if !first {
                        Divider()
                        Button("Merge with section above") { store.mergeSection(noteID, sectionID: section.id) }
                    }
                } label: { Image(systemName: "rectangle.split.1x2").font(.system(size: 12)).frame(width: 28, height: 27) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Split this section or add another").accessibilityLabel("Section options")
            }
            NativeNoteEditor(text: section.body, richText: section.richText, selectedText: $selected,
                             controller: controller, onChange: { body, richText in
                store.updateSection(noteID, sectionID: section.id, body: body, richText: richText)
            }, onFocus: { store.activeColumn = noteID; selected = "" })
            .frame(height: max(minimumHeight, controller.contentHeight))
            .overlay(alignment: .topLeading) {
                if section.body.isEmpty {
                    Text("A thought, a meeting, something to remember…").font(.system(size: 14))
                        .foregroundStyle(Palette.muted).padding(.top, 4).allowsHitTesting(false)
                }
            }
        }
    }
}
