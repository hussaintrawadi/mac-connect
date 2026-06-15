import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct MirrorView: View {
    @ObservedObject var mirrorFeature: ScreenMirrorFeature
    var fileSystem: FileSystemFeature?

    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Color.black

            if mirrorFeature.isActive && mirrorFeature.videoWidth > 0 {
                MirrorDisplayView(mirrorFeature: mirrorFeature)
            } else {
                VStack(spacing: Theme.s5) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 96, height: 96)
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    VStack(spacing: Theme.s2) {
                        HStack(spacing: Theme.s2) {
                            ProgressView()
                                .controlSize(.small)
                                .colorScheme(.dark)
                            Text("Waiting for screen stream…")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text("On your phone, open Mac Connect and tap “Start Mirroring.”")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Theme.s8)
                    }
                }
                .padding(Theme.s8)
            }
        }
        .frame(
            minWidth: 270, idealWidth: CGFloat(mirrorFeature.videoWidth > 0 ? mirrorFeature.videoWidth : 360),
            minHeight: 480, idealHeight: CGFloat(mirrorFeature.videoHeight > 0 ? mirrorFeature.videoHeight : 640)
        )
        .aspectRatio(
            mirrorFeature.videoWidth > 0 ? CGFloat(mirrorFeature.videoWidth) / CGFloat(mirrorFeature.videoHeight) : 9.0/16.0,
            contentMode: .fit
        )
        .overlay {
            if dropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.12)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(6)
                    Label("Drop to send to phone", systemImage: "arrow.down.doc.fill")
                        .font(.headline)
                        .padding(.horizontal, Theme.s4)
                        .padding(.vertical, Theme.s3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline(), lineWidth: 1))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleFileDrop(providers)
            return true
        }
    }

    /// Files dropped on the mirror are uploaded to the phone, which then opens its
    /// share sheet so you can drop them into the app you're using on screen.
    private func handleFileDrop(_ providers: [NSItemProvider]) {
        guard let fileSystem else { return }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    fileSystem.uploadFile(from: url, toPath: "", shareAfter: true)
                }
            }
        }
    }
}

struct MirrorDisplayView: NSViewRepresentable {
    let mirrorFeature: ScreenMirrorFeature

    func makeNSView(context: Context) -> MirrorNSView {
        let view = MirrorNSView(mirrorFeature: mirrorFeature)
        return view
    }

    func updateNSView(_ nsView: MirrorNSView, context: Context) {}
}

final class MirrorNSView: NSView {
    let mirrorFeature: ScreenMirrorFeature
    private let displayLayer = AVSampleBufferDisplayLayer()

    init(mirrorFeature: ScreenMirrorFeature) {
        self.mirrorFeature = mirrorFeature
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black
        layer?.addSublayer(displayLayer)

        mirrorFeature.displayLayer = displayLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    // MARK: - Mouse Events → Touch

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let (nx, ny) = normalizedCoordinates(from: event)
        mirrorFeature.sendTouchDown(normalizedX: nx, normalizedY: ny)
    }

    override func mouseDragged(with event: NSEvent) {
        let (nx, ny) = normalizedCoordinates(from: event)
        mirrorFeature.sendTouchMove(normalizedX: nx, normalizedY: ny)
    }

    override func mouseUp(with event: NSEvent) {
        let (nx, ny) = normalizedCoordinates(from: event)
        mirrorFeature.sendTouchUp(normalizedX: nx, normalizedY: ny)
    }

    override func rightMouseDown(with event: NSEvent) {
        let (nx, ny) = normalizedCoordinates(from: event)
        showContextMenu(at: event.locationInWindow, normalizedX: nx, normalizedY: ny)
    }

    // Two-finger trackpad swipe state
    private var scrollActive = false
    private var scrollCurX: Float = 0
    private var scrollCurY: Float = 0

    override func scrollWheel(with event: NSEvent) {
        let w = Float(bounds.width)
        let h = Float(bounds.height)
        guard w > 0, h > 0 else { return }

        // Amplify so a comfortable trackpad swipe reaches across the phone screen —
        // needed for edge-back and bottom-up-home gestures to register.
        let amplify: Float = 2.2

        if event.phase != [] {
            // Active trackpad gesture: stream it as a real touch swipe at the cursor.
            switch event.phase {
            case .began:
                let (nx, ny) = normalizedCoordinates(from: event)
                scrollCurX = nx
                scrollCurY = ny
                scrollActive = true
                mirrorFeature.sendTouchDown(normalizedX: nx, normalizedY: ny)
            case .changed:
                guard scrollActive else { return }
                // Direct (non-inverted): scroll down moves the touch down, scroll up moves it up.
                scrollCurX += Float(event.scrollingDeltaX) / w * amplify
                scrollCurY += Float(event.scrollingDeltaY) / h * amplify
                scrollCurX = max(0, min(1, scrollCurX))
                scrollCurY = max(0, min(1, scrollCurY))
                mirrorFeature.sendTouchMove(normalizedX: scrollCurX, normalizedY: scrollCurY)
            case .ended, .cancelled:
                if scrollActive {
                    scrollActive = false
                    mirrorFeature.sendTouchUp(normalizedX: scrollCurX, normalizedY: scrollCurY)
                }
            default:
                break
            }
        } else if event.momentumPhase != [] {
            // Inertial momentum after lift — ignore; the phone does its own fling physics.
        } else {
            // Plain mouse wheel (no phase): synthesize a quick vertical swipe.
            let (nx, ny) = normalizedCoordinates(from: event)
            let dy = Float(event.scrollingDeltaY)
            if dy != 0 {
                let endY = max(0, min(1, ny + (dy / h) * 6 * amplify))
                mirrorFeature.sendTouchDown(normalizedX: nx, normalizedY: ny)
                mirrorFeature.sendTouchMove(normalizedX: nx, normalizedY: endY)
                mirrorFeature.sendTouchUp(normalizedX: nx, normalizedY: endY)
            }
        }
    }

    // MARK: - Keyboard Events → Keys

    override func keyDown(with event: NSEvent) {
        // Navigation / editing keys are sent as commands, NOT as text — otherwise
        // their invisible Unicode codes get typed as random characters.
        switch event.keyCode {
        case 51:  mirrorFeature.sendSpecialKey(6);  return // Backspace
        case 117: mirrorFeature.sendSpecialKey(12); return // Forward Delete
        case 36, 76: mirrorFeature.sendSpecialKey(7); return // Return / Enter
        case 53:  mirrorFeature.sendSpecialKey(1);  return // Escape → Back
        case 123: mirrorFeature.sendSpecialKey(8);  return // ← Left
        case 124: mirrorFeature.sendSpecialKey(9);  return // → Right
        case 126: mirrorFeature.sendSpecialKey(10); return // ↑ Up
        case 125: mirrorFeature.sendSpecialKey(11); return // ↓ Down
        default:
            break
        }

        // Cmd-modified keys are macOS shortcuts — don't type them into the phone.
        if event.modifierFlags.contains(.command) { return }

        guard let chars = event.characters, !chars.isEmpty else { return }

        // Only forward actually printable text. Apple maps arrows/function keys to
        // the private-use range 0xF700–0xF8FF; those must never be sent as text.
        let isPrintable = chars.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF ~= scalar.value)
        }
        if isPrintable {
            mirrorFeature.sendKeyText(chars)
        }
    }

    // MARK: - Context Menu

    private func showContextMenu(at point: NSPoint, normalizedX: Float, normalizedY: Float) {
        let menu = NSMenu()

        let tapItem = NSMenuItem(title: "Tap", action: #selector(contextTap(_:)), keyEquivalent: "")
        tapItem.representedObject = [normalizedX, normalizedY]
        tapItem.target = self
        menu.addItem(tapItem)

        let longPressItem = NSMenuItem(title: "Long Press", action: #selector(contextLongPress(_:)), keyEquivalent: "")
        longPressItem.representedObject = [normalizedX, normalizedY]
        longPressItem.target = self
        menu.addItem(longPressItem)

        menu.addItem(NSMenuItem.separator())

        // Swipe gestures (reliable alternative to the trackpad)
        let swipeUpItem = NSMenuItem(title: "Swipe Up", action: #selector(contextSwipeUp), keyEquivalent: "")
        swipeUpItem.target = self
        menu.addItem(swipeUpItem)

        let swipeDownItem = NSMenuItem(title: "Swipe Down", action: #selector(contextSwipeDown), keyEquivalent: "")
        swipeDownItem.target = self
        menu.addItem(swipeDownItem)

        let swipeLeftItem = NSMenuItem(title: "Swipe Left", action: #selector(contextSwipeLeft), keyEquivalent: "")
        swipeLeftItem.target = self
        menu.addItem(swipeLeftItem)

        let swipeRightItem = NSMenuItem(title: "Swipe Right", action: #selector(contextSwipeRight), keyEquivalent: "")
        swipeRightItem.target = self
        menu.addItem(swipeRightItem)

        menu.addItem(NSMenuItem.separator())

        let backItem = NSMenuItem(title: "Back", action: #selector(contextBack), keyEquivalent: "")
        backItem.target = self
        menu.addItem(backItem)

        let homeItem = NSMenuItem(title: "Home", action: #selector(contextHome), keyEquivalent: "")
        homeItem.target = self
        menu.addItem(homeItem)

        let recentsItem = NSMenuItem(title: "Recent Apps", action: #selector(contextRecents), keyEquivalent: "")
        recentsItem.target = self
        menu.addItem(recentsItem)

        menu.addItem(NSMenuItem.separator())

        let notifItem = NSMenuItem(title: "Notifications", action: #selector(contextNotifications), keyEquivalent: "")
        notifItem.target = self
        menu.addItem(notifItem)

        menu.addItem(NSMenuItem.separator())

        // Power-button equivalents: wake to reach the lock screen (then swipe up
        // and type the PIN from the Mac), or lock the phone.
        let wakeItem = NSMenuItem(title: "Wake Screen", action: #selector(contextWake), keyEquivalent: "")
        wakeItem.target = self
        menu.addItem(wakeItem)

        let lockItem = NSMenuItem(title: "Lock Phone", action: #selector(contextLock), keyEquivalent: "")
        lockItem.target = self
        menu.addItem(lockItem)

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: self)
    }

    @objc private func contextTap(_ sender: NSMenuItem) {
        guard let coords = sender.representedObject as? [Float], coords.count == 2 else { return }
        mirrorFeature.sendTouchDown(normalizedX: coords[0], normalizedY: coords[1])
        mirrorFeature.sendTouchUp(normalizedX: coords[0], normalizedY: coords[1])
    }

    @objc private func contextLongPress(_ sender: NSMenuItem) {
        guard let coords = sender.representedObject as? [Float], coords.count == 2 else { return }
        mirrorFeature.sendLongPress(normalizedX: coords[0], normalizedY: coords[1])
    }

    @objc private func contextBack() { mirrorFeature.sendSpecialKey(1) }
    @objc private func contextHome() { mirrorFeature.sendSpecialKey(2) }
    @objc private func contextRecents() { mirrorFeature.sendSpecialKey(3) }
    @objc private func contextNotifications() { mirrorFeature.sendSpecialKey(4) }
    @objc private func contextLock() { mirrorFeature.sendSpecialKey(5) }
    @objc private func contextWake() { mirrorFeature.sendSpecialKey(13) }

    // Directional swipes (center of screen)
    @objc private func contextSwipeUp() { mirrorFeature.sendSwipe(fromX: 0.5, fromY: 0.72, toX: 0.5, toY: 0.25) }
    @objc private func contextSwipeDown() { mirrorFeature.sendSwipe(fromX: 0.5, fromY: 0.28, toX: 0.5, toY: 0.75) }
    @objc private func contextSwipeLeft() { mirrorFeature.sendSwipe(fromX: 0.78, fromY: 0.5, toX: 0.18, toY: 0.5) }
    @objc private func contextSwipeRight() { mirrorFeature.sendSwipe(fromX: 0.18, fromY: 0.5, toX: 0.78, toY: 0.5) }

    // MARK: - Helpers

    private func normalizedCoordinates(from event: NSEvent) -> (Float, Float) {
        let loc = convert(event.locationInWindow, from: nil)
        let nx = Float(loc.x / bounds.width)
        let ny = Float(1.0 - loc.y / bounds.height) // Flip Y — macOS is bottom-up
        return (max(0, min(1, nx)), max(0, min(1, ny)))
    }
}
