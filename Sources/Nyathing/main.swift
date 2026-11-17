import AppKit
import Foundation

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainStatusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var mainFrames: [NSImage] = []
    private var mainFrameIndex = 0
    private var activeAnimations: [String: ActiveAnimation] = [:]
    private var activities: [UUID: String] = [:]
    private var activityDeadlines: [UUID: UInt64] = [:]
    private var activityTimeout: TimeInterval = 5
    private var apiServer: LocalAPIServer?
    private var apiGeneration = 0
    private var disconnectedCount = 0
    private var warningFrames: [NSImage] = []
    private var warningFrameIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainStatusItem = item
        configureMenu(for: item)
        reloadConfigurationAndAnimations()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.advanceAnimations()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
        apiGeneration += 1
        apiServer?.stop()
        activeAnimations.values.forEach { NSStatusBar.system.removeStatusItem($0.statusItem) }
    }

    private func configureMenu(for item: NSStatusItem) {
        let menu = NSMenu()
        menu.addItem(withTitle: "About Nyathing", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset Disconnected Count", action: #selector(resetDisconnectedCount), keyEquivalent: "")
        menu.addItem(withTitle: "Reload Configuration and Animations", action: #selector(reloadFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Open Configuration", action: #selector(openConfiguration), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nyathing", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Nyathing"])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func resetDisconnectedCount() {
        disconnectedCount = 0
        warningFrames = []
        warningFrameIndex = 0
        updateMainStatusItem()
    }

    @objc private func reloadFromMenu() {
        reloadConfigurationAndAnimations()
    }

    @objc private func openConfiguration() {
        let url = AppConfiguration.configurationDirectory.appendingPathComponent("config.toml")
        guard NSWorkspace.shared.open(url) else {
            NSLog("Unable to open configuration at %@", url.path)
            return
        }
    }

    private func reloadConfigurationAndAnimations() {
        apiGeneration += 1
        apiServer?.stop()
        apiServer = nil
        clearRuntimeState()
        do {
            let configuration = try AppConfiguration.load()
            activityTimeout = configuration.activityTimeout
            let directory = AppConfiguration.configurationDirectory.appendingPathComponent("animations", isDirectory: true)
            let animations = SpriteAnimation.loadAll(in: directory)
            guard let selected = animations[configuration.defaultAnimation] else {
                throw AnimationError.invalidFilename(configuration.defaultAnimation)
            }
            mainFrames = selected.frames
            try startAPIServer()
        } catch {
            NSLog("Unable to load configuration or start local API: %@", error.localizedDescription)
            mainFrames = Self.builtInGhostFrames()
        }
        mainFrameIndex = 0
        updateMainStatusItem()
    }

    private func startAPIServer() throws {
        let generation = apiGeneration
        apiServer = LocalAPIServer(
            onStart: { [weak self] filename in
                try DispatchQueue.main.sync {
                    guard let self, self.apiGeneration == generation else { throw LocalAPIError.unavailable }
                    return self.startActivity(animation: filename).uuidString
                }
            },
            onKeepalive: { [weak self] activityID in
                try DispatchQueue.main.sync {
                    guard let self, self.apiGeneration == generation,
                          let id = UUID(uuidString: activityID), self.keepaliveActivity(id) else {
                        throw LocalAPIError.unknownActivity
                    }
                }
            },
            onStop: { [weak self] activityID in
                try DispatchQueue.main.sync {
                    guard let self, self.apiGeneration == generation,
                          let id = UUID(uuidString: activityID), self.activities[id] != nil else {
                        throw LocalAPIError.unknownActivity
                    }
                    self.stopActivity(id)
                }
            }
        )
        try apiServer?.start()
    }

    private func clearRuntimeState() {
        for active in activeAnimations.values {
            NSStatusBar.system.removeStatusItem(active.statusItem)
        }
        activeAnimations.removeAll()
        activities.removeAll()
        activityDeadlines.removeAll()
        disconnectedCount = 0
        warningFrames = []
        warningFrameIndex = 0
        mainFrameIndex = 0
    }

    /// Begins an activity for a named animation, sharing its status item with matching activities.
    @discardableResult
    func startActivity(animation filename: String) -> UUID {
        let id = UUID()
        activities[id] = filename
        scheduleActivityExpiration(id)
        if let active = activeAnimations[filename] {
            active.activityIDs.insert(id)
            updateActivityStatus(active)
            return id
        }

        let directory = AppConfiguration.configurationDirectory.appendingPathComponent("animations", isDirectory: true)
        let animation = SpriteAnimation.loadAll(in: directory)[filename]
        let frames = animation?.frames ?? Self.builtInGhostFrames()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let active = ActiveAnimation(statusItem: statusItem, frames: frames, activityIDs: [id])
        activeAnimations[filename] = active
        updateActivityStatus(active)
        return id
    }

    /// Ends an activity without counting it as a disconnect.
    func stopActivity(_ id: UUID) {
        guard let filename = activities.removeValue(forKey: id),
              let active = activeAnimations[filename] else { return }
        activityDeadlines.removeValue(forKey: id)
        active.activityIDs.remove(id)
        if active.activityIDs.isEmpty {
            NSStatusBar.system.removeStatusItem(active.statusItem)
            activeAnimations.removeValue(forKey: filename)
        } else {
            updateActivityStatus(active)
        }
    }

    /// Records a timed-out activity and displays its explosion effect when available.
    func recordActivityTimeout() {
        disconnectedCount += 1
        let directory = AppConfiguration.configurationDirectory.appendingPathComponent("animations", isDirectory: true)
        if let explosion = SpriteAnimation.loadAll(in: directory)["explosion_36x36.png"] {
            warningFrames = explosion.frames
            warningFrameIndex = 0
        } else {
            warningFrames = []
            NSLog("Explosion animation explosion_36x36.png is missing or invalid")
        }
        updateMainStatusItem()
    }

    private func updateActivityStatus(_ active: ActiveAnimation) {
        guard let button = active.statusItem.button, !active.frames.isEmpty else { return }
        button.image = active.frames[active.frameIndex]
        button.image?.isTemplate = false
        button.title = active.activityIDs.count > 1 ? "\(active.activityIDs.count)" : ""
        button.image?.accessibilityDescription = "Active Nyathing animation"
    }

    private func keepaliveActivity(_ id: UUID) -> Bool {
        guard activities[id] != nil else { return false }
        scheduleActivityExpiration(id)
        return true
    }

    private func scheduleActivityExpiration(_ id: UUID) {
        let deadline = DispatchTime.now() + activityTimeout
        let deadlineUptime = deadline.uptimeNanoseconds
        activityDeadlines[id] = deadlineUptime
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { [weak self] in
            DispatchQueue.main.async {
                self?.expireActivity(id, deadlineUptime: deadlineUptime)
            }
        }
    }

    private func expireActivity(_ id: UUID, deadlineUptime: UInt64) {
        guard activityDeadlines[id] == deadlineUptime else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= deadlineUptime else {
            let remaining = Double(deadlineUptime - now) / 1_000_000_000
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + remaining) { [weak self] in
                DispatchQueue.main.async {
                    self?.expireActivity(id, deadlineUptime: deadlineUptime)
                }
            }
            return
        }
        stopActivity(id)
        recordActivityTimeout()
    }

    private func advanceAnimations() {
        if !mainFrames.isEmpty { mainFrameIndex = (mainFrameIndex + 1) % mainFrames.count }
        for active in activeAnimations.values {
            active.frameIndex = (active.frameIndex + 1) % active.frames.count
            updateActivityStatus(active)
        }
        if !warningFrames.isEmpty {
            warningFrameIndex += 1
            if warningFrameIndex >= warningFrames.count {
                warningFrames = []
                warningFrameIndex = 0
            }
        }
        updateMainStatusItem()
    }

    private func updateMainStatusItem() {
        guard let button = mainStatusItem?.button else { return }
        if disconnectedCount > 0 {
            button.image = warningFrames.isEmpty
                ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Disconnected clients")
                : warningFrames[warningFrameIndex]
            button.title = "\(disconnectedCount)"
        } else {
            button.image = mainFrames.isEmpty ? nil : mainFrames[mainFrameIndex]
            button.title = ""
        }
        button.image?.isTemplate = false
        button.image?.accessibilityDescription = disconnectedCount > 0 ? "Disconnected clients" : "Nyathing animation"
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

private final class ActiveAnimation {
    let statusItem: NSStatusItem
    let frames: [NSImage]
    var frameIndex = 0
    var activityIDs: Set<UUID>

    init(statusItem: NSStatusItem, frames: [NSImage], activityIDs: Set<UUID>) {
        self.statusItem = statusItem
        self.frames = frames
        self.activityIDs = activityIDs
    }
}
