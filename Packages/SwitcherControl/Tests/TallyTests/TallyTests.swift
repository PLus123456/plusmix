import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherTally

/// 外部 tally 输出：TallyFrame 由快照推导（全系统只算 MixerState.tallies 这一处）、只在 tally 变化时推、WS JSON 流 + GET 轮询、心跳。
final class TallyTests: XCTestCase {

    // MARK: 帧

    func testTally_frameDerivedFromSnapshot() throws {
        var state = TestStates.base()
        state.outputs[0].enabled = true
        state.overlays[2].input = 4
        state.overlays[2].on = true
        state.overlays[2].animProgress = 1
        let clock = TickClockSpec(t0: HostClock.now(), frameRate: .fps60)
        let snap = MixerSnapshot(state: state, sequence: 7, tick: Tick(12))
        let frame = TallyFrame(snapshot: snap, clock: clock)
        XCTAssertEqual(frame.type, "tally")
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.tick, Tick(12))
        XCTAssertEqual(frame.tickTime, clock.time(of: Tick(12)))
        XCTAssertEqual(frame.publishedAt, snap.publishedAt)
        XCTAssertEqual(frame.program, 1)
        XCTAssertEqual(frame.preview, 2)
        XCTAssertFalse(frame.transitionActive)
        XCTAssertFalse(frame.ftb)
        XCTAssertEqual(frame.inputs.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(frame.inputs.map(\.name), ["机位 1", "机位 2", "机位 3", "机位 4"])
        XCTAssertEqual(frame.inputs.map(\.program), [true, false, false, true], "叠加通道上的输入也算在 PGM")
        XCTAssertEqual(frame.inputs.map(\.preview), [false, true, false, false])
        XCTAssertEqual(frame.outputs.map(\.number), [1, 2])
        XCTAssertEqual(frame.outputs.map(\.kind), [.record, .stream])
        XCTAssertEqual(frame.outputs.map(\.enabled), [true, false])
        XCTAssertTrue(frame.recording)
        XCTAssertFalse(frame.streaming)
        for input in state.inputs {
            let t = state.tallies[input.number]!
            let mine = frame.inputs.first { $0.number == input.number }!
            XCTAssertEqual(mine.program, t.program)
            XCTAssertEqual(mine.preview, t.preview)
        }
        // 只看 tally 相关字段的相等
        var later = state
        later.inputs[0].settings.audio.gainDb = -10
        let frame2 = TallyFrame(snapshot: MixerSnapshot(state: later, sequence: 8, tick: Tick(13)), clock: clock)
        XCTAssertTrue(frame.sameTally(as: frame2), "增益变化不影响 tally")
        var renamed = state
        renamed.inputs[0].name = "改名"
        XCTAssertFalse(frame.sameTally(as: TallyFrame(snapshot: MixerSnapshot(state: renamed, sequence: 9, tick: Tick(14)), clock: clock)), "名字进 tally（TSL 的文字）")
        // JSON：键名固定（外部设备靠它们）
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try TallyJSON.encoder.encode(frame)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "tally")
        XCTAssertEqual(json["program"] as? Int, 1)
        XCTAssertEqual(json["preview"] as? Int, 2)
        XCTAssertEqual(json["recording"] as? Bool, true)
        XCTAssertEqual(json["streaming"] as? Bool, false)
        XCTAssertEqual(json["ftb"] as? Bool, false)
        let inputs = try XCTUnwrap(json["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 4)
        XCTAssertEqual(inputs[3]["program"] as? Bool, true)
        XCTAssertEqual(inputs[0]["name"] as? String, "机位 1")
        XCTAssertNotNil(json["tickTime"] as? UInt64)
        XCTAssertNotNil(json["publishedAt"] as? UInt64)
        // 没时钟：tickTime 是 null 而不是缺键
        let noClock = try XCTUnwrap(JSONSerialization.jsonObject(with: try TallyJSON.encoder.encode(TallyFrame(snapshot: snap, clock: nil))) as? [String: Any])
        XCTAssertTrue(noClock["tickTime"] is NSNull)
    }

    // MARK: 发布器

    func testTally_publisherEmitsOnlyWhenTallyChanges() async throws {
        let f = try await TallyFixture.start(serve: false)
        defer { Task { await f.stop() } }
        XCTAssertEqual(f.publisher.latest?.program, 1)
        let sub = f.publisher.subscribe()
        defer { f.publisher.unsubscribe(sub.id) }
        var iterator = sub.stream.makeAsyncIterator()
        let firstNext = await iterator.next()
        let first = try XCTUnwrap(firstNext)
        XCTAssertTrue(first.contains("\"type\":\"tally\""), "订阅先补发当前帧")
        await f.stateMachine.apply(.cut)
        let afterCutNext = await iterator.next()
        let afterCut = try XCTUnwrap(afterCutNext)
        XCTAssertTrue(afterCut.contains("\"program\":2"))
        XCTAssertEqual(f.publisher.latest?.program, 2)
        let before = f.publisher.counters.frames
        await f.stateMachine.apply(.audioGain(input: 3, dB: -3))
        await f.stateMachine.apply(.renameInput(input: 3, name: "机位 3"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(f.publisher.counters.frames, before, "与 tally 无关的变化不出帧")
        await f.stateMachine.apply(.startRecord(output: 1))
        let recNext = await iterator.next()
        let rec = try XCTUnwrap(recNext)
        XCTAssertTrue(rec.contains("\"recording\":true"))
        await f.stateMachine.apply(.renameInput(input: 3, name: "新名"))
        let renamedNext = await iterator.next()
        let renamed = try XCTUnwrap(renamedNext)
        XCTAssertTrue(renamed.contains("新名"))
        // 转场：进行中 PVW 也在 PGM；完成后对调
        await f.stateMachine.schedule(.fade(durationTicks: 30), at: Tick(10))
        await f.stateMachine.prepare(upTo: Tick(20))
        let midNext = await iterator.next()
        let mid = try XCTUnwrap(midNext)
        XCTAssertTrue(mid.contains("\"transitionActive\":true"))
        XCTAssertEqual(f.publisher.latest?.inputs.filter(\.program).map(\.number), [1, 2])
        await f.stateMachine.prepare(upTo: Tick(40))
        _ = await iterator.next()
        XCTAssertEqual(f.publisher.latest?.program, 1)
        XCTAssertFalse(f.publisher.latest!.transitionActive)
        XCTAssertGreaterThanOrEqual(f.publisher.counters.frames, 5)
        XCTAssertEqual(f.publisher.counters.subscribers, 1)
    }

    // MARK: WS / HTTP

    func testTally_wsStreamHelloFrameUpdatesAndPolling() async throws {
        let f = try await TallyFixture.start(heartbeat: 1)
        defer { Task { await f.stop() } }
        let ws = WSClient(url: f.wsURL)
        defer { ws.close() }
        let hello = try await receive(ws)
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["version"] as? String, SwitcherVersion.current)
        XCTAssertNotNil(hello["timebase"] as? [String: Any])
        XCTAssertNotNil(hello["clock"] as? [String: Any])
        let first = try await receive(ws)
        XCTAssertEqual(first["type"] as? String, "tally")
        XCTAssertEqual(first["program"] as? Int, 1)
        await f.stateMachine.apply(.cut)
        let update = try await receive(ws, type: "tally")
        XCTAssertEqual(update["program"] as? Int, 2)
        XCTAssertEqual(update["preview"] as? Int, 1)
        let inputs = try XCTUnwrap(update["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs[1]["program"] as? Bool, true)
        // 心跳（1 s）
        let hb = try await receive(ws, type: "heartbeat", timeout: 3)
        XCTAssertNotNil(hb["now"] as? UInt64)
        // 轮询：GET /tally 与最近一帧一致
        let (data, resp) = try await URLSession.shared.data(from: f.httpURL)
        XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 200)
        let polled = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(polled["program"] as? Int, 2)
        XCTAssertEqual(polled["sequence"] as? Int, Int(f.publisher.latest!.sequence))
        XCTAssertEqual(f.publisher.counters.subscribers, 1)
        // 慢订阅者不拖状态机：不读 WS 猛发 1000 条
        let slow = WSClient(url: f.wsURL)
        let t0 = Date()
        for i in 0..<1000 { await f.stateMachine.apply(.setPreview(input: 1 + i % 4)) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        slow.close()
        let unsubscribed = await waitUntil { f.publisher.counters.subscribers == 1 }
        XCTAssertTrue(unsubscribed, "断开后退订")
    }
}
