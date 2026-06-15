import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import IOKit.ps
import os

/// Handles "control the Mac from the phone" features: lock the screen, play a
/// find-my-Mac sound, and report the Mac's battery/name back to the phone.
final class MacSystemFeature {
    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "MacSystem")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    private var ringSound: NSSound?
    private var ringSafetyTimer: Timer?
    private var statusTimer: Timer?
    private var mediaTimer: Timer?

    // MARK: - Commands from phone

    func handleControl(_ control: ABMacControl) {
        switch control.action {
        case .lock: lockScreen()
        case .ring: startRing()
        case .stopRing: stopRing()
        case .setVolume:
            setVolume(Int(control.value))
        case .mute: setMuted(true)
        case .unmute: setMuted(false)
        case .wifiOn: setWifi(true)
        case .wifiOff: setWifi(false)
        case .sleep: sleepMac()
        case .setBrightness: setBrightness(Int(control.value))
        case .btOn: setBluetooth(true)
        case .btOff: setBluetooth(false)
        default: break
        }
    }

    // MARK: - Brightness (DisplayServices / CoreDisplay private APIs)

    private func setBrightness(_ value: Int) {
        let level = Float(max(0, min(100, value))) / 100.0
        let id = CGMainDisplayID()
        if let fn = PrivateAPI.setBrightness {
            _ = fn(id, level)
        } else if let core = PrivateAPI.coreSetBrightness {
            core(id, Double(level))
        } else {
            logger.warning("No brightness API available")
        }
        logger.info("Brightness set to \(value)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.sendStatus() }
    }

    private func brightnessInfo() -> Int {
        let id = CGMainDisplayID()
        if let fn = PrivateAPI.getBrightness {
            var level: Float = 0
            if fn(id, &level) == 0 { return Int((level * 100).rounded()) }
        }
        if let core = PrivateAPI.coreGetBrightness {
            let v = core(id)
            if v >= 0 { return Int((v * 100).rounded()) }
        }
        return -1
    }

    // MARK: - Bluetooth (IOBluetooth private power API)
    //
    // Touching IOBluetooth without an NSBluetoothAlwaysUsageDescription in
    // Info.plist makes macOS hard-kill the app (TCC SIGABRT). Guard every call
    // so the app never crashes even if that key is somehow missing.

    private static let bluetoothUsable: Bool =
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil

    private func setBluetooth(_ on: Bool) {
        guard Self.bluetoothUsable, let fn = PrivateAPI.setBluetoothPower else {
            logger.warning("Bluetooth control unavailable (missing usage description)")
            return
        }
        fn(on ? 1 : 0)
        logger.info("Bluetooth \(on ? "on" : "off")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.sendStatus() }
    }

    private func bluetoothIsOn() -> Bool {
        guard Self.bluetoothUsable, let fn = PrivateAPI.getBluetoothPower else { return false }
        return fn() != 0
    }

    // MARK: - System controls (volume / Wi-Fi / sleep)

    private func setVolume(_ value: Int) {
        let clamped = max(0, min(100, value))
        runOsa("set volume output volume \(clamped)")
        if clamped > 0 { runOsa("set volume without output muted") }
        logger.info("Volume set to \(clamped)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.sendStatus() }
    }

    private func setMuted(_ muted: Bool) {
        runOsa("set volume \(muted ? "with" : "without") output muted")
        logger.info("Muted: \(muted)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.sendStatus() }
    }

    private func setWifi(_ on: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let device = self.wifiInterface()
            guard !device.isEmpty else { self.logger.warning("No Wi-Fi interface found"); return }
            _ = self.run("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"], capture: true)
            self.logger.info("Wi-Fi \(on ? "on" : "off") on \(device)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.sendStatus() }
        }
    }

    private func sleepMac() {
        _ = run("/usr/bin/pmset", ["sleepnow"], capture: false)
        logger.info("Sleep requested")
    }

    /// Find the Wi-Fi hardware port's BSD device name (e.g. "en0").
    private func wifiInterface() -> String {
        let out = run("/usr/sbin/networksetup", ["-listallhardwareports"], capture: true)
        let lines = out.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if i + 1 < lines.count {
                let dev = lines[i + 1].replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty { return dev }
            }
        }
        return "en0"
    }

    @discardableResult
    private func run(_ path: String, _ args: [String], capture: Bool) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if capture {
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            } catch { return "" }
        } else {
            try? task.run()
            return ""
        }
    }

    private func lockScreen() {
        // Sleeps the display; with "require password after sleep" this locks the Mac.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
        logger.info("Lock requested (display sleep)")
    }

    private func startRing() {
        runOsa("set volume output volume 100")
        DispatchQueue.main.async {
            self.stopRingInternal()
            let sound = SystemSound.looping(["Sosumi", "Submarine", "Ping", "Glass"])
            sound?.play()
            self.ringSound = sound
            // Safety auto-stop after 5 min in case the phone never sends STOP_RING.
            self.ringSafetyTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
                self?.stopRing()
            }
        }
        logger.info("Find-my-Mac ring started")
    }

    private func stopRing() {
        DispatchQueue.main.async { self.stopRingInternal() }
    }

    private func stopRingInternal() {
        ringSound?.stop()
        ringSound = nil
        ringSafetyTimer?.invalidate()
        ringSafetyTimer = nil
    }

    @discardableResult
    private func runOsa(_ script: String, capture: Bool = false) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        if capture {
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            } catch { return "" }
        } else {
            try? task.run()
            return ""
        }
    }

    // MARK: - Status reporting to phone

    func startReporting() {
        sendStatus()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendStatus()
        }
        // Poll now-playing (Music / Spotify) more frequently.
        mediaTimer?.invalidate()
        mediaTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.pollMedia()
        }
        pollMedia()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.sendStatus() }
    }

    func stopReporting() {
        statusTimer?.invalidate()
        statusTimer = nil
        mediaTimer?.invalidate()
        mediaTimer = nil
        stopRingInternal()
    }

    // MARK: - Mac now-playing (Music / Spotify via AppleScript)

    func handleMediaControl(_ control: ABMacMediaControl) {
        let cmd: String
        switch control.action {
        case .playPause: cmd = "playpause"
        case .next: cmd = "next track"
        case .previous: cmd = "previous track"
        default: return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if self.musicAppRunning() {
                _ = self.runOsa(self.controlScript(cmd), capture: true)
            } else {
                // No Music/Spotify — send a hardware media key so whatever is
                // playing (YouTube in a browser, VLC, …) responds.
                let key: Int32
                switch control.action {
                case .playPause: key = 16   // NX_KEYTYPE_PLAY
                case .next: key = 17        // NX_KEYTYPE_NEXT
                case .previous: key = 18    // NX_KEYTYPE_PREVIOUS
                default: return
                }
                DispatchQueue.main.async { self.postMediaKey(key) }
            }
            DispatchQueue.main.async { self.pollMedia() }
        }
    }

    private func musicAppRunning() -> Bool {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return ids.contains("com.spotify.client") || ids.contains("com.apple.Music")
    }

    /// Posts a system media key press (play/pause/next/previous) like the
    /// keyboard's hardware keys — reaches any app, no scripting needed.
    /// Requires Accessibility permission to deliver synthetic events.
    private func postMediaKey(_ key: Int32) {
        guard ensureAccessibilityTrust() else {
            logger.warning("Media key needs Accessibility permission — prompted user")
            return
        }
        func send(_ down: Bool) {
            let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xA00)
                                                    : NSEvent.ModifierFlags(rawValue: 0xB00)
            let data1 = Int((Int(key) << 16) | ((down ? 0xA : 0xB) << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        send(true)
        send(false)
        logger.info("Posted media key \(key)")
    }

    /// True if the app may post synthetic key events. Otherwise prompts the user
    /// to grant Accessibility once (opens the System Settings pane).
    private static var didPromptForAX = false
    private func ensureAccessibilityTrust() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !Self.didPromptForAX {
            Self.didPromptForAX = true
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return false
    }

    private func controlScript(_ cmd: String) -> String {
        """
        if application "Spotify" is running then
            tell application "Spotify" to \(cmd)
        else if application "Music" is running then
            tell application "Music" to \(cmd)
        end if
        """
    }

    private func nowPlayingScript() -> String {
        """
        set out to ""
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is not stopped then
                    set out to (name of current track) & "\\n" & (artist of current track) & "\\n" & (player state as text)
                end if
            end tell
        end if
        if out is "" and application "Music" is running then
            tell application "Music"
                if player state is not stopped then
                    set out to (name of current track) & "\\n" & (artist of current track) & "\\n" & (player state as text)
                end if
            end tell
        end if
        return out
        """
    }

    private func pollMedia() {
        DispatchQueue.global(qos: .utility).async {
            let out = self.runOsa(self.nowPlayingScript(), capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
            var state = ABMacMediaState()
            let parts = out.components(separatedBy: "\n")
            if parts.count >= 3, !parts[0].isEmpty {
                state.hasMedia_p = true
                state.title = parts[0]
                state.artist = parts[1]
                state.isPlaying = parts[2].lowercased().contains("playing")
            } else {
                state.hasMedia_p = false
            }
            var env = ABEnvelope()
            env.macMediaState = state
            self.onSendEnvelope?(env)
        }
    }

    func sendStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let (level, charging) = self.batteryInfo()
            let (volume, muted) = self.volumeInfo()
            let wifi = self.wifiIsOn()
            let brightness = self.brightnessInfo()
            let bt = self.bluetoothIsOn()

            var status = ABMacStatus()
            status.batteryLevel = Int32(level)
            status.isCharging = charging
            status.deviceName = Host.current().localizedName ?? "Mac"
            status.volume = Int32(volume)
            status.muted = muted
            status.wifiOn = wifi
            status.brightness = Int32(brightness)
            status.bluetoothOn = bt

            var env = ABEnvelope()
            env.macStatus = status
            self.onSendEnvelope?(env)
        }
    }

    /// Reads current output volume (0-100) and mute state via AppleScript.
    private func volumeInfo() -> (Int, Bool) {
        let out = runOsa("set v to get volume settings\nreturn (output volume of v as text) & \"|\" & (output muted of v as text)", capture: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = out.components(separatedBy: "|")
        let vol = Int(parts.first ?? "") ?? -1
        let muted = parts.count > 1 && parts[1].lowercased().contains("true")
        return (vol, muted)
    }

    /// Checks whether Wi-Fi power is on.
    private func wifiIsOn() -> Bool {
        let device = wifiInterface()
        let out = run("/usr/sbin/networksetup", ["-getairportpower", device], capture: true)
        return out.contains(": On")
    }

    private func batteryInfo() -> (Int, Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (-1, false)
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? -1
            let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""
            let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? (state == (kIOPSACPowerValue as String))
            let pct = maxCap > 0 ? Int((Double(capacity) / Double(maxCap)) * 100.0) : capacity
            return (pct, isCharging)
        }
        return (-1, false)
    }
}

// MARK: - Private system APIs (brightness + Bluetooth)
//
// macOS has no public CLI/API to set display brightness or toggle Bluetooth.
// We dlopen the system frameworks and resolve the well-known private symbols
// used by the OS itself. Resolved lazily once; degrade gracefully if missing.

private enum PrivateAPI {
    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias CoreSetBrightnessFn = @convention(c) (CGDirectDisplayID, Double) -> Void
    typealias CoreGetBrightnessFn = @convention(c) (CGDirectDisplayID) -> Double
    typealias SetBTPowerFn = @convention(c) (Int32) -> Void
    typealias GetBTPowerFn = @convention(c) () -> Int32

    private static func sym<T>(_ image: String, _ name: String, _ type: T.Type) -> T? {
        guard let handle = dlopen(image, RTLD_LAZY), let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let coreDisplay = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
    private static let ioBluetooth = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"

    static let setBrightness = sym(displayServices, "DisplayServicesSetBrightness", SetBrightnessFn.self)
    static let getBrightness = sym(displayServices, "DisplayServicesGetBrightness", GetBrightnessFn.self)
    static let coreSetBrightness = sym(coreDisplay, "CoreDisplay_Display_SetUserBrightness", CoreSetBrightnessFn.self)
    static let coreGetBrightness = sym(coreDisplay, "CoreDisplay_Display_GetUserBrightness", CoreGetBrightnessFn.self)
    static let setBluetoothPower = sym(ioBluetooth, "IOBluetoothPreferenceSetControllerPowerState", SetBTPowerFn.self)
    static let getBluetoothPower = sym(ioBluetooth, "IOBluetoothPreferenceGetControllerPowerState", GetBTPowerFn.self)
}
