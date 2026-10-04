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
                    Button(action: beginMeeting) { Label("Meeting", systemImage: "tag") }.buttonStyle(.plain)
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
                            HStack(spacing: 5) {
                                Button(meeting.title) { store.focusMeeting(meeting.id) }.buttonStyle(.plain)
                                Button { store.linkSection(noteID, sectionID: section.id, to: meeting) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8))
                                }.buttonStyle(.plain).help("Remove \(meeting.title) from this section")
                            }.padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Palette.accent.opacity(0.10), in: Capsule())
                        }
                    }
                }.scrollIndicators(.hidden)
            }.font(.system(size: 11)).foregroundStyle(Palette.accent).frame(height: 30).padding(.bottom, 10)
                .popover(item: $newMeeting) { meeting in
                    MeetingEditor(meeting: meeting, linkingNoteID: noteID, linkingSectionID: section.id).environmentObject(store)
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
                    Divider()
                    Button("Delete section…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "rectangle.split.1x2").font(.system(size: 17)).frame(width: 32, height: 36) }
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
                    Text("A thought, a meeting, something to remember…").font(.system(size: 17))
                        .foregroundStyle(Palette.muted).padding(.top, 4).allowsHitTesting(false)
                }
            }
        }
        .confirmationDialog("Delete this section?", isPresented: $confirmDelete) {
            Button("Delete section", role: .destructive) { store.removeSection(noteID, sectionID: section.id) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes this section’s heading, text and meeting tags. The column and other sections stay saved.")
        }
    }
    private func beginMeeting() {
        let start = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        newMeeting = Meeting(title: "", start: start, end: start.addingTimeInterval(3600))
    }
}
