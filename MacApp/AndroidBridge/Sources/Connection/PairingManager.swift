import Foundation
import Network
import CryptoKit
import Security
import os

final class PairingManager: ObservableObject {
    @Published var state: PairingState = .idle
    @Published var qrPayload: String = ""

    enum PairingState: Equatable {
        case idle
        case waitingForPhone
        case connecting
        case paired(deviceName: String)
        case failed(String)
    }

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Pairing")
    private let queue = DispatchQueue(label: "com.androidbridge.pairing")
    private var listener: NWListener?
    private var pairingPort: UInt16 = 0
    private var macDeviceId: String = ""
    private var publicKeyB64: String = ""

    // MARK: - Start Pairing

    func startPairing(onComplete: @escaping (Bool) -> Void) {
        macDeviceId = loadOrCreateDeviceId()
        let keyPair = generateOrLoadKeyPair()
        publicKeyB64 = keyPair?.base64EncodedString() ?? ""

        startListener(onComplete: onComplete)
    }

    func stopPairing() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Listener

    /// Fixed pairing port so a QR stays valid across app restarts (random ports
    /// meant every relaunch invalidated the on-screen code → "connection refused").
    private static let fixedPairingPort: UInt16 = 47291

    private func startListener(onComplete: @escaping (Bool) -> Void, useFixedPort: Bool = true) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true   // survive TIME_WAIT on relaunch
            let listener: NWListener
            if useFixedPort, let port = NWEndpoint.Port(rawValue: Self.fixedPairingPort) {
                listener = try NWListener(using: params, on: port)
            } else {
                listener = try NWListener(using: params, on: .any)
            }

            listener.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    if let actualPort = listener.port {
                        self.pairingPort = actualPort.rawValue
                        self.logger.info("Pairing listener ready on port \(self.pairingPort)")
                        self.generateQRPayload()
                    }
                case .failed(let error):
                    self.logger.error("Pairing listener failed: \(error.localizedDescription)")
                    // The fixed port may be momentarily busy — fall back to a random one.
                    if useFixedPort {
                        self.logger.info("Retrying pairing listener on a random port")
                        listener.cancel()
                        self.listener = nil
                        self.startListener(onComplete: onComplete, useFixedPort: false)
                    } else {
                        DispatchQueue.main.async {
                            self.state = .failed("Network error: \(error.localizedDescription)")
                            onComplete(false)
                        }
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.logger.info("Phone connected for pairing")
                DispatchQueue.main.async {
                    self?.state = .connecting
                }
                self?.handlePairingConnection(connection, onComplete: onComplete)
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            logger.error("Failed to start listener: \(error.localizedDescription)")
            if useFixedPort {
                startListener(onComplete: onComplete, useFixedPort: false)
            } else {
                DispatchQueue.main.async {
                    self.state = .failed("Cannot start listener")
                    onComplete(false)
                }
            }
        }
    }

    private func generateQRPayload() {
        let allIPs = getAllLocalIPAddresses()
        let primaryIP = allIPs.first ?? "0.0.0.0"

        logger.info("Local IPs: \(allIPs.joined(separator: ", "))")

        // Keep QR small: just version, IP(s), port, and short ID
        // Public key is exchanged over TCP after the phone connects
        var payload: [String: Any] = [
            "v": 1,
            "id": String(macDeviceId.prefix(8)),
            "port": Int(pairingPort),
            "ip": primaryIP
        ]
        if allIPs.count > 1 {
            payload["ips"] = allIPs
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            DispatchQueue.main.async {
                self.state = .failed("Failed to create QR data")
            }
            return
        }

        logger.info("QR payload: \(jsonString.count) chars, port=\(self.pairingPort) ip=\(primaryIP)")

        DispatchQueue.main.async {
            self.qrPayload = jsonString
            self.state = .waitingForPhone
        }
    }

    // MARK: - Connection Handling

    private func handlePairingConnection(_ connection: NWConnection, onComplete: @escaping (Bool) -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                // Mac sends its info FIRST, then waits for phone's response
                self?.sendMacInfo(connection, onComplete: onComplete)
            }
        }
        connection.start(queue: queue)
    }

    private func sendMacInfo(_ connection: NWConnection, onComplete: @escaping (Bool) -> Void) {
        let macInfo: [String: Any] = [
            "id": macDeviceId,
            "pk": publicKeyB64,
            "name": Host.current().localizedName ?? "Mac"
        ]

        guard let macData = try? JSONSerialization.data(withJSONObject: macInfo) else {
            DispatchQueue.main.async {
                self.state = .failed("Failed to serialize Mac info")
                onComplete(false)
            }
            return
        }

        let header = withUnsafeBytes(of: UInt32(macData.count).bigEndian) { Data($0) }
        connection.send(content: header + macData, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("Failed to send Mac info: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.state = .failed("Send failed")
                    onComplete(false)
                }
                return
            }
            self?.receivePhoneResponse(connection, onComplete: onComplete)
        })
    }

    private func receivePhoneResponse(_ connection: NWConnection, onComplete: @escaping (Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] headerData, _, _, error in
            guard let self, let headerData, headerData.count == 4 else {
                DispatchQueue.main.async {
                    self?.state = .failed("Connection lost")
                    onComplete(false)
                }
                return
            }

            let length = headerData.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            guard length > 0 && length < 100_000 else {
                DispatchQueue.main.async {
                    self.state = .failed("Invalid data length")
                    onComplete(false)
                }
                return
            }

            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let phoneDeviceId = json["id"] as? String else {
                    DispatchQueue.main.async {
                        self.state = .failed("Invalid pairing data")
                        onComplete(false)
                    }
                    return
                }

                let phoneName = json["name"] as? String ?? "Android Device"
                let phonePkB64 = json["pk"] as? String ?? ""

                let fingerprint = self.sha256Hex(Data(phonePkB64.utf8))
                KeychainHelper.save(key: "paired_device_id", value: phoneDeviceId)
                KeychainHelper.save(key: "paired_cert_fingerprint", value: fingerprint)

                connection.cancel()
                self.listener?.cancel()
                self.listener = nil

                self.logger.info("Paired with \(phoneName) (\(phoneDeviceId.prefix(8)))")

                DispatchQueue.main.async {
                    self.state = .paired(deviceName: phoneName)
                    onComplete(true)
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadOrCreateDeviceId() -> String {
        if let existing = KeychainHelper.load(key: "mac_device_id") {
            return existing
        }
        let id = UUID().uuidString
        KeychainHelper.save(key: "mac_device_id", value: id)
        return id
    }

    private func generateOrLoadKeyPair() -> Data? {
        let tag = "com.androidbridge.mac.rsa"
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]

        var ref: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
           let key = ref as! SecKey?,
           let pubKey = SecKeyCopyPublicKey(key),
           let pubData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? {
            return pubData
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }
        return publicKeyData
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func getAllLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" || name == "en2" || name == "en3" || name == "en4" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen = socklen_t(ptr.pointee.ifa_addr.pointee.sa_len)
            if getnameinfo(ptr.pointee.ifa_addr, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let addr = String(cString: hostname)
                if !addr.isEmpty && addr != "0.0.0.0" {
                    addresses.append(addr)
                }
            }
        }
        return addresses
    }
}
