import Foundation

/// Locates the SwiftPM resource bundle in both packaged apps and CLI builds.
enum BundledResources {
  private final class BundleMarker {}

  static let bundle: Bundle = {
    let bundleName = "Nyathing_Nyathing.bundle"
    let candidates = [
      Bundle.main.resourceURL,
      Bundle.main.bundleURL,
      Bundle.main.executableURL?.deletingLastPathComponent(),
      Bundle(for: BundleMarker.self).resourceURL,
    ]

    var searched = Set<URL>()
    for candidate in candidates.compactMap({ $0 }) {
      var directory = candidate
      for _ in 0..<8 {
        let normalizedDirectory = directory.standardizedFileURL
        if searched.insert(normalizedDirectory).inserted {
          let bundleURL = normalizedDirectory.appendingPathComponent(
            bundleName, isDirectory: true)
          if let bundle = Bundle(url: bundleURL) {
            return bundle
          }
        }
        let parent = directory.deletingLastPathComponent()
        guard parent != directory else { break }
        directory = parent
      }
    }

    fatalError("Unable to locate \(bundleName); checked resource and parent directories")
  }()
}
