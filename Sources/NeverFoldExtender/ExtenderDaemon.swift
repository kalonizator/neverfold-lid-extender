import Foundation
import IOKit.pwr_mgt

/// The daemon process that holds IOPMAssertions and manages pmset state.
/// Listens on TCP localhost for commands from the main NeverFold app.
final class ExtenderDaemon {
    private var assertionID: IOPMAssertionID = 0
    private var isActive = false
    private var serverSocket: Int32 = -1
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Daemon Lifecycle

    func run() -> Never {
        setupSignalHandlers()
        startTCPServer()
        // Keep the daemon running
        RunLoop.main.run()
        exit(0)
    }

    // MARK: - TCP Server

    private func startTCPServer() {
        let port = ExtenderInfo.ipcPort

        // Create TCP socket
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            fputs("Error: Failed to create socket\n", stderr)
            exit(1)
        }

        // Allow port reuse
        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to localhost only
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            fputs("Error: Failed to bind to port \(port): \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }

        guard listen(serverSocket, 5) == 0 else {
            fputs("Error: Failed to listen on port \(port)\n", stderr)
            exit(1)
        }

        fputs("Extender daemon listening on 127.0.0.1:\(port)\n", stderr)

        // Accept connections on a background thread
        DispatchQueue.global(qos: .default).async { [weak self] in
            while true {
                guard let self else { return }
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        accept(self.serverSocket, sockaddrPtr, &clientAddrLen)
                    }
                }

                if clientSocket >= 0 {
                    self.handleClient(clientSocket)
                }
            }
        }
    }

    private func handleClient(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read the incoming JSON command
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientSocket, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let data = Data(buffer[0..<bytesRead])

        // Trim any trailing newline
        let trimmedData: Data
        if let lastByte = data.last, lastByte == UInt8(ascii: "\n") {
            trimmedData = data.dropLast()
        } else {
            trimmedData = data
        }

        guard let command = try? decoder.decode(ExtenderCommand.self, from: trimmedData) else {
            let errorResponse = ExtenderResponse(success: false, active: isActive, error: "Invalid command")
            sendResponse(errorResponse, to: clientSocket)
            return
        }

        let response: ExtenderResponse
        switch command.action {
        case .enable:
            response = enableSleepPrevention()
        case .disable:
            response = disableSleepPrevention()
        case .status:
            response = ExtenderResponse(success: true, active: isActive)
        case .quit:
            _ = disableSleepPrevention()
            sendResponse(ExtenderResponse(success: true, active: false), to: clientSocket)
            cleanup()
            exit(0)
        }

        sendResponse(response, to: clientSocket)
    }

    private func sendResponse(_ response: ExtenderResponse, to socket: Int32) {
        guard var data = try? encoder.encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { rawBuffer in
            _ = write(socket, rawBuffer.baseAddress!, rawBuffer.count)
        }
    }

    // MARK: - Sleep Prevention

    private func enableSleepPrevention() -> ExtenderResponse {
        // 1. Create IOPMAssertion to prevent system sleep (including lid-close)
        if assertionID == 0 {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NeverFold: Keeping system awake with lid closed" as CFString,
                &assertionID
            )
            if result != kIOReturnSuccess {
                assertionID = 0
                return ExtenderResponse(
                    success: false,
                    active: false,
                    error: "Failed to create IOPMAssertion (code: \(result))"
                )
            }
        }

        // 2. Also run pmset as a belt-and-suspenders backup
        let pmsetResult = runPmset(disable: true)
        if !pmsetResult.success {
            // IOPMAssertion is still active, so we're partially working
            isActive = true
            return ExtenderResponse(
                success: true,
                active: true,
                error: "IOPMAssertion active, but pmset failed: \(pmsetResult.error ?? "unknown")"
            )
        }

        isActive = true
        return ExtenderResponse(success: true, active: true)
    }

    private func disableSleepPrevention() -> ExtenderResponse {
        // 1. Release IOPMAssertion
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }

        // 2. Re-enable sleep via pmset
        _ = runPmset(disable: false)

        isActive = false
        return ExtenderResponse(success: true, active: false)
    }

    private struct PmsetResult {
        let success: Bool
        let error: String?
    }

    private func runPmset(disable: Bool) -> PmsetResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-a", "disablesleep", disable ? "1" : "0"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                return PmsetResult(success: true, error: nil)
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                return PmsetResult(success: false, error: "pmset exit \(task.terminationStatus): \(output)")
            }
        } catch {
            return PmsetResult(success: false, error: "Failed to run pmset: \(error.localizedDescription)")
        }
    }

    // MARK: - Signal Handling & Cleanup

    private func setupSignalHandlers() {
        signal(SIGTERM) { _ in
            exit(0)
        }
        signal(SIGINT) { _ in
            exit(0)
        }

        // Register atexit cleanup
        atexit {
            // Re-enable sleep on exit
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-a", "disablesleep", "0"]
            try? task.run()
            task.waitUntilExit()
        }
    }

    private func cleanup() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        _ = runPmset(disable: false)
        if serverSocket >= 0 {
            close(serverSocket)
        }
    }
}
