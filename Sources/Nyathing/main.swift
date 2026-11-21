import AppKit
import Foundation
import UniformTypeIdentifiers

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
  private var maxWaitTime: TimeInterval = 180
  private var activityTimeouts: [UUID: TimeInterval] = [:]
  private var externalActivityIDs: [String: UUID] = [:]
  private var activityKeepaliveIntervals: [UUID: TimeInterval] = [:]
  private var activityKeepaliveIntervalSources: [UUID: String] = [:]
  private var timedOutActivityDetails: [UUID: ActivityTimeoutDetails] = [:]
  private var activityStartOrder: [UUID: UInt64] = [:]
  private var nextActivityStartOrder: UInt64 = 0
  private var apiServer: LocalAPIServer?
  private var apiGeneration = 0
  private var errorsWindow: NSWindow?
  private var errorsStackView: NSStackView?
  private var configurationWindow: NSWindow?
  private var maxWaitTimeField: NSTextField?
  private var autoStartCheckbox: NSButton?
  private var defaultAnimationPicker: NSPopUpButton?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    mainStatusItem = item
    configureMenu(for: item)
    if serverMode {
      startDedicatedServer()
    } else {
      reloadConfiguration()
    }
    animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.advanceAnimations()
    }
  }

  private func startDedicatedServer() {
    // Keep the AppKit event loop alive for API callbacks and animation updates.
    reloadConfiguration()
  }

  func applicationWillTerminate(_ notification: Notification) {
    animationTimer?.invalidate()
    apiGeneration += 1
    apiServer?.stop()
  }

  private func configureMenu(for item: NSStatusItem) {
    let menu = NSMenu()
    let activities = activeTaskMenuItems()
    for menuItem in activities { menu.addItem(menuItem) }
    if !activities.isEmpty { menu.addItem(.separator()) }
    if !lifecycle.timedOutActivities.isEmpty {
      menu.addItem(
        withTitle: "View Errors", action: #selector(viewErrors), keyEquivalent: "")
    }
    menu.addItem(
      withTitle: "Edit Configuration", action: #selector(editConfiguration), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "About", action: #selector(showAbout), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
    for menuItem in menu.items { menuItem.target = self }
    item.menu = menu
  }

  private func activeTaskMenuItems() -> [NSMenuItem] {
    let rows = activityStartOrder.keys.sorted {
      activityStartOrder[$0, default: 0] > activityStartOrder[$1, default: 0]
    }
    let font = NSFont.menuFont(ofSize: 0)
    let widestActionTitle =
      [
        "View Errors", "Edit Configuration", "About", "Quit",
      ].map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    let iconColumnWidth: CGFloat = 16
    let horizontalMenuPadding: CGFloat = 16
    let availableWidth = max(0, widestActionTitle - iconColumnWidth - horizontalMenuPadding)
    return rows.compactMap { id in
      guard let animation = lifecycle.animation(for: id),
        let active = activeAnimations[animation], let icon = active.frames.first,
        let description = lifecycle.description(for: id)
      else { return nil }
      let item = NSMenuItem(
        title: Self.truncatedMenuDescription(description, font: font, width: availableWidth),
        action: nil, keyEquivalent: "")
      let menuIcon = (icon.copy() as? NSImage) ?? icon
      menuIcon.size = NSSize(width: iconColumnWidth, height: iconColumnWidth)
      item.image = menuIcon
      item.isEnabled = false
      return item
    }
  }

  private static func truncatedMenuDescription(_ text: String, font: NSFont, width: CGFloat)
    -> String
  {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    guard (text as NSString).size(withAttributes: attributes).width > width else { return text }
    let ellipsis = "…"
    var result = text
    while !result.isEmpty,
      ((result + ellipsis) as NSString).size(withAttributes: attributes).width > width
    {
      result.removeLast()
    }
    return result.isEmpty ? ellipsis : result + ellipsis
  }

  private func refreshStatusItemMenus() {
    if let mainStatusItem { configureMenu(for: mainStatusItem) }
    for active in activeAnimations.values { configureMenu(for: active.statusItem) }
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
    let version = bundleVersion ?? AppVersion.current
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
      stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
      stack.setContentHuggingPriority(.required, for: .vertical)
      stack.setContentCompressionResistancePriority(.required, for: .vertical)
      stack.translatesAutoresizingMaskIntoConstraints = false
      scrollView.documentView = stack
      window.contentView = scrollView
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
        stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        stack.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
      ])
      errorsWindow = window
      errorsStackView = stack
    }
    refreshErrorsWindow()
    errorsWindow?.center()
    errorsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func sectionLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    return label
  }

  private static func seconds(_ value: TimeInterval) -> String {
    "\(value.formatted()) seconds"
  }

  @objc private func acknowledgeError(_ sender: NSButton) {
    guard let id = UUID(uuidString: sender.identifier?.rawValue ?? ""),
      lifecycle.acknowledgeTimeout(id)
    else { return }
    timedOutActivityDetails.removeValue(forKey: id)
    updateMainStatusItemVisibility()
    updateMainStatusItem()
    refreshStatusItemMenus()
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
      let details = timedOutActivityDetails[error.id]
      let block = NSStackView()
      block.orientation = .vertical
      block.alignment = .leading
      block.spacing = 5
      block.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      block.addArrangedSubview(sectionLabel("Activity ID"))
      let idLabel = NSTextField(labelWithString: error.id.uuidString)
      idLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
      block.addArrangedSubview(idLabel)
      block.addArrangedSubview(sectionLabel("Client description"))
      let descriptionLabel = NSTextField(wrappingLabelWithString: error.description)
      descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      block.addArrangedSubview(descriptionLabel)
      block.addArrangedSubview(sectionLabel("Reason"))
      let reasonLabel = NSTextField(
        wrappingLabelWithString: "No keepalive was received before the activity timed out.")
      reasonLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      block.addArrangedSubview(reasonLabel)
      if let details {
        let intervalLabel = NSTextField(
          wrappingLabelWithString:
            "Keepalive interval: \(Self.seconds(details.keepaliveInterval)) "
            + "(\(details.intervalSource)).")
        intervalLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        block.addArrangedSubview(intervalLabel)
        let waitExplanation =
          details.timeout < details.keepaliveInterval * 2
          ? "capped by max_wait_time"
          : "2 × keepalive interval"
        let timeoutLabel = NSTextField(
          wrappingLabelWithString:
            "Expiration threshold: \(Self.seconds(details.timeout)) "
            + "(\(waitExplanation); max_wait_time is "
            + "\(Self.seconds(details.maxWaitTime))).")
        timeoutLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        block.addArrangedSubview(timeoutLabel)
      }
      let buttonRow = NSStackView()
      buttonRow.orientation = .horizontal
      buttonRow.alignment = .centerY
      buttonRow.distribution = .fill
      let buttonSpacer = NSView()
      buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let acknowledgeButton = NSButton(
        title: "Acknowledge", target: self, action: #selector(acknowledgeError(_:)))
      acknowledgeButton.identifier = NSUserInterfaceItemIdentifier(error.id.uuidString)
      buttonRow.addArrangedSubview(buttonSpacer)
      buttonRow.addArrangedSubview(acknowledgeButton)
      block.addArrangedSubview(buttonRow)
      buttonRow.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
      stack.addArrangedSubview(block)
      block.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }
  }

  private static func shortAnimationName(_ filename: String) -> String? {
    guard
      let range = filename.range(
        of: #"_[0-9]+x[0-9]+\.png$"#, options: .regularExpression)
    else { return nil }
    return String(filename[..<range.lowerBound])
  }

  private func animationMenuItem(title: String, frame: NSImage?) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.representedObject = title
    let attributedTitle = NSMutableAttributedString(string: "\u{2002}\(title)  ")
    if let frame {
      let image = (frame.copy() as? NSImage) ?? frame
      image.size = NSSize(width: 18, height: 18)
      let attachment = NSTextAttachment()
      attachment.image = image
      attachment.bounds = CGRect(x: 0, y: -4, width: 18, height: 18)
      attributedTitle.append(NSAttributedString(attachment: attachment))
    }
    item.attributedTitle = attributedTitle
    return item
  }

  @objc private func editConfiguration() {
    if let configurationWindow {
      configurationWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let configuration: AppConfiguration
    let configuredAnimation: String
    do {
      configuration = try AppConfiguration.load(validateDefaultAnimation: false)
      configuredAnimation = try configuration.defaultAnimation
    } catch {
      showConfigurationEditorError(error.localizedDescription)
      return
    }

    let animationDirectory = AppConfiguration.configurationDirectory
      .appendingPathComponent("animations", isDirectory: true)
    var animationsByName: [String: SpriteAnimation] = [:]
    for animation in SpriteAnimation.loadAll(in: animationDirectory).values {
      guard let name = Self.shortAnimationName(animation.filename) else { continue }
      if let current = animationsByName[name],
        current.frameSize.width * current.frameSize.height
          >= animation.frameSize.width * animation.frameSize.height
      {
        continue
      }
      animationsByName[name] = animation
    }
    let animationNames = ["random"] + animationsByName.keys.sorted()

    let maxWaitTimeField = NSTextField(string: String(configuration.maxWaitTime))
    maxWaitTimeField.placeholderString = "Seconds"
    maxWaitTimeField.alignment = .right
    maxWaitTimeField.widthAnchor.constraint(equalToConstant: 130).isActive = true

    let animationPicker = NSPopUpButton()
    for name in animationNames {
      animationPicker.menu?.addItem(
        animationMenuItem(title: name, frame: animationsByName[name]?.frames.first))
    }
    selectAnimation(configuredAnimation, in: animationPicker)
    let browseButton = NSButton(
      title: "Choose PNG…", target: self, action: #selector(chooseConfigurationAnimation))
    let animationControls = NSStackView(views: [animationPicker, browseButton])
    animationControls.spacing = 8
    animationPicker.widthAnchor.constraint(equalToConstant: 170).isActive = true

    let autoStart = NSButton(
      checkboxWithTitle: "Launch Nyathing at login", target: self, action: nil)
    autoStart.state = configuration.autoStart ? .on : .off

    func row(_ title: String, control: NSView) -> NSStackView {
      let label = NSTextField(labelWithString: title)
      label.widthAnchor.constraint(equalToConstant: 190).isActive = true
      let row = NSStackView(views: [label, control])
      row.orientation = .horizontal
      row.alignment = .centerY
      row.spacing = 12
      return row
    }

    let fields = NSStackView(views: [
      row("Maximum wait time (seconds)", control: maxWaitTimeField),
      row("Default animation", control: animationControls),
      autoStart,
    ])
    fields.orientation = .vertical
    fields.alignment = .leading
    fields.spacing = 14
    fields.translatesAutoresizingMaskIntoConstraints = false

    let cancelButton = NSButton(
      title: "Cancel", target: self, action: #selector(cancelConfigurationEdit))
    let acceptButton = NSButton(
      title: "Accept", target: self, action: #selector(acceptConfigurationEdit))
    acceptButton.keyEquivalent = "\\r"
    let buttons = NSStackView(views: [cancelButton, acceptButton])
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 8
    buttons.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()
    content.addSubview(fields)
    content.addSubview(buttons)
    NSLayoutConstraint.activate([
      fields.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      fields.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
      fields.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      fields.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -18),
    ])

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 230),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Edit Configuration"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = content
    configurationWindow = window
    self.maxWaitTimeField = maxWaitTimeField
    autoStartCheckbox = autoStart
    defaultAnimationPicker = animationPicker
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func selectAnimation(_ value: String, in picker: NSPopUpButton) {
    if let item = picker.itemArray.first(where: { ($0.representedObject as? String) == value }) {
      picker.select(item)
      return
    }
    let title = URL(fileURLWithPath: value).lastPathComponent
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.representedObject = value
    item.toolTip = value
    picker.menu?.addItem(item)
    picker.select(item)
  }

  @objc private func chooseConfigurationAnimation() {
    guard let configurationWindow else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png]
    panel.beginSheetModal(for: configurationWindow) { [weak self] response in
      guard response == .OK, let url = panel.url, let self, let picker = self.defaultAnimationPicker
      else { return }
      self.selectAnimation(url.path, in: picker)
    }
  }

  @objc private func cancelConfigurationEdit() {
    configurationWindow?.close()
  }

  @objc private func acceptConfigurationEdit() {
    guard let maxWaitTimeField,
      let autoStartCheckbox,
      let defaultAnimationPicker,
      let selectedAnimation = defaultAnimationPicker.selectedItem?.representedObject as? String
    else { return }

    guard let maxWaitTime = Double(maxWaitTimeField.stringValue),
      maxWaitTime.isFinite, maxWaitTime > 0
    else {
      showConfigurationEditorError("Maximum wait time must be a positive finite number.")
      return
    }

    let animation: String
    do {
      _ = try AppConfiguration.resolveDefaultAnimation(
        selectedAnimation, in: AppConfiguration.configurationDirectory)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      animation = String(decoding: try encoder.encode(selectedAnimation), as: UTF8.self)
    } catch {
      showConfigurationEditorError(error.localizedDescription)
      return
    }

    let configurationText = """
      # Maximum seconds to wait since the last client keepalive.
      max_wait_time = \(maxWaitTime)
      # Whether Nyathing should launch automatically when you log in.
      auto_start = \(autoStartCheckbox.state == .on ? "true" : "false")
      # Animation name, PNG path, or "random" used when a client omits the animation field.
      default_animation = \(animation)
      """

    let configurationURL = AppConfiguration.configurationDirectory
      .appendingPathComponent("config.toml")
    do {
      try configurationText.write(to: configurationURL, atomically: true, encoding: .utf8)
    } catch {
      showConfigurationEditorError(error.localizedDescription)
      return
    }

    configurationWindow?.close()
    reloadConfiguration()
  }

  private func showConfigurationEditorError(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Unable to Apply Configuration"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  func windowWillClose(_ notification: Notification) {
    guard (notification.object as? NSWindow) === configurationWindow else { return }
    configurationWindow = nil
    maxWaitTimeField = nil
    autoStartCheckbox = nil
    defaultAnimationPicker = nil
  }

  private func reloadConfiguration() {
    do {
      let configuration = try AppConfiguration.load(validateDefaultAnimation: false)
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
      maxWaitTime = configuration.maxWaitTime
      if let apiServer {
        apiServer.updateStartSettings(
          defaultAnimation: { try configuration.resolvedDefaultAnimation },
          maxWaitTime: maxWaitTime)
      } else {
        try startAPIServer(configuration: configuration)
      }
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

  private func startAPIServer(configuration: AppConfiguration) throws {
    let generation = apiGeneration
    let server = LocalAPIServer(
      defaultAnimation: { try configuration.resolvedDefaultAnimation },
      maxWaitTime: maxWaitTime,
      onStart: {
        [weak self] filename, description, requestedID, interval, intervalWasProvided, timeout in
        try DispatchQueue.main.sync {
          guard let self, self.apiGeneration == generation else { throw LocalAPIError.unavailable }
          if let requestedID, self.externalActivityIDs[requestedID] != nil {
            throw LocalAPIError.activityIDInUse(requestedID)
          }
          let id = try self.startActivity(
            animation: filename, description: description, activityTimeout: timeout,
            keepaliveInterval: interval, intervalWasProvided: intervalWasProvided
          )
          let externalID = requestedID ?? id.uuidString
          self.externalActivityIDs[externalID] = id
          return externalID
        }
      },
      onKeepalive: { [weak self] activityID in
        try DispatchQueue.main.sync {
          guard let self, self.apiGeneration == generation,
            let id = self.externalActivityIDs[activityID], self.keepaliveActivity(id)
          else {
            throw LocalAPIError.unknownActivity
          }
        }
      },
      onStop: { [weak self] activityID in
        try DispatchQueue.main.sync {
          guard let self, self.apiGeneration == generation,
            let id = self.externalActivityIDs[activityID], self.lifecycle.animation(for: id) != nil
          else {
            throw LocalAPIError.unknownActivity
          }
          self.stopActivity(id)
          self.externalActivityIDs.removeValue(forKey: activityID)
        }
      }
    )
    try server.start()
    apiServer = server
  }

  /// Begins an activity for a named animation, sharing its status item with matching activities.
  @discardableResult
  func startActivity(
    animation filename: String, description: String? = nil,
    activityTimeout timeout: TimeInterval? = nil,
    keepaliveInterval: TimeInterval = LocalAPIServer.defaultKeepaliveInterval,
    intervalWasProvided: Bool = false
  ) throws -> UUID {
    let directory = AppConfiguration.configurationDirectory.appendingPathComponent(
      "animations", isDirectory: true)
    let resolvedFilename = try NyathingCLI.resolveAnimation(filename, in: directory)
    let existingAnimation = activeAnimations[resolvedFilename]
    let frames: [NSImage]?
    if existingAnimation == nil {
      let sourceFrames: [NSImage]
      if resolvedFilename == NyathingCLI.builtInGhostAnimation {
        sourceFrames = Self.builtInGhostFrames()
      } else {
        sourceFrames = try SpriteAnimation.load(from: URL(fileURLWithPath: resolvedFilename)).frames
      }
      frames = Self.scaledAnimationFrames(sourceFrames, height: 22)
    } else {
      frames = nil
    }

    let timeout = timeout ?? min(LocalAPIServer.defaultKeepaliveInterval * 2, maxWaitTime)
    let deadline = DispatchTime.now() + timeout
    let deadlineUptime = deadline.uptimeNanoseconds
    let id = lifecycle.start(
      animation: resolvedFilename, description: description, deadline: deadlineUptime)
    activityStartOrder[id] = nextActivityStartOrder
    nextActivityStartOrder &+= 1
    activityTimeouts[id] = timeout
    activityKeepaliveIntervals[id] = keepaliveInterval
    activityKeepaliveIntervalSources[id] =
      intervalWasProvided ? "client-provided" : "built-in default"
    scheduleActivityExpiration(id, deadlineUptime: deadlineUptime)
    if let active = existingAnimation {
      active.activityIDs.insert(id)
      updateActivityStatus(active)
      updateMainStatusItemVisibility()
      updateMainStatusItem()
      refreshStatusItemMenus()
      return id
    }

    guard let frames else { preconditionFailure("New animations must have decoded frames.") }
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    configureMenu(for: statusItem)
    let active = ActiveAnimation(
      filename: resolvedFilename, statusItem: statusItem, frames: frames, activityIDs: [id])
    activeAnimations[resolvedFilename] = active
    updateActivityStatus(active)
    updateMainStatusItemVisibility()
    updateMainStatusItem()
    refreshStatusItemMenus()
    return id
  }

  /// Ends an activity without counting it as a disconnect.
  func stopActivity(_ id: UUID) {
    guard let filename = lifecycle.stop(id) else { return }
    activityTimeouts.removeValue(forKey: id)
    activityKeepaliveIntervals.removeValue(forKey: id)
    activityKeepaliveIntervalSources.removeValue(forKey: id)
    activityStartOrder.removeValue(forKey: id)
    removeActivityFromStatusItem(id, animation: filename)
    refreshStatusItemMenus()
  }

  private func removeActivityFromStatusItem(_ id: UUID, animation filename: String) {
    guard let active = activeAnimations[filename] else { return }
    active.activityIDs.remove(id)
    if active.activityIDs.isEmpty {
      activeAnimations.removeValue(forKey: filename)
      NSStatusBar.system.removeStatusItem(active.statusItem)
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

  private static func scaledAnimationFrames(_ frames: [NSImage], height: CGFloat) -> [NSImage] {
    frames.map { frame in
      let scaled = (frame.copy() as? NSImage) ?? frame
      let scale = height / frame.size.height
      scaled.size = NSSize(width: frame.size.width * scale, height: height)
      return scaled
    }
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
    let fallbackTimeout = min(LocalAPIServer.defaultKeepaliveInterval * 2, maxWaitTime)
    let deadline = DispatchTime.now() + (activityTimeouts[id] ?? fallbackTimeout)
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
    let interval =
      activityKeepaliveIntervals.removeValue(forKey: id)
      ?? LocalAPIServer.defaultKeepaliveInterval
    let intervalSource =
      activityKeepaliveIntervalSources.removeValue(forKey: id)
      ?? "built-in default"
    let timeout = activityTimeouts.removeValue(forKey: id) ?? min(interval * 2, maxWaitTime)
    externalActivityIDs = externalActivityIDs.filter { $0.value != id }
    timedOutActivityDetails[id] = ActivityTimeoutDetails(
      keepaliveInterval: interval, intervalSource: intervalSource,
      timeout: timeout, maxWaitTime: maxWaitTime)
    activityStartOrder.removeValue(forKey: id)
    removeActivityFromStatusItem(id, animation: expired.animation)
    refreshStatusItemMenus()
    presentActivityTimeout()
  }

  private func advanceAnimations() {
    for active in activeAnimations.values {
      guard !active.frames.isEmpty else { continue }
      active.frameIndex = (active.frameIndex + 1) % active.frames.count
      updateActivityStatus(active)
    }
    updateMainStatusItem()
  }

  private func updateMainStatusItemVisibility() {
    mainStatusItem?.isVisible = activeAnimations.isEmpty || !lifecycle.timedOutActivities.isEmpty
  }

  private func updateMainStatusItem() {
    guard let button = mainStatusItem?.button else { return }
    let outstandingErrorCount = lifecycle.timedOutActivities.count
    if outstandingErrorCount > 0 {
      button.image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: "Outstanding timeout errors")
      button.title = "\(outstandingErrorCount)"
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

private struct ActivityTimeoutDetails {
  let keepaliveInterval: TimeInterval
  let intervalSource: String
  let timeout: TimeInterval
  let maxWaitTime: TimeInterval
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
