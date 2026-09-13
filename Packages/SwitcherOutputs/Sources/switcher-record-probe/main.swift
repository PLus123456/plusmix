// switcher-record-probe —— 命令行录制器（W1-E）。
//   record  --out PATH --seconds N [--fps 60|59.94|30] [--width W --height H] [--codec h264|hevc|prores422|prores422HQ|prores4444]
//           [--bitrate BPS] [--keyint N] [--audio aac|pcm|none] [--texture flat|noise] [--amplitude 24] [--remux] [--fragment SEC]
//           [--pacing realtime|fastest] [--input-id N]
//           实时节拍录制 N 秒，逐秒打印进度。E6 崩溃恢复测试用它当子进程（随机时刻 kill -9）。
//   fixture --out PATH [--seconds 10]
//           生成 Tests/Fixtures/pattern.mov：纯图案 1080p60 H.264 + AAC click 音轨。
//   --version
// 输出行（供父进程解析）：origin <hostTicks> <tick>、tick <n> <hostTicks>、done <videoFrames> <audioFrames>、error <msg>
import Foundation
import SwitcherContracts
import SwitcherOutputs

func fail(_ msg: String) -> Never {
    print("error \(msg)")
    fflush(stdout)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.first == "--version" {
    print("switcher-record-probe \(SwitcherOutputsInfo.version)")
    exit(0)
}
let command = args.removeFirst()
var options: [String: String] = [:]
var flags: Set<String> = []
var i = 0
while i < args.count {
    let a = args[i]
    if a.hasPrefix("--") {
        let key = String(a.dropFirst(2))
        if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
            options[key] = args[i + 1]
            i += 2
        } else {
            flags.insert(key)
            i += 1
        }
    } else {
        fail("unexpected argument \(a)")
    }
}

guard let outPath = options["out"] else { fail("--out required") }
let seconds = Double(options["seconds"] ?? (command == "fixture" ? "10" : "5")) ?? 5
let fpsText = options["fps"] ?? "60"
let frameRate: FrameRate
switch fpsText {
case "60": frameRate = .fps60
case "59.94": frameRate = .fps5994
case "30": frameRate = .fps30
case "29.97": frameRate = .fps2997
case "50": frameRate = .fps50
case "25": frameRate = .fps25
case "24": frameRate = .fps24
default: fail("unknown fps \(fpsText)")
}
let width = Int(options["width"] ?? "1920") ?? 1920
let height = Int(options["height"] ?? "1080") ?? 1080
let format = ProgramFormat(width: width, height: height, frameRate: frameRate)
let codec: VideoCodec = VideoCodec(rawValue: options["codec"] ?? "h264") ?? .h264
let bitrate = Int(options["bitrate"] ?? "6000000") ?? 6_000_000
let keyint = Int(options["keyint"] ?? "120") ?? 120
let audioOption = options["audio"] ?? "aac"
let audio: AudioEncodeSettings? = audioOption == "none" ? nil : AudioEncodeSettings(codec: audioOption == "pcm" ? .pcm : .aac)
let texture: PatternFeeder.Texture = (options["texture"] ?? "flat") == "noise"
    ? .noise(amplitude: Int(options["amplitude"] ?? "24") ?? 24, seed: 1)
    : .flat
let fragment = Double(options["fragment"] ?? "1") ?? 1
let inputID = Int(options["input-id"] ?? "0") ?? 0
let realTime = (options["pacing"] ?? "realtime") == "realtime"

let url = URL(fileURLWithPath: outPath)
let config = Recorder.Configuration(
    url: url, format: format, video: VideoEncodeSettings(codec: codec, bitrateBps: bitrate, keyframeIntervalFrames: keyint),
    audio: audio, fragmentIntervalSeconds: fragment, remuxToMP4: flags.contains("remux"), name: "probe")
let recorder = Recorder(configuration: config)
let feeder: PatternFeeder
do { feeder = try PatternFeeder(configuration: .init(format: format, inputID: inputID, texture: texture)) } catch { fail("feeder \(error)") }

// 起点：现在 + 0.3 s 的整拍，让编码器先热身
let t0 = HostClock.now() + HostDuration(milliseconds: 300)
let clock = TickClockSpec(t0: t0, frameRate: frameRate)
let totalTicks = Int((seconds * frameRate.approximateFramesPerSecond).rounded())
let start = RecordingStart(clock: clock, tick: .zero)
let signal = TestSignal(t0: t0, clickPeriod: TestPattern.flashPeriod(frameRate: frameRate))
let signalFeeder = SignalFeeder(signal: signal)

do { try recorder.start(at: start) } catch { fail("start \(error)") }
print("origin \(t0.ticks) 0")
fflush(stdout)
let nominal = frameRate.nominalFramesPerSecond
do {
    _ = try feeder.feed(consumers: [recorder], clock: clock, ticks: Tick.zero..<Tick(Int64(totalTicks)),
                        pacing: realTime ? .realTime : .fastest(readyToAccept: { !recorder.isQueueFull })) { tick, tickTime in
        signalFeeder.feed(upTo: tickTime, to: [recorder])
        if tick.rawValue % Int64(nominal) == 0 {
            print("tick \(tick.rawValue) \(HostClock.now().ticks)")
            fflush(stdout)
        }
    }
} catch { fail("feed \(error)") }
let endTick = Tick(Int64(totalTicks))
signalFeeder.flush(upToSample: signal.sampleIndex(at: clock.time(of: endTick)), to: [recorder])
let sem = DispatchSemaphore(value: 0)
recorder.stop(atTick: endTick) { result in
    switch result {
    case .success(let r):
        print("done \(r.videoFrames) \(r.audioFrames) \(r.mp4URL?.path ?? "-") \(r.remuxError ?? "-")")
    case .failure(let e):
        print("error \(e)")
    }
    fflush(stdout)
    sem.signal()
}
sem.wait()
