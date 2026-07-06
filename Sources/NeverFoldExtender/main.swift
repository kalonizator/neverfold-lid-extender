import Foundation

/// NeverFold Lid Extender — standalone CLI tool for preventing sleep on lid close.
///
/// Usage:
///   neverfold-lid-extender install    — Install as a LaunchDaemon (requires admin)
///   neverfold-lid-extender uninstall  — Remove LaunchDaemon and clean up
///   neverfold-lid-extender daemon     — Run in daemon mode (called by launchd)
///   neverfold-lid-extender enable     — Send enable command to running daemon
///   neverfold-lid-extender disable    — Send disable command to running daemon
///   neverfold-lid-extender status     — Query daemon status
///   neverfold-lid-extender version    — Print version

// MARK: - Main Entry Point

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "help"

switch command {
case "install":
    performInstall()
case "uninstall":
    performUninstall()
case "daemon":
    let daemon = ExtenderDaemon()
    daemon.run()
case "enable":
    sendCommandToDaemon(.enable)
case "disable":
    sendCommandToDaemon(.disable)
case "status":
    sendCommandToDaemon(.status)
case "version":
    print(ExtenderInfo.version)
case "help", "--help", "-h":
    printUsage()
default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}

// MARK: - Install / Uninstall

func performInstall() {
    let fm = FileManager.default
    let supportDir = ExtenderInfo.supportDirectory
    let installedPath = ExtenderInfo.installedBinaryPath

    // 1. Create support directory
    do {
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    } catch {
        fputs("Error: Failed to create support directory: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    // 2. Copy self to the install location
    let selfPath = CommandLine.arguments[0]
    let selfURL = URL(fileURLWithPath: selfPath).standardizedFileURL

    if selfURL != installedPath.standardizedFileURL {
        do {
            if fm.fileExists(atPath: installedPath.path) {
                try fm.removeItem(at: installedPath)
            }
            try fm.copyItem(at: selfURL, to: installedPath)
            // Make executable
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedPath.path)
        } catch {
            fputs("Error: Failed to copy binary: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // 3. Generate the LaunchDaemon plist
    let plistContent = generateDaemonPlist(binaryPath: installedPath.path)

    // 4. Install LaunchDaemon with admin privileges via osascript
    let plistPath = ExtenderInfo.daemonPlistPath.path
    let tempPlistPath = NSTemporaryDirectory() + "kz.kzai.neverfold.extender.plist"

    do {
        try plistContent.write(toFile: tempPlistPath, atomically: true, encoding: .utf8)
    } catch {
        fputs("Error: Failed to write temp plist: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    // Use osascript to copy plist with admin privileges and load the daemon
    let script = """
    do shell script "cp '\(tempPlistPath)' '\(plistPath)' && chown root:wheel '\(plistPath)' && chmod 644 '\(plistPath)' && launchctl bootout system/\(ExtenderInfo.daemonLabel) 2>/dev/null; launchctl bootstrap system '\(plistPath)'" with administrator privileges
    """

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    do {
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus == 0 {
            // Clean up temp file
            try? fm.removeItem(atPath: tempPlistPath)
            print("✅ NeverFold Lid Extender installed successfully")
            print("   Binary: \(installedPath.path)")
            print("   Daemon: \(plistPath)")
        } else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if output.contains("User canceled") || output.contains("-128") {
                fputs("Installation cancelled by user.\n", stderr)
            } else {
                fputs("Error: Installation failed: \(output)\n", stderr)
            }
            try? fm.removeItem(atPath: tempPlistPath)
            exit(1)
        }
    } catch {
        fputs("Error: Failed to run installer: \(error.localizedDescription)\n", stderr)
        try? fm.removeItem(atPath: tempPlistPath)
        exit(1)
    }
}

func performUninstall() {
    let plistPath = ExtenderInfo.daemonPlistPath.path

    // Unload and remove daemon with admin privileges
    let script = """
    do shell script "launchctl bootout system/\(ExtenderInfo.daemonLabel) 2>/dev/null; rm -f '\(plistPath)'" with administrator privileges
    """

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        fputs("Warning: Failed to unload daemon: \(error.localizedDescription)\n", stderr)
    }

    // Remove installed binary and support files
    let fm = FileManager.default
    try? fm.removeItem(at: ExtenderInfo.installedBinaryPath)
    try? fm.removeItem(atPath: ExtenderInfo.socketPath)

    // Remove support directory if empty
    let supportDir = ExtenderInfo.supportDirectory
    if let contents = try? fm.contentsOfDirectory(atPath: supportDir.path), contents.isEmpty {
        try? fm.removeItem(at: supportDir)
    }

    print("✅ NeverFold Lid Extender uninstalled")
}

// MARK: - IPC Client

func sendCommandToDaemon(_ action: ExtenderCommand.Action) {
    let socketPath = ExtenderInfo.socketPath

    // Create socket
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else {
        fputs("Error: Failed to create socket\n", stderr)
        exit(1)
    }
    defer { close(sock) }

    // Connect to daemon
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
        sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for i in 0..<pathBytes.count {
                dest[i] = pathBytes[i]
            }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else {
        fputs("Error: Daemon not running (could not connect to \(socketPath))\n", stderr)
        exit(1)
    }

    // Send command
    let command = ExtenderCommand(action: action)
    guard var data = try? JSONEncoder().encode(command) else {
        fputs("Error: Failed to encode command\n", stderr)
        exit(1)
    }
    data.append(UInt8(ascii: "\n"))

    data.withUnsafeBytes { rawBuffer in
        _ = write(sock, rawBuffer.baseAddress!, rawBuffer.count)
    }

    // Read response
    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(sock, &buffer, buffer.count)
    guard bytesRead > 0 else {
        fputs("Error: No response from daemon\n", stderr)
        exit(1)
    }

    let responseData = Data(buffer[0..<bytesRead])
    if let response = try? JSONDecoder().decode(ExtenderResponse.self, from: responseData) {
        if action == .status {
            print("Version: \(response.version)")
            print("Active:  \(response.active ? "yes" : "no")")
            if let error = response.error {
                print("Warning: \(error)")
            }
        } else {
            if response.success {
                print("OK: \(action.rawValue) — active: \(response.active)")
            } else {
                fputs("Error: \(response.error ?? "Unknown error")\n", stderr)
                exit(1)
            }
        }
    } else {
        fputs("Error: Invalid response from daemon\n", stderr)
        exit(1)
    }
}

// MARK: - Helpers

func generateDaemonPlist(binaryPath: String) -> String {
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(ExtenderInfo.daemonLabel)</string>
        <key>Program</key>
        <string>\(binaryPath)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(binaryPath)</string>
            <string>daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardErrorPath</key>
        <string>/tmp/neverfold-extender.log</string>
        <key>StandardOutPath</key>
        <string>/tmp/neverfold-extender.log</string>
    </dict>
    </plist>
    """
}

func printUsage() {
    print("""
    NeverFold Lid Extender v\(ExtenderInfo.version)
    Prevents macOS from sleeping when the laptop lid is closed.

    Usage:
      neverfold-lid-extender <command>

    Commands:
      install     Install as a system LaunchDaemon (requires admin password)
      uninstall   Remove the LaunchDaemon and clean up
      daemon      Run in daemon mode (used by launchd, not for manual use)
      enable      Enable lid-close sleep prevention
      disable     Disable lid-close sleep prevention
      status      Show current daemon status
      version     Print version number
      help        Show this help message

    The extender works with the NeverFold app to prevent your Mac from
    sleeping when you close the lid. It requires a one-time admin setup
    to install a system daemon.
    """)
}
