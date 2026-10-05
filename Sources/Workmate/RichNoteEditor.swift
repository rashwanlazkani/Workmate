import AppKit
import SwiftUI
import WorkmateCore

@MainActor final class NoteEditorController: ObservableObject {
    weak var editor: RichNoteTextView?
    @Published var contentHeight: CGFloat = 180
    @Published var selectionStyle = NoteFormatting.SelectionStyle()
    func refreshSelectionStyle() {
        guard let editor else { return }
        hasSelection = editor.selectedRange().length > 0
        let next = NoteFormatting.selectionStyle(editor.attributedString(), selection: editor.selectedRange(), typingAttributes: editor.typingAttributes)
        if selectionStyle != next { selectionStyle = next }
    }
    @Published var aiShown = false
    @Published var hasSelection = false
    var aiOriginal = ""
    private var aiRange = NSRange(location: 0, length: 0)
    private var aiSnapshot = NSAttributedString(string: "")
    func beginAI() {
        guard let editor else { return }
        aiRange = editor.selectedRange()
        guard aiRange.length > 0, NSMaxRange(aiRange) <= editor.attributedString().length else { return }
        aiSnapshot = NSAttributedString(attributedString: editor.attributedString())
        aiOriginal = (editor.string as NSString).substring(with: aiRange)
        aiShown = true
    }
    func applyAI(_ text: String) -> Bool {
        guard let editor, editor.attributedString().isEqual(to: aiSnapshot) else { return false }
        let next = NSMutableAttributedString(attributedString: aiSnapshot)
        let replacement = AIFormattedText.render(text)
        next.replaceCharacters(in: aiRange, with: replacement)
        guard next.string.count <= 60000 else { return false }
        apply(next, selection: NSRange(location: aiRange.location, length: replacement.length), name: "AI edit")
        return true
    }
    @Published var markdownShown = false
    var markdownOriginal = ""
    private var markdownSnapshot = NSAttributedString(string: "")
    func beginMarkdown(_ source: String) {
        guard let editor else { return }
        markdownSnapshot = NSAttributedString(attributedString: editor.attributedString())
        markdownOriginal = source
        markdownShown = true
    }
    func applyMarkdown(_ source: String, validate: (NSAttributedString) -> Bool) -> Bool {
        guard let editor, editor.attributedString().isEqual(to: markdownSnapshot),
              let next = try? NoteMarkdown.render(source), validate(next) else { return false }
        apply(next, selection: NSRange(location: 0, length: 0), name: "Markdown")
        editor.typingAttributes = NoteFormatting.attributes
        return true
    }
    func pasteMarkdown(validate: (NSAttributedString) -> Bool) {
        guard let editor, let source = NSPasteboard.general.string(forType: .string),
              let rendered = try? NoteMarkdown.render(source) else { NSSound.beep(); return }
        let next = NSMutableAttributedString(attributedString: editor.attributedString())
        let range = editor.selectedRange()
        next.replaceCharacters(in: range, with: rendered)
        guard next.string.count <= 60000, validate(next) else { NSSound.beep(); return }
        apply(next, selection: NSRange(location: range.location + rendered.length, length: 0), name: "Paste Markdown")
        editor.typingAttributes = NoteFormatting.attributes
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
            let current = editor.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 17)
            editor.typingAttributes[.font] = fonts.traits(of: current).contains(trait) ? fonts.convert(current, toNotHaveTrait: trait) : fonts.convert(current, toHaveTrait: trait)
            refreshSelectionStyle()
            return
        }
        let next = NSMutableAttributedString(attributedString: editor.attributedString())
        var allHaveTrait = true
        next.enumerateAttribute(.font, in: selected) { value, _, _ in
            if !fonts.traits(of: value as? NSFont ?? .systemFont(ofSize: 17)).contains(trait) { allHaveTrait = false }
        }
        next.enumerateAttribute(.font, in: selected) { value, range, _ in
            let font = value as? NSFont ?? .systemFont(ofSize: 17)
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
        let indentation = (String(line.prefix { $0 == " " || $0 == "\t" }) as NSString).length
        let content = (line as NSString).substring(from: indentation)
        guard content.hasPrefix("☐ ") || content.hasPrefix("☑ ") else { return }
        let next = NSMutableAttributedString(attributedString: editor.attributedString())
        next.replaceCharacters(in: NSRange(location: paragraph.location + indentation, length: 1), with: content.hasPrefix("☐") ? "☑" : "☐")
        apply(next, selection: editor.selectedRange(), name: "Checklist")
    }
}

struct NoteFormattingToolbar: View {
    @ObservedObject var controller: NoteEditorController
    var editMarkdown: () -> Void
    var body: some View {
        HStack(spacing: 3) {
            formatButton("Bold · ⌘B", icon: "bold", active: controller.selectionStyle.bold) { controller.toggleFont(.boldFontMask) }
            formatButton("Italic · ⌘I", icon: "italic", active: controller.selectionStyle.italic) { controller.toggleFont(.italicFontMask) }
            Rectangle().fill(Palette.line).frame(width: 1, height: 20).padding(.horizontal, 2)
            formatButton("Bulleted list", icon: "list.bullet", active: controller.selectionStyle.list == .bullet) { controller.list(.bullet) }
            formatButton("Numbered list", icon: "list.number", active: controller.selectionStyle.list == .numbered) { controller.list(.numbered) }
            formatButton("Checklist", icon: "checklist", active: controller.selectionStyle.list == .checklist) { controller.list(.checklist) }
            Rectangle().fill(Palette.line).frame(width: 1, height: 20).padding(.horizontal, 2)
            formatButton("Add link · ⌘K", icon: "link", active: controller.selectionStyle.linked) { controller.beginLink() }
                .popover(isPresented: $controller.linkShown, arrowEdge: .bottom) { NoteLinkPopover(controller: controller) }
            formatControl("Edit Markdown", active: controller.markdownShown, action: editMarkdown) {
                Text("M↓")
            }
            formatButton("AI · Improve selected text", icon: "sparkles", active: controller.aiShown) { controller.beginAI() }
                .disabled(!controller.hasSelection)
                .popover(isPresented: $controller.aiShown, arrowEdge: .bottom) {
                    AIEditSheet(original: controller.aiOriginal, apply: controller.applyAI)
                }
            Spacer(minLength: 0)
        }.padding(.bottom, 12)
    }
    private func formatButton(_ label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        formatControl(label, active: active, action: action) { Image(systemName: icon) }
    }
    private func formatControl<Icon: View>(_ label: String, active: Bool, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon().font(.system(size: 18, weight: .medium)).symbolRenderingMode(.monochrome)
                .frame(width: 34, height: 36).contentShape(RoundedRectangle(cornerRadius: 6))
        }
            .buttonStyle(FullHitButtonStyle())
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
    var makeAction: ((String) -> Void)?
    private lazy var selectionButton: NSButton = {
        let button = NSButton(title: "↗ Make action", target: self, action: #selector(makeSelectedAction))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        button.layer?.backgroundColor = NSColor(Palette.background).cgColor
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = NSColor(Palette.accent)
        button.refusesFirstResponder = true
        button.setAccessibilityLabel("Make action from selection")
        button.toolTip = "Create a task from the highlighted text"
        button.isHidden = true
        button.setAccessibilityHidden(true)
        return button
    }()
    private lazy var selectionAIButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI tools")!, target: self, action: #selector(improveSelectedText))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        button.layer?.backgroundColor = NSColor(Palette.background).cgColor
        button.contentTintColor = NSColor(Palette.accent)
        button.refusesFirstResponder = true
        button.setAccessibilityLabel("AI tools for selection")
        button.toolTip = "Improve the highlighted text with AI"
        button.isHidden = true
        button.setAccessibilityHidden(true)
        return button
    }()
    @objc private func improveSelectedText() {
        controller?.beginAI()
        hideSelectionButton()
    }
    private var scrollObserver: NSObjectProtocol?
    private var selectionClickMonitor: Any?
    private func hideSelectionButton() {
        selectionAIButton.isHidden = true
        selectionAIButton.setAccessibilityHidden(true)
        selectionButton.isHidden = true
        selectionButton.setAccessibilityHidden(true)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver); self.scrollObserver = nil }
        if let selectionClickMonitor { NSEvent.removeMonitor(selectionClickMonitor); self.selectionClickMonitor = nil }
        selectionButton.removeFromSuperview()
        selectionAIButton.removeFromSuperview()
        guard let window else { return }
        window.contentView?.addSubview(selectionButton)
        window.contentView?.addSubview(selectionAIButton)
        // NSHostingView handles its own hit testing; route the floating native overlay first.
        selectionClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, !self.selectionButton.isHidden else { return event }
            if self.selectionAIButton.bounds.contains(self.selectionAIButton.convert(event.locationInWindow, from: nil)) {
                self.improveSelectedText(); return nil
            }
            if self.selectionButton.bounds.contains(self.selectionButton.convert(event.locationInWindow, from: nil)) {
                self.makeSelectedAction(); return nil
            }
            return event
        }
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSelectionButton() }
        }
    }
    deinit {
        if let selectionClickMonitor { NSEvent.removeMonitor(selectionClickMonitor) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }
    @objc private func makeSelectedAction() {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        let text = (string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        makeAction?(text)
        setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        hideSelectionButton()
    }
    func updateSelectionButton() {
        let range = selectedRange(), ns = string as NSString
        guard makeAction != nil, window?.firstResponder === self, range.length > 0,
              NSMaxRange(range) <= ns.length,
              !ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let layoutManager, let textContainer else { hideSelectionButton(); return }
        layoutManager.ensureLayout(for: textContainer)
        var last = NSMaxRange(range) - 1
        while last > range.location && CharacterSet.newlines.contains(UnicodeScalar(ns.character(at: last)) ?? " ") { last -= 1 }
        let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: last, length: 1), actualCharacterRange: nil)
        var anchor = layoutManager.boundingRect(forGlyphRange: glyph, in: textContainer)
        anchor.origin.x += textContainerOrigin.x; anchor.origin.y += textContainerOrigin.y
        guard visibleRect.intersects(anchor), let container = window?.contentView else { hideSelectionButton(); return }
        let target = convert(anchor, to: container)
        let width: CGFloat = 122, height: CGFloat = 28
        let x = min(max(4, target.maxX - 10), max(4, container.bounds.width - width - 38 - 4))
        let y = container.isFlipped ? target.minY - height - 6 : target.maxY + 6
        selectionButton.frame = NSRect(x: x, y: max(4, min(y, container.bounds.height - height - 4)), width: width, height: height)
        selectionAIButton.frame = NSRect(x: x + width + 6, y: selectionButton.frame.minY, width: 32, height: height)
        selectionAIButton.isHidden = false
        selectionAIButton.setAccessibilityHidden(false)
        selectionButton.isHidden = false
        selectionButton.setAccessibilityHidden(false)
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { hideSelectionButton() }
        return result
    }
    override func layout() {
        super.layout()
        updateContentHeight()
        updateSelectionButton()
    }
    func updateContentHeight() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2 + 24)
        guard let controller, abs(controller.contentHeight - height) > 1 else { return }
        DispatchQueue.main.async { [weak controller] in
            if let controller, abs(controller.contentHeight - height) > 1 { controller.contentHeight = height }
        }
    }
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
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let content = String(line.dropFirst(indentation.count))
        let prefix = NoteFormatting.listPrefix(content)
        guard !prefix.isEmpty else { super.insertNewline(sender); return }
        if content == prefix {
            insertText("", replacementRange: NSRange(location: paragraph.location, length: ((indentation + prefix) as NSString).length))
            return
        }
        let next = prefix.first?.isNumber == true ? "\((Int(prefix.dropLast(2)) ?? 0) + 1). " : prefix.hasPrefix("•") ? "• " : "☐ "
        insertText("\n" + indentation + next, replacementRange: selection)
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
                if ns.substring(with: NSRange(location: paragraph.location, length: index - paragraph.location)).trimmingCharacters(in: .whitespaces).isEmpty, bounds.insetBy(dx: -3, dy: -2).contains(point), ["☐", "☑"].contains(ns.substring(with: NSRange(location: index, length: 1))) {
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
    var onMakeAction: ((String) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = RichNoteTextView()
        editor.isRichText = true; editor.importsGraphics = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 17); editor.textColor = .white
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
        editor.makeAction = onMakeAction
        editor.delegate = context.coordinator; editor.controller = controller; controller.editor = editor
        context.coordinator.lastRichText = richText
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? RichNoteTextView else { return }
        controller.editor = editor
        editor.makeAction = onMakeAction
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
            let readable = NoteFormatting.readable(editor.attributedString())
            readable.enumerateAttribute(.font, in: NSRange(location: 0, length: readable.length)) { value, range, _ in
                if let value { editor.textStorage?.addAttribute(.font, value: value, range: range) }
            }
            let encoded = NoteFormatting.encode(editor.attributedString())
            lastRichText = encoded
            (editor as? RichNoteTextView)?.updateContentHeight()
            parent.onChange(editor.string, encoded)
            parent.controller.refreshSelectionStyle()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let editor = notification.object as? NSTextView else { return }
            parent.controller.refreshSelectionStyle()
            (editor as? RichNoteTextView)?.updateSelectionButton()
            let range = editor.selectedRange()
            if NSMaxRange(range) <= (editor.string as NSString).length { parent.selectedText = (editor.string as NSString).substring(with: range) }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = NoteFormatting.safeLink(String(describing: link)) { NSWorkspace.shared.open(url) }
            return true
        }
    }
}
