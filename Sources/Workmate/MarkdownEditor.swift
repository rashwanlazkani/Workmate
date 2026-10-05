import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkmateCore

struct MarkdownEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> var source: String
    var apply: (String) -> Bool
    @ViewState<Bool> private var preview = false
    @ViewState<String?> private var error: String?
    @FocusState private var sourceFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Edit Markdown", systemImage: "text.badge.star").font(.system(size: 20, weight: .semibold))
                Spacer()
                PopoverCloseButton { dismiss() }
            }
            HStack(spacing: 6) {
                Button("Markdown") { preview = false }.modernButtonStyle(prominent: !preview)
                Button("Preview") { preview = true }.modernButtonStyle(prominent: preview)
                Spacer()
                Text("\(source.count.formatted()) / 60,000").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if preview {
                    if let text = try? NoteMarkdown.render(source) { MarkdownPreview(text: text) }
                    else { Text("This section is too large to preview.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                } else {
                    TextEditor(text: $source).font(.system(size: 14, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(10).focused($sourceFocused)
                        .accessibilityLabel("Markdown source")
                }
            }
            .frame(minHeight: 300, maxHeight: .infinity)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
            Text(verbatim: "# Heading · **bold** · *italic* · - list · - [ ] task · [text](url)\nImages appear as labels and URLs. HTML is shown as text.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.modernButtonStyle()
                Button("Apply Markdown") {
                    if apply(source) { dismiss() }
                    else { error = "The note changed or is too large. Close this editor and try again; your Markdown is still here to copy." }
                }.modernButtonStyle(prominent: true).disabled(source.count > 60000)
            }
        }
        .padding(24).frame(width: 650, height: 570).background(Palette.background)
        .onAppear { sourceFocused = true }.onExitCommand { dismiss() }
    }
}

private struct MarkdownPreview: NSViewRepresentable {
    var text: NSAttributedString
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Markdown preview")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSTextView)?.textStorage?.setAttributedString(text)
    }
}

extension WorkspaceStore {
    func importMarkdown() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Import Markdown as a new note."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 240000 else { throw NoteMarkdown.Failure.tooLarge }
            let source = try String(contentsOf: url, encoding: .utf8)
            var section = try NoteMarkdown.section(source)
            section.meetingIds = meetingFocusID.map { [$0] } ?? []
            var note = Note(title: String(url.deletingPathExtension().lastPathComponent.prefix(200)))
            note.setSections([section])
            change { $0.notes.append(note) }
            openNote(note.id)
        } catch { self.error = error.localizedDescription }
    }
    func exportMarkdown(_ note: Note) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = String(note.displayTitle.map { "/:".contains($0) ? "-" : $0 }) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try NoteMarkdown.export(note).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}
