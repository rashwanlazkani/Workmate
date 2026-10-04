import SwiftUI

struct WorkspaceToolbar: ToolbarContent {
    @ObservedObject var store: WorkspaceStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Workmate").font(.headline)
                Text(store.status).font(.caption2).foregroundStyle(.secondary)
            }.help(store.status)
        }
        if let occurrence = store.currentOrNextMeeting {
            ToolbarItem(placement: .principal) {
                Button { store.focusMeeting(occurrence.meeting.id) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: occurrence.isCurrent(at: store.clock) ? "circle.inset.filled" : "calendar")
                        Text(occurrence.isCurrent(at: store.clock) ? "Now · \(occurrence.meeting.title)" : occurrence.meeting.title)
                            .lineLimit(1)
                    }.frame(maxWidth: 220)
                }.help("Open meeting notes · \(occurrence.start.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Search", systemImage: "magnifyingglass") { store.searchShown = true }
                .help("Search · ⌘F")
                .popover(isPresented: $store.searchShown, arrowEdge: .bottom) {
                    SearchSheet().environmentObject(store).popoverSurface()
                }
            Button("Meetings", systemImage: "calendar") { store.meetingsShown = true }
                .help("Meetings")
                .popover(isPresented: $store.meetingsShown, arrowEdge: .bottom) {
                    MeetingsSheet().environmentObject(store).onDisappear { store.editingMeeting = nil }
                }
            Button("Help", systemImage: "questionmark.circle") { store.openHelp() }
                .help("Workmate Help")
                .popover(isPresented: $store.helpShown, arrowEdge: .bottom) {
                    HelpView(tutorial: store.tutorialShown).environmentObject(store).interactiveDismissDisabled()
                }
            Button("Settings", systemImage: "gearshape") { store.settingsShown = true }
                .help("Settings · ⌘,")
                .popover(isPresented: $store.settingsShown, arrowEdge: .bottom) {
                    SettingsView().environmentObject(store).environmentObject(store.intelligence)
                        .environmentObject(store.calendars).frame(width: 510, height: 630).popoverSurface()
                        .interactiveDismissDisabled()
                }
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New note", systemImage: "square.and.pencil") { store.newNote() }
                .help("New note · ⌘N")
        }
    }
}
