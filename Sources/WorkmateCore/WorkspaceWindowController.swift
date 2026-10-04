import AppKit

@MainActor public final class WorkspaceWindowController {
    private weak var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private let activate: @MainActor () -> Void
    public var openWindow: (() -> Void)?
    public init(activate: @escaping @MainActor () -> Void = { NSApp?.activate(ignoringOtherApps: true) }) { self.activate = activate }

    public func register(_ window: NSWindow) {
        guard self.window !== window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
    }
    public func show() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
        activate()
    }
    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}
