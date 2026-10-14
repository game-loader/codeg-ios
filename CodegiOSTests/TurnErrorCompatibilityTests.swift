import Foundation
import XCTest
@testable import Codeg

@MainActor
final class TurnErrorCompatibilityTests: XCTestCase {
    func testPersistedFailedTurnDecodesAndAppearsInTimeline() throws {
        let turn: MessageTurn = try CodegJSON.decoder.decode(MessageTurn.self, from: Data(#"{"id":"failed-turn","role":"system","blocks":[{"type":"turn_error","message":"API Error: 503 unavailable"}],"timestamp":"2026-10-14T00:00:00Z"}"#.utf8))
        XCTAssertEqual(turn.blocks, [.turnError(message: "API Error: 503 unavailable")])
        let nodes = TranscriptTimeline.buildPersisted(turns: [turn], pending: [], agent: .claudeCode,
                                                      suppressInFlight: false)
        XCTAssertEqual(nodes.count, 1)
        guard case .error(let message) = nodes.first?.content else {
            return XCTFail("Persisted failures must render as errors")
        }
        XCTAssertEqual(message, "API Error: 503 unavailable")
    }

    func testFailureKeepsOrdinarySystemTextAndStableIdentity() {
        let turn = MessageTurn(id: "mixed", role: .system,
                               blocks: [.text("Context note"), .turnError(message: "Disconnected")],
                               timestamp: .distantPast)
        let nodes = TranscriptTimeline.buildPersisted(turns: [turn], pending: [], agent: .codex,
                                                      suppressInFlight: true)
        XCTAssertEqual(nodes.map(\.id), ["mixed", "mixed#error-1"])
        guard case .system(let original) = nodes[0].content else { return XCTFail("System text lost") }
        XCTAssertEqual(SystemText.of(original), "Context note")
        guard case .error(let message) = nodes[1].content else { return XCTFail("Failure lost") }
        XCTAssertEqual(message, "Disconnected")
    }

    func testKnownFailureIsNotUnknownOrAssistantProse() throws {
        let block = try CodegJSON.decoder.decode(ContentBlock.self,
                                                from: Data(#"{"type":"turn_error","message":"Failed"}"#.utf8))
        let turn = MessageTurn(id: "adapter", role: .assistant, blocks: [block], timestamp: .distantPast)
        let parts = MessageRender.adaptTurn(turn)
        guard case .turnError(let message) = parts.first else { return XCTFail("Adapter must retain failure type") }
        XCTAssertEqual(message, "Failed")
        let unknown = try CodegJSON.decoder.decode(ContentBlock.self, from: Data(#"{"type":"future_block"}"#.utf8))
        XCTAssertEqual(unknown, .unknown(type: "future_block"))
    }
}
