import SwiftUI
import AppKit
import WorkmateCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var calendars: CalendarController
    @EnvironmentObject var intelligence: IntelligenceController
    @ViewState<Bool> private var cloudOpen = true
    @ViewState<Bool> private var telegramOpen = false
    @ViewState<Bool> private var briefOpen = true
    @ViewState<String> private var token = ""
    @ViewState<Bool> private var working = false
    @ViewState<Bool> private var showPreview = false
    @ViewState<Bool> private var disconnecting = false
    @ViewState<String> private var timezone = ""
    @ViewState<Bool> private var calendarOpen = false
    @ViewState<Bool> private var intelligenceOpen = false
    private var time: Binding<Date> {
        Binding(get: {
            let parts = store.workspace.settings.digestTime.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: parts.first ?? 8, minute: parts.last ?? 30, second: 0, of: Date()) ?? Date()
        }, set: { value in
            let c = Calendar.current.dateComponents([.hour, .minute], from: value)
            store.change { $0.settings.digestTime = String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 30) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Settings").font(.system(size: 23, weight: .medium)); Spacer(); PopoverCloseButton { dismiss() } }.padding(28)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    HStack {
                        Label("Help & getting started", systemImage: "questionmark.circle").font(.system(size: 13))
                        Spacer()
                        Button("Open help") { store.settingsShown = false; store.openHelp() }
                    }
                    Divider()
                    if let error = store.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let message = store.message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.accent) }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(store.files.usesICloud ? "iCloud Drive" : "Documents", systemImage: store.files.usesICloud ? "icloud" : "folder")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Text("Your workspace").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(store.files.usesICloud ? "Notes, tasks, meetings and settings are saved to Documents / Workmate in your iCloud Drive. macOS syncs these files with your current Apple Account." : "Your files are saved in Documents / Workmate. Enable iCloud Drive in System Settings to use iCloud on this Mac.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Show files in Finder") { store.showFiles() }
                    }
                    Divider()
                    DisclosureGroup(isExpanded: $calendarOpen) {
                        VStack(alignment: .leading, spacing: 13) {
                            if calendars.authorized {
                                Text("Choose the calendars to show in Workmate.").font(.system(size: 12)).foregroundStyle(.secondary)
                                ForEach(calendars.calendars, id: \.calendarIdentifier) { calendar in
                                    Toggle(isOn: Binding(get: { calendars.selected.contains(calendar.calendarIdentifier) }, set: { _ in
                                        calendars.toggle(calendar)
                                        if !store.macNotificationsAllowed { Task { await store.enableNotifications() } }
                                    })) {
                                        HStack { Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 7, height: 7); Text(calendar.title).font(.system(size: 12)); Spacer(); Text(calendar.source.title).font(.system(size: 10)).foregroundStyle(.secondary) }
                                    }.toggleStyle(.checkbox)
                                }
                                if calendars.calendars.isEmpty { Text("No calendars found. Open Calendar and choose Calendar → Add Account.").font(.system(size: 12)).foregroundStyle(.secondary) }
                                Button("Refresh calendars") { calendars.refresh(); store.refreshCalendar() }
                            } else {
                                Text("Use calendars already connected to macOS, including iCloud, Google, and Exchange. Workmate reads the calendars you choose.").font(.system(size: 12)).foregroundStyle(.secondary)
                                Button("Connect Mac calendars") { Task { await calendars.connect() } }
                            }
                            Text("To add iCloud, Google or Exchange, open Calendar → Add Account. Then return here and choose your calendars.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("Open Calendar") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
                            if let error = calendars.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
                            Text("Meeting notifications open a focused view of the meeting’s notes and actions.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.top, 16)
                    } label: { settingsLabel("Calendars", subtitle: calendars.selected.isEmpty ? "Not connected" : "\(calendars.selected.count) selected") }
                    Divider()
                    DisclosureGroup(isExpanded: $intelligenceOpen) {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Scan notes with AI", isOn: Binding(get: { intelligence.enabled }, set: { value in intelligence.setEnabled(value, workspace: store.workspace); store.updateConfiguration { $0.intelligenceEnabled = value } })).toggleStyle(.switch).controlSize(.small)
                            Text(intelligence.availabilityText).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("Suggests meeting links, short summaries, and unfinished action points. Suggestions are based on your notes and can be wrong; add the ones you want to keep. Notes are processed on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
                            if !intelligence.status.isEmpty { Text(intelligence.status).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Button(intelligence.running ? "Scanning notes…" : "Scan now") { intelligence.scan(store.workspace, immediate: true) }.disabled(!intelligence.available || !intelligence.enabled || intelligence.running)
                        }.padding(.top, 16)
                    } label: { settingsLabel("Intelligence", subtitle: intelligence.running ? "Scanning…" : intelligence.available && intelligence.enabled ? "On device" : "Unavailable") }
                    Divider()
                    DisclosureGroup(isExpanded: $cloudOpen) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("A second copy in private S3 storage in Stockholm. Your iCloud files remain the main workspace. Your Raspberry Pi checks this copy to deliver Telegram reminders while Workmate is closed.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if store.driveConfiguration.serviceToken != nil {
                                Toggle("Keep an AWS backup", isOn: Binding(get: { store.driveConfiguration.backupEnabled }, set: { enabled in
                                    store.updateConfiguration { $0.backupEnabled = enabled }
                                    if enabled { Task { await store.backUpNow() } }
                                })).toggleStyle(.switch).controlSize(.small)
                                if let seen = store.telegram.agentLastSeen.flatMap({ WorkmateCore.Dates.parse($0) }) {
                                    let online = Date().timeIntervalSince(seen) < 180
                                    Label(online ? "Raspberry Pi · Online" : "Raspberry Pi · Last seen " + seen.formatted(date: .omitted, time: .shortened), systemImage: online ? "checkmark.circle.fill" : "exclamationmark.circle")
                                        .font(.system(size: 11)).foregroundStyle(online ? Palette.accent : .orange)
                                }
                                if store.isCloud {
                                    HStack {
                                        Text(store.backupStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Back up now") { Task { await store.backUpNow() } }
                                    }
                                } else {
                                    Text("Backup updates are paused. Reminders already sent to AWS may still arrive.").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("This Workmate folder has no AWS connection yet. Its private connection is stored in config.json — no email, password or Workmate account is needed.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Button("Show configuration folder") { store.showFiles() }
                            }
                        }.padding(.top, 12)
                    } label: { settingsLabel("AWS backup", subtitle: store.isCloud ? "Connected" : "Not connected") }
                    .id("backup")
                    Divider()
                    DisclosureGroup(isExpanded: $telegramOpen) {
                        VStack(alignment: .leading, spacing: 14) {
                            if store.isCloud {
                                Text("1. Open @BotFather and send /newbot.\n2. Paste the bot token below.\n3. Connect, open the link and tap Start.").font(.system(size: 12)).foregroundStyle(.secondary)
                                Link("Open BotFather", destination: URL(string: "https://t.me/BotFather")!).font(.system(size: 12))
                                SecureField("Bot token", text: $token).modernTextField(autofocus: telegramOpen).accessibilityLabel("Bot token")
                                HStack {
                                    Button(working ? "Connecting…" : "Connect bot") {
                                        working = true
                                        Task {
                                            do { store.telegram = try await store.api.connectTelegram(token.trimmingCharacters(in: .whitespacesAndNewlines)); token = "" }
                                            catch { store.error = error.localizedDescription }
                                            working = false
                                        }
                                    }.disabled(token.isEmpty || working)
                                    Button("Refresh status") { Task { await store.refreshTelegram() } }
                                }
                                if let link = store.telegram.link, let url = URL(string: link) { Link("Open Telegram & tap Start", destination: url) }
                                if store.telegram.connected { Button("Disconnect…") { disconnecting = true }.font(.system(size: 11)) }
                                if let error = store.telegram.lastError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
                            } else {
                                Text("Enable AWS backup to connect Telegram. It shares your reminders with the Raspberry Pi; no separate sign-in is needed.").font(.system(size: 12)).foregroundStyle(.secondary)
                                Button("Show AWS backup") { withAnimation { cloudOpen = true; proxy.scrollTo("backup", anchor: .top) } }
                            }
                        }.padding(.top, 16)
                    } label: { settingsLabel("Telegram", subtitle: store.telegram.connected ? "Connected" : store.telegram.configured ? "Finish linking" : "Not connected") }
                    Divider()
                    DisclosureGroup(isExpanded: $briefOpen) {
                        VStack(alignment: .leading, spacing: 17) {
                            Text("Include priorities").font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(Priority.allCases) { p in
                                    let included = store.workspace.settings.digestPriorities.contains(p)
                                    Button {
                                        if included && store.workspace.settings.digestPriorities.count == 1 { return }
                                        store.change { w in
                                            if included { w.settings.digestPriorities.removeAll { $0 == p } }
                                            else { w.settings.digestPriorities.append(p) }
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: included ? "checkmark.circle.fill" : "circle").font(.system(size: 10))
                                            Text(p.title)
                                        }.font(.system(size: 11)).foregroundStyle(included ? p.tint : Color.secondary)
                                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                                            .background(included ? p.tint.opacity(0.08) : .clear, in: Capsule())
                                            .overlay { Capsule().stroke(included ? p.tint.opacity(0.5) : Palette.line) }
                                    }.buttonStyle(.plain).accessibilityLabel("Include \(p.title)").accessibilityValue(included ? "Included" : "Excluded")
                                }
                            }
                            Text("\(store.workspace.briefTasks.count) open actions · urgent first").font(.system(size: 11)).foregroundStyle(.secondary)
                            Toggle("Send each morning", isOn: Binding(get: { store.workspace.settings.digestEnabled }, set: { v in store.change { $0.settings.digestEnabled = v } }))
                                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                            if store.workspace.settings.digestEnabled {
                                DatePicker("Send at", selection: time, displayedComponents: [.hourAndMinute]).datePickerStyle(.stepperField).font(.system(size: 12))
                                HStack {
                                    Text("Timezone").font(.system(size: 12))
                                    Spacer()
                                    TextField("Europe/Stockholm", text: $timezone).modernTextField().frame(width: 200)
                                        .onSubmit(saveTimezone)
                                        .onDisappear(perform: saveTimezone)
                                }
                                if !store.telegram.connected { Text("Connect Telegram to receive the morning brief.").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                            HStack {
                                Button("Preview") { showPreview.toggle() }
                                Spacer()
                                Button("Send now") { Task { await store.sendBrief() } }.modernButtonStyle(prominent: true).disabled(!store.telegram.connected)
                            }
                            if showPreview {
                                Text(store.workspace.brief).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(13).background(Palette.panel, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }.padding(.top, 16)
                    } label: { settingsLabel("Daily brief", subtitle: store.workspace.settings.digestEnabled ? store.workspace.settings.digestTime : "On demand") }
                    Divider()
                    HStack {
                        Label("Mac notifications", systemImage: "desktopcomputer").font(.system(size: 13))
                        Spacer()
                        Text("Always included").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("Every reminder includes a Mac notification. Add Telegram individually from an action’s reminder menu.").font(.system(size: 11)).foregroundStyle(.secondary)
                    if !store.macNotificationsAllowed {
                        Button("Allow notifications in macOS") { Task { await store.enableNotifications() } }
                    }
                    Divider()
                    HStack {
                        Button("Export backup…") { store.exportBackup() }
                        Button("Import backup…") { store.importBackup() }
                        Spacer()
                    }.font(.system(size: 11))
                    Text("Workmate for Mac · Native SwiftUI").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 4)
                }.disclosureGroupStyle(SettingsDisclosureStyle()).padding(.horizontal, 30).padding(.bottom, 30)
            }
            }
        }.tint(Palette.accent).modernButtonStyle()
        .onAppear {
            timezone = store.workspace.settings.timezone
            telegramOpen = store.settingsSection == "telegram"
            if telegramOpen { cloudOpen = false }
            store.settingsSection = ""
            Task { await store.refreshTelegram() }
        }
        .confirmationDialog("Disconnect Telegram?", isPresented: $disconnecting) {
            Button("Disconnect", role: .destructive) { Task { do { try await store.api.disconnectTelegram(); await store.refreshTelegram() } catch { store.error = error.localizedDescription } } }
        }
    }
    private func settingsLabel(_ title: String, subtitle: String) -> some View {
        HStack { Text(title).font(.system(size: 13)); Spacer(); Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
    private func saveTimezone() {
        guard !timezone.isEmpty else { return }
        guard TimeZone(identifier: timezone) != nil else { timezone = store.workspace.settings.timezone; store.error = "Choose a timezone such as Europe/Stockholm."; return }
        if timezone != store.workspace.settings.timezone { store.change { $0.settings.timezone = timezone } }
    }
}

private struct SettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0)).foregroundStyle(.secondary)
                    configuration.label
                }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
