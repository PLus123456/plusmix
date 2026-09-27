// W3-E3 交付第 1 条：App 的 NDI 发送接线。OutputRuntime 把 kind = ndi 且 enabled 的输出变成活的 NDISender（W2-D）：
// PGM / PVW / 多画面从 RenderedFrame 挑（PVW / 多画面帧由渲染器按状态自动填），输入 n 走该路的帧槽分支（与 ISO / Aux 同一个 InputFrameTee）；
// Stats.encoder 那一项由 sender 的 statsEntry 填；输出设置 NDI 页的名字 / 源 / 开关生效。
// 回环：本机的 NDI 输入（W3-A 的 NDIInput）收自己发出去的 PGM，放到 PVW 上读回纹理解测试图案——输入 ID 是 PGM 那一路的、帧号在走，就是收到了 PGM。
// 没有 SDK（编译时没探测到 /Library/NDI SDK for Apple）：BLOCKED-SDK。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherNDISend
import SwitcherNDI
@testable import Switcher

@MainActor
final class NDISendAppTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard NDISender.isAvailable, SwitcherNDIInfo.isSDKAvailable else {
            throw XCTSkip("BLOCKED-SDK：没有 NDI SDK（/Library/NDI SDK for Apple 或 NDI_SDK_DIR）；解锁：装 NDI SDK for Apple 后 make clean && make gen 重编")
        }
    }

    /// 每次跑用不同的名字（NDI 源名在网络上全局可见，别和上一次没散掉的源撞名）。
    private func uniqueName(_ base: String) -> String {
        "\(base) \(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970 * 10) % 100_000)"
    }

    /// 在发现列表里按 "机器名 (名字)" 找本机发送端（NDI 源名 = 机器名 + 括号里的发送端名字）。发现在后台线程做，主线程照常泵事件。
    private func discover(_ name: String, timeout: Double) -> (full: String?, seen: [String]) {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var full: String?
            var seen: [String] = []
            var done = false
        }
        let box = Box()
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let sources = (try? NDIFinder.discover(timeoutMs: 1000, showLocalSources: true)) ?? []
                let hit = sources.first { $0.name.hasSuffix(" (\(name))") }
                box.lock.withLock {
                    box.seen = sources.map(\.name)
                    box.full = hit?.name
                }
                if hit != nil { break }
            } while Date() < deadline
            box.lock.withLock { box.done = true }
        }
        AppTest.waitUntil(timeout + 3) { box.lock.withLock { box.done } }
        return box.lock.withLock { (box.full, box.seen) }
    }

    private func encoderEntry(_ session: SwitcherSession, output number: Int) -> Stats.EncoderEntry? {
        session.stats.flatMap { OutputRuntime.encoderEntry(in: $0, forOutput: number) }   // 019：按 EncoderEntry.output 对号
    }

    /// 输出设置 NDI 页加一路（源 PGM）→ NDISender 起来、挂在引擎上；Stats.encoder 那一项 = sender 的 statsEntry（publishing、帧数在涨、
    /// dropped = 队列满丢的 = skipped、码率 = UYVY 原始码率）；本机 NDI 输入收到的就是 PGM（PVW 上解出输入 1 的图案、帧号在走）；删输出 → sender 停。
    func testNDI_sendLoopbackReceivesPGM_statsEncoderFromSender() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        session.send(.setProgram(input: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { AppTest.readback(session)?.decodePattern().inputID == 0 }, "PGM 应是输入 1 的图案（ID 0）")

        // 1. 输出设置 NDI 页"添加"：enabled，源 PGM
        let page = AppTest.controller.panels.showOutputSettings(tab: .ndi).model
        let name = uniqueName("Switcher 回环")
        let number = page.addNDI(name: name, groups: "", conversion: "auto", source: .program)
        XCTAssertTrue(AppTest.waitUntil(8) { session.outputs.ndiSenders[number]?.sender.isRunning == true },
                      "NDISender 应起来：\(String(describing: session.outputs.failed[number]))")
        let entry = try XCTUnwrap(session.outputs.ndiSenders[number])
        let sender = entry.sender
        XCTAssertEqual(sender.configuration.name, name, "NDI 源名 = 输出名")
        XCTAssertEqual(sender.configuration.source, .program)
        XCTAssertEqual(sender.configuration.format, session.format)
        XCTAssertFalse(sender.countersSnapshot.unavailable)

        // 2. Stats.encoder 里这一项由 sender 的 statsEntry 填（铁律 4：状态行 / API / 测试读同一行）
        // 等到第三秒的那一行：码率按"上一行以来"的窗口算，头一行没有上一行（窗口按 1 s 记），不拿它比
        XCTAssertTrue(AppTest.waitUntil(8) { (self.encoderEntry(session, output: number)?.frames ?? 0) > 150 },
                      "Stats.encoder 应有这路 NDI 且帧数在涨：\(String(describing: session.stats?.encoder))")
        let e = try XCTUnwrap(encoderEntry(session, output: number))
        XCTAssertEqual(e.state, "publishing")
        XCTAssertEqual(e.dropped, e.skipped, "NDI 的 dropped = 队列满丢的帧（提案 001）")
        XCTAssertEqual(e.reconnects, 0)
        XCTAssertEqual(e.diskFreeMb, 0)
        XCTAssertEqual(e.output, number, "019：encoder 项带输出编号，App 按它对号（不再按顺序）")
        XCTAssertLessThanOrEqual(e.frames, sender.countersSnapshot.framesSent, "Stats 里的帧数来自 sender 的计数（采样在前）")
        let rawBitrate = Double(session.format.width * session.format.height * 2 * 8) * session.format.frameRate.framesPerSecond.doubleValue
        XCTAssertEqual(e.bitrate, rawBitrate, accuracy: rawBitrate * 0.25, "NDI 码率 = 窗口内送出的 UYVY 字节 × 8 / 秒")

        // 3. 回环：发现列表里找到它 → 加一路 NDI 输入（2 号）→ 放 PVW → PVW 上是输入 1 的图案（ID 0），帧号在走
        let found = discover(name, timeout: 12)
        let full = try XCTUnwrap(found.full, "12 s 内发现列表里应有「… (\(name))」；能看到的：\(found.seen)")
        session.send(.addInput(config: InputConfig(number: 2, name: "NDI 回环", source: .ndi(sourceName: full))))
        XCTAssertEqual(AppTest.waitLive(session, input: 2, timeout: 10), .live, "NDI 输入应收到本机发出去的流")
        session.send(.setPreview(input: 2))
        XCTAssertTrue(AppTest.waitUntil(5) {
            guard let d = AppTest.readback(session, target: .preview)?.decodePattern() else { return false }
            return d.inputID == 0 && d.frameNumber != nil
        }, "PVW（NDI 回环）应解出 PGM 那一路的图案：\(String(describing: AppTest.readback(session, target: .preview)?.decodePattern()))")
        var samples: [(pgm: UInt32, loop: UInt32)] = []
        for _ in 0..<12 {
            AppTest.pump(seconds: 0.1)
            if let p = AppTest.readback(session)?.decodePattern().frameNumber, let l = AppTest.readback(session, target: .preview)?.decodePattern().frameNumber {
                samples.append((p, l))
            }
        }
        XCTAssertGreaterThanOrEqual(samples.count, 10, "回环画面每次都应解得出帧号：\(samples)")
        let loopNumbers = samples.map(\.loop)
        XCTAssertTrue(zip(loopNumbers, loopNumbers.dropFirst()).allSatisfy { $1 >= $0 }, "回环帧号不倒退：\(loopNumbers)")
        XCTAssertGreaterThan(Int(loopNumbers.last ?? 0) - Int(loopNumbers.first ?? 0), 30, "约 1.1 s 里回环帧号应走 60 左右：\(loopNumbers)")
        let lags = samples.map { Int($0.pgm) - Int($0.loop) }
        print("NDI 发送（App）回环：\(name) → \(full)；PGM − 回环 帧号差 \(lags)（中位 \(lags.sorted()[lags.count / 2]) 帧，信息项）；"
              + "Stats.encoder：frames \(e.frames) skipped \(e.skipped) bitrate \(String(format: "%.0f", e.bitrate / 1e6)) Mb/s；"
              + "sender：发 \(sender.countersSnapshot.framesSent) 帧，转换 \(sender.countersSnapshot.conversion)\(sender.countersSnapshot.usingGPU ? "(GPU)" : "(CPU)")，接收方 \(sender.countersSnapshot.connections)")
        XCTAssertTrue(lags.allSatisfy { (0...30).contains($0) }, "回环画面落后 PGM 0–30 帧（合理区间，不是阈值）：\(lags)")
        // 019（W3-E4）：接收方数进 Stats（本机回环输入 = 1 个接收方），NDI 页的状态行读同一行显示它
        XCTAssertTrue(AppTest.waitUntil(5) { (self.encoderEntry(session, output: number)?.connections ?? 0) >= 1 },
                      "Stats.encoder 应报接收方数：\(String(describing: self.encoderEntry(session, output: number)))")
        XCTAssertTrue(AppTest.waitUntil(3) { page.ndiStatus(output: number) == OutputStatusText.ndi(enabled: true, entry: self.encoderEntry(session, output: number)) },
                      "NDI 页状态行 = 同一行 Stats：\(page.ndiStatus(output: number))")
        XCTAssertTrue(page.ndiStatus(output: number).contains(L("ndi.status.connections", Int(self.encoderEntry(session, output: number)?.connections ?? 0))), page.ndiStatus(output: number))
        print("NDI 发送（App）019：output \(String(describing: self.encoderEntry(session, output: number)?.output))，接收方 \(String(describing: self.encoderEntry(session, output: number)?.connections))，状态行「\(page.ndiStatus(output: number))」")

        // 4. 删输出 → sender 停、运行表里没有它；删回环输入
        session.send(.removeInput(input: 2))
        page.removeOutput(number)
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.ndiSenders[number] == nil && !sender.isRunning }, "删输出应停掉 NDISender")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        AppTest.controller.panels.closeAll()
    }

    /// NDI 页的名字 / 源 / 开关生效：改名（renameOutput）= 换一个用新名字的 sender；改源（PVW / 输入 n）= 换 sender，
    /// PVW 帧由渲染器按状态自动填、输入 n 走该路的帧槽分支；转换方式运行时改、不重建；开关（setOutputEnabled）起停，关着 Stats 里是 idle。
    func testNDI_settingsPageNameSourceEnabledTakeEffect() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 2)
        session.send(.setProgram(input: 1))
        session.send(.setPreview(input: 2))
        let since = session.control.bus.recentEntries().last?.sequence ?? 0
        let page = AppTest.controller.panels.showOutputSettings(tab: .ndi).model
        let first = uniqueName("Switcher 设置 A")
        let number = page.addNDI(name: first, groups: "", conversion: "auto", source: .program)
        XCTAssertTrue(AppTest.waitUntil(8) { session.outputs.ndiSenders[number]?.sender.isRunning == true })
        let s1 = try XCTUnwrap(session.outputs.ndiSenders[number]?.sender)

        // 名字：输出名就是 NDI 源名，改名 = 用新名字重建 sender（NDI 源名建好后改不了）
        let second = uniqueName("Switcher 设置 B")
        page.rename(number, second)
        XCTAssertTrue(AppTest.waitUntil(8) {
            guard let s = session.outputs.ndiSenders[number]?.sender else { return false }
            return s !== s1 && s.isRunning && s.configuration.name == second
        }, "改名后应换成新名字的 sender：\(String(describing: session.outputs.ndiSenders[number]?.sender.configuration.name))")
        XCTAssertFalse(s1.isRunning, "旧 sender 停掉")

        // 源 = PVW：渲染器按状态自动填 RenderedFrame.preview（开头可能缺一两帧），sender 在送
        page.setNDI(number, source: .preview)
        XCTAssertTrue(AppTest.waitUntil(8) {
            guard let s = session.outputs.ndiSenders[number]?.sender else { return false }
            return s.configuration.source == .preview && s.isRunning && s.countersSnapshot.framesSent > 30
        }, "源换成 PVW 后应在送：\(String(describing: session.outputs.ndiSenders[number]?.sender.countersSnapshot))")

        // 源 = 输入 2（Aux，原始画面）：该路帧槽开一个分支，ISO 同款的 tap 每拍挑帧交给 sender
        page.setNDI(number, source: .input(number: 2))
        XCTAssertTrue(AppTest.waitUntil(8) {
            guard let e = session.outputs.ndiSenders[number] else { return false }
            return e.sender.configuration.source == .input(number: 2) && e.sender.isRunning && (e.inputTap?.counters.forwarded ?? 0) > 30
                && e.sender.countersSnapshot.framesSent > 30
        }, "源换成输入 2 后应从该路的分支送帧")
        XCTAssertEqual(session.outputs.ndiSenders[number]?.inputTap?.inputNumber, 2)
        XCTAssertEqual(session.inputs.entries[2]?.tee.branchCount, 1, "输入 2 开了一个分支")

        // 输入 2 换来源（setInputSource：InputRuntime 重建那一路、换一个新 tee）→ 分支跟到新 tee 上，sender 不重建、接着送
        let senderBefore = try XCTUnwrap(session.outputs.ndiSenders[number]?.sender)
        let tapBefore = try XCTUnwrap(session.outputs.ndiSenders[number]?.inputTap)
        let oldTee = try XCTUnwrap(session.inputs.entries[2]?.tee)
        session.send(.setInputSource(input: 2, source: AppTest.syntheticConfig(number: 2, gray: 200).source))
        XCTAssertTrue(AppTest.waitUntil(5) { session.inputs.entries[2]?.tee !== oldTee && session.inputs.runtimeState(of: 2) == .live }, "输入 2 应按新来源重建")
        XCTAssertTrue(AppTest.waitUntil(5) {
            guard let e = session.outputs.ndiSenders[number], let tap = e.inputTap else { return false }
            return tap !== tapBefore && tap.counters.forwarded > 30
        }, "分支应换到新 tee 上接着送：\(String(describing: session.outputs.ndiSenders[number]?.inputTap?.counters))")
        XCTAssertTrue(session.outputs.ndiSenders[number]?.sender === senderBefore, "换的是分支，不是 sender")
        XCTAssertEqual(session.inputs.entries[2]?.tee.branchCount, 1, "新 tee 上一个分支")

        // 转换方式：运行时改，同一个 sender
        let s4 = try XCTUnwrap(session.outputs.ndiSenders[number]?.sender)
        page.setNDI(number, conversion: "cpu")
        XCTAssertTrue(AppTest.waitUntil(3) { s4.conversion == .cpu }, "转换方式应运行时生效")
        XCTAssertTrue(session.outputs.ndiSenders[number]?.sender === s4, "改转换方式不重建 sender")

        // 开关：关 = 停（分支还回去），Stats 里 idle；再开 = 起一个新的
        page.setOutputEnabled(number, on: false)
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.ndiSenders[number] == nil && !s4.isRunning }, "关掉应停 sender")
        XCTAssertTrue(AppTest.waitUntil(3) { session.inputs.entries[2]?.tee.branchCount == 0 }, "输入 2 的分支应还回去")
        XCTAssertTrue(AppTest.waitUntil(4) { self.encoderEntry(session, output: number)?.state == "idle" },
                      "关着的 NDI 输出在 Stats 里是 idle：\(String(describing: self.encoderEntry(session, output: number)))")
        page.setOutputEnabled(number, on: true)
        XCTAssertTrue(AppTest.waitUntil(8) { session.outputs.ndiSenders[number]?.sender.isRunning == true && session.outputs.ndiSenders[number]?.sender !== s4 })
        XCTAssertEqual(session.outputs.ndiSenders[number]?.sender.conversion, .cpu, "新 sender 按设置里的转换方式起")

        // 全程走的是 renameOutput / setOutputSettings / setOutputEnabled（提案 012），没有删了重加
        let commands = session.control.bus.recentEntries().filter { $0.sequence > since }.map(\.command)
        XCTAssertTrue(commands.contains(.renameOutput(output: number, name: second)), "\(commands)")
        XCTAssertTrue(commands.contains(.setOutputEnabled(output: number, on: false)))
        XCTAssertFalse(commands.contains { if case .removeOutput = $0 { return true } else { return false } })
        XCTAssertEqual(commands.filter { if case .addOutput = $0 { return true } else { return false } }.count, 1)
        page.removeOutput(number)
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.ndiSenders[number] == nil })
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
        AppTest.controller.panels.closeAll()
    }
}
