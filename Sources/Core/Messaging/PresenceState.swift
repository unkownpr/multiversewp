import Foundation

/// Snapshot of a contact's presence as last reported by whatsmeow.
///
/// All fields are independent — the helper emits two distinct events:
/// `presence` carries availability + (optional) last seen, while
/// `chat_presence` carries the composing / recording indicator for the
/// currently open chat. The aggregator in `AppEnvironment` merges them
/// into this struct keyed by JID.
public struct PresenceState: Sendable, Equatable {
    public var isOnline: Bool
    public var lastSeen: Date?
    public var isTyping: Bool
    public var isRecording: Bool

    public init(isOnline: Bool = false,
                lastSeen: Date? = nil,
                isTyping: Bool = false,
                isRecording: Bool = false) {
        self.isOnline = isOnline
        self.lastSeen = lastSeen
        self.isTyping = isTyping
        self.isRecording = isRecording
    }
}
