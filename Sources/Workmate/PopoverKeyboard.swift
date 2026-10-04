import AppKit
import SwiftUI

/// SwiftUI's persistent popovers can leave keyboard focus in their parent window.
/// Route Escape to the most recently opened visible popup, regardless of first responder.
@MainActor private final class PopoverKeyboardRouter {
    static let shared = PopoverKeyboardRouter()
    private struct Entry {
        let id: UUID
        weak var view: NSView?
        var dismiss: () -> Void
    }
    private var entries: [Entry] = []
    private var monitor: Any?
    func register(_ view: PopupKeyboardView) {
        if let index = entries.firstIndex(where: { $0.id == view.id }) {
            entries[index].dismiss = view.dismiss
        } else {
            entries.append(Entry(id: view.id, view: view, dismiss: view.dismiss))
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }
    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id || $0.view == nil }
        if entries.isEmpty, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    private func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53,
              NSApp.modalWindow == nil, NSApp.keyWindow?.isSheet != true,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let popup = entries.last(where: { $0.view?.window?.isVisible == true }) else { return false }
        popup.dismiss()
        return true
    }
}

@MainActor private final class PopupKeyboardView: NSView {
    let id = UUID()
    var dismiss: () -> Void = {}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { PopoverKeyboardRouter.shared.remove(id) }
        else { PopoverKeyboardRouter.shared.register(self) }
    }
}

struct PopoverKeyboard: NSViewRepresentable {
    @Environment(\.dismiss) private var dismiss
    func makeNSView(context: Context) -> NSView {
        let view = PopupKeyboardView()
        view.dismiss = { dismiss() }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PopupKeyboardView else { return }
        view.dismiss = { dismiss() }
        if view.window != nil { PopoverKeyboardRouter.shared.register(view) }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        if let view = nsView as? PopupKeyboardView { PopoverKeyboardRouter.shared.remove(view.id) }
    }
}
