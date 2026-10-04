import SwiftUI
import AppKit
import WorkmateCore

struct WorkspaceWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var body: some View {
        WindowRegistration(controller: delegate.workspaceWindow)
            .onAppear {
                let open = openWindow
                delegate.workspaceWindow.openWindow = { open(id: "workspace") }
            }
            .allowsHitTesting(false)
    }
}

private struct WindowRegistration: NSViewRepresentable {
    let controller: WorkspaceWindowController
    func makeNSView(context: Context) -> WindowObserver {
        let view = WindowObserver()
        view.controller = controller
        return view
    }
    func updateNSView(_ view: WindowObserver, context: Context) {
        if let window = view.window { controller.register(window) }
    }
    final class WindowObserver: NSView {
        weak var controller: WorkspaceWindowController?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.backgroundColor = NSColor(Palette.background)
                controller?.register(window)
            }
        }
    }
}
