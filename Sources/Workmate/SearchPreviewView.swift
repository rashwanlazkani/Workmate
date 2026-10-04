import SwiftUI
import AppKit
import WorkmateCore

struct SearchPreviewView: View {
    let note: Note
    let query: String
    var meetings: [Meeting] = []
    var body: some View {
        let preview = NoteSearchPreview(note: note, query: query, meetings: meetings)
        VStack(alignment: .leading, spacing: 4) {
            if let section = preview.section, note.contentSections.count > 1 {
                Text(section).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !preview.text.isEmpty {
                Text(highlighted(preview)).font(.system(size: 12)).lineSpacing(3).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func highlighted(_ preview: NoteSearchPreview) -> AttributedString {
        let text = NSMutableAttributedString(string: preview.text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        for range in preview.highlights {
            text.addAttributes([.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor(Palette.accent), .backgroundColor: NSColor(Palette.accent).withAlphaComponent(0.12)], range: range)
        }
        return AttributedString(text)
    }
}
