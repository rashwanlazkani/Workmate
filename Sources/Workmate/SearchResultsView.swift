import SwiftUI
import WorkmateCore

struct SearchResultsView: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var intelligence: IntelligenceController
    @ViewState<String> private var kind = "All"
    @FocusState private var queryFocused: Bool
    var body: some View {
        let matches = store.search(store.filterQuery)
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                Button { store.filterQuery = "" } label: { Label("All notes", systemImage: "chevron.left") }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Include archive", isOn: $store.includeArchive).toggleStyle(.checkbox).font(.system(size: 12))
                Text("\(matches.count) related items").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter your workspace", text: $store.filterQuery).textFieldStyle(.plain).font(.system(size: 27, weight: .medium)).accessibilityLabel("Filter workspace")
                    .focused($queryFocused).focusOnEntry($queryFocused)
                Picker("Show", selection: $kind) { ForEach(["All", "Notes", "Tasks", "Meetings"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).frame(width: 270)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    if (kind == "All" || kind == "Meetings") && !matches.meetings.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionTitle("Meetings")
                            ForEach(matches.meetings) { meeting in
                                Button { store.focusMeeting(meeting.id) } label: {
                                    HStack(spacing: 15) {
                                        Image(systemName: "calendar").foregroundStyle(Palette.accent)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(meeting.title).font(.system(size: 16, weight: .medium))
                                            let date = meeting.occurrences(after: store.clock).first?.start ?? meeting.start
                                            Text(date, format: .dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                                    }.padding(17).background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if (kind == "All" || kind == "Notes") && !matches.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionTitle("Notes")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 18)], alignment: .leading, spacing: 18) {
                                ForEach(matches.notes) { note in
                                    Button {
                                        store.filterQuery = ""; store.meetingFocusID = nil; store.openNote(note.id)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text(note.displayTitle).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                            Text(note.body).font(.system(size: 12)).lineSpacing(5).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                            let linked = store.workspace.meetings.filter { (note.meetingIds ?? []).contains($0.id) }
                                            if !linked.isEmpty { Text(linked.map(\.title).joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(Palette.accent).lineLimit(1) }
                                        }.frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading).padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if (kind == "All" || kind == "Tasks") && !matches.tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("Tasks")
                            ForEach(matches.tasks) { task in TaskRow(task: task).frame(maxWidth: 600, alignment: .leading) }
                        }
                    }
                    if matches.count == 0 { Text("Nothing matches yet. Try a meeting name, a topic, or a phrase from a note.").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 20) }
                }.padding(.bottom, 30)
            }
        }.padding(.horizontal, 38).padding(.bottom, 25)
    }
    private func sectionTitle(_ title: String) -> some View { Text(title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(Palette.muted) }
}
