import AppKit
import SwiftUI
import UserNotifications
import Combine
import WorkmateCore

@MainActor final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspace = Workspace()
    @Published var columns: [String] = []
    @Published var activeColumn = ""
    @Published var status = "Opening Workmate…"
    @Published var backupStatus = "Not connected"
    @Published var settingsSection = ""
    @Published private(set) var driveConfiguration = DriveConfiguration()
    @Published var error: String?
    @Published var message: String?
    @Published private(set) var highlightedActionID: String?
    private var actionHighlightMonitor: Any?
    @Published var account = "local"
    @Published var email = ""
    @Published var telegram = TelegramStatus.empty
    @Published var searchShown = false
    @Published var settingsShown = false
    @Published var helpShown = false
    @Published var tutorialShown = false
    @Published var filterQuery = ""
    @Published var includeArchive = false
    @Published var busy = false
    @Published var meetingFocusID: String?
    @Published var meetingsShown = false
    @Published var editingMeeting: Meeting?
    @Published private(set) var macNotificationsAllowed = false
    @Published var clock = Date()
    let calendars = CalendarController()
    let intelligence = IntelligenceController()
    private var notificationObserver: NSObjectProtocol?
    private var taskNotificationObserver: NSObjectProtocol?
    let api: DriveAPI
    let files: DriveWorkspaceFiles
    private let legacyFiles: WorkspaceFiles
    private var cloudBaseline: Workspace?
    private var storageReady = false
    private var dirty = false
    private var version = 0
    private var syncing = false
    private var syncTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var requestingNotificationPermission = false
    private var pollTask: Task<Void, Never>?
    var isCloud: Bool { !previewMode && driveConfiguration.serviceReady }
    var storageLabel: String { files.usesICloud ? "Saved in iCloud Drive" : "Saved in Documents" }
    var visibleNotes: [Note] { columns.compactMap { id in workspace.notes.first { $0.id == id } } }
    var configuration: CloudConfig
    private let previewMode: Bool

    init() {
        let resource = Bundle.main.url(forResource: "CloudConfig", withExtension: "json")
        configuration = resource.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(CloudConfig.self, from: $0) } ?? .init(region: "eu-north-1", clientId: "example-client-id", apiUrl: "https://example.invalid")
        let testDirectory = ProcessInfo.processInfo.environment["WORKMATE_DATA_DIR"] ?? Bundle.main.object(forInfoDictionaryKey: "WorkmateDataDirectory") as? String
        previewMode = testDirectory != nil
        legacyFiles = try! WorkspaceFiles(directory: testDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) })
        files = try! DriveWorkspaceFiles(directory: testDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) })
        var config = DriveConfiguration()
        do {
            config = try files.configuration()
            // Read the previous account's local cache without signing in or downloading anything.
            let oldSession = !previewMode ? Keychain.read().flatMap { try? JSONDecoder().decode(CloudSession.self, from: $0) } : nil
            workspace = try files.migrate(from: legacyFiles, account: oldSession?.subject ?? "local") ?? Workspace()
            storageReady = true
        } catch { self.error = "Could not open your Workmate folder: \(error.localizedDescription)" }
        driveConfiguration = config
        api = DriveAPI(configuration: config)
        let baselineURL = legacyFiles.directory.appendingPathComponent("aws-base-\(config.workspaceID).json")
        cloudBaseline = (try? Data(contentsOf: baselineURL)).flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }
        status = storageReady ? storageLabel : "Waiting for your files"
        dirty = config.serviceReady
        if !previewMode {
            calendars.selected = Set(config.selectedCalendars.isEmpty ? Array(calendars.selected) : config.selectedCalendars)
            intelligence.enabled = config.intelligenceEnabled
        }
        restoreColumns()
        intelligence.configure(directory: files.directory, account: account)
        notificationObserver = NotificationCenter.default.addObserver(forName: .openWorkmateMeeting, object: nil, queue: .main) { [weak self] notification in
            guard let id = notification.object as? String else { return }
            Task { @MainActor in self?.focusMeeting(id) }
        }
        taskNotificationObserver = NotificationCenter.default.addObserver(forName: .workmateTaskAction, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handlePendingTaskAction() }
        }
        calendars.changed = { [weak self] in
            guard let self else { return }
            self.updateConfiguration { $0.selectedCalendars = Array(self.calendars.selected) }
            self.refreshCalendar()
        }
        Task { await bootstrap() }
    }
    func openHelp(tutorial: Bool = false) {
        settingsShown = false; tutorialShown = tutorial; helpShown = true
    }
    private func bootstrap() async {
        if !UserDefaults.standard.bool(forKey: "workmate.tour.completed") {
            Task { try? await Task.sleep(for: .milliseconds(600)); openHelp(tutorial: true) }
        }
        if storageReady { persist() }
        intelligence.configure(directory: files.directory, account: account)
        if !previewMode { refreshCalendar(); intelligence.scan(workspace) }
        if let id = UserDefaults.standard.string(forKey: "pending-meeting-focus") { focusMeeting(id); UserDefaults.standard.removeObject(forKey: "pending-meeting-focus") }
        handlePendingTaskAction()
        scheduleNotifications()
        if isCloud { await sync(); await refreshTelegram() }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                self.clock = Date(); self.readDriveChanges(); tick += 1
                if !self.previewMode {
                    if tick % 10 == 0 { self.refreshCalendar() }
                    if self.isCloud && !self.busy {
                        if self.dirty { await self.sync() } else { await self.pull() }
                    }
                }
            }
        }
    }
    func updateConfiguration(_ mutate: (inout DriveConfiguration) -> Void) {
        do {
            driveConfiguration = try files.updateConfiguration(mutate)
            Task { await api.configure(driveConfiguration) }
        } catch { self.error = error.localizedDescription }
    }
    private func awaitConfiguration() { Task { await api.configure(driveConfiguration) } }
    private func readDriveChanges() {
        guard status != "Not saved" else { _ = persist(); return }
        do {
            if !storageReady {
                driveConfiguration = try files.configuration()
                workspace = try files.migrate(from: legacyFiles) ?? Workspace()
                storageReady = true; restoreColumns(); dirty = isCloud
                awaitConfiguration()
                _ = persist()
            }
            let config = try files.configuration()
            if config != driveConfiguration {
                driveConfiguration = config
                Task { await api.configure(config) }
                if config.serviceReady { dirty = true }
                calendars.selected = Set(config.selectedCalendars)
                intelligence.enabled = config.intelligenceEnabled
            }
            if let saved = try files.read(), saved != workspace {
                workspace = saved; version += 1; dirty = isCloud
                restoreColumns(); scheduleNotifications()
                if !previewMode { intelligence.scan(workspace) }
                status = storageLabel
            }
        } catch { self.error = error.localizedDescription }
    }
    private var columnKey: String { "note-columns-\(previewMode ? files.directory.lastPathComponent : account)" }
    func restoreColumns() {
        if workspace.notes.isEmpty { workspace.notes.append(Note()) }
        let stored = driveConfiguration.columns.isEmpty ? UserDefaults.standard.stringArray(forKey: columnKey) ?? [] : driveConfiguration.columns
        var seen = Set<String>()
        columns = stored.filter { id in workspace.notes.contains { $0.id == id } && seen.insert(id).inserted }
        if columns.isEmpty, let first = workspace.notes.first { columns = [first.id] }
        activeColumn = columns.first ?? ""
    }
    func saveColumns() { UserDefaults.standard.set(columns, forKey: columnKey); updateConfiguration { $0.columns = columns } }
    func openNote(_ id: String, beside: Bool = true) {
        guard workspace.notes.contains(where: { $0.id == id }) else { return }
        if !columns.contains(id) {
            if beside { columns.append(id) }
            else if let index = columns.firstIndex(of: activeColumn) { columns[index] = id }
            else { columns.append(id) }
        }
        activeColumn = id; saveColumns()
    }
    func newNote() {
        var note = Note()
        if let meetingFocusID { note.meetingIds = [meetingFocusID] }
        change { $0.notes.append(note) }
        openNote(note.id)
    }
    func closeColumn(_ id: String) {
        guard columns.count > 1 else { return }
        columns.removeAll { $0 == id }; activeColumn = columns.last ?? ""; saveColumns()
    }
    func moveColumn(_ id: String, by amount: Int) {
        guard let index = columns.firstIndex(of: id), columns.indices.contains(index + amount) else { return }
        columns.swapAt(index, index + amount); saveColumns()
    }
    func updateNote(_ id: String, title: String? = nil, body: String? = nil) {
        change { w in
            guard let i = w.notes.firstIndex(where: { $0.id == id }) else { return }
            if let title {
                w.notes[i].title = String(title.prefix(200))
                if var sections = w.notes[i].sections, sections.count == 1 {
                    sections[0].title = w.notes[i].title; w.notes[i].setSections(sections)
                }
            }
            if let body { w.notes[i].body = String(body.prefix(60000)); w.notes[i].richText = nil }
            w.notes[i].updatedAt = Dates.iso()
        }
    }
    func updateNoteContent(_ id: String, body: String, richText: String?) {
        change { w in
            guard let i = w.notes.firstIndex(where: { $0.id == id }) else { return }
            w.notes[i].body = body; w.notes[i].richText = richText
            w.notes[i].updatedAt = Dates.iso()
        }
    }
    @discardableResult
    func editSections(_ noteID: String, _ edit: (inout [NoteSection]) -> Void) -> Bool {
        guard var note = workspace.notes.first(where: { $0.id == noteID }) else { return false }
        var sections = note.contentSections; edit(&sections); note.setSections(sections)
        guard note.validSections, note.body.count <= 60000 else { toast("This note is full. Add another note column."); return false }
        change { workspace in
            if let index = workspace.notes.firstIndex(where: { $0.id == noteID }) { workspace.notes[index] = note }
        }
        return true
    }
    func updateSection(_ noteID: String, sectionID: String, title: String? = nil, body: String? = nil, richText: String? = nil) {
        editSections(noteID) { sections in
            guard let index = sections.firstIndex(where: { $0.id == sectionID }) else { return }
            if let title { sections[index].title = String(title.prefix(200)) }
            if let body { sections[index].body = body; sections[index].richText = richText }
        }
    }
    func addSection(_ noteID: String, after sectionID: String? = nil, splitAt: Int? = nil) -> String? {
        var addedID: String?
        let saved = editSections(noteID) { sections in
            let index = sections.firstIndex(where: { $0.id == sectionID }) ?? (sections.count - 1)
            let added: NoteSection
            if let splitAt {
                let pair = NoteFormatting.splitSection(sections[index], at: splitAt)
                sections[index] = pair.0; added = pair.1
            } else { added = NoteSection(meetingIds: meetingFocusID.map { [$0] } ?? []) }
            sections.insert(added, at: index + 1); addedID = added.id
        }
        return saved ? addedID : nil
    }
    func removeSection(_ noteID: String, sectionID: String) {
        change { workspace in
            if let index = workspace.notes.firstIndex(where: { $0.id == noteID }) {
                workspace.notes[index].removeSection(sectionID)
            }
        }
    }
    func mergeSection(_ noteID: String, sectionID: String) {
        editSections(noteID) { sections in
            guard let index = sections.firstIndex(where: { $0.id == sectionID }), index > 0 else { return }
            sections[index - 1] = NoteFormatting.mergeSections(sections[index - 1], sections[index])
            sections.remove(at: index)
        }
    }
    func addActions(from note: Note, selected: String = "") {
        let candidates = selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? extractActions(note.body) : [selected.trimmingCharacters(in: .whitespacesAndNewlines)]
        let existing = Set(workspace.tasks.filter { $0.noteId == note.id }.map(\.title))
        var seen = existing
        let fresh = candidates.filter { seen.insert(String($0.prefix(500))).inserted }
        guard !fresh.isEmpty else {
            if let match = workspace.tasks.first(where: { $0.noteId == note.id && candidates.map { String($0.prefix(500)) }.contains($0.title) }) {
                highlightAction(match.id)
            }
            toast("Already in your actions.")
            return
        }
        change { w in w.tasks += fresh.map { WorkTask(title: String($0.prefix(500)), noteId: note.id) } }
        toast(fresh.count == 1 ? "Added to Next." : "\(fresh.count) actions added.")
    }
    private func highlightAction(_ id: String) {
        highlightedActionID = id
        if let actionHighlightMonitor { NSEvent.removeMonitor(actionHighlightMonitor) }
        actionHighlightMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard event.window != nil else { return event }
            self?.highlightedActionID = nil
            if let monitor = self?.actionHighlightMonitor {
                NSEvent.removeMonitor(monitor)
                self?.actionHighlightMonitor = nil
            }
            return event
        }
    }
    func addTask(_ title: String, priority: Priority, reminder: Date?, telegramReminder: Bool = false) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var task = WorkTask(title: String(title.prefix(500)), priority: priority, reminder: reminder)
        task.meetingId = meetingFocusID
        task.notifiesTelegram = telegramReminder
        change { $0.tasks.append(task) }
        if reminder != nil { requestNotificationsIfNeeded() }
    }
    func updateTask(_ id: String, _ mutate: (inout WorkTask) -> Void) {
        change { w in if let i = w.tasks.firstIndex(where: { $0.id == id }) { mutate(&w.tasks[i]) } }
        if let task = workspace.tasks.first(where: { $0.id == id }), !task.isArchived, task.reminder != nil { requestNotificationsIfNeeded() }
    }
    func toggleTask(_ task: WorkTask) {
        updateTask(task.id) { t in
            t.setCompleted(!t.isArchived)
        }
    }
    func deleteTask(_ id: String) { change { $0.tasks.removeAll { $0.id == id } } }
    func deleteNote(_ id: String) {
        change { w in
            w.notes.removeAll { $0.id == id }
            for i in w.tasks.indices where w.tasks[i].noteId == id { w.tasks[i].noteId = "" }
            if w.notes.isEmpty { w.notes.append(Note()) }
        }
        columns.removeAll { $0 == id }
        if columns.isEmpty { columns = [workspace.notes[0].id] }
        saveColumns()
    }
    func change(_ mutate: (inout Workspace) -> Void) {
        guard storageReady else { error = "Your Workmate files are not available yet. Reopen the app after iCloud finishes downloading them."; return }
        var next = workspace; mutate(&next)
        do { _ = try next.validated() } catch { self.error = error.localizedDescription; return }
        let notesChanged = workspace.notes != next.notes || workspace.meetings != next.meetings
        workspace = next; version += 1; dirty = isCloud
        persist(); scheduleNotifications()
        if notesChanged && !previewMode { intelligence.scan(workspace) }
        syncTask?.cancel()
        if isCloud {
            syncTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                Task { await self?.sync() }
            }
        }
    }
    @discardableResult private func persist() -> Bool {
        guard storageReady else { return false }
        do {
            let previousRecovery = files.recoveryURL
            let saved = try files.save(workspace)
            if saved != workspace { version += 1; dirty = isCloud }
            workspace = saved
            status = storageLabel
            if files.recoveryURL != previousRecovery {
                error = "Some edits conflicted. Both versions were kept; the other copy is in Workmate’s Recovery folder."
            }
            return true
        } catch { self.error = "Could not save: \(error.localizedDescription)"; status = "Not saved"; return false }
    }
    private func rememberCloud(_ value: Workspace) throws {
        cloudBaseline = value
        let url = legacyFiles.directory.appendingPathComponent("aws-base-\(driveConfiguration.workspaceID).json")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func mergeCloud(_ remote: Workspace) throws {
        let merged = Workspace.merge(base: cloudBaseline ?? remote, local: workspace, remote: remote)
        if merged.hasConflicts { _ = try files.preserve(remote, reason: "aws-conflict") }
        workspace = merged.workspace
        if merged.hasConflicts { error = "Different edits were found in the AWS copy. Your current edits are kept, with the other version in Recovery." }
    }
    func sync() async {
        guard isCloud, dirty, !syncing, !busy, storageReady else { return }
        syncing = true; backupStatus = "Backing up…"
        defer { syncing = false }
        for _ in 0..<3 {
            do {
                let remote = try await api.load()
                try mergeCloud(remote)
                guard persist() else { return }
                let sentVersion = version
                let saved = try await api.save(workspace)
                workspace.revision = saved.revision
                try rememberCloud(saved)
                dirty = sentVersion != version
                guard persist() else { return }
                backupStatus = "Backed up at " + Date().formatted(date: .omitted, time: .shortened)
                if !dirty { return }
            } catch WorkmateError.conflict { continue }
            catch { backupStatus = "Waiting to retry"; self.error = error.localizedDescription; return }
        }
        backupStatus = "Waiting to retry"
    }
    func pull() async {
        guard isCloud, !dirty, !syncing, storageReady else { return }
        do {
            let remote = try await api.load()
            guard !dirty, !syncing else { return }
            if remote != cloudBaseline {
                try mergeCloud(remote); try rememberCloud(remote)
                dirty = true; version += 1
                guard persist() else { return }
                restoreColumns(); scheduleNotifications()
                if !previewMode { intelligence.scan(workspace) }
                await sync()
            }
        } catch { backupStatus = "Waiting to retry" }
    }
    func backUpNow() async {
        dirty = true; await sync(); await refreshTelegram()
    }
    func showFiles() { NSWorkspace.shared.open(files.directory) }
    func refreshTelegram() async {
        guard isCloud else { return }
        do { telegram = try await api.telegramStatus() } catch { self.error = error.localizedDescription }
    }
    func sendBrief() async {
        guard isCloud else { error = "Connect AWS backup in Settings to use Telegram reminders."; return }
        await sync()
        guard !dirty else { return }
        do { try await api.sendBrief(priorities: workspace.settings.digestPriorities); toast("Daily brief sent to Telegram.") }
        catch { self.error = error.localizedDescription }
    }
    func toast(_ text: String) {
        message = text
        Task { try? await Task.sleep(for: .seconds(3)); if message == text { message = nil } }
    }
    func exportBackup() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Workmate-\(Dates.day(Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(workspace).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    func importBackup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 4_000_000 else { throw WorkmateError.message("Choose a backup smaller than 4 MB.") }
            var imported = try JSONDecoder().decode(Workspace.self, from: data).validated()
            let alert = NSAlert(); alert.messageText = "Restore this backup?"; alert.informativeText = "Your current workspace will be backed up on this Mac before it is replaced."
            alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let backup = files.directory.appendingPathComponent("before-import-\(Int(Date().timeIntervalSince1970)).json")
            try JSONEncoder().encode(workspace).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            imported.revision = workspace.revision
            change { $0 = imported }; restoreColumns()
        } catch { self.error = error.localizedDescription }
    }
    private func handlePendingTaskAction() {
        guard let action = UserDefaults.standard.dictionary(forKey: "workmate.pendingTaskAction"),
              let id = action["id"] as? String, let kind = action["action"] as? String else { return }
        guard storageReady else { return }
        UserDefaults.standard.removeObject(forKey: "workmate.pendingTaskAction")
        guard let task = workspace.tasks.first(where: { $0.id == id }) else { return }
        if kind == "complete" {
            if !task.isArchived { change { w in if let i = w.tasks.firstIndex(where: { $0.id == id }) { w.tasks[i].setCompleted(true) } } }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            toast("Completed · saved in Archive")
        } else if kind == "snooze", !task.isArchived {
            let until = (action["at"] as? Double ?? Date().timeIntervalSince1970) + 3600
            change { w in if let i = w.tasks.firstIndex(where: { $0.id == id }) { w.tasks[i].remindAt = Dates.iso(Date(timeIntervalSince1970: until)) } }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            toast("Snoozed for 1 hour")
        } else if kind == "open" {
            filterQuery = task.title; includeArchive = task.isArchived
        }
    }
    func enableNotifications() async {
        guard !previewMode, !requestingNotificationPermission else { return }
        requestingNotificationPermission = true
        defer { requestingNotificationPermission = false }
        let center = UNUserNotificationCenter.current()
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                macNotificationsAllowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } else {
                macNotificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            }
            guard macNotificationsAllowed else {
                error = "Allow Workmate notifications in System Settings → Notifications."; return
            }
            if !workspace.settings.browserNotifications { change { $0.settings.browserNotifications = true } }
            else { scheduleNotifications() }
        } catch { self.error = error.localizedDescription }
    }
    private func scheduleNotifications() {
        guard !previewMode else { return }
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            let settings = await center.notificationSettings()
            guard !Task.isCancelled else { return }
            self.macNotificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            guard self.macNotificationsAllowed else { return }
            var requests: [(Date, UNNotificationRequest)] = []
            let tasks = self.workspace.openTasks.filter { ($0.reminder ?? .distantPast) > Date() }
            for task in tasks {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent(); content.title = task.title; content.body = "\(task.priority.title) priority"; content.sound = .default
                content.categoryIdentifier = "WORKMATE_TASK"; content.userInfo = ["taskId": task.id]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, task.reminder!.timeIntervalSinceNow), repeats: false)
                requests.append((task.reminder!, UNNotificationRequest(identifier: task.id, content: content, trigger: trigger)))
            }
            var repeating = Set<String>()
            for occurrence in self.workspace.meetings.flatMap({ $0.occurrences() }) where occurrence.meeting.reminderEnabled && occurrence.start > Date() {
                let content = UNMutableNotificationContent()
                content.title = "\(occurrence.meeting.title) coming up"
                content.body = "\(occurrence.start.formatted(date: .omitted, time: .shortened))–\(occurrence.end.formatted(date: .omitted, time: .shortened)) · Open your meeting notes."
                content.sound = .default
                content.userInfo = ["meetingId": occurrence.meeting.id]
                if occurrence.meeting.recurrence == "weekly" {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: occurrence.meeting.timezone) ?? .current
                    let repeatID = occurrence.meeting.id + "-" + String(calendar.component(.weekday, from: occurrence.start))
                    guard repeating.insert(repeatID).inserted else { continue }
                    var components = calendar.dateComponents([.weekday, .hour, .minute], from: occurrence.reminderDate)
                    components.timeZone = calendar.timeZone; components.second = 0
                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                    requests.append((trigger.nextTriggerDate() ?? occurrence.reminderDate, UNNotificationRequest(identifier: "weekly-" + repeatID, content: content, trigger: trigger)))
                    continue
                }
                let fireKey = "meeting-fire-\(self.account)-\(occurrence.id)-\(occurrence.meeting.reminderMinutes)"
                let savedFire = UserDefaults.standard.double(forKey: fireKey)
                let fire = savedFire > 0 ? Date(timeIntervalSince1970: savedFire) : max(occurrence.reminderDate, Date().addingTimeInterval(3))
                guard fire > Date() else { continue }
                UserDefaults.standard.set(fire.timeIntervalSince1970, forKey: fireKey)
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
                requests.append((fire, UNNotificationRequest(identifier: "meeting-" + occurrence.id, content: content, trigger: trigger)))
            }
            for (_, request) in requests.sorted(by: { $0.0 < $1.0 }).prefix(60) {
                guard !Task.isCancelled else { return }
                try? await center.add(request)
            }
        }
    }
}

extension Notification.Name {
    static let workmateTaskAction = Notification.Name("workmate.taskAction")
    static let openWorkmateMeeting = Notification.Name("workmate.openMeeting") }
extension WorkspaceStore {
    var agenda: [MeetingOccurrence] { workspace.meetings.flatMap { $0.occurrences(after: clock) }.sorted { $0.start < $1.start } }
    var currentOrNextMeeting: MeetingOccurrence? { agenda.first }
    var focusedMeeting: Meeting? { workspace.meetings.first { $0.id == meetingFocusID } }
    func focusMeeting(_ id: String) {
        guard workspace.meetings.contains(where: { $0.id == id }) else { return }
        meetingFocusID = id
        filterQuery = ""
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Workmate" }?.makeKeyAndOrderFront(nil)
    }
    func saveMeeting(_ meeting: Meeting, linkingNoteID: String? = nil, linkingSectionID: String? = nil) {
        var meeting = meeting
        meeting.title = String(meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        change { w in
            if let i = w.meetings.firstIndex(where: { $0.id == meeting.id }) { w.meetings[i] = meeting }
            else { w.meetings.append(meeting) }
            if let linkingNoteID, let index = w.notes.firstIndex(where: { $0.id == linkingNoteID }) {
                var sections = w.notes[index].contentSections
                if let sectionIndex = sections.firstIndex(where: { $0.id == linkingSectionID }) ?? sections.indices.first {
                    var ids = sections[sectionIndex].meetingIds ?? []
                    if !ids.contains(meeting.id) { ids.append(meeting.id) }
                    sections[sectionIndex].meetingIds = ids
                    w.notes[index].setSections(sections)
                }
            }
        }
        if meeting.reminderEnabled { requestNotificationsIfNeeded() }
    }
    func requestNotificationsIfNeeded() {
        guard !previewMode else { return }
        Task { await enableNotifications() }
    }
    func linkNote(_ id: String, to meeting: Meeting) {
        guard let sectionID = workspace.notes.first(where: { $0.id == id })?.contentSections.first?.id else { return }
        linkSection(id, sectionID: sectionID, to: meeting)
    }
    func linkSection(_ noteID: String, sectionID: String, to meeting: Meeting) {
        editSections(noteID) { sections in
            guard let index = sections.firstIndex(where: { $0.id == sectionID }) else { return }
            var ids = sections[index].meetingIds ?? []
            if ids.contains(meeting.id) { ids.removeAll { $0 == meeting.id } } else { ids.append(meeting.id) }
            sections[index].meetingIds = ids
        }
    }
    func linkedNotes(for meeting: Meeting) -> [Note] { workspace.notes.filter { ($0.meetingIds ?? []).contains(meeting.id) } }
    func suggestedNotes(for meeting: Meeting) -> [Note] {
        workspace.notes.filter { note in
            guard !(note.meetingIds ?? []).contains(meeting.id) else { return false }
            if intelligence.insight(for: note, meetings: workspace.meetings)?.meetingIds.contains(meeting.id) == true { return true }
            let normalize: (String) -> String = { $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") }
            let title = normalize(meeting.title)
            return title.count > 3 && normalize(note.title + " " + note.body).contains(title)
        }
    }
    func meetingTasks(_ meeting: Meeting) -> [WorkTask] {
        let notes = Set(linkedNotes(for: meeting).map(\.id))
        return workspace.openTasks.filter { $0.meetingId == meeting.id || notes.contains($0.noteId) || $0.tagNames.contains(TaskTags.normalize(meeting.title)) }
    }
    func refreshCalendar() {
        guard let next = calendars.readMeetings(existing: workspace.meetings), next != workspace.meetings else { return }
        change { $0.meetings = next }
    }
    func createMeeting() {
        let start = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        editingMeeting = Meeting(title: "", start: start, end: start.addingTimeInterval(3600))
    }
    func search(_ query: String) -> SearchMatches {
        let suggestions = Dictionary(uniqueKeysWithValues: workspace.notes.map { ($0.id, intelligence.insight(for: $0, meetings: workspace.meetings)?.meetingIds ?? []) })
        return workspace.search(query, includeArchived: includeArchive, suggestedMeetingLinks: suggestions)
    }
    func applyFilter(_ query: String) {
        filterQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        meetingFocusID = nil; searchShown = false
    }
}
