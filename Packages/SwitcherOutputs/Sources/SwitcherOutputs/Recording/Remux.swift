import AVFoundation
import Foundation

/// 停止后可选的转封装：.mov → .mp4，AVAssetExportSession passthrough（不重新编码）。失败时 .mov 原样保留。
public enum Remux {
    /// 错误。
    public enum Error: Swift.Error {
        case sessionUnavailable
        case exportFailed(String)
    }

    /// 转封装到同目录同名 .mp4（已存在则覆盖）。completion 在任意线程。
    public static func toMP4(movURL: URL, completion: @escaping @Sendable (Result<URL, Swift.Error>) -> Void) {
        let mp4 = movURL.deletingPathExtension().appendingPathExtension("mp4")
        let asset = AVURLAsset(url: movURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(.failure(Error.sessionUnavailable))
            return
        }
        try? FileManager.default.removeItem(at: mp4)
        Task {
            do {
                try await session.export(to: mp4, as: .mp4)
                completion(.success(mp4))
            } catch {
                try? FileManager.default.removeItem(at: mp4)
                completion(.failure(Error.exportFailed("\(error)")))
            }
        }
    }

    /// 同步版本（测试 / 命令行用）。
    public static func toMP4Sync(movURL: URL) -> Result<URL, Swift.Error> {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        toMP4(movURL: movURL) { r in box.set(r); sem.signal() }
        sem.wait()
        return box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private var value: Result<URL, Swift.Error> = .failure(Error.sessionUnavailable)
        private let lock = NSLock()
        func set(_ v: Result<URL, Swift.Error>) { lock.withLock { value = v } }
        func get() -> Result<URL, Swift.Error> { lock.withLock { value } }
    }
}
