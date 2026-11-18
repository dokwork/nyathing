import AppKit
import Foundation
import ImageIO

struct AppConfiguration {
  let keepaliveInterval: TimeInterval
  let activityTimeout: TimeInterval
  let autoStart: Bool
  let defaultAnimation: String

  static let template = """
    # Seconds between client keepalive messages; must be greater than zero.
    keepalive_interval_seconds = 5
    # Seconds without a keepalive before an activity expires; must be greater than zero.
    activity_timeout_seconds = 5
    # Whether Nyathing should launch automatically when you log in.
    auto_start = false
    # Animation filename used when a client omits the animation field.
    default_animation = "nyathing_36x36.png"
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

  static func load() throws -> AppConfiguration {
    try load(in: configurationDirectory)
  }

  /// Loads and validates configuration from a configuration directory.
  static func load(in directory: URL) throws -> AppConfiguration {
    let configURL = directory.appendingPathComponent("config.toml")
    let animationsDirectory = directory.appendingPathComponent("animations", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: animationsDirectory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: configURL.path) {
      try template.write(to: configURL, atomically: true, encoding: .utf8)
    }
    if let bundledResources = Bundle.module.resourceURL {
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
    var text = try String(contentsOf: configURL, encoding: .utf8)
    var removedObsoleteSettings = false
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
      try text.write(to: configURL, atomically: true, encoding: .utf8)
    }
    var values: [String: String] = [:]
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
      guard
        [
          "keepalive_interval_seconds", "activity_timeout_seconds", "auto_start",
          "default_animation",
        ].contains(key),
        values[key] == nil
      else { throw ConfigError.invalidKey(key, offset + 1) }
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
    guard let rawAnimation = values["default_animation"],
      rawAnimation.count >= 2, rawAnimation.first == "\"", rawAnimation.last == "\""
    else {
      throw ConfigError.invalidValue("default_animation")
    }
    let defaultAnimation = String(rawAnimation.dropFirst().dropLast())
    guard !defaultAnimation.contains("/"), !defaultAnimation.contains("\\"),
      (try? SpriteAnimation.load(
        from: animationsDirectory.appendingPathComponent(
          defaultAnimation))) != nil
    else {
      throw ConfigError.invalidValue("default_animation")
    }
    return AppConfiguration(
      keepaliveInterval: try number("keepalive_interval_seconds"),
      activityTimeout: try number("activity_timeout_seconds"),
      autoStart: rawAuto == "true",
      defaultAnimation: defaultAnimation)
  }
}

enum ConfigError: LocalizedError {
  case invalidLine(Int)
  case invalidKey(String, Int)
  case invalidValue(String)

  var errorDescription: String? {
    switch self {
    case .invalidLine(let line):
      return
        "Invalid config.toml line \(line). Write each setting as key = value, or remove the line."
    case .invalidKey(let key, let line):
      return
        "Unknown or duplicate setting '\(key)' on line \(line). Use each supported setting once."
    case .invalidValue(let key):
      switch key {
      case "keepalive_interval_seconds", "activity_timeout_seconds":
        return "Missing or invalid '\(key)'. Add it to config.toml as a positive number of seconds."
      case "auto_start":
        return
          "Missing or invalid '\(key)'. Add it to config.toml with the value true or false."
      case "default_animation":
        return
          "Missing or invalid 'default_animation'. Set it to the filename of a valid animation in the animations directory."
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

  static func load(from url: URL) throws -> SpriteAnimation {
    let filename = url.lastPathComponent
    let pattern = #"^(.+)_((?:36x36)|(?:54x36))\.png$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let match = regex.firstMatch(
        in: filename, range: NSRange(filename.startIndex..., in: filename)),
      let sizeRange = Range(match.range(at: 2), in: filename)
    else {
      throw AnimationError.invalidFilename(filename)
    }
    let sizeName = filename[sizeRange].lowercased()
    let size: NSSize =
      sizeName == "36x36" ? NSSize(width: 36, height: 36) : NSSize(width: 54, height: 36)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw AnimationError.invalidPNG(filename)
    }
    let width = image.width
    let height = image.height
    let frameWidth = Int(size.width)
    let frameHeight = Int(size.height)
    guard height == frameHeight, width > 0, width % frameWidth == 0 else {
      throw AnimationError.invalidDimensions(filename, width, height)
    }
    let sheet = NSImage(cgImage: image, size: NSSize(width: width, height: height))
    var frames: [NSImage] = []
    for index in 0..<(width / frameWidth) {
      let rect = CGRect(x: index * frameWidth, y: 0, width: frameWidth, height: frameHeight)
      guard let crop = image.cropping(to: rect) else { throw AnimationError.invalidPNG(filename) }
      frames.append(NSImage(cgImage: crop, size: size))
    }
    _ = sheet
    return SpriteAnimation(filename: filename, frameSize: size, frames: frames)
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
  case invalidDimensions(String, Int, Int)
  var errorDescription: String? {
    switch self {
    case .invalidFilename(let name): return "Unrecognized animation filename: \(name)"
    case .invalidPNG(let name): return "Unable to decode PNG animation: \(name)"
    case .invalidDimensions(let name, let width, let height):
      return "Invalid sprite dimensions for \(name): \(width)x\(height)"
    }
  }
}
