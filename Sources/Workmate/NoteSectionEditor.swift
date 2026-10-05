import AppKit
import SwiftUI
import WorkmateCore

struct NoteSectionEditor: View {
    @EnvironmentObject var store: WorkspaceStore
    let noteID: String
    let section: NoteSection
    let first: Bool
    let showHeading: Bool
    let minimumHeight: CGFloat
    let autofocus: Bool
    @Binding var selected: String
    var added: (String?) -> Void
    @StateObject private var controller = NoteEditorController()
    @ViewState<Bool> private var confirmDelete = false
    @ViewState<Meeting?> private var newMeeting: Meeting?
    @FocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeading {
                TextField("Section heading", text: Binding(get: { section.title }, set: {
                    store.updateSection(noteID, sectionID: section.id, title: $0)
                }))
                .textFieldStyle(.plain).font(.system(size: 22, weight: .medium))
                .focused($headingFocused).focusOnEntry($headingFocused, when: autofocus)
                .accessibilityLabel("Section heading").padding(.bottom, 16)
            }
            HStack(spacing: 8) {
                let meetings = store.workspace.meetings.filter { !$0.canceled }
                if meetings.isEmpty {
                    Button(action: beginMeeting) { Label("Meeting", systemImage: "tag") }.buttonStyle(FullHitButtonStyle())
                } else {
                    Menu {
                        ForEach(meetings) { meeting in
                            Button { store.linkSection(noteID, sectionID: section.id, to: meeting) } label: {
                                Label(meeting.title, systemImage: (section.meetingIds ?? []).contains(meeting.id) ? "checkmark" : "calendar")
                            }
                        }
                        Divider()
                        Button("New meeting…", action: beginMeeting)
                    } label: { Label("Meeting", systemImage: "tag") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Section meeting")
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(store.workspace.meetings.filter { (section.meetingIds ?? []).contains($0.id) }) { meeting in
                            HStack(spacing: 0) {
                                Button { store.focusMeeting(meeting.id) } label: {
                                    Text(meeting.title).padding(.leading, 9).padding(.trailing, 5).frame(minHeight: 28)
                                }.buttonStyle(FullHitButtonStyle())
                                Button { store.linkSection(noteID, sectionID: section.id, to: meeting) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8)).frame(width: 22, height: 28)
                                }.buttonStyle(FullHitButtonStyle()).help("Remove \(meeting.title) from this section")
                            }
                                .background(Palette.accent.opacity(0.10), in: Capsule())
                        }
                    }
                }.scrollIndicators(.hidden)
            }.font(.system(size: 11)).foregroundStyle(Palette.accent).frame(height: 30).padding(.bottom, 10)
                .popover(item: $newMeeting) { meeting in
                    MeetingEditor(meeting: meeting, linkingNoteID: noteID, linkingSectionID: section.id).environmentObject(store)
                }
            HStack(alignment: .top, spacing: 4) {
                NoteFormattingToolbar(controller: controller) { controller.beginMarkdown(NoteMarkdown.source(for: section)) }
                Menu {
                    Button("Edit Markdown…") { controller.beginMarkdown(NoteMarkdown.source(for: section)) }
                    Button("Paste Markdown") { controller.pasteMarkdown(validate: canApplyMarkdown) }
                    Divider()
                    Button("Split at cursor") {
                        added(store.addSection(noteID, after: section.id, splitAt: controller.editor?.selectedRange().location ?? (section.body as NSString).length))
                    }
                    Button("Add section below") { added(store.addSection(noteID, after: section.id)) }
                    if !first {
                        Divider()
                        Button("Merge with section above") { store.mergeSection(noteID, sectionID: section.id) }
                    }
                    Divider()
                    Button("Delete section…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "rectangle.split.1x2").font(.system(size: 17)).frame(width: 32, height: 36).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Split this section or add another").accessibilityLabel("Section options")
            }
            NativeNoteEditor(text: section.body, richText: section.richText, selectedText: $selected,
                             controller: controller, onChange: { body, richText in
                store.updateSection(noteID, sectionID: section.id, body: body, richText: richText)
            }, onFocus: { store.activeColumn = noteID; selected = "" }, onMakeAction: { text in
                guard let note = store.workspace.notes.first(where: { $0.id == noteID }) else { return }
                store.addActions(from: note, selected: text)
                selected = ""
            })
            .frame(height: max(minimumHeight, controller.contentHeight))
            .overlay(alignment: .topLeading) {
                if section.body.isEmpty {
                    Text("A thought, a meeting, something to remember…").font(.system(size: 17))
                        .foregroundStyle(Palette.muted).padding(.top, 4).allowsHitTesting(false)
                }
            }
        }
        .sheet(isPresented: $controller.markdownShown) {
            MarkdownEditorSheet(source: controller.markdownOriginal) { source in
                guard controller.applyMarkdown(source, validate: canApplyMarkdown) else { return false }
                store.editSections(noteID) { sections in
                    if let index = sections.firstIndex(where: { $0.id == section.id }) { sections[index].markdownSource = source }
                }
                return true
            }
        }
        .confirmationDialog("Delete this section?", isPresented: $confirmDelete) {
            Button("Delete section", role: .destructive) { store.removeSection(noteID, sectionID: section.id) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes this section’s heading, text and meeting tags. The column and other sections stay saved.")
        }
    }
    private func canApplyMarkdown(_ text: NSAttributedString) -> Bool {
        guard var note = store.workspace.notes.first(where: { $0.id == noteID }) else { return false }
        var sections = note.contentSections
        guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return false }
        sections[index].body = text.string
        sections[index].richText = NoteFormatting.encode(text)
        note.setSections(sections)
        return note.validSections && note.body.count <= 60000
    }
    private func beginMeeting() {
        let start = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        newMeeting = Meeting(title: "", start: start, end: start.addingTimeInterval(3600))
    }
}
