import Foundation

/// Shared IPC protocol for communication between the main NeverFold app
/// and the neverfold-lid-extender daemon via TCP on localhost.
///
/// Messages are newline-delimited JSON over TCP port 52734.

// MARK: - Commands (App → Extender)

struct ExtenderCommand: Codable {
    enum Action: String, Codable {
        case enable
        case disable
        case status
        case quit
    }

    let action: Action
}

// MARK: - Responses (Extender → App)

struct ExtenderResponse: Codable {
    let success: Bool
    let active: Bool
    let version: String
    let error: String?

    init(success: Bool, active: Bool, version: String = ExtenderInfo.version, error: String? = nil) {
        self.success = success
        self.active = active
        self.version = version
        self.error = error
    }
}

// MARK: - Extender Metadata

enum ExtenderInfo {
    static let version = "1.0.1"
    static let bundleIdentifier = "kz.kzai.neverfold.extender"
    static let daemonLabel = "kz.kzai.neverfold.extender"

    /// TCP port for IPC — works through App Sandbox with network.client entitlement
    static let ipcPort: UInt16 = 52734

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NeverFold", isDirectory: true)
    }

    static var installedBinaryPath: URL {
        supportDirectory.appendingPathComponent("neverfold-lid-extender")
    }

    static var daemonPlistPath: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons/\(daemonLabel).plist")
    }
}
