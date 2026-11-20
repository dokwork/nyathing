import AppKit
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

    XCTAssertNoThrow(try NyathingCLI.validateAnimation("nyan", in: animationsDirectory))
    XCTAssertThrowsError(
      try NyathingCLI.validateAnimation("missing", in: animationsDirectory))

    let externalDirectory = directory.appendingPathComponent("external")
    try FileManager.default.createDirectory(
      at: externalDirectory, withIntermediateDirectories: true)
    let externalAnimation = externalDirectory.appendingPathComponent("outside_54x36.png")
    try FileManager.default.copyItem(
      at: animationsDirectory.appendingPathComponent("nyan_54x36.png"), to: externalAnimation)
    XCTAssertNoThrow(
      try NyathingCLI.validateAnimation(externalAnimation.path, in: animationsDirectory))
    XCTAssertThrowsError(
      try NyathingCLI.validateAnimation(
        externalAnimation.lastPathComponent, in: animationsDirectory))
  }

  func testRandomAnimationSelectsFromAvailableAnimations() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NyathingRandom-\\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try AppConfiguration.load(in: directory)
    let animationsDirectory = directory.appendingPathComponent("animations", isDirectory: true)
    let listedAnimations = Set(SpriteAnimation.loadAll(in: animationsDirectory).keys)

    let selected = try NyathingCLI.resolveAnimation("random", in: animationsDirectory)

    XCTAssertFalse(listedAnimations.isEmpty)
    XCTAssertTrue(listedAnimations.contains(URL(fileURLWithPath: selected).lastPathComponent))
  }

  func testNamedRandomAnimationTakesPrecedence() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NyathingRandom-\\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try AppConfiguration.load(in: directory)
    let animationsDirectory = directory.appendingPathComponent("animations", isDirectory: true)
    let randomAnimation = animationsDirectory.appendingPathComponent("random_36x36.png")
    try FileManager.default.copyItem(
      at: animationsDirectory.appendingPathComponent("nyathing_36x36.png"), to: randomAnimation)

    XCTAssertEqual(
      try NyathingCLI.resolveAnimation("random", in: animationsDirectory),
      randomAnimation.standardizedFileURL.path)
  }

  func testRandomAnimationFallsBackToBuiltInGhostWhenPoolIsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NyathingRandom-\\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let selected = try NyathingCLI.resolveAnimation("random", in: directory)

    XCTAssertEqual(selected, NyathingCLI.builtInGhostAnimation)
    if case .builtInGhost = AnimationResolution.resolve(selected, available: [:]) {
      XCTAssertTrue(true)
    } else {
      XCTFail("An empty random selection pool must resolve to the built-in ghost.")
    }
  }

  func testActivityDescriptionJoinsChildCommandAndArguments() {
    XCTAssertEqual(
      NyathingCLI.activityDescription(command: "./run me", arguments: ["--flag", "a b"]),
      "./run me --flag a b")
    XCTAssertEqual(NyathingCLI.activityDescription(command: "sleep", arguments: []), "sleep")
  }

  func testZshCompletionTracksCLICommandsAndDynamicAnimations() throws {
    let script = try XCTUnwrap(ShellCompletion.script(for: "zsh"))

    for command in documentedCLICommands {
      XCTAssertTrue(script.contains(command))
    }
    XCTAssertTrue(script.contains("nyathing list"))
    XCTAssertTrue(script.contains("start stop status"))
    XCTAssertTrue(script.contains("start keepalive stop"))
    XCTAssertTrue(script.contains("compadd -- zsh bash"))
  }

  func testBashCompletionTracksCLICommandsAndDynamicAnimations() throws {
    let script = try XCTUnwrap(ShellCompletion.script(for: "bash"))

    for command in documentedCLICommands {
      XCTAssertTrue(script.contains(command))
    }
    XCTAssertTrue(script.contains("nyathing list"))
    XCTAssertTrue(script.contains("start stop status"))
    XCTAssertTrue(script.contains("start keepalive stop"))
    XCTAssertTrue(script.contains("zsh bash"))
  }

  func testCompletionRejectsUnsupportedShells() {
    XCTAssertNil(ShellCompletion.script(for: "fish"))
  }

  private var documentedCLICommands: [String] {
    let commandsSection =
      CLIArguments.usage
      .components(separatedBy: "Commands:\n").last?
      .components(separatedBy: "\n\nOptions:").first ?? ""
    return commandsSection.split(separator: "\n").compactMap { line in
      let command = line.split(whereSeparator: \.isWhitespace).first.map(String.init)
      return command == "COMMAND" ? nil : command
    }
  }

  func testHelpAndVersionAreOnlyAvailableAsOptions() throws {
    XCTAssertEqual(try CLIArguments.parse(["help"]).command, "help")
    XCTAssertEqual(try CLIArguments.parse(["version"]).command, "version")
    XCTAssertThrowsError(try CLIArguments.parse([]))
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

  func testResolvesBareArgv0ThroughPathForStartingServer() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NyathingPATH-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("nyathing")
    try Data("#!/bin/sh\\nexit 0\\n".utf8).write(to: executable)
    XCTAssertEqual(chmod(executable.path, 0o755), 0)

    XCTAssertEqual(
      try NyathingCLI.resolveExecutable("nyathing", searchPath: directory.path),
      executable.path)
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
    XCTAssertEqual(configuration.maxWaitTime, 60)
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
  }

  func testMigratesLegacyKeepaliveConfiguration() throws {
    let legacy = AppConfiguration.template.replacingOccurrences(
      of: "max_wait_time = 60",
      with: "keepalive_interval_seconds = 7\nactivity_timeout_seconds = 24")
    try writeConfiguration(legacy)

    let configuration = try AppConfiguration.load(in: temporaryDirectory)

    XCTAssertEqual(configuration.maxWaitTime, 24)
    let saved = try String(
      contentsOf: temporaryDirectory.appendingPathComponent("config.toml"), encoding: .utf8)
    XCTAssertFalse(saved.contains("keepalive_interval_seconds"))
    XCTAssertFalse(saved.contains("activity_timeout_seconds"))
    XCTAssertTrue(saved.contains("max_wait_time = 24"))
  }

  func testRandomIsAcceptedAsDefaultAnimation() throws {
    let configurationText = AppConfiguration.template.replacingOccurrences(
      of: "default_animation = \"nyathing_36x36.png\"",
      with: "default_animation = \"random\"")
    try writeConfiguration(configurationText)

    let configuration = try AppConfiguration.load(in: temporaryDirectory)

    XCTAssertEqual(configuration.defaultAnimation, "random")
  }

  func testLoadsAnimationWithFrameDimensionsFromFilename() throws {
    let url = temporaryDirectory.appendingPathComponent("wide_64x48.png")
    try writePNG(width: 128, height: 48, to: url)

    let animation = try SpriteAnimation.load(from: url)

    XCTAssertEqual(animation.frameSize, NSSize(width: 64, height: 48))
    XCTAssertEqual(animation.frames.count, 2)
  }

  func testShortAnimationNameResolvesLargestValidFrame() throws {
    _ = try AppConfiguration.load(in: temporaryDirectory)
    let animationsDirectory = temporaryDirectory.appendingPathComponent("animations")
    let largerAnimation = animationsDirectory.appendingPathComponent("nyathing_64x48.png")
    try writePNG(width: 128, height: 48, to: largerAnimation)

    XCTAssertEqual(
      try NyathingCLI.resolveAnimation("nyathing", in: animationsDirectory),
      largerAnimation.standardizedFileURL.path)
    XCTAssertEqual(
      try NyathingCLI.resolveAnimation("nyathing", in: animationsDirectory),
      try NyathingCLI.resolveAnimation(largerAnimation.path, in: animationsDirectory))
  }

  func testRejectsFrameDimensionsOutsideSupportedBounds() {
    for filename in ["small_15x36.png", "large_257x36.png", "wide_256x16.png"] {
      XCTAssertThrowsError(
        try SpriteAnimation.load(from: URL(fileURLWithPath: "/tmp/\(filename)")),
        filename)
    }
  }

  func testRejectsOversizedSpriteSheetsAndExcessiveFrameCounts() throws {
    let oversized = temporaryDirectory.appendingPathComponent("large_256x256.png")
    try writePNG(width: 256 * 62, height: 256, to: oversized)
    XCTAssertThrowsError(try SpriteAnimation.load(from: oversized))

    let tooManyFrames = temporaryDirectory.appendingPathComponent("many_16x16.png")
    try writePNG(width: 16 * 121, height: 16, to: tooManyFrames)
    XCTAssertThrowsError(try SpriteAnimation.load(from: tooManyFrames))
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

    XCTAssertEqual(configuration.maxWaitTime, 60)
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
      "max_wait_time = 0\nauto_start = false\n")
    XCTAssertThrowsError(try AppConfiguration.load(in: temporaryDirectory))

    try writeConfiguration(
      AppConfiguration.template.replacingOccurrences(
        of: "max_wait_time = 60", with: "max_wait_time = 0"))
    XCTAssertThrowsError(try AppConfiguration.load(in: temporaryDirectory))
  }

  private func writePNG(width: Int, height: Int, to url: URL) throws {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
      let data = bitmap.representation(using: .png, properties: [:])
    else {
      throw NSError(domain: "ConfigurationTests", code: 1)
    }
    try data.write(to: url)
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
    XCTAssertEqual(
      lifecycle.expire(second, deadline: 40),
      ActivityLifecycle.ExpiredActivity(
        id: second, animation: "same_36x36.png", description: ActivityLifecycle.missingDescription))
    XCTAssertEqual(lifecycle.disconnectedCount, 1)
    XCTAssertEqual(lifecycle.activityCount(for: "same_36x36.png"), 0)
    XCTAssertEqual(
      lifecycle.expire(distinct, deadline: 30),
      ActivityLifecycle.ExpiredActivity(
        id: distinct, animation: "other_36x36.png",
        description: ActivityLifecycle.missingDescription))
    XCTAssertEqual(lifecycle.disconnectedCount, 2)
    XCTAssertEqual(lifecycle.timedOutActivities.count, 2)
  }

  func testDescriptionsAreRetainedThroughTimeoutAndDefaultWhenAbsent() {
    var lifecycle = ActivityLifecycle()
    let described = lifecycle.start(
      animation: "nyathing_36x36.png", description: "build test", deadline: 10)
    let undescribed = lifecycle.start(animation: "nyathing_36x36.png", deadline: 20)

    XCTAssertEqual(lifecycle.description(for: described), "build test")
    XCTAssertEqual(lifecycle.description(for: undescribed), ActivityLifecycle.missingDescription)
    XCTAssertEqual(
      lifecycle.expire(described, deadline: 10),
      ActivityLifecycle.ExpiredActivity(
        id: described, animation: "nyathing_36x36.png", description: "build test"))
    XCTAssertEqual(
      lifecycle.expire(undescribed, deadline: 20),
      ActivityLifecycle.ExpiredActivity(
        id: undescribed, animation: "nyathing_36x36.png",
        description: ActivityLifecycle.missingDescription))
    XCTAssertEqual(
      lifecycle.timedOutActivities.map(\.description),
      [
        "build test", ActivityLifecycle.missingDescription,
      ])
  }

  func testAcknowledgesTimeoutsIndividuallyEvenWhenDescriptionsMatch() {
    var lifecycle = ActivityLifecycle()
    let first = lifecycle.start(animation: "one", description: "same", deadline: 10)
    let second = lifecycle.start(animation: "two", description: "same", deadline: 20)
    _ = lifecycle.expire(first, deadline: 10)
    _ = lifecycle.expire(second, deadline: 20)

    XCTAssertTrue(lifecycle.acknowledgeTimeout(first))
    XCTAssertEqual(lifecycle.timedOutActivities.map(\.id), [second])
    XCTAssertEqual(lifecycle.disconnectedCount, 1)
    XCTAssertFalse(lifecycle.acknowledgeTimeout(first))
    XCTAssertTrue(lifecycle.acknowledgeTimeout(second))
    XCTAssertTrue(lifecycle.timedOutActivities.isEmpty)
    XCTAssertEqual(lifecycle.disconnectedCount, 0)
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
    XCTAssertTrue(lifecycle.timedOutActivities.isEmpty)
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
    var startedDescriptions: [String?] = []
    var startedTimeouts: [Double] = []
    var stoppedIDs: [String] = []
    let server = LocalAPIServer(
      socketPath: socketPath,
      defaultAnimation: "nyan_54x36.png",
      maxWaitTime: 30,
      onStart: { animation, description, timeout in
        lock.lock()
        defer { lock.unlock() }
        startedAnimations.append(animation)
        startedDescriptions.append(description)
        startedTimeouts.append(timeout)
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
    let defaultIntervalStart = try first.command(["command": "start"])
    XCTAssertEqual(defaultIntervalStart["activity_id"] as? String, "activity-1")
    let nonPositiveInterval = try first.command([
      "command": "start", "keepalive_interval_seconds": 0,
    ])
    XCTAssertEqual(nonPositiveInterval["ok"] as? Bool, false)
    XCTAssertTrue(
      (nonPositiveInterval["error"] as? String)?.contains("positive finite number") == true)
    let largeInterval = try first.command([
      "command": "start", "keepalive_interval_seconds": 30,
    ])
    XCTAssertEqual(largeInterval["activity_id"] as? String, "activity-2")
    XCTAssertEqual(startedTimeouts[1], 30)
    let clientTimeoutOverride = try first.command([
      "command": "start", "keepalive_interval_seconds": 5, "activity_timeout_seconds": 10,
    ])
    XCTAssertEqual(clientTimeoutOverride["ok"] as? Bool, false)
    XCTAssertTrue(
      (clientTimeoutOverride["error"] as? String)?.contains("controlled by the server") == true)
    let firstStart = try first.command([
      "command": "start", "animation": "same_36x36.png", "description": "first client",
      "keepalive_interval_seconds": 8,
    ])
    XCTAssertEqual(firstStart["activity_id"] as? String, "activity-3")
    XCTAssertEqual(startedTimeouts[2], 16)
    XCTAssertEqual(
      try first.command(["command": "keepalive", "activity_id": "activity-3"])["ok"] as? Bool,
      true)
    XCTAssertEqual(
      try first.command(["command": "stop", "activity_id": "activity-3"])["ok"] as? Bool, true)

    let second = try UnixJSONClient(path: socketPath)
    let secondStart = try second.command([
      "command": "start", "animation": "same_36x36.png", "keepalive_interval_seconds": 5,
    ])
    XCTAssertEqual(secondStart["activity_id"] as? String, "activity-4")
    XCTAssertEqual(startedTimeouts[3], 10)
    XCTAssertEqual(
      try second.command(["command": "start", "keepalive_interval_seconds": 1])["activity_id"]
        as? String,
      "activity-5")
    lock.lock()
    XCTAssertEqual(
      startedAnimations,
      ["nyan_54x36.png", "nyan_54x36.png", "same_36x36.png", "same_36x36.png", "nyan_54x36.png"])
    XCTAssertEqual(stoppedIDs, ["activity-3"])
    XCTAssertEqual(startedDescriptions, [nil, nil, "first client", nil, nil])
    XCTAssertEqual(startedTimeouts, [10, 30, 16, 10, 2])
    lock.unlock()

    let responseLock = NSLock()
    var concurrentResults: [Bool] = []
    DispatchQueue.concurrentPerform(iterations: 4) { _ in
      let result =
        (try? UnixJSONClient(path: socketPath)
          .command([
            "command": "start", "animation": "other_36x36.png",
            "keepalive_interval_seconds": 5,
          ])["ok"] as? Bool) ?? false
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

  func command(_ request: [String: Any]) throws -> [String: Any] {
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
