import AppKit
import Foundation
import ImageIO

struct AppConfiguration {
  let maxWaitTime: TimeInterval
  let autoStart: Bool
  private let defaultAnimationValues: [String]
  private let directory: URL

  var defaultAnimation: String {
    get throws {
      guard defaultAnimationValues.count == 1,
        let rawAnimation = defaultAnimationValues.first,
        let value = try? JSONDecoder().decode(String.self, from: Data(rawAnimation.utf8)),
        !value.isEmpty
      else { throw ConfigError.invalidValue("default_animation") }
      return value
    }
  }

  var resolvedDefaultAnimation: String {
    get throws {
      let value = try defaultAnimation
      do {
        return try Self.resolveDefaultAnimation(value, in: directory)
      } catch {
        throw ConfigError.invalidDefaultAnimation(error.localizedDescription)
      }
    }
  }

  static let template = """
    # Maximum seconds to wait since the last client keepalive.
    max_wait_time = 180
    # Whether Nyathing should launch automatically when you log in.
    auto_start = false
    # Animation name, PNG path, or "random" used when a client omits the animation field.
    default_animation = "nyathing"
    """

  static var configurationDirectory: URL {
    let base: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      base = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
      base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
    }
    return base.appendingPathComponent("nyathing", isDirectory: true)
  }

  private static func stripComment(from line: Substring) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
        continue
      }
      if quote == "\"", character == "\\" {
        escaped = true
        continue
      }
      if let activeQuote = quote {
        if character == activeQuote { quote = nil }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == "#" {
        return String(line[..<index])
      }
    }
    return String(line)
  }

  static func prepareDirectory(_ directory: URL) throws {
    let configURL = directory.appendingPathComponent("config.toml")
    let animationsDirectory = directory.appendingPathComponent("animations", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: animationsDirectory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: configURL.path) {
      try template.write(to: configURL, atomically: true, encoding: .utf8)
    }
    if let bundledResources = BundledResources.bundle.resourceURL {
      let bundledAnimations = try FileManager.default.contentsOfDirectory(
        at: bundledResources, includingPropertiesForKeys: nil)
      for bundled in bundledAnimations where bundled.pathExtension.lowercased() == "png" {
        guard (try? SpriteAnimation.load(from: bundled)) != nil else { continue }
        let destination = animationsDirectory.appendingPathComponent(bundled.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.copyItem(at: bundled, to: destination)
        }
      }
    }
  }

  static func load(
    in directory: URL = configurationDirectory, validateDefaultAnimation: Bool = true
  ) throws -> AppConfiguration {
    try prepareDirectory(directory)
    let configURL = directory.appendingPathComponent("config.toml")
    var text = try String(contentsOf: configURL, encoding: .utf8)
    var removedObsoleteSettings = false
    var legacyMaxWaitTime: String?
    let obsoleteComments = [
      "# Animate the app's icon instead of showing the static project logo.",
      "# Animate the app's main icon instead of showing the static logo.",
    ]
    let retainedLines = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
      rawLine -> String? in
      let original = String(rawLine)
      if obsoleteComments.contains(original.trimmingCharacters(in: .whitespaces)) {
        removedObsoleteSettings = true
        return nil
      }
      let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespaces)
      guard let equal = line.firstIndex(of: "=") else { return original }
      let key = line[..<equal].trimmingCharacters(in: .whitespaces)
      if key == "keepalive_interval_seconds" {
        removedObsoleteSettings = true
        if legacyMaxWaitTime == nil { legacyMaxWaitTime = "180" }
        return nil
      }
      if key == "animate_icon" {
        removedObsoleteSettings = true
        return nil
      }
      if key == "default_animation",
        line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
          == "\"ghost_36x36.png\""
      {
        removedObsoleteSettings = true
        return "\(original[..<equal])= \"nyathing_36x36.png\""
      }
      return original
    }
    if removedObsoleteSettings {
      text = retainedLines.joined(separator: "\n")
      if let legacyMaxWaitTime,
        !text.split(separator: "\n").contains(where: {
          stripComment(from: $0).trimmingCharacters(in: .whitespaces).hasPrefix("max_wait_time")
        })
      {
        text += "\nmax_wait_time = \(legacyMaxWaitTime)\n"
      }
      try text.write(to: configURL, atomically: true, encoding: .utf8)
    }
    var values: [String: String] = [:]
    var defaultAnimationValues: [String] = []
    for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      guard let equal = line.firstIndex(of: "=") else {
        throw ConfigError.invalidLine(offset + 1)
      }
      let key = line[..<equal].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
      if key == "default_animation" {
        defaultAnimationValues.append(value)
        continue
      }
      guard ["max_wait_time", "auto_start"].contains(key), values[key] == nil else {
        throw ConfigError.invalidKey(key, offset + 1)
      }
      values[key] = value
    }
    func number(_ key: String) throws -> Double {
      let decimal =
        #"^[+-]?(?:0|[1-9](?:_?[0-9])*)(?:(?:\.[0-9](?:_?[0-9])*)(?:[eE][+-]?[0-9](?:_?[0-9])*)?|[eE][+-]?[0-9](?:_?[0-9])*)?$"#
      guard let raw = values[key], raw.range(of: decimal, options: .regularExpression) != nil,
        let value = Double(raw.replacingOccurrences(of: "_", with: "")),
        value.isFinite, value > 0
      else {
        throw ConfigError.invalidValue(key)
      }
      return value
    }
    guard let rawAuto = values["auto_start"], rawAuto == "true" || rawAuto == "false" else {
      throw ConfigError.invalidValue("auto_start")
    }
    let configuration = AppConfiguration(
      maxWaitTime: try number("max_wait_time"),
      autoStart: rawAuto == "true",
      defaultAnimationValues: defaultAnimationValues,
      directory: directory)
    if validateDefaultAnimation { _ = try configuration.resolvedDefaultAnimation }
    return configuration
  }

  static func resolveDefaultAnimation(_ value: String, in directory: URL) throws -> String {
    // Keep random selection deferred until a client starts an activity.
    if value == "random" { return value }
    return try NyathingCLI.resolveAnimation(
      value, in: directory.appendingPathComponent("animations", isDirectory: true),
      relativeTo: directory)
  }
}

enum ConfigError: LocalizedError {
  case invalidLine(Int)
  case invalidKey(String, Int)
  case invalidValue(String)
  case invalidDefaultAnimation(String)

  var errorDescription: String? {
    switch self {
    case .invalidLine(let line):
      return
        "Invalid config.toml line \(line). Write each setting as key = value, or remove the line."
    case .invalidKey(let key, let line):
      return
        "Unknown or duplicate setting '\(key)' on line \(line). Use each supported setting once."
    case .invalidDefaultAnimation(let reason):
      return "Invalid 'default_animation': \(reason)"
    case .invalidValue(let key):
      switch key {
      case "max_wait_time":
        return "Missing or invalid '\(key)'. Add it to config.toml as a positive number of seconds."
      case "auto_start":
        return
          "Missing or invalid '\(key)'. Add it to config.toml with the value true or false."
      case "default_animation":
        return
          "Missing or invalid 'default_animation'. Set it to an animation name, PNG path, or 'random'."
      default:
        return "Missing or invalid setting: \(key). Check config.toml and correct its value."
      }
    }
  }
}

struct SpriteAnimation {
  let filename: String
  let frameSize: NSSize
  let frames: [NSImage]

  static let minimumFrameDimension = 16
  static let maximumFrameDimension = 256
  static let maximumFrameAspectRatio = 3.0
  static let maximumFrameCount = 120
  static let maximumSpriteSheetPixels = 4_000_000

  static func load(from url: URL) throws -> SpriteAnimation {
    let filename = url.lastPathComponent
    let pattern = #"^(.+)_([0-9]+)x([0-9]+)\.png$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let match = regex.firstMatch(
        in: filename, range: NSRange(filename.startIndex..., in: filename)),
      let widthRange = Range(match.range(at: 2), in: filename),
      let heightRange = Range(match.range(at: 3), in: filename),
      let frameWidth = Int(filename[widthRange]),
      let frameHeight = Int(filename[heightRange])
    else {
      throw AnimationError.invalidFilename(filename)
    }
    let frameSize = NSSize(width: frameWidth, height: frameHeight)
    let dimensionsAreInRange =
      (Self.minimumFrameDimension...Self.maximumFrameDimension).contains(frameWidth)
      && (Self.minimumFrameDimension...Self.maximumFrameDimension).contains(frameHeight)
    let aspectRatio = Double(max(frameWidth, frameHeight)) / Double(min(frameWidth, frameHeight))
    guard dimensionsAreInRange, aspectRatio <= Self.maximumFrameAspectRatio else {
      throw AnimationError.unsupportedFrameSize(filename, frameWidth, frameHeight)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else {
      throw AnimationError.invalidPNG(filename)
    }
    guard height == frameHeight, width > 0, width % frameWidth == 0 else {
      throw AnimationError.invalidDimensions(filename, width, height)
    }
    let frameCount = width / frameWidth
    guard frameCount <= Self.maximumFrameCount else {
      throw AnimationError.tooManyFrames(filename, frameCount, Self.maximumFrameCount)
    }
    guard width <= Self.maximumSpriteSheetPixels / height else {
      throw AnimationError.spriteSheetTooLarge(
        filename, width, height, Self.maximumSpriteSheetPixels)
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw AnimationError.invalidPNG(filename)
    }
    var frames: [NSImage] = []
    for index in 0..<frameCount {
      let rect = CGRect(x: index * frameWidth, y: 0, width: frameWidth, height: frameHeight)
      guard let crop = image.cropping(to: rect) else { throw AnimationError.invalidPNG(filename) }
      frames.append(NSImage(cgImage: crop, size: frameSize))
    }
    return SpriteAnimation(filename: filename, frameSize: frameSize, frames: frames)
  }

  static func loadAll(in directory: URL) -> [String: SpriteAnimation] {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil)
    else { return [:] }
    var result: [String: SpriteAnimation] = [:]
    for file in files where file.pathExtension.lowercased() == "png" {
      do { result[file.lastPathComponent] = try load(from: file) } catch {
        NyathingLog.write(
          "Ignoring animation \(file.lastPathComponent): \(error.localizedDescription)")
      }
    }
    return result
  }
}

enum AnimationResolution {
  case asset(SpriteAnimation)
  case builtInGhost

  static func resolve(_ filename: String, available: [String: SpriteAnimation])
    -> AnimationResolution
  {
    guard let animation = available[filename] else { return .builtInGhost }
    return .asset(animation)
  }
}

enum AnimationError: LocalizedError {
  case invalidFilename(String)
  case invalidPNG(String)
  case unsupportedFrameSize(String, Int, Int)
  case invalidDimensions(String, Int, Int)
  case tooManyFrames(String, Int, Int)
  case spriteSheetTooLarge(String, Int, Int, Int)
  var errorDescription: String? {
    switch self {
    case .invalidFilename(let name): return "Unrecognized animation filename: \(name)"
    case .invalidPNG(let name): return "Unable to decode PNG animation: \(name)"
    case .unsupportedFrameSize(let name, let width, let height):
      return
        "Unsupported frame size for \(name): \(width)x\(height). Dimensions must be between 16 and 256 pixels with an aspect ratio no greater than 3:1."
    case .invalidDimensions(let name, let width, let height):
      return "Invalid sprite dimensions for \(name): \(width)x\(height)"
    case .tooManyFrames(let name, let count, let maximum):
      return "Too many frames in \(name): \(count); maximum is \(maximum)."
    case .spriteSheetTooLarge(let name, let width, let height, let maximumPixels):
      return
        "Sprite sheet \(name) is too large (\(width)x\(height)); maximum is \(maximumPixels) pixels."
    }
  }
}
