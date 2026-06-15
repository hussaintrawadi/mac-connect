import SwiftUI

struct CallHUDView: View {
    @ObservedObject var callFeature: CallFeature
    @State private var showKeypad = false

    var body: some View {
        VStack(spacing: 0) {
            switch callFeature.callState {
            case .ringing:
                incomingCallView
            case .active, .dialing, .held:
                inCallView
            default:
                EmptyView()
            }
        }
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.hairline(), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
    }

    // MARK: - Incoming Call

    private var incomingCallView: some View {
        VStack(spacing: Theme.s5) {
            // Caller info
            VStack(spacing: Theme.s2) {
                Avatar(name: callFeature.callerName, size: 64)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "phone.arrow.down.left.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.green, in: Circle())
                            .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                            .offset(x: 4, y: 4)
                    }

                Text("Incoming Call")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.top, Theme.s1)

                Text(callFeature.callerName)
                    .font(.title2)
                    .fontWeight(.semibold)

                if callFeature.callerName != callFeature.callerNumber {
                    Text(callFeature.callerNumber)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Actions
            HStack(spacing: 48) {
                callActionButton(icon: "phone.down.fill", label: "Decline", tint: .red) {
                    callFeature.decline()
                }
                callActionButton(icon: "phone.fill", label: "Answer", tint: .green) {
                    callFeature.answer()
                }
            }
        }
        .padding(Theme.s6)
    }

    private func callActionButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.s1 + 2) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(tint, in: Circle())
                    .shadow(color: tint.opacity(0.4), radius: 8, y: 3)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - In-Call (dialing + active)

    private var inCallView: some View {
        VStack(spacing: Theme.s5) {
            VStack(spacing: Theme.s3) {
                Avatar(name: callFeature.callerName.isEmpty ? callFeature.callerNumber : callFeature.callerName, size: 56)

                Text(callFeature.callerName.isEmpty ? callFeature.callerNumber : callFeature.callerName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(callFeature.callState == .dialing ? "Calling…" : callFeature.formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(callFeature.callState == .dialing ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
            }

            if showKeypad {
                dtmfKeypad
            }

            HStack(spacing: 28) {
                hudCircleButton(
                    icon: callFeature.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: callFeature.isMuted ? "Unmute" : "Mute",
                    active: callFeature.isMuted
                ) { callFeature.toggleMute() }

                hudCircleButton(
                    icon: "circle.grid.3x3.fill",
                    label: "Keypad",
                    active: showKeypad
                ) { showKeypad.toggle() }

                hudCircleButton(
                    icon: "phone.down.fill",
                    label: "End",
                    iconColor: .white,
                    bgColor: .red
                ) { callFeature.hangUp() }
            }
        }
        .padding(Theme.s5)
    }

    private var dtmfKeypad: some View {
        let keys = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
        return VStack(spacing: Theme.s2) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: Theme.s2 + 2) {
                    ForEach(row, id: \.self) { key in
                        Button(key) { callFeature.sendDTMF(key) }
                            .font(.system(.title3, design: .rounded))
                            .frame(width: 48, height: 36)
                            .background(Color(.controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                                    .strokeBorder(Theme.hairline(), lineWidth: 1)
                            )
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Monochrome capsule/circle control. When `active`, fills with the accent;
    /// callers may override colors (used for the red "End" button).
    private func hudCircleButton(icon: String, label: String,
                                 active: Bool = false,
                                 iconColor: Color? = nil, bgColor: Color? = nil,
                                 action: @escaping () -> Void) -> some View {
        let resolvedBg: AnyShapeStyle
        let resolvedIcon: Color
        if let bgColor {
            resolvedBg = AnyShapeStyle(bgColor)
            resolvedIcon = iconColor ?? .white
        } else if active {
            resolvedBg = AnyShapeStyle(Color.accentColor)
            resolvedIcon = .white
        } else {
            resolvedBg = AnyShapeStyle(Color(.controlBackgroundColor))
            resolvedIcon = .primary
        }
        return Button(action: action) {
            VStack(spacing: Theme.s1 + 1) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(resolvedIcon)
                    .frame(width: 50, height: 50)
                    .background(resolvedBg, in: Circle())
                    .overlay(
                        Circle().strokeBorder(active || bgColor != nil ? Color.clear : Theme.hairline(), lineWidth: 1)
                    )
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Phone View (Contacts + Recents + Dial Pad)

struct PhoneView: View {
    @ObservedObject var callFeature: CallFeature
    @State private var selectedTab = 0
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Contacts").tag(0)
                Text("Recents").tag(1)
                Text("Dial Pad").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .background(.bar)

            Divider()

            switch selectedTab {
            case 0: contactsTab
            case 1: recentsTab
            default: dialPadTab
            }
        }
        .frame(minWidth: 340, minHeight: 560)
        .onAppear {
            callFeature.requestContacts()
            callFeature.requestCallLog()
        }
    }

    // MARK: - Contacts Tab

    private var contactsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search contacts", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s2)
            .background(Color(.textBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline(), lineWidth: 1))
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)

            if filteredContacts.isEmpty {
                EmptyStateView(
                    systemImage: callFeature.contacts.isEmpty ? "person.2.slash" : "magnifyingglass",
                    title: callFeature.contacts.isEmpty ? "No Contacts Yet" : "No Matches",
                    message: callFeature.contacts.isEmpty ? "Contacts will appear once your phone syncs them." : nil
                )
            } else {
                List(filteredContacts) { contact in
                    HStack(spacing: Theme.s3) {
                        Avatar(name: contact.name, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.name).fontWeight(.medium)
                            Text(contact.number).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        callButton { callFeature.dial(number: contact.number) }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    /// A compact circular green call button, used in contacts and recents rows.
    private func callButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "phone.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.green, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Call")
    }

    private var filteredContacts: [ContactItem] {
        if searchText.isEmpty { return callFeature.contacts }
        return callFeature.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.number.contains(searchText)
        }
    }

    // MARK: - Recents Tab

    private var recentsTab: some View {
        Group {
            if callFeature.recentCalls.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: "No Recent Calls",
                    message: "Your call history will appear here."
                )
            } else {
                List(callFeature.recentCalls) { call in
                    HStack(spacing: Theme.s3) {
                        Image(systemName: call.isMissed ? "phone.arrow.down.left" : (call.isOutgoing ? "arrow.up.right" : "arrow.down.left"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(call.isMissed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .frame(width: 22, height: 22)
                            .background(.quaternary, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(call.name)
                                .fontWeight(.medium)
                                .foregroundStyle(call.isMissed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            Text(call.number).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(call.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        callButton { callFeature.dial(number: call.number) }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Dial Pad Tab

    private var dialPadTab: some View {
        DialPadView(callFeature: callFeature)
    }
}

// MARK: - Dial Pad View

struct DialPadView: View {
    @ObservedObject var callFeature: CallFeature
    @State private var number = ""
    @State private var keyMonitor: Any?

    private let keys = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"],
    ]

    /// Type the number straight from the Mac keyboard: digits, * # +,
    /// Backspace deletes, Return dials, ⌘V pastes, ⌘C copies.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌘V / ⌘C — paste or copy the number. Other ⌘-shortcuts pass through.
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "v":
                    pasteNumber()
                    return nil
                case "c" where !number.isEmpty:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(number, forType: .string)
                    return nil
                default:
                    return event
                }
            }
            if event.keyCode == 51 {                 // Backspace
                if !number.isEmpty { number.removeLast() }
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {  // Return / Enter
                if !number.isEmpty { callFeature.dial(number: number) }
                return nil
            }
            if let chars = event.characters, chars.count == 1,
               "0123456789*#+".contains(chars) {
                number.append(chars)
                return nil
            }
            return event
        }
    }

    /// Paste from the clipboard, keeping only dialable characters — so
    /// "+91 98765-43210" or "(555) 123 4567" paste cleanly.
    private func pasteNumber() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let cleaned = raw.filter { "0123456789*#+".contains($0) }
        if !cleaned.isEmpty { number += cleaned }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
    }

    var body: some View {
        VStack(spacing: Theme.s4) {
            Spacer(minLength: 0)

            Text(number.isEmpty ? "Enter a number" : number)
                .font(.system(size: 28, weight: .regular, design: .rounded))
                .foregroundStyle(number.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .padding(.horizontal, Theme.s5)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Paste") { pasteNumber() }
                    if !number.isEmpty {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(number, forType: .string)
                        }
                        Button("Clear") { number = "" }
                    }
                }

            // Keypad
            VStack(spacing: Theme.s3) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: Theme.s5) {
                        ForEach(row, id: \.self) { key in
                            Button { number.append(key) } label: {
                                Text(key)
                                    .font(.system(size: 24, weight: .regular, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .frame(width: 56, height: 56)
                                    .background(Color(.controlBackgroundColor), in: Circle())
                                    .overlay(Circle().strokeBorder(Theme.hairline(), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: Theme.s6) {
                // Spacer to balance the delete button on the right.
                Color.clear.frame(width: 44, height: 44)

                Button(action: {
                    guard !number.isEmpty else { return }
                    callFeature.dial(number: number)
                }) {
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(number.isEmpty ? AnyShapeStyle(Color.green.opacity(0.4)) : AnyShapeStyle(Color.green), in: Circle())
                        .shadow(color: .green.opacity(number.isEmpty ? 0 : 0.35), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(number.isEmpty)

                Button(action: {
                    if !number.isEmpty { number.removeLast() }
                }) {
                    Image(systemName: "delete.left")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(number.isEmpty)
                .opacity(number.isEmpty ? 0.4 : 1)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.s4)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
