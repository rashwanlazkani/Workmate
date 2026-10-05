import AppKit
import UniformTypeIdentifiers

extension WorkspaceStore {
    /// Let Calendar handle the full iCalendar format, including recurrence exceptions
    /// and custom time zones. Workmate continues to read the user's chosen calendars.
    func importCalendarFile() {
        let panel = NSOpenPanel()
        panel.title = "Import ICS file"
        panel.message = "Choose an ICS file to import into Mac Calendar. Then select its calendar in Workmate Settings."
        panel.prompt = "Import"
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "ics" else {
            error = "Choose an iCalendar (.ics) file."
            return
        }
        let hasAccess = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                    configuration: configuration
                )
                meetingsShown = false
                settingsSection = "calendars"
                settingsShown = true
            } catch {
                self.error = "Could not open the ICS file in Calendar. \(error.localizedDescription)"
            }
        }
    }
}
