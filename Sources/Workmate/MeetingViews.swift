import SwiftUI
import EventKit
import WorkmateCore

struct MeetingsSheet: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var query = ""
    private var meetings: [Meeting] {
        store.workspace.meetings.filter { !$0.canceled && (query.isEmpty || $0.title.localizedStandardContains(query)) }
            .sorted { left, right in
                let a = left.occurrences(after: store.clock).first?.start ?? .distantFuture
                let b = right.occurrences(after: store.clock).first?.start ?? .distantFuture
                return a == b ? left.title.localizedStandardCompare(right.title) == .orderedAscending : a < b
            }
    }
    var body: some View {
        if let editing = store.editingMeeting {
            MeetingEditor(meeting: editing).environmentObject(store)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Calendar").font(.system(size: 18, weight: .semibold)); Spacer(); PopoverCloseButton { dismiss() } }
                TextField("Find a meeting…", text: $query).modernTextField(autofocus: true).accessibilityLabel("Find a meeting")
                Button { store.createMeeting() } label: {
                    Label("New meeting", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(FullHitButtonStyle()).foregroundStyle(Palette.accent).padding(.vertical, 4)
                Button { store.importCalendarFile() } label: {
                    Label("Import ICS file…", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(FullHitButtonStyle()).foregroundStyle(Palette.accent).padding(.vertical, 4)
                Divider().overlay(Palette.line)
                if meetings.isEmpty {
                    Text(query.isEmpty ? "Add your first meeting to keep its notes and actions together." : "No matching meetings.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 16)
                } else {
                    Text("FILTER BY MEETING").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(meetings) { meeting in
                                HStack(spacing: 12) {
                                    Button { store.focusMeeting(meeting.id); dismiss() } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "calendar").foregroundStyle(Palette.accent)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                                if let next = meeting.occurrences(after: store.clock).first {
                                                    Text(next.isCurrent(at: store.clock) ? "Happening now" : next.start.formatted(date: .abbreviated, time: .shortened))
                                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                                } else { Text("Notes & actions").font(.system(size: 11)).foregroundStyle(.secondary) }
                                            }
                                            Spacer()
                                            if store.meetingFocusID == meeting.id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                                        }.padding(.vertical, 10).contentShape(Rectangle())
                                    }.buttonStyle(FullHitButtonStyle()).accessibilityLabel("Filter by " + meeting.title)
                                    Button { store.editingMeeting = meeting } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28).contentShape(Rectangle()) }
                                        .buttonStyle(FullHitButtonStyle()).foregroundStyle(.secondary).help("Edit meeting").accessibilityLabel("Edit " + meeting.title)
                                }
                            }
                        }
                    }.frame(maxHeight: 290)
                }
                Divider().overlay(Palette.line)
                HStack {
                    Button("All notes") { store.meetingFocusID = nil; store.filterQuery = ""; dismiss() }.buttonStyle(FullHitButtonStyle())
                    Spacer()
                    Button("Connect calendar") { dismiss(); store.settingsSection = "calendars"; store.settingsShown = true }.buttonStyle(FullHitButtonStyle())
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(22).frame(width: 380).popoverSurface()
        }
    }
}

struct MeetingEditor: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ViewState<Meeting> var meeting: Meeting
    var linkingNoteID: String? = nil
    var linkingSectionID: String? = nil
    @ViewState<Bool> private var removing = false
    private var start: Binding<Date> { Binding(get: { meeting.start }, set: { value in
        let duration = meeting.end.timeIntervalSince(meeting.start)
        meeting.startAt = Dates.iso(value); meeting.endAt = Dates.iso(value.addingTimeInterval(max(900, duration)))
    }) }
    private var end: Binding<Date> { Binding(get: { meeting.end }, set: { meeting.endAt = Dates.iso($0) }) }
    private var meetingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: meeting.timezone) ?? .current
        return calendar
    }
    private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
    private var selectedDays: Set<Int> { meeting.recurringWeekdays }
    private var repeatDescription: String {
        if selectedDays.count == 7 { return "Every day" }
        if selectedDays == Set([2, 3, 4, 5, 6]) { return "Every weekday" }
        return "Every " + weekdayOrder.filter { selectedDays.contains($0) }.map { String(weekdayNames[$0 - 1].prefix(3)) }.joined(separator: ", ")
    }
    private func toggleDay(_ day: Int) {
        var rules = meeting.daySchedules
        if rules.contains(where: { $0.weekday == day }) {
            guard rules.count > 1 else { return }
            rules.removeAll { $0.weekday == day }
        } else {
            let template = rules.first ?? MeetingDaySchedule(weekday: day, startTime: "09:00", endTime: "10:00")
            rules.append(.init(weekday: day, startTime: template.startTime, endTime: template.endTime))
        }
        meeting.scheduleWeekly(with: rules)
    }
    private func dayTime(_ day: Int, end: Bool) -> Binding<Date> {
        Binding(get: {
            let rule = meeting.daySchedules.first { $0.weekday == day } ?? .init(weekday: day, startTime: "09:00", endTime: "10:00")
            let parts = (end ? rule.endTime : rule.startTime).split(separator: ":").compactMap { Int($0) }
            return meetingCalendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: meeting.start)!
        }, set: { value in
            var rules = meeting.daySchedules
            guard let index = rules.firstIndex(where: { $0.weekday == day }) else { return }
            let text = String(format: "%02d:%02d", meetingCalendar.component(.hour, from: value), meetingCalendar.component(.minute, from: value))
            if end { rules[index].endTime = text } else { rules[index].startTime = text }
            meeting.scheduleWeekly(with: rules)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "calendar").foregroundStyle(Palette.accent)
                Text(meeting.isImported ? "Meeting reminder" : "Meeting")
                    .font(.system(size: 17, weight: .semibold))
            }
            TextField("e.g. PO-sync", text: $meeting.title)
                .modernTextField(autofocus: !meeting.isImported).disabled(meeting.isImported)
                .accessibilityLabel("Meeting title").onSubmit(save)
            if meeting.isImported {
                Text("\(meeting.start.formatted(date: .abbreviated, time: .shortened)) – \(meeting.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 13))
                Text("From \(meeting.calendarName). Change the meeting time in Calendar.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    scheduleChoice("One-time", value: "none")
                    scheduleChoice("Recurring", value: "weekly")
                }.padding(4).background(Palette.field, in: Capsule())
                VStack(spacing: 0) {
                    if meeting.recurrence == "weekly" {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Repeat on").font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                ForEach(weekdayOrder, id: \.self) { day in
                                    let selected = selectedDays.contains(day)
                                    Button { toggleDay(day) } label: {
                                        Text(String(weekdayNames[day - 1].prefix(3)))
                                            .font(.system(size: 11, weight: .semibold))
                                            .frame(maxWidth: .infinity, minHeight: 36)
                                            .foregroundStyle(selected ? Color.white : Color.secondary)
                                            .background(selected ? Palette.accent : Palette.field, in: RoundedRectangle(cornerRadius: 10))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(FullHitButtonStyle()).accessibilityLabel(weekdayNames[day - 1])
                                        .accessibilityValue(selected ? "Selected" : "Not selected")
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                }
                            }
                        }.padding(14)
                        Divider().padding(.horizontal, 14)
                        VStack(spacing: 10) {
                            HStack {
                                Text("Day").frame(width: 42, alignment: .leading)
                                Text("Starts").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Ends").frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                            ScrollView {
                            VStack(spacing: 10) {
                            ForEach(weekdayOrder.filter { selectedDays.contains($0) }, id: \.self) { day in
                                HStack(spacing: 10) {
                                    Text(String(weekdayNames[day - 1].prefix(3))).font(.system(size: 12, weight: .medium)).frame(width: 32, alignment: .leading)
                                    NativeTimeField(date: dayTime(day, end: false), timezone: meetingCalendar.timeZone, label: "\(weekdayNames[day - 1]) start")
                                        .frame(height: 28).padding(.horizontal, 10).padding(.vertical, 3).background(Palette.field, in: RoundedRectangle(cornerRadius: 9))
                                    NativeTimeField(date: dayTime(day, end: true), timezone: meetingCalendar.timeZone, label: "\(weekdayNames[day - 1]) end")
                                        .frame(height: 28).padding(.horizontal, 10).padding(.vertical, 3).background(Palette.field, in: RoundedRectangle(cornerRadius: 9))
                                }
                            }
                            }
                            }.frame(height: min(CGFloat(selectedDays.count) * 44 - 10, 210))
                        }.padding(14)
                    } else {
                        meetingDateRow("Starts", date: start)
                        Divider().padding(.horizontal, 14)
                        meetingDateRow("Ends", date: end)
                    }
                }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line) }
                if meeting.recurrence == "weekly" {
                    Text("\(repeatDescription) · An earlier end time finishes the next day.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Label("Reminder", systemImage: "bell").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("None") { meeting.reminderEnabled = false }
                    ForEach([0, 5, 10, 15, 30, 60], id: \.self) { minutes in
                        Button(minutes == 0 ? "At the start" : "\(minutes) min before") {
                            meeting.reminderEnabled = true; meeting.reminderMinutes = minutes
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(!meeting.reminderEnabled ? "None" : meeting.reminderMinutes == 0 ? "At the start" : "\(meeting.reminderMinutes) min before")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Meeting reminder")
            }
            Divider().overlay(Palette.line)
            HStack(spacing: 10) {
                if store.workspace.meetings.contains(where: { $0.id == meeting.id }) && !meeting.isImported {
                    Button { removing = true } label: {
                        Image(systemName: "trash").font(.system(size: 13)).frame(width: 18, height: 18)
                    }.modernButtonStyle(shape: .circle).accessibilityLabel("Delete meeting").help("Delete meeting")
                }
                Spacer()
                Button("Cancel") { dismiss() }.modernButtonStyle()
                Button("Save meeting", action: save).modernButtonStyle(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meeting.end <= meeting.start)
            }
        }.padding(24).frame(width: 420).popoverSurface()
        .onExitCommand { dismiss() }
        .confirmationDialog("Remove this meeting?", isPresented: $removing) {
            Button("Remove meeting", role: .destructive) {
                store.change { w in w.meetings.removeAll { $0.id == meeting.id } }
                if store.meetingFocusID == meeting.id { store.meetingFocusID = nil }
                dismiss()
            }
        } message: { Text("Your notes and tasks will stay saved.") }
    }
    private func save() {
        guard !meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, meeting.end > meeting.start else { return }
        store.saveMeeting(meeting, linkingNoteID: linkingNoteID, linkingSectionID: linkingSectionID); dismiss()
    }
    private func scheduleChoice(_ title: String, value: String) -> some View {
        Button {
            guard meeting.recurrence != value else { return }
            if value == "weekly" { meeting.scheduleWeekly(with: meeting.daySchedules) }
            else { meeting.recurrence = "none" }
        } label: {
            Text(title).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
                .foregroundStyle(meeting.recurrence == value ? Color.white : .secondary)
                .background(meeting.recurrence == value ? Palette.accent : .clear, in: Capsule())
                .contentShape(Rectangle())
        }.buttonStyle(FullHitButtonStyle()).accessibilityAddTraits(meeting.recurrence == value ? .isSelected : [])
    }
    private func meetingDateRow(_ title: String, date: Binding<Date>) -> some View {
        MeetingDateRow(title: title, date: date, timezone: meetingCalendar.timeZone)
    }

}

private struct MeetingDateRow: View {
    let title: String
    @Binding var date: Date
    var timezone: TimeZone
    @ViewState<Bool> private var choosingDate = false
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { choosingDate = true } label: {
                HStack(spacing: 6) {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }.modernButtonStyle().accessibilityLabel("\(title) date")
                .popover(isPresented: $choosingDate) {
                    VStack(spacing: 18) {
                        HStack {
                            Text("\(title) date").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            PopoverCloseButton { choosingDate = false }
                        }
                        ReminderCalendar(date: $date)
                    }.padding(20).frame(width: 320).popoverSurface()
                }
            NativeTimeField(date: $date, timezone: timezone, label: "\(title) time")
                .frame(width: 76, height: 28).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Palette.field, in: Capsule())
        }.padding(14)
    }
}

struct MeetingFocusView: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var intelligence: IntelligenceController
    let meeting: Meeting
    @ViewState<Bool> private var showBrief = true
    @ViewState<Bool> private var linkExisting = false
    @ViewState<Bool> private var editMeeting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button { store.meetingFocusID = nil } label: { Label("All notes", systemImage: "chevron.left") }
                .buttonStyle(FullHitButtonStyle()).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(meeting.title).font(.system(size: 30, weight: .medium))
                    let occurrence = meeting.occurrences(after: store.clock).first
                    Text("\((occurrence?.start ?? meeting.start).formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) · \((occurrence?.start ?? meeting.start).formatted(date: .omitted, time: .shortened))–\((occurrence?.end ?? meeting.end).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if meeting.occurrences(after: store.clock).first?.isCurrent(at: store.clock) == true {
                    Label("In progress", systemImage: "circle.fill").font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
                Button { editMeeting = true } label: { Image(systemName: "ellipsis") }.buttonStyle(FullHitButtonStyle()).help("Meeting details")
                    .popover(isPresented: $editMeeting, arrowEdge: .bottom) { MeetingEditor(meeting: meeting).environmentObject(store) }
            }
            Divider().overlay(Palette.line)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    let notes = store.linkedNotes(for: meeting)
                    let summaries = notes.compactMap { note -> (Note, NoteInsight)? in
                        guard let insight = intelligence.insight(for: note, meetings: store.workspace.meetings) else { return nil }
                        return (note, insight)
                    }
                    if !summaries.isEmpty {
                        DisclosureGroup(isExpanded: $showBrief) {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(summaries, id: \.0.id) { note, insight in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(note.displayTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                        Text(insight.summary).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                                        ForEach(insight.actions, id: \.self) { action in
                                            if !store.workspace.tasks.contains(where: { $0.title == action && ($0.noteId == note.id || $0.meetingId == meeting.id) }) {
                                                HStack {
                                                    Text(action).font(.system(size: 12)).foregroundStyle(.secondary)
                                                    Spacer()
                                                    Button("Add action") { store.change { w in var task = WorkTask(title: action, noteId: note.id); task.meetingId = meeting.id; w.tasks.append(task) } }.font(.system(size: 11))
                                                }
                                            }
                                        }
                                    }
                                }
                            }.padding(.top, 14)
                        } label: { Label("AI briefing", systemImage: "sparkles").font(.system(size: 12)).foregroundStyle(Palette.accent) }
                        .padding(15).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        Text("Meeting notes").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        if intelligence.running { ProgressView().controlSize(.mini); Text("Reading notes…").font(.system(size: 10)).foregroundStyle(.secondary) }
                        Button { linkExisting = true } label: { Label("Link a note", systemImage: "link") }.buttonStyle(FullHitButtonStyle()).font(.system(size: 11))
                            .popover(isPresented: $linkExisting) {
                                NoteChooser { id in
                                    if !(store.workspace.notes.first { $0.id == id }?.meetingIds ?? []).contains(meeting.id) { store.linkNote(id, to: meeting) }
                                    linkExisting = false
                                }.environmentObject(store)
                            }
                        Button { store.newNote() } label: { Image(systemName: "plus") }.buttonStyle(FullHitButtonStyle()).help("New meeting note")
                    }
                    if notes.isEmpty {
                        VStack(alignment: .leading, spacing: 15) {
                            Text("Everything for \(meeting.title), in one place.").font(.system(size: 16))
                            Text("Link existing notes or start a fresh one. Related notes will appear as suggestions.").font(.system(size: 13)).foregroundStyle(.secondary)
                            Button("Start meeting notes") { store.newNote() }.modernButtonStyle()
                        }.padding(.top, 25).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        GeometryReader { geometry in
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 24) {
                                    ForEach(notes) { note in NoteColumn(note: note).frame(width: max(300, (geometry.size.width - CGFloat(max(0, notes.count - 1)) * 24) / CGFloat(notes.count))) }
                                }.frame(height: geometry.size.height)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    Text("Next for this meeting").font(.system(size: 13, weight: .medium))
                    QuickAddTask()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.meetingTasks(meeting)) { task in TaskRow(task: task) }
                            let suggestions = store.suggestedNotes(for: meeting)
                            if !suggestions.isEmpty {
                                Divider().padding(.vertical, 12)
                                Text("Suggested links").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                ForEach(suggestions) { note in
                                    HStack {
                                        Text(note.displayTitle).font(.system(size: 12)).lineLimit(2)
                                        Spacer()
                                        Button { store.linkNote(note.id, to: meeting) } label: { Image(systemName: "plus.circle") }.buttonStyle(FullHitButtonStyle()).help("Link \(note.displayTitle)")
                                    }.padding(.vertical, 6)
                                }
                            }
                            Button { intelligence.scan(store.workspace, immediate: true) } label: { Label(intelligence.running ? "Scanning…" : "Scan notes", systemImage: "sparkles") }
                                .buttonStyle(FullHitButtonStyle()).font(.system(size: 11)).foregroundStyle(Palette.accent).disabled(!intelligence.available || intelligence.running).padding(.top, 15)
                            if !intelligence.available { Text(intelligence.availabilityText).font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(width: 265)
            }
        }.padding(.horizontal, 38).padding(.bottom, 30)
    }
}
