import Cocoa

class SettingsWindowController: NSWindowController, NSWindowDelegate {

    override init(window: NSWindow?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Quitty Settings"
        window.center()
        window.minSize = NSSize(width: 650, height: 540)
        window.maxSize = NSSize(width: 650, height: 540)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        
        super.init(window: window)
        window.delegate = self

        // Set the content view controller
        let settingsVC = SettingsViewController()
        window.contentViewController = settingsVC
        
        // Initial policy
        NSApp.setActivationPolicy(.accessory)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        // More robust activation
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
