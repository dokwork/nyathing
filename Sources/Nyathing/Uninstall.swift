import Darwin
import Foundation

/// Coordinates synchronous end-user removal of the app and CLI command.
enum NyathingUninstaller {
  static let appPath = "/Applications/Nyathing.app"
  static let symlinkPath = "/usr/local/bin/nyathing"
  static let prompt = "Remove Nyathing configuration and user animations? [y/N]"
  static func run() -> Int32 {
    do {
      let removeUserData = try confirmUserDataRemoval()
      try requestAuthorization(removeUserData: removeUserData)
      FileHandle.standardError.write(Data("Nyathing was successfully uninstalled.\n".utf8))
      return 0
    } catch {
      FileHandle.standardError.write(
        Data("nyathing: Uninstall failed: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  static func confirmUserDataRemoval() throws -> Bool {
    FileHandle.standardOutput.write(Data((prompt + " ").utf8))
    guard let answer = readLine() else { return false }
    return try parseConfirmation(answer)
  }

  static func parseConfirmation(_ answer: String) throws -> Bool {
    switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "", "n", "no": return false
    case "y", "yes": return true
    default: throw UninstallError.invalidConfirmation
    }
  }

  private static func requestAuthorization(removeUserData: Bool) throws {
    let pid = getpid()
    let executablePath = appPath + "/Contents/MacOS/nyathing"
    let removalCommand = """
      attempts=0
      while :; do
        pids=$(/usr/sbin/lsof -t \(shellQuote(executablePath)) 2>/dev/null)
        lsof_status=$?
        if [ "$lsof_status" -gt 1 ]; then exit 1; fi
        other_pids=
        for process_pid in $pids; do
          if [ "$process_pid" != "\(pid)" ]; then other_pids="$other_pids $process_pid"; fi
        done
        if [ -z "$other_pids" ]; then break; fi
        if [ "$attempts" -lt 1 ]; then signal=TERM; else signal=KILL; fi
        for process_pid in $other_pids; do
          /bin/kill -"$signal" "$process_pid" 2>/dev/null || true
        done
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 10 ]; then exit 1; fi
        /bin/sleep 1
      done
      /bin/rm -f -- \(shellQuote(symlinkPath)) && /bin/rm -rf -- \(shellQuote(appPath)) &&
      [ ! -e \(shellQuote(symlinkPath)) ] && [ ! -L \(shellQuote(symlinkPath)) ] &&
      [ ! -e \(shellQuote(appPath)) ] && [ ! -L \(shellQuote(appPath)) ]
      """
    var commands = [removalCommand]
    if removeUserData {
      let configuration = AppConfiguration.configurationDirectory.path
      commands.append("/bin/rm -rf -- \(shellQuote(configuration + "/animations"))")
      commands.append("/bin/rm -rf -- \(shellQuote(configuration))")
    }
    let shellCommand = commands.joined(separator: " && ")
    let appleScript =
      "do shell script \"\(appleScriptQuote(shellCommand))\" with administrator privileges"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", appleScript]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    do {
      try process.run()
    } catch {
      throw UninstallError.authorization(error.localizedDescription)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let details = String(
        data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw UninstallError.authorization(details?.isEmpty == false ? details! : nil)
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func appleScriptQuote(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

enum UninstallError: LocalizedError {
  case invalidConfirmation
  case authorization(String?)

  var errorDescription: String? {
    switch self {
    case .invalidConfirmation:
      return "Please answer yes or no; user data has not been removed."
    case .authorization(let details):
      return details.map { "Administrator authorization failed: \($0)" }
        ?? "Administrator authorization was canceled or failed."
    }
  }
}
