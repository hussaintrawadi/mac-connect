import Foundation
import AVFoundation
import Combine
import os

final class CallFeature: ObservableObject {
    @Published var callState: CallState = .idle
    @Published var callerName: String = ""
    @Published var callerNumber: String = ""
    @Published var isOutgoing: Bool = false
    @Published var isMuted: Bool = false
    @Published var callDuration: TimeInterval = 0
    @Published var contacts: [ContactItem] = []
    @Published var recentCalls: [RecentCall] = []

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Calls")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    private var callTimer: Timer?
    private var callStartTime: Date?

    // Audio
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?

    enum CallState {
        case idle, ringing, active, held, dialing
    }

    // MARK: - Call Events from Android

    func handleCallEvent(_ event: ABCallEvent) {
        DispatchQueue.main.async {
            self.callerNumber = event.phoneNumber
            self.callerName = event.contactName.isEmpty ? event.phoneNumber : event.contactName
            self.isOutgoing = event.isOutgoing

            switch event.state {
            case .ringing:
                self.callState = .ringing
                self.logger.info("Incoming call from \(self.callerName)")

            case .active:
                self.callState = .active
                self.startCallTimer()
                self.startAudioEngine()
                self.logger.info("Call active with \(self.callerName)")

            case .ended:
                self.callState = .idle
                self.stopCallTimer()
                self.stopAudioEngine()
                self.callerName = ""
                self.callerNumber = ""
                self.callDuration = 0
                self.isMuted = false
                self.logger.info("Call ended")

            case .held:
                self.callState = .held

            case .dialing:
                self.callState = .dialing

            default:
                break
            }
        }
    }

    // MARK: - Audio from Android → Mac Speaker

    func handleAudioChunk(_ chunk: ABCallAudioChunk) {
        guard let playerNode, let audioFormat else { return }

        let data = chunk.opusData
        guard !data.isEmpty else { return }

        // Convert PCM bytes to audio buffer
        let frameCount = AVAudioFrameCount(data.count / 2) // 16-bit = 2 bytes per sample
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            guard let dst = buffer.int16ChannelData?[0] else { return }
            for i in 0..<Int(frameCount) {
                dst[i] = src[i]
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    // MARK: - Mac Mic → Android

    private func startAudioEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        audioFormat = format

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Capture Mac mic
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap on input to capture mic audio
        let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        inputNode.installTap(onBus: 0, bufferSize: 640, format: inputFormat) { [weak self] buffer, time in
            self?.processMicBuffer(buffer, inputFormat: inputFormat)
        }

        do {
            try engine.start()
            audioEngine = engine
            playerNode = player
            logger.info("Audio engine started")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        audioFormat = nil
    }

    private func processMicBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        // Convert to 16kHz mono PCM
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        // Simple downsampling: take every Nth sample to get ~16kHz
        let ratio = max(1, Int(inputFormat.sampleRate / 16000))
        let outputCount = frameCount / ratio
        var pcmData = Data(count: outputCount * 2)

        pcmData.withUnsafeMutableBytes { rawBuf in
            guard let dst = rawBuf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<outputCount {
                let sample = channelData[i * ratio]
                dst[i] = Int16(max(-1.0, min(1.0, sample)) * Float(Int16.max))
            }
        }

        var chunk = ABCallAudioChunk()
        chunk.opusData = pcmData
        chunk.timestampUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)

        var envelope = ABEnvelope()
        envelope.callAudioChunk = chunk
        onSendEnvelope?(envelope)
    }

    // MARK: - Controls

    func answer() {
        var control = ABCallControl()
        control.action = .answer
        sendControl(control)
    }

    func decline() {
        var control = ABCallControl()
        control.action = .decline
        sendControl(control)
        endCallLocally()
    }

    func hangUp() {
        var control = ABCallControl()
        control.action = .hangUp
        sendControl(control)
        // Close the HUD immediately even if the phone is slow to report the end.
        endCallLocally()
    }

    func sendDTMF(_ digit: String) {
        var control = ABCallControl()
        control.action = .dtmf
        control.dtmfDigit = digit
        sendControl(control)
    }

    private func endCallLocally() {
        DispatchQueue.main.async {
            self.callState = .idle
            self.stopCallTimer()
            self.stopAudioEngine()
            self.callerName = ""
            self.callerNumber = ""
            self.callDuration = 0
            self.isMuted = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        var control = ABCallControl()
        control.action = isMuted ? .mute : .unmute
        sendControl(control)
    }

    func dial(number: String) {
        var control = ABCallControl()
        control.action = .dial
        control.phoneNumber = number
        sendControl(control)

        DispatchQueue.main.async {
            self.callState = .dialing
            self.callerNumber = number
            self.callerName = number
        }
    }

    private func sendControl(_ control: ABCallControl) {
        var envelope = ABEnvelope()
        envelope.callControl = control
        onSendEnvelope?(envelope)
    }

    // MARK: - Timer

    private func startCallTimer() {
        callStartTime = Date()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.callStartTime else { return }
            DispatchQueue.main.async {
                self.callDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopCallTimer() {
        callTimer?.invalidate()
        callTimer = nil
        callStartTime = nil
    }

    var formattedDuration: String {
        let mins = Int(callDuration) / 60
        let secs = Int(callDuration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Contacts

    func requestContacts() {
        var request = ABContactRequest()
        request.searchQuery = ""
        var envelope = ABEnvelope()
        envelope.contactRequest = request
        onSendEnvelope?(envelope)
    }

    func handleContactList(_ list: ABContactList) {
        let items = list.contacts.compactMap { c -> ContactItem? in
            let number = c.phoneNumbers.first ?? ""
            guard !number.isEmpty else { return nil }
            return ContactItem(name: c.name, number: number)
        }
        DispatchQueue.main.async {
            self.contacts = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Call log (recents from the phone)

    func requestCallLog() {
        var envelope = ABEnvelope()
        envelope.callLogRequest = ABCallLogRequest()
        onSendEnvelope?(envelope)
    }

    func handleCallLogList(_ list: ABCallLogList) {
        let calls = list.entries.map { e -> RecentCall in
            let number = e.number.isEmpty ? "Unknown" : e.number
            return RecentCall(
                name: e.name.isEmpty ? number : e.name,
                number: number,
                isOutgoing: e.type == 2,
                isMissed: e.type == 3,
                timestamp: Date(timeIntervalSince1970: Double(e.dateMs) / 1000),
                durationSeconds: Int(e.durationS)
            )
        }
        DispatchQueue.main.async {
            self.recentCalls = calls
        }
    }
}

// MARK: - Contact & Recent Call Models

struct ContactItem: Identifiable {
    let name: String
    let number: String
    var id: String { "\(name)-\(number)" }
}

struct RecentCall: Identifiable {
    let name: String
    let number: String
    let isOutgoing: Bool
    var isMissed: Bool = false
    let timestamp: Date
    var durationSeconds: Int = 0
    var id: String { "\(number)-\(timestamp.timeIntervalSince1970)" }

    var subtitle: String {
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: timestamp, relativeTo: Date())
    }
}
