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
    private var lifecycle = ActivityLifecycle()
    private var activityTimeout: TimeInterval = 5
    private var apiServer: LocalAPIServer?
    private var apiGeneration = 0
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
        lifecycle.resetDisconnectedCount()
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
            NyathingLog.report(NSError(domain: "Nyathing", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "Unable to open configuration at \(url.path)"]),
                               context: "Unable to open configuration")
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
            do {
                try LaunchAgentSupport.configure(enabled: configuration.autoStart,
                                                 in: AppConfiguration.configurationDirectory)
                if configuration.autoStart {
                    NyathingLog.write("Configured Nyathing to launch at the next login")
                }
            } catch {
                NyathingLog.report(error, context: "Unable to configure login launch")
            }
            activityTimeout = configuration.activityTimeout
            let directory = AppConfiguration.configurationDirectory.appendingPathComponent("animations", isDirectory: true)
            let animations = SpriteAnimation.loadAll(in: directory)
            guard let selected = animations[configuration.defaultAnimation] else {
                throw AnimationError.invalidFilename(configuration.defaultAnimation)
            }
            mainFrames = selected.frames
            try startAPIServer()
        } catch {
            let configurationURL = AppConfiguration.configurationDirectory.appendingPathComponent("config.toml")
            let animationsURL = AppConfiguration.configurationDirectory.appendingPathComponent("animations", isDirectory: true)
            let recoveryActions: [NyathingLog.RecoveryAction]
            if let configError = error as? ConfigError {
                if case .invalidAnimation = configError {
                    recoveryActions = [.init(title: "Open Animations Folder", url: animationsURL)]
                } else {
                    recoveryActions = [.init(title: "Open Configuration", url: configurationURL)]
                }
            } else if error is AnimationError {
                recoveryActions = [.init(title: "Open Animations Folder", url: animationsURL)]
            } else {
                recoveryActions = []
            }
            NyathingLog.report(error, context: "Unable to load configuration or start local API",
                               recoveryActions: recoveryActions)
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
                          let id = UUID(uuidString: activityID), self.lifecycle.animation(for: id) != nil else {
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
        lifecycle.reset()
        warningFrames = []
        warningFrameIndex = 0
        mainFrameIndex = 0
    }

    /// Begins an activity for a named animation, sharing its status item with matching activities.
    @discardableResult
    func startActivity(animation filename: String) -> UUID {
        let deadline = DispatchTime.now() + activityTimeout
        let deadlineUptime = deadline.uptimeNanoseconds
        let id = lifecycle.start(animation: filename, deadline: deadlineUptime)
        scheduleActivityExpiration(id, deadlineUptime: deadlineUptime)
        if let active = activeAnimations[filename] {
            active.activityIDs.insert(id)
            updateActivityStatus(active)
            return id
        }

        let directory = AppConfiguration.configurationDirectory.appendingPathComponent("animations", isDirectory: true)
        let animations = SpriteAnimation.loadAll(in: directory)
        let frames: [NSImage]
        switch AnimationResolution.resolve(filename, available: animations) {
        case .asset(let animation): frames = animation.frames
        case .builtInGhost: frames = Self.builtInGhostFrames()
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let active = ActiveAnimation(filename: filename, statusItem: statusItem, frames: frames, activityIDs: [id])
        activeAnimations[filename] = active
        updateActivityStatus(active)
        return id
    }

    /// Ends an activity without counting it as a disconnect.
    func stopActivity(_ id: UUID) {
        guard let filename = lifecycle.stop(id) else { return }
        removeActivityFromStatusItem(id, animation: filename)
    }

    private func removeActivityFromStatusItem(_ id: UUID, animation filename: String) {
        guard let active = activeAnimations[filename] else { return }
        active.activityIDs.remove(id)
        if active.activityIDs.isEmpty {
            NSStatusBar.system.removeStatusItem(active.statusItem)
            activeAnimations.removeValue(forKey: filename)
        } else {
            updateActivityStatus(active)
        }
    }

    /// Displays the timeout effect after lifecycle accounting records an expired activity.
    private func presentActivityTimeout() {
        let directory = AppConfiguration.configurationDirectory.appendingPathComponent("animations", isDirectory: true)
        if let explosion = SpriteAnimation.loadAll(in: directory)["explosion_36x36.png"] {
            warningFrames = explosion.frames
            warningFrameIndex = 0
        } else {
            warningFrames = []
            NyathingLog.write("Explosion animation explosion_36x36.png is missing or invalid")
        }
        updateMainStatusItem()
    }

    private func updateActivityStatus(_ active: ActiveAnimation) {
        guard let button = active.statusItem.button, !active.frames.isEmpty else { return }
        button.image = active.frames[active.frameIndex]
        button.image?.isTemplate = false
        let count = lifecycle.activityCount(for: active.filename)
        button.title = count > 1 ? "\(count)" : ""
        button.image?.accessibilityDescription = "Active Nyathing animation"
    }

    private func keepaliveActivity(_ id: UUID) -> Bool {
        let deadline = DispatchTime.now() + activityTimeout
        let deadlineUptime = deadline.uptimeNanoseconds
        guard lifecycle.keepalive(id, deadline: deadlineUptime) else { return false }
        scheduleActivityExpiration(id, deadlineUptime: deadlineUptime)
        return true
    }

    private func scheduleActivityExpiration(_ id: UUID, deadlineUptime: UInt64) {
        let deadline = DispatchTime(uptimeNanoseconds: deadlineUptime)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { [weak self] in
            DispatchQueue.main.async {
                self?.expireActivity(id, deadlineUptime: deadlineUptime)
            }
        }
    }

    private func expireActivity(_ id: UUID, deadlineUptime: UInt64) {
        guard lifecycle.deadline(for: id) == deadlineUptime else { return }
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
        guard let filename = lifecycle.expire(id, deadline: deadlineUptime) else { return }
        removeActivityFromStatusItem(id, animation: filename)
        presentActivityTimeout()
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
        if lifecycle.disconnectedCount > 0 {
            button.image = warningFrames.isEmpty
                ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Disconnected clients")
                : warningFrames[warningFrameIndex]
            button.title = "\(lifecycle.disconnectedCount)"
        } else {
            button.image = mainFrames.isEmpty ? nil : mainFrames[mainFrameIndex]
            button.title = ""
        }
        button.image?.isTemplate = false
        button.image?.accessibilityDescription = lifecycle.disconnectedCount > 0 ? "Disconnected clients" : "Nyathing animation"
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
    let filename: String
    let statusItem: NSStatusItem
    let frames: [NSImage]
    var frameIndex = 0
    var activityIDs: Set<UUID>

    init(filename: String, statusItem: NSStatusItem, frames: [NSImage], activityIDs: Set<UUID>) {
        self.filename = filename
        self.statusItem = statusItem
        self.frames = frames
        self.activityIDs = activityIDs
    }
}
