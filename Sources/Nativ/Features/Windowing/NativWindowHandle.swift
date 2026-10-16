import AppKit

@MainActor
protocol NativWindowHandle: AnyObject {
    var appKitWindow: NSWindow? { get }
    func activate()
}

extension NSWindow: NativWindowHandle {
    var appKitWindow: NSWindow? {
        self
    }

    func activate() {
        makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}
