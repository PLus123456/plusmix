import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
@testable import SwitcherControl

/// 命令总线：统一入口、sequence 连续、issuedAt、回执带生效拍、结构性校验、C4 的进程内形态。
final class CommandBusTests: XCTestCase {
    // MARK: 基本行为

    func testBus_assignsContiguousSequencesAndIssuedAt() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let before = HostClock.now()
        let r1 = try await f.bus.submit(.setPreview(input: 3), source: .api)
        let r2 = try await f.bus.submit(.cut, source: .hotkey)
        let r3 = try await f.bus.submit(.setPreview(input: 4), source: .midi)
        let after = HostClock.now()
        XCTAssertEqual([r1.sequence, r2.sequence, r3.sequence], [1, 2, 3])
        XCTAssertEqual(f.bus.lastSequence, 3)
        let log = f.bus.recentEntries()
        XCTAssertEqual(log.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(log.map(\.source), [.api, .hotkey, .midi])
        for e in log {
            XCTAssertGreaterThanOrEqual(e.issuedAt, before)
            XCTAssertLessThanOrEqual(e.issuedAt, after)
            XCTAssertGreaterThanOrEqual(e.appliedAt, e.issuedAt)
        }
        let state = await f.stateMachine.state
        XCTAssertEqual(state.program, 3)
        XCTAssertEqual(state.preview, 4)
        // 快照的 sequence 跟到最后一条
        XCTAssertEqual(f.stateMachine.publisher.latest?.sequence, 3)
    }

    func testBus_receiptTickIsTheTickThePictureChangesOn() async throws {
        // 渲染线程已经消费到第 100 拍 → 命令只能落在 101
        let f = BusFixture()
        defer { f.stop() }
        await f.stateMachine.prepare(upTo: Tick(100))
        f.stateMachine.noteRendered(Tick(100))
        let r = try await f.bus.submit(.cut, source: .ui)
        XCTAssertEqual(r.appliedTick, Tick(101))
        let snap = f.stateMachine.publisher.latest!
        XCTAssertEqual(snap.tick, Tick(101))
        XCTAssertEqual(snap.state.program, 2)
    }

    // MARK: 结构性校验（非法命令 400 的依据）

    func testBus_rejectsStructurallyInvalidCommandsWithReason() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let cases: [(Command, String)] = [
            (.setPreview(input: 9), "输入"),
            (.setProgram(input: -1), "输入"),
            (.overlay(channel: 5, on: true, input: nil), "通道"),
            (.overlay(channel: 1, on: true, input: 42), "输入"),
            (.setOverlay(channel: 0, rect: .full, animation: OverlayAnimation()), "通道"),
            (.audioGain(input: 7, dB: 0), "输入"),
            (.mute(input: 7, on: true), "输入"),
            (.startRecord(output: 2), "录制"),      // 2 号是推流
            (.stopStream(output: 1), "推流"),       // 1 号是录制
            (.startRecord(output: 9), "输出"),
            (.setInputSettings(input: 8, settings: InputSettings()), "输入"),
            (.renameInput(input: 8, name: "x"), "输入"),
            (.addInput(config: InputConfig(number: 1, name: "重复", source: .synthetic(settings: SyntheticSourceSettings()))), "已存在"),
            (.addInput(config: InputConfig(number: 0, name: "零", source: .synthetic(settings: SyntheticSourceSettings()))), "编号"),
            (.removeInput(input: 99), "输入"),
            (.addOutput(config: OutputState(number: 1, kind: .ndi, name: "重复")), "已存在"),
            (.removeOutput(output: 99), "输出"),
            (.setOutputSettings(output: 99, settings: OutputSettings()), "输出"),
            (.fade(durationTicks: -1), "时长"),
            (.setTransition(type: .wipe, durationTicks: -5), "时长"),
        ]
        for (command, keyword) in cases {
            do {
                _ = try await f.bus.submit(command, source: .api)
                XCTFail("应被拒绝：\(command)")
            } catch let e as CommandRejection {
                XCTAssertTrue(e.reason.contains(keyword), "\(command) 的理由「\(e.reason)」应含「\(keyword)」")
                XCTAssertEqual(e.command, command)
            }
        }
        XCTAssertEqual(f.bus.lastSequence, 0, "被拒的命令不占 sequence")
        XCTAssertEqual(f.bus.counters.rejected, UInt64(cases.count))
        let state = await f.stateMachine.state
        XCTAssertEqual(state, TestStates.base(), "状态未变")
    }

    /// 校验器和 reducer 一致：校验器放行的命令，reducer 不会因为"引用不存在"而原样返回；校验器拒绝的，reducer 一定原样返回。
    func testValidator_agreesWithReducer() {
        let state = TestStates.base()
        let reducer = MixerReducer()
        let legal: [Command] = [
            .cut, .fade(durationTicks: 30), .setTransition(type: .wipe, durationTicks: 10), .autoTransition,
            .setPreview(input: 3), .setProgram(input: 0), .tbar(progress: 0.5), .ftb(on: true),
            .overlay(channel: 4, on: true, input: 2), .setOverlay(channel: 1, rect: .bottomRightQuarter, animation: OverlayAnimation(kind: .fade, durationTicks: 10)),
            .audioGain(input: 1, dB: -6), .mute(input: 2, on: true), .busGain(bus: .master, dB: -3), .busMute(bus: .busA, on: true), .setAFV(on: true),
            .startRecord(output: 1), .stopRecord(output: 1), .startStream(output: 2), .stopStream(output: 2),
            .setInputSettings(input: 1, settings: InputSettings()), .renameInput(input: 1, name: "新名"),
            .addInput(config: InputConfig(number: 5, name: "五", source: .synthetic(settings: SyntheticSourceSettings()))), .removeInput(input: 4),
            .addOutput(config: OutputState(number: 3, kind: .ndi, name: "NDI")), .removeOutput(output: 2), .setOutputSettings(output: 1, settings: OutputSettings()),
            .loadShow(show: Show(name: "s", state: state)),
        ]
        for c in legal {
            XCTAssertNil(CommandValidator.reason(rejecting: c, in: state), "\(c) 应放行")
        }
        let illegal: [Command] = [
            .setPreview(input: 9), .overlay(channel: 5, on: true, input: nil), .audioGain(input: 7, dB: 0), .startRecord(output: 2),
            .removeInput(input: 99), .removeOutput(output: 99), .fade(durationTicks: -1),
        ]
        for c in illegal {
            XCTAssertNotNil(CommandValidator.reason(rejecting: c, in: state), "\(c) 应拒绝")
            XCTAssertEqual(reducer.reduce(state, c, at: .zero), state, "reducer 对 \(c) 也应原样返回")
        }
    }

    // MARK: C4（进程内形态）：每秒 100 条带序号命令，两个并发"客户端"

    func testC4_hundredCommandsPerSecond_twoConcurrentClients_noLossNoReorder() async throws {
        let f = BusFixture()
        defer { f.stop() }
        let perClient = 300   // 每客户端 3 s × 100/s；正式 60 s 的版本在 scripts/apitest 里跑
        let interval: Duration = .milliseconds(10)
        actor Log { var receipts: [CommandReceipt] = []; func add(_ r: CommandReceipt) { receipts.append(r) } }
        let logs = [Log(), Log()]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in 0..<2 {
                group.addTask {
                    var next = ContinuousClock.now
                    for k in 1...perClient {
                        let r = try await f.bus.submit(.renameInput(input: client + 1, name: "c\(client)-\(k)"), source: .api)
                        await logs[client].add(r)
                        next += interval
                        try await Task.sleep(until: next)
                    }
                }
            }
            try await group.waitForAll()
        }
        // 每个客户端自己的回执 sequence 严格递增（无乱序）
        for client in 0..<2 {
            let seqs = await logs[client].receipts.map(\.sequence)
            XCTAssertEqual(seqs.count, perClient)
            XCTAssertEqual(seqs, seqs.sorted(), "客户端 \(client) 乱序")
            XCTAssertEqual(Set(seqs).count, perClient)
        }
        // 两个客户端合起来：1…600 连续无丢失
        let all = await (logs[0].receipts + logs[1].receipts).map(\.sequence).sorted()
        XCTAssertEqual(all, Array(1...UInt64(2 * perClient)))
        XCTAssertEqual(f.bus.lastSequence, UInt64(2 * perClient))
        // 状态机按序应用：最终名字是各自的最后一条；快照 sequence = 最后一条
        let state = await f.stateMachine.state
        XCTAssertEqual(state.input(1)?.name, "c0-\(perClient)")
        XCTAssertEqual(state.input(2)?.name, "c1-\(perClient)")
        XCTAssertEqual(f.stateMachine.publisher.latest?.sequence, UInt64(2 * perClient))
        let applied = await f.stateMachine.appliedSequences
        XCTAssertEqual(applied, Array(1...UInt64(2 * perClient)), "状态机应用顺序 = sequence 顺序")
        let pending = await f.stateMachine.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// 观察者在每条命令应用后被调用（状态推送靠它）。
    func testBus_observerSeesEveryAppliedEntryInOrder() async throws {
        let f = BusFixture()
        defer { f.stop() }
        final class Recorder: CommandBusObserver, @unchecked Sendable {
            let lock = NSLock(); var seen: [UInt64] = []
            func commandBus(_ bus: CommandBus, didApply entry: CommandLogEntry) { lock.lock(); seen.append(entry.sequence); lock.unlock() }
        }
        let rec = Recorder()
        f.bus.addObserver(rec)
        for _ in 0..<5 { _ = try await f.bus.submit(.cut, source: .ui) }
        XCTAssertEqual(rec.seen, [1, 2, 3, 4, 5])
    }
}
