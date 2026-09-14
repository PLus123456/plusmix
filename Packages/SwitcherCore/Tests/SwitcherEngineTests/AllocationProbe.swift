import Darwin
import Foundation
import Synchronization

// 按线程计数 malloc / free 的探针：通过 dlsym 拿 libsystem_malloc 的 `malloc_logger` 全局钩子
// （Instruments 的 malloc stack logging 用的就是它；SDK 头文件里没声明，但符号是导出的，探针 5 验证可用）。
// 只在测试里用，用来断言渲染线程每帧零分配（设计方案 §3.2）。钩子本身不分配、不加锁。
enum AllocationProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    static let watchedThread = Atomic<UInt32>(0)
    static let secondThread = Atomic<UInt32>(0)
    static let allocations = Atomic<UInt64>(0)
    static let deallocations = Atomic<UInt64>(0)
    static let secondAllocations = Atomic<UInt64>(0)
    private static let hook: Logger = { type, _, _, _, _, _ in
        let me = pthread_mach_thread_np(pthread_self())
        if me == watchedThread.load(ordering: .relaxed) {
            if type & 2 != 0 { allocations.add(1, ordering: .relaxed) }
            if type & 4 != 0 { deallocations.add(1, ordering: .relaxed) }
        } else if me == secondThread.load(ordering: .relaxed) {
            if type & 2 != 0 { secondAllocations.add(1, ordering: .relaxed) }
        }
    }

    private static var slot: UnsafeMutablePointer<Logger?>? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return sym.assumingMemoryBound(to: Logger?.self)
    }

    /// 装钩子并开始对 thread（mach 线程端口）计数；返回 false = 本系统没有 malloc_logger。
    static func start(watching thread: UInt32, second: UInt32 = 0) -> Bool {
        guard let slot else { return false }
        allocations.store(0, ordering: .relaxed)
        deallocations.store(0, ordering: .relaxed)
        secondAllocations.store(0, ordering: .relaxed)
        watchedThread.store(thread, ordering: .relaxed)
        secondThread.store(second, ordering: .relaxed)
        slot.pointee = hook
        return true
    }

    /// 卸钩子，返回 (被盯线程的 malloc 数, free 数, 第二条线程的 malloc 数)。
    static func stop() -> (allocations: UInt64, deallocations: UInt64, secondAllocations: UInt64) {
        slot?.pointee = nil
        watchedThread.store(0, ordering: .relaxed)
        secondThread.store(0, ordering: .relaxed)
        return (allocations.load(ordering: .relaxed), deallocations.load(ordering: .relaxed), secondAllocations.load(ordering: .relaxed))
    }
}
