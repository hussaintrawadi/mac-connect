import SwiftUI
import AppKit

/// A translucent "Liquid Glass" material backdrop (the same look the menu-bar panel
/// has) so the panel and the main app window read identically.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = .active
    }
}

/// A premium custom dropdown panel shown from the menu-bar icon (replacing the
/// plain native NSMenu) — connection status, feature tiles, now-playing, actions.
/// Shared verbatim between the menu-bar panel and the main app window.
struct MenuBarPopoverView: View {
    @ObservedObject var connectionManager: ConnectionManager
    @ObservedObject var notifications: NotificationFeature

    var onMirror: () -> Void
    var onMessages: () -> Void
    var onFiles: () -> Void
    var onGallery: () -> Void
    var onPhone: () -> Void
    var onFindPhone: () -> Void
    var onSendToPhone: () -> Void
    var onPair: () -> Void
    var onConnect: () -> Void
    var onDisconnect: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void
    /// When true the panel fills its container width (used inside the app window);
    /// when false it's the fixed 320-pt menu-bar width.
    var fillWidth: Bool = false

    private var connected: Bool { connectionManager.state.isConnected }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)

            VStack(spacing: 14) {
                if connected {
                    featureGrid
                    sendFileButton
                    disconnectButton
                    nowPlaying
                } else {
                    notConnected
                }
            }
            .padding(16)

            Divider().opacity(0.6)
            notificationsToggle
            Divider().opacity(0.6)
            footer
        }
        .frame(width: fillWidth ? nil : 320)
        .frame(maxWidth: fillWidth ? .infinity : nil)
        // NOTE: the material backdrop is applied by each host (the menu-bar panel and
        // the app window) so each can position it correctly — not here.
    }

    // MARK: - Notifications toggle

    private var notificationsToggle: some View {
        Toggle(isOn: $notifications.enabled) {
            HStack(spacing: 9) {
                Image(systemName: notifications.enabled ? "bell.fill" : "bell.slash.fill")
                    .frame(width: 16)
                    .foregroundStyle(notifications.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text("Phone notifications")
                    .font(.subheadline)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(.green)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
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
        case .disconnected: return connectionManager.bluetoothLinked ? .blue : .secondary
        }
    }

    private var statusText: String {
        switch connectionManager.state {
        case .connected(let name): return name
        case .searching: return connectionManager.bluetoothLinked ? "Connected · Bluetooth" : "Searching…"
        case .connecting: return "Connecting…"
        case .reconnecting: return connectionManager.bluetoothLinked ? "Connected · Bluetooth" : "Reconnecting…"
        case .disconnected: return connectionManager.bluetoothLinked ? "Connected · Bluetooth" : "Not connected"
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
            tile("Find Phone", "wave.3.right.circle", onFindPhone)
        }
    }

    private func tile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        FeatureTile(title: title, icon: icon, action: action)
    }

    // MARK: - Send file to phone (AirDrop-style)

    private var sendFileButton: some View {
        Button(action: onSendToPhone) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                Text("Send file to phone")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Disconnect (hard stop — stops all searching until you press Connect)

    private var disconnectButton: some View {
        Button(action: onDisconnect) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.slash.fill")
                Text("Disconnect")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            if connectionManager.userDisconnected {
                // Paired but the user chose Disconnect — offer a one-tap reconnect.
                Image(systemName: "bolt.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Disconnected")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(action: onConnect) {
                    Text("Connect").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "iphone.gen3.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(searchingNow ? "Searching for your phone…" : "No phone connected")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(action: onPair) {
                    Text("Pair New Device")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 8)
    }

    private var searchingNow: Bool {
        switch connectionManager.state {
        case .searching, .connecting, .reconnecting: return true
        default: return false
        }
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
