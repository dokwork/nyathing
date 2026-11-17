import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var frames: [NSImage] = []
    private var frameIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        do {
            let configuration = try AppConfiguration.load()
            let animationDirectory = AppConfiguration.configurationDirectory
                .appendingPathComponent("animations", isDirectory: true)
            let animations = SpriteAnimation.loadAll(in: animationDirectory)
            guard let selected = animations[configuration.defaultAnimation] else {
                throw AnimationError.invalidFilename(configuration.defaultAnimation)
            }
            frames = selected.frames
        } catch {
            NSLog("Unable to load configuration or default animation: %@", error.localizedDescription)
            frames = Self.builtInGhostFrames()
        }
        showCurrentFrame()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, !self.frames.isEmpty else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.showCurrentFrame()
        }
    }

    private func showCurrentFrame() {
        guard !frames.isEmpty, let button = statusItem?.button else { return }
        button.image = frames[frameIndex]
        button.image?.isTemplate = false
        button.image?.accessibilityDescription = "Nyathing animation"
    }

    private static func builtInGhostFrames() -> [NSImage] {
        (0..<4).map { frame in
            let image = NSImage(size: NSSize(width: 18, height: 18))
            image.lockFocus()
            let body = NSBezierPath(ovalIn: NSRect(x: 2, y: 4 + (frame % 2), width: 14, height: 12))
            NSColor(calibratedRed: 0.88, green: 0.94, blue: 1, alpha: 1).setFill()
            body.fill()
            NSColor(calibratedRed: 0.1, green: 0.15, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 9, width: 2, height: 2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11, y: 9, width: 2, height: 2)).fill()
            image.unlockFocus()
            return image
        }
    }
}
