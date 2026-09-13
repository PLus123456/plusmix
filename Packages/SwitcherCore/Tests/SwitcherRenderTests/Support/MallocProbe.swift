// 数某个线程上的堆分配：挂 libmalloc 的 malloc_logger（Instruments Allocations 用的同一个钩子），只数目标线程、只数分配（不数释放）。
// 每次分配抓一段回溯（backtrace() 走帧指针，不分配），测试结束后用 dladdr 归类：哪些落在 SwitcherRender 的代码里、哪些在 Metal / CoreVideo 内部。
import Darwin
import Foundation

enum MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    private static let maxSamples = 200_000
    private static let framesPerSample = 24
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var target: pthread_t?
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var sampleCount = 0
    nonisolated(unsafe) private static var frames = [UnsafeMutableRawPointer?](repeating: nil, count: maxSamples * framesPerSample)
    nonisolated(unsafe) private static var frameCounts = [Int32](repeating: 0, count: maxSamples)
    nonisolated(unsafe) private static var reentrancyGuard = false

    private static let hook: Logger = { type, _, _, _, _, _ in
        // type 位：2 = 分配（malloc/calloc/realloc 的结果），4 = 释放
        guard enabled, (type & 2) != 0, let t = target, pthread_equal(pthread_self(), t) != 0, !reentrancyGuard else { return }
        reentrancyGuard = true
        count += 1
        if sampleCount < maxSamples {
            let n = frames.withUnsafeMutableBufferPointer { buf in
                backtrace(buf.baseAddress! + sampleCount * framesPerSample, Int32(framesPerSample))
            }
            frameCounts[sampleCount] = n
            sampleCount += 1
        }
        reentrancyGuard = false
    }

    private static var slot: UnsafeMutablePointer<Logger?>? {
        guard let p = dlsym(dlopen(nil, RTLD_NOW), "malloc_logger") else { return nil }
        return p.assumingMemoryBound(to: Logger?.self)
    }

    /// 钩子能不能装上（找不到符号就跳过测试）。
    static var isAvailable: Bool { slot != nil }

    /// 开始数当前线程（或指定线程）的分配。
    static func start(thread: pthread_t = pthread_self()) {
        count = 0
        sampleCount = 0
        target = thread
        enabled = true
        slot?.pointee = hook
    }

    /// 停止；返回分配次数。
    @discardableResult
    static func stop() -> Int {
        enabled = false
        slot?.pointee = nil
        return count
    }

    /// 一次分配的归类结果。
    struct Attribution {
        /// 回溯里最靠近 malloc 的"真实调用者"（跳过 libsystem_malloc / libobjc / CoreFoundation / libc++ / Swift 运行时）。
        var directCaller: String
        /// 直接调用者是不是 SwitcherRender 的代码（= 我们的 Swift 代码自己分配了；框架内部的分配不算）。
        var isOwn: Bool
        var stack: [String]
    }

    static let runtimeModules = ["libsystem_malloc", "libobjc", "CoreFoundation", "libc++", "libswiftCore", "libdispatch", "libsystem_platform"]

    /// 把抓到的回溯符号化并归类。
    static func attributions() -> [Attribution] {
        var result: [Attribution] = []
        result.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            var stack: [String] = []
            var direct: String?
            var own = false
            for f in 0..<Int(frameCounts[i]) {
                guard let addr = frames[i * framesPerSample + f] else { continue }
                var info = Dl_info()
                guard dladdr(addr, &info) != 0 else { continue }
                let module = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
                let symbol = info.dli_sname.map { String(cString: $0) } ?? "0x\(String(UInt(bitPattern: addr), radix: 16))"
                stack.append("\(module):\(symbol)")
                if direct == nil, f > 0, !runtimeModules.contains(where: { module.hasPrefix($0) }), !symbol.hasPrefix("_malloc"), !symbol.hasPrefix("malloc") {
                    direct = "\(module):\(symbol)"
                    // Swift 名字修饰里的模块名：14SwitcherRender 是库，19SwitcherRenderTests 是测试；测试代码自己的分配不算库的
                    own = symbol.contains("14SwitcherRender")
                }
            }
            result.append(Attribution(directCaller: direct ?? "?", isOwn: own, stack: stack))
        }
        return result
    }

    /// 汇总：按直接调用者计数，降序。
    static func histogram(_ list: [Attribution]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for a in list { counts[a.directCaller, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }
    }
}
