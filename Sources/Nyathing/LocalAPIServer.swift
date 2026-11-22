import Darwin
import Foundation

/// Serves the local JSON Lines API over a current-user Unix domain socket.
final class LocalAPIServer {
  static let defaultKeepaliveInterval: TimeInterval = 5
  private var defaultAnimation: () throws -> String
  private var maxWaitTime: TimeInterval
  private let onStart: (String, String?, String?, TimeInterval, Bool, TimeInterval) throws -> String
  private let onKeepalive: (String) throws -> Void
  private let onStop: (String) throws -> Void
  private let socketPath: String
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var clients: Set<Int32> = []
  private var stopped = true

  init(
    socketPath: String = LocalAPIServer.socketPath,
    defaultAnimation: @escaping () throws -> String = { "nyathing_36x36.png" },
    maxWaitTime: TimeInterval = 180,
    onStart:
      @escaping (String, String?, String?, TimeInterval, Bool, TimeInterval) throws -> String,
    onKeepalive: @escaping (String) throws -> Void,
    onStop: @escaping (String) throws -> Void
  ) {
    self.defaultAnimation = defaultAnimation
    self.maxWaitTime = maxWaitTime
    self.onStart = onStart
    self.onKeepalive = onKeepalive
    self.onStop = onStop
    self.socketPath = socketPath
  }

  /// Updates the settings for future starts without disconnecting existing clients.
  func updateStartSettings(
    defaultAnimation: @escaping () throws -> String, maxWaitTime: TimeInterval
  ) {
    lock.lock()
    defer { lock.unlock() }
    self.defaultAnimation = defaultAnimation
    self.maxWaitTime = maxWaitTime
  }

  private func startSettings() -> (defaultAnimation: () throws -> String, maxWaitTime: TimeInterval)
  {
    lock.lock()
    defer { lock.unlock() }
    return (defaultAnimation, maxWaitTime)
  }

  deinit { stop() }

  static var socketPath: String {
    let environment = ProcessInfo.processInfo.environment
    if let runtimeDirectory = environment["XDG_RUNTIME_DIR"], !runtimeDirectory.isEmpty {
      return URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
        .appendingPathComponent("nyathing.sock").path
    }
    let temporaryDirectory = environment["TMPDIR"] ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
      .appendingPathComponent("nyathing-\(getuid()).sock").path
  }

  func start() throws {
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw LocalAPIError.socketPathTooLong
    }
    try removeStaleSocketIfNeeded()
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Self.posixError() }
    var boundSocket = false
    do {
      var address = try Self.address(for: socketPath)
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard result == 0 else { throw Self.posixError() }
      boundSocket = true
      guard chmod(socketPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
        throw Self.posixError()
      }
      guard Darwin.listen(fd, 16) == 0 else { throw Self.posixError() }
      lock.lock()
      listener = fd
      stopped = false
      lock.unlock()
    } catch {
      Darwin.close(fd)
      if boundSocket {
        var info = stat()
        if lstat(socketPath, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid()
        {
          _ = unlink(socketPath)
        }
      }
      throw error
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.acceptConnections(on: fd)
    }
  }

  func stop() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    let fd = listener
    listener = -1
    for client in clients {
      _ = Darwin.shutdown(client, SHUT_RDWR)
    }
    lock.unlock()
    if fd >= 0 {
      _ = Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
    }
    var info = stat()
    if lstat(socketPath, &info) == 0,
      info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK
    {
      _ = unlink(socketPath)
    }
  }

  private func removeStaleSocketIfNeeded() throws {
    guard access(socketPath, F_OK) == 0 else { return }
    let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else { throw Self.posixError() }
    var address = try Self.address(for: socketPath)
    var result: Int32
    repeat {
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    } while result < 0 && errno == EINTR
    let probeError = result == 0 ? nil : errno
    Darwin.close(probe)
    if result == 0 { throw LocalAPIError.alreadyRunning(socketPath) }
    guard probeError == ECONNREFUSED else {
      throw Self.posixError(code: probeError ?? EIO)
    }

    var info = stat()
    guard lstat(socketPath, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFSOCK,
      info.st_uid == getuid()
    else {
      throw LocalAPIError.unsafeSocketPath(socketPath)
    }
    guard unlink(socketPath) == 0 else { throw Self.posixError() }
  }

  private func acceptConnections(on fd: Int32) {
    while true {
      let client = Darwin.accept(fd, nil, nil)
      if client < 0 {
        lock.lock()
        let shouldStop = stopped
        lock.unlock()
        if shouldStop || errno == EBADF || errno == EINVAL { return }
        if errno == EINTR { continue }
        NyathingLog.write(
          "Unable to accept local API connection: \(Self.posixError().localizedDescription)")
        continue
      }
      lock.lock()
      let shouldServe = !stopped
      if shouldServe { clients.insert(client) }
      lock.unlock()
      guard shouldServe else {
        _ = Darwin.shutdown(client, SHUT_RDWR)
        Darwin.close(client)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        self.serve(client)
      }
    }
  }

  private func serve(_ client: Int32) {
    defer {
      lock.lock()
      clients.remove(client)
      lock.unlock()
      Darwin.close(client)
    }
    var noSignal: Int32 = 1
    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var userID: uid_t = 0
    var groupID: gid_t = 0
    guard getpeereid(client, &userID, &groupID) == 0, userID == getuid() else {
      return
    }

    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = recv(client, &buffer, buffer.count, 0)
      guard count > 0 else { return }
      pending.append(contentsOf: buffer[..<count])
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = Data(pending[..<newline])
        pending.removeSubrange(...newline)
        guard line.count <= 1_048_576 else {
          _ = writeResponse(errorResponse(.requestTooLarge), to: client)
          return
        }
        guard writeResponse(handle(line), to: client) else { return }
      }
      if pending.count > 1_048_576 {
        _ = writeResponse(errorResponse(.requestTooLarge), to: client)
        return
      }
    }
  }

  private func handle(_ line: Data) -> [String: Any] {
    guard isRunning else {
      return errorResponse(.unavailable)
    }
    do {
      guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
        let command = request["command"] as? String
      else {
        throw LocalAPIError.invalidRequest
      }
      switch command {
      case "start":
        let settings = startSettings()
        let animation: String
        if let explicit = request["animation"] {
          guard let value = explicit as? String, !value.isEmpty else {
            throw LocalAPIError.invalidRequest
          }
          animation = value
        } else {
          do {
            animation = try settings.defaultAnimation()
          } catch {
            throw LocalAPIError.invalidDefaultAnimation(error.localizedDescription)
          }
        }
        let requestedActivityID = request["activity_id"] as? String
        if request["activity_id"] != nil && (requestedActivityID?.isEmpty ?? true) {
          throw LocalAPIError.invalidRequest
        }
        let keepaliveIntervalWasProvided = request["keepalive_interval_seconds"] != nil
        let keepaliveInterval: TimeInterval
        if let rawKeepaliveInterval = request["keepalive_interval_seconds"] {
          keepaliveInterval = try positiveSeconds(rawKeepaliveInterval)
        } else {
          keepaliveInterval = Self.defaultKeepaliveInterval
        }
        let activityTimeout = min(keepaliveInterval * 2, settings.maxWaitTime)
        return [
          "ok": true,
          "activity_id": try onStart(
            animation, request["description"] as? String, requestedActivityID, keepaliveInterval,
            keepaliveIntervalWasProvided, activityTimeout),
        ]
      case "keepalive":
        guard let activityID = request["activity_id"] as? String, !activityID.isEmpty else {
          throw LocalAPIError.invalidRequest
        }
        try onKeepalive(activityID)
        return ["ok": true]
      case "stop":
        guard let activityID = request["activity_id"] as? String, !activityID.isEmpty else {
          throw LocalAPIError.invalidRequest
        }
        try onStop(activityID)
        return ["ok": true]
      default:
        throw LocalAPIError.unknownCommand(command)
      }
    } catch let error as LocalAPIError {
      return errorResponse(error)
    } catch CLIError.animationUnavailable(let filename, let reason) {
      return errorResponse(.animationUnavailable("Animation '\(filename)' \(reason)"))
    } catch let error as AnimationError {
      return errorResponse(.animationUnavailable(error.localizedDescription))
    } catch {
      return errorResponse(.internalError)
    }
  }

  private func errorResponse(_ error: LocalAPIError) -> [String: Any] {
    let error = error.protocolCode == nil ? .internalError : error
    return [
      "ok": false, "error_code": error.protocolCode ?? "internal_error",
      "error": error.localizedDescription,
    ]
  }

  @discardableResult
  private func writeResponse(_ response: [String: Any], to fd: Int32) -> Bool {
    guard var data = try? JSONSerialization.data(withJSONObject: response) else { return false }
    data.append(0x0A)
    return data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return false }
      var written = 0
      while written < rawBuffer.count {
        let count = send(fd, baseAddress.advanced(by: written), rawBuffer.count - written, 0)
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        written += count
      }
      return true
    }
  }

  private func positiveSeconds(_ value: Any) throws -> TimeInterval {
    guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0
    else {
      throw LocalAPIError.invalidKeepaliveInterval
    }
    return number.doubleValue
  }

  private var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !stopped
  }

  private static func address(for path: String) throws -> sockaddr_un {
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw LocalAPIError.socketPathTooLong
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
      pathPointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
        _ = path.withCString { source in
          strlcpy(destination, source, pathCapacity)
        }
      }
    }
    return address
  }

  private static func posixError(code: Int32? = nil) -> NSError {
    let errorCode = code ?? errno
    return NSError(
      domain: NSPOSIXErrorDomain, code: Int(errorCode),
      userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))])
  }
}

enum LocalAPIError: LocalizedError {
  case unavailable
  case invalidRequest
  case invalidKeepaliveInterval
  case unknownCommand(String)
  case unknownActivity
  case animationCancelled
  case requestTooLarge
  case invalidDefaultAnimation(String)
  case animationUnavailable(String)
  case internalError
  case activityIDInUse(String)
  case socketPathTooLong
  case alreadyRunning(String)
  case unsafeSocketPath(String)

  /// Stable wire identifier for request failures; transport setup errors have no code.
  var protocolCode: String? {
    switch self {
    case .unavailable: return "server_unavailable"
    case .invalidRequest: return "invalid_request"
    case .invalidKeepaliveInterval: return "invalid_keepalive_interval"
    case .unknownCommand: return "unknown_command"
    case .unknownActivity: return "unknown_activity"
    case .animationCancelled: return "animation_cancelled"
    case .activityIDInUse: return "activity_id_in_use"
    case .requestTooLarge: return "request_too_large"
    case .invalidDefaultAnimation: return "invalid_default_animation"
    case .animationUnavailable: return "animation_unavailable"
    case .internalError: return "internal_error"
    case .socketPathTooLong, .alreadyRunning, .unsafeSocketPath: return nil
    }
  }

  var errorDescription: String? {
    switch self {
    case .unavailable: return "The local API is unavailable."
    case .invalidRequest: return "Invalid JSON Lines request."
    case .invalidKeepaliveInterval:
      return "'keepalive_interval_seconds' must be a positive finite number of seconds."
    case .unknownCommand(let command): return "Unknown command: \(command)."
    case .unknownActivity: return "Unknown activity ID."
    case .animationCancelled: return "Animation was cancelled."
    case .requestTooLarge: return "Request line is too large."
    case .invalidDefaultAnimation(let reason): return "Cannot use the default animation: \(reason)"
    case .animationUnavailable(let reason): return "Cannot load the animation: \(reason)"
    case .internalError: return "An internal server error occurred."
    case .activityIDInUse(let id): return "Activity ID \"\(id)\" is already in use."
    case .socketPathTooLong: return "The local API socket path is too long."
    case .alreadyRunning(let path): return "Another Nyathing instance is listening at \(path)."
    case .unsafeSocketPath(let path):
      return "Refusing to replace a non-owned or non-socket path: \(path)."
    }
  }
}
