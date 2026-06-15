import Foundation
import os

final class USBManager {
    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "USB")
    private var monitorTask: Task<Void, Never>?

    var onDeviceConnected: ((UInt16) -> Void)?
    var onDeviceDisconnected: (() -> Void)?

    private let adbPort: UInt16

    init(adbPort: UInt16) {
        self.adbPort = adbPort
    }

    func startMonitoring() {
        monitorTask = Task.detached { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let connected = self.checkADBDevice()
                if connected {
                    self.setupPortForwarding()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000) // Poll every 3s
            }
        }
        logger.info("USB monitoring started")
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func findADB() -> String? {
        let paths = [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try `which adb`
        let result = shell("which adb")
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            return path
        }

        return nil
    }

    func checkADBDevice() -> Bool {
        guard let adb = findADB() else {
            logger.debug("ADB not found")
            return false
        }

        let output = shell("\(adb) devices")
        let lines = output.components(separatedBy: "\n")
            .filter { $0.contains("device") && !$0.contains("List") }

        return !lines.isEmpty
    }

    func setupPortForwarding() {
        guard let adb = findADB() else { return }

        let result = shell("\(adb) reverse tcp:\(adbPort) tcp:\(adbPort)")

        if result.contains("error") {
            logger.error("ADB port forwarding failed: \(result)")
            return
        }

        logger.info("ADB port forwarding set up: tcp:\(self.adbPort)")
        onDeviceConnected?(adbPort)
    }

    func removePortForwarding() {
        guard let adb = findADB() else { return }
        _ = shell("\(adb) reverse --remove tcp:\(adbPort)")
        logger.info("ADB port forwarding removed")
    }

    var isADBAvailable: Bool {
        findADB() != nil
    }

    private func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
