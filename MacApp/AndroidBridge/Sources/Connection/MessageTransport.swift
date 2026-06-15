import Foundation
import Network
import SwiftProtobuf
import os

protocol MessageHandler: AnyObject {
    func handleEnvelope(_ envelope: ABEnvelope)
}

final class MessageTransport {
    private let connection: NWConnection
    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Transport")

    weak var handler: MessageHandler?
    var onDisconnect: (() -> Void)?

    private var sequenceCounter: UInt64 = 0
    private let sequenceLock = NSLock()
    private var didDisconnect = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    private func notifyDisconnect() {
        guard !didDisconnect else { return }
        didDisconnect = true
        onDisconnect?()
    }

    // MARK: - Send

    func send(_ envelope: ABEnvelope) {
        do {
            let data = try envelope.serializedData()
            sendFramed(data)
        } catch {
            logger.error("Failed to serialize envelope: \(error.localizedDescription)")
        }
    }

    func sendHeartbeat() {
        var envelope = ABEnvelope()
        envelope.sequence = nextSequence()
        envelope.timestampMs = currentTimestampMs()
        var heartbeat = ABHeartbeat()
        heartbeat.timestampMs = currentTimestampMs()
        envelope.heartbeat = heartbeat
        send(envelope)
    }

    func sendHandshake(deviceId: String, deviceName: String, publicKey: Data) {
        var envelope = ABEnvelope()
        envelope.sequence = nextSequence()
        envelope.timestampMs = currentTimestampMs()
        var handshake = ABHandshake()
        handshake.deviceID = deviceId
        handshake.deviceName = deviceName
        handshake.protocolVersion = 1
        handshake.publicKey = publicKey
        envelope.handshake = handshake
        send(envelope)
    }

    func sendAck(forSequence seq: UInt64, success: Bool, error: String = "") {
        var envelope = ABEnvelope()
        envelope.sequence = nextSequence()
        envelope.timestampMs = currentTimestampMs()
        var ack = ABAck()
        ack.sequence = seq
        ack.success = success
        ack.error = error
        envelope.ack = ack
        send(envelope)
    }

    // MARK: - Receive Loop

    func startReceiving() {
        receiveHeader()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.error("Receive header error: \(error.localizedDescription)")
                self.notifyDisconnect()
                return
            }

            guard let data, data.count == 4 else {
                if isComplete {
                    self.logger.info("Connection closed by peer")
                }
                self.notifyDisconnect()
                return
            }

            let length = data.withUnsafeBytes { buf in
                Int(buf.load(as: UInt32.self).bigEndian)
            }

            guard length > 0, length <= 10_485_760 else {
                self.logger.error("Invalid message length: \(length)")
                self.notifyDisconnect()
                return
            }

            self.receiveBody(length: length)
        }
    }

    private func receiveBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.error("Receive body error: \(error.localizedDescription)")
                self.notifyDisconnect()
                return
            }

            if let data {
                self.handleReceivedData(data)
            }

            if isComplete {
                self.notifyDisconnect()
            } else {
                self.receiveHeader()
            }
        }
    }

    private func handleReceivedData(_ data: Data) {
        do {
            let envelope = try ABEnvelope(serializedData: data)
            logger.debug("Received message seq=\(envelope.sequence)")
            handler?.handleEnvelope(envelope)
        } catch {
            logger.error("Failed to deserialize envelope: \(error.localizedDescription)")
        }
    }

    // MARK: - Framing

    private func sendFramed(_ data: Data) {
        let header = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }

        connection.send(content: header + data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("Send error: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - Helpers

    private func nextSequence() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sequenceCounter += 1
        return sequenceCounter
    }

    private func currentTimestampMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
