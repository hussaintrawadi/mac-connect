import AppKit
import Foundation
import os

final class URLHandoffFeature {
    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "URLHandoff")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    func openURLFromAndroid(_ handoff: ABUrlHandoff) {
        guard let url = URL(string: handoff.url) else {
            logger.warning("Invalid URL from Android: \(handoff.url)")
            return
        }

        NSWorkspace.shared.open(url)
        logger.info("Opened URL from Android: \(handoff.url)")
    }

    func sendURLToAndroid(_ url: String, title: String = "") {
        var handoff = ABUrlHandoff()
        handoff.url = url
        handoff.title = title

        var envelope = ABEnvelope()
        envelope.urlHandoff = handoff
        onSendEnvelope?(envelope)

        logger.info("URL sent to Android: \(url)")
    }
}
