import SwiftUI

/// Time formatting for SMS — hours and minutes only (no seconds, no live ticking).
enum SMSTime {
    private static let clockFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    static func clock(_ d: Date) -> String { clockFmt.string(from: d) }
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return clock(d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .weekOfYear) ? "EEE" : "MMM d"
        return f.string(from: d)
    }
}

struct SMSView: View {
    @ObservedObject var smsFeature: SMSFeature

    var body: some View {
        NavigationSplitView {
            ConversationListView(
                conversations: smsFeature.conversations,
                selectedThread: $smsFeature.activeThread
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            if let thread = smsFeature.activeThread,
               let conv = smsFeature.conversations.first(where: { $0.threadId == thread }) {
                MessageThreadView(
                    conversation: conv,
                    messages: smsFeature.activeMessages,
                    onSend: { body in
                        smsFeature.sendMessage(to: conv.contactNumber, body: body)
                    }
                )
            } else {
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No Conversation Selected",
                    message: "Choose a conversation from the list to read and reply."
                )
                .background(.background)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

struct ConversationListView: View {
    let conversations: [SMSConversation]
    @Binding var selectedThread: String?

    var body: some View {
        Group {
            if conversations.isEmpty {
                EmptyStateView(
                    systemImage: "message",
                    title: "No Messages",
                    message: "Conversations from your phone will appear here."
                )
            } else {
                List(conversations, selection: $selectedThread) { conv in
                    ConversationRow(conv: conv)
                        .tag(conv.threadId)
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Messages")
    }
}

private struct ConversationRow: View {
    let conv: SMSConversation

    private var isUnread: Bool { conv.unreadCount > 0 }

    var body: some View {
        HStack(spacing: Theme.s3) {
            Avatar(name: conv.contactName, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.s2) {
                    Text(conv.contactName)
                        .font(.subheadline)
                        .fontWeight(isUnread ? .semibold : .medium)
                        .lineLimit(1)
                    Spacer(minLength: Theme.s1)
                    Text(SMSTime.short(conv.lastTimestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: Theme.s2) {
                    Text(conv.lastMessage)
                        .font(.caption)
                        .foregroundStyle(isUnread ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: Theme.s1)
                    if isUnread {
                        Text("\(conv.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }
}

struct MessageThreadView: View {
    let conversation: SMSConversation
    let messages: [SMSMessageItem]
    let onSend: (String) -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            WindowHeader(
                title: conversation.contactName,
                subtitle: conversation.contactNumber
            ) {
                Avatar(name: conversation.contactName, size: 30)
            }

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.s2) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.messageId)
                        }
                    }
                    .padding(.horizontal, Theme.s4)
                    .padding(.vertical, Theme.s4)
                }
                .background(.background)
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.messageId, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Compose
            HStack(spacing: Theme.s2) {
                TextField("Type a message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, Theme.s2)
                    .background(Color(.textBackgroundColor), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline(composerFocused), lineWidth: 1))
                    .onSubmit { send() }

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(draft.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                }
                .disabled(draft.isEmpty)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .background(.bar)
        }
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(draft)
        draft = ""
    }
}

struct MessageBubble: View {
    let message: SMSMessageItem

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 64) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                Text(message.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, Theme.s2)
                    .background(bubbleBackground)
                    .foregroundStyle(message.isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(message.isOutgoing ? Color.clear : Theme.hairline(), lineWidth: 1)
                    )

                Text(SMSTime.clock(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.s1)
            }

            if !message.isOutgoing { Spacer(minLength: 64) }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.isOutgoing {
            Color.accentColor
        } else {
            Color(.controlBackgroundColor)
        }
    }
}
