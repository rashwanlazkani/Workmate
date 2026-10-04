import AppKit
import SwiftUI
import WorkmateCore

@MainActor final class NoteEditorController: ObservableObject {
    weak var editor: RichNoteTextView?
    @Published var selectionStyle = NoteFormatting.SelectionStyle()
    func refreshSelectionStyle() {
        guard let editor else { return }
        let next = NoteFormatting.selectionStyle(editor.attributedString(), selection: editor.selectedRange(), typingAttributes: editor.typingAttributes)
        if selectionStyle != next { selectionStyle = next }
    }
    @Published var linkShown = false
    @Published var linkText = ""
    @Published var linkURL = ""
    private var linkRange = NSRange(location: 0, length: 0)

    func focus() { if let editor { editor.window?.makeFirstResponder(editor) } }
    func toggleFont(_ trait: NSFontTraitMask) {
        guard let editor else { return }
        focus()
        let selected = editor.selectedRange(), fonts = NSFontManager.shared
        if selected.length == 0 {
            let current = editor.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
            editor.typingAttributes[.font] = fonts.traits(of: current).contains(trait) ? fonts.convert(current, toNotHaveTrait: trait) : fonts.convert(current, toHaveTrait: trait)
            refreshSelectionStyle()
            return
        }
        let next = NSMutableAttributedString(attributedString: editor.attributedString())
        var allHaveTrait = true
        next.enumerateAttribute(.font, in: selected) { value, _, _ in
            if !fonts.traits(of: value as? NSFont ?? .systemFont(ofSize: 14)).contains(trait) { allHaveTrait = false }
        }
        next.enumerateAttribute(.font, in: selected) { value, range, _ in
            let font = value as? NSFont ?? .systemFont(ofSize: 14)
            next.addAttribute(.font, value: allHaveTrait ? fonts.convert(font, toNotHaveTrait: trait) : fonts.convert(font, toHaveTrait: trait), range: range)
        }
        apply(next, selection: selected, name: trait == .boldFontMask ? "Bold" : "Italic")
    }
    func list(_ kind: NoteFormatting.ListKind) {
        guard let editor else { return }
        let (next, selected) = NoteFormatting.list(editor.attributedString(), selection: editor.selectedRange(), kind: kind)
        apply(next, selection: selected, name: "List")
    }
    func beginLink() {
        guard let editor else { return }
        linkRange = editor.selectedRange()
        linkText = (editor.string as NSString).substring(with: linkRange)
        linkURL = ""
        if linkRange.location < editor.attributedString().length,
           let value = editor.attributedString().attribute(.link, at: linkRange.location, effectiveRange: nil) {
            linkURL = String(describing: value)
        }
        linkShown = true
    }
    func saveLink() {
        guard let editor, let url = NoteFormatting.safeLink(linkURL) else { return }
        let label = linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.absoluteString : linkText
        guard NSMaxRange(linkRange) <= editor.attributedString().length else { return }
        var attributes = NoteFormatting.attributes
        if linkRange.length > 0 { attributes = editor.attributedString().attributes(at: linkRange.location, effectiveRange: nil) }
        attributes[.link] = url
        let next = NSMutableAttributedString(attributedString: editor.attributedString())
        next.replaceCharacters(in: linkRange, with: NSAttributedString(string: label, attributes: attributes))
        apply(next, selection: NSRange(location: linkRange.location + (label as NSString).length, length: 0), name: "Link")
        editor.typingAttributes = NoteFormatting.attributes
        linkShown = false
    }
    func apply(_ value: NSAttributedString, selection: NSRange, name: String) {
        guard let editor, value.string.count <= 60000 else { NSSound.beep(); return }
        let previous = NSAttributedString(attributedString: editor.attributedString()), previousSelection = editor.selectedRange()
        editor.breakUndoCoalescing()
        editor.undoManager?.registerUndo(withTarget: self) { target in target.apply(previous, selection: previousSelection, name: name) }
        editor.undoManager?.setActionName(name)
        editor.textStorage?.setAttributedString(value)
        editor.setSelectedRange(selection)
        editor.didChangeText()
        refreshSelectionStyle()
        focus()
    }
    func toggleCheck(at index: Int) {
        guard let editor, index < (editor.string as NSString).length else { return }
        let ns = editor.string as NSString, paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
        let line = ns.substring(with: paragraph)
        guard line.hasPrefix("☐ ") || line.hasPrefix("☑ ") else { return }
        let next = NSMutableAttributedString(attributedString: editor.attributedString())
        next.replaceCharacters(in: NSRange(location: paragraph.location, length: 1), with: line.hasPrefix("☐") ? "☑" : "☐")
        apply(next, selection: editor.selectedRange(), name: "Checklist")
    }
}

struct NoteFormattingToolbar: View {
    @ObservedObject var controller: NoteEditorController
    var body: some View {
        HStack(spacing: 3) {
            formatButton("Bold · ⌘B", icon: "bold", active: controller.selectionStyle.bold) { controller.toggleFont(.boldFontMask) }
            formatButton("Italic · ⌘I", icon: "italic", active: controller.selectionStyle.italic) { controller.toggleFont(.italicFontMask) }
            Rectangle().fill(Palette.line).frame(width: 1, height: 15).padding(.horizontal, 4)
            formatButton("Bulleted list", icon: "list.bullet", active: controller.selectionStyle.list == .bullet) { controller.list(.bullet) }
            formatButton("Numbered list", icon: "list.number", active: controller.selectionStyle.list == .numbered) { controller.list(.numbered) }
            formatButton("Checklist", icon: "checklist", active: controller.selectionStyle.list == .checklist) { controller.list(.checklist) }
            Rectangle().fill(Palette.line).frame(width: 1, height: 15).padding(.horizontal, 4)
            formatButton("Add link · ⌘K", icon: "link", active: controller.selectionStyle.linked) { controller.beginLink() }
                .popover(isPresented: $controller.linkShown, arrowEdge: .bottom) { NoteLinkPopover(controller: controller) }
            Spacer(minLength: 0)
        }.padding(.bottom, 12)
    }
    private func formatButton(_ label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 28, height: 27).contentShape(RoundedRectangle(cornerRadius: 6)) }
            .buttonStyle(.plain)
            .foregroundStyle(active ? Palette.accent : Color.secondary)
            .background(active ? Palette.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .help(label).accessibilityLabel(label).accessibilityValue(active ? "Selected" : "Not selected")
    }
}

private struct NoteLinkPopover: View {
    @ObservedObject var controller: NoteEditorController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Add link").font(.system(size: 17, weight: .semibold)); Spacer(); PopoverCloseButton { dismiss() } }
            TextField("https://example.com", text: $controller.linkURL).modernTextField(autofocus: true).accessibilityLabel("Link URL").onSubmit(controller.saveLink)
            TextField("Text to display", text: $controller.linkText).modernTextField().accessibilityLabel("Link text").onSubmit(controller.saveLink)
            HStack { Spacer(); Button("Cancel") { dismiss() }.modernButtonStyle(); Button("Add link") { controller.saveLink() }.modernButtonStyle(prominent: true).disabled(NoteFormatting.safeLink(controller.linkURL) == nil) }
        }.padding(22).frame(width: 340).popoverSurface()
    }
}

@MainActor final class RichNoteTextView: NSTextView {
    weak var controller: NoteEditorController?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection([.command, .option, .control]) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": controller?.toggleFont(.boldFontMask); return true
            case "i": controller?.toggleFont(.italicFontMask); return true
            case "k": controller?.beginLink(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString, selection = selectedRange()
        guard selection.length == 0 else { super.insertNewline(sender); return }
        let paragraph = ns.paragraphRange(for: selection), line = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
        let prefix = NoteFormatting.listPrefix(line)
        guard !prefix.isEmpty else { super.insertNewline(sender); return }
        if line == prefix {
            insertText("", replacementRange: NSRange(location: paragraph.location, length: (prefix as NSString).length))
            return
        }
        let next = prefix.first?.isNumber == true ? "\((Int(prefix.dropLast(2)) ?? 0) + 1). " : prefix.hasPrefix("•") ? "• " : "☐ "
        insertText("\n" + next, replacementRange: selection)
    }
    override func mouseDown(with event: NSEvent) {
        if let layoutManager, let textContainer {
            var point = convert(event.locationInWindow, from: nil)
            point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            if glyph < layoutManager.numberOfGlyphs {
                let index = layoutManager.characterIndexForGlyph(at: glyph), ns = string as NSString
                let paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
                let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                if index == paragraph.location, bounds.insetBy(dx: -3, dy: -2).contains(point), ["☐", "☑"].contains(ns.substring(with: NSRange(location: index, length: 1))) {
                    controller?.toggleCheck(at: index); return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

struct NativeNoteEditor: NSViewRepresentable {
    var text: String
    var richText: String?
    @Binding var selectedText: String
    var controller: NoteEditorController
    var onChange: (String, String?) -> Void
    var onFocus: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = RichNoteTextView()
        editor.isRichText = true; editor.importsGraphics = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14); editor.textColor = .white
        editor.insertionPointColor = NSColor(Palette.accent)
        editor.linkTextAttributes = [.foregroundColor: NSColor(Palette.accent), .underlineStyle: NSUnderlineStyle.single.rawValue]
        editor.textContainerInset = NSSize(width: 0, height: 4); editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = true; editor.allowsUndo = true
        editor.setAccessibilityLabel("Note content")
        editor.textStorage?.setAttributedString(NoteFormatting.decode(body: text, richText: richText))
        editor.typingAttributes = NoteFormatting.attributes
        editor.delegate = context.coordinator; editor.controller = controller; controller.editor = editor
        context.coordinator.lastRichText = richText
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? RichNoteTextView else { return }
        controller.editor = editor
        if editor.string != text || context.coordinator.lastRichText != richText {
            let range = editor.selectedRange()
            context.coordinator.applying = true
            editor.textStorage?.setAttributedString(NoteFormatting.decode(body: text, richText: richText))
            editor.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0))
            context.coordinator.lastRichText = richText
            context.coordinator.applying = false
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeNoteEditor
        var lastRichText: String?
        var applying = false
        init(_ parent: NativeNoteEditor) { self.parent = parent }
        func textDidBeginEditing(_ notification: Notification) { parent.onFocus(); parent.controller.refreshSelectionStyle() }
        func textViewDidChangeTypingAttributes(_ notification: Notification) { parent.controller.refreshSelectionStyle() }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            return (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString).count <= 60000
        }
        func textDidChange(_ notification: Notification) {
            guard !applying, let editor = notification.object as? NSTextView else { return }
            editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: editor.attributedString().length))
            let encoded = NoteFormatting.encode(editor.attributedString())
            lastRichText = encoded
            parent.onChange(editor.string, encoded)
            parent.controller.refreshSelectionStyle()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let editor = notification.object as? NSTextView else { return }
            parent.controller.refreshSelectionStyle()
            let range = editor.selectedRange()
            if NSMaxRange(range) <= (editor.string as NSString).length { parent.selectedText = (editor.string as NSString).substring(with: range) }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = NoteFormatting.safeLink(String(describing: link)) { NSWorkspace.shared.open(url) }
            return true
        }
    }
}
