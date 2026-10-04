import SwiftUI
import WorkmateCore

struct TaskTagEditor: View {
    @Binding var tags: [String]
    @Binding var draft: String
    let meetings: [Meeting]
    let existing: [String]
    private var meetingNames: [String] { TaskTags.unique(meetings.filter { !$0.canceled }.map(\.title)) }
    private var suggestions: [String] {
        let query = TaskTags.normalize(draft)
        return Array(TaskTags.unique(meetingNames + existing).filter {
            !tags.contains($0) && (query.isEmpty || $0.localizedStandardContains(query))
        }.prefix(4))
    }
    private var canAdd: Bool { !TaskTags.normalize(draft).isEmpty && tags.count < 20 }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tags").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if tags.count >= 20 { Text("20-tag limit").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if !tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 7) {
                                Text("#" + tag).lineLimit(1)
                                Button { tags.removeAll { $0 == tag } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                                    .buttonStyle(.plain).accessibilityLabel("Remove tag " + tag)
                            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Palette.accent.opacity(0.10), in: Capsule())
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            HStack(spacing: 8) {
                TextField("Add a tag or meeting…", text: Binding(get: { draft }, set: { draft = String($0.lowercased().prefix(200)) }))
                    .modernTextField().accessibilityLabel("Add a tag or meeting").onSubmit(addDraft)
                Button(action: addDraft) { Image(systemName: "plus").frame(width: 15, height: 15) }
                    .modernButtonStyle(shape: .circle).accessibilityLabel("Add tag").disabled(!canAdd)
            }
            if tags.count < 20 && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { name in
                        Button { add(name) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: meetingNames.contains(name) ? "calendar" : "tag").foregroundStyle(.secondary).frame(width: 16)
                                Text(name).lineLimit(1)
                                Spacer()
                                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(Palette.accent)
                            }.font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Add tag " + name)
                    }
                }.background(Palette.field, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func add(_ value: String) {
        tags = Array(TaskTags.unique(tags + [value]).prefix(20)); draft = ""
    }
    private func addDraft() {
        guard canAdd else { return }
        tags = Array(TaskTags.unique(tags + draft.split(separator: ",").map(String.init)).prefix(20)); draft = ""
    }
}
