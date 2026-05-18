import XCTest
@testable import MultiverseWP

final class WireProtocolTests: XCTestCase {

    func testEncodeConnect() throws {
        let envelope = WireEnvelope(id: "abc", command: .connect)
        let data = try WireEncoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "connect")
        XCTAssertEqual(json?["id"] as? String, "abc")
    }

    func testEncodeSendMessage() throws {
        let envelope = WireEnvelope(
            id: "send-1",
            command: .sendMessage(SendMessageRequest(chatJID: "111@s.whatsapp.net", text: "hi"))
        )
        let data = try WireEncoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = json?["payload"] as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "send_message")
        XCTAssertEqual(payload?["chat_jid"] as? String, "111@s.whatsapp.net")
        XCTAssertEqual(payload?["text"] as? String, "hi")
    }

    func testDecodeQR() throws {
        let json = #"{"type":"qr","payload":{"code":"WA:abc"}}"#
        let result = try WireDecoder.decode(Data(json.utf8))
        guard case .event(.qrCode(let code)) = result else {
            return XCTFail("Expected qr event, got \(result)")
        }
        XCTAssertEqual(code, "WA:abc")
    }

    func testDecodeMessage() throws {
        let json = """
        {"type":"message","payload":{
            "id":"m1","chat_jid":"chat@x","sender_jid":"sender@x",
            "kind":"text","body":"hello","timestamp":1700000000
        }}
        """
        let result = try WireDecoder.decode(Data(json.utf8))
        guard case .event(.messageReceived(let message)) = result else {
            return XCTFail("Expected message event, got \(result)")
        }
        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(message.body, "hello")
        XCTAssertEqual(message.chatJID, "chat@x")
    }

    func testDecodeResponseMapsBackToCommandID() throws {
        let json = #"{"type":"response","id":"req-1","payload":{"message_id":"abc","ok":true}}"#
        let result = try WireDecoder.decode(Data(json.utf8))
        guard case .response(let id, let response) = result else {
            return XCTFail("Expected response, got \(result)")
        }
        XCTAssertEqual(id, "req-1")
        XCTAssertEqual(response.messageID, "abc")
        XCTAssertTrue(response.ok)
    }

    func testDecodeRejectsUnknownType() {
        let json = #"{"type":"nope","payload":{}}"#
        XCTAssertThrowsError(try WireDecoder.decode(Data(json.utf8)))
    }

    func testDecodeMessageCarriesMediaPath() throws {
        let json = """
        {"type":"message","payload":{
            "id":"m2","chat_jid":"chat@x","sender_jid":"sender@x",
            "kind":"image","mime_type":"image/jpeg","media_byte_size":2048,
            "media_path":"/var/folders/X/photo.jpg","timestamp":1700000000
        }}
        """
        let result = try WireDecoder.decode(Data(json.utf8))
        guard case .event(.messageReceived(let message)) = result else {
            return XCTFail("Expected message event, got \(result)")
        }
        XCTAssertEqual(message.kind, "image")
        XCTAssertEqual(message.mediaPath, "/var/folders/X/photo.jpg")
        XCTAssertEqual(message.mediaByteSize, 2048)
    }

    func testDecodeDeliveryParsesMediaPath() throws {
        let json = #"{"type":"delivery","payload":{"message_id":"abc","status":"downloaded","media_path":"/tmp/a.jpg"}}"#
        let result = try WireDecoder.decode(Data(json.utf8))
        guard case .event(.deliveryUpdate(let id, let status, let mediaPath)) = result else {
            return XCTFail("Expected delivery event, got \(result)")
        }
        XCTAssertEqual(id, "abc")
        XCTAssertEqual(status, "downloaded")
        XCTAssertEqual(mediaPath, "/tmp/a.jpg")
    }

    func testEncodeSendMessageIncludesMediaFields() throws {
        let envelope = WireEnvelope(
            id: "media-1",
            command: .sendMessage(SendMessageRequest(
                chatJID: "111@s.whatsapp.net",
                text: nil,
                mediaPath: "/tmp/photo.png",
                mediaMimeType: "image/png",
                caption: "trip"
            ))
        )
        let data = try WireEncoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = json?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["media_path"] as? String, "/tmp/photo.png")
        XCTAssertEqual(payload?["mime_type"] as? String, "image/png")
        XCTAssertEqual(payload?["caption"] as? String, "trip")
    }

    func testEncodeListGroupMembers() throws {
        let envelope = WireEnvelope(
            id: "lgm-1",
            command: .listGroupMembers(chatJID: "g@g.us")
        )
        let data = try WireEncoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "list_group_members")
        let payload = json?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["chat_jid"] as? String, "g@g.us")
    }

    func testEncodeCreateGroup() throws {
        let envelope = WireEnvelope(
            id: "cg-1",
            command: .createGroup(subject: "Trip Crew", participantJIDs: ["a@s.whatsapp.net", "b@s.whatsapp.net"])
        )
        let data = try WireEncoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "create_group")
        let payload = json?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["subject"] as? String, "Trip Crew")
        XCTAssertEqual(payload?["participant_jids"] as? [String], ["a@s.whatsapp.net", "b@s.whatsapp.net"])
    }

    func testEncodeCheckPhone() throws {
        let envelope = WireEnvelope(
            id: "cp-1",
            command: .checkPhone(phoneNumber: "+905551112233")
        )
        let data = try WireEncoder.encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "check_phone")
        let payload = json?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["phone_number"] as? String, "+905551112233")
    }

    func testDecodeResponseExposesExtraPayload() throws {
        let json = """
        {"type":"response","id":"req-9","payload":{"ok":true,"members":[{"jid":"a@s.whatsapp.net","is_admin":true}]}}
        """
        let result = try WireDecoder.decode(Data(json.utf8))
        guard case .response(_, let response) = result else {
            return XCTFail("Expected response, got \(result)")
        }
        XCTAssertTrue(response.ok)
        let members = response.extra?["members"] as? [[String: Any]]
        XCTAssertEqual(members?.first?["jid"] as? String, "a@s.whatsapp.net")
        XCTAssertEqual(members?.first?["is_admin"] as? Bool, true)
    }
}
