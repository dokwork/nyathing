import AppKit
import Foundation

/// Writes timestamped diagnostics to the user's XDG state directory.
enum NyathingLog {
  private static let lock = NSLock()

  static let fileURL: URL = {
    let environment = ProcessInfo.processInfo.environment
    let base: URL
    if let stateHome = environment["XDG_STATE_HOME"], !stateHome.isEmpty {
      base = URL(fileURLWithPath: stateHome, isDirectory: true)
    } else {
      base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state", isDirectory: true)
    }
    return base.appendingPathComponent("nyathing/nyathing.log")
  }()

  static func write(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    let directory = fileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      _ = chmod(directory.path, mode_t(S_IRWXU))
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let line = "\(timestamp) \(message)\n"
      let data = Data(line.utf8)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } else {
        try data.write(to: fileURL, options: .atomic)
      }
      _ = chmod(fileURL.path, mode_t(S_IRUSR | S_IWUSR))
    } catch {
      NSLog("Nyathing log write failed: %@ (original: %@)", error.localizedDescription, message)
    }
  }

  struct RecoveryAction {
    let title: String
    let url: URL
  }

  static func report(_ error: Error, context: String, recoveryActions: [RecoveryAction] = []) {
    let message = "\(context): \(error.localizedDescription)"
    write(message)
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = context
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "Open Log")
      for action in recoveryActions {
        alert.addButton(withTitle: action.title)
      }
      alert.addButton(withTitle: "OK")

      let response =
        alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
      if response == 0 {
        NSWorkspace.shared.open(fileURL)
      } else if response > 0 && response <= recoveryActions.count {
        NSWorkspace.shared.open(recoveryActions[response - 1].url)
      }
    }
  }
}

enum LaunchAgentSupport {
  static let label = "com.nyathing.Nyathing"

  /// Installs or removes the user's login agent according to the auto-start setting.
  static func configure(enabled: Bool, in configurationDirectory: URL) throws {
    let launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    let agentURL = launchAgentsDirectory.appendingPathComponent("\(label).plist")
    let legacyURL = configurationDirectory.appendingPathComponent("\(label).plist")

    if enabled {
      guard let executable = Bundle.main.executableURL?.path else {
        throw LaunchAgentError.executableUnavailable
      }
      let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [executable],
        "RunAtLoad": true,
      ]
      let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
      try FileManager.default.createDirectory(
        at: launchAgentsDirectory,
        withIntermediateDirectories: true)
      try data.write(to: agentURL, options: .atomic)
    } else if FileManager.default.fileExists(atPath: agentURL.path) {
      try FileManager.default.removeItem(at: agentURL)
    }

    if FileManager.default.fileExists(atPath: legacyURL.path) {
      try FileManager.default.removeItem(at: legacyURL)
    }
  }
}

enum LaunchAgentError: LocalizedError {
  case executableUnavailable
  var errorDescription: String? {
    "Unable to determine Nyathing's executable path for the LaunchAgent plist."
  }
}
