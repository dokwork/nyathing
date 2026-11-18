import Darwin
import Foundation
import XCTest

@testable import Nyathing

final class CLITests: XCTestCase {
  func testParsesAnimationOptionsAndPreservesChildArguments() throws {
    let long = try XCTUnwrap(
      CLIArguments.parse(["--animation", "nyan image.png", "./run me", "a b"]))
    XCTAssertEqual(long.animation, "nyan image.png")
    XCTAssertEqual(long.command, "./run me")
    XCTAssertEqual(long.arguments, ["a b"])

    let short = try XCTUnwrap(CLIArguments.parse(["-a", "matrix.png", "echo", "hello"]))
    XCTAssertEqual(short.animation, "matrix.png")
    XCTAssertEqual(short.command, "echo")
    XCTAssertEqual(short.arguments, ["hello"])

    let dashedCommand = try XCTUnwrap(
      CLIArguments.parse(["-a", "matrix.png", "-tool", "--child-option"]))
    XCTAssertEqual(dashedCommand.command, "-tool")
    XCTAssertEqual(dashedCommand.arguments, ["--child-option"])
  }

  func testRejectsMissingCommandOrAnimationValue() {
    XCTAssertThrowsError(try CLIArguments.parse([]))
    XCTAssertThrowsError(try CLIArguments.parse(["-a", "animation.png"]))
    XCTAssertThrowsError(try CLIArguments.parse(["--animation"]))
    XCTAssertThrowsError(try CLIArguments.parse(["--animation", "", "echo"]))
  }

  func testPathsWithSpacesRemainSingleCommandAndAnimationValues() throws {
    let parsed = try XCTUnwrap(
      CLIArguments.parse(["--animation", "my animations/nyan cat.png", "./some folder/run me"]))
    XCTAssertEqual(parsed.animation, "my animations/nyan cat.png")
    XCTAssertEqual(parsed.command, "./some folder/run me")
    XCTAssertTrue(parsed.arguments.isEmpty)
  }

  func testRejectsUnavailableRequestedAnimation() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NyathingAnimation-\\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try AppConfiguration.load(in: directory)
    let animationsDirectory = directory.appendingPathComponent("animations", isDirectory: true)

    XCTAssertNoThrow(try NyathingCLI.validateAnimation("nyan_54x36.png", in: animationsDirectory))
    XCTAssertThrowsError(
      try NyathingCLI.validateAnimation("missing_36x36.png", in: animationsDirectory))
    XCTAssertThrowsError(
      try NyathingCLI.validateAnimation("../nyan_54x36.png", in: animationsDirectory))
  }

  func testKeepaliveIntervalPrecedesConfiguredActivityTimeout() {
    let configuration = AppConfiguration(
      keepaliveInterval: 5, activityTimeout: 0.8, autoStart: false,
      defaultAnimation: "nyathing_36x36.png")
    XCTAssertEqual(NyathingCLI.keepaliveInterval(for: configuration), 0.4, accuracy: 0.0001)

    let shorterConfiguredInterval = AppConfiguration(
      keepaliveInterval: 0.2, activityTimeout: 3, autoStart: false,
      defaultAnimation: "nyathing_36x36.png")
    XCTAssertEqual(NyathingCLI.keepaliveInterval(for: shorterConfiguredInterval), 0.2)
  }

  func testHelpAndVersionParseAsCommandsAndOptions() throws {
    XCTAssertNil(try CLIArguments.parse(["help"]))
    XCTAssertNil(try CLIArguments.parse(["version"]))
    XCTAssertNil(try CLIArguments.parse(["--help"]))
    XCTAssertNil(try CLIArguments.parse(["--version"]))
  }

  func testBareRelativeExecutableResolvesFromCurrentDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NyathingCLI-\\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let previousDirectory = FileManager.default.currentDirectoryPath
    XCTAssertEqual(chdir(directory.path), 0)
    defer { _ = chdir(previousDirectory) }

    let name = "run-me-\\(UUID().uuidString)"
    let executable = directory.appendingPathComponent(name)
    try Data("#!/bin/sh\\nexit 0\\n".utf8).write(to: executable)
    XCTAssertEqual(chmod(executable.path, 0o755), 0)

    XCTAssertEqual(try NyathingCLI.resolveExecutable(name), executable.path)
  }
}

final class ConfigurationTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NyathingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  func testFirstLaunchSeedsConfigurationAndSampleAnimation() throws {
    let configuration = try AppConfiguration.load(in: temporaryDirectory)
    XCTAssertEqual(configuration.keepaliveInterval, 5)
    XCTAssertEqual(configuration.defaultAnimation, "nyathing_36x36.png")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: temporaryDirectory.appendingPathComponent("config.toml").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          temporaryDirectory
          .appendingPathComponent("animations/nyathing_36x36.png").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          temporaryDirectory
          .appendingPathComponent("animations/nyan_54x36.png").path))
    let nyan = try SpriteAnimation.load(
      from:
        temporaryDirectory
        .appendingPathComponent("animations/nyan_54x36.png"))
    XCTAssertEqual(nyan.frameSize, NSSize(width: 54, height: 36))
    XCTAssertEqual(nyan.frames.count, 8)
    let matrixURL = temporaryDirectory.appendingPathComponent("animations/matrix_36x36.png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: matrixURL.path))
    let matrix = try SpriteAnimation.load(from: matrixURL)
    XCTAssertEqual(matrix.frameSize, NSSize(width: 36, height: 36))
    XCTAssertEqual(matrix.frames.count, 16)
    let explosionURL = temporaryDirectory.appendingPathComponent("animations/explosion_36x36.png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: explosionURL.path))
    let explosion = try SpriteAnimation.load(from: explosionURL)
    XCTAssertEqual(explosion.frameSize, NSSize(width: 36, height: 36))
    XCTAssertEqual(explosion.frames.count, 16)
  }

  func testRemovesObsoleteIconSettingAndKeepsDefaultAnimation() throws {
    let oldTemplate = AppConfiguration.template
      .replacingOccurrences(
        of: "default_animation = \"nyathing_36x36.png\"",
        with: "default_animation = \"ghost_36x36.png\""
      )
      .replacingOccurrences(
        of: "auto_start = false", with: "auto_start = false\nanimate_icon = false")
    try writeConfiguration(oldTemplate)

    let configuration = try AppConfiguration.load(in: temporaryDirectory)

    XCTAssertEqual(configuration.keepaliveInterval, 5)
    XCTAssertEqual(configuration.activityTimeout, 5)
    XCTAssertFalse(configuration.autoStart)
    let savedConfig = try String(
      contentsOf: temporaryDirectory.appendingPathComponent("config.toml"), encoding: .utf8)
    XCTAssertFalse(savedConfig.contains("animate_icon"))
    XCTAssertTrue(savedConfig.contains("default_animation = \"nyathing_36x36.png\""))
  }

  func testAnimationResolutionUsesAssetOrBuiltInGhost() throws {
    let animation = try SpriteAnimation.load(from: Self.ghostFixture)
    let available = [animation.filename: animation]
    if case .asset(let selected) = AnimationResolution.resolve(
      animation.filename, available: available)
    {
      XCTAssertEqual(selected.filename, animation.filename)
    } else {
      XCTFail("A validated requested animation should use its asset.")
    }
    if case .builtInGhost = AnimationResolution.resolve("missing_36x36.png", available: available) {
      XCTAssertTrue(true)
    } else {
      XCTFail("An unavailable animation must resolve to the built-in ghost.")
    }
  }

  func testRejectsMissingAndNonPositiveSettings() throws {
    try writeConfiguration(
      "keepalive_interval_seconds = 5\nactivity_timeout_seconds = 5\nauto_start = false\n")
    XCTAssertThrowsError(try AppConfiguration.load(in: temporaryDirectory))

    try writeConfiguration(
      AppConfiguration.template.replacingOccurrences(
        of: "activity_timeout_seconds = 5", with: "activity_timeout_seconds = 0"))
    XCTAssertThrowsError(try AppConfiguration.load(in: temporaryDirectory))
  }

  private func writeConfiguration(_ contents: String) throws {
    try FileManager.default.createDirectory(
      at: temporaryDirectory.appendingPathComponent("animations"),
      withIntermediateDirectories: true)
    try contents.write(
      to: temporaryDirectory.appendingPathComponent("config.toml"),
      atomically: true, encoding: .utf8)
  }

  private static var ghostFixture: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../Sources/Nyathing/Resources/nyathing_36x36.png")
      .standardizedFileURL
  }
}

final class ActivityLifecycleTests: XCTestCase {
  func testAggregatesActivitiesAndDistinguishesExplicitStopFromTimeout() throws {
    var lifecycle = ActivityLifecycle()
    let first = lifecycle.start(animation: "same_36x36.png", deadline: 10)
    let second = lifecycle.start(animation: "same_36x36.png", deadline: 20)
    let distinct = lifecycle.start(animation: "other_36x36.png", deadline: 30)

    XCTAssertEqual(lifecycle.activityCount(for: "same_36x36.png"), 2)
    XCTAssertEqual(lifecycle.activityCount(for: "other_36x36.png"), 1)
    XCTAssertEqual(lifecycle.stop(first), "same_36x36.png")
    XCTAssertEqual(lifecycle.disconnectedCount, 0)
    XCTAssertEqual(lifecycle.activityCount(for: "same_36x36.png"), 1)

    XCTAssertTrue(lifecycle.keepalive(second, deadline: 40))
    XCTAssertNil(
      lifecycle.expire(second, deadline: 20),
      "An obsolete timeout must not expire a renewed activity.")
    XCTAssertEqual(lifecycle.expire(second, deadline: 40), "same_36x36.png")
    XCTAssertEqual(lifecycle.disconnectedCount, 1)
    XCTAssertEqual(lifecycle.activityCount(for: "same_36x36.png"), 0)
    XCTAssertEqual(lifecycle.expire(distinct, deadline: 30), "other_36x36.png")
    XCTAssertEqual(lifecycle.disconnectedCount, 2)
  }

  func testResetClearsActivitiesDeadlinesAndDisconnectCount() throws {
    var lifecycle = ActivityLifecycle()
    let id = lifecycle.start(animation: "nyathing_36x36.png", deadline: 10)
    _ = lifecycle.expire(id, deadline: 10)
    XCTAssertEqual(lifecycle.disconnectedCount, 1)

    let activeID = lifecycle.start(animation: "same_36x36.png", deadline: 20)
    lifecycle.reset()

    XCTAssertEqual(lifecycle.disconnectedCount, 0)
    XCTAssertNil(lifecycle.animation(for: activeID))
    XCTAssertNil(lifecycle.deadline(for: activeID))
    XCTAssertEqual(lifecycle.activityCount(for: "same_36x36.png"), 0)
  }
}

final class LocalAPIServerTests: XCTestCase {
  func testMultipleCommandsOnConnectionAndConcurrentClients() throws {
    let directory = URL(
      fileURLWithPath: "/tmp/nyathing-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketPath = directory.appendingPathComponent("api.sock").path
    let lock = NSLock()
    var startedAnimations: [String] = []
    var stoppedIDs: [String] = []
    let server = LocalAPIServer(
      socketPath: socketPath,
      defaultAnimation: "nyan_54x36.png",
      onStart: { animation in
        lock.lock()
        defer { lock.unlock() }
        startedAnimations.append(animation)
        return "activity-\(startedAnimations.count)"
      }, onKeepalive: { _ in },
      onStop: { id in
        lock.lock()
        defer { lock.unlock() }
        stoppedIDs.append(id)
      })
    try server.start()
    defer { server.stop() }

    let first = try UnixJSONClient(path: socketPath)
    XCTAssertEqual(
      try first.command(["command": "start", "animation": "same_36x36.png"])["activity_id"]
        as? String,
      "activity-1")
    XCTAssertEqual(
      try first.command(["command": "keepalive", "activity_id": "activity-1"])["ok"] as? Bool,
      true)
    XCTAssertEqual(
      try first.command(["command": "stop", "activity_id": "activity-1"])["ok"] as? Bool, true)

    let second = try UnixJSONClient(path: socketPath)
    XCTAssertEqual(
      try second.command(["command": "start", "animation": "same_36x36.png"])["activity_id"]
        as? String,
      "activity-2")
    XCTAssertEqual(
      try second.command(["command": "start"])["activity_id"] as? String,
      "activity-3")
    lock.lock()
    XCTAssertEqual(
      startedAnimations, ["same_36x36.png", "same_36x36.png", "nyan_54x36.png"])
    XCTAssertEqual(stoppedIDs, ["activity-1"])
    lock.unlock()

    let responseLock = NSLock()
    var concurrentResults: [Bool] = []
    DispatchQueue.concurrentPerform(iterations: 4) { _ in
      let result =
        (try? UnixJSONClient(path: socketPath)
          .command(["command": "start", "animation": "other_36x36.png"])["ok"] as? Bool) ?? false
      responseLock.lock()
      concurrentResults.append(result)
      responseLock.unlock()
    }
    responseLock.lock()
    XCTAssertEqual(concurrentResults.count, 4)
    XCTAssertTrue(concurrentResults.allSatisfy { $0 })
    responseLock.unlock()
  }
}

private final class UnixJSONClient {
  private let descriptor: Int32

  init(path: String) throws {
    descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
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
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  deinit { Darwin.close(descriptor) }

  func command(_ request: [String: String]) throws -> [String: Any] {
    var data = try JSONSerialization.data(withJSONObject: request)
    data.append(0x0A)
    let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
    guard written == data.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var response = Data()
    var byte: UInt8 = 0
    while Darwin.read(descriptor, &byte, 1) == 1 {
      if byte == 0x0A { break }
      response.append(byte)
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
  }
}
