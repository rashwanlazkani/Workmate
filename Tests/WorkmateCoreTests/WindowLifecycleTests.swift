import AppKit
import Testing
@testable import WorkmateCore

@MainActor @Suite(.serialized)
struct WindowLifecycleTests {
    @Test func dockReopenCreatesWorkspaceAfterCloseAndReusesItWhileOpen() {
        _ = NSApplication.shared
        var activations = 0
        let controller = WorkspaceWindowController(activate: { activations += 1 })
        var created: [HiddenTestWindow] = []
        controller.openWindow = {
            let window = HiddenTestWindow()
            created.append(window)
            controller.register(window)
        }
        controller.show()
        #expect(created.count == 1)
        controller.show()
        #expect(created.count == 1)
        #expect(created[0].presentations == 1)

        // Close a real AppKit window, retaining it as SwiftUI may do during teardown.
        created[0].close()
        controller.show()
        #expect(created.count == 2)
        #expect(created[0].presentations == 1)
        controller.show()
        #expect(created.count == 2)
        #expect(created[1].presentations == 1)
        #expect(activations == 4)
        created[1].close()
        controller.openWindow = nil
    }

    @Test func closingAnOldWindowDoesNotForgetTheCurrentWorkspace() {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(activate: {})
        let old = HiddenTestWindow(), current = HiddenTestWindow()
        controller.register(old)
        controller.register(current)
        old.close()
        var reopened = false
        controller.openWindow = { reopened = true }
        controller.show()
        #expect(!reopened)
        #expect(current.presentations == 1)
        current.close()
    }
}

@MainActor private final class HiddenTestWindow: NSWindow {
    var presentations = 0
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }
    // These tests never display or activate a window on the user's desktop.
    override func makeKeyAndOrderFront(_ sender: Any?) { presentations += 1 }
}
