import SwiftUI

private struct HelpTopic: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
}
private let helpTopics = [
    HelpTopic(id: "notes", symbol: "rectangle.split.2x1", title: "Notes, side by side", detail: "Press ⌘N to create a note. Use Add column to open another note beside it. Format notes with bold (⌘B), italic (⌘I), bullets, numbered lists, checklists, and links (⌘K). Use Add section to stack headings in a note column. The section icon beside each formatting toolbar lets you split at the cursor or merge with the section above. Click a checkbox to mark it done. Return continues a list; Return on an empty item ends it. Notes save automatically to your Workmate folder in iCloud Drive, or Documents if iCloud is unavailable."),
    HelpTopic(id: "actions", symbol: "checkmark.circle", title: "Actions and priorities", detail: "Type a next step in the Next column and press Return. Click its priority to choose Low, Medium, High or Urgent. Open an action to add lowercase tags; meeting names are suggested. Click a tag to search. Click the circle to complete an action; it moves to Archive, where you can restore it."),
    HelpTopic(id: "reminders", symbol: "bell", title: "Reminders and snooze", detail: "Click Remind me on an action. Pick a quick reminder or a date and time. Mac notifications are included once permission is allowed. Also notify in Telegram is optional for each task. Reminder buttons let you mark the action complete or snooze it for one hour."),
    HelpTopic(id: "meetings", symbol: "calendar", title: "Meetings that fit your week", detail: "Open Meetings → New meeting. Choose One-time or Recurring. Select any combination of weekdays, then set a separate start and end time for each day. Choose how early to be reminded. Link notes using Meeting at the bottom of a note; click a meeting at the top to see its notes and actions together."),
    HelpTopic(id: "search", symbol: "magnifyingglass", title: "Find anything, including the archive", detail: "Press ⌘F to search notes, actions and meetings. Searching PO-sync also finds content linked to that meeting. Tick Include archive to include completed actions."),
    HelpTopic(id: "connections", symbol: "externaldrive.connected.to.line.below", title: "Calendars, intelligence and Telegram", detail: "Open Settings to select calendars, enable on-device intelligence and connect a Telegram bot. In Telegram, open the connection link and tap Start. Choose priorities and a time in Daily brief. The Help menu can restart this tour anytime."),
    HelpTopic(id: "delivery", symbol: "network", title: "When Workmate is closed", detail: "macOS delivers reminders already scheduled on this Mac. The Raspberry Pi agent checks the AWS copy and delivers Telegram reminders independently of the app. Keep the Pi online and wait for your edits to sync before closing Workmate. Telegram completions and snoozes appear in iCloud when Workmate next syncs. If a reminder is missing, check macOS notification permission, Telegram connection and AWS backup in Settings.")
]

struct HelpView: View {
    @EnvironmentObject var store: WorkspaceStore
    @ViewState<Bool> var tutorial: Bool
    @ViewState<Int> private var page = 0
    @ViewState<String> private var query = ""
    private let tourIDs = ["notes", "actions", "meetings", "reminders"]
    private var topic: HelpTopic { helpTopics.first { $0.id == tourIDs[page] }! }
    private let tourTitles = ["Make room for your notes", "Turn thoughts into actions", "Meetings, on your schedule", "Remember at the right time"]
    private let tourDetails = [
        "Start a note with ⌘N. Add a column to keep related notes side by side.",
        "Add a next step, choose its priority, and check it off when you’re done. Completed actions stay in Archive.",
        "Choose the days you meet. Give each day its own times, then link your notes to the meeting.",
        "Pick a reminder time. Mac notifications are included; add Telegram when you want it there too."
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tutorial ? "Welcome to Workmate" : "Workmate Help").font(.system(size: tutorial ? 15 : 22, weight: .semibold))
                    if !tutorial {
                        Text("Find a quick answer.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                PopoverCloseButton { close() }
            }
            if tutorial {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tourTitles[page]).font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                    Text(tourDetails[page]).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                        .frame(height: 60, alignment: .topLeading)
                }
                tourExample.frame(height: 138).frame(maxWidth: .infinity)
                    .padding(16).background(Palette.field, in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line) }
                    .accessibilityElement(children: .combine).accessibilityLabel("Example: " + tourTitles[page])
                HStack(spacing: 10) {
                    Text("\(page + 1) / \(tourIDs.count)").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button(page == 0 ? "Not now" : "Back") {
                        if page == 0 { close() } else { page -= 1 }
                    }.modernButtonStyle()
                    Button(page == tourIDs.count - 1 ? "Get started" : "Next") {
                        if page < tourIDs.count - 1 { page += 1 } else { close() }
                    }.modernButtonStyle(prominent: true).keyboardShortcut(.defaultAction)
                }
            } else {
                TextField("Search help", text: $query).modernTextField(autofocus: true).accessibilityLabel("Search help")
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        let matches = helpTopics.filter { query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
                        ForEach(matches) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(item.title, systemImage: item.symbol).font(.system(size: 14, weight: .semibold))
                                Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider().overlay(Palette.line)
                        }
                        if matches.isEmpty { Text("No matching help topics.").foregroundStyle(.secondary) }
                    }
                }.frame(height: 330)
                HStack {
                    Text("⌘N  New note     ⌘F  Search     ⌘,  Settings").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart tour") { page = 0; tutorial = true }.modernButtonStyle()
                }
            }
        }.padding(24).frame(width: tutorial ? 420 : 480).popoverSurface()
        .onExitCommand { close() }
        .onDisappear { if tutorial { UserDefaults.standard.set(true, forKey: "workmate.tour.completed") } }
    }
    @ViewBuilder private var tourExample: some View {
        switch page {
        case 0:
            HStack(alignment: .top, spacing: 14) {
                exampleNote("Meeting notes", lines: [0.9, 0.65, 0.82])
                Rectangle().fill(Palette.line).frame(width: 1)
                exampleNote("Next ideas", lines: [0.7, 0.9, 0.5])
            }.padding(.vertical, 12)
        case 1:
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                    Text("Prepare the agenda").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    Text("High").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.orange.opacity(0.9))
                        .padding(.horizontal, 9).padding(.vertical, 5).background(Color.orange.opacity(0.08), in: Capsule())
                }
                Divider().overlay(Palette.line)
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    Text("Send the follow-up").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "archivebox").foregroundStyle(.secondary)
                }
            }
        case 2:
            VStack(alignment: .leading, spacing: 14) {
                Label("PO-sync", systemImage: "calendar").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack {
                    Text("Mon").frame(width: 42, alignment: .leading)
                    Text("09:00").frame(maxWidth: .infinity)
                    Text("–").foregroundStyle(.secondary)
                    Text("10:00").frame(maxWidth: .infinity)
                }
                HStack {
                    Text("Wed").frame(width: 42, alignment: .leading)
                    Text("13:00").frame(maxWidth: .infinity)
                    Text("–").foregroundStyle(.secondary)
                    Text("14:30").frame(maxWidth: .infinity)
                }
            }.font(.system(size: 13, weight: .medium)).monospacedDigit()
        default:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prepare the agenda").font(.system(size: 13, weight: .semibold))
                        Text("High priority · Today, 13:00").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text("Mark complete")
                    Text("Snooze 1 hour")
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                Divider().overlay(Palette.line)
                Label("Telegram is optional for each action", systemImage: "paperplane").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private func exampleNote(_ title: String, lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "doc.text").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, width in
                GeometryReader { geometry in
                    Capsule().fill(Color.white.opacity(0.13)).frame(width: geometry.size.width * width, height: 4)
                }.frame(height: 4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func close() {
        UserDefaults.standard.set(true, forKey: "workmate.tour.completed")
        store.helpShown = false
    }
}
