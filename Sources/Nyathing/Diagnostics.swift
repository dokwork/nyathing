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
  static let serverArgument = "--nyathing-server"

  private static var agentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent("\(label).plist")
  }

  private static var serviceTarget: String {
    "gui/\(getuid())/\(label)"
  }

  static func startServer(in configurationDirectory: URL) throws {
    try configure(enabled: true, in: configurationDirectory)
    if launchctl(["print", serviceTarget]).status == 0 {
      try runLaunchctl(["kickstart", serviceTarget])
      return
    }
    try runLaunchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
  }

  static func stopServer(in configurationDirectory: URL) throws {
    if launchctl(["print", serviceTarget]).status == 0 {
      try runLaunchctl(["bootout", serviceTarget])
    }
    try? FileManager.default.removeItem(at: agentURL)
  }

  static func serverIsRunning() -> Bool {
    let result = launchctl(["print", serviceTarget])
    guard result.status == 0 else { return false }
    return result.output.components(separatedBy: .newlines).contains { line in
      guard line.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") else { return false }
      let value = line.trimmingCharacters(in: .whitespaces).dropFirst("pid = ".count)
      return Int(value).map { $0 > 0 } ?? false
    }
  }

  private static func runLaunchctl(_ arguments: [String]) throws {
    let result = launchctl(arguments)
    guard result.status == 0 else {
      let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      throw LaunchAgentError.launchctl(detail.isEmpty ? "launchctl failed." : detail)
    }
  }

  private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "")
    } catch {
      return (1, error.localizedDescription)
    }
  }

  /// Installs or removes the user's login agent according to the auto-start setting.
  static func configure(enabled: Bool, in configurationDirectory: URL) throws {
    let launchAgentsDirectory = agentURL.deletingLastPathComponent()
    let legacyURL = configurationDirectory.appendingPathComponent("\(label).plist")

    if enabled {
      guard let executable = Bundle.main.executableURL?.path else {
        throw LaunchAgentError.executableUnavailable
      }
      let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [executable, serverArgument],
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
  case launchctl(String)
  var errorDescription: String? {
    switch self {
    case .executableUnavailable:
      return "Unable to determine Nyathing's executable path for the LaunchAgent plist."
    case .launchctl(let message):
      return "Unable to manage the Nyathing server: \(message)"
    }
  }
}
