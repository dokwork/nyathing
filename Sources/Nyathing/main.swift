import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == [LaunchAgentSupport.serverArgument] {
  runNyathingApplication(serverMode: true)
  exit(EXIT_SUCCESS)
}
if arguments.isEmpty {
  if Bundle.main.bundleURL.pathExtension == "app" {
    runNyathingApplication(serverMode: false)
  } else {
    exit(NyathingCLI.run(["--help"]))
  }
} else {
  exit(NyathingCLI.run(arguments))
}

private func runNyathingApplication(serverMode: Bool) {
  let application = NSApplication.shared
  application.setActivationPolicy(.accessory)

  let delegate = AppDelegate(serverMode: serverMode)
  application.delegate = delegate
  application.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let serverMode: Bool

  init(serverMode: Bool = false) {
    self.serverMode = serverMode
    super.init()
  }

  private var mainStatusItem: NSStatusItem?
  private var animationTimer: Timer?
  private lazy var staticAppIcon: NSImage? = {
    guard let url = BundledResources.bundle.url(forResource: "nyathing_icon", withExtension: "png"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.size = NSSize(width: 22, height: 18)
    return image
  }()
  private var activeAnimations: [String: ActiveAnimation] = [:]
  private var lifecycle = ActivityLifecycle()
  private var activityTimeout: TimeInterval = 5
  private var keepaliveInterval: TimeInterval = 5
  private var activityTimeouts: [UUID: TimeInterval] = [:]
  private var defaultAnimation = "nyathing_36x36.png"
  private var apiServer: LocalAPIServer?
  private var apiGeneration = 0
  private var errorsWindow: NSWindow?
  private var errorsStackView: NSStackView?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    mainStatusItem = item
    configureMenu(for: item)
    if serverMode {
      startDedicatedServer()
    } else {
      reloadConfigurationAndAnimations()
    }
    animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.advanceAnimations()
    }
  }

  private func startDedicatedServer() {
    // Keep the AppKit event loop alive for API callbacks and animation updates.
    reloadConfigurationAndAnimations()
  }

  func applicationWillTerminate(_ notification: Notification) {
    animationTimer?.invalidate()
    apiGeneration += 1
    apiServer?.stop()
  }

  private func configureMenu(for item: NSStatusItem) {
    let menu = NSMenu()
    menu.addItem(withTitle: "About Nyathing", action: #selector(showAbout), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "View Errors", action: #selector(viewErrors), keyEquivalent: "")
    menu.addItem(
      withTitle: "Reset Disconnected Count", action: #selector(resetDisconnectedCount),
      keyEquivalent: "")
    menu.addItem(
      withTitle: "Reload Configuration and Animations", action: #selector(reloadFromMenu),
      keyEquivalent: "")
    menu.addItem(
      withTitle: "Open Configuration", action: #selector(openConfiguration), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Nyathing", action: #selector(quit), keyEquivalent: "q")
    for menuItem in menu.items { menuItem.target = self }
    item.menu = menu
  }

  @objc private func showAbout() {
    let repositoryURL = URL(string: "https://github.com/dokwork/nyathing")!
    let credits = NSMutableAttributedString(
      string:
        "Playful menu bar animations for background tasks.\n\nCopyright © 2026 Vladimir Popov\nMIT License\n\n"
    )
    credits.append(
      NSAttributedString(
        string: "GitHub repository",
        attributes: [.link: repositoryURL]
      )
    )
    let bundleVersion =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String
    let version = bundleVersion ?? "Development build"
    var options: [NSApplication.AboutPanelOptionKey: Any] = [
      .applicationName: "Nyathing",
      .applicationVersion: version,
      .credits: credits,
    ]
    if let iconURL = BundledResources.bundle.url(forResource: "nyathing", withExtension: "png"),
      let icon = NSImage(contentsOf: iconURL)
    {
      options[.applicationIcon] = icon
    }
    NSApp.orderFrontStandardAboutPanel(options: options)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  @objc private func viewErrors() {
    if errorsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
      window.title = "Timeout Errors"
      window.isReleasedWhenClosed = false

      let scrollView = NSScrollView()
      scrollView.hasVerticalScroller = true
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      let stack = NSStackView()
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 10
      stack.setContentHuggingPriority(.required, for: .vertical)
      stack.setContentCompressionResistancePriority(.required, for: .vertical)
      stack.translatesAutoresizingMaskIntoConstraints = false
      scrollView.documentView = stack
      window.contentView = scrollView
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 12),
        stack.trailingAnchor.constraint(
          equalTo: scrollView.contentView.trailingAnchor, constant: -12),
        stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 12),
        stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -24),
        stack.heightAnchor.constraint(
          greaterThanOrEqualTo: scrollView.contentView.heightAnchor, constant: -24),
      ])
      errorsWindow = window
      errorsStackView = stack
    }
    refreshErrorsWindow()
    errorsWindow?.center()
    errorsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func acknowledgeError(_ sender: NSButton) {
    guard let id = UUID(uuidString: sender.identifier?.rawValue ?? ""),
      lifecycle.acknowledgeTimeout(id)
    else { return }
    updateMainStatusItemVisibility()
    updateMainStatusItem()
    refreshErrorsWindow()
    if lifecycle.timedOutActivities.isEmpty {
      errorsWindow?.close()
      errorsWindow = nil
      errorsStackView = nil
    }
  }

  private func refreshErrorsWindow() {
    guard let stack = errorsStackView else { return }
    for subview in Array(stack.arrangedSubviews) {
      stack.removeArrangedSubview(subview)
      subview.removeFromSuperview()
    }
    if lifecycle.timedOutActivities.isEmpty {
      let emptyLabel = NSTextField(labelWithString: "No errors")
      emptyLabel.lineBreakMode = .byWordWrapping
      stack.addArrangedSubview(emptyLabel)
      return
    }
    for (index, error) in lifecycle.timedOutActivities.enumerated() {
      if index > 0 {
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      }
      let row = NSStackView()
      row.orientation = .horizontal
      row.alignment = .centerY
      row.spacing = 12
      row.distribution = .fill
      let leadingInset = NSView()
      leadingInset.setContentHuggingPriority(.required, for: .horizontal)
      leadingInset.widthAnchor.constraint(equalToConstant: 8).isActive = true
      let descriptionLabel = NSTextField(wrappingLabelWithString: error.description)
      descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let acknowledgeButton = NSButton(
        title: "Acknowledge", target: self, action: #selector(acknowledgeError(_:)))
      acknowledgeButton.identifier = NSUserInterfaceItemIdentifier(error.id.uuidString)
      row.addArrangedSubview(leadingInset)
      row.addArrangedSubview(descriptionLabel)
      row.addArrangedSubview(acknowledgeButton)
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
  }

  @objc private func resetDisconnectedCount() {
    lifecycle.resetDisconnectedCount()
    updateMainStatusItemVisibility()
    updateMainStatusItem()
    refreshErrorsWindow()
  }

  @objc private func reloadFromMenu() {
    reloadConfigurationAndAnimations()
  }

  @objc private func openConfiguration() {
    let url = AppConfiguration.configurationDirectory.appendingPathComponent("config.toml")
    guard NSWorkspace.shared.open(url) else {
      NyathingLog.report(
        NSError(
          domain: "Nyathing", code: 1,
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
        try LaunchAgentSupport.configure(
          enabled: configuration.autoStart,
          in: AppConfiguration.configurationDirectory)
        if configuration.autoStart {
          NyathingLog.write("Configured Nyathing to launch at the next login")
        }
      } catch {
        NyathingLog.report(error, context: "Unable to configure login launch")
      }
      activityTimeout = configuration.activityTimeout
      keepaliveInterval = configuration.keepaliveInterval
      defaultAnimation = configuration.defaultAnimation
      try startAPIServer()
    } catch {
      let configurationURL = AppConfiguration.configurationDirectory.appendingPathComponent(
        "config.toml")
      let recoveryActions: [NyathingLog.RecoveryAction]
      if error is ConfigError {
        recoveryActions = [.init(title: "Open Configuration", url: configurationURL)]
      } else {
        recoveryActions = []
      }
      NyathingLog.report(
        error, context: "Unable to load configuration or start local API",
        recoveryActions: recoveryActions)
    }
    updateMainStatusItem()
  }

  private func startAPIServer() throws {
    let generation = apiGeneration
    apiServer = LocalAPIServer(
      defaultAnimation: defaultAnimation,
      defaultKeepaliveInterval: keepaliveInterval,
      defaultActivityTimeout: activityTimeout,
      onStart: { [weak self] filename, description, _, timeout in
        try DispatchQueue.main.sync {
          guard let self, self.apiGeneration == generation else { throw LocalAPIError.unavailable }
          return self.startActivity(
            animation: filename, description: description, activityTimeout: timeout
          ).uuidString
        }
      },
      onKeepalive: { [weak self] activityID in
        try DispatchQueue.main.sync {
          guard let self, self.apiGeneration == generation,
            let id = UUID(uuidString: activityID), self.keepaliveActivity(id)
          else {
            throw LocalAPIError.unknownActivity
          }
        }
      },
      onStop: { [weak self] activityID in
        try DispatchQueue.main.sync {
          guard let self, self.apiGeneration == generation,
            let id = UUID(uuidString: activityID), self.lifecycle.animation(for: id) != nil
          else {
            throw LocalAPIError.unknownActivity
          }
          self.stopActivity(id)
        }
      }
    )
    try apiServer?.start()
  }

  private func clearRuntimeState() {
    activeAnimations.removeAll()
    lifecycle.reset()
    updateMainStatusItemVisibility()
    updateMainStatusItem()
    refreshErrorsWindow()
  }

  /// Begins an activity for a named animation, sharing its status item with matching activities.
  @discardableResult
  func startActivity(
    animation filename: String, description: String? = nil,
    activityTimeout timeout: TimeInterval? = nil
  ) -> UUID {
    let timeout = timeout ?? activityTimeout
    let deadline = DispatchTime.now() + timeout
    let deadlineUptime = deadline.uptimeNanoseconds
    let id = lifecycle.start(
      animation: filename, description: description, deadline: deadlineUptime)
    activityTimeouts[id] = timeout
    scheduleActivityExpiration(id, deadlineUptime: deadlineUptime)
    if let active = activeAnimations[filename] {
      active.activityIDs.insert(id)
      updateActivityStatus(active)
      updateMainStatusItemVisibility()
      updateMainStatusItem()
      return id
    }

    let directory = AppConfiguration.configurationDirectory.appendingPathComponent(
      "animations", isDirectory: true)
    let animations = SpriteAnimation.loadAll(in: directory)
    let frames: [NSImage]
    switch AnimationResolution.resolve(filename, available: animations) {
    case .asset(let animation): frames = animation.frames
    case .builtInGhost: frames = Self.builtInGhostFrames()
    }
    guard let statusItem = mainStatusItem else { return id }
    let active = ActiveAnimation(
      filename: filename, statusItem: statusItem, frames: frames, activityIDs: [id])
    activeAnimations[filename] = active
    updateActivityStatus(active)
    updateMainStatusItemVisibility()
    updateMainStatusItem()
    return id
  }

  /// Ends an activity without counting it as a disconnect.
  func stopActivity(_ id: UUID) {
    guard let filename = lifecycle.stop(id) else { return }
    activityTimeouts.removeValue(forKey: id)
    removeActivityFromStatusItem(id, animation: filename)
  }

  private func removeActivityFromStatusItem(_ id: UUID, animation filename: String) {
    guard let active = activeAnimations[filename] else { return }
    active.activityIDs.remove(id)
    if active.activityIDs.isEmpty {
      activeAnimations.removeValue(forKey: filename)
      updateMainStatusItemVisibility()
      updateMainStatusItem()
    } else {
      updateActivityStatus(active)
    }
  }

  /// Refreshes the static error indicator after lifecycle accounting records a timeout.
  private func presentActivityTimeout() {
    updateMainStatusItemVisibility()
    updateMainStatusItem()
    refreshErrorsWindow()
  }

  private func updateActivityStatus(_ active: ActiveAnimation) {
    guard let button = active.statusItem.button, !active.frames.isEmpty else { return }
    let frame = active.frames[active.frameIndex]
    let count = lifecycle.activityCount(for: active.filename)
    button.image = count > 1 ? Self.image(frame, withCountBadge: count) : frame
    button.image?.isTemplate = false
    button.title = ""
    button.toolTip = active.filename
    active.statusItem.length = frame.size.width
    button.image?.accessibilityDescription =
      count > 1 ? "Active Nyathing animation, \(count) activities" : "Active Nyathing animation"
  }

  private static func image(_ frame: NSImage, withCountBadge count: Int) -> NSImage {
    let image = NSImage(size: frame.size)
    image.lockFocus()
    frame.draw(in: NSRect(origin: .zero, size: frame.size))

    let text = "\(count)" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.boldSystemFont(ofSize: 9),
      .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attributes)
    let badgeWidth = max(14, textSize.width + 6)
    let badge = NSRect(
      x: frame.size.width - badgeWidth - 1,
      y: 1,
      width: badgeWidth,
      height: 13)
    let background = NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6)
    NSColor(calibratedWhite: 0.08, alpha: 0.95).setFill()
    background.fill()
    NSColor.white.setStroke()
    background.lineWidth = 1
    background.stroke()
    text.draw(
      at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
      withAttributes: attributes)
    image.unlockFocus()
    return image
  }

  private func keepaliveActivity(_ id: UUID) -> Bool {
    let deadline = DispatchTime.now() + (activityTimeouts[id] ?? activityTimeout)
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
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + remaining) {
        [weak self] in
        DispatchQueue.main.async {
          self?.expireActivity(id, deadlineUptime: deadlineUptime)
        }
      }
      return
    }
    guard let expired = lifecycle.expire(id, deadline: deadlineUptime) else { return }
    activityTimeouts.removeValue(forKey: id)
    removeActivityFromStatusItem(id, animation: expired.animation)
    presentActivityTimeout()
  }

  private func advanceAnimations() {
    for active in activeAnimations.values {
      active.frameIndex = (active.frameIndex + 1) % active.frames.count
      updateActivityStatus(active)
    }
    updateMainStatusItem()
  }

  private func updateMainStatusItemVisibility() {
    mainStatusItem?.isVisible = true
  }

  private func updateMainStatusItem() {
    guard let button = mainStatusItem?.button else { return }
    let outstandingErrorCount = lifecycle.timedOutActivities.count
    if outstandingErrorCount > 0 {
      button.image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: "Outstanding timeout errors")
      button.title = "\(outstandingErrorCount)"
    } else if let active = activeAnimations.values.first {
      updateActivityStatus(active)
    } else {
      button.image =
        staticAppIcon
        ?? NSImage(
          systemSymbolName: "sparkles", accessibilityDescription: "Nyathing")
      button.title = ""
    }
    button.image?.isTemplate = false
    button.image?.accessibilityDescription =
      outstandingErrorCount > 0 ? "Outstanding timeout errors" : "Nyathing"
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
