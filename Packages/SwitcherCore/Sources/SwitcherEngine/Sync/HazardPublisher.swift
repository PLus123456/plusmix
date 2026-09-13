import Synchronization

// 单写多读的"原子指针发布"（设计方案 §4、§9.1：渲染线程 / 音频线程靠原子指针交换拿到最新快照，不进 actor）。
//
// 问题：读方 load 到指针后要用它（读字段或 retain），但在 load 与使用之间写方可能已经换了指针并释放旧对象。
// 解法：hazard pointer（风险指针）。
//   读方：p = published.load; hazard[i].store(p); 再 load 一次 published，与 p 不同就重来；相同则 p 受保护，用完把 hazard 清空。
//   写方：published.exchange(new)；旧对象进 retired 表；扫描所有 hazard 槽，没被登记的才 release。
// 内存序：两边都是 store-load 型的 Dekker 模式（读方 "store hazard 然后 load published"，写方 "store published 然后 load hazard"），
// 必须 sequentially consistent；acquire/release 允许 store 与后面的 load 重排，会让写方看漏读方刚登记的 hazard。
// 完整论证在 reports/w1-core.md。
//
// 线程规则：`publish` 只能由一条写线程调（状态机线程）。每个实时读线程各持一个 `ReaderSlot`（单线程使用）；
// 借用期间零分配、无锁，写方永远不等读方。非实时读者用 `latest`（一把互斥锁，只保护一个强引用）。

/// 单写多读的原子指针发布器。
public final class HazardPublisher<Object: AnyObject & Sendable>: @unchecked Sendable {
    /// 最多同时存在的读槽数。
    public let readerCapacity: Int
    private let published: Atomic<Unmanaged<Object>?>
    private let hazards: UnsafeMutablePointer<Atomic<Unmanaged<Object>?>>
    private let slotTaken: UnsafeMutablePointer<Atomic<Bool>>
    /// 写方私有：已被替换、等读方放手的对象。
    private var retired: [Unmanaged<Object>] = []
    /// 给非实时读者的强引用副本。
    private let strong: Mutex<Object?>

    public init(initial: Object?, readerCapacity: Int = 4) {
        precondition(readerCapacity >= 1)
        self.readerCapacity = readerCapacity
        published = Atomic(initial.map { Unmanaged.passRetained($0) })
        hazards = .allocate(capacity: readerCapacity)
        slotTaken = .allocate(capacity: readerCapacity)
        for i in 0..<readerCapacity {
            (hazards + i).initialize(to: Atomic(nil))
            (slotTaken + i).initialize(to: Atomic(false))
        }
        strong = Mutex(initial)
        retired.reserveCapacity(readerCapacity + 1)
    }

    deinit {
        // 读者必须已经全部结束（ReaderSlot 持有本对象的强引用，所以到这里没有读者了）
        published.load(ordering: .sequentiallyConsistent)?.release()
        for u in retired { u.release() }
        for i in 0..<readerCapacity {
            (hazards + i).deinitialize(count: 1)
            (slotTaken + i).deinitialize(count: 1)
        }
        hazards.deallocate()
        slotTaken.deallocate()
    }

    // MARK: 写方

    /// 发布新对象（写线程）。旧对象等所有读者放手后释放。
    public func publish(_ object: Object) {
        let new = Unmanaged.passRetained(object)
        strong.withLock { $0 = object }
        let old = published.exchange(new, ordering: .sequentiallyConsistent)
        if let old { retired.append(old) }
        scanRetired()
    }

    /// 释放 retired 里没有任何读者登记的对象（写线程）。
    private func scanRetired() {
        var i = 0
        while i < retired.count {
            if isHazarded(retired[i]) {
                i += 1
            } else {
                retired[i].release()
                retired.swapAt(i, retired.count - 1)
                retired.removeLast()
            }
        }
    }

    private func isHazarded(_ u: Unmanaged<Object>) -> Bool {
        let p = u.toOpaque()
        for k in 0..<readerCapacity {
            if hazards[k].load(ordering: .sequentiallyConsistent)?.toOpaque() == p { return true }
        }
        return false
    }

    /// 等所有 retired 对象被释放（读者应已停止或很快归还）。返回是否清空。写线程 / 停机时调。
    @discardableResult
    public func drain(maxSpins: Int = 1_000_000) -> Bool {
        var spins = 0
        while !retired.isEmpty && spins < maxSpins {
            scanRetired()
            spins += 1
        }
        return retired.isEmpty
    }

    /// retired 表长度（写线程读；测试用）。
    public var retiredCount: Int { retired.count }

    // MARK: 读方

    /// 非实时读者：拿当前对象的强引用（一把短锁）。
    public var latest: Object? { strong.withLock { $0 } }

    /// 分配一个读槽。每条实时读线程一个；槽用尽是配置错误。
    public func makeReaderSlot() -> ReaderSlot {
        for i in 0..<readerCapacity {
            let (ok, _) = slotTaken[i].compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
            if ok { return ReaderSlot(publisher: self, index: i) }
        }
        preconditionFailure("HazardPublisher 读槽用尽（readerCapacity = \(readerCapacity)）")
    }

    fileprivate func releaseSlot(_ index: Int) {
        hazards[index].store(nil, ordering: .sequentiallyConsistent)
        slotTaken[index].store(false, ordering: .releasing)
    }

    /// 一条读线程的借用凭据。`borrow` / `endBorrow` 成对，同一时刻只借一个；全部零分配、无锁。
    public final class ReaderSlot: @unchecked Sendable {
        private let publisher: HazardPublisher
        private let index: Int

        fileprivate init(publisher: HazardPublisher, index: Int) {
            self.publisher = publisher
            self.index = index
        }
        deinit { publisher.releaseSlot(index) }

        /// 借用当前对象；返回后到 `endBorrow` 之前写方不会释放它。没有对象时返回 nil。
        @inline(__always)
        public func borrow() -> Unmanaged<Object>? {
            var p = publisher.published.load(ordering: .sequentiallyConsistent)
            while true {
                publisher.hazards[index].store(p, ordering: .sequentiallyConsistent)
                let q = publisher.published.load(ordering: .sequentiallyConsistent)
                if q?.toOpaque() == p?.toOpaque() { return p }
                p = q
            }
        }

        /// 归还。
        @inline(__always)
        public func endBorrow() {
            publisher.hazards[index].store(nil, ordering: .sequentiallyConsistent)
        }

        /// 借用 + retain + 归还：得到普通强引用（零分配）。
        public func acquire() -> Object? {
            guard let u = borrow() else { endBorrow(); return nil }
            let object = u.takeUnretainedValue()
            endBorrow()
            return object
        }
    }
}
