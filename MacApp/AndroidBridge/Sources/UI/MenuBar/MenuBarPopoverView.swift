import SwiftUI

/// A premium custom dropdown panel shown from the menu-bar icon (replacing the
/// plain native NSMenu) — connection status, feature tiles, now-playing, actions.
struct MenuBarPopoverView: View {
    @ObservedObject var connectionManager: ConnectionManager

    var onMirror: () -> Void
    var onMessages: () -> Void
    var onFiles: () -> Void
    var onGallery: () -> Void
    var onPhone: () -> Void
    var onPair: () -> Void
    var onDisconnect: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    private var connected: Bool { connectionManager.state.isConnected }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)

            VStack(spacing: 14) {
                if connected {
                    featureGrid
                    nowPlaying
                } else {
                    notConnected
                }
            }
            .padding(16)

            Divider().opacity(0.6)
            footer
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 44, height: 44)
                Image(systemName: connected ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(connected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Mac Connect")
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if connected && connectionManager.phoneBattery >= 0 {
                HStack(spacing: 4) {
                    Image(systemName: batterySymbol)
                        .foregroundStyle(connectionManager.phoneBattery <= 20 && !connectionManager.phoneCharging
                                         ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    Text("\(connectionManager.phoneBattery)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .help(connectionManager.phoneCharging ? "Phone battery (charging)" : "Phone battery")
            }
        }
        .padding(16)
    }

    private var batterySymbol: String {
        if connectionManager.phoneCharging { return "battery.100.bolt" }
        switch connectionManager.phoneBattery {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private var statusColor: Color {
        switch connectionManager.state {
        case .connected: return .green
        case .searching, .connecting: return .orange
        case .reconnecting: return .orange
        case .disconnected: return .secondary
        }
    }

    private var statusText: String {
        switch connectionManager.state {
        case .connected(let name): return name
        case .searching: return "Searching…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Not connected"
        }
    }

    // MARK: - Feature grid

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            tile("Mirror Screen", "rectangle.on.rectangle", onMirror)
            tile("Messages", "message", onMessages)
            tile("Files", "folder", onFiles)
            tile("Gallery", "photo.on.rectangle", onGallery)
            tile("Phone", "phone", onPhone)
            tile("Disconnect", "bolt.slash", onDisconnect)
        }
    }

    private func tile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        FeatureTile(title: title, icon: icon, action: action)
    }

    // MARK: - Now Playing

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(connectionManager.mediaControlFeature.title.isEmpty
                     ? "Nothing playing" : connectionManager.mediaControlFeature.title)
                    .font(.subheadline).fontWeight(.medium).lineLimit(1)
                Text(connectionManager.mediaControlFeature.title.isEmpty
                     ? "Phone media controls" : connectionManager.mediaControlFeature.artist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 14) {
                iconButton("backward.fill") { connectionManager.mediaControlFeature.previous() }
                iconButton(connectionManager.mediaControlFeature.isPlaying ? "pause.fill" : "play.fill") {
                    connectionManager.mediaControlFeature.togglePlayPause()
                }
                iconButton("forward.fill") { connectionManager.mediaControlFeature.next() }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func iconButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Not connected

    private var notConnected: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.gen3.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No phone connected")
                .font(.subheadline).foregroundStyle(.secondary)
            Button(action: onPair) {
                Text("Pair New Device")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("Pair", "plus.circle", onPair)
            Divider().frame(height: 18)
            footerButton("Settings", "gearshape", onSettings)
            Divider().frame(height: 18)
            footerButton("Quit", "power", onQuit)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func footerButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.caption)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct FeatureTile: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .regular))
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(Color.primary.opacity(hover ? 0.10 : 0.05),
                       in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
