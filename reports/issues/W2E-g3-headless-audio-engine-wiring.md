# G3 接线：headless 换用 W2-E 的 AudioEngine（补丁 + 说明）

归属会话 / 分支：G3（`Tools/switcher-headless/` 是 W2-C / 检查点的目录，W2-E 不能改）
发现于：W2-E / w2-audio-integ

## 为什么

G2 的 headless 自己 attach 环、自建 `AudioPump` 把 Master tap 喂给 Recorder，块 PTS = 块首 host time（没扣混音器年龄），A2 因此 −16.6…−18.5 ms
（`G2-w2-audio-integ-av-offset.md`）。W2-E 的 `SwitcherAudioIntegration.AudioEngine` 把这些都收进去了：对齐延迟、AFV、FTB、每路参数、监听、
消费者泵、真设备 host 时钟重采样、状态快照。W2-E 在 scratchpad 里用一份改过的 headless 副本跑了 45 s / 10 min / 60 min（数字在 `reports/w2-audio-integ.md`），
改动就是下面这个补丁（`AudioPump.swift` 整个删掉；另加了 `--iso-audio N`：再起 N 个录制器录 PGM 视频 + 输入 1…N 的 ISO 音轨，A4 用）。

## 接线要点

1. `import SwitcherAudioIntegration`；`extension Recorder: AudioBlockConsuming {}`（协议与 W1-E 的逐字同签名；提案 001 批后改成契约协议，这行删）。
2. `AudioEngine(stateMachine:configuration:)`：`configuration.output` 由 `--audio-device` 映射（null / systemDefault / device(name:)）；
   `SW_AUDIO_SILENT=1` → `outputChannelMap = BusChannelMap(master: nil)`（真设备不出声，Master 照常处理、照常录）。
3. 每路带音频的输入：`audioEngine.registerInput(number:ring:hints:)`，`hints.producerBlockFrames = 源的块大小`。
4. 录制：`audioEngine.addConsumer(rec, source: .master)` 拿到 token；ISO 音轨用 `.input(number:)`。
5. `engine.audioStatsProvider = { audioEngine.audioCounters }`（铁律 4）。
6. 顺序：`await audioEngine.start(clock: spec)` → 视频源 → 音频源 → 录制 start → 引擎 start；停：引擎停 → **等边界的块送到（边界 + 对齐延迟 + 2 块 + 6 ms）
   → `audioEngine.removeConsumer(token)` → `rec.stop(atTick:)`** → `audioEngine.stop()` → 音频源 stop。先摘消费者是绕 W1-E 录制器的收尾问题
   （`W2E-w1-outputs-recorder-drift-check-before-stop.md`），W1-E 修好后可以先 stop 再摘。
7. 汇总打印 `audioEngine.status`（对齐、年龄、消费者、不连续、设备）。

Package.swift 加 `.product(name: "SwitcherAudioIntegration", package: "SwitcherAudio")`。

## 补丁

```diff
--- Tools/switcher-headless/Sources/switcher-headless/HeadlessRun.swift	2026-09-15 11:17:02
+++ Tools/switcher-headless/Sources/switcher-headless/HeadlessRun.swift	2026-09-15 12:48:27
@@ -4,9 +4,13 @@
 import SwitcherEngine
 import SwitcherRender
 import SwitcherAudio
+import SwitcherAudioIntegration
 import SwitcherOutputs
 import SwitcherTestKit
 
+/// W2-E：Recorder 与集成层的消费者协议逐字同签名，空扩展即可接上（提案 001 批后两边都是契约协议，这行删掉）。
+extension Recorder: AudioBlockConsuming {}
+
 /// run 子命令的参数。
 struct RunOptions: Sendable {
     var showURL: URL
@@ -22,50 +26,24 @@
     var inputLeadMs: Double?
     /// 录制封口的看门狗（秒）。
     var stopTimeoutSeconds: Double = 60
+    /// W2-E A4：另起 N 个录制器（PGM 视频 + 输入 1…N 各自的 ISO 音轨），文件名 <record>-iso<k>.mov。
+    var isoAudio: Int = 0
 }
 
-/// 音频输出：空设备（实时假时钟，不出声）或真设备。
+/// 音频输出：--audio-device null|default|<名字> → 集成层的设备选择（空设备 = W1-D 假时钟，不出声，CI 用）。
 enum AudioOutputChoice {
-    case null(NullOutputDevice)
-    case device(AudioOutputDevice)
-
-    static func make(_ spec: String, mixer: AudioMixer) throws -> AudioOutputChoice {
+    static func output(_ spec: String) throws -> AudioEngineConfiguration.Output {
         switch spec.lowercased() {
-        case "null", "none": return .null(NullOutputDevice(mixer: mixer))
-        case "default", "": return .device(try AudioOutputDevice(mixer: mixer))
+        case "null", "none": return .null
+        case "default", "": return .systemDefault
         default:
-            guard let info = AudioHAL.device(named: spec) else {
+            guard AudioHAL.device(named: spec) != nil else {
                 let names = AudioHAL.devices().filter { $0.outputChannels > 0 }.map(\.name).joined(separator: " / ")
                 throw CLIError("找不到音频输出设备「\(spec)」。有：\(names)")
             }
-            return .device(try AudioOutputDevice(mixer: mixer, deviceID: info.id))
+            return .device(name: spec)
         }
     }
-
-    func start() throws {
-        switch self {
-        case .null(let d): try d.start()
-        case .device(let d): try d.start()
-        }
-    }
-
-    func stop() {
-        switch self {
-        case .null(let d): d.stop()
-        case .device(let d): d.stop()
-        }
-    }
-
-    var summary: String {
-        switch self {
-        case .null(let d):
-            let s = d.stats
-            return "空设备：\(s.blocks) 块，跳块 \(s.skippedBlocks)，最晚醒来 \(String(format: "%.3f", s.maxWakeLateMs)) ms"
-        case .device(let d):
-            let s = d.callbackStats
-            return "\(d.info.name)：\(s.callbacks) 次回调，抖动 max \(String(format: "%.3f", s.maxJitterMs)) ms，buffer \(d.actualBlockFrames)"
-        }
-    }
 }
 
 /// 把录制器的编码计数变成 Stats.encoder 的一项：skipped 累计、bitrate 按上次采样以来的窗口算。只在 Stats 采样线程上被调。
@@ -172,17 +150,22 @@
             }
         }
 
-        // 2. 音频：混音器（C 热路径）+ 输出设备；每路带音频的输入挂一个槽位，参数照节目文件。
-        let mixer = AudioMixer()
-        for (slotIndex, entry) in audioInputs.enumerated() {
-            mixer.attach(ring: entry.ring, toSlot: slotIndex)
-            mixer.apply(entry.settings, toSlot: slotIndex)
+        // 2. 音频：W2-E 的 AudioEngine（混音器 + 设备 + 对齐 + AFV + 消费者泵）；每路带音频的输入把环注册进去，参数从状态机快照来。
+        var audioConfig = AudioEngineConfiguration()
+        audioConfig.output = try AudioOutputChoice.output(options.audioDevice)
+        // SW_AUDIO_SILENT=1：真设备也不出声（Master 不映射到设备通道，仍照常处理、照常送录制器）——W2-E 长跑用
+        if ProcessInfo.processInfo.environment["SW_AUDIO_SILENT"] == "1" { audioConfig.outputChannelMap = BusChannelMap(master: nil) }
+        let audioEngine = try AudioEngine(stateMachine: stateMachine, configuration: audioConfig)
+        for entry in audioInputs {
+            var hints = AudioInputHints()
+            hints.producerBlockFrames = entry.source.blockFrames
+            try audioEngine.registerInput(number: entry.number, ring: entry.ring, hints: hints)
         }
-        let audioDevice = try AudioOutputChoice.make(options.audioDevice, mixer: mixer)
 
         // 3. 录制：Recorder 是 PGM 帧的消费者（有界队列 + 自己的编码线程）；Master 块经泵线程喂给它。
         var recorder: Recorder?
-        var pump: AudioPump?
+        var recorderAudioToken: AudioConsumerToken?
+        var isoRecorders: [(Recorder, AudioConsumerToken)] = []
         if let url = options.recordURL {
             let outputSettings = show.outputs.first { $0.kind == .record }?.settings
             let cfg = Recorder.Configuration(url: url, format: format,
@@ -194,11 +177,19 @@
                                              name: "record")
             let rec = Recorder(configuration: cfg)
             engine.addConsumer(rec)
-            if !audioInputs.isEmpty {
-                guard let tap = mixer.addTap(source: .bus(.master)) else { throw CLIError("混音器消费者队列已满") }
-                pump = AudioPump(tap: tap, consumer: rec)
-            }
+            if !audioInputs.isEmpty { recorderAudioToken = try audioEngine.addConsumer(rec, source: .master) }
             recorder = rec
+            // A4：ISO 音轨录制器（视频仍是 PGM——每路视频 ISO 是 W3-C 的事）
+            for k in 0..<options.isoAudio {
+                let number = audioInputs[k].number
+                let isoURL = url.deletingPathExtension().appendingPathExtension("iso\(number).mov")
+                var isoCfg = cfg
+                isoCfg.url = isoURL
+                isoCfg.name = "iso\(number)"
+                let iso = Recorder(configuration: isoCfg)
+                engine.addConsumer(iso)
+                isoRecorders.append((iso, try audioEngine.addConsumer(iso, source: .input(number: number))))
+            }
         }
 
         // 4. Stats：引擎每秒组一行（铁律 4，只有这一份），编码 / 音频 / GPU 三个来源从这里灌。
@@ -210,7 +201,7 @@
                 let source = EncoderStatsSource(recorder: rec)
                 engine.encoderStatsProvider = { source.entries() }
             }
-            engine.audioStatsProvider = { mixer.audioCounters }
+            engine.audioStatsProvider = { audioEngine.audioCounters }
             if options.gpuStats, let g = GPUUtilization() {
                 gpu = g
                 engine.gpuPercentProvider = { g.deviceUtilizationPercent() }
@@ -225,13 +216,13 @@
 
         // 6. 起：音频设备 → 视频输入（到 t0 才出第一帧）→ 音频输入 → 录制（起点 = 第 0 拍；尽量晚起，
         //    它的入口环只存 256 块 ≈ 1.4 s，起点之前的块留在里面等第一个压缩视频样本到了才会被丢掉）→ 泵 → 引擎（start 里 prepare 渲染器，lead 要盖住它）
-        try audioDevice.start()
+        try await audioEngine.start(clock: spec)
         for input in inputs { try input.start() }
         for entry in audioInputs { try entry.source.start() }
         if let rec = recorder { try rec.start(at: RecordingStart(clock: spec, tick: .zero)) }
-        pump?.start()
+        for (iso, _) in isoRecorders { try iso.start(at: RecordingStart(clock: spec, tick: .zero)) }
         if stopRequested {
-            shutdownEarly(inputs: inputs, audioInputs: audioInputs.map(\.source), recorder: recorder, pump: pump, audioDevice: audioDevice, writer: writer)
+            await shutdownEarly(inputs: inputs, audioInputs: audioInputs.map(\.source), recorder: recorder, audioEngine: audioEngine, writer: writer)
             return
         }
         try await engine.start(t0: t0, firstTick: .zero, lastTick: lastTick)
@@ -243,7 +234,7 @@
               节目：\(show.name)（\(options.showURL.path)）\(format.width)×\(format.height)@\(format.frameRate)，\(inputs.count) 路合成源，\(audioInputs.count) 路音频
               场景：\(options.scriptURL?.path ?? "无")（\(scenario?.events.count ?? 0) 个事件）
               时长：\(totalTicks) 拍（\(String(format: "%.1f", options.durationSeconds)) s）  t0 距现在 \(String(format: "%.0f", leadLeft)) ms\(leadLeft < 0 ? "  ⚠️ 起晚了，开头会跳拍" : "")  合成源提前量 \(String(format: "%.2f", inputLeadMs)) ms
-              音频：\(options.audioDevice)  录制：\(options.recordURL?.path ?? "无")  stats：\(options.statsURL?.path ?? "无")  GPU 占用：\(gpu == nil ? "不可用" : "IOKit")
+              音频：\(options.audioDevice)（对齐延迟 \(String(format: "%.2f", audioEngine.alignmentDuration.milliseconds)) ms，消费者流\(audioEngine.resamplesToHostClock ? "重采样到 host 时钟" : "不重采样")）  录制：\(options.recordURL?.path ?? "无")  stats：\(options.statsURL?.path ?? "无")  GPU 占用：\(gpu == nil ? "不可用" : "IOKit")
               时钟实时策略：\(clock.isRealtime ? "已生效" : "⚠️ 未生效（V3 会超）")
             """)
 
@@ -268,6 +259,18 @@
         let boundary = Tick((engine.counters.lastTick?.rawValue ?? -1) + 1)
         var recordResult: RecordingResult?
         if let rec = recorder {
+            // 边界之后的音频块不再送录制器：块 PTS = 块首 − 对齐延迟，含边界的块要等对齐延迟 + 一块 + 泵周期才到，等够再摘消费者。
+            // 否则录制器封口期间还在收块，它的漂移硬校正会对"边界之后"的块补静音（W1-E 的 drainAudio 先查漂移后查 stopTime），
+            // 每次补的静音随墙钟增长，appendPCM 每 4096 帧等 200 ms 超时——45 s 冒烟跑封口卡了 3 分钟。给 W1-E 的问题单。
+            if let token = recorderAudioToken {
+                let boundaryTime = spec.time(of: boundary)
+                let deadline = boundaryTime + audioEngine.alignmentDuration + audioEngine.blockDuration * 2 + HostDuration(milliseconds: 6)
+                let wait = deadline - HostClock.now()
+                if wait.ticks > 0 { try? await Task.sleep(for: .nanoseconds(Int(wait.nanoseconds))) }
+                audioEngine.removeConsumer(token)
+                recorderAudioToken = nil
+                for (_, t) in isoRecorders { audioEngine.removeConsumer(t) }
+            }
             let before = rec.counters
             let result = await stopRecorder(rec, atTick: boundary, timeoutSeconds: options.stopTimeoutSeconds)
             switch result {
@@ -286,14 +289,21 @@
                 exitCode = 1
             }
         }
-        pump?.stop()
-        audioDevice.stop()
+        for (iso, _) in isoRecorders {
+            switch await stopRecorder(iso, atTick: boundary, timeoutSeconds: options.stopTimeoutSeconds) {
+            case .success(let r)?: print("  ISO：\(r.url.lastPathComponent) 视频 \(r.videoFrames) 帧 / 音频 \(r.audioFrames) 样本 / 音频漂移 \(String(format: "%.3f", iso.counters.audioDrift.milliseconds)) ms 硬校正 \(iso.counters.audioCorrections)")
+            case .failure(let e)?: print("  ISO 封口失败：\(e)")
+            case nil: print("  ISO 封口超时")
+            }
+        }
+        let audioStatus = audioEngine.status
+        await audioEngine.stop()
         for entry in audioInputs { entry.source.stop() }
         writer?.close()
 
         // 9. 汇总（stdout；数字来源都是各对象的计数器，正式指标以 stats.jsonl / frameprobe 为准）
-        printSummary(clock: clock, inputs: inputs, audioInputs: audioInputs.map { (number: $0.number, source: $0.source) }, mixer: mixer,
-                     audioDevice: audioDevice, pump: pump, recorder: recorder, recordResult: recordResult, writer: writer, interrupted: interrupted)
+        printSummary(clock: clock, inputs: inputs, audioInputs: audioInputs.map { (number: $0.number, source: $0.source) }, audioStatus: audioStatus,
+                     recorder: recorder, recordResult: recordResult, writer: writer, interrupted: interrupted)
     }
 
     /// 录制封口，带看门狗：nil = 超时。
@@ -312,15 +322,12 @@
         }
     }
 
-    private func shutdownEarly(inputs: [SyntheticVideoInput], audioInputs: [SyntheticAudioInput], recorder: Recorder?, pump: AudioPump?,
-                               audioDevice: AudioOutputChoice, writer: StatsWriter?) {
+    private func shutdownEarly(inputs: [SyntheticVideoInput], audioInputs: [SyntheticAudioInput], recorder: Recorder?,
+                               audioEngine: AudioEngine, writer: StatsWriter?) async {
         if let rec = recorder {
-            let done = DispatchSemaphore(value: 0)
-            rec.stop(atTick: .zero) { _ in done.signal() }
-            _ = done.wait(timeout: .now() + 10)
+            _ = await stopRecorder(rec, atTick: .zero, timeoutSeconds: 10)
         }
-        pump?.stop()
-        audioDevice.stop()
+        await audioEngine.stop()
         for a in audioInputs { a.stop() }
         for input in inputs { input.stop() }
         writer?.close()
@@ -329,7 +336,7 @@
     }
 
     private func printSummary(clock: ProgramClock, inputs: [SyntheticVideoInput], audioInputs: [(number: Int, source: SyntheticAudioInput)],
-                              mixer: AudioMixer, audioDevice: AudioOutputChoice, pump: AudioPump?, recorder: Recorder?,
+                              audioStatus a: AudioEngineStatus, recorder: Recorder?,
                               recordResult: RecordingResult?, writer: StatsWriter?, interrupted: Bool) {
         let c = engine.counters
         func ms(_ d: HostDuration?) -> String { d.map { String(format: "%.3f", $0.milliseconds) } ?? "—" }
@@ -346,8 +353,13 @@
             }
             lines.append("  输入 \(input.number)：生成 \(k.generated)，设定丢 \(k.droppedByDesign)，池不够 \(k.poolStarved)，迟到 \(k.late)，唤醒 max \(String(format: "%.3f", Double(k.wakeLatencyMaxNs) / 1e6)) ms；帧槽 pushed \(s?.pushed ?? 0) consumed \(s?.consumed ?? 0) reused \(s?.reused ?? 0) dropped \(s?.dropped ?? 0)" + pacing)
         }
-        let a = mixer.stats
-        lines.append("  音频：\(a.blocksRendered) 块，dropouts \(a.dropouts)，underruns \(a.underruns)，实时违规 \(a.rtViolations)，队列丢块 \(a.tapDrops)，最长一块 \(String(format: "%.3f", HostDuration(ticks: Int64(a.maxBlockTicks)).milliseconds)) ms；\(audioDevice.summary)" + (pump.map { "；泵搬块 \($0.moved)" } ?? ""))
+        lines.append("  音频：\(a.blocksRendered) 块，dropouts \(a.counters.dropouts)，underruns \(a.counters.underruns)，不连续 \(a.discontinuities)，实时违规 \(a.realtimeViolations)，队列丢块 \(a.tapDrops)；设备 \(a.device.kind) \(a.device.name)：\(a.device.callbacks) 块，最晚醒 / 抖动 \(String(format: "%.3f", a.device.maxJitterMs)) ms；对齐延迟 \(String(format: "%.2f", a.alignmentMs)) ms")
+        for i in a.inputs {
+            lines.append("  音频输入 \(i.number)：槽位 \(i.slot)，年龄 \(String(format: "%.0f", i.ageSetpointFrames)) 帧，对齐延迟 \(i.alignmentDelayFrames) 帧，补不齐 \(i.residualFrames)，比率 \(String(format: "%+.1f", i.ratioPpm)) ppm，欠载块 \(i.underrunBlocks)，重就绪 \(i.reprimes)，AFV \(String(format: "%.2f", i.afvGain))")
+        }
+        for c in a.consumers {
+            lines.append("  音频消费者 \(c.source) → \(c.consumers)：\(c.blocks) 块 / \(c.frames) 帧，tap 丢 \(c.tapDropped)" + (c.devicePpm.map { String(format: "，设备 %+.2f ppm，重采样比 %.7f，挨饿 %d", $0, c.resampleRatio ?? 1, c.resamplerStarved) } ?? ""))
+        }
         for entry in audioInputs {
             let k = entry.source.counters
             lines.append("  音频源 \(entry.number)：写 \(k.blocksWritten) 块 / \(k.framesWritten) 帧，拒 \(k.framesRejected)，迟到 \(k.late)")
--- Tools/switcher-headless/Sources/switcher-headless/HeadlessCLI.swift	2026-09-15 11:17:02
+++ Tools/switcher-headless/Sources/switcher-headless/HeadlessCLI.swift	2026-09-15 12:48:27
@@ -21,7 +21,7 @@
     /// 带值的参数；其余 -- 开头的都是开关。
     static let valueKeys: Set<String> = [
         "show", "script", "duration", "stats", "record", "audio-device", "lead-ms", "input-lead-ms", "stop-timeout",
-        "out", "width", "height", "minutes", "fps", "inputs", "baseline", "write-baseline", "v1-avg-ms", "meta",
+        "out", "width", "height", "minutes", "fps", "inputs", "baseline", "write-baseline", "v1-avg-ms", "meta", "iso-audio",
     ]
 
     static func dispatch(_ args: [String]) throws {
@@ -51,7 +51,8 @@
                                  statsURL: p.url("stats"), recordURL: p.url("record"), preview: p.has("preview"),
                                  audioDevice: p.string("audio-device") ?? "default",
                                  leadMs: try p.double("lead-ms") ?? 1000, gpuStats: !p.has("no-gpu-stats"),
-                                 inputLeadMs: try p.double("input-lead-ms"), stopTimeoutSeconds: try p.double("stop-timeout") ?? 60)
+                                 inputLeadMs: try p.double("input-lead-ms"), stopTimeoutSeconds: try p.double("stop-timeout") ?? 60,
+                                 isoAudio: try p.int("iso-audio") ?? 0)
         let session = try HeadlessSession(options: options)
         SignalHandling.install(session)
         if options.preview {
```
