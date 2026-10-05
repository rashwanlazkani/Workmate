import SwiftUI
import AppKit
import UserNotifications
import WorkmateCore

// Use the stable property wrapper when an SDK also exports the newer State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main struct WorkmateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = WorkspaceStore()
    var body: some Scene {
        WindowGroup("Workmate", id: "workspace") {
            WorkspaceView().environmentObject(store).environmentObject(store.intelligence).environmentObject(store.calendars).preferredColorScheme(.dark).tint(Palette.accent)
                .background(WorkspaceWindowBridge(delegate: delegate))
                .frame(minWidth: 820, minHeight: 560)
                .onOpenURL { url in
                    if url.scheme == "workmate", url.host == "meeting" { store.focusMeeting(url.lastPathComponent) }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.showWorkspace(); store.settingsShown = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Button("Workmate Help") { delegate.showWorkspace(); store.openHelp() }.keyboardShortcut("?", modifiers: .command)
                Button("Welcome Tour…") { delegate.showWorkspace(); store.openHelp(tutorial: true) }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Note") { delegate.showWorkspace(); store.newNote() }.keyboardShortcut("n")
                Button("Find…") { delegate.showWorkspace(); store.searchShown = true }.keyboardShortcut("f")
                Button("Show Workmate") { delegate.showWorkspace() }.keyboardShortcut("0")
            }
            CommandGroup(after: .importExport) {
                Button("Import Markdown…") { store.importMarkdown() }
                Button("Export Note as Markdown…") {
                    if let note = store.workspace.notes.first(where: { $0.id == store.activeColumn }) { store.exportMarkdown(note) }
                }.disabled(!store.workspace.notes.contains { $0.id == store.activeColumn })
                Divider()
                Button("Export Backup…") { store.exportBackup() }
                Button("Import Backup…") { store.importBackup() }
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let workspaceWindow = WorkspaceWindowController()
    override init() {
        super.init()
        // Set the running icon before SwiftUI creates the workspace. Dock can
        // retain an older icon even when the bundle's Launch Services icon is current.
        applyBundleIcon()
    }
    private func applyBundleIcon() {
        guard let url = Bundle.main.url(forResource: "WorkmateBlue", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        applyBundleIcon()
    }
    func showWorkspace() { workspaceWindow.show() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UNUserNotificationCenter.current().delegate = self
        let complete = UNNotificationAction(identifier: "complete", title: "Mark complete", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "snooze", title: "Snooze 1 hour", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "WORKMATE_TASK", actions: [complete, snooze], intentIdentifiers: [])])
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWorkspace()
        return false
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let taskID = response.notification.request.content.userInfo["taskId"] as? String, UUID(uuidString: taskID) != nil {
            let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "open" : response.actionIdentifier
            guard ["complete", "snooze", "open"].contains(action) else { return }
            await MainActor.run {
                UserDefaults.standard.set(["id": taskID, "action": action, "at": Date().timeIntervalSince1970], forKey: "workmate.pendingTaskAction")
                NotificationCenter.default.post(name: .workmateTaskAction, object: nil)
                showWorkspace()
            }
            return
        }
        guard let id = response.notification.request.content.userInfo["meetingId"] as? String, UUID(uuidString: id) != nil else { return }
        await MainActor.run {
            UserDefaults.standard.set(id, forKey: "pending-meeting-focus")
            NotificationCenter.default.post(name: .openWorkmateMeeting, object: id)
            if let url = URL(string: "workmate://meeting/\(id)") { NSWorkspace.shared.open(url) }
        }
    }
}

enum Palette {
    static let background = Color(red: 31 / 255, green: 31 / 255, blue: 36 / 255)
    static let foreground = Color.white
    static let field = Color.white.opacity(0.045)
    static let panel = Color.white.opacity(0.028)
    static let muted = Color.white.opacity(0.42)
    static let accent = Color(red: 84 / 255, green: 130 / 255, blue: 255 / 255)
    static let line = Color.white.opacity(0.075)
}
extension Priority {
    var tint: Color {
        switch self {
        case .low: return Color(red: 0.57, green: 0.70, blue: 0.62)
        case .medium: return Color(red: 0.60, green: 0.69, blue: 0.80)
        case .high: return Color(red: 0.84, green: 0.69, blue: 0.42)
        case .urgent: return Color(red: 0.88, green: 0.55, blue: 0.53)
        }
    }
    var symbol: String { self == .urgent ? "exclamationmark.2" : "circle.fill" }
}

struct WorkspaceView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ViewState<Bool> private var addColumn = false
    @ViewState<Bool> private var archiveShown = false
    @ViewState<Bool> private var allTasks = false
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    if store.isCloud { Button("Retry") { Task { await store.sync() } } }
                    Button { store.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error")
                }
                .font(.system(size: 12)).foregroundStyle(.orange.opacity(0.85)).padding(12)
                .background(.orange.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 30).padding(.vertical, 16)
            }
            if !store.filterQuery.isEmpty {
                SearchResultsView().padding(.top, 24)
            } else if let meeting = store.focusedMeeting {
                MeetingFocusView(meeting: meeting).padding(.top, 24)
            } else {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("NOTES").font(.system(size: 10, weight: .medium)).tracking(1.7).foregroundStyle(Palette.muted)
                        Spacer()
                        Button { addColumn.toggle() } label: { Label("Add column", systemImage: "rectangle.split.2x1") }
                            .buttonStyle(FullHitButtonStyle()).font(.system(size: 12)).foregroundStyle(.secondary)
                            .popover(isPresented: $addColumn, arrowEdge: .bottom) {
                                NoteChooser { id in store.openNote(id); addColumn = false }
                                    .environmentObject(store)
                            }
                    }.padding(.horizontal, 8)
                    GeometryReader { geometry in
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(store.visibleNotes) { note in
                                        NoteColumn(note: note)
                                            .frame(width: max(360, (geometry.size.width - CGFloat(max(0, store.columns.count - 1)) * 25) / CGFloat(max(1, store.columns.count))))
                                            .id(note.id)
                                        if note.id != store.columns.last {
                                            Rectangle().fill(Palette.line).frame(width: 1).padding(.horizontal, 12)
                                        }
                                    }
                                }.frame(minHeight: geometry.size.height - 14, alignment: .top)
                            }
                            .scrollIndicators(.automatic)
                            .onChange(of: store.activeColumn) { _, id in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                        }
                    }
                }.padding(.trailing, 28)
                Rectangle().fill(Palette.line).frame(width: 1).padding(.top, 42).padding(.bottom, 24)
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Text("Next").font(.system(size: 15, weight: .medium)); Spacer() }
                    QuickAddTask()
                    ScrollViewReader { actionProxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            let archivedMatch = store.workspace.tasks.filter { $0.isArchived && $0.id == store.highlightedActionID }
                            let tasks = store.workspace.openTasks + archivedMatch
                            ForEach(allTasks || store.highlightedActionID != nil ? tasks : Array(tasks.prefix(6))) { task in TaskRow(task: task).id(task.id) }
                            if tasks.isEmpty {
                                Text("A little room to breathe.").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 15)
                            }
                            if tasks.count > 6 {
                                Button(allTasks ? "Show less" : "Show \(tasks.count - 6) more") { allTasks.toggle() }
                                    .buttonStyle(FullHitButtonStyle()).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 15)
                            }
                        }
                    }.scrollIndicators(.hidden)
                    .onChange(of: store.highlightedActionID) { _, id in
                        guard let id else { return }
                        Task { @MainActor in
                            await Task.yield()
                            withAnimation { actionProxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    }
                    Button { archiveShown = true } label: {
                        Label("Archive · \(store.workspace.tasks.filter { $0.isArchived }.count)", systemImage: "archivebox")
                    }.buttonStyle(FullHitButtonStyle()).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("View and restore completed tasks")
                        .popover(isPresented: $archiveShown, arrowEdge: .leading) { ArchiveView().environmentObject(store) }
                    if store.workspace.settings.digestEnabled {
                        Button { Task { await store.sendBrief() } } label: { Label("Send daily brief", systemImage: "paperplane") }
                            .buttonStyle(FullHitButtonStyle()).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.bottom, 12)
                    }
                }.frame(width: 265).padding(.leading, 26).padding(.top, 40)
            }.padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 28)
            }
        }
        .background(Palette.background)
        .foregroundStyle(Palette.foreground)
        .tint(Palette.accent)
        .toolbar { WorkspaceToolbar(store: store) }
        .overlay(alignment: .bottom) {
            if let message = store.message {
                Text(message).font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 18).allowsHitTesting(false)
            }
        }
    }
}

struct NoteColumn: View {
    @EnvironmentObject var store: WorkspaceStore
    let note: Note
    @ViewState<String> private var selected = ""
    @ViewState<String?> private var newSectionID: String?
    @ViewState<Bool> private var chooseNote = false
    @ViewState<Bool> private var confirmDelete = false
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { chooseNote = true } label: { Label("Your notes", systemImage: "doc.text") }
                    .buttonStyle(FullHitButtonStyle()).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .popover(isPresented: $chooseNote) { NoteChooser { id in store.activeColumn = note.id; store.openNote(id, beside: false); chooseNote = false }.environmentObject(store) }
                Spacer()
                Menu {
                    Button("Move left") { store.moveColumn(note.id, by: -1) }.disabled(store.columns.first == note.id)
                    Button("Move right") { store.moveColumn(note.id, by: 1) }.disabled(store.columns.last == note.id)
                    Divider()
                    Button("Export Markdown…") { store.exportMarkdown(note) }
                    Button("Delete note…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).help("Note options")
                if store.columns.count > 1 {
                    Button { store.closeColumn(note.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(FullHitButtonStyle()).foregroundStyle(Palette.muted).help("Close column. Your note stays saved.").accessibilityLabel("Close \(note.displayTitle) column")
                }
            }.padding(.bottom, 22)
            TextField("Untitled note", text: Binding(get: { note.title }, set: { store.updateNote(note.id, title: $0) }))
                .textFieldStyle(.plain).font(.system(size: 25, weight: .medium)).focused($titleFocused)
                .accessibilityLabel(note.contentSections.count > 1 ? "Column name" : "Note title")
                .help("Name this column independently of its section headings").padding(.bottom, 15)
                .focusOnEntry($titleFocused, when: store.activeColumn == note.id)
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(note.sections(for: store.meetingFocusID).enumerated()), id: \.element.id) { index, section in
                                if index > 0 { Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 24) }
                                NoteSectionEditor(noteID: note.id, section: section, first: section.id == note.contentSections.first?.id,
                                                  showHeading: note.contentSections.count > 1,
                                                  minimumHeight: note.contentSections.count == 1 ? max(180, geometry.size.height - 80) : 200,
                                                  autofocus: newSectionID == section.id, selected: $selected,
                                                  added: { newSectionID = $0 })
                                    .id(section.id)
                            }
                            Button {
                                newSectionID = store.addSection(note.id)
                            } label: {
                                Label("Add section", systemImage: "plus").font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                            }.buttonStyle(FullHitButtonStyle()).foregroundStyle(Palette.accent)
                                .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                                .padding(.top, 20).disabled(note.contentSections.count >= 50)
                        }.padding(.bottom, 8)
                    }
                    .onAppear { if let id = store.aiSourceSectionID { proxy.scrollTo(id, anchor: .top) } }
                    .onChange(of: store.aiSourceSectionID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                    }
                    .onChange(of: newSectionID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                    }
                }
            }

        }
        .padding(.horizontal, 8)
        .onChange(of: titleFocused) { _, focused in if focused { store.activeColumn = note.id } }
        .confirmationDialog("Delete “\(note.displayTitle)”?", isPresented: $confirmDelete) {
            Button("Delete note", role: .destructive) { store.deleteNote(note.id) }
        } message: { Text("Its tasks will stay in Next.") }
    }
}
