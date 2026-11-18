import AppKit
import Darwin
import Foundation

private var signalChildPID: pid_t = 0
private var pendingChildSignal: Int32 = 0
private var receivedTerminationSignal = false

private func forwardSignal(_ signal: Int32) {
  let forwardedSignal = receivedTerminationSignal ? SIGKILL : signal
  receivedTerminationSignal = true
  if signalChildPID > 0 {
    _ = kill(signalChildPID, forwardedSignal)
  } else {
    pendingChildSignal = forwardedSignal
  }
}

private final class KeepaliveFailure {
  private let lock = NSLock()
  private var storedMessage: String?

  var message: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedMessage
  }

  func record(_ message: String) {
    lock.lock()
    if storedMessage == nil { storedMessage = message }
    lock.unlock()
  }
}

struct CLIArguments {
  let animation: String
  let command: String
  let arguments: [String]

  static let usage = "Usage: nyathing [--animation FILE | -a FILE] COMMAND [ARGUMENT ...]\n       nyathing help | --help\n       nyathing version | --version"

  static func parse(_ arguments: [String]) throws -> CLIArguments? {
    if arguments == ["help"] || arguments == ["--help"] { return nil }
    if arguments == ["version"] || arguments == ["--version"] { return nil }
    var values = arguments
    var animation = "nyathing_36x36.png"
    if values.first == "--animation" || values.first == "-a" {
      guard values.count >= 3, !values[1].isEmpty else { throw CLIError.usage }
      animation = values[1]
      values.removeFirst(2)
    }
    guard let command = values.first else { throw CLIError.usage }
    return CLIArguments(animation: animation, command: command, arguments: Array(values.dropFirst()))
  }
}

enum CLIError: LocalizedError {
  case usage
  case animationUnavailable(String)
  case server(String)
  case api(String)

  var errorDescription: String? {
    switch self {
    case .usage: return CLIArguments.usage
    case .animationUnavailable(let filename):
      return "Animation not found or invalid: \(filename)."
    case .server(let message), .api(let message): return message
    }
  }
}

enum NyathingCLI {
  static func run(_ arguments: [String]) -> Int32 {
    if arguments == ["help"] || arguments == ["--help"] {
      print(CLIArguments.usage)
      return 0
    }
    if arguments == ["version"] || arguments == ["--version"] {
      print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "Development build")
      return 0
    }
    do {
      guard let parsed = try CLIArguments.parse(arguments) else { return 0 }
      return try execute(parsed)
    } catch {
      FileHandle.standardError.write(Data("nyathing: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private static func execute(_ cli: CLIArguments) throws -> Int32 {
    let executable = try resolveExecutable(cli.command)
    let configuration = try AppConfiguration.load()
    try validateAnimation(cli.animation, in: AppConfiguration.configurationDirectory)
    let keepaliveInterval = keepaliveInterval(for: configuration)
    let client = try LocalAPIClient.connectOrStartServer()
    let activity = try client.command(["command": "start", "animation": cli.animation])
    guard let activityID = activity["activity_id"] as? String else {
      throw CLIError.api("The server returned an invalid activity response.")
    }
    defer { _ = try? client.command(["command": "stop", "activity_id": activityID]) }
    _ = try client.command(["command": "keepalive", "activity_id": activityID])

    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = cli.arguments
    child.standardInput = FileHandle.standardInput
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError

    let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    signalChildPID = 0
    pendingChildSignal = 0
    receivedTerminationSignal = false
    let previousHandlers = signals.map { Darwin.signal($0, forwardSignal) }
    defer {
      signalChildPID = 0
      for (signal, handler) in zip(signals, previousHandlers) { _ = Darwin.signal(signal, handler) }
    }
    do { try child.run() } catch { throw error }
    signalChildPID = child.processIdentifier
    if pendingChildSignal != 0 { _ = kill(child.processIdentifier, pendingChildSignal) }

    let keepaliveFailure = KeepaliveFailure()
    let escalation = DispatchSource.makeTimerSource(queue: .global())
    escalation.schedule(deadline: .now() + 2, repeating: 2)
    escalation.setEventHandler {
      if (receivedTerminationSignal || keepaliveFailure.message != nil) && child.isRunning {
        _ = kill(child.processIdentifier, SIGKILL)
      }
    }
    escalation.resume()

    let keepalive = DispatchSource.makeTimerSource(queue: .global())
    keepalive.schedule(deadline: .now() + keepaliveInterval, repeating: keepaliveInterval)
    keepalive.setEventHandler {
      do { _ = try client.command(["command": "keepalive", "activity_id": activityID]) }
      catch {
        keepaliveFailure.record(error.localizedDescription)
        if child.isRunning { _ = kill(child.processIdentifier, SIGTERM) }
      }
    }
    keepalive.resume()
    child.waitUntilExit()
    keepalive.cancel()
    escalation.cancel()
    if let failure = keepaliveFailure.message {
      throw CLIError.api("Animation keepalive failed; child process was terminated: \(failure)")
    }
    if child.terminationReason == .uncaughtSignal { return 128 + child.terminationStatus }
    return child.terminationStatus
  }

  static func validateAnimation(_ filename: String, in directory: URL) throws {
    guard !filename.contains("/"), !filename.contains("\\"),
      (try? SpriteAnimation.load(from: directory.appendingPathComponent(filename))) != nil
    else {
      throw CLIError.animationUnavailable(filename)
    }
  }

  static func keepaliveInterval(for configuration: AppConfiguration) -> TimeInterval {
    min(configuration.keepaliveInterval, configuration.activityTimeout / 2)
  }

  static func resolveExecutable(_ command: String) throws -> String {
    if command.contains("/") {
      let path = URL(fileURLWithPath: command, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "Command not found or not executable: \(command)"])
      }
      return path
    }
    let currentDirectoryPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(command).standardizedFileURL.path
    if FileManager.default.isExecutableFile(atPath: currentDirectoryPath) {
      return currentDirectoryPath
    }
    let paths = ProcessInfo.processInfo.environment["PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"].split(separator: ":")
    for directory in paths {
      let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "Command not found: \(command)"])
  }
}

private final class LocalAPIClient {
  private let descriptor: Int32
  private let lock = NSLock()

  private init(descriptor: Int32) { self.descriptor = descriptor }
  deinit { Darwin.close(descriptor) }

  static func connectOrStartServer() throws -> LocalAPIClient {
    if let connected = try? connect() { return connected }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["--nyathing-server"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw CLIError.server(error.localizedDescription) }
    for _ in 0..<50 {
      if let connected = try? connect() { return connected }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw CLIError.server("Unable to connect to the Nyathing server.")
  }

  private static func connect() throws -> LocalAPIClient {
    let path = LocalAPIServer.socketPath
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw posixError() }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { Darwin.close(fd); throw LocalAPIError.socketPathTooLong }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { strlcpy($0, path, capacity) }
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { let error = posixError(); Darwin.close(fd); throw error }
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    return LocalAPIClient(descriptor: fd)
  }

  func command(_ request: [String: String]) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    var data = try JSONSerialization.data(withJSONObject: request)
    data.append(0x0A)
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let count = Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
        if count < 0 { if errno == EINTR { continue }; throw Self.posixError() }
        offset += count
      }
    }
    var response = Data()
    var byte: UInt8 = 0
    while Darwin.recv(descriptor, &byte, 1, 0) == 1 {
      if byte == 0x0A { break }
      response.append(byte)
    }
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      throw CLIError.api("The server returned an invalid response.")
    }
    guard object["ok"] as? Bool == true else {
      throw CLIError.api(object["error"] as? String ?? "The server rejected the request.")
    }
    return object
  }

  private static func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
  }
}
