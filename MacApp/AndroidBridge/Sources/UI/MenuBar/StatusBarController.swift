import AppKit
import SwiftUI
import Combine
import LocalAuthentication
import os

final class StatusBarController {
    private var statusItem: NSStatusItem
    private let connectionManager: ConnectionManager
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "StatusBar")
    private let popover = NSPopover()

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        setupStatusItem()
        observeConnectionState()
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }

        let image = NSImage(systemSymbolName: "iphone.slash", accessibilityDescription: "Mac Connect")
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(togglePopover)

        // Premium custom dropdown panel instead of the plain native menu.
        let view = MenuBarPopoverView(
            connectionManager: connectionManager,
            onMirror: { [weak self] in self?.popover.performClose(nil); self?.mirrorScreen() },
            onMessages: { [weak self] in self?.popover.performClose(nil); self?.openSMS() },
            onFiles: { [weak self] in self?.popover.performClose(nil); self?.openFiles() },
            onGallery: { [weak self] in self?.popover.performClose(nil); self?.openGallery() },
            onPhone: { [weak self] in self?.popover.performClose(nil); self?.openDialPad() },
            onPair: { [weak self] in self?.popover.performClose(nil); self?.pairDevice() },
            onDisconnect: { [weak self] in self?.popover.performClose(nil); self?.disconnectPhone() },
            onSettings: { [weak self] in
                self?.popover.performClose(nil)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
            onQuit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .transient
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // Status + device info
        let statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 1
        menu.addItem(statusMenuItem)

        let batteryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        batteryItem.tag = 2
        batteryItem.isHidden = true
        menu.addItem(batteryItem)

        menu.addItem(NSMenuItem.separator())

        // Now Playing
        let nowPlayingHeader = NSMenuItem(title: "Now Playing", action: nil, keyEquivalent: "")
        nowPlayingHeader.tag = 20
        nowPlayingHeader.isHidden = true
        menu.addItem(nowPlayingHeader)

        let nowPlayingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        nowPlayingItem.tag = 21
        nowPlayingItem.isHidden = true
        menu.addItem(nowPlayingItem)

        let mediaControlsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mediaControlsItem.tag = 22
        mediaControlsItem.isHidden = true
        menu.addItem(mediaControlsItem)

        let mediaSeparator = NSMenuItem.separator()
        mediaSeparator.tag = 23
        mediaSeparator.isHidden = true
        menu.addItem(mediaSeparator)

        // Pair
        let pairItem = NSMenuItem(title: "Pair New Device…", action: #selector(pairDevice), keyEquivalent: "p")
        pairItem.target = self
        pairItem.image = menuSymbol("plus.circle")
        menu.addItem(pairItem)

        // Disconnect phone (save battery)
        let disconnectItem = NSMenuItem(title: "Disconnect Phone", action: #selector(disconnectPhone), keyEquivalent: "")
        disconnectItem.target = self
        disconnectItem.tag = 15
        disconnectItem.image = menuSymbol("bolt.slash")
        menu.addItem(disconnectItem)

        menu.addItem(NSMenuItem.separator())

        // Features
        let mirrorItem = NSMenuItem(title: "Mirror Screen", action: #selector(mirrorScreen), keyEquivalent: "m")
        mirrorItem.target = self
        mirrorItem.tag = 10
        mirrorItem.image = menuSymbol("rectangle.on.rectangle")
        menu.addItem(mirrorItem)

        let smsItem = NSMenuItem(title: "Messages", action: #selector(openSMS), keyEquivalent: "s")
        smsItem.target = self
        smsItem.tag = 11
        smsItem.image = menuSymbol("message")
        menu.addItem(smsItem)

        let filesItem = NSMenuItem(title: "Files", action: #selector(openFiles), keyEquivalent: "f")
        filesItem.target = self
        filesItem.tag = 12
        filesItem.image = menuSymbol("folder")
        menu.addItem(filesItem)

        let galleryItem = NSMenuItem(title: "Gallery", action: #selector(openGallery), keyEquivalent: "g")
        galleryItem.target = self
        galleryItem.tag = 14
        galleryItem.image = menuSymbol("photo.on.rectangle")
        menu.addItem(galleryItem)

        let dialItem = NSMenuItem(title: "Phone", action: #selector(openDialPad), keyEquivalent: "d")
        dialItem.target = self
        dialItem.tag = 13
        dialItem.image = menuSymbol("phone")
        menu.addItem(dialItem)

        menu.addItem(NSMenuItem.separator())

        // Media controls inline
        let prevItem = NSMenuItem(title: "Previous Track", action: #selector(mediaPrevious), keyEquivalent: "[")
        prevItem.target = self
        prevItem.tag = 30
        prevItem.image = menuSymbol("backward.fill")
        menu.addItem(prevItem)

        let playPauseItem = NSMenuItem(title: "Play / Pause", action: #selector(mediaPlayPause), keyEquivalent: " ")
        playPauseItem.target = self
        playPauseItem.tag = 31
        playPauseItem.image = menuSymbol("playpause.fill")
        menu.addItem(playPauseItem)

        let nextItem = NSMenuItem(title: "Next Track", action: #selector(mediaNext), keyEquivalent: "]")
        nextItem.target = self
        nextItem.tag = 32
        nextItem.image = menuSymbol("forward.fill")
        menu.addItem(nextItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Mac Connect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = menuSymbol("power")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// A small, template SF Symbol sized for menu rows so every item lines up neatly.
    private func menuSymbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private func observeConnectionState() {
        connectionManager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusIcon(for: state)
            }
            .store(in: &cancellables)

    }

    private func updateStatusIcon(for state: ConnectionState) {
        let symbol: String
        switch state {
        case .disconnected: symbol = "iphone.slash"
        case .searching, .connecting: symbol = "iphone.radiowaves.left.and.right"
        case .connected: symbol = "iphone"
        case .reconnecting: symbol = "arrow.triangle.2.circlepath"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Media Actions

    @objc private func disconnectPhone() {
        connectionManager.requestPhoneDisconnect()
    }

    @objc private func mediaPrevious() { connectionManager.mediaControlFeature.previous() }
    @objc private func mediaPlayPause() { connectionManager.mediaControlFeature.togglePlayPause() }
    @objc private func mediaNext() { connectionManager.mediaControlFeature.next() }

    private var pairingWindow: NSWindow?

    @objc private func pairDevice() {
        logger.info("Opening pairing flow")

        if pairingWindow != nil {
            pairingWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let pairingView = PairingView(onPaired: { [weak self] in
            self?.pairingWindow?.close()
            self?.pairingWindow = nil
            self?.connectionManager.start()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: pairingView)
        window.title = "Pair with Android"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)

        pairingWindow = window
    }

    private var mirrorWindow: NSWindow?

    @objc private func mirrorScreen() {
        // Seeing/controlling the phone is sensitive — require Touch ID
        // (or the Mac password) before the mirror opens.
        let context = LAContext()
        context.localizedReason = "view and control your Android phone"
        var authError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "view and control your Android phone") { [weak self] ok, _ in
                DispatchQueue.main.async {
                    if ok { self?.openMirrorWindow() }
                }
            }
        } else {
            // No auth available on this Mac — open directly.
            openMirrorWindow()
        }
    }

    private func openMirrorWindow() {
        logger.info("Opening screen mirror")

        // If the phone isn't capturing yet, ask it to start — the phone shows
        // its one-tap consent dialog and frames begin flowing.
        connectionManager.requestMirrorStart()

        if mirrorWindow != nil {
            mirrorWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let mirrorView = MirrorView(
            mirrorFeature: connectionManager.screenMirrorFeature,
            fileSystem: connectionManager.fileSystemFeature
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: mirrorView)
        window.title = "Android Screen"
        window.backgroundColor = .black
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)

        mirrorWindow = window

        // Auto-size the window to the phone's real aspect ratio when the video config arrives.
        connectionManager.screenMirrorFeature.$videoWidth
            .combineLatest(connectionManager.screenMirrorFeature.$videoHeight)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] width, height in
                self?.resizeMirrorWindow(width: width, height: height)
            }
            .store(in: &mirrorCancellables)

        // Apply immediately if we already know the dimensions.
        let f = connectionManager.screenMirrorFeature
        resizeMirrorWindow(width: f.videoWidth, height: f.videoHeight)
    }

    private var mirrorCancellables = Set<AnyCancellable>()

    private func resizeMirrorWindow(width: Int, height: Int) {
        guard let window = mirrorWindow, width > 0, height > 0 else { return }
        let aspect = CGFloat(width) / CGFloat(height)
        window.contentAspectRatio = NSSize(width: width, height: height)

        // Fit a comfortable height on screen while preserving the phone's aspect ratio.
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let targetHeight = min(CGFloat(760), maxHeight)
        let targetWidth = targetHeight * aspect
        window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        window.center()
    }

    private var smsWindow: NSWindow?

    @objc private func openSMS() {
        logger.info("Opening SMS")

        if smsWindow != nil {
            smsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let smsView = SMSView(smsFeature: connectionManager.smsFeature)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: smsView)
        window.title = "Messages"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)

        smsWindow = window
    }

    private var filesWindow: NSWindow?

    @objc private func openFiles() {
        logger.info("Opening file browser")

        if filesWindow != nil {
            filesWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let filesView = FileBrowserView(fileSystem: connectionManager.fileSystemFeature)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: filesView)
        window.title = "Android Files"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)

        filesWindow = window
    }

    private var galleryWindow: NSWindow?

    @objc private func openGallery() {
        logger.info("Opening gallery")

        if galleryWindow != nil {
            galleryWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let galleryView = GalleryView(
            gallery: connectionManager.galleryFeature,
            fileSystem: connectionManager.fileSystemFeature
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: galleryView)
        window.title = "Android Photos"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)

        galleryWindow = window
    }

    private var dialPadWindow: NSWindow?

    @objc private func openDialPad() {
        logger.info("Opening phone")

        if dialPadWindow != nil {
            dialPadWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let phoneView = PhoneView(callFeature: connectionManager.callFeature)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: phoneView)
        window.contentMinSize = NSSize(width: 340, height: 560)
        window.title = "Phone"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)

        dialPadWindow = window
    }

    // MARK: - Public Triggers (for dashboard buttons)

    func triggerMirrorScreen() { mirrorScreen() }
    func triggerOpenSMS() { openSMS() }
    func triggerOpenFiles() { openFiles() }
    func triggerOpenGallery() { openGallery() }
    func triggerOpenDialPad() { openDialPad() }
}
