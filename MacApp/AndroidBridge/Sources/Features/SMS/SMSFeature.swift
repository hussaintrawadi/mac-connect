import Foundation
import Combine
import os

final class SMSFeature: ObservableObject {
    @Published var conversations: [SMSConversation] = []
    @Published var activeThread: String? {
        didSet {
            // When a conversation is opened, show its stored messages.
            loadActiveMessages()
        }
    }
    @Published var activeMessages: [SMSMessageItem] = []

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "SMS")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    private func loadActiveMessages() {
        guard let thread = activeThread,
              let conv = conversations.first(where: { $0.threadId == thread }) else {
            activeMessages = []
            return
        }
        activeMessages = conv.messages.sorted { $0.timestamp < $1.timestamp }
        // Opening a thread clears its unread badge.
        if let idx = conversations.firstIndex(where: { $0.threadId == thread }) {
            conversations[idx].unreadCount = 0
        }
    }

    func handleConversation(_ proto: ABSmsConversation) {
        // Conversations now arrive WITH their recent messages populated.
        let msgs: [SMSMessageItem] = proto.messages.map { m in
            SMSMessageItem(
                messageId: m.messageID.isEmpty ? UUID().uuidString : m.messageID,
                threadId: proto.threadID,
                sender: m.sender,
                body: m.body,
                timestamp: Date(timeIntervalSince1970: Double(m.timestampMs) / 1000),
                isOutgoing: m.isOutgoing,
                isRead: m.isRead
            )
        }

        let conv = SMSConversation(
            threadId: proto.threadID,
            contactName: proto.contactName,
            contactNumber: proto.contactNumber,
            lastMessage: proto.lastMessage,
            lastTimestamp: Date(timeIntervalSince1970: Double(proto.lastTimestampMs) / 1000),
            unreadCount: Int(proto.unreadCount),
            messages: msgs
        )

        DispatchQueue.main.async {
            if let idx = self.conversations.firstIndex(where: { $0.threadId == conv.threadId }) {
                self.conversations[idx] = conv
            } else {
                self.conversations.append(conv)
            }
            self.conversations.sort { $0.lastTimestamp > $1.lastTimestamp }
            // If this thread is open, refresh the visible messages.
            if self.activeThread == conv.threadId {
                self.loadActiveMessages()
            }
        }
    }

    func handleMessage(_ proto: ABSmsMessage) {
        let msg = SMSMessageItem(
            messageId: proto.messageID.isEmpty ? UUID().uuidString : proto.messageID,
            threadId: proto.threadID,
            sender: proto.sender,
            body: proto.body,
            timestamp: Date(timeIntervalSince1970: Double(proto.timestampMs) / 1000),
            isOutgoing: proto.isOutgoing,
            isRead: proto.isRead,
            contactName: proto.contactName
        )

        DispatchQueue.main.async {
            self.ingestMessage(msg)
        }
    }

    /// Insert a message into its conversation (creating the conversation if it's new),
    /// and into the open thread view if it belongs there.
    private func ingestMessage(_ msg: SMSMessageItem) {
        // Find conversation by threadId first, then by phone number.
        var idx = conversations.firstIndex(where: { !msg.threadId.isEmpty && $0.threadId == msg.threadId })
        if idx == nil {
            idx = conversations.firstIndex(where: { $0.contactNumber == msg.sender })
        }

        if let i = idx {
            if !conversations[i].messages.contains(where: { $0.messageId == msg.messageId }) {
                conversations[i].messages.append(msg)
            }
            conversations[i].lastMessage = msg.body
            conversations[i].lastTimestamp = msg.timestamp
            // Upgrade a number-only title to the real contact name if we now have it.
            if !msg.contactName.isEmpty, msg.contactName != msg.sender,
               conversations[i].contactName == conversations[i].contactNumber {
                conversations[i].contactName = msg.contactName
            }
            if !msg.isOutgoing && conversations[i].threadId != activeThread {
                conversations[i].unreadCount += 1
            }
        } else {
            // New conversation — prefer the contact name over the raw number.
            let displayName = msg.contactName.isEmpty ? msg.sender : msg.contactName
            let conv = SMSConversation(
                threadId: msg.threadId.isEmpty ? msg.sender : msg.threadId,
                contactName: displayName,
                contactNumber: msg.sender,
                lastMessage: msg.body,
                lastTimestamp: msg.timestamp,
                unreadCount: msg.isOutgoing ? 0 : 1,
                messages: [msg]
            )
            conversations.append(conv)
        }

        conversations.sort { $0.lastTimestamp > $1.lastTimestamp }

        // Append to the open thread (match by threadId or sender number).
        let activeConv = conversations.first(where: { $0.threadId == activeThread })
        let belongsToActive = (!msg.threadId.isEmpty && msg.threadId == activeThread)
            || (activeConv != nil && activeConv?.contactNumber == msg.sender)
        if belongsToActive, !activeMessages.contains(where: { $0.messageId == msg.messageId }) {
            activeMessages.append(msg)
            activeMessages.sort { $0.timestamp < $1.timestamp }
        }
    }

    func handleDeliveryStatus(_ status: ABSmsDeliveryStatus) {
        logger.info("SMS delivery: requestId=\(status.requestID) delivered=\(status.delivered)")
    }

    func sendMessage(to recipient: String, body: String) {
        let requestId = UUID().uuidString

        var smsSend = ABSmsSend()
        smsSend.recipient = recipient
        smsSend.body = body
        smsSend.requestID = requestId

        var envelope = ABEnvelope()
        envelope.smsSend = smsSend
        onSendEnvelope?(envelope)

        // Optimistically show the outgoing message right away.
        let outgoing = SMSMessageItem(
            messageId: requestId,
            threadId: activeThread ?? "",
            sender: recipient,
            body: body,
            timestamp: Date(),
            isOutgoing: true,
            isRead: true
        )
        DispatchQueue.main.async { self.ingestMessage(outgoing) }

        logger.info("SMS send requested to \(recipient)")
    }
}

struct SMSConversation: Identifiable {
    let threadId: String
    var contactName: String
    let contactNumber: String
    var lastMessage: String
    var lastTimestamp: Date
    var unreadCount: Int
    var messages: [SMSMessageItem] = []

    var id: String { threadId }
}

struct SMSMessageItem: Identifiable {
    let messageId: String
    let threadId: String
    let sender: String
    let body: String
    let timestamp: Date
    let isOutgoing: Bool
    let isRead: Bool
    var contactName: String = ""

    var id: String { messageId }
}
