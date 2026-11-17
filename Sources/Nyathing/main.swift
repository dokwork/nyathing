import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button,
           let image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Nyathing") {
            image.isTemplate = true
            button.image = image
        }
        statusItem = item
    }
}
