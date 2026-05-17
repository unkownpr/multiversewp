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
}
