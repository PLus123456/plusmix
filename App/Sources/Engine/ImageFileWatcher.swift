// 图片输入的文件监视（W5-H，01a G14）：外面改了 PNG（做字幕 / 台标最常用的路子），这一路下一拍换上，不用换路径再"应用来源"。
// SwitcherInputs 的 ImageInput 只在 start() 里解码一次、自己不监视文件（问题单 W5H-w2-inputs-image-input-no-file-watch）；
// 包里有监视之前，App 这边用 DispatchSource 盯文件，变了让运行表对同一个输入对象重新读同一条路径（InputRuntime.reloadImage）。
//
// 两种改法都要认：
// - 原地覆盖写（截断再写）：write / extend 事件，fd 还是那个文件；
// - 写临时文件再改名盖过去（多数编辑器、replaceItemAt）：旧 inode 收到 delete / rename，按路径重新打开新文件、照样算"变了"。
// 写到一半的文件解不完整：先用 ImageIO 看文件是否完整（CGImageSourceGetStatus == complete），不完整就等下一个事件；
// 同一阵事件（一次保存常有好几个）合成一次，在 20 ms 后的主线程上处理。文件被删了、还没回来：每 0.25 s 看一眼路径，回来了接着监视。
import Foundation
import ImageIO

@MainActor
final class ImageFileWatcher {
    let path: String
    private let onChange: @MainActor () -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private var retryTimer: Timer?
    /// 上次交出去的版本（修改时间 + 大小）：同一个版本只换一次（attrib 之类不改内容的事件不重读）。
    private var lastVersion: Version?
    private(set) var isWatching = false

    private struct Version: Equatable {
        let modified: Date
        let size: Int
        let inode: Int
    }

    /// 合并一阵事件的窗口。
    static let coalesceDelay: TimeInterval = 0.02
    /// 文件不在时多久再看一次。
    static let retryInterval: TimeInterval = 0.25

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
        lastVersion = Self.version(of: path)
        arm()
    }

    /// 停止监视（这一路删了 / 换了来源 / 停引擎）。重复调无害。
    func stop() {
        pending?.cancel()
        pending = nil
        retryTimer?.invalidate()
        retryTimer = nil
        source?.cancel()
        source = nil
        isWatching = false
    }

    private func arm() {
        source?.cancel()
        source = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            isWatching = false
            scheduleRetry()
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke], queue: .main)
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                let events = source.data
                // 旧 inode 不再代表这条路径（被删 / 被改名盖掉）：重开路径上的新文件
                if !events.intersection([.delete, .rename, .revoke]).isEmpty { self.arm() }
                self.scheduleCheck()
            }
        }
        s.setCancelHandler { close(fd) }
        source = s
        isWatching = true
        s.resume()
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, FileManager.default.fileExists(atPath: self.path) else { return }
                self.arm()
                self.scheduleCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func scheduleCheck() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceDelay, execute: item)
    }

    /// 文件完整、而且确实是个新版本：交出去。
    private func check() {
        pending = nil
        guard let version = Self.version(of: path), version != lastVersion, Self.isCompleteImage(path) else { return }
        lastVersion = version
        onChange()
    }

    private static func version(of path: String) -> Version? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Version(modified: modified, size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                       inode: (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0)
    }

    /// ImageIO 认为整张图都在（写到一半的 PNG 是 incomplete）。
    static func isCompleteImage(_ path: String) -> Bool {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceGetStatus(source) == .statusComplete && CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }
}
