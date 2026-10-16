import AppKit

@MainActor
final class NativWindowReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowChange()
    }

    func reportWindowChange() {
        onWindowChange?(window)
    }
}
