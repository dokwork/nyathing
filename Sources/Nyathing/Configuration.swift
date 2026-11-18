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
    # Animation filename in the sibling animations directory.
    default_animation = \"ghost_36x36.png\"
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

  private static func decodeTOMLString(_ raw: String) -> String? {
    let characters = Array(raw)
    guard characters.count >= 2,
      (characters.first == "\"" && characters.last == "\"")
        || (characters.first == "'" && characters.last == "'")
    else { return nil }
    let quote = characters[0]
    let content = Array(characters.dropFirst().dropLast())
    var result = ""
    var index = 0
    while index < content.count {
      let character = content[index]
      if character == quote { return nil }
      if quote == "'" || character != "\\" {
        result.append(character)
        index += 1
        continue
      }
      index += 1
      guard index < content.count else { return nil }
      let escape = content[index]
      let replacements: [Character: Character] = [
        "\"": "\"", "\\": "\\", "b": "\u{8}", "t": "\t", "n": "\n", "f": "\u{c}", "r": "\r",
      ]
      if let replacement = replacements[escape] {
        result.append(replacement)
        index += 1
      } else if escape == "u" || escape == "U" {
        let digits = escape == "u" ? 4 : 8
        guard index + digits < content.count else { return nil }
        let hex = String(content[(index + 1)...(index + digits)])
        guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value),
          !(0xD800...0xDFFF).contains(value)
        else { return nil }
        result.unicodeScalars.append(scalar)
        index += digits + 1
      } else {
        return nil
      }
    }
    return result
  }

  static func load() throws -> AppConfiguration {
    try load(in: configurationDirectory)
  }

  /// Loads and validates configuration and its selected animation from a configuration directory.
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
    let text = try String(contentsOf: configURL, encoding: .utf8)
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
    guard let rawName = values["default_animation"],
      let name = decodeTOMLString(rawName), !name.isEmpty,
      !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw ConfigError.invalidValue("default_animation")
    }
    let animationURL = animationsDirectory.appendingPathComponent(name)
    do {
      _ = try SpriteAnimation.load(from: animationURL)
    } catch {
      throw ConfigError.invalidAnimation(name, error.localizedDescription)
    }
    return AppConfiguration(
      keepaliveInterval: try number("keepalive_interval_seconds"),
      activityTimeout: try number("activity_timeout_seconds"),
      autoStart: rawAuto == "true", defaultAnimation: name)
  }
}

enum ConfigError: LocalizedError {
  case invalidLine(Int)
  case invalidKey(String, Int)
  case invalidValue(String)
  case invalidAnimation(String, String)

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
          "Missing or invalid 'auto_start'. Add it to config.toml with the value true or false."
      case "default_animation":
        return
          "Missing or invalid 'default_animation'. Set it to a quoted animation filename in animations/."
      default:
        return "Missing or invalid setting: \(key). Check config.toml and correct its value."
      }
    case .invalidAnimation(let name, let reason):
      return "The default animation '\(name)' is missing or invalid in animations/: \(reason) "
        + "Add a valid sprite sheet there or choose another filename in config.toml."
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
