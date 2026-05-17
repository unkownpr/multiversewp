import Foundation

enum WireCommand: Sendable {
    case connect
    case disconnect
    case sendMessage(SendMessageRequest)
    case fetchHistory(chatJID: String, limit: Int)
    case downloadMedia(messageID: String)
    case markRead(chatJID: String)
}

struct WireEnvelope: Sendable {
    let id: String
    let command: WireCommand
}

struct WireResponse: Sendable {
    let messageID: String?
    let localPath: String?
    let ok: Bool
    let errorMessage: String?
}

enum WireMessage: Sendable {
    case response(id: String, WireResponse)
    case event(WAClientEvent)
}

enum WireEncoder {
    static func encode(_ envelope: WireEnvelope) throws -> Data {
        var dict: [String: Any] = ["id": envelope.id]
        switch envelope.command {
        case .connect:
            dict["type"] = "connect"
        case .disconnect:
            dict["type"] = "disconnect"
        case .sendMessage(let request):
            dict["type"] = "send_message"
            var payload: [String: Any] = ["chat_jid": request.chatJID]
            if let text = request.text { payload["text"] = text }
            if let path = request.mediaPath { payload["media_path"] = path }
            if let mime = request.mediaMimeType { payload["mime_type"] = mime }
            if let caption = request.caption { payload["caption"] = caption }
            if let quoted = request.quotedMessageID { payload["quoted_message_id"] = quoted }
            dict["payload"] = payload
        case .fetchHistory(let chatJID, let limit):
            dict["type"] = "fetch_history"
            dict["payload"] = ["chat_jid": chatJID, "limit": limit]
        case .downloadMedia(let id):
            dict["type"] = "download_media"
            dict["payload"] = ["message_id": id]
        case .markRead(let chatJID):
            dict["type"] = "mark_read"
            dict["payload"] = ["chat_jid": chatJID]
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }
}

enum WireDecoder {
    static func decode(_ data: Data) throws -> WireMessage {
        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw WAClientError.decodingFailed("Expected JSON object")
        }
        guard let type = json["type"] as? String else {
            throw WAClientError.decodingFailed("Missing 'type'")
        }

        if type == "response", let id = json["id"] as? String {
            let payload = json["payload"] as? [String: Any] ?? [:]
            let response = WireResponse(
                messageID: payload["message_id"] as? String,
                localPath: payload["local_path"] as? String,
                ok: (payload["ok"] as? Bool) ?? (json["error"] == nil),
                errorMessage: json["error"] as? String
            )
            return .response(id: id, response)
        }

        let payload = json["payload"] as? [String: Any] ?? [:]
        switch type {
        case "qr":
            guard let code = payload["code"] as? String else {
                throw WAClientError.decodingFailed("qr missing code")
            }
            return .event(.qrCode(code))
        case "pair_success":
            let jid = payload["jid"] as? String ?? ""
            let push = payload["push_name"] as? String
            return .event(.pairSuccess(jid: jid, pushName: push))
        case "connected":
            return .event(.connected)
        case "disconnected":
            return .event(.disconnected(reason: payload["reason"] as? String))
        case "message":
            return .event(.messageReceived(try decodeMessage(payload)))
        case "delivery":
            guard
                let id = payload["message_id"] as? String,
                let status = payload["status"] as? String
            else { throw WAClientError.decodingFailed("delivery missing fields") }
            return .event(.deliveryUpdate(messageID: id, status: status))
        case "contact":
            guard let jid = payload["jid"] as? String else {
                throw WAClientError.decodingFailed("contact missing jid")
            }
            return .event(.contactUpdate(IncomingContact(
                jid: jid,
                pushName: payload["push_name"] as? String,
                businessName: payload["business_name"] as? String,
                phoneNumber: payload["phone_number"] as? String
            )))
        case "error":
            return .event(.error(payload["message"] as? String ?? "unknown error"))
        default:
            throw WAClientError.decodingFailed("Unknown event type: \(type)")
        }
    }

    private static func decodeMessage(_ payload: [String: Any]) throws -> IncomingMessage {
        guard
            let id = payload["id"] as? String,
            let chatJID = payload["chat_jid"] as? String,
            let senderJID = payload["sender_jid"] as? String,
            let kind = payload["kind"] as? String
        else { throw WAClientError.decodingFailed("message missing required fields") }

        let timestamp: Date
        if let unix = payload["timestamp"] as? Double {
            timestamp = Date(timeIntervalSince1970: unix)
        } else if let unix = payload["timestamp"] as? Int {
            timestamp = Date(timeIntervalSince1970: TimeInterval(unix))
        } else {
            timestamp = Date()
        }

        return IncomingMessage(
            id: id,
            chatJID: chatJID,
            senderJID: senderJID,
            senderPushName: payload["sender_push_name"] as? String,
            isFromMe: (payload["is_from_me"] as? Bool) ?? false,
            isGroup: (payload["is_group"] as? Bool) ?? false,
            kind: kind,
            body: payload["body"] as? String,
            mimeType: payload["mime_type"] as? String,
            mediaURL: payload["media_url"] as? String,
            mediaByteSize: payload["media_byte_size"] as? Int64,
            quotedMessageID: payload["quoted_message_id"] as? String,
            timestamp: timestamp
        )
    }
}
