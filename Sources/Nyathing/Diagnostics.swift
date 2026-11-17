import AppKit
import Foundation

/// Writes timestamped diagnostics to the user's XDG state directory.
enum NyathingLog {
    private static let lock = NSLock()

    static let fileURL: URL = {
        let environment = ProcessInfo.processInfo.environment
        let base: URL
        if let stateHome = environment["XDG_STATE_HOME"], !stateHome.isEmpty {
            base = URL(fileURLWithPath: stateHome, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state", isDirectory: true)
        }
        return base.appendingPathComponent("nyathing/nyathing.log")
    }()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            _ = chmod(directory.path, mode_t(S_IRWXU))
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) \(message)\n"
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            _ = chmod(fileURL.path, mode_t(S_IRUSR | S_IWUSR))
        } catch {
            NSLog("Nyathing log write failed: %@ (original: %@)", error.localizedDescription, message)
        }
    }

    static func report(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        write(message)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = context
            alert.informativeText = "\(error.localizedDescription)\n\nFull log: \(fileURL.path)"
            alert.addButton(withTitle: "Open Full Log")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(fileURL)
            }
        }
    }
}

enum LaunchAgentSupport {
    static let label = "com.nyathing.Nyathing"

    /// Writes a user-installable LaunchAgent plist beside the configuration when auto-start is enabled.
    static func prepare(in directory: URL) throws {
        guard let executable = Bundle.main.executableURL?.path else {
            throw LaunchAgentError.executableUnavailable
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("com.nyathing.Nyathing.plist"), options: .atomic)
    }
}

enum LaunchAgentError: LocalizedError {
    case executableUnavailable
    var errorDescription: String? {
        "Unable to determine Nyathing's executable path for the LaunchAgent plist."
    }
}
