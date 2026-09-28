import SwiftUI
import AppKit

/// Resets the app window to hug its SwiftUI content. An earlier build pinned the
/// window's contentMinSize to 600 (via a `.frame(minHeight:)`); macOS persists that,
/// so the window refuses to shrink below it. This clears the stale minimum, locks
/// the window to the content's fitting size, and disables frame restore so a stale
/// (taller) frame can't come back on the next launch.
/// Measures the panel content's real height so the window can be sized to it exactly.
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Drives the app window to an exact size (fixed width × measured content height),
/// anchored at the top edge. Deterministic — no reliance on SwiftUI's content-size
/// heuristics, which kept fighting the title-bar safe area. Also disables frame
/// restore/autosave so a stale (taller) frame can't come back.
struct WindowConfigurator: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ v: NSView, context: Context) {
        let w0 = width, h0 = height
        DispatchQueue.main.async {
            guard let w = v.window, h0 > 60 else { return }
            w.isRestorable = false
            w.setFrameAutosaveName("")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.contentMinSize = NSSize(width: 200, height: 60)
            w.contentMaxSize = NSSize(width: 5000, height: 5000)

            // With fullSizeContentView the SwiftUI content is laid out below the title
            // bar (contentLayoutRect), so the window frame = title-bar height + content.
            var titleBar = w.frame.height - w.contentLayoutRect.height
            if titleBar < 1 || titleBar > 60 { titleBar = 28 }   // sane fallback
            let targetH = h0 + titleBar
            if abs(w.frame.height - targetH) > 0.5 || abs(w.frame.width - w0) > 0.5 {
                var f = w.frame
                f.origin.y += (f.height - targetH)   // keep the top edge fixed
                f.size = NSSize(width: w0, height: targetH)
                w.setFrame(f, display: true)
            }
        }
    }
}

// MARK: - Design Tokens
//
// A small, cohesive set of constants used across every Mac Connect window so the
// app reads as one polished, native macOS product. Monochrome by default with a
// single restrained accent; an 8pt spacing grid; soft rounded cards with hairline
// strokes and subtle material backgrounds.

enum Theme {
    static let cardRadius: CGFloat = 14
    static let smallRadius: CGFloat = 10
    static let chipRadius: CGFloat = 8

    static let strokeIdle: Double = 0.08
    static let strokeHover: Double = 0.18

    // 8pt spacing grid
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32

    /// Hairline stroke used on cards and surfaces.
    static func hairline(_ hovering: Bool = false) -> Color {
        Color.primary.opacity(hovering ? strokeHover : strokeIdle)
    }
}

// MARK: - Card Surface

/// A rounded, material-backed surface with a hairline stroke — the base building
/// block for cards, panels and tiles throughout the app.
struct CardSurface: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var hovering: Bool = false
    var fill: AnyShapeStyle = AnyShapeStyle(Color(.controlBackgroundColor))

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline(hovering), lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(radius: CGFloat = Theme.cardRadius,
                     hovering: Bool = false,
                     fill: AnyShapeStyle = AnyShapeStyle(Color(.controlBackgroundColor))) -> some View {
        modifier(CardSurface(radius: radius, hovering: hovering, fill: fill))
    }
}

// MARK: - Window Toolbar Header

/// A consistent title-bar-style header used at the top of feature windows. Uses a
/// bar material so it blends with the native title bar above it.
struct WindowHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.s3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.s3)
            trailing()
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .frame(minHeight: 52)
        .background(.bar)
    }
}

extension WindowHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, trailing: { EmptyView() })
    }
}

// MARK: - Empty State

/// A polished, centered empty / loading state with an icon, title and optional
/// detail line. Keeps every window's "nothing here" view consistent.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var isLoading: Bool = false

    var body: some View {
        VStack(spacing: Theme.s4) {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.6))
                    .frame(width: 76, height: 76)
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: Theme.s1) {
                Text(title)
                    .font(.headline)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(Theme.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Monogram Avatar

/// A circular monochrome avatar showing a contact's initials — used in messaging,
/// contacts and recents lists for a clean, native look.
struct Avatar: View {
    let name: String
    var size: CGFloat = 36

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        if letters.isEmpty {
            return name.first.map { String($0).uppercased() } ?? "?"
        }
        return letters.uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            Circle().strokeBorder(Theme.hairline(), lineWidth: 1)
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Welcome / Onboarding / Dashboard

struct WelcomeView: View {
    @ObservedObject var connectionManager: ConnectionManager
    @State private var currentPage = 0
    @StateObject private var pairingManager = PairingManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var panelHeight: CGFloat = 320

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                // Onboarding keeps its own fixed size.
                onboardingFlow
                    .frame(width: 400, height: 620)
            } else {
                // The main window shows the SAME premium panel as the menu-bar
                // dropdown — same 320-pt width. Its exact height is measured and the
                // window is sized to match (see WindowConfigurator).
                panelView
            }
        }
        // Fill the whole window with the Liquid-Glass material (incl. under the title bar).
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    /// The exact menu-bar panel, embedded in the window (320-pt width). A small top
    /// inset clears the traffic-light buttons; its measured height drives the window.
    private var panelView: some View {
        MenuBarPopoverView(
            connectionManager: connectionManager,
            notifications: connectionManager.notificationFeature,
            onMirror: { NotificationCenter.default.post(name: .openMirror, object: nil) },
            onMessages: { NotificationCenter.default.post(name: .openSMS, object: nil) },
            onFiles: { NotificationCenter.default.post(name: .openFiles, object: nil) },
            onGallery: { NotificationCenter.default.post(name: .openGallery, object: nil) },
            onPhone: { NotificationCenter.default.post(name: .openDialPad, object: nil) },
            onFindPhone: { NotificationCenter.default.post(name: .findPhone, object: nil) },
            onSendToPhone: { NotificationCenter.default.post(name: .sendToPhone, object: nil) },
            onPair: { hasCompletedOnboarding = false; currentPage = 2 },
            onConnect: { connectionManager.connectPhone() },
            onDisconnect: { connectionManager.requestPhoneDisconnect() },
            onSettings: { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) },
            onQuit: { NSApp.terminate(nil) },
            fillWidth: false
        )
        // Pull the content up a touch so the header icon sits close to the traffic
        // lights (the title-bar area otherwise leaves too big a gap up top). The
        // measured height below already accounts for this, so the bottom stays snug.
        .padding(.top, -12)
        // Content respects the title-bar area (so the icon sits nicely below the
        // traffic lights); the material still bleeds under the bar via the window
        // background. We measure the content's real height and size the window to it.
        .background(GeometryReader { geo in
            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { panelHeight = $0 }
        .background(WindowConfigurator(width: 320, height: panelHeight))
    }

    // MARK: - Onboarding (no tab bar — custom page switching)

    private var onboardingFlow: some View {
        Group {
            switch currentPage {
            case 0: welcomePage
            case 1: featuresPage
            case 2: pairPage
            default: welcomePage
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentPage)
    }

    // Small page indicator dots shared by the onboarding pages.
    private func pageDots(_ active: Int) -> some View {
        HStack(spacing: Theme.s2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == active ? Color.primary.opacity(0.75) : Color.primary.opacity(0.15))
                    .frame(width: i == active ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: active)
            }
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: Theme.s6) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

            VStack(spacing: Theme.s2) {
                Text("Mac Connect")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("Your Android, on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("Mirror your screen, take calls, send messages, and share files — all without touching your phone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .padding(.horizontal, 44)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            VStack(spacing: Theme.s5) {
                Button(action: { currentPage = 1 }) {
                    Text("Get Started")
                        .font(.headline)
                        .frame(width: 220, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                pageDots(0)
            }

            Spacer().frame(height: Theme.s8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Page 2: Features

    private var featuresPage: some View {
        VStack(spacing: Theme.s5) {
            Spacer().frame(height: Theme.s6)

            VStack(spacing: Theme.s1) {
                Text("Everything You Need")
                    .font(.title)
                    .fontWeight(.bold)
                Text("One app, your whole phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.s3),
                                GridItem(.flexible(), spacing: Theme.s3)], spacing: Theme.s3) {
                FeatureCard(icon: "rectangle.on.rectangle", title: "Screen Mirror", description: "See and control your Android")
                FeatureCard(icon: "phone.fill", title: "Calls", description: "Make & receive calls from Mac")
                FeatureCard(icon: "message.fill", title: "Messages", description: "Read & send SMS from Mac")
                FeatureCard(icon: "bell.fill", title: "Notifications", description: "All alerts mirrored to Mac")
                FeatureCard(icon: "folder.fill", title: "Files", description: "Browse & transfer files")
                FeatureCard(icon: "doc.on.clipboard", title: "Clipboard", description: "Copy-paste across devices")
            }
            .padding(.horizontal, Theme.s6)

            Spacer()

            HStack(spacing: Theme.s2) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("100% local. Zero cloud. Zero cost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: Theme.s4) {
                Button(action: { currentPage = 2 }) {
                    Text("Continue")
                        .font(.headline)
                        .frame(width: 220, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                pageDots(1)
            }

            Spacer().frame(height: Theme.s6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Page 3: Pair (Mac shows QR code, phone scans it)

    private var pairPage: some View {
        VStack(spacing: Theme.s5) {
            Spacer().frame(height: Theme.s6)

            VStack(spacing: Theme.s1) {
                Text("Pair Your Android")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Almost there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            switch pairingManager.state {
            case .idle, .waitingForPhone:
                VStack(spacing: Theme.s4) {
                    Text("Open Mac Connect on your Android phone and scan this code.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.s8)
                        .fixedSize(horizontal: false, vertical: true)

                    QRCard(payload: pairingManager.qrPayload, size: 210)

                    HStack(spacing: Theme.s2) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for phone to connect…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            case .connecting:
                VStack(spacing: Theme.s3) {
                    ProgressView().scaleEffect(1.3)
                    Text("Connecting…")
                        .font(.title3)
                }
                .frame(maxHeight: .infinity)

            case .paired(let name):
                PairSuccessView(name: name)
                    .frame(maxHeight: .infinity)

            case .failed(let reason):
                PairFailureView(reason: reason) {
                    pairingManager.startPairing { _ in }
                }
                .frame(maxHeight: .infinity)
            }

            Spacer()

            Button("Skip for now") {
                pairingManager.stopPairing()
                hasCompletedOnboarding = true
            }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)

            Spacer().frame(height: Theme.s6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if pairingManager.state == .idle {
                pairingManager.startPairing { success in
                    if success {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            hasCompletedOnboarding = true
                            connectionManager.start()
                        }
                    }
                }
            }
        }
        .onDisappear {
            pairingManager.stopPairing()
        }
    }

    // MARK: - Connection View (after onboarding, not yet connected)

    private var connectionView: some View {
        VStack(spacing: Theme.s6) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)

            switch connectionManager.state {
            case .searching:
                statusBlock(title: "Searching for your Android…",
                            detail: "Make sure both devices are on the same Wi-Fi.",
                            showSpinner: true)
            case .connecting:
                statusBlock(title: "Connecting…", detail: nil, showSpinner: true)
            case .reconnecting:
                statusBlock(title: "Reconnecting…",
                            detail: "Hang tight — restoring your connection.",
                            symbol: "arrow.triangle.2.circlepath")
            default:
                statusBlock(title: "Not Connected",
                            detail: "Open Mac Connect on your phone to reconnect.",
                            symbol: "wifi.slash")
            }

            Spacer()

            Button("Pair New Device") {
                hasCompletedOnboarding = false
                currentPage = 2
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: Theme.s8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func statusBlock(title: String, detail: String?, symbol: String? = nil, showSpinner: Bool = false) -> some View {
        VStack(spacing: Theme.s3) {
            if showSpinner {
                ProgressView().scaleEffect(1.2).frame(height: 36)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(height: 36)
            }
            Text(title)
                .font(.title3)
                .fontWeight(.medium)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.s8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Dashboard (connected)

    private var dashboardView: some View {
        VStack(spacing: 0) {
            // Connected device header
            HStack(spacing: Theme.s3) {
                ZStack {
                    Circle().fill(.quaternary)
                    Image(systemName: "iphone")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.primary)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    if case .connected(let name) = connectionManager.state {
                        Text(name)
                            .font(.headline)
                    } else {
                        Text("Android")
                            .font(.headline)
                    }
                    HStack(spacing: Theme.s1 + 1) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                if connectionManager.phoneBattery >= 0 {
                    HStack(spacing: 4) {
                        Image(systemName: connectionManager.phoneCharging ? "battery.100.bolt" : "battery.75")
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
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s4)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(spacing: Theme.s4) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.s3),
                                        GridItem(.flexible(), spacing: Theme.s3)], spacing: Theme.s3) {
                        DashboardButton(icon: "rectangle.on.rectangle", title: "Mirror Screen") {
                            NotificationCenter.default.post(name: .openMirror, object: nil)
                        }
                        DashboardButton(icon: "message", title: "Messages") {
                            NotificationCenter.default.post(name: .openSMS, object: nil)
                        }
                        DashboardButton(icon: "phone", title: "Phone") {
                            NotificationCenter.default.post(name: .openDialPad, object: nil)
                        }
                        DashboardButton(icon: "folder", title: "Files") {
                            NotificationCenter.default.post(name: .openFiles, object: nil)
                        }
                        DashboardButton(icon: "photo.on.rectangle", title: "Gallery") {
                            NotificationCenter.default.post(name: .openGallery, object: nil)
                        }
                        DashboardButton(icon: "bolt.slash", title: "Disconnect", tint: .red) {
                            connectionManager.requestPhoneDisconnect()
                        }
                    }

                    nowPlayingCard

                    Spacer(minLength: Theme.s4)
                }
                .padding(Theme.s5)
                .frame(maxWidth: .infinity, minHeight: dashboardMinHeight)
            }
        }
    }

    /// Keeps the dashboard content filling the (taller) onboarding-sized window
    /// instead of leaving a big empty gap below a short grid.
    private var dashboardMinHeight: CGFloat { 470 }

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("NOW PLAYING")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
            }

            HStack(spacing: Theme.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionManager.mediaControlFeature.title.isEmpty
                         ? "Nothing playing" : connectionManager.mediaControlFeature.title)
                        .font(.subheadline).fontWeight(.medium)
                        .lineLimit(1)
                    Text(connectionManager.mediaControlFeature.title.isEmpty
                         ? "Phone media controls" : connectionManager.mediaControlFeature.artist)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: Theme.s4) {
                    Button { connectionManager.mediaControlFeature.previous() } label: {
                        Image(systemName: "backward.fill")
                    }.buttonStyle(.borderless)
                    Button { connectionManager.mediaControlFeature.togglePlayPause() } label: {
                        Image(systemName: connectionManager.mediaControlFeature.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }.buttonStyle(.borderless)
                    Button { connectionManager.mediaControlFeature.next() } label: {
                        Image(systemName: "forward.fill")
                    }.buttonStyle(.borderless)
                }
                .foregroundStyle(.primary)
            }
        }
        .padding(Theme.s4)
        .cardSurface()
    }
}

// MARK: - Pairing sub-views (shared visual language)

/// A crisp white QR card with the payload, or a placeholder while it generates.
struct QRCard: View {
    let payload: String
    var size: CGFloat = 200

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)

            if !payload.isEmpty {
                QRGeneratorView(pairingPayload: payload)
                    .frame(width: size - 36, height: size - 36)
            } else {
                ProgressView()
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

struct PairSuccessView: View {
    let name: String
    var body: some View {
        VStack(spacing: Theme.s4) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.green)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(spacing: Theme.s1) {
                Text("Paired Successfully")
                    .font(.title3).fontWeight(.semibold)
                Text("Connected to \(name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PairFailureView: View {
    let reason: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: Theme.s4) {
            ZStack {
                Circle().fill(Color.red.opacity(0.10)).frame(width: 80, height: 80)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.red)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(spacing: Theme.s1) {
                Text("Pairing Failed")
                    .font(.title3).fontWeight(.semibold)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - Supporting Views

struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: Theme.s2) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.7))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 38, height: 38)

            Text(title)
                .font(.subheadline).fontWeight(.semibold)
            Text(description)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.s4)
        .padding(.horizontal, Theme.s2)
        .cardSurface(radius: Theme.cardRadius, fill: AnyShapeStyle(Color(.controlBackgroundColor)))
    }
}

struct DashboardButton: View {
    let icon: String
    let title: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.s2 + 2) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(tint == .primary ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 94)
            .cardSurface(radius: Theme.cardRadius, hovering: hovering,
                         fill: AnyShapeStyle(Color(.controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.04 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

extension Notification.Name {
    static let openMirror = Notification.Name("openMirror")
    static let openSMS = Notification.Name("openSMS")
    static let openFiles = Notification.Name("openFiles")
    static let openGallery = Notification.Name("openGallery")
    static let openDialPad = Notification.Name("openDialPad")
    static let findPhone = Notification.Name("findPhone")
    static let sendToPhone = Notification.Name("sendToPhone")
}
