import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

/// E6 崩溃恢复：子进程录制，随机时刻 kill -9，重复 10 次，可播放时长损失 ≤ 2 s（目标 1 s）；转封装后的 MP4 也能播。
final class CrashRecoveryTests: XCTestCase {
    override func setUpWithError() throws {
        try FFprobe.requireAvailable()
    }

    func testE6_kill9TenTimes_playableLossUnder2s() throws {
        let binary = try TestPaths.probeBinary()
        var rng = SplitMix64(seed: 77)
        var losses: [Double] = []
        var lines: [String] = []
        for run in 0..<10 {
            let url = TestPaths.file("e6-\(run).mov")
            try? FileManager.default.removeItem(at: url)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["record", "--out", url.path, "--seconds", "30", "--texture", run % 2 == 0 ? "flat" : "noise"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.standardError
            try process.run()
            // 读到 origin 行
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            var originTicks: UInt64?
            let deadline = Date().addingTimeInterval(20)
            while originTicks == nil && Date() < deadline {
                let chunk = handle.availableData
                if chunk.isEmpty { usleep(5000); continue }
                buffer.append(chunk)
                for line in String(decoding: buffer, as: UTF8.self).split(separator: "\n") where line.hasPrefix("origin ") {
                    originTicks = UInt64(line.split(separator: " ")[1])
                }
            }
            guard let originTicks else { process.terminate(); XCTFail("第 \(run) 次：子进程没打印 origin"); continue }
            // 起点之后 2–12 s 的随机时刻杀
            let killAfter = 2.0 + Double(rng.next() % 10_000) / 1000.0
            let killTime = HostTime(ticks: originTicks) + HostDuration(seconds: killAfter)
            // 持续排空 stdout 防止子进程阻塞
            let drainer = Thread { while true { let d = handle.availableData; if d.isEmpty { break } } }
            drainer.start()
            mach_wait_until(killTime.ticks)
            let actualKill = HostClock.now()
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            let recorded = (actualKill - HostTime(ticks: originTicks)).seconds
            let probe = try FFprobe.probe(url, countFrames: true)
            let playableFrames = probe.video?.nbReadFrames ?? 0
            let playable = Double(playableFrames) / 60
            let loss = recorded - playable
            losses.append(loss)
            // 转封装后的 MP4 也要能播
            var mp4Note = "-"
            switch Remux.toMP4Sync(movURL: url) {
            case .success(let mp4):
                let p2 = try FFprobe.probe(mp4, countFrames: true)
                let mp4Frames = p2.video?.nbReadFrames ?? 0
                mp4Note = "mp4 \(mp4Frames) 帧 \(p2.stderr.isEmpty ? "无错" : "有错：\(p2.stderr)")"
                XCTAssertEqual(p2.stderr, "", "第 \(run) 次：转封装后的 MP4 ffprobe 报错")
                XCTAssertGreaterThanOrEqual(mp4Frames, playableFrames - 60, "第 \(run) 次：MP4 可播放帧数不该比 .mov 少超过 1 s")
            case .failure(let e):
                mp4Note = "转封装失败 \(e)"
                XCTFail("第 \(run) 次：截断文件转封装失败：\(e)")
            }
            lines.append(String(format: "  #%02d 杀于 %.3f s，可播放 %.3f s（%d 帧），损失 %.3f s；%@%@", run, recorded, playable, playableFrames, loss, mp4Note, probe.stderr.isEmpty ? "" : "；ffprobe: \(probe.stderr)"))
            XCTAssertLessThanOrEqual(loss, 2.0, "第 \(run) 次：损失 \(loss) s 超过 2 s")
            XCTAssertGreaterThan(playableFrames, 0)
        }
        print("E6 kill -9 × 10：\n" + lines.joined(separator: "\n"))
        print(String(format: "E6 损失：最大 %.3f s，平均 %.3f s（必须 ≤ 2 s，目标 ≤ 1 s）", losses.max() ?? 0, losses.reduce(0, +) / Double(max(1, losses.count))))
    }
}
