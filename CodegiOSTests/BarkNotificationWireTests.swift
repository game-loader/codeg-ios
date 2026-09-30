import Foundation
import XCTest
@testable import Codeg

@MainActor
final class BarkNotificationWireTests: XCTestCase {
    func testSharedDecoderAcceptsContractCamelCaseAndSnakeCase() throws {
        for json in [
            #"{"enabled":true,"pushUrl":"http://bark.example/key","includePreview":true,"language":"zh-Hans"}"#,
            #"{"enabled":true,"push_url":"http://bark.example/key","include_preview":true,"language":"zh-Hans"}"#
        ] {
            let settings = try CodegJSON.decoder.decode(BarkNotificationSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings, BarkNotificationSettings(enabled: true, pushUrl: "http://bark.example/key",
                                                               includePreview: true, language: "zh-Hans"))
        }
    }

    func testRequestsEncodeExactCamelCaseFieldsAndProfileUUID() throws {
        let id = UUID()
        let settings = BarkNotificationSettings()
        let body = SetBarkNotificationSettingsBody(deviceId: id.uuidString, settings: settings)
        let data = try CodegJSON.encoder.encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["deviceId", "settings"])
        XCTAssertEqual(object["deviceId"] as? String, id.uuidString)
        let wireSettings = try XCTUnwrap(object["settings"] as? [String: Any])
        XCTAssertEqual(Set(wireSettings.keys), ["enabled", "pushUrl", "includePreview", "language"])
        XCTAssertEqual(wireSettings["enabled"] as? Bool, false)
        XCTAssertEqual(wireSettings["pushUrl"] as? String, "")
        XCTAssertEqual(wireSettings["includePreview"] as? Bool, false)
        XCTAssertEqual(wireSettings["language"] as? String, "en")
        let device = try CodegJSON.encoder.encode(BarkDeviceBody(deviceId: id.uuidString))
        let deviceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: device) as? [String: String])
        XCTAssertEqual(deviceObject, ["deviceId": id.uuidString])
    }

    func testOptionalSourceNameAndServerURLDecodeAndRoundTrip() throws {
        for source in ["", #","sourceName":null"#, #","sourceName":"""#] {
            let json = "{\"enabled\":false,\"pushUrl\":\"\",\"includePreview\":false,\"language\":\"en\"\(source)}"
            let settings = try CodegJSON.decoder.decode(BarkNotificationSettings.self, from: Data(json.utf8))
            XCTAssertTrue(settings.sourceName?.isEmpty ?? true)
        }
        for json in [
            #"{"enabled":true,"pushUrl":"http://bark.example/key","includePreview":true,"language":"zh-Hans","sourceName":"研究服务器","serverUrl":"https://workspace.example"}"#,
            #"{"enabled":true,"push_url":"http://bark.example/key","include_preview":true,"language":"zh-Hans","source_name":"研究服务器","server_url":"https://workspace.example"}"#
        ] {
            let settings = try CodegJSON.decoder.decode(BarkNotificationSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.sourceName, "研究服务器")
            XCTAssertEqual(settings.serverUrl, "https://workspace.example")
            let encoded = try CodegJSON.encoder.encode(settings)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["enabled", "pushUrl", "includePreview", "language", "sourceName", "serverUrl"])
            XCTAssertEqual(object["sourceName"] as? String, "研究服务器")
            XCTAssertEqual(object["serverUrl"] as? String, "https://workspace.example")
            XCTAssertEqual(try CodegJSON.decoder.decode(BarkNotificationSettings.self, from: encoded), settings)
        }
    }

    func testClientPOSTEndpointsUseSavedProfileIdentityAndAcceptNullAcknowledgement() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = CodegClient(baseURL: URL(string: "https://wire.bark.invalid")!, token: "fixture", session: session)
        let loaded = try await client.barkNotificationSettings(deviceID: BarkWireProtocol.deviceID)
        XCTAssertEqual(loaded, BarkNotificationSettings())
        let settings = BarkNotificationSettings(enabled: true, pushUrl: "https://api.day.app/test-key",
                                                includePreview: true, language: "zh-Hans",
                                                sourceName: "Remote workspace", serverUrl: "https://workspace.example")
        let saved = try await client.setBarkNotificationSettings(deviceID: BarkWireProtocol.deviceID, settings: settings)
        XCTAssertEqual(saved, settings)
        try await client.testBarkNotification(deviceID: BarkWireProtocol.deviceID)
    }

    func testMalformedTestAcknowledgementIsNotReportedAsSuccess() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = CodegClient(baseURL: URL(string: "https://bad-ack.bark.invalid")!, token: "fixture", session: session)
        do {
            try await client.testBarkNotification(deviceID: BarkWireProtocol.deviceID)
            XCTFail("Expected an invalid acknowledgement to fail")
        } catch APIError.decoding { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BarkWireProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// No global mutable handler: every fixture request is checked independently.
/// Invalid paths, verbs, identities, or keys fail instead of reaching a network.
private final class BarkWireProtocol: URLProtocol, @unchecked Sendable {
    static let deviceID = UUID(uuidString: "E2570956-B079-41D6-9A15-5B3D27DAB5F7")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            guard request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json" else {
                throw URLError(.badServerResponse)
            }
            let body = try requestBody()
            guard body["deviceId"] as? String == Self.deviceID.uuidString else { throw URLError(.badServerResponse) }
            let response: Data
            switch request.url?.path {
            case "/api/get_bark_notification_settings":
                guard Set(body.keys) == ["deviceId"] else { throw URLError(.badServerResponse) }
                response = Data(#"{"enabled":false,"pushUrl":"","includePreview":false,"language":"en"}"#.utf8)
            case "/api/set_bark_notification_settings":
                guard Set(body.keys) == ["deviceId", "settings"],
                      let settings = body["settings"] as? [String: Any],
                      Set(settings.keys) == ["enabled", "pushUrl", "includePreview", "language", "sourceName", "serverUrl"],
                      settings["sourceName"] as? String == "Remote workspace",
                      settings["serverUrl"] as? String == "https://workspace.example" else {
                    throw URLError(.badServerResponse)
                }
                response = try JSONSerialization.data(withJSONObject: settings)
            case "/api/test_bark_notification":
                guard Set(body.keys) == ["deviceId"] else { throw URLError(.badServerResponse) }
                response = Data((request.url?.host == "bad-ack.bark.invalid" ? "{}" : "null").utf8)
            default: throw URLError(.unsupportedURL)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func requestBody() throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeRawData)
        }
        return body
    }
}
