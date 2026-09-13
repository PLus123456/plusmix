// 数某个线程上的堆分配：挂 libmalloc 的 malloc_logger（Instruments Allocations 用的同一个钩子），只数目标线程、只数分配（不数释放）。
// 每次分配抓一段回溯（backtrace() 走帧指针，不分配），测试结束后用 dladdr 归类：哪些落在 SwitcherRender 的代码里、哪些在 Metal / CoreVideo 内部。
import Darwin
import Foundation

enum MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    private static let maxSamples = 200_000
    private static let framesPerSample = 24

    /// 钩子里能碰的状态。放在裸指针后面：Swift 全局 var 在 debug 下每次访问都走 swift_beginAccess，
    /// 它第一次在某线程用 TLS 时会 malloc → 钩子里再进 malloc → 递归崩（实测 SIGBUS）。裸指针的 pointee 不做独占性检查。
    private struct State {
        var enabled = false
        var target: pthread_t? = nil
        var count = 0
        var sampleCount = 0
        var reentrancyGuard = false
        var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>
        var frameCounts: UnsafeMutablePointer<Int32>
    }

    nonisolated(unsafe) private static let state: UnsafeMutablePointer<State> = {
        let p = UnsafeMutablePointer<State>.allocate(capacity: 1)
        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxSamples * framesPerSample)
        frames.initialize(repeating: nil, count: maxSamples * framesPerSample)
        let counts = UnsafeMutablePointer<Int32>.allocate(capacity: maxSamples)
        counts.initialize(repeating: 0, count: maxSamples)
        p.initialize(to: State(frames: frames, frameCounts: counts))
        return p
    }()

    private static let hook: Logger = { type, _, _, _, _, _ in
        // type 位：2 = 分配（malloc/calloc/realloc 的结果），4 = 释放
        let s = state
        guard s.pointee.enabled, (type & 2) != 0, let t = s.pointee.target, pthread_equal(pthread_self(), t) != 0,
              !s.pointee.reentrancyGuard else { return }
        s.pointee.reentrancyGuard = true
        s.pointee.count += 1
        let i = s.pointee.sampleCount
        if i < maxSamples {
            s.pointee.frameCounts[i] = backtrace(s.pointee.frames + i * framesPerSample, Int32(framesPerSample))
            s.pointee.sampleCount = i + 1
        }
        s.pointee.reentrancyGuard = false
    }

    private static var slot: UnsafeMutablePointer<Logger?>? {
        guard let p = dlsym(dlopen(nil, RTLD_NOW), "malloc_logger") else { return nil }
        return p.assumingMemoryBound(to: Logger?.self)
    }

    /// 钩子能不能装上（找不到符号就跳过测试）。
    static var isAvailable: Bool { slot != nil }

    /// 开始数当前线程（或指定线程）的分配。
    static func start(thread: pthread_t = pthread_self()) {
        let s = state   // 先触发一次性初始化（在钩子外面）
        s.pointee.count = 0
        s.pointee.sampleCount = 0
        s.pointee.target = thread
        s.pointee.enabled = true
        slot?.pointee = hook
    }

    /// 停止；返回分配次数。
    @discardableResult
    static func stop() -> Int {
        state.pointee.enabled = false
        slot?.pointee = nil
        return state.pointee.count
    }

    private static var sampleCount: Int { state.pointee.sampleCount }
    private static func frame(_ i: Int, _ f: Int) -> UnsafeMutableRawPointer? { state.pointee.frames[i * framesPerSample + f] }
    private static func frameCount(_ i: Int) -> Int { Int(state.pointee.frameCounts[i]) }

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
            // 回溯从钩子自己开始：backtrace → hook → libsystem_malloc 的几层 → 真正的调用者。先找到最后一个 libsystem_malloc 帧。
            var lastMallocFrame = -1
            var modules: [String] = [], symbols: [String] = []
            for f in 0..<frameCount(i) {
                guard let addr = frame(i, f) else { modules.append("?"); symbols.append("?"); continue }
                var info = Dl_info()
                guard dladdr(addr, &info) != 0 else { modules.append("?"); symbols.append("?"); continue }
                let module = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
                let symbol = info.dli_sname.map { String(cString: $0) } ?? "0x\(String(UInt(bitPattern: addr), radix: 16))"
                modules.append(module)
                symbols.append(symbol)
                if module.hasPrefix("libsystem_malloc") { lastMallocFrame = f }
            }
            for f in 0..<modules.count {
                let module = modules[f], symbol = symbols[f]
                stack.append("\(module):\(symbol)")
                if direct == nil, f > lastMallocFrame, !runtimeModules.contains(where: { module.hasPrefix($0) }) {
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
