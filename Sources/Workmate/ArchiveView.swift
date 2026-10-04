import SwiftUI
import WorkmateCore

struct ArchiveView: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tasks = store.workspace.archivedTasks
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Archive", systemImage: "archivebox").font(.system(size: 15, weight: .semibold))
                Spacer()
                PopoverCloseButton { dismiss() }
            }
            Text("Completed tasks live here. Uncheck one to restore it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            if tasks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "archivebox").font(.system(size: 28, weight: .light))
                    Text("No archived tasks yet").font(.system(size: 13))
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(tasks) { task in TaskRow(task: task) }
                    }
                }
            }
        }.padding(24).frame(width: 440, height: 420).popoverSurface()
    }
}
