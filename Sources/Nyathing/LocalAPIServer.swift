import Darwin
import Foundation

/// Serves the local JSON Lines API over a current-user Unix domain socket.
final class LocalAPIServer {
  private let defaultAnimation: String
  private let onStart: (String) throws -> String
  private let onKeepalive: (String) throws -> Void
  private let onStop: (String) throws -> Void
  private let socketPath: String
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var clients: Set<Int32> = []
  private var stopped = true

  init(
    socketPath: String = LocalAPIServer.socketPath,
    defaultAnimation: String = "nyathing_36x36.png",
    onStart: @escaping (String) throws -> String,
    onKeepalive: @escaping (String) throws -> Void,
    onStop: @escaping (String) throws -> Void
  ) {
    self.defaultAnimation = defaultAnimation
    self.onStart = onStart
    self.onKeepalive = onKeepalive
    self.onStop = onStop
    self.socketPath = socketPath
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
          _ = writeResponse(["ok": false, "error": "Request line is too large."], to: client)
          return
        }
        guard writeResponse(handle(line), to: client) else { return }
      }
      if pending.count > 1_048_576 {
        _ = writeResponse(["ok": false, "error": "Request line is too large."], to: client)
        return
      }
    }
  }

  private func handle(_ line: Data) -> [String: Any] {
    guard isRunning else {
      return ["ok": false, "error": LocalAPIError.unavailable.localizedDescription]
    }
    do {
      guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any],
        let command = request["command"] as? String
      else {
        throw LocalAPIError.invalidRequest
      }
      switch command {
      case "start":
        let animation = request["animation"] as? String ?? defaultAnimation
        guard !animation.isEmpty else { throw LocalAPIError.invalidRequest }
        return ["ok": true, "activity_id": try onStart(animation)]
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
    } catch {
      return ["ok": false, "error": error.localizedDescription]
    }
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
  case unknownCommand(String)
  case unknownActivity
  case socketPathTooLong
  case alreadyRunning(String)
  case unsafeSocketPath(String)

  var errorDescription: String? {
    switch self {
    case .unavailable: return "The local API is unavailable."
    case .invalidRequest: return "Invalid JSON Lines request."
    case .unknownCommand(let command): return "Unknown command: \(command)."
    case .unknownActivity: return "Unknown activity ID."
    case .socketPathTooLong: return "The local API socket path is too long."
    case .alreadyRunning(let path): return "Another Nyathing instance is listening at \(path)."
    case .unsafeSocketPath(let path):
      return "Refusing to replace a non-owned or non-socket path: \(path)."
    }
  }
}
