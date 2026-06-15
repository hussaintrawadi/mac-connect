import AppKit
import SwiftUI
import ServiceManagement
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    let connectionManager = ConnectionManager()

    static let logger = Logger(subsystem: "com.androidbridge.mac", category: "App")

    /// Right-click Dock menu — jump straight to any feature window.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let items: [(String, Notification.Name)] = [
            ("Mirror Screen", .openMirror),
            ("Messages", .openSMS),
            ("Files", .openFiles),
            ("Gallery", .openGallery),
            ("Phone", .openDialPad),
        ]
        for (title, name) in items {
            let item = NSMenuItem(title: title, action: #selector(dockMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        return menu
    }

    @objc private func dockMenuAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? Notification.Name else { return }
        NotificationCenter.default.post(name: name, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("AndroidBridge starting up")

        applyStoredAppearance()
        registerAutoLaunch()
        statusBarController = StatusBarController(connectionManager: connectionManager)
        registerDashboardNotifications()

        connectionManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.info("AndroidBridge shutting down")
        connectionManager.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Re-open main window when dock icon is clicked
            for window in NSApp.windows {
                if window.title == "AndroidBridge" || window.contentView is NSHostingView<WelcomeView> {
                    window.makeKeyAndOrderFront(nil)
                    return true
                }
            }
        }
        return true
    }

    // MARK: - Appearance

    private func applyStoredAppearance() {
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    // MARK: - Dashboard Notifications

    private func registerDashboardNotifications() {
        NotificationCenter.default.addObserver(forName: .openMirror, object: nil, queue: .main) { [weak self] _ in
            self?.statusBarController?.triggerMirrorScreen()
        }
        NotificationCenter.default.addObserver(forName: .openSMS, object: nil, queue: .main) { [weak self] _ in
            self?.statusBarController?.triggerOpenSMS()
        }
        NotificationCenter.default.addObserver(forName: .openFiles, object: nil, queue: .main) { [weak self] _ in
            self?.statusBarController?.triggerOpenFiles()
        }
        NotificationCenter.default.addObserver(forName: .openGallery, object: nil, queue: .main) { [weak self] _ in
            self?.statusBarController?.triggerOpenGallery()
        }
        NotificationCenter.default.addObserver(forName: .openDialPad, object: nil, queue: .main) { [weak self] _ in
            self?.statusBarController?.triggerOpenDialPad()
        }
    }

    // MARK: - Auto Launch

    private func registerAutoLaunch() {
        guard UserDefaults.standard.bool(forKey: "launchAtLogin") else { return }
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                Self.logger.info("Registered for launch at login")
            } catch {
                Self.logger.warning("Failed to register launch at login: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Demo Data

    #if DEBUG
    private func loadDemoData() {
        Self.logger.info("Loading demo data for preview")
        connectionManager.state = .connected(deviceName: "Pixel 8 Pro")

        let sms = connectionManager.smsFeature
        let now = Date()

        let convos: [(String, String, String, String, Int)] = [
            ("1", "Mom", "+1 555-0101", "Don't forget to eat lunch! Love you", 0),
            ("2", "Ahmed K.", "+1 555-0202", "Are we still on for tomorrow?", 2),
            ("3", "Work - Sarah", "+1 555-0303", "The meeting has been moved to 3pm", 1),
            ("4", "Ali", "+1 555-0404", "Haha that was hilarious", 0),
            ("5", "Delivery Updates", "+1 555-0505", "Your package has been delivered to front door", 0),
        ]

        for (i, (tid, name, number, msg, unread)) in convos.enumerated() {
            sms.conversations.append(SMSConversation(
                threadId: tid, contactName: name, contactNumber: number,
                lastMessage: msg, lastTimestamp: now.addingTimeInterval(Double(-i * 3600)),
                unreadCount: unread
            ))
        }

        let msgs: [(String, Bool)] = [
            ("Hey how are you doing?", false),
            ("I'm good! Just working on the app", true),
            ("That's great! What app?", false),
            ("AndroidBridge - it connects Android to Mac", true),
            ("Wow that sounds cool!", false),
            ("Don't forget to eat lunch! Love you", false),
        ]

        for (i, (body, isOut)) in msgs.enumerated() {
            sms.activeMessages.append(SMSMessageItem(
                messageId: "msg-\(i)", threadId: "1",
                sender: isOut ? "me" : "+1 555-0101", body: body,
                timestamp: now.addingTimeInterval(Double(-3600 + i * 120)),
                isOutgoing: isOut, isRead: true
            ))
        }
        sms.activeThread = "1"

        let fs = connectionManager.fileSystemFeature
        fs.currentPath = "/storage/emulated/0"
        fs.entries = [
            FileItem(name: "DCIM", path: "/storage/emulated/0/DCIM", isDirectory: true, sizeBytes: 0, modifiedDate: now.addingTimeInterval(-86400), mimeType: "inode/directory"),
            FileItem(name: "Download", path: "/storage/emulated/0/Download", isDirectory: true, sizeBytes: 0, modifiedDate: now.addingTimeInterval(-3600), mimeType: "inode/directory"),
            FileItem(name: "Documents", path: "/storage/emulated/0/Documents", isDirectory: true, sizeBytes: 0, modifiedDate: now.addingTimeInterval(-7200), mimeType: "inode/directory"),
            FileItem(name: "Music", path: "/storage/emulated/0/Music", isDirectory: true, sizeBytes: 0, modifiedDate: now.addingTimeInterval(-172800), mimeType: "inode/directory"),
            FileItem(name: "Pictures", path: "/storage/emulated/0/Pictures", isDirectory: true, sizeBytes: 0, modifiedDate: now.addingTimeInterval(-259200), mimeType: "inode/directory"),
            FileItem(name: "screenshot_2026.png", path: "/storage/emulated/0/screenshot_2026.png", isDirectory: false, sizeBytes: 2_450_000, modifiedDate: now.addingTimeInterval(-1800), mimeType: "image/png"),
            FileItem(name: "meeting_notes.pdf", path: "/storage/emulated/0/meeting_notes.pdf", isDirectory: false, sizeBytes: 540_000, modifiedDate: now.addingTimeInterval(-7200), mimeType: "application/pdf"),
            FileItem(name: "voice_recording.m4a", path: "/storage/emulated/0/voice_recording.m4a", isDirectory: false, sizeBytes: 8_900_000, modifiedDate: now.addingTimeInterval(-14400), mimeType: "audio/mp4"),
            FileItem(name: "backup.zip", path: "/storage/emulated/0/backup.zip", isDirectory: false, sizeBytes: 156_000_000, modifiedDate: now.addingTimeInterval(-86400), mimeType: "application/zip"),
        ]

        connectionManager.mediaControlFeature.title = "Blinding Lights"
        connectionManager.mediaControlFeature.artist = "The Weeknd"
        connectionManager.mediaControlFeature.isPlaying = true
        connectionManager.mediaControlFeature.durationMs = 200_000
        connectionManager.mediaControlFeature.positionMs = 45_000
    }
    #endif
}
