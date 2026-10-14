import Foundation
import XCTest
@testable import Codeg

final class TerminalSnapshotRecoveryTests: XCTestCase {
    private func snapshot(_ data: String = "history", seq: UInt64 = 4,
                          generation: String? = "pty-a", alive: Bool = true,
                          exists: Bool = true, code: UInt32? = nil) -> TerminalSnapshot {
        TerminalSnapshot(exists: exists, alive: alive, data: data, seq: seq,
                         generation: generation, exitCode: code, cols: 120, rows: 40)
    }

    func testSnakeSnapshotRawEscapesAndNullDefaults() throws {
        let wire = Data(#"{"exists":true,"alive":false,"data":"\u001b[31m你好\r\n","seq":18446744073709551615,"generation":"pty-a","exit_code":9,"cols":120,"rows":40}"#.utf8)
        let value = try CodegJSON.decoder.decode(TerminalSnapshot.self, from: wire)
        XCTAssertEqual(value.data, "\u{1b}[31m你好\r\n")
        XCTAssertEqual(value.seq, UInt64.max)
        XCTAssertEqual(value.exitCode, 9)
        XCTAssertEqual(value.cols, 120)
        XCTAssertEqual(value.rows, 40)
        XCTAssertTrue(value.exists)
        XCTAssertFalse(value.alive)
        let missing = try CodegJSON.decoder.decode(TerminalSnapshot.self, from: Data(#"{"exists":false,"alive":false,"data":"","generation":null,"exit_code":null,"cols":null,"rows":null}"#.utf8))
        XCTAssertEqual(missing.seq, 0)
        XCTAssertNil(missing.generation)
        XCTAssertNil(missing.exitCode)
        XCTAssertNil(missing.cols)
    }

    func testOlderSnapshotDefaultsAndMalformedResponses() throws {
        let old = try CodegJSON.decoder.decode(TerminalSnapshot.self, from: Data(#"{"alive":true,"data":"shell","seq":2}"#.utf8))
        XCTAssertTrue(old.exists)
        XCTAssertNil(old.generation)
        XCTAssertNil(old.rows)
        let missing = try CodegJSON.decoder.decode(TerminalSnapshot.self, from: Data(#"{"alive":false,"data":""}"#.utf8))
        XCTAssertFalse(missing.exists)
        for raw in ["{}", "null", #"{"alive":true,"data":5}"#, #"{"alive":true,"data":"","seq":-1}"#] {
            XCTAssertThrowsError(try CodegJSON.decoder.decode(TerminalSnapshot.self, from: Data(raw.utf8)))
        }
    }

    func testActualFirehoseWirePreservesCursorsAndLegacyFrames() {
        XCTAssertEqual(TerminalFrame.decode(Data(#"{"channel":"__ready__","payload":null}"#.utf8)), .ready)
        XCTAssertEqual(TerminalFrame.decode(Data(#"{"channel":"terminal://output/t","payload":{"terminal_id":"t","data":"\u001b[Hok","seq":18446744073709551615,"generation":"g"}}"#.utf8)),
                       .output(id: "t", data: "\u{1b}[Hok", seq: UInt64.max, generation: "g"))
        XCTAssertEqual(TerminalFrame.decode(Data(#"{"channel":"terminal://exit/t","payload":{"terminal_id":"t","data":"","seq":0,"generation":"g"}}"#.utf8)), .exit(id: "t", seq: 0, generation: "g"))
        XCTAssertEqual(TerminalFrame.decode(Data(#"{"channel":"terminal://output/t","payload":{"data":"old"}}"#.utf8)), .output(id: "t", data: "old"))
        XCTAssertEqual(TerminalFrame.decode(Data(#"{"channel":"terminal://exit/t"}"#.utf8)), .exit(id: "t"))
        for raw in [#"{"type":"attached"}"#, #"{"channel":"other","payload":null}"#,
                    #"{"channel":"terminal://output/t","payload":{"data":"x","seq":"1"}}"#,
                    #"{"channel":"terminal://output/t","payload":{"data":"x","terminal_id":"other"}}"#] {
            XCTAssertNil(TerminalFrame.decode(Data(raw.utf8)))
        }
    }

    func testGapRebuildOverlapReplayAndPermanentWatermark() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        XCTAssertEqual(r.receive(.output(id: "t", data: "before", seq: 1, generation: "pty-a")), [.output("before")])
        let ticket = r.beginReconnect()
        XCTAssertEqual(r.receive(.output(id: "t", data: "overlap", seq: 4, generation: "pty-a")), [])
        XCTAssertEqual(r.receive(.output(id: "t", data: "newer", seq: 5, generation: "pty-a")), [])
        let value = snapshot("before+gap+overlap")
        XCTAssertEqual(r.resolve(value, request: ticket), [.rebuild(value), .output("newer")])
        XCTAssertEqual(r.state, .streaming)
        XCTAssertEqual(r.receive(.output(id: "t", data: "late covered", seq: 3, generation: "pty-a")), [])
        XCTAssertEqual(r.receive(.output(id: "t", data: "late newer", seq: 6, generation: "pty-a")), [.output("late newer")])
        XCTAssertEqual(r.snapshotWatermark, 4)
    }

    func testLiveOrderDoesNotRaiseSnapshotFloor() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let ticket = r.beginReconnect()
        _ = r.resolve(snapshot(), request: ticket)
        XCTAssertEqual(r.receive(.output(id: "t", data: "six", seq: 6, generation: "pty-a")), [.output("six")])
        XCTAssertEqual(r.receive(.output(id: "t", data: "five", seq: 5, generation: "pty-a")), [.output("five")])
    }

    func testRejectStaleOutputAndEveryBufferedExitGeneration() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let ticket = r.beginReconnect()
        _ = r.receive(.output(id: "t", data: "stale", seq: 99, generation: "old"))
        _ = r.receive(.exit(id: "t", seq: 0, generation: "pty-a"))
        _ = r.receive(.exit(id: "t", seq: 0, generation: "old"))
        _ = r.receive(.output(id: "t", data: "tail", seq: 5, generation: "pty-a"))
        let value = snapshot()
        XCTAssertEqual(r.resolve(value, request: ticket), [.rebuild(value), .output("tail"), .exited(nil)])
        XCTAssertEqual(r.state, .exited)
        XCTAssertEqual(r.receive(.output(id: "t", data: "ignored", seq: 7, generation: "pty-a")), [])
    }

    func testStaleExitCannotEndRecoveredRunningPTY() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let ticket = r.beginReconnect()
        _ = r.receive(.exit(id: "t", generation: "old"))
        let value = snapshot()
        XCTAssertEqual(r.resolve(value, request: ticket), [.rebuild(value)])
        XCTAssertEqual(r.receive(.exit(id: "t", generation: "old")), [])
        XCTAssertEqual(r.receive(.output(id: "other", data: "other", seq: 5, generation: "pty-a")), [])
        XCTAssertEqual(r.state, .streaming)
    }

    func testExitDuringOfflineGapRecoveredFromRetainedSnapshot() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let ticket = r.beginReconnect()
        let value = snapshot("final output", alive: false, code: 17)
        XCTAssertEqual(r.resolve(value, request: ticket), [.rebuild(value), .exited(17)])
        XCTAssertEqual(r.state, .exited)
    }

    func testMissingAndRequestFailureRequireExplicitRestart() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let ticket = r.beginReconnect()
        XCTAssertEqual(r.resolve(snapshot("", seq: 0, generation: nil, alive: false, exists: false), request: ticket), [.unavailable(.missing)])
        XCTAssertEqual(r.state, .unavailable(.missing))
        var failed = TerminalSnapshotRecovery(terminalID: "t")
        let request = failed.beginReconnect()
        XCTAssertEqual(failed.failed("HTTP 500", request: request), [.unavailable(.request("HTTP 500"))])
        XCTAssertEqual(failed.receive(.exit(id: "t")), [])
    }

    func testPTYGenerationCannotChangeUnderRetainedTerminalUUID() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        _ = r.receive(.output(id: "t", data: "original", seq: 1, generation: "pty-a"))
        let ticket = r.beginReconnect()
        XCTAssertEqual(r.resolve(snapshot(generation: "replacement"), request: ticket), [.unavailable(.generationChanged)])
    }

    func testRetirementCancellationAndSupersededHTTPResultsAreIgnored() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let first = r.beginReconnect()
        _ = r.receive(.output(id: "t", data: "held", seq: 5, generation: "pty-a"))
        r.cancelRequest()
        XCTAssertEqual(r.resolve(snapshot(), request: first), [])
        let newer = r.beginReconnect()
        XCTAssertEqual(r.failed("late failure", request: first), [])
        let value = snapshot()
        XCTAssertEqual(r.resolve(value, request: newer), [.rebuild(value), .output("held")])
        let retired = r.beginReconnect()
        r.retire()
        XCTAssertEqual(r.resolve(value, request: retired), [])
        XCTAssertEqual(r.unsupported(request: retired), [])
        _ = r.beginReconnect()
        XCTAssertEqual(r.state, .retired)
        XCTAssertEqual(r.receive(.exit(id: "t")), [])
    }

    func testLegacyAndZeroSequenceOutputNeverSilentlyDropped() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let ticket = r.beginReconnect()
        _ = r.resolve(snapshot(), request: ticket)
        XCTAssertEqual(r.receive(.output(id: "t", data: "no cursor")), [.output("no cursor")])
        XCTAssertEqual(r.receive(.output(id: "t", data: "zero", seq: 0, generation: "pty-a")), [.output("zero")])
        XCTAssertEqual(r.receive(.output(id: "t", data: "no generation", seq: 2)), [.output("no generation")])
        let reconnect = r.beginReconnect()
        _ = r.receive(.output(id: "t", data: "legacy buffer"))
        XCTAssertEqual(r.unsupported(request: reconnect), [.output("legacy buffer")])
        XCTAssertEqual(r.state, .legacy)
        XCTAssertEqual(r.receive(.exit(id: "t")), [.exited(nil)])
    }

    func testOldSnapshotStillSupportsItsComparableSequence() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let ticket = r.beginReconnect()
        _ = r.receive(.output(id: "t", data: "covered", seq: 2))
        _ = r.receive(.output(id: "t", data: "new", seq: 3))
        let value = snapshot("old", seq: 2, generation: nil)
        XCTAssertEqual(r.resolve(value, request: ticket), [.rebuild(value), .output("new")])
    }

    func testBuffersAndRebuildAreBoundedWithoutSplittingEscapeBytes() {
        var r = TerminalSnapshotRecovery(terminalID: "t", maximumBufferedBytes: 4, maximumBufferedFrames: 2)
        _ = r.beginReconnect()
        XCTAssertEqual(r.receive(.output(id: "t", data: "你好")), [.unavailable(.bufferOverflow)])
        var exits = TerminalSnapshotRecovery(terminalID: "t", maximumBufferedFrames: 1)
        _ = exits.beginReconnect()
        _ = exits.receive(.exit(id: "t", generation: "old"))
        XCTAssertEqual(exits.receive(.exit(id: "t")), [.unavailable(.bufferOverflow)])
        var huge = TerminalSnapshotRecovery(terminalID: "t")
        let ticket = huge.beginReconnect()
        XCTAssertEqual(huge.resolve(snapshot(String(repeating: "x", count: TerminalSnapshotRecovery.maximumSnapshotBytes + 1)), request: ticket), [.unavailable(.invalidSnapshot)])
        var geometry = TerminalSnapshotRecovery(terminalID: "t")
        let request = geometry.beginReconnect()
        XCTAssertEqual(geometry.resolve(TerminalSnapshot(exists: true, alive: true, data: "", cols: 65535, rows: 65535), request: request), [.unavailable(.invalidSnapshot)])
    }

    func testSameGenerationSnapshotCannotRewindItsWatermark() {
        var r = TerminalSnapshotRecovery(terminalID: "t")
        let first = r.beginReconnect()
        _ = r.resolve(snapshot(), request: first)
        let second = r.beginReconnect()
        XCTAssertEqual(r.resolve(snapshot(seq: 3), request: second), [.unavailable(.sequenceRegressed)])
    }
}

#if canImport(UIKit)
@MainActor
final class TerminalSnapshotNetworkingTests: XCTestCase {
    private func eventually(_ description: String = #function,
                            file: StaticString = #filePath, line: UInt = #line,
                            diagnostics: () -> String = { "" },
                            _ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = diagnostics()
        let message = "Terminal condition did not settle: \(description)" + (state.isEmpty ? "" : "; \(state)")
        XCTFail(message, file: file, line: line)
        throw TerminalConditionTimeout(description: "\(file):\(line): \(message)")
    }

    /// Fixture metadata only: never log tokens, request bodies, or terminal output.
    private func restartDiagnostics(session: TerminalSession, fixture: WorktreeTestFixture,
                                    sockets: TerminalRecoveryTestSockets, gate: WorktreeTestGate,
                                    snapshotReleased: Bool) -> String {
        let phase: String
        switch session.phase {
        case .idle: phase = "idle"
        case .connecting: phase = "connecting"
        case .running: phase = "running"
        case .exited: phase = "exited"
        case .failed: phase = "failed"
        }
        let recovery: String
        switch session.recoveryState {
        case .streaming: recovery = "streaming"
        case .recovering: recovery = "recovering"
        case .legacy: recovery = "legacy"
        case .exited: recovery = "exited"
        case .retired: recovery = "retired"
        case .unavailable(let reason):
            switch reason {
            case .missing: recovery = "unavailable(missing)"
            case .generationChanged: recovery = "unavailable(generationChanged)"
            case .sequenceRegressed: recovery = "unavailable(sequenceRegressed)"
            case .bufferOverflow: recovery = "unavailable(bufferOverflow)"
            case .invalidSnapshot: recovery = "unavailable(invalidSnapshot)"
            case .request: recovery = "unavailable(request)"
            }
        }
        let routes = ["get_system_terminal_settings", "terminal_spawn", "terminal_kill",
                      "terminal_snapshot", "terminal_resize", "terminal_write"]
            .map { "\($0)=\(fixture.server.count($0))" }.joined(separator: ",")
        return "phase=\(phase), recovery=\(recovery), \(sockets.diagnostics), routes=[\(routes)], "
            + "unexpectedRoutes=\(fixture.server.unexpected.count), snapshotRequested=\(gate.hasRequest), "
            + "snapshotReleased=\(snapshotReleased)"
    }

    private func reply(alive: Bool = true, exists: Bool = true, data: String = "snapshot", seq: Int = 4,
                       generation: String = "pty-a") throws -> WorktreeTestReply {
        WorktreeTestReply(data: try WorktreeTestReply.json([
            "exists": exists, "alive": alive, "data": data, "seq": seq,
            "generation": generation, "exit_code": alive ? NSNull() : 9 as Any,
            "cols": 120, "rows": 40,
        ]))
    }

    private func prepare(_ fixture: WorktreeTestFixture) throws {
        fixture.server.enqueue("get_system_terminal_settings", WorktreeTestReply(data: Data("{}".utf8)))
        fixture.server.enqueue("terminal_spawn", WorktreeTestReply(data: Data(#""fixture-pty""#.utf8)))
    }

    func testExistingSnapshotOperationUsesCapturedHostCamelBodyAndSnakeResponse() async throws {
        let a = try WorktreeTestFixture(), b = try WorktreeTestFixture()
        defer { a.close(); b.close() }
        a.server.enqueue("terminal_snapshot", try reply(alive: false))
        let value = try await a.client.terminalSnapshot(terminalId: "same-id")
        XCTAssertEqual(value.exitCode, 9)
        XCTAssertEqual(value.generation, "pty-a")
        XCTAssertEqual(value.cols, 120)
        XCTAssertEqual(value.rows, 40)
        let body = try XCTUnwrap(a.server.bodies("terminal_snapshot").first)
        XCTAssertEqual(Set(body.keys), ["terminalId"])
        XCTAssertEqual(body["terminalId"] as? String, "same-id")
        XCTAssertEqual(b.server.count("terminal_snapshot"), 0)
        XCTAssertTrue(a.server.unexpected.isEmpty)
    }

    func testOnlyUntypedRoute404IsUnsupported() async throws {
        let fixture = try WorktreeTestFixture()
        defer { fixture.close() }
        fixture.server.enqueue("terminal_snapshot", .failure(status: 404, code: nil, message: "Not Found"))
        do { _ = try await fixture.client.terminalSnapshot(terminalId: "t"); XCTFail("Expected unsupported") }
        catch { XCTAssertTrue(error is TerminalSnapshotAPIError) }
        for (status, code) in [(404, "not_found"), (401, "unauthorized"), (500, "internal_error")] {
            fixture.server.enqueue("terminal_snapshot", .failure(status: status, code: code))
            do { _ = try await fixture.client.terminalSnapshot(terminalId: "t"); XCTFail("Expected failure") }
            catch { XCTAssertFalse(error is TerminalSnapshotAPIError) }
        }
        fixture.server.enqueue("terminal_snapshot", WorktreeTestReply(data: Data("{}".utf8)))
        do { _ = try await fixture.client.terminalSnapshot(terminalId: "t"); XCTFail("Expected decoding error") }
        catch { guard case APIError.decoding = error else { return XCTFail("Unexpected \(error)") } }
    }

    func testCancelledAndRetiredHTTPRepliesCannotReturnSnapshot() async throws {
        for retirement in [false, true] {
            let fixture = try WorktreeTestFixture()
            let lifetime = ServerBindingLifetime(), gate = WorktreeTestGate()
            var held = try reply()
            held.gate = gate
            fixture.server.enqueue("terminal_snapshot", held)
            let client = fixture.client.bound(to: lifetime)
            let pending = Task { try await client.terminalSnapshot(terminalId: "t") }
            try await eventually { gate.hasRequest }
            if retirement { lifetime.invalidate() } else { pending.cancel() }
            gate.release()
            do { _ = try await pending.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            fixture.close()
        }
    }

    func testSessionWaitsForReadyBuffersOverlapAndUsesSameUUID() async throws {
        let fixture = try WorktreeTestFixture(), lifetime = ServerBindingLifetime()
        let sockets = TerminalRecoveryTestSockets()
        let session = TerminalSession(client: fixture.client.bound(to: lifetime), folder: fixture.folder,
                                      socketFactory: { sockets.make(client: $0) })
        defer { lifetime.invalidate(); session.retire(); fixture.close() }
        try prepare(fixture)
        session.start()
        try await eventually { sockets.count == 1 }
        XCTAssertEqual(fixture.server.count("terminal_spawn"), 0)
        sockets.at(0).emit(.ready)
        try await eventually { session.phase == .running }
        let id = try XCTUnwrap(fixture.server.bodies("terminal_spawn").first?["terminalId"] as? String)
        XCTAssertNotNil(UUID(uuidString: id))
        let gate = WorktreeTestGate()
        var held = try reply(data: "snapshot covered")
        held.gate = gate
        fixture.server.enqueue("terminal_snapshot", held)
        sockets.at(0).emit(.output(id: id, data: "before", seq: 1, generation: "pty-a"))
        sockets.at(0).emit(.closed(reason: "gap"))
        try await eventually { sockets.count == 2 }
        XCTAssertEqual(fixture.server.count("terminal_snapshot"), 0)
        sockets.at(1).emit(.ready)
        try await eventually { gate.hasRequest }
        sockets.at(1).emit(.output(id: id, data: "duplicate", seq: 4, generation: "pty-a"))
        sockets.at(1).emit(.output(id: id, data: " tail", seq: 5, generation: "pty-a"))
        gate.release()
        try await eventually { session.recoveryState == .streaming }
        sockets.at(1).emit(.output(id: id, data: "late duplicate", seq: 3, generation: "pty-a"))
        sockets.at(1).emit(.output(id: id, data: " done", seq: 6, generation: "pty-a"))
        try await eventually { String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self).contains("done") }
        let text = String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(text.contains("snapshot covered tail done"))
        XCTAssertFalse(text.contains("duplicate"))
        XCTAssertEqual(session.view.getTerminal().cols, 120)
        XCTAssertEqual(session.view.getTerminal().rows, 40)
        XCTAssertEqual(fixture.server.count("terminal_spawn"), 1)
        XCTAssertEqual(fixture.server.bodies("terminal_snapshot").first?["terminalId"] as? String, id)
        XCTAssertEqual(sockets.hosts, [fixture.host, fixture.host])
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testSessionOfflineExitAndMissingDoNotSpawnReplacement() async throws {
        for missing in [false, true] {
            let fixture = try WorktreeTestFixture(), lifetime = ServerBindingLifetime()
            let sockets = TerminalRecoveryTestSockets()
            let session = TerminalSession(client: fixture.client.bound(to: lifetime), folder: fixture.folder,
                                          socketFactory: { sockets.make(client: $0) })
            try prepare(fixture)
            session.start()
            try await eventually { sockets.count == 1 }
            sockets.at(0).emit(.ready)
            try await eventually { session.phase == .running }
            fixture.server.enqueue("terminal_snapshot", try reply(alive: false, exists: !missing, data: missing ? "" : "final output"))
            sockets.at(0).emit(.closed(reason: "offline exit"))
            try await eventually { sockets.count == 2 }
            sockets.at(1).emit(.ready)
            try await eventually { session.phase != .running }
            if missing {
                XCTAssertEqual(session.recoveryState, .unavailable(.missing))
                guard case .failed = session.phase else { return XCTFail("Missing must require restart") }
            } else {
                XCTAssertEqual(session.phase, .exited)
                let text = String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
                XCTAssertTrue(text.contains("final output"))
                XCTAssertTrue(text.contains("Process exited (9)"))
            }
            XCTAssertEqual(fixture.server.count("terminal_spawn"), 1)
            XCTAssertEqual(fixture.server.count("terminal_kill"), 0)
            lifetime.invalidate(); session.retire(); fixture.close()
        }
    }

    func testSessionUnsupportedRouteKeepsExplicitLegacyConnectionAndFailureStops() async throws {
        for unsupported in [false, true] {
            let fixture = try WorktreeTestFixture(), lifetime = ServerBindingLifetime()
            let sockets = TerminalRecoveryTestSockets()
            let session = TerminalSession(client: fixture.client.bound(to: lifetime), folder: fixture.folder,
                                          socketFactory: { sockets.make(client: $0) })
            try prepare(fixture)
            session.start()
            try await eventually { sockets.count == 1 }
            sockets.at(0).emit(.ready)
            try await eventually { session.phase == .running }
            fixture.server.enqueue("terminal_snapshot", .failure(status: unsupported ? 404 : 500, code: nil))
            sockets.at(0).emit(.closed(reason: "gap"))
            try await eventually { sockets.count == 2 }
            sockets.at(1).emit(.ready)
            try await eventually { session.recoveryState != .recovering }
            if unsupported {
                XCTAssertEqual(session.recoveryState, .legacy)
                XCTAssertEqual(session.phase, .running)
            } else {
                guard case .failed = session.phase else { return XCTFail("Failure must require restart") }
            }
            XCTAssertEqual(fixture.server.count("terminal_spawn"), 1)
            XCTAssertEqual(fixture.server.count("terminal_kill"), 0)
            lifetime.invalidate(); session.retire(); fixture.close()
        }
    }

    func testRetirementDuringSessionSnapshotClosesSocketAndIgnoresHTTP() async throws {
        let fixture = try WorktreeTestFixture(), lifetime = ServerBindingLifetime()
        let sockets = TerminalRecoveryTestSockets()
        let session = TerminalSession(client: fixture.client.bound(to: lifetime), folder: fixture.folder,
                                      socketFactory: { sockets.make(client: $0) })
        defer { lifetime.invalidate(); session.retire(); fixture.close() }
        try prepare(fixture)
        session.start()
        try await eventually { sockets.count == 1 }
        sockets.at(0).emit(.ready)
        try await eventually { session.phase == .running }
        let gate = WorktreeTestGate()
        var held = try reply(data: "must not restore")
        held.gate = gate
        fixture.server.enqueue("terminal_snapshot", held)
        sockets.at(0).emit(.closed(reason: "gap"))
        try await eventually { sockets.count == 2 }
        sockets.at(1).emit(.ready)
        try await eventually { gate.hasRequest }
        lifetime.invalidate()
        session.retire()
        gate.release()
        await Task.yield()
        XCTAssertEqual(session.recoveryState, .retired)
        XCTAssertEqual(session.phase, .exited)
        XCTAssertTrue(sockets.at(1).isClosed)
        XCTAssertFalse(String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self).contains("must not restore"))
        XCTAssertEqual(fixture.server.count("terminal_kill"), 0)
    }

    func testExplicitRestartUsesNewUUIDKillsOnlyOldUUIDAndCancelsRecovery() async throws {
        let fixture = try WorktreeTestFixture(), lifetime = ServerBindingLifetime()
        let sockets = TerminalRecoveryTestSockets()
        let session = TerminalSession(client: fixture.client.bound(to: lifetime), folder: fixture.folder,
                                      socketFactory: { sockets.make(client: $0) })
        let gate = WorktreeTestGate()
        var snapshotReleased = false
        let diagnostics = {
            self.restartDiagnostics(session: session, fixture: fixture, sockets: sockets,
                                    gate: gate, snapshotReleased: snapshotReleased)
        }
        defer {
            if let testRun, testRun.failureCount > 0 {
                print("Terminal restart fixture failure: \(diagnostics())")
            }
            gate.release(); lifetime.invalidate(); session.retire(); fixture.close()
        }
        try prepare(fixture)
        session.start()
        try await eventually("initial socket opens", diagnostics: diagnostics) { sockets.count == 1 }
        sockets.at(0).emit(.ready)
        try await eventually("initial PTY runs after ready", diagnostics: diagnostics) { session.phase == .running }
        let oldID = try XCTUnwrap(fixture.server.bodies("terminal_spawn").first?["terminalId"] as? String)
        var held = try reply(data: "old recovery must not appear")
        held.gate = gate
        fixture.server.enqueue("terminal_snapshot", held)
        sockets.at(0).emit(.closed(reason: "gap"))
        try await eventually("recovery socket opens", diagnostics: diagnostics) { sockets.count == 2 }
        sockets.at(1).emit(.ready)
        try await eventually("old snapshot HTTP reaches hold", diagnostics: diagnostics) { gate.hasRequest }
        try prepare(fixture)
        fixture.server.enqueue("terminal_kill", WorktreeTestReply(data: Data("null".utf8)))
        // Queue old-consumer frames on this actor immediately before restart.
        // They must not mutate the replacement when the consumer next resumes.
        sockets.at(1).emit(.output(id: oldID, data: "stale consumer", seq: 98, generation: "pty-a"))
        sockets.at(1).emit(.exit(id: oldID, generation: "pty-a"))
        session.restart()
        try await eventually("replacement sockets=3 and old PTY kills=1 while snapshot held", diagnostics: diagnostics) {
            sockets.count == 3 && fixture.server.count("terminal_kill") == 1
        }
        XCTAssertEqual(session.phase, .connecting)
        XCTAssertEqual(fixture.server.count("terminal_spawn"), 1, "Replacement must await its own ready frame")
        XCTAssertTrue(sockets.at(1).isClosed)
        sockets.at(2).emit(.ready)
        try await eventually("replacement PTY runs while old snapshot held", diagnostics: diagnostics) { session.phase == .running }
        let newID = try XCTUnwrap(fixture.server.bodies("terminal_spawn").last?["terminalId"] as? String)
        XCTAssertNotEqual(oldID, newID)
        XCTAssertNotNil(UUID(uuidString: newID))
        let close = try XCTUnwrap(fixture.server.bodies("terminal_kill").first)
        XCTAssertEqual(Set(close.keys), ["terminalId"])
        XCTAssertEqual(close["terminalId"] as? String, oldID)
        sockets.at(2).emit(.output(id: oldID, data: "wrong terminal", seq: 99, generation: "pty-a"))
        sockets.at(2).emit(.exit(id: oldID, generation: "pty-a"))
        sockets.at(2).emit(.output(id: newID, data: "fresh", seq: 1, generation: "pty-b"))
        try await eventually("replacement renders its own output", diagnostics: diagnostics) {
            String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self).contains("fresh")
        }
        snapshotReleased = true
        gate.release()
        // Let the cancelled HTTP/consumer continuations run before final checks.
        await Task.yield()
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(session.recoveryState, .streaming)
        let text = String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(text.contains("fresh"))
        XCTAssertFalse(text.contains("old recovery"))
        XCTAssertFalse(text.contains("wrong terminal"))
        XCTAssertFalse(text.contains("stale consumer"))
        XCTAssertEqual(fixture.server.count("get_system_terminal_settings"), 2)
        XCTAssertEqual(fixture.server.count("terminal_spawn"), 2)
        XCTAssertEqual(fixture.server.count("terminal_kill"), 1)
        XCTAssertEqual(fixture.server.count("terminal_snapshot"), 1)
        XCTAssertEqual(sockets.count, 3)
        XCTAssertTrue(fixture.server.unexpected.isEmpty)
    }

    func testReplayDimensionsDoNotSendTemporaryResizeOrOverwritePaneSize() async throws {
        let fixture = try WorktreeTestFixture(), lifetime = ServerBindingLifetime()
        let sockets = TerminalRecoveryTestSockets()
        let session = TerminalSession(client: fixture.client.bound(to: lifetime), folder: fixture.folder,
                                      socketFactory: { sockets.make(client: $0) })
        defer { lifetime.invalidate(); session.retire(); fixture.close() }
        try prepare(fixture)
        fixture.server.enqueue("terminal_resize", WorktreeTestReply(data: Data("null".utf8)))
        session.handleResize(cols: 80, rows: 24)
        session.start()
        try await eventually { sockets.count == 1 }
        sockets.at(0).emit(.ready)
        try await eventually { session.phase == .running && fixture.server.count("terminal_resize") == 1 }
        let gate = WorktreeTestGate()
        var held = try reply()
        held.gate = gate
        fixture.server.enqueue("terminal_snapshot", held)
        sockets.at(0).emit(.closed(reason: "gap"))
        try await eventually { sockets.count == 2 }
        sockets.at(1).emit(.ready)
        try await eventually { gate.hasRequest }
        session.handleResize(cols: 130, rows: 50)
        fixture.server.enqueue("terminal_resize", WorktreeTestReply(data: Data("null".utf8)))
        gate.release()
        try await eventually { fixture.server.count("terminal_resize") == 2 }
        XCTAssertEqual(session.view.getTerminal().cols, 130)
        XCTAssertEqual(session.view.getTerminal().rows, 50)
        let resize = try XCTUnwrap(fixture.server.bodies("terminal_resize").last)
        XCTAssertEqual(resize["cols"] as? Int, 130)
        XCTAssertEqual(resize["rows"] as? Int, 50)
        XCTAssertFalse(fixture.server.bodies("terminal_resize").contains { $0["cols"] as? Int == 120 })
    }
}

private struct TerminalConditionTimeout: Error, CustomStringConvertible {
    let description: String
}

private final class TerminalRecoveryTestSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [TerminalRecoveryTestSocket] = []
    private var capturedHosts: [String] = []
    var count: Int { lock.withLock { sockets.count } }
    var hosts: [String] { lock.withLock { capturedHosts } }
    var diagnostics: String {
        lock.withLock {
            let states = sockets.enumerated().map { "\($0.offset):\($0.element.isClosed ? "closed" : "open")" }
                .joined(separator: ",")
            return "sockets=\(sockets.count)[\(states)]"
        }
    }
    func at(_ index: Int) -> TerminalRecoveryTestSocket { lock.withLock { sockets[index] } }
    func make(client: CodegClient) -> TerminalRecoveryTestSocket {
        lock.withLock {
            let socket = TerminalRecoveryTestSocket()
            sockets.append(socket)
            capturedHosts.append(client.baseURL.host!)
            return socket
        }
    }
}

private final class TerminalRecoveryTestSocket: TerminalSocketConnection, @unchecked Sendable {
    let frames: AsyncStream<TerminalFrame>
    private let continuation: AsyncStream<TerminalFrame>.Continuation
    private let lock = NSLock()
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    init() {
        let pair = AsyncStream<TerminalFrame>.makeStream()
        frames = pair.stream; continuation = pair.continuation
    }
    func start() {}
    func emit(_ frame: TerminalFrame) { continuation.yield(frame) }
    func close() { lock.withLock { closed = true }; continuation.finish() }
}
#endif
