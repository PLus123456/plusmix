// 输出之间的"跟随"（W5-I，prompt 95；01a K4 / K9 / K10 / L9）——都在 App 层，契约不改，标记放 OutputSettings.extra（"各输出会话放自己的附加项"，
// 同 NDI 的 ndi.groups / ndi.conversion），节目文件里带着，API / headless 不认也不受影响：
// - 录制路"参与录制"（app.record.armed，缺 = 参与）：底栏"录制"只起参与的路；ISO 表里 PGM 那一行取消 = 只录 ISO（K4 / K9）。
// - 录制格式共用（K10）：录制 1（第一个来源 = PGM 的录制输出，ISORoutes.programRecord）的编码 = ISO 路的编码；录制页的"文件"一节（目录、文件名模板、
//   片段间隔、文件格式）= 全部录制路共用。跟随录制 1 编码的路 = 来源是某路输入的录制输出（ISO 路），除非标了 app.record.ownFormat（录制页里自己定格式的路）。
//   不在录的路马上跟；在录的路不动（运行中的录制器不吃新设置），停了再跟——"在录的下次起录生效"。
// - 推流"与推流 1 相同"（L9，app.stream.followFirst）：第 2 个起新建的目的地默认跟，可取消；跟的路编码（video / audio）= 推流 1 的；
//   在推的路不动，停了再跟。重连最长间隔、地址、密钥不跟。
// 谁来跟：PanelCoordinator 每个快照调一次 `OutputLinkageSync.commands(for:)`，发 setOutputSettings。只在录制 1 / 推流 1 变了的时候跟（见类注释），
// 新建 / 勾上跟随的那一刻由设置页抄一次。
import Foundation
import SwitcherContracts

@MainActor
enum OutputLinkage {
    static let armedKey = "app.record.armed"
    static let ownFormatKey = "app.record.ownFormat"
    static let streamFollowKey = "app.stream.followFirst"

    private static func flag(_ o: OutputState, _ key: String) -> Bool? {
        if case .bool(let b)? = o.settings.extra[key] { return b }
        return nil
    }

    // MARK: 录制

    /// 录制 1：第一个来源 = PGM 的录制输出（录制页的"格式"一节、ISO 表的 PGM 行都是它）。
    static func recordMaster(in state: MixerState) -> OutputState? { ISORoutes.programRecord(in: state) }

    /// 按底栏"录制"时这一路录不录（缺 = 录）。
    static func isArmed(_ o: OutputState) -> Bool { flag(o, armedKey) ?? true }

    /// 底栏"录制"要起的路：参与的录制输出。
    static func armedRecords(in state: MixerState) -> [OutputState] { state.outputs.filter { $0.kind == .record && isArmed($0) } }

    /// 这一路的编码跟录制 1：来源是某路输入、没标"自己的格式"、又不是录制 1 本身。
    static func followsRecordMaster(_ o: OutputState, in state: MixerState) -> Bool {
        guard o.kind == .record, o.settings.source.inputNumber != nil, flag(o, ownFormatKey) != true else { return false }
        return recordMaster(in: state)?.number != o.number
    }

    /// 跟录制 1 的"文件"一节：录制 1 的 RecordSettings，文件名模板补上 {output}（同一秒起的几路文件名不撞）。
    static func sharedRecordFile(from master: OutputState) -> RecordSettings? {
        guard var r = master.settings.record else { return nil }
        if !r.fileNamePattern.contains("{output}") { r.fileNamePattern += "-{output}" }
        return r
    }

    /// 一路录制输出该是什么样（录制 1 本身、没有录制 1 = nil，不动）。
    static func expectedRecordSettings(_ o: OutputState, in state: MixerState) -> OutputSettings? {
        guard o.kind == .record, let master = recordMaster(in: state), master.number != o.number else { return nil }
        var s = o.settings
        if let file = sharedRecordFile(from: master) { s.record = file }
        if followsRecordMaster(o, in: state) {
            s.video = master.settings.video
            s.audio = master.settings.audio
        }
        return s
    }

    // MARK: 推流

    /// 推流 1：编号最小的推流目的地。
    static func streamLeader(in state: MixerState) -> OutputState? { state.outputs.first { $0.kind == .stream } }

    /// 这一路勾着"与推流 1 相同"（推流 1 自己不算）。
    static func followsFirstStream(_ o: OutputState, in state: MixerState) -> Bool {
        guard o.kind == .stream, flag(o, streamFollowKey) == true else { return false }
        return streamLeader(in: state)?.number != o.number
    }

    static func expectedStreamSettings(_ o: OutputState, in state: MixerState) -> OutputSettings? {
        guard followsFirstStream(o, in: state), let leader = streamLeader(in: state) else { return nil }
        var s = o.settings
        s.video = leader.settings.video
        s.audio = leader.settings.audio
        return s
    }

    // MARK: 同步

    /// 这一路该跟成什么（不跟 / 已经一样 = nil）。
    static func expectedSettings(_ o: OutputState, in state: MixerState) -> OutputSettings? {
        let expected: OutputSettings? = switch o.kind {
        case .record: expectedRecordSettings(o, in: state)
        case .stream: expectedStreamSettings(o, in: state)
        default: nil
        }
        return expected == o.settings ? nil : expected
    }

    /// 在录 / 在推、和录制 1 / 推流 1 对不上的路（停了才会跟上；页上提示用）。
    static func deferred(in state: MixerState) -> [OutputState] {
        state.outputs.filter { $0.enabled && expectedSettings($0, in: state) != nil }
    }
}

/// 跟随的执行者（PanelCoordinator 持有，每个快照调一次）。只在录制 1 / 推流 1 的设置**变了**的时候跟——打开一个各路设置本来就不一样的老节目不会被悄悄改写；
/// 同一个快照里跟随的那一路自己也变了（API 直接改它、loadShow 整个换掉）就不碰它。在录 / 在推的路记下来，停了再跟。
@MainActor
final class OutputLinkageSync {
    private var previous: [Int: OutputState] = [:]
    private var hasBaseline = false
    /// 等它停下来再跟的路。
    private(set) var deferred: Set<Int> = []

    /// 换 session：下一个快照只当基准。
    func reset() {
        previous.removeAll()
        hasBaseline = false
        deferred.removeAll()
    }

    func commands(for state: MixerState) -> [Command] {
        defer {
            previous = Dictionary(state.outputs.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
            hasBaseline = true
        }
        guard hasBaseline else { return [] }
        // 录制 1 的编码 / 文件变了 → 其余录制路
        if let m = OutputLinkage.recordMaster(in: state), let pm = previous[m.number], pm.kind == .record, pm.settings.source == .program,
           pm.settings.video != m.settings.video || pm.settings.audio != m.settings.audio || pm.settings.record != m.settings.record {
            markFollowers(in: state, kind: .record, leader: m.number)
        }
        // 推流 1 的编码变了 → 勾着"与推流 1 相同"的目的地
        if let l = OutputLinkage.streamLeader(in: state), let pl = previous[l.number], pl.kind == .stream,
           pl.settings.video != l.settings.video || pl.settings.audio != l.settings.audio {
            markFollowers(in: state, kind: .stream, leader: l.number)
        }
        var out: [Command] = []
        for n in deferred.sorted() {
            guard let o = state.output(n) else { deferred.remove(n); continue }
            guard !o.enabled else { continue }   // 还在录 / 在推：等它停
            deferred.remove(n)
            if let expected = OutputLinkage.expectedSettings(o, in: state) { out.append(.setOutputSettings(output: n, settings: expected)) }
        }
        return out
    }

    private func markFollowers(in state: MixerState, kind: OutputKind, leader: Int) {
        for o in state.outputs where o.kind == kind && o.number != leader {
            if let po = previous[o.number], po.settings != o.settings { continue }   // 同一个快照里它自己也被改了：不碰
            if OutputLinkage.expectedSettings(o, in: state) != nil { deferred.insert(o.number) }
        }
    }
}
