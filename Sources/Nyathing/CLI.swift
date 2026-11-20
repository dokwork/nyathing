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

  static var usage: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development build"
    return """
      Nyathing displays playful animations in the macOS menu bar while commands run.

      Version:
        \(version)

      Usage:
        nyathing [--animation NAME | -a NAME] COMMAND [ARGUMENT ...]
        nyathing uninstall
        nyathing server start|stop|status
        nyathing list
        nyathing completion zsh|bash
        nyathing --help
        nyathing --version

      Commands:
        COMMAND [ARGUMENT ...]  Run a command while showing an activity animation.
        uninstall               Remove the installed app and CLI command.
        server                  Manage the background server (start, stop, status).
        list                    List available valid animations.
        completion SHELL        Print shell completion code for zsh or bash.

      Options:
        -a, --animation NAME     Select a short animation name or path to a PNG.
        --help                  Show this help.
        --version               Show the app version.

      Examples:
        nyathing sleep 5
        nyathing --animation nyan make test
      """
  }

  static func parse(_ arguments: [String]) throws -> CLIArguments {
    var values = arguments
    var animation = "nyathing"
    if values.first == "--animation" || values.first == "-a" {
      guard values.count >= 3, !values[1].isEmpty else { throw CLIError.usage }
      animation = values[1]
      values.removeFirst(2)
    }
    guard let command = values.first else { throw CLIError.usage }
    return CLIArguments(
      animation: animation, command: command, arguments: Array(values.dropFirst()))
  }
}

enum CLIError: LocalizedError {
  case usage
  case animationUnavailable(String, String)
  case server(String)
  case api(String)

  var errorDescription: String? {
    switch self {
    case .usage: return CLIArguments.usage
    case .animationUnavailable(let filename, let reason):
      return "Animation '\(filename)' \(reason)"
    case .server(let message), .api(let message): return message
    }
  }
}

enum NyathingCLI {
  static let builtInGhostAnimation = "__built_in_ghost__"

  static func run(_ arguments: [String]) -> Int32 {
    if arguments == ["uninstall"] {
      return NyathingUninstaller.run()
    }
    if arguments.count == 2, arguments[0] == "completion" {
      guard let script = ShellCompletion.script(for: arguments[1]) else {
        FileHandle.standardError.write(Data("Supported shells: zsh, bash\n".utf8))
        return 1
      }
      print(script, terminator: "")
      return 0
    }
    if arguments.isEmpty || arguments == ["--help"] {
      print(CLIArguments.usage)
      return 0
    }
    if arguments == ["--version"] {
      print(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "Development build")
      return 0
    }
    do {
      if arguments.count == 2, arguments[0] == "server" {
        let configurationDirectory = AppConfiguration.configurationDirectory
        switch arguments[1] {
        case "start":
          try LaunchAgentSupport.startServer(in: configurationDirectory)
          print("Nyathing server started in the background.")
          return 0
        case "stop":
          try LaunchAgentSupport.stopServer(in: configurationDirectory)
          print("Nyathing server stopped.")
          return 0
        case "status":
          let running = LaunchAgentSupport.serverIsRunning()
          print(running ? "Nyathing server is running." : "Nyathing server is not running.")
          return running ? 0 : 1
        default:
          throw CLIError.usage
        }
      }
      if arguments == ["list"] {
        _ = try AppConfiguration.load()
        let directory = AppConfiguration.configurationDirectory
          .appendingPathComponent("animations", isDirectory: true)
        for filename in SpriteAnimation.loadAll(in: directory).keys.sorted() {
          print(filename)
        }
        return 0
      }
      let parsed = try CLIArguments.parse(arguments)
      return try execute(parsed)
    } catch {
      FileHandle.standardError.write(Data("nyathing: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private static func execute(_ cli: CLIArguments) throws -> Int32 {
    let executable = try resolveExecutable(cli.command)
    let configuration = try AppConfiguration.load()
    let animationsDirectory = AppConfiguration.configurationDirectory
      .appendingPathComponent("animations", isDirectory: true)
    let animation = try resolveAnimation(cli.animation, in: animationsDirectory)
    let keepaliveInterval = configuration.keepaliveInterval
    let client = try LocalAPIClient.connectOrStartServer()
    let activity = try client.command([
      "command": "start",
      "animation": animation,
      "description": activityDescription(command: cli.command, arguments: cli.arguments),
      "keepalive_interval_seconds": NSNumber(value: keepaliveInterval),
    ])
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
      do { _ = try client.command(["command": "keepalive", "activity_id": activityID]) } catch {
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
    _ = try resolveAnimation(filename, in: directory)
  }

  static func resolveAnimation(_ name: String, in directory: URL) throws -> String {
    if name == "random" {
      if let namedAnimation = try? resolveNamedAnimation(name, in: directory) {
        return namedAnimation
      }
      let available = SpriteAnimation.loadAll(in: directory)
      return available.keys.sorted().randomElement().map {
        directory.appendingPathComponent($0).standardizedFileURL.path
      } ?? builtInGhostAnimation
    }
    if isShortAnimationName(name) {
      return try resolveNamedAnimation(name, in: directory)
    }
    let path = URL(
      fileURLWithPath: (name as NSString).expandingTildeInPath,
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
    do {
      _ = try SpriteAnimation.load(from: path)
      return path.path
    } catch {
      throw CLIError.animationUnavailable(
        name, "could not load animation file: \(error.localizedDescription).")
    }
  }

  private static func isShortAnimationName(_ name: String) -> Bool {
    !name.contains("/") && !name.contains("\\")
      && URL(fileURLWithPath: name).pathExtension.isEmpty
      && name.range(of: #"_[0-9]+x[0-9]+$"#, options: .regularExpression) == nil
  }

  private static func resolveNamedAnimation(_ name: String, in directory: URL) throws -> String {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else {
      throw CLIError.animationUnavailable(
        name,
        "could not be checked because the animations directory is unavailable at \(directory.path)."
      )
    }

    let pattern =
      "^\(NSRegularExpression.escapedPattern(for: name))_([0-9]+)x([0-9]+)\\.png$"
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else {
      throw CLIError.animationUnavailable(name, "could not be resolved to a filename.")
    }
    let candidates = files.compactMap { file -> (url: URL, width: Int, height: Int)? in
      let filename = file.lastPathComponent
      guard
        let match = regex.firstMatch(
          in: filename, range: NSRange(filename.startIndex..., in: filename)),
        let widthRange = Range(match.range(at: 1), in: filename),
        let heightRange = Range(match.range(at: 2), in: filename),
        let width = Int(filename[widthRange]), let height = Int(filename[heightRange])
      else { return nil }
      return (file, width, height)
    }.sorted {
      let leftArea = Double($0.width) * Double($0.height)
      let rightArea = Double($1.width) * Double($1.height)
      if leftArea != rightArea { return leftArea > rightArea }
      if $0.width != $1.width { return $0.width > $1.width }
      return $0.url.lastPathComponent < $1.url.lastPathComponent
    }

    var invalidAssetError: Error?
    for candidate in candidates {
      do {
        _ = try SpriteAnimation.load(from: candidate.url)
        return candidate.url.standardizedFileURL.path
      } catch {
        invalidAssetError = invalidAssetError ?? error
      }
    }
    if let invalidAssetError {
      throw CLIError.animationUnavailable(
        name, "has no valid matching animation: \(invalidAssetError.localizedDescription).")
    }
    throw CLIError.animationUnavailable(
      name,
      "was not found in \(directory.path). Use 'nyathing list' to see available animations."
    )
  }

  static func activityDescription(command: String, arguments: [String]) -> String {
    ([command] + arguments).joined(separator: " ")
  }

  static func resolveExecutable(_ command: String, searchPath: String? = nil) throws -> String {
    if command.contains("/") {
      let path = URL(
        fileURLWithPath: command,
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      ).standardizedFileURL.path
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(ENOENT),
          userInfo: [NSLocalizedDescriptionKey: "Command not found or not executable: \(command)"])
      }
      return path
    }
    let currentDirectoryPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(command).standardizedFileURL.path
    if FileManager.default.isExecutableFile(atPath: currentDirectoryPath) {
      return currentDirectoryPath
    }
    let paths =
      (searchPath
      ?? ProcessInfo.processInfo.environment[
        "PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"
      ]).split(separator: ":")
    for directory in paths {
      let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    throw NSError(
      domain: NSPOSIXErrorDomain, code: Int(ENOENT),
      userInfo: [NSLocalizedDescriptionKey: "Command not found: \(command)"])
  }
}

enum ShellCompletion {
  static let supportedCommands = ["server", "list", "uninstall", "completion"]

  static func script(for shell: String) -> String? {
    let commands = supportedCommands.joined(separator: " ")
    switch shell {
    case "zsh":
      return #"""
        #compdef nyathing

        _nyathing() {
          local -a commands animations
          commands=(\#(commands))

          case "${words[CURRENT-1]}" in
            -a|--animation)
              animations=(random ${(f)"$(nyathing list 2>/dev/null)"})
              compadd -- "${animations[@]}"
              return
              ;;
            server)
              compadd -- start stop status
              return
              ;;
            completion)
              compadd -- zsh bash
              return
              ;;
          esac

          if (( CURRENT == 2 )); then
            compadd -- "${commands[@]}" --animation -a --help --version
          fi
        }

        compdef _nyathing nyathing
        """#
    case "bash":
      return #"""
        _nyathing() {
          local cur prev animations
          COMPREPLY=()
          cur="${COMP_WORDS[COMP_CWORD]}"
          prev="${COMP_WORDS[COMP_CWORD-1]}"

          case "$prev" in
            -a|--animation)
              animations="$(nyathing list 2>/dev/null)"
              COMPREPLY=( $(compgen -W "random $animations" -- "$cur") )
              return
              ;;
            server)
              COMPREPLY=( $(compgen -W "start stop status" -- "$cur") )
              return
              ;;
            completion)
              COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") )
              return
              ;;
          esac

          if (( COMP_CWORD == 1 )); then
            COMPREPLY=( $(compgen -W "\#(commands)" -- "$cur") )
            COMPREPLY+=( $(compgen -W "--animation -a --help --version" -- "$cur") )
          fi
        }
        complete -F _nyathing nyathing
        """#
    default:
      return nil
    }
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
    let executable = try NyathingCLI.resolveExecutable(CommandLine.arguments[0])
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [LaunchAgentSupport.serverArgument]
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
    guard path.utf8.count < capacity else {
      Darwin.close(fd)
      throw LocalAPIError.socketPathTooLong
    }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { strlcpy($0, path, capacity) }
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let error = posixError()
      Darwin.close(fd)
      throw error
    }
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    return LocalAPIClient(descriptor: fd)
  }

  func command(_ request: [String: Any]) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    var data = try JSONSerialization.data(withJSONObject: request)
    data.append(0x0A)
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let count = Darwin.send(
          descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
        if count < 0 {
          if errno == EINTR { continue }
          throw Self.posixError()
        }
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
    NSError(
      domain: NSPOSIXErrorDomain, code: Int(errno),
      userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
  }
}
