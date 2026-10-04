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
        ToolbarItem(placement: .principal) {
                Button { store.editingMeeting = nil; store.meetingsShown = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "calendar")
                        if let selected = store.focusedMeeting {
                            Text(selected.title).lineLimit(1).frame(maxWidth: 200)
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                }.help("Add a meeting or filter by meeting").accessibilityLabel("Calendar")
                    .popover(isPresented: $store.meetingsShown, arrowEdge: .bottom) {
                        MeetingsSheet().environmentObject(store).onDisappear { store.editingMeeting = nil }
                    }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Search", systemImage: "magnifyingglass") { store.searchShown = true }
                .help("Search · ⌘F")
                .popover(isPresented: $store.searchShown, arrowEdge: .bottom) {
                    SearchSheet().environmentObject(store).popoverSurface()
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
