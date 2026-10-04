import SwiftUI
import AppKit
import WorkmateCore

struct PriorityMenu: View {
    @Binding var priority: Priority
    @ViewState<Bool> private var shown = false
    var body: some View {
        Button { shown = true } label: {
            HStack(spacing: 5) {
                Circle().fill(priority.tint).frame(width: 4, height: 4)
                Text(priority.title).font(.system(size: 10))
            }.foregroundStyle(priority.tint)
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel("Priority: \(priority.title)").help("Change priority")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Priority").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
                ForEach(Priority.allCases) { value in
                    Button { priority = value; shown = false } label: {
                        HStack(spacing: 10) {
                            Circle().fill(value.tint).frame(width: 7, height: 7)
                            Text(value.title).font(.system(size: 13))
                            Spacer()
                            if value == priority { Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(value.tint) }
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(18).frame(width: 205).popoverSurface()
        }
    }
}

struct ReminderControl: View {
    @EnvironmentObject var store: WorkspaceStore
    @Binding var date: Date?
    @Binding var sendToTelegram: Bool
    @ViewState<Bool> private var shown = false
    @ViewState<Bool> private var custom = false
    @ViewState<Date> private var draft = Dates.tomorrowMorning()
    var compact = false
    var prominent = false
    var body: some View {
        Button {
            draft = date ?? Dates.tomorrowMorning(); custom = false; shown = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: date == nil ? "bell" : "bell.fill").font(.system(size: prominent ? 12 : 10))
                if let date {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: prominent ? 13 : 10)).lineLimit(1)
                } else if !compact { Text(prominent ? "Add reminder" : "Remind me").font(.system(size: prominent ? 13 : 10)) }
                if date != nil && sendToTelegram { Image(systemName: "paperplane.fill").font(.system(size: 10)) }
                if prominent { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
            }.foregroundStyle(date == nil && !prominent ? Palette.muted : Palette.accent)
                .padding(.horizontal, prominent ? 12 : 0).padding(.vertical, prominent ? 8 : 0)
                .background(prominent ? Palette.accent.opacity(0.10) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.map { "Reminder: \($0.formatted(date: .abbreviated, time: .shortened)), \(sendToTelegram ? "Mac and Telegram" : "Mac")" } ?? "Add reminder")
        .help("Set a reminder")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Remind me").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    PopoverCloseButton { shown = false }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("On this Mac", systemImage: "desktopcomputer")
                        Spacer()
                        Label("Always", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.help("Mac notifications are always included. Workmate needs notification permission in macOS.")
                    Toggle(isOn: $sendToTelegram) {
                        Label("Also notify in Telegram", systemImage: "paperplane")
                    }.toggleStyle(.switch).controlSize(.small)
                    if sendToTelegram && !store.telegram.connected {
                        Text("Connect Telegram in Settings to receive this reminder there.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Open Settings") { shown = false; store.settingsSection = "telegram"; store.settingsShown = true }.modernButtonStyle()
                    }
                }
                Divider().overlay(Palette.line)
                if custom {
                    ReminderCalendar(date: $draft)
                    Divider().overlay(Palette.line)
                    HStack {
                        Label("Time", systemImage: "clock").foregroundStyle(.secondary)
                        Spacer()
                        NativeTimeField(date: $draft, timezone: .current, label: "Reminder time")
                            .frame(width: 90, height: 28).padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Palette.field, in: Capsule())
                    }

                    HStack {
                        Button("Back") { custom = false }.modernButtonStyle()
                        Spacer()
                        Button("Set reminder") { date = draft; shown = false }
                            .modernButtonStyle(prominent: true).disabled(draft <= Date())
                    }
                } else {
                    quick("In 1 hour", symbol: "clock", value: Date().addingTimeInterval(3600))
                    quick("Tomorrow morning", symbol: "sunrise", value: Dates.tomorrowMorning())
                    quick("Next Monday", symbol: "calendar", value: Dates.nextMonday())
                    Divider()
                    Button { custom = true } label: {
                        HStack { Label("Choose date & time…", systemImage: "calendar.badge.clock"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)) }
                    }.buttonStyle(.plain)
                    if date != nil {
                        Divider()
                        Button("Remove reminder", role: .destructive) { date = nil; shown = false }.buttonStyle(.plain)
                    }
                }
            }.font(.system(size: 13)).padding(20).frame(width: 320).popoverSurface().modernButtonStyle()
        }
    }
    private func quick(_ title: String, symbol: String, value: Date) -> some View {
        Button { date = value; shown = false } label: {
            HStack {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(title); Spacer()
                Text(value, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
struct QuickAddTask: View {
    @EnvironmentObject var store: WorkspaceStore
    @ViewState<String> private var title = ""
    @ViewState<Priority> private var priority: Priority = .medium
    @ViewState<Date?> private var reminder: Date?
    @ViewState<Bool> private var telegramReminder = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                TextField("Add a next step…", text: $title).textFieldStyle(.plain)
                    .font(.system(size: 13)).onSubmit(add).focused($focused).accessibilityLabel("Add a task")
                Button(action: add) { Image(systemName: "plus.circle.fill").font(.system(size: 17)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Save task")
            }
            HStack(spacing: 15) {
                PriorityMenu(priority: $priority)
                ReminderControl(date: $reminder, sendToTelegram: $telegramReminder)
                Spacer(minLength: 0)
            }
        }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1) }
    }
    private func add() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addTask(title, priority: priority, reminder: reminder, telegramReminder: telegramReminder)
        title = ""; reminder = nil; telegramReminder = false; focused = true
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: WorkspaceStore
    var task: WorkTask
    @ViewState<Bool> private var edit = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { store.toggleTask(task) } label: {
                Image(systemName: task.isArchived ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .light)).foregroundStyle(task.isArchived ? Palette.accent : Color.white.opacity(0.28))
            }.buttonStyle(.plain).padding(.top, 1).accessibilityLabel("\(task.isArchived ? "Restore" : "Complete") \(task.title)")
                .help(task.isArchived ? "Restore to Next" : "Complete and archive")
            VStack(alignment: .leading, spacing: 8) {
                Button { edit = true } label: {
                    Text(task.title).font(.system(size: 13)).multilineTextAlignment(.leading).lineSpacing(4)
                        .foregroundStyle(task.isArchived ? Color.secondary : Color.white.opacity(0.84)).strikethrough(task.isArchived)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).popover(isPresented: $edit, arrowEdge: .bottom) { TaskEditor(task: task).environmentObject(store) }
                if task.isArchived {
                    HStack(spacing: 5) {
                        Label("Archived", systemImage: "archivebox")
                        if let completedAt = task.completedAt.flatMap(Dates.parse) {
                            Text("·")
                            Text(completedAt, format: .dateTime.day().month(.abbreviated).year())
                        }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 13) {
                        PriorityMenu(priority: Binding(get: { task.priority }, set: { value in store.updateTask(task.id) { $0.priority = value } }))
                        ReminderControl(
                            date: Binding(get: { task.reminder }, set: { value in store.updateTask(task.id) { $0.reminder = value } }),
                            sendToTelegram: Binding(get: { task.notifiesTelegram }, set: { value in store.updateTask(task.id) { $0.notifiesTelegram = value } })
                        )
                        Spacer(minLength: 0)
                    }
                }
            }
        }.padding(.vertical, 12).padding(.horizontal, 2)
        .contextMenu {
            Button(task.isArchived ? "Restore to Next" : "Complete and archive") { store.toggleTask(task) }
            Button("Edit task…") { edit = true }
            Menu("Priority") { ForEach(Priority.allCases) { p in Button(p.title) { store.updateTask(task.id) { $0.priority = p } } } }
            Button("Remind in 1 hour") { store.updateTask(task.id) { $0.reminder = Date().addingTimeInterval(3600) } }
        }
    }
}

struct TaskEditor: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ViewState<WorkTask> var task: WorkTask
    @ViewState<Bool> private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle").foregroundStyle(Palette.accent)
                Text("Edit task").font(.system(size: 17, weight: .semibold))
                Spacer()
                if task.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
            }
            TextField("What needs doing?", text: $task.title)
                .modernTextField(autofocus: true).accessibilityLabel("Task title").onSubmit(save)
            VStack(alignment: .leading, spacing: 10) {
                Text("Priority").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    ForEach(Priority.allCases) { value in
                        Button { task.priority = value } label: {
                            Text(value.title).frame(maxWidth: .infinity)
                        }.modernButtonStyle(prominent: task.priority == value)
                            .accessibilityLabel("Priority: \(value.title)")
                            .accessibilityAddTraits(task.priority == value ? .isSelected : [])
                    }
                }
            }
            HStack {
                Label("Reminder", systemImage: "bell").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                ReminderControl(
                    date: Binding(get: { task.reminder }, set: { task.reminder = $0 }),
                    sendToTelegram: Binding(get: { task.notifiesTelegram }, set: { task.notifiesTelegram = $0 }), prominent: true
                )
            }
            Divider().overlay(Palette.line)
            HStack(spacing: 10) {
                Button { deleting = true } label: {
                    Image(systemName: "trash").font(.system(size: 13)).frame(width: 18, height: 18)
                }.modernButtonStyle(shape: .circle).accessibilityLabel("Delete task").help("Delete task")
                Spacer()
                Button("Cancel") { dismiss() }.modernButtonStyle()
                Button("Save", action: save).modernButtonStyle(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 400).popoverSurface()
        .onExitCommand { dismiss() }
        .confirmationDialog("Delete this task?", isPresented: $deleting) { Button("Delete task", role: .destructive) { store.deleteTask(task.id); dismiss() } }
    }
    private func save() {
        task.title = String(task.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !task.title.isEmpty else { return }
        store.updateTask(task.id) { $0 = task }; dismiss()
    }
}

struct SearchSheet: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                NativeSearchField(text: $query, placeholder: "Search notes, tasks & meetings", onSubmit: { store.applyFilter(query) })
                PopoverCloseButton { dismiss() }
            }
            Toggle("Include archive", isOn: $store.includeArchive).toggleStyle(.checkbox).font(.system(size: 12))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let matches = store.search(query)
                    ForEach(matches.meetings) { meeting in
                        Button { store.focusMeeting(meeting.id); dismiss() } label: { Label(meeting.title, systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }.buttonStyle(.plain)
                    }
                    ForEach(query.isEmpty ? store.workspace.notes : matches.notes) { note in
                        Button { store.filterQuery = ""; store.meetingFocusID = nil; store.openNote(note.id); dismiss() } label: { Label(note.displayTitle, systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }.buttonStyle(.plain)
                    }
                    ForEach(matches.tasks) { task in TaskRow(task: task) }
                    if !query.isEmpty && matches.count == 0 { Text("No matching notes, tasks or meetings.").foregroundStyle(.secondary).padding(.vertical, 20) }
                }.font(.system(size: 13))
            }.frame(height: 300)
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Button { store.applyFilter(query) } label: { Label("Show everything for “\(query)”", systemImage: "line.3.horizontal.decrease") }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.accent)
            }
        }.padding(20).frame(width: 470).onAppear { query = store.filterQuery }
    }
}
