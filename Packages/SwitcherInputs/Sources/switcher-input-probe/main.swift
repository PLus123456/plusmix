// switcher-input-probe：W2-A 的命令行探针（组装方）。
//
//   switcher-input-probe                      版本（make test 的冒烟）
//   switcher-input-probe devices              摄像头 / 屏幕目标清单 + 权限状态
//   switcher-input-probe clocks --camera 0 [--seconds 5]      摄像头时间戳时钟探针（synchronizationClock 是否 host clock、d 分布）
//   switcher-input-probe clocks --screen 0 [--seconds 5]      屏幕时间戳探针
//   switcher-input-probe run --input camera:0 [--input file:/x.mov] --seconds 10 [--format 1080p60] [--audio]
//                                             真引擎 + 真渲染器跑，量每路 L1（ingressTime → 编码器入口）
//   switcher-input-probe hotplug --camera <uniqueID> [--cycles 20] [--timeout 120]   S5：用户手动拔插，这里计时
//   switcher-input-probe permission --camera 0 | --screen 0 [--seconds 60]           S6：打印状态变化，看授权后是否自动恢复
//   switcher-input-probe audio-device [--uid <deviceUID> --seconds N] [--channels 4,5] [--no-force-48k] [--no-convert]
//                                             纯音频设备输入（W2-A2）：列设备 / 跑 N 秒报块数、断裂、hostTime 单调性、块间隔分布
//
// 摄像头 / 屏幕需要 TCC 权限：从 Claude / 脚本直接跑没有提示会被拒；用 Scripts/probe-app.sh 包成 .app 跑（它的 Info.plist 带用途说明）。
import AVFoundation
import Foundation
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs
import SwitcherInputsHarness

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("switcher-input-probe \(SwitcherVersion.current)")
    exit(0)
}

/// 极简参数表。
struct Options {
    var values: [String: [String]] = [:]
    init(_ a: ArraySlice<String>) {
        var i = a.startIndex
        while i < a.endIndex {
            let k = a[i]
            if k.hasPrefix("--") {
                let key = String(k.dropFirst(2))
                if i + 1 < a.endIndex, !a[i + 1].hasPrefix("--") {
                    values[key, default: []].append(a[i + 1]); i += 2
                } else {
                    values[key, default: []].append(""); i += 1
                }
            } else { i += 1 }
        }
    }
    func string(_ k: String) -> String? { values[k]?.last }
    func all(_ k: String) -> [String] { values[k] ?? [] }
    func double(_ k: String, _ d: Double) -> Double { values[k]?.last.flatMap(Double.init) ?? d }
    func int(_ k: String, _ d: Int) -> Int { values[k]?.last.flatMap(Int.init) ?? d }
    func has(_ k: String) -> Bool { values[k] != nil }
}
let opts = Options(args.dropFirst())

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data((m + "\n").utf8))
    exit(1)
}

func parseFormat(_ s: String?) -> ProgramFormat {
    switch (s ?? "1080p60").lowercased() {
    case "1080p60": .hd1080p60
    case "1080p5994", "1080p59.94": .hd1080p5994
    case "1080p30": .hd1080p30
    case "720p60": .hd720p60
    case "2160p30": .uhd2160p30
    default: fail("--format 只认 1080p60 / 1080p5994 / 1080p30 / 720p60 / 2160p30")
    }
}

/// `camera:0`、`screen:0`、`screen:display:1`、`screen:window:123`、`screen:app:com.apple.Safari`、`file:/x.mov[:loop|hold|black[:rate]]`、`image:/x.png`
func parseInput(_ spec: String, number: Int) -> InputConfig {
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { fail("--input 格式：camera:<id|index> | screen:<display id|window:<id>|app:<bundle>> | file:<path> | image:<path>（收到 \(spec)）") }
    switch parts[0] {
    case "camera":
        let id = CameraDevices.device(uniqueID: parts[1])?.uniqueID ?? parts[1]
        return InputConfig(number: number, name: "camera \(parts[1])", source: .camera(uniqueID: id))
    case "screen":
        let rest = parts[1]
        let target: ScreenTarget
        if rest.hasPrefix("window:") { target = .window(id: UInt32(rest.dropFirst(7)) ?? 0) }
        else if rest.hasPrefix("app:") { target = .application(bundleID: String(rest.dropFirst(4))) }
        else if rest.hasPrefix("display:") { target = .display(id: UInt32(rest.dropFirst(8)) ?? 0) }
        else { target = .display(id: UInt32(rest) ?? 0) }
        return InputConfig(number: number, name: "screen \(rest)", source: .screen(target: target, frameRate: nil, captureAudio: opts.has("audio")))
    case "file":
        // 路径里可能有冒号，从右边找结束动作 / 速率
        var path = parts[1]
        var end = FileEndAction.loop
        var rate = 1.0
        let tail = path.split(separator: ":").map(String.init)
        if tail.count >= 2, let r = Double(tail.last!) , ["loop", "hold", "black"].contains(tail[tail.count - 2]) {
            rate = r; path = tail.dropLast(2).joined(separator: ":")
            end = tail[tail.count - 2] == "hold" ? .holdLastFrame : tail[tail.count - 2] == "black" ? .black : .loop
        } else if tail.count >= 2, ["loop", "hold", "black"].contains(tail.last!) {
            end = tail.last == "hold" ? .holdLastFrame : tail.last == "black" ? .black : .loop
            path = tail.dropLast().joined(separator: ":")
        }
        return InputConfig(number: number, name: "file \(URL(fileURLWithPath: path).lastPathComponent)", source: .file(path: path, endAction: end, rate: rate))
    case "image":
        return InputConfig(number: number, name: "image \(URL(fileURLWithPath: parts[1]).lastPathComponent)", source: .image(path: parts[1]))
    default:
        fail("不认识的输入类型 \(parts[0])")
    }
}

func makeInput(_ config: InputConfig, timing: ProgramTiming, slot: any FrameSlot, ring: (any AudioRing)?) throws -> any Input {
    switch config.source {
    case .camera: try CameraInput(config: config, timing: timing, videoSlot: slot, audioRing: ring)
    case .screen: try ScreenInput(config: config, timing: timing, videoSlot: slot, audioRing: ring)
    case .file: try FileInput(config: config, timing: timing, videoSlot: slot, audioRing: ring)
    case .image: try ImageInput(config: config, timing: timing, videoSlot: slot)
    default: fail("探针只接 camera / screen / file / image")
    }
}

func fmt(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }
func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
}
func describe(_ input: any Input) -> String {
    var s = "输入 \(input.number)「\(input.name)」state=\(input.state)"
    if let c = input as? CameraInput {
        s += " 设备=\(c.deviceName ?? "?")"
        if let n = c.negotiated { s += " 协商=\(n.candidate.width)×\(n.candidate.height)@\(fmt(n.frameRate, 3)) \(CameraDevices.fourCC(n.candidate.mediaSubType)) 匹配节目帧率=\(n.matchesProgramFrameRate)" }
        let t = c.timestampStats
        s += "\n    时间戳：syncClock==host=\(t.syncClockIsHostClock.map { "\($0)" } ?? "未知") d(ingress−pts) 平均 \(fmt(t.meanDelayMs)) / max \(fmt(t.maxDelayMs)) / min \(fmt(t.minDelayMs)) ms，采集丢帧 \(t.droppedByCapture)"
        s += "\n    热插拔：断开 \(c.hotplugEvents.disconnects) 次，连接 \(c.hotplugEvents.connects) 次"
        s += "\n    计数：\(c.counters)"
        if let e = c.lastError { s += "\n    最近错误：\(e)" }
    } else if let sc = input as? ScreenInput {
        s += " 目标=\(sc.targetDescription ?? "?") 输出=\(sc.outputWidth)×\(sc.outputHeight)"
        let t = sc.timestampStats
        s += "\n    时间戳：d 平均 \(fmt(t.meanDelayMs)) / max \(fmt(t.maxDelayMs)) / min \(fmt(t.minDelayMs)) ms；退回 displayTime \(t.fallbackToDisplayTime)，退回 now \(t.fallbackToNow)，idle \(t.idleFrames)，重推 \(t.refreshedFrames)"
        s += "\n    计数：\(sc.counters)"
        if let e = sc.lastError { s += "\n    最近错误：\(e)" }
    } else if let f = input as? FileInput {
        s += " \(f.info.map { "\($0.codec) \($0.width)×\($0.height) \(fmt($0.nominalFrameRate, 3)) fps \(fmt($0.duration.doubleValue, 3)) s alpha=\($0.hasAlpha) audio=\($0.hasAudio)" } ?? "")"
        s += "\n    计数：\(f.counters)\n    文件：\(f.fileCountersSnapshot)"
        if let e = f.lastError { s += "\n    最近错误：\(e)" }
    } else if let im = input as? ImageInput {
        s += " \(im.imageWidth)×\(im.imageHeight)\n    计数：\(im.counters)"
        if let e = im.lastError { s += "\n    最近错误：\(e)" }
    }
    return s
}

switch command {
case "devices":
    print("权限：摄像头 \(CapturePermission.status(for: .video))，麦克风 \(CapturePermission.status(for: .audio))，屏幕录制 \(ScreenInput.hasPermission ? "authorized" : "denied/notDetermined")")
    let cams = CameraDevices.list()
    print("摄像头 \(cams.count) 个：")
    for (i, d) in cams.enumerated() {
        print("  [\(i)] \(d.name)  uniqueID=\(d.uniqueID)  type=\(d.deviceType)  model=\(d.modelID)  connected=\(d.isConnected)\(d.linkedAudioDeviceName.map { "  自带麦克风=\($0)" } ?? "")")
        for f in d.formats { print("      \(CameraDevices.fourCC(f.mediaSubType)) \(f.width)×\(f.height) \(f.frameRateRanges.map { "\(fmt($0.lowerBound, 0))–\(fmt($0.upperBound, 0))" }.joined(separator: ","))") }
    }
    if ScreenInput.hasPermission {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {   // detached：main.swift 的顶层代码在主 actor 上，Task {} 会排在被 sem.wait 卡住的主线程后面
            do {
                let displays = try await ScreenTargets.displays()
                print("显示器 \(displays.count) 个：")
                for d in displays { print("  id=\(d.id) \(d.pixelWidth)×\(d.pixelHeight) px（\(d.pointWidth)×\(d.pointHeight) pt）") }
                let windows = try await ScreenTargets.windows().filter { $0.isOnScreen && $0.pointWidth > 50 }
                print("窗口（在屏、> 50 pt）\(windows.count) 个：")
                for w in windows.prefix(30) { print("  id=\(w.id) \(w.pointWidth)×\(w.pointHeight) \(w.applicationName)「\(w.title)」") }
                let apps = try await ScreenTargets.applications()
                print("应用 \(apps.count) 个：" + apps.prefix(20).map { "\($0.name)(\($0.bundleID))" }.joined(separator: "、"))
            } catch { print("屏幕目标清单失败：\(error)") }
            sem.signal()
        }
        sem.wait()
    }

case "clocks", "permission":
    // 单路输入 + 裸帧槽（不起引擎）：看时间戳 / 状态变化。clocks 模式下每拍把帧取出来，记每帧的 pts / ingress，最后出分布。
    let seconds = opts.double("seconds", command == "clocks" ? 5 : 60)
    let timing = ProgramTiming(format: parseFormat(opts.string("format")), t0: HostClock.now())
    let spec: String
    if let c = opts.string("camera") { spec = "camera:\(c)" } else if let s = opts.string("screen") { spec = "screen:\(s)" } else { fail("要 --camera <id> 或 --screen <id>") }
    let config = parseInput(spec, number: 1)
    let slot = LockFreeFrameSlot(capacity: 3)
    let input = try makeInput(config, timing: timing, slot: slot, ring: nil)
    print("[\(stamp())] start \(config.name)（\(seconds) s；期间可以在系统设置里改权限 / 拔插设备）")
    try input.start()
    var lastState = input.state
    var lastPushed: UInt64 = 0
    let deadline = HostClock.now() + HostDuration(seconds: seconds)
    var seen: [(seq: UInt64, pts: HostTime, ingress: HostTime)] = []
    var lastSeq: UInt64 = 0
    while HostClock.now() < deadline {
        let s = input.state
        if s != lastState {
            print("[\(stamp())] state \(lastState) → \(s)\(input is CameraInput ? "  \((input as! CameraInput).lastError ?? "")" : "")")
            lastState = s
        }
        if let f = slot.latest(atOrBefore: HostClock.now() + HostDuration(seconds: 10)), f.sequence != lastSeq {   // 上限放宽：把所有到达的帧都取出来
            lastSeq = f.sequence
            seen.append((f.sequence, f.pts, f.ingressTime))
        }
        usleep(command == "clocks" ? 4_000 : 100_000)
        if command == "permission" {
            let pushed = (input as? CameraInput)?.counters.framesPushed ?? (input as? ScreenInput)?.counters.framesPushed ?? 0
            if pushed != lastPushed, Int(pushed) % 60 == 0 { print("[\(stamp())] 已推 \(pushed) 帧"); lastPushed = pushed }
        }
    }
    print(describe(input))
    print("帧槽：\(slot.stats)")
    if command == "clocks", let first = seen.first {
        print("取到 \(seen.count) 帧（序号缺口 = 被帧槽挤掉的）。d = ingress − pts；Δpts / Δingress = 与上一帧的间隔")
        print("| # | seq | pts（相对首帧 ms） | ingress（相对首帧 ms） | d ms | Δpts ms | Δingress ms |")
        print("|---|---|---|---|---|---|---|")
        for (i, f) in seen.enumerated() where i < 15 || i >= seen.count - 5 {
            let prev = i > 0 ? seen[i - 1] : nil
            print("| \(i) | \(f.seq) | \(fmt((f.pts - first.pts).milliseconds)) | \(fmt((f.ingress - first.ingress).milliseconds)) | \(fmt((f.ingress - f.pts).milliseconds)) | \(prev.map { fmt((f.pts - $0.pts).milliseconds) } ?? "-") | \(prev.map { fmt((f.ingress - $0.ingress).milliseconds) } ?? "-") |")
        }
        // 每秒统计
        print("| 秒 | 帧 | d min | d 平均 | d max | Δpts min/max | Δingress min/max |")
        print("|---|---|---|---|---|---|---|")
        var bucket: [[(seq: UInt64, pts: HostTime, ingress: HostTime)]] = []
        for f in seen {
            let sec = Int((f.ingress - first.ingress).seconds)
            while bucket.count <= sec { bucket.append([]) }
            bucket[sec].append(f)
        }
        var prev: (seq: UInt64, pts: HostTime, ingress: HostTime)? = nil
        for (sec, b) in bucket.enumerated() where !b.isEmpty {
            let ds = b.map { ($0.ingress - $0.pts).milliseconds }
            var dp: [Double] = [], di: [Double] = []
            for f in b { if let p = prev { dp.append((f.pts - p.pts).milliseconds); di.append((f.ingress - p.ingress).milliseconds) }; prev = f }
            print("| \(sec) | \(b.count) | \(fmt(ds.min()!)) | \(fmt(ds.reduce(0, +) / Double(ds.count))) | \(fmt(ds.max()!)) | \(dp.isEmpty ? "-" : "\(fmt(dp.min()!))/\(fmt(dp.max()!))") | \(di.isEmpty ? "-" : "\(fmt(di.min()!))/\(fmt(di.max()!))") |")
        }
    }
    input.stop()

case "run":
    let specs = opts.all("input")
    guard !specs.isEmpty else { fail("至少一个 --input") }
    let seconds = opts.double("seconds", 10)
    let format = parseFormat(opts.string("format"))
    let configs = specs.enumerated().map { parseInput($0.element, number: $0.offset + 1) }
    var engineOptions = EngineOptions()
    if opts.has("no-pacing") { engineOptions.pacing.enabled = false }   // 对照：引擎退回契约入口 latest(atOrBefore:)，不带到达余量
    let harness = try InputEngineHarness(format: format, configs: configs, leadMs: opts.double("lead-ms", 800), engineOptions: engineOptions)
    var inputs: [any Input] = []
    for c in configs {
        let slot = harness.makeSlot(forInput: c.number)
        let input = try makeInput(c, timing: harness.timing, slot: slot, ring: nil)
        harness.add(input)
        inputs.append(input)
    }
    let ticks = Int64((seconds * format.frameRate.approximateFramesPerSecond).rounded())
    print("[\(stamp())] run \(format.width)×\(format.height)@\(format.frameRate) \(ticks) 拍（\(seconds) s），\(inputs.count) 路：\(configs.map(\.name).joined(separator: "、"))，到达余量\(engineOptions.pacing.enabled ? "开" : "关")")
    let sem = DispatchSemaphore(value: 0)
    let box = ErrorBox()
    Task.detached {
        do {
            try await harness.start(lastTick: Tick(ticks - 1))
            print("[\(stamp())] 引擎已起，t0 距现在 \(fmt((harness.timing.clock.t0 - HostClock.now()).milliseconds, 0)) ms，时钟实时策略 \(harness.engine.clock?.isRealtime == true ? "已生效" : "未生效")")
            var lastStates = inputs.map(\.state)
            let deadline = HostClock.now() + HostDuration(seconds: seconds + 5)
            while HostClock.now() < deadline, let c = harness.engine.clock, c.ticksDispatched + c.ticksSkipped < UInt64(ticks) {
                try await Task.sleep(for: .milliseconds(100))
                for (i, inp) in inputs.enumerated() where inp.state != lastStates[i] {
                    print("[\(stamp())] 输入 \(inp.number) state \(lastStates[i]) → \(inp.state)")
                    lastStates[i] = inp.state
                }
            }
            let stats = harness.engine.makeStats()
            await harness.stop()
            print("[\(stamp())] 结束。引擎：派发 \(harness.engine.counters.ticksDispatched) 拍，跳拍 \(harness.engine.counters.ticksSkipped)，missed_render \(stats.missedRender)，render_ms \(fmt(stats.renderMs)) ，jitter_ms \(fmt(stats.jitterMs, 3))，消费者收到 \(harness.consumer?.framesConsumed ?? 0) 帧")
            print("| 输入 | 类型 | L1 样本 | 平均 ms（帧） | p50 | p99 ms（帧） | max ms（帧） | min | 没帧拍 | 重复拍 | 阈值 | 通过 |")
            print("|---|---|---|---|---|---|---|---|---|---|---|---|")
            for (c, inp) in zip(configs, inputs) {
                guard let l = harness.latency(ofInput: c.number) else { continue }
                let f = l.frames(at: format.frameRate)
                let limit: Double = c.kind == .file ? 2 : 3
                let pass = f.mean <= limit && f.p99 <= limit
                print("| \(c.number) | \(c.kind) | \(l.samples) | \(fmt(l.meanMs))（\(fmt(f.mean))） | \(fmt(l.p50Ms)) | \(fmt(l.p99Ms))（\(fmt(f.p99))） | \(fmt(l.maxMs))（\(fmt(f.max))） | \(fmt(l.minMs)) | \(l.ticksWithoutFrame) | \(l.ticksReused) | ≤ \(fmt(limit, 0)) 帧 | \(pass ? "✅" : "❌") |")
                _ = inp
            }
            if let outliers = harness.consumer?.outliers, !outliers.isEmpty {
                print("L1 离群（> 100 ms）：")
                for o in outliers { print("  输入 \(o.inputNumber) 拍 \(o.tick)：\(fmt(o.latencyMs)) ms，ingress \(fmt((o.ingressTime - harness.timing.clock.t0).milliseconds)) ms（相对 t0），消费 \(fmt((o.consumeTime - harness.timing.clock.t0).milliseconds)) ms") }
            }
            for (c, inp) in zip(configs, inputs) {
                print(describe(inp))
                if let p = stats.perInput[c.number] { print("    Stats.per_input：fps \(fmt(p.fps, 1)) dup \(p.dup) drop \(p.drop)") }
                if let ps = harness.engine.pacingStats(forInput: c.number) { print("    到达余量：\(fmt(ps.margin.milliseconds)) ms（窗口最大到达延迟 \(fmt(ps.windowMaxLatency.milliseconds)) ms，迟到 \(ps.lateFrames)，抬 \(ps.raises) / 降 \(ps.decreases)）") }
                if let s = harness.slots.first(where: { $0.number == c.number }) { print("    帧槽：\(s.slot.stats)") }
            }
        } catch { box.error = error }
        sem.signal()
    }
    sem.wait()
    if let e = box.error { fail("run 失败：\(e)") }

case "audio-device":
    // W2-A2 的纯音频设备探针：实现全在 SwitcherInputsHarness.AudioDeviceProbe，这里只是命令行入口（G4 续做合入时按 W2-A2 的问题单接的，胶水）
    if let uid = opts.string("uid") {
        let seconds = opts.double("seconds", 10)
        var audioOptions = AudioDeviceInput.Options()
        if opts.has("no-force-48k") { audioOptions.forceSampleRate48k = false }
        if opts.has("no-convert") { audioOptions.convertSampleRate = false }
        if let map = opts.string("channels") { audioOptions.channelMap = map.split(separator: ",").compactMap { Int($0) } }   // 提案 014 的声道映射
        let run = try AudioDeviceProbe.run(uid: uid, seconds: seconds, channelCount: opts.int("channels-in-ring", 2),
                                           options: audioOptions) { print("[\(stamp())] \($0)") }
        for line in AudioDeviceProbe.report(run) { print(line) }
        exit(run.breaks == 0 && run.nonMonotonic == 0 && run.state == .live ? 0 : 2)
    } else {
        for line in AudioDeviceProbe.deviceLines() { print(line) }
    }

case "hotplug":
    guard let id = opts.string("camera") else { fail("要 --camera <uniqueID>") }
    let cycles = opts.int("cycles", 20)
    let timeout = opts.double("timeout", 120)
    let timing = ProgramTiming(format: parseFormat(opts.string("format")), t0: HostClock.now())
    let slot = LockFreeFrameSlot(capacity: 3)
    guard let dev = CameraDevices.device(uniqueID: id) else { fail("找不到设备 \(id)（先 devices 看清单）") }
    let input = CameraInput(number: 7, name: dev.localizedName, uniqueID: dev.uniqueID, timing: timing, videoSlot: slot)
    try input.start()
    print("[\(stamp())] 等设备「\(dev.localizedName)」起来……")
    let deadline = HostClock.now() + HostDuration(seconds: 15)
    while HostClock.now() < deadline && input.state != .live { usleep(50_000) }
    guard input.state == .live else { fail("设备没起来：\(input.state) \(input.lastError ?? "")") }
    print("[\(stamp())] live。开始 \(cycles) 次拔插（每步超时 \(fmt(timeout, 0)) s）")
    let result = HotplugTimer.run(input: input, cycles: cycles, cycleTimeoutSeconds: timeout) { print("[\(stamp())] \($0)") }
    print(result.summary)
    print(describe(input))
    input.stop()
    exit(result.completedCycles == cycles && result.maxRecoverySeconds <= 3 ? 0 : 2)

default:
    fail("不认识的子命令 \(command)")
}

final class ErrorBox: @unchecked Sendable { var error: (any Error)? }
