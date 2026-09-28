// 用法：fileprobe <show.json> <秒数> [--consume] [--no-audio-ring] [--interval 30]
// 只起 FileInput（W2-A）：帧槽 = LockFreeFrameSlot(3)，音频环 = CAudioRing(2)；不接引擎、渲染器、音频引擎。
// --consume：另起线程每拍 latest(atOrBefore: now) 取帧并把音频环读空（模拟有人消费）；不给则没人取帧（槽满淘汰）、音频环没人读。
// 每 interval 秒打印：秒数、phys_footprint MB、圈数、解码没跟上、晚醒、帧槽 pushed / dropped、音频块写 / 跳。
import Darwin
import Foundation
import SwitcherAudio
import SwitcherContracts
import SwitcherEngine
import SwitcherInputs

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("用法：fileprobe <show.json> <秒数> [--consume] [--no-audio-ring] [--interval 30]"); exit(2) }
let seconds = Double(args[2]) ?? 600
let consume = args.contains("--consume")
let noRing = args.contains("--no-audio-ring")
var interval = 30.0
if let i = args.firstIndex(of: "--interval"), i + 1 < args.count { interval = Double(args[i + 1]) ?? 30 }

let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let inputJSON = try JSONSerialization.data(withJSONObject: (json["inputs"] as! [[String: Any]])[0])
let cfg = try JSONDecoder().decode(InputConfig.self, from: inputJSON)
let timing = ProgramTiming(format: .hd1080p60, t0: HostTime.now() + HostDuration(milliseconds: 500))
let slot = LockFreeFrameSlot(capacity: 3)
let ring: CAudioRing? = noRing ? nil : CAudioRing(channelCount: 2)
let input = try FileInput(config: cfg, timing: timing, videoSlot: slot, audioRing: ring, options: FileInput.Options())
try input.start()
print("fileprobe：\(cfg.name)  consume=\(consume) audioRing=\(ring != nil)  起始 footprint \(String(format: "%.1f", footprintMB())) MB")

nonisolated(unsafe) var stopFlag = false
let consumer = Thread {
    let frameNs = UInt64(1_000_000_000 / 60)
    while !stopFlag {
        _ = slot.latest(atOrBefore: HostTime.now())
        if let ring, ring.availableFrames > 0 { _ = ring.read(frameCount: ring.availableFrames) }
        var ts = timespec(tv_sec: 0, tv_nsec: Int(frameNs))
        nanosleep(&ts, nil)
    }
}
if consume { consumer.name = "fileprobe.consumer"; consumer.start() }

let start = Date()
var next = interval
while Date().timeIntervalSince(start) < seconds {
    Thread.sleep(forTimeInterval: 1)
    let el = Date().timeIntervalSince(start)
    if el >= next {
        next += interval
        let f = input.fileCountersSnapshot, s = slot.stats, r = ring?.stats
        print(String(format: "%6.0f s  footprint %7.1f MB  圈 %4llu  没跟上 %llu  晚醒 %llu  槽 pushed %llu dropped %llu  音频块写 %llu 跳 %llu  overruns %@",
                     el, footprintMB(), f.loops, f.ticksStarved, f.lateWakes, s.pushed, s.dropped, f.audioChunksWritten, f.audioChunksSkipped,
                     r.map { "\($0.overruns)" } ?? "-"))
        fflush(stdout)
    }
}
stopFlag = true
input.stop()
print("结束：footprint \(String(format: "%.1f", footprintMB())) MB，圈 \(input.fileCountersSnapshot.loops)，状态 \(input.state)")
