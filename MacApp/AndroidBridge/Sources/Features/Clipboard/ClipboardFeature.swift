import AppKit
import Foundation
import os

final class ClipboardFeature {
    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Clipboard")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    private var lastChangeCount: Int
    private var monitorTimer: Timer?
    private var lastSentText: String?
    private var ignoreNextChange = false

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        logger.info("Clipboard monitoring started")
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if ignoreNextChange {
            ignoreNextChange = false
            return
        }

        if let text = pasteboard.string(forType: .string), text != lastSentText {
            lastSentText = text
            sendText(text)
        } else if let imageData = pasteboard.data(forType: .png) {
            sendImage(imageData, mimeType: "image/png")
        } else if let tiffData = pasteboard.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiffData),
                  let png = rep.representation(using: .png, properties: [:]) {
            // Most apps put TIFF on the pasteboard — convert to PNG for the phone.
            sendImage(png, mimeType: "image/png")
        }
    }

    private func sendText(_ text: String) {
        let isUrl = text.hasPrefix("http://") || text.hasPrefix("https://")

        var sync = ABClipboardSync()
        sync.type = isUrl ? .url : .text
        sync.text = text

        var envelope = ABEnvelope()
        envelope.clipboardSync = sync
        onSendEnvelope?(envelope)

        logger.debug("Clipboard sent: \(text.prefix(50))")
    }

    private func sendImage(_ data: Data, mimeType: String) {
        var sync = ABClipboardSync()
        sync.type = .image
        sync.imageData = data
        sync.mimeType = mimeType

        var envelope = ABEnvelope()
        envelope.clipboardSync = sync
        onSendEnvelope?(envelope)

        logger.debug("Clipboard image sent: \(data.count) bytes")
    }

    func applyFromAndroid(_ sync: ABClipboardSync) {
        ignoreNextChange = true
        let pasteboard = NSPasteboard.general

        switch sync.type {
        case .text, .url:
            pasteboard.clearContents()
            pasteboard.setString(sync.text, forType: .string)
            lastSentText = sync.text
            logger.debug("Clipboard applied from Android: \(sync.text.prefix(50))")

        case .image:
            if !sync.imageData.isEmpty {
                pasteboard.clearContents()
                pasteboard.setData(sync.imageData, forType: .png)
                logger.debug("Clipboard image applied from Android: \(sync.imageData.count) bytes")
            }

        default:
            break
        }

        lastChangeCount = pasteboard.changeCount
    }
}
