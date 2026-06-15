import Foundation
import Combine
import os

final class MediaControlFeature: ObservableObject {
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var isPlaying: Bool = false
    @Published var positionMs: Int64 = 0
    @Published var durationMs: Int64 = 0
    @Published var albumArtData: Data?
    @Published var appPackage: String = ""
    @Published var lastMediaUpdateTime: Date = .distantPast

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Media")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    var hasMedia: Bool {
        guard !title.isEmpty else { return false }
        return isPlaying || Date().timeIntervalSince(lastMediaUpdateTime) < 10
    }

    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return Double(positionMs) / Double(durationMs)
    }

    var formattedPosition: String {
        formatTime(positionMs)
    }

    var formattedDuration: String {
        formatTime(durationMs)
    }

    func handleMediaState(_ state: ABMediaState) {
        DispatchQueue.main.async {
            if state.title.isEmpty && !state.isPlaying {
                // Empty state received — clear all fields
                self.title = ""
                self.artist = ""
                self.album = ""
                self.isPlaying = false
                self.positionMs = 0
                self.durationMs = 0
                self.appPackage = ""
                self.albumArtData = nil
                self.lastMediaUpdateTime = .distantPast
            } else {
                self.title = state.title
                self.artist = state.artist
                self.album = state.album
                self.isPlaying = state.isPlaying
                self.positionMs = state.positionMs
                self.durationMs = state.durationMs
                self.appPackage = state.appPackage
                self.lastMediaUpdateTime = Date()

                if !state.albumArt.isEmpty {
                    self.albumArtData = state.albumArt
                }
            }
        }
    }

    func play() { sendAction(.play) }
    func pause() { sendAction(.pause) }
    func next() { sendAction(.next) }
    func previous() { sendAction(.previous) }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    private func sendAction(_ action: ABMediaControl.Action) {
        var control = ABMediaControl()
        control.action = action

        var envelope = ABEnvelope()
        envelope.mediaControl = control
        onSendEnvelope?(envelope)
    }

    private func formatTime(_ ms: Int64) -> String {
        let totalSeconds = Int(ms / 1000)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
