import Foundation
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherInputsHarness
@testable import SwitcherDeckLink

/// 真硬件 / 无硬件的行为。没有 DeckLink 卡：L1、L2、S5 标 BLOCKED-硬件（有卡时这些用例真跑）。
final class DeckLinkHardwareTests: XCTestCase {
    private var device: DeckLinkDeviceInfo? { DeckLinkDevices.list().first { $0.hasInput } }

    /// 没有 SDK / 驱动 / 卡时都不崩：枚举空、输入进 noSignal 并给清楚文案。
    func testDeckLink_noHardware_enumerationEmpty_inputNoSignalWithClearMessage() throws {
        let devices = DeckLinkDevices.list()
        print("DeckLink：SDK \(SwitcherDeckLinkInfo.isSDKAvailable ? SwitcherDeckLinkInfo.sdkVersion : "无")，驱动 \(SwitcherDeckLinkInfo.isDriverPresent ? SwitcherDeckLinkInfo.driverVersion : "无")，设备 \(devices)")
        if !devices.isEmpty { throw XCTSkip("本机有 DeckLink 设备，无硬件行为不适用") }
        XCTAssertEqual(devices.count, 0)
        XCTAssertNil(DeckLinkDevices.device(persistentID: ""))
        let timing = ProgramTiming(format: .hd1080p60, t0: HostClock.now())
        let config = InputConfig(number: 3, name: "DeckLink", source: .decklink(deviceID: "peid:12345"))
        let input = try DeckLinkInput(config: config, timing: timing, videoSlot: LockFreeFrameSlot(capacity: 3))
        if SwitcherDeckLinkInfo.isSDKAvailable {
            try input.start()
            XCTAssertTrue(waitUntil(timeoutMs: 2000) { input.lastError != nil })
            XCTAssertEqual(input.state, .noSignal, "没有设备是 noSignal（等它来），不是 error")
            let msg = input.lastError ?? ""
            print("文案：\(msg)")
            if SwitcherDeckLinkInfo.isDriverPresent {
                XCTAssertTrue(msg.contains("找不到 DeckLink 设备"), msg)
            } else {
                XCTAssertEqual(msg, SwitcherDeckLinkInfo.driverMissingMessage)
                XCTAssertTrue(msg.contains("Desktop Video"), "文案要指到该装什么")
            }
            Thread.sleep(forTimeInterval: 1.2)   // 轮询一轮也不崩
            XCTAssertEqual(input.state, .noSignal)
            XCTAssertEqual(input.deckLinkCounters.rebuilds, 0)
        } else {
            XCTAssertThrowsError(try input.start()) { XCTAssertEqual($0 as? DeckLinkInputError, .sdkUnavailable) }
            XCTAssertEqual(input.state, .error(message: SwitcherDeckLinkInfo.unavailableMessage))
        }
        input.stop()
        XCTAssertEqual(input.state, .noSignal)
    }

    func testDeckLink_sourceKindMismatch_throws() throws {
        let timing = ProgramTiming(format: .hd1080p60, t0: HostClock.now())
        let config = InputConfig(number: 2, name: "x", source: .ndi(sourceName: "x"))
        XCTAssertThrowsError(try DeckLinkInput(config: config, timing: timing, videoSlot: LockFreeFrameSlot(capacity: 3))) {
            XCTAssertEqual($0 as? DeckLinkInputError, .notADeckLinkSource(.ndi))
        }
    }

    func testDeckLink_connectionNames() {
        let c: SwitcherDeckLink.DeckLinkConnection = [.sdi, .hdmi]   // 契约里有同名的"单个口"枚举（提案 008），这里是位集
        XCTAssertEqual(c.names, ["SDI", "HDMI"])
        XCTAssertEqual(SwitcherDeckLink.DeckLinkConnection(rawValue: 0).names, [])
    }

    /// L1：真卡 + 真引擎（SDI 信号源接上，任意格式）。
    func testL1_deckLinkInput_within3Frames() async throws {
        guard let dev = device else {
            throw XCTSkip("BLOCKED-硬件：没有 DeckLink 输入设备（需要 Mini Recorder / UltraStudio + Desktop Video + 信号源）。解锁后：swift test --filter DeckLinkHardwareTests")
        }
        let format = ProgramFormat.hd1080p60
        let config = InputConfig(number: 1, name: dev.displayName, source: .decklink(deviceID: dev.persistentID))
        let harness = try InputEngineHarness(format: format, configs: [config], leadMs: 1500)
        let slot = harness.makeSlot(forInput: 1)
        let input = try DeckLinkInput(config: config, timing: harness.timing, videoSlot: slot)
        harness.add(input)
        let ticks: Int64 = 8 * 60
        try await harness.start(lastTick: Tick(ticks - 1))
        let deadline = HostClock.now() + HostDuration(seconds: 8 + 4)
        while HostClock.now() < deadline, let c = harness.engine.clock, c.ticksDispatched + c.ticksSkipped < UInt64(ticks) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let stats = harness.engine.makeStats()
        await harness.stop()
        let l1 = try XCTUnwrap(harness.latency(ofInput: 1))
        let c = input.deckLinkCounters
        let f = l1.frames(at: format.frameRate)
        print(String(format: "DeckLink %@ L1：%d 样本，平均 %.2f ms（%.2f 帧），p99 %.2f（%.2f 帧），max %.2f；格式 %@；校准偏移 %lld ns 残差最大 %lld ns RMS %.0f ns；d 均值 %.2f ms；状态 %@",
                     dev.displayName, l1.samples, l1.meanMs, f.mean, l1.p99Ms, f.p99, l1.maxMs, c.currentFormat, c.calibrationOffsetNs, c.residualMaxAbsNs, c.residualRmsNs,
                     c.arrivalMinusPtsMeanMs, "\(input.state)"))
        XCTAssertGreaterThan(l1.samples, 100, "要有信号源：\(input.lastError ?? "-")")
        XCTAssertLessThanOrEqual(f.mean, 3)
        XCTAssertLessThanOrEqual(f.p99, 3)
        XCTAssertEqual(stats.missedRender, 0)
    }

    /// L2 端到端（SDI ≤ 100 ms 含设备）：要外部显示 / 回环采集，人工秒表法或回环法，测试标准 §3。
    func testL2_deckLink_endToEnd_manual() throws {
        throw XCTSkip("BLOCKED-硬件：L2 需要 DeckLink 卡 + 信号源 + 外部显示 / HDMI 回环采集（测试标准 §3 L2 测法），有硬件时按 §3 人工跑并把数字写进报告")
    }

    /// S5 热插拔 20 次：崩溃 0、恢复 ≤ 3 s、编号与设置保持。
    func testS5_deckLink_hotplug20Cycles() throws {
        guard device != nil else {
            throw XCTSkip("BLOCKED-硬件：没有 DeckLink 设备。解锁后：SWITCHER_DECKLINK_HOTPLUG_CYCLES=20 swift test --filter testS5_deckLink_hotplug20Cycles，按提示拔插 Thunderbolt / USB 线，每次记恢复时间")
        }
        guard let cycles = ProcessInfo.processInfo.environment["SWITCHER_DECKLINK_HOTPLUG_CYCLES"].flatMap(Int.init), cycles > 0 else {
            throw XCTSkip("设 SWITCHER_DECKLINK_HOTPLUG_CYCLES=20 才跑（要有人拔插）")
        }
        let dev = device!
        let timing = ProgramTiming(format: .hd1080p60, t0: HostClock.now())
        let config = InputConfig(number: 7, name: dev.displayName, source: .decklink(deviceID: dev.persistentID))
        let input = try DeckLinkInput(config: config, timing: timing, videoSlot: LockFreeFrameSlot(capacity: 3))
        try input.start()
        XCTAssertTrue(waitUntil(timeoutMs: 10_000) { input.state == .live }, "先接上信号：\(input.lastError ?? "-")")
        var recoveries: [Double] = []
        for i in 1...cycles {
            print("[\(i)/\(cycles)] 请拔掉 \(dev.displayName) …")
            XCTAssertTrue(waitUntil(timeoutMs: 60_000, pollMs: 20) { input.state == .noSignal }, "拔掉后应 noSignal")
            print("[\(i)/\(cycles)] 已断开（\(input.lastError ?? "")）。请插回 …")
            let removedAt = input.deckLinkCounters.deviceRemovals
            _ = removedAt
            let t0 = HostClock.now()
            XCTAssertTrue(waitUntil(timeoutMs: 60_000, pollMs: 20) { input.deckLinkCounters.deviceArrivals >= UInt64(i) }, "应收到连接通知")
            let arrivedAt = HostClock.now()
            XCTAssertTrue(waitUntil(timeoutMs: 10_000, pollMs: 20) { input.state == .live }, "插回后应回 live")
            let ms = (HostClock.now() - arrivedAt).milliseconds
            recoveries.append(ms)
            print("[\(i)/\(cycles)] 恢复 \(String(format: "%.0f", ms)) ms（连接通知 → live；拔着 \(String(format: "%.1f", (arrivedAt - t0).seconds)) s）")
        }
        XCTAssertEqual(input.number, 7, "编号不变")
        XCTAssertLessThanOrEqual(recoveries.max() ?? 0, 3000, "恢复 ≤ 3 s：\(recoveries)")
        print("S5：\(cycles) 次，恢复最大 \(String(format: "%.0f", recoveries.max() ?? 0)) ms，平均 \(String(format: "%.0f", recoveries.reduce(0, +) / Double(max(recoveries.count, 1)))) ms，会话重建 \(input.deckLinkCounters.rebuilds)")
        input.stop()
    }
}
