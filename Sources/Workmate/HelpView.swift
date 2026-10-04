import SwiftUI

private struct HelpTopic: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
}
private let helpTopics = [
    HelpTopic(id: "notes", symbol: "rectangle.split.2x1", title: "Notes, side by side", detail: "Press ⌘N to create a note. Use Add column to open another note beside it. Notes save automatically to your Workmate folder in iCloud Drive, or Documents if iCloud is unavailable."),
    HelpTopic(id: "actions", symbol: "checkmark.circle", title: "Actions and priorities", detail: "Type a next step in the Next column and press Return. Click its priority to choose Low, Medium, High or Urgent. Click the circle to complete it; it moves to Archive, where you can restore it."),
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
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tutorial ? "Welcome to Workmate" : "Workmate Help").font(.system(size: 22, weight: .semibold))
                    Text(tutorial ? "A clear place for your working day." : "A few simple ways to stay on top of things.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                PopoverCloseButton { close() }
            }
            if tutorial {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: topic.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent)
                        .frame(width: 64, height: 64).background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    Text(topic.title).font(.system(size: 20, weight: .semibold))
                    Text(topic.detail).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    if page == 2 {
                        VStack(spacing: 12) {
                            sampleDay("Mon", "09:00", "10:00")
                            sampleDay("Wed", "13:00", "14:30")
                        }.padding(16).background(Palette.field, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, minHeight: 285, alignment: .topLeading)
                HStack(spacing: 7) {
                    ForEach(0..<tourIDs.count, id: \.self) { index in
                        Circle().fill(index == page ? Palette.accent : Color.white.opacity(0.18)).frame(width: 6, height: 6)
                    }
                    Text("\(page + 1) of \(tourIDs.count)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 5)
                    Spacer()
                    if page > 0 { Button("Back") { page -= 1 }.modernButtonStyle() }
                    Button(page == tourIDs.count - 1 ? "Get started" : "Next") {
                        if page < tourIDs.count - 1 { page += 1 } else { close() }
                    }.modernButtonStyle(prominent: true).keyboardShortcut(.defaultAction)
                }
                if page == 0 { Button("Skip tour") { close() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12)) }
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
        }.padding(26).frame(width: 480).popoverSurface()
        .onExitCommand { close() }
    }
    private func sampleDay(_ day: String, _ from: String, _ to: String) -> some View {
        HStack { Text(day).foregroundStyle(Palette.accent).frame(width: 40, alignment: .leading); Spacer(); Text(from); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(to) }.font(.system(size: 13, weight: .medium)).monospacedDigit()
    }
    private func close() {
        UserDefaults.standard.set(true, forKey: "workmate.tour.completed")
        store.helpShown = false
    }
}
