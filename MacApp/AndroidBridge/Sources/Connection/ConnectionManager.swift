import AppKit
import SwiftUI
import Foundation
import Network
import Combine
import os

final class ConnectionManager: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var phoneBattery: Int = -1          // 0-100, -1 = unknown
    @Published var phoneCharging: Bool = false

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Connection")

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var transport: MessageTransport?
    private var heartbeatTimer: DispatchSourceTimer?

    private let queue = DispatchQueue(label: "com.androidbridge.connection", qos: .userInitiated)

    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var isReconnecting = false

    // Feature handlers
    let notificationFeature = NotificationFeature()
    let smsFeature = SMSFeature()
    let clipboardFeature = ClipboardFeature()
    let urlHandoffFeature = URLHandoffFeature()
    let fileSystemFeature = FileSystemFeature()
    let galleryFeature = GalleryFeature()
    let screenMirrorFeature = ScreenMirrorFeature()
    let callFeature = CallFeature()
    let mediaControlFeature = MediaControlFeature()
    let macSystemFeature = MacSystemFeature()

    private var pairedDeviceId: String?
    private var pairedCertFingerprint: String?

    private var missedHeartbeats = 0

    // MARK: - Lifecycle

    func start() {
        logger.info("ConnectionManager starting")
        loadPairedDevice()
        setupCallHUDObserver()

        if pairedDeviceId != nil {
            startBrowsing()
        } else {
            logger.info("No paired device found — waiting for pairing")
            state = .disconnected
        }
    }

    private var callCancellables = Set<AnyCancellable>()
    private var callHUDObserverSet = false

    /// Show the call HUD the moment a call starts (dialing/ringing/active) — including
    /// outgoing calls dialed from the Mac — and hide it when the call ends.
    private var incomingRingSound: NSSound?

    private func setupCallHUDObserver() {
        guard !callHUDObserverSet else { return }
        callHUDObserverSet = true

        callFeature.$callState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .ringing:
                    self?.showCallHUD()
                    self?.startIncomingRing()
                case .dialing, .active, .held:
                    self?.showCallHUD()
                    self?.stopIncomingRing()
                case .idle:
                    self?.hideCallHUD()
                    self?.stopIncomingRing()
                }
            }
            .store(in: &callCancellables)
    }

    /// Ring with a looping default macOS sound while a call is incoming.
    private func startIncomingRing() {
        guard incomingRingSound == nil else { return }
        let sound = SystemSound.looping(["Glass", "Ping", "Sosumi"])
        sound?.play()
        incomingRingSound = sound
    }

    private func stopIncomingRing() {
        incomingRingSound?.stop()
        incomingRingSound = nil
    }

    func stop() {
        logger.info("ConnectionManager stopping")
        stopHeartbeat()
        stopDirectDialFallback()
        transport = nil
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        state = .disconnected
    }

    // MARK: - mDNS Discovery

    // MARK: - Direct-dial fallback (always-connected)
    //
    // mDNS can be flaky on some routers. The phone listens on a port derived
    // deterministically from the Mac's device id (same formula both sides), so
    // once we know the phone's last IP we can reconnect without discovery.

    private var fallbackTimer: DispatchSourceTimer?

    /// Same as Android's `derivePort` (Java String.hashCode semantics).
    private var derivedPhonePort: UInt16? {
        guard let macId = KeychainHelper.load(key: "mac_device_id") else { return nil }
        var h: Int32 = 0
        for u in macId.utf16 { h = 31 &* h &+ Int32(u) }
        let positive = Int(h) & 0x7FFF_FFFF
        return UInt16(10000 + (positive % 50000))
    }

    private func startDirectDialFallback() {
        fallbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 6, repeating: 8)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard case .searching = self.state else { return }
            guard let ip = KeychainHelper.load(key: "last_phone_ip"),
                  let port = self.derivedPhonePort,
                  let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            self.logger.info("mDNS quiet — direct-dialing last phone IP \(ip):\(port)")
            self.connect(to: .hostPort(host: NWEndpoint.Host(ip), port: nwPort))
        }
        timer.resume()
        fallbackTimer = timer
    }

    private func stopDirectDialFallback() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    /// Remember the phone's IP so the next reconnect can skip discovery.
    private func rememberPhoneAddress(of connection: NWConnection) {
        guard let remote = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, _) = remote else { return }
        var ip = "\(host)"
        if let percent = ip.firstIndex(of: "%") { ip = String(ip[..<percent]) }  // strip %en0
        guard !ip.isEmpty, ip != "127.0.0.1", ip != "::1" else { return }
        KeychainHelper.save(key: "last_phone_ip", value: ip)
        logger.info("Remembered phone address \(ip)")
    }

    func startBrowsing() {
        browser?.cancel()
        state = .searching
        logger.info("Starting mDNS browse for _androidbridge._tcp")
        startDirectDialFallback()

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_androidbridge._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)

        browser.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.logger.info("mDNS browser ready")
            case .failed(let error):
                self.logger.error("mDNS browser failed: \(error.localizedDescription)")
                self.scheduleBrowseRetry()
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    self.logger.info("Discovered service: \(name)")
                    if self.shouldConnect(to: name) {
                        self.browser?.cancel()
                        self.connect(to: result.endpoint)
                        return
                    }
                }
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    private func shouldConnect(to serviceName: String) -> Bool {
        guard let pairedId = pairedDeviceId else { return false }
        return serviceName.contains(pairedId.prefix(8))
    }

    private func scheduleBrowseRetry() {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.startBrowsing()
        }
    }

    // MARK: - Connection

    func connect(to endpoint: NWEndpoint) {
        logger.info("Connecting to \(endpoint.debugDescription)")
        state = .connecting

        // Use plain TCP for now — Android side doesn't have TLS yet
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.logger.info("Connection established")
                self.reconnectAttempt = 0
                self.isReconnecting = false
                self.stopDirectDialFallback()
                self.rememberPhoneAddress(of: connection)
                self.onConnected(connection)
            case .failed(let error):
                self.logger.error("Connection failed: \(error.localizedDescription)")
                self.scheduleReconnect()
            case .waiting(let error):
                self.logger.warning("Connection waiting: \(error.localizedDescription)")
            default:
                break
            }
        }

        connection.start(queue: queue)
        self.connection = connection
    }

    func connectUSB(port: UInt16) {
        logger.info("Connecting via USB on port \(port)")
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        connect(to: endpoint)
    }

    private func onConnected(_ connection: NWConnection) {
        let transport = MessageTransport(connection: connection)
        transport.handler = self
        transport.onDisconnect = { [weak self] in
            self?.queue.async {
                self?.logger.info("Transport reported disconnect — scheduling reconnect")
                self?.scheduleReconnect()
            }
        }
        self.transport = transport

        // Wire features to send through this transport
        let sendFn: (ABEnvelope) -> Void = { [weak self] envelope in
            self?.sendEnvelope(envelope)
        }
        notificationFeature.onSendAction = sendFn
        smsFeature.onSendEnvelope = sendFn
        clipboardFeature.onSendEnvelope = sendFn
        urlHandoffFeature.onSendEnvelope = sendFn
        fileSystemFeature.onSendEnvelope = sendFn
        galleryFeature.onSendEnvelope = sendFn
        screenMirrorFeature.onSendEnvelope = sendFn
        callFeature.onSendEnvelope = sendFn
        mediaControlFeature.onSendEnvelope = sendFn
        macSystemFeature.onSendEnvelope = sendFn
        macSystemFeature.startReporting()

        let macDeviceId = KeychainHelper.load(key: "mac_device_id") ?? "unknown"
        transport.sendHandshake(
            deviceId: macDeviceId,
            deviceName: Host.current().localizedName ?? "Mac",
            publicKey: Data()
        )

        transport.startReceiving()
        startHeartbeat()

        DispatchQueue.main.async {
            self.clipboardFeature.startMonitoring()
            self.state = .connected(deviceName: "Android Device")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        missedHeartbeats = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            if self.missedHeartbeats >= 3 {
                self.logger.warning("Missed 3 heartbeats — reconnecting")
                self.scheduleReconnect()
                return
            }

            self.missedHeartbeats += 1
            self.transport?.sendHeartbeat()
        }

        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        // Guard against multiple simultaneous reconnect triggers (heartbeat +
        // onDisconnect + connection.failed can all fire at once).
        guard !isReconnecting else { return }
        isReconnecting = true

        connection?.cancel()
        connection = nil
        transport = nil
        stopHeartbeat()

        DispatchQueue.main.async {
            self.state = .reconnecting
        }
        reconnectAttempt += 1

        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempt))")

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startBrowsing()
        }
    }

    // MARK: - Send Convenience

    func sendEnvelope(_ envelope: ABEnvelope) {
        transport?.send(envelope)
    }

    /// Ask the phone to start screen capture (shows its one-tap consent dialog
    /// if a projection session isn't already running).
    func requestMirrorStart() {
        guard !screenMirrorFeature.isActive else { return }
        var control = ABConnectionControl()
        control.action = .startMirror
        var envelope = ABEnvelope()
        envelope.connectionControl = control
        sendEnvelope(envelope)
        logger.info("Requested mirror start from phone")
    }

    /// Ask the phone to stop its background service (saves phone battery). The phone
    /// must be re-enabled from the phone's "Connect" button afterwards.
    func requestPhoneDisconnect() {
        var control = ABConnectionControl()
        control.action = .disconnect
        var envelope = ABEnvelope()
        envelope.connectionControl = control
        sendEnvelope(envelope)
        logger.info("Sent disconnect request to phone")
    }

    // MARK: - Call HUD

    private var callHUDWindow: NSWindow?

    func showCallHUD() {
        guard callHUDWindow == nil else {
            callHUDWindow?.orderFront(nil)
            return
        }

        let hudView = CallHUDView(callFeature: callFeature)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: hudView)
        window.title = "Phone Call"
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        // Position top-right
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 340
            let y = screen.visibleFrame.maxY - 240
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        callHUDWindow = window
    }

    func hideCallHUD() {
        // Delay hiding so user sees "Call ended" briefly
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.callHUDWindow?.close()
            self?.callHUDWindow = nil
        }
    }

    // MARK: - Pairing Storage

    private func loadPairedDevice() {
        pairedDeviceId = KeychainHelper.load(key: "paired_device_id")
        pairedCertFingerprint = KeychainHelper.load(key: "paired_cert_fingerprint")
        if let id = pairedDeviceId {
            logger.info("Loaded paired device: \(id.prefix(8))...")
        }
    }

    func savePairedDevice(deviceId: String, certFingerprint: Data) {
        let hex = certFingerprint.hexString
        KeychainHelper.save(key: "paired_device_id", value: deviceId)
        KeychainHelper.save(key: "paired_cert_fingerprint", value: hex)
        pairedDeviceId = deviceId
        pairedCertFingerprint = hex
        logger.info("Saved paired device: \(deviceId.prefix(8))...")
    }
}

// MARK: - MessageHandler

extension ConnectionManager: MessageHandler {
    func handleEnvelope(_ envelope: ABEnvelope) {
        switch envelope.payload {
        case .heartbeat:
            missedHeartbeats = 0
            logger.debug("Heartbeat received")

        case .handshakeResponse(let response):
            if response.accepted {
                logger.info("Handshake accepted by \(response.deviceName)")
                DispatchQueue.main.async {
                    self.state = .connected(deviceName: response.deviceName)
                }
            } else {
                logger.error("Handshake rejected: \(response.rejectReason)")
                scheduleReconnect()
            }

        case .deviceInfo(let info):
            logger.info("Device: \(info.deviceName), battery: \(info.batteryLevel)%")
            DispatchQueue.main.async {
                self.phoneBattery = Int(info.batteryLevel)
                self.phoneCharging = info.batteryCharging
            }

        case .notificationEvent(let event):
            logger.info("Notification from \(event.appName): \(event.title)")
            notificationFeature.handleNotification(event)

        case .smsConversation(let conv):
            logger.info("SMS conversation: \(conv.contactName)")
            smsFeature.handleConversation(conv)

        case .smsMessage(let msg):
            logger.info("SMS from \(msg.sender)")
            smsFeature.handleMessage(msg)

        case .smsDeliveryStatus(let status):
            smsFeature.handleDeliveryStatus(status)

        case .clipboardSync(let clip):
            logger.info("Clipboard sync from Android")
            clipboardFeature.applyFromAndroid(clip)

        case .urlHandoff(let handoff):
            logger.info("URL from Android: \(handoff.url)")
            urlHandoffFeature.openURLFromAndroid(handoff)

        case .fileListResponse(let response):
            logger.info("File list: \(response.entries.count) entries in \(response.path)")
            fileSystemFeature.handleListResponse(response)

        case .fileChunk(let chunk):
            fileSystemFeature.handleFileChunk(chunk)

        case .fileTransferComplete(let complete):
            fileSystemFeature.handleTransferComplete(complete)

        case .fileTransferCancel(let cancel):
            fileSystemFeature.handleTransferCancel(cancel)

        case .galleryResponse(let response):
            logger.info("Gallery: \(response.items.count) photos")
            galleryFeature.handleResponse(response)

        case .galleryAlbumsResponse(let response):
            logger.info("Gallery albums: \(response.albums.count)")
            galleryFeature.handleAlbumsResponse(response)

        case .fileOperationResult(let result):
            logger.info("File operation result: \(result.success)")
            fileSystemFeature.handleOperationResult(result)

        case .macControl(let control):
            logger.info("Mac control: \(String(describing: control.action))")
            macSystemFeature.handleControl(control)

        case .macMediaControl(let control):
            macSystemFeature.handleMediaControl(control)

        case .videoConfig(let config):
            logger.info("Video config: \(config.width)x\(config.height)")
            screenMirrorFeature.handleVideoConfig(config)

        case .videoFrame(let frame):
            screenMirrorFeature.handleVideoFrame(frame)

        case .callEvent(let call):
            logger.info("Call event: \(String(describing: call.state)) from \(call.phoneNumber)")
            callFeature.handleCallEvent(call)
            if call.state == .ringing || call.state == .active || call.state == .dialing {
                DispatchQueue.main.async { self.showCallHUD() }
            } else if call.state == .ended {
                DispatchQueue.main.async { self.hideCallHUD() }
            }

        case .callAudioChunk(let chunk):
            callFeature.handleAudioChunk(chunk)

        case .contactList(let list):
            logger.info("Received \(list.contacts.count) contacts")
            callFeature.handleContactList(list)

        case .callLogList(let list):
            logger.info("Received \(list.entries.count) call-log entries")
            callFeature.handleCallLogList(list)

        case .mediaState(let media):
            logger.info("Now playing: \(media.title) — \(media.artist)")
            mediaControlFeature.handleMediaState(media)

        case .ack(let ack):
            logger.debug("ACK for seq \(ack.sequence): success=\(ack.success)")

        default:
            logger.debug("Unhandled message type")
        }
    }
}

// MARK: - Data Helpers

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
