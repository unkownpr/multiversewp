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
}
