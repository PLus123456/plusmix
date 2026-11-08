// Record only the requested PlusMix process's main window, including its real Metal views.
// Usage: record-window PID output.mov seconds (or PID output.png for a still).
import AppKit
import AVFoundation
import ScreenCaptureKit

let app = NSApplication.shared // Initialize WindowServer before using screenshot APIs.
app.setActivationPolicy(.prohibited) // The recording helper must never cover/activate over PlusMix.
guard CommandLine.arguments.count >= 3, let pid = Int32(CommandLine.arguments[1]) else {
    fatalError("Usage: record-window PID output.mov seconds | PID output.png")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    var finished = false
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        try? Data("ready\n".utf8).write(to: output.appendingPathExtension("ready"))
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finished = true }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        FileHandle.standardError.write(Data("Recording failed: \(error)\n".utf8))
        exit(1)
    }
}

Task { @MainActor in
    do {
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "ReadmeMedia", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Screen Recording access is required for the terminal running this command."])
        }
        guard let target = NSRunningApplication(processIdentifier: pid) else { throw NSError(domain: "ReadmeMedia", code: 5) }
        target.activate(options: [.activateAllWindows])
        for _ in 0..<60 where !target.isActive { try await Task.sleep(for: .milliseconds(50)) }
        guard target.isActive else {
            throw NSError(domain: "ReadmeMedia", code: 6, userInfo: [NSLocalizedDescriptionKey: "Keep the demo window in front while recording; obscured Metal views may stop presenting."])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.frame.width >= 1000 && ($0.title ?? "").contains("PlusMix")
        }) else { throw NSError(domain: "ReadmeMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: "PlusMix main window not found for PID \(pid)"]) }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        if output.pathExtension == "png" {
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                throw NSError(domain: "ReadmeMedia", code: 3)
            }
            try png.write(to: output)
        } else {
            guard CommandLine.arguments.count == 4, let seconds = Double(CommandLine.arguments[3]), seconds > 0 else {
                fatalError("Recording duration must be positive")
            }
            let delegate = RecordingDelegate()
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = output
            recording.outputFileType = .mov
            recording.videoCodecType = .h264
            let sink = SCRecordingOutput(configuration: recording, delegate: delegate)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addRecordingOutput(sink)
            try await stream.startCapture()
            for _ in 0..<Int(ceil(seconds * 5)) {
                try await Task.sleep(for: .milliseconds(200))
                guard target.isActive else {
                    try await stream.stopCapture()
                    throw NSError(domain: "ReadmeMedia", code: 7, userInfo: [NSLocalizedDescriptionKey: "PlusMix lost focus during recording; retry with its window in front."])
                }
            }
            try await stream.stopCapture()
            for _ in 0..<100 where !delegate.finished { try await Task.sleep(for: .milliseconds(50)) }
            guard delegate.finished else { throw NSError(domain: "ReadmeMedia", code: 4, userInfo: [NSLocalizedDescriptionKey: "Recording did not finish"]) }
        }
        print("Captured \(window.windowID): \(config.width)×\(config.height) → \(output.lastPathComponent)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
app.run()
