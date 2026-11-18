import Darwin
import Foundation

/// Coordinates end-user removal while avoiding deletion of the running app executable.
enum NyathingUninstaller {
  static let appPath = "/Applications/Nyathing.app"
  static let symlinkPath = "/usr/local/bin/nyathing"
  static let prompt = "Remove Nyathing configuration and user animations? [y/N]"
  static let deferredRemovalHelperContents = """
    #!/bin/sh
    parent_pid="$1"
    symlink_path="$2"
    app_path="$3"
    helper_path="$4"
    bundle_executable="$5"
    trap '/bin/rm -f -- "$helper_path"' EXIT
    while /bin/kill -0 "$parent_pid" 2>/dev/null; do /bin/sleep 1; done
    removal_failed=0
    while :; do
      /usr/sbin/lsof -t "$bundle_executable" >/dev/null 2>&1
      lsof_status=$?
      if [ "$lsof_status" -eq 1 ]; then break; fi
      if [ "$lsof_status" -ne 0 ]; then removal_failed=1; break; fi
      /bin/sleep 1
    done
    if [ "$removal_failed" -eq 0 ]; then
      /bin/rm -f -- "$symlink_path" || removal_failed=1
      /bin/rm -rf -- "$app_path" || removal_failed=1
    fi
    if [ "$removal_failed" -ne 0 ]; then
      /usr/bin/osascript -e 'display alert "Nyathing uninstall failed" message "Nyathing could not safely remove the app or CLI link. Remove /Applications/Nyathing.app and /usr/local/bin/nyathing manually."' >/dev/null 2>&1 || true
    fi
    """

  static func run() -> Int32 {
    do {
      let removeUserData = try confirmUserDataRemoval()
      try requestAuthorization(removeUserData: removeUserData)
      print(
        "Uninstall request accepted, not completed. Removal will wait for all Nyathing processes to exit; a macOS alert will report any failure."
      )
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
    var commands: [String] = []
    if removeUserData {
      let configuration = AppConfiguration.configurationDirectory.path
      commands.append("/bin/rm -rf -- \(shellQuote(configuration + "/animations"))")
      commands.append("/bin/rm -rf -- \(shellQuote(configuration))")
    }
    let helperContents = deferredRemovalHelperContents
    let executablePath = appPath + "/Contents/MacOS/nyathing"
    let helperCommand =
      "helper=$(/usr/bin/mktemp /private/tmp/nyathing-uninstall.XXXXXX) && /usr/bin/printf %s \(shellQuote(helperContents)) > \"$helper\" && /bin/chmod 700 \"$helper\" && (/usr/bin/nohup /bin/sh \"$helper\" \(pid) \(shellQuote(symlinkPath)) \(shellQuote(appPath)) \"$helper\" \(shellQuote(executablePath)) >/dev/null 2>&1 </dev/null &)"
    commands.append(helperCommand)
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
  case helperCreation(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfirmation:
      return "Please answer yes or no; user data has not been removed."
    case .authorization(let details):
      return details.map { "Administrator authorization failed: \($0)" }
        ?? "Administrator authorization was canceled or failed."
    case .helperCreation(let reason):
      return "Unable to create the deferred removal helper: \(reason)"
    }
  }
}
