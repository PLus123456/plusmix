// 输出设置窗（W3-E 交付第 3 条）：录制（格式、码率、关键帧间隔、目录、停止后转 MP4）、ISO 路选择、推流目的地列表
// （RTMP / RTMPS / SRT、地址、密钥、每路编码参数）、外部输出、NDI 发送、虚拟摄像头开关与安装状态、多画面布局（W3-E2）。
// 全部落在 MixerState.outputs（addOutput / removeOutput / setOutputSettings；非录制 / 推流输出的开关与改名走提案 012 的
// setOutputEnabled / renameOutput）；ISO = 一路 source = .input(n) 的录制输出（契约："ISO = 同一拍发多条 startRecord"；W3-C 做同拍起步）。
// 外部显示的显示器与"退回主屏"只写正式字段 OutputSettings.display（提案 013 / 015），显示类输出的状态读 Stats.display[]。
// W5-B：推流页在推的那一段（目标开着、没起不来）地址 / 密钥 / 编码锁住、"删除目的地"灰掉（X05 / X24，同 ISO 页录着的路）；地址 / 密钥回车或失焦才提交；
// 起不来的那一段写明原因、不锁（要能改对地址，改对后运行表自动重试），给"重试"与"停用这一路"；录制页"容器"与"停止后转 MP4"合成一个"文件格式"单选，
// 只写 remuxToMP4、不写 container（照读，04 Q12 (a)）；录着的时候页顶提示"改动从下一次开录起生效"（K6）。
// W5-I（prompt 95）：最上面加"输出总览"（F8）；录制页改成录制输出列表（K4）、ISO 页改成表（K9）、推流页加起停 / 状态行 / 服务 / 质量 / 鉴权 / 合计上行
// （L3 / L5–L10）、外部显示页改成每屏单选（M2 / M5）、多画面布局页加格子编辑（M7）、每一节标题行加名字框（F9）。各页的逻辑在 OutputPagesModel.swift，
// 视图在 OutputPagesViews.swift，跟随规则在 OutputLinkage.swift。
import AppKit
import SwiftUI
import SwitcherContracts
import SwitcherExternal
import SwitcherRender
import SwitcherVirtualCamera

@MainActor
final class OutputSettingsModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case overview, record, iso, stream, external, ndi, virtualCamera, multiview
        var id: String { rawValue }
        var title: String { L("outputSettings.tab.\(rawValue)") }
    }

    @Published var tab: Tab
    @Published private(set) var state: MixerState
    /// 虚拟摄像头扩展的安装状态（W3-C 的 SystemExtensionInstaller，与输出菜单同一个对象）。
    @Published private(set) var virtualCameraStatus: String = ""
    /// 最近一行 Stats 的 display[]（提案 013：外部显示 / 虚拟摄像头的状态与帧数都读它）。
    @Published private(set) var displayStats: [Stats.DisplayEntry] = []
    /// 最近一行 Stats 的 encoder[]（NDI 发送的状态与帧数读它；每项带输出编号 `output`，按它对号——提案 019）。
    @Published private(set) var encoderStats: [Stats.EncoderEntry] = []
    /// 起不来的录制 / 推流 → 原因；推流正在第几次连接（运行表，refreshRouteDetails 时取；W5-B）。
    @Published private(set) var failures: [Int: String] = [:]
    @Published private(set) var attempts: [Int: Int] = [:]
    var send: ((Command) -> Void)?
    /// 一路起不来的原因 + 推流正在第几次连接（PanelCoordinator 接到 session 的运行表）。
    var routeDetail: ((Int) -> (failure: String?, attempt: Int?))?
    /// 重试起不来的那几路（session.retryFailedOutputs）。
    var onRetry: (([Int]) -> Void)?
    /// 新建录制输出的默认目录。
    let defaultRecordDirectory: String
    /// 节目名（示例文件名用）。
    var showName: String
    /// 虚拟摄像头扩展的安装器：App 里只有 session 的那一个（AuxOutputRuntime.installer）；没有 session 为 nil。
    private let installer: SystemExtensionInstaller?
    private var extensionToken: ObserverToken?
    /// 测试宿主不去问系统扩展（没有扩展包，只会报错）。
    let queriesSystemExtensions: Bool
    /// ISO 页估算"还能录多久"时留出的磁盘余量（= 录制的下限，AppSettings.recordMinimumFreeMB）。
    let reserveBytes: UInt64
    /// 推流页每一路在"服务"下拉里刚选过的服务 id（每场发地址的平台从地址认不出来；只在窗口开着时记，节目里只存地址）。
    @Published var chosenServices: [Int: String] = [:]
    /// 推流页展开了"编码详情…"的目的地。
    @Published var expandedEncodeDetails: Set<Int> = []
    /// ISO 表列出纯音频 / 图片输入（默认收起）。
    @Published var isoShowAllInputs = false
    /// 总览里点的那一路（详情页滚到它）。
    @Published var focusedOutput: Int?
    /// 停录制 / 推流前问一声（PanelCoordinator 接到 ConfirmationCenter，挂在输出设置窗上）；nil = 直接停（模型级测试）。
    var confirmStop: ((ConfirmationCenter.Kind, [OutputState], @escaping @MainActor () -> Void) -> Void)?
    /// 接着的显示器（外部显示页的每屏单选；测试可换）。
    var displays: () -> [DisplayInfo] = { ExternalDisplays.all() }

    init(state: MixerState, tab: Tab, defaultRecordDirectory: String, showName: String, queriesSystemExtensions: Bool, reserveBytes: UInt64 = 0,
         aux: AuxOutputRuntime? = nil) {
        self.state = state
        self.tab = tab
        self.defaultRecordDirectory = defaultRecordDirectory
        self.showName = showName
        self.queriesSystemExtensions = queriesSystemExtensions
        self.reserveBytes = reserveBytes
        installer = aux?.installer
        virtualCameraStatus = OutputStatusText.extensionStatus(installer?.status ?? .unknown)
        extensionToken = aux?.observeExtensionStatus { [weak self] s in self?.virtualCameraStatus = OutputStatusText.extensionStatus(s) }
    }

    func apply(state: MixerState) {
        self.state = state
        refreshRouteDetails()
    }

    func apply(stats: Stats) {
        if stats.display != displayStats { displayStats = stats.display }
        if stats.encoder != encoderStats { encoderStats = stats.encoder }
        refreshRouteDetails()
    }

    /// 重新取一遍录制 / 推流各路起不来的原因与连接次数（快照 / Stats 来的时候，或点了重试之后）。
    func refreshRouteDetails() {
        var f: [Int: String] = [:], a: [Int: Int] = [:]
        for o in state.outputs where o.kind == .record || o.kind == .stream {
            guard let d = routeDetail?(o.number) else { continue }
            if let failure = d.failure { f[o.number] = failure }
            if let attempt = d.attempt { a[o.number] = attempt }
        }
        if f != failures { failures = f }
        if a != attempts { attempts = a }
    }

    /// 扩展的 bundle ID（安装器用的那个）。
    var extensionIdentifier: String { installer?.extensionIdentifier ?? VirtualCameraConstants.extensionBundleIdentifier }

    /// 某个显示类输出在 Stats.display[] 里的一行（没有为 nil）。
    func displayStatus(output number: Int, kind: String) -> String? {
        displayStats.first { $0.output == number && $0.kind == kind }.map(OutputStatusText.display)
    }

    /// 虚拟摄像头输出的一行（Stats.display[]）。
    var virtualCameraOutputStatus: String {
        let output = state.outputs.first { $0.kind == .virtualCamera && $0.enabled }
        let entry = output.flatMap { o in displayStats.first { $0.kind == "virtualCamera" && $0.output == o.number } }
        return OutputStatusText.virtualCamera(enabled: output != nil, entry: entry)
    }

    static let videoCodecs: [VideoCodec] = [.h264, .hevc, .prores422, .prores422HQ, .prores4444]
    static let audioCodecs: [AudioCodec] = [.aac, .pcm]
    static let resolutionPresets: [(title: String, width: Int?, height: Int?)] = [
        (L("outputSettings.resolution.program"), nil, nil), ("1920×1080", 1920, 1080), ("1280×720", 1280, 720), ("3840×2160", 3840, 2160), ("854×480", 854, 480),
    ]

    func nextOutputNumber() -> Int { (state.outputs.map(\.number).max() ?? 0) + 1 }

    /// 改开关（提案 012 的 setOutputEnabled）：本地先改，再发命令。record / stream 走 startRecord / startStream，被 reducer 拒。
    func setOutputEnabled(_ number: Int, on: Bool) {
        guard let i = state.outputs.firstIndex(where: { $0.number == number }), state.outputs[i].enabled != on else { return }
        state.outputs[i].enabled = on
        send?(.setOutputEnabled(output: number, on: on))
    }

    /// 改设置：本地先改（表单立刻响应），再发 setOutputSettings。在推的推流目的地锁着，不改（W5-B）。
    func updateOutput(_ number: Int, _ body: (inout OutputSettings) -> Void) {
        guard !isStreamLocked(number), let i = state.outputs.firstIndex(where: { $0.number == number }) else { return }
        var settings = state.outputs[i].settings
        body(&settings)
        guard settings != state.outputs[i].settings else { return }
        state.outputs[i].settings = settings
        send?(.setOutputSettings(output: number, settings: settings))
    }

    /// 删掉一个输出；在推的推流目的地锁着，不删（W5-B，X05：原来一点就断流）。
    func removeOutput(_ number: Int) {
        guard !isStreamLocked(number) else { return }
        state.outputs.removeAll { $0.number == number }
        send?(.removeOutput(output: number))
    }

    /// 改名（提案 012 的 renameOutput）：不再删了重加，运行表不会看到"消失 → 再出现"。
    func rename(_ number: Int, _ name: String) {
        guard let i = state.outputs.firstIndex(where: { $0.number == number }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != state.outputs[i].name else { return }
        state.outputs[i].name = trimmed
        send?(.renameOutput(output: number, name: trimmed))
    }

    /// 一条命令先在本地状态上照做（表单立刻响应），快照回来再对齐（外部显示页每屏单选一次发好几条）。
    func applyLocally(_ c: Command) {
        switch c {
        case .addOutput(let config): state.outputs.append(config); state.outputs.sort { $0.number < $1.number }
        case .setOutputSettings(let n, let settings): if let i = state.outputs.firstIndex(where: { $0.number == n }) { state.outputs[i].settings = settings }
        case .setOutputEnabled(let n, let on): if let i = state.outputs.firstIndex(where: { $0.number == n }) { state.outputs[i].enabled = on }
        case .renameOutput(let n, let name): if let i = state.outputs.firstIndex(where: { $0.number == n }) { state.outputs[i].name = name }
        default: break
        }
    }

    /// 加一个输出：本地先加，再发 addOutput。
    func addOutputConfig(_ output: OutputState) {
        state.outputs.append(output)
        state.outputs.sort { $0.number < $1.number }
        send?(.addOutput(config: output))
    }

    // MARK: 录制（PGM 那一路）

    var recordOutput: OutputState? { state.outputs.first { $0.kind == .record && $0.settings.source == .program } }

    /// 没有录制输出就先加一个默认的（同底栏"录制"按钮）。
    func updateRecord(_ body: (inout OutputSettings) -> Void) {
        if recordOutput == nil {
            // 新建录制输出的默认值跟节目格式走（K8 / Q30）
            addOutputConfig(RecordDefaults.output(number: nextOutputNumber(), name: L("show.defaultRecordName"), format: state.format, directory: defaultRecordDirectory))
        }
        guard let r = recordOutput else { return }
        updateOutput(r.number) { s in
            if s.video == nil { s.video = VideoEncodeSettings() }
            if s.audio == nil { s.audio = AudioEncodeSettings() }
            if s.record == nil { s.record = RecordSettings(directory: self.defaultRecordDirectory) }
            body(&s)
        }
    }

    /// 录制表单的绑定（读当前录制输出，没有就默认值）。
    func recordBinding<T>(_ keyPath: WritableKeyPath<OutputSettings, T>, default defaultValue: T) -> Binding<T> {
        Binding(get: { self.recordOutput?.settings[keyPath: keyPath] ?? defaultValue }, set: { v in self.updateRecord { $0[keyPath: keyPath] = v } })
    }

    /// 录制的"文件格式"（K5 / X14，04 Q12 (a)）："容器"与"停止后转 MP4"合成一个单选，只写 remuxToMP4。
    /// RecordSettings.container 运行时从来不读（文件一律 .mov），这里照读不写；旧节目文件里写着 .mp4 的，页上说一句它不起作用。
    enum RecordFileFormat: String, CaseIterable, Identifiable {
        /// .mov，边录边存片段（崩溃可恢复）。
        case mov
        /// .mov，停止后转封装成 .mp4（失败保留 .mov）。
        case movThenMP4
        var id: String { rawValue }
        var title: String { L("outputSettings.record.fileFormat.\(rawValue)") }
    }

    var recordFileFormat: RecordFileFormat {
        get { recordOutput?.settings.record?.remuxToMP4 == true ? .movThenMP4 : .mov }
        set { updateRecord { $0.record?.remuxToMP4 = newValue == .movThenMP4 } }
    }

    /// 节目文件里 container 写着 .mp4、又没开"停止后转 .mp4"：照读不写，提示它不起作用（开了转 .mp4 就不用说了）。
    var recordLegacyContainerNote: String? {
        guard let record = recordOutput?.settings.record, record.container == .mp4, !record.remuxToMP4 else { return nil }
        return L("outputSettings.record.legacyContainerNote")
    }

    /// 录着的时候：改动从下一次开录起生效（K6；运行中的录制器不跟着改）。
    var recordLiveNote: String? {
        state.outputs.contains { $0.kind == .record && $0.enabled } ? L("outputSettings.record.liveNote") : nil
    }

    /// 示例文件名。
    var recordExampleFileName: String {
        guard let r = recordOutput, let record = r.settings.record else { return "" }
        return record.outputURL(showName: showName, outputName: r.name).lastPathComponent
    }

    // MARK: ISO（ISO 只有这一个入口：底栏"ISO…"打开的就是这一页，W3-E2 交付第 4 条）

    /// 已选 ISO 的输入编号。
    var isoInputs: Set<Int> {
        Set(state.outputs.compactMap { o -> Int? in
            guard o.kind == .record, case .input(let n) = o.settings.source else { return nil }
            return n
        })
    }

    /// 开 = 按 W3-C 的 ISORoutes 加一路（编码 / 目录抄 PGM 录制输出，文件名模板带 {output}）；关 = 删。录着的路锁住，不在这里删。
    func setISO(input: Int, on: Bool) {
        let existing = ISORoutes.isoRecord(in: state, input: input)
        if on {
            guard existing == nil, let config = state.input(input) else { return }
            var output = ISORoutes.makeISOOutput(for: config, in: state, defaultDirectory: defaultRecordDirectory)
            output.number = nextOutputNumber()
            addOutputConfig(output)
        } else if let existing, !existing.enabled {
            removeOutput(existing.number)
        }
    }

    /// 这路的 ISO 正在录（开关锁住）。
    func isoLocked(input: Int) -> Bool { ISORoutes.isoRecord(in: state, input: input)?.enabled ?? false }

    /// 开关旁的说明："→ ISO 3（录制中）"。
    func isoRouteText(input: Int) -> String {
        guard let iso = ISORoutes.isoRecord(in: state, input: input) else { return "" }
        return iso.enabled ? L("outputSettings.iso.routeRecording", iso.name) : L("outputSettings.iso.route", iso.name)
    }

    /// 录制目录、剩余空间、按全部录制输出码率估的"还能录多久"。
    var isoEstimateText: String {
        ISORoutes.estimateText(state: state, defaultDirectory: defaultRecordDirectory, reserveBytes: reserveBytes)
    }

    // MARK: 推流

    var streamOutputs: [OutputState] { state.outputs.filter { $0.kind == .stream } }

    /// 加一个目的地：质量按默认档（封顶 1080p、关键帧 2 s 按节目帧率写帧数，Q30），第 2 个起"与推流 1 相同"（L9）。
    @discardableResult
    func addStream(url: String, key: String) -> Int {
        let n = nextOutputNumber()
        addOutputConfig(OutputState(number: n, kind: .stream, name: L("outputSettings.stream.name", streamOutputs.count + 1), enabled: false,
                                    settings: newStreamSettings(url: url, key: key)))
        return n
    }

    func outputBinding<T>(_ number: Int, _ keyPath: WritableKeyPath<OutputSettings, T>, default defaultValue: T) -> Binding<T> {
        Binding(get: { self.state.output(number)?.settings[keyPath: keyPath] ?? defaultValue }, set: { v in self.updateOutput(number) { $0[keyPath: keyPath] = v } })
    }

    /// 在推的推流目的地（目标开着、没起不来）：地址 / 密钥 / 编码锁住、不能删（W5-B，L12 / X05 / X24）。起不来的那一路不锁——要能把地址改对。
    func isStreamLocked(_ number: Int) -> Bool {
        guard let o = state.output(number), o.kind == .stream else { return false }
        return o.enabled && failures[number] == nil
    }

    /// 锁着时那一段的说明；没锁为 nil。
    func streamLockNote(_ number: Int) -> String? { isStreamLocked(number) ? L("outputSettings.stream.lockedNote") : nil }

    /// 地址 / 密钥（回车或失焦时提交，不再每按一个键发一次 setOutputSettings；W5-B，L12）。
    func commitStreamAddress(_ number: Int, url: String, key: String) {
        updateOutput(number) { s in
            var stream = s.stream ?? StreamSettings(url: "")
            stream.url = url
            stream.streamKey = key
            s.stream = stream
        }
    }

    /// 推流页那一段的状态行：起不来写原因；其余与底栏同一套文字（Stats.encoder 的 state + 正在第几次连接）。
    func streamStatus(output number: Int) -> String {
        guard let o = state.output(number) else { return "" }
        if o.enabled, let failure = failures[number] { return L("outputSettings.stream.statusFailed", failure) }
        let entry = OutputRuntime.encoderEntry(encoderStats, forOutput: number)
        let route = OutputRouteStatus(number: number, name: o.name, enabled: o.enabled, state: entry?.state, frames: entry?.frames ?? 0, attempt: attempts[number])
        return OutputButtonSummary.routeState(route, kind: .stream).text
    }

    /// 重试起不来的这一路。
    func retryStream(_ number: Int) {
        onRetry?([number])
        refreshRouteDetails()
    }

    /// 停用这一路（目标关掉：起不来的那一路不再算在跑，底栏主体又能停其余的）。
    func disableStream(_ number: Int) { send?(.stopStream(output: number)) }

    // MARK: 外部显示

    var externalOutputs: [OutputState] { state.outputs.filter { $0.kind == .externalDisplay } }

    @discardableResult
    func addExternalDisplay(screenNumber: UInt32, source: OutputSource) -> Int {
        let n = nextOutputNumber()
        let screenName = NSScreen.screen(number: screenNumber)?.localizedName ?? "\(screenNumber)"
        // fallbackToMain 用默认（提案 015 起默认 false = 显示器不在就收起窗口等它回来）；要退回主屏在页上打开
        addOutputConfig(OutputState(number: n, kind: .externalDisplay, name: L("outputSettings.external.name", screenName), enabled: true,
                        settings: OutputSettings(source: source, display: DisplayOutputSettings(displayID: screenNumber))))
        return n
    }

    /// 改显示器 / 来源：只写正式字段 `OutputSettings.display`（提案 013），只改要改的那一项。状态机里的状态不会带输出的过渡键
    /// （P4 起 addOutput / setOutputSettings / loadShow 进 reducer 时都先按 Show.load 同一套规则搬迁），这里不用再搬（W3-E4 删了多余的调用）。
    func setExternalDisplay(_ number: Int, screenNumber: UInt32?, source: OutputSource?) {
        updateOutput(number) { s in
            if let screenNumber {
                var d = s.display ?? DisplayOutputSettings()
                d.displayID = screenNumber
                s.display = d
            }
            if let source { s.source = source }
        }
    }

    /// 显示器不在时退回主屏（true）还是黑着等它回来（false，默认）。
    func setExternalFallback(_ number: Int, on: Bool) {
        updateOutput(number) { s in
            var d = s.display ?? DisplayOutputSettings()
            d.fallbackToMain = on
            s.display = d
        }
    }

    /// 显示器下拉的选项：接着的每块屏 + 当前设的那块（拔掉了也列出来，免得选中项凭空消失）。
    func screenChoices(including current: UInt32?) -> [(id: UInt32, title: String)] {
        var out = NSScreen.screens.compactMap { s in s.displayNumber.map { (id: $0, title: s.displayTitle) } }
        if let current, !out.contains(where: { $0.id == current }) { out.append((current, L("outputSettings.external.missingScreen", current))) }
        return out
    }

    // MARK: NDI 发送

    var ndiOutputs: [OutputState] { state.outputs.filter { $0.kind == .ndi } }

    @discardableResult
    func addNDI(name: String, groups: String, conversion: String, source: OutputSource) -> Int {
        let n = nextOutputNumber()
        var extra: [String: JSONValue] = [OutputExtras.ndiConversion: .string(conversion)]
        if !groups.isEmpty { extra[OutputExtras.ndiGroups] = .string(groups) }
        addOutputConfig(OutputState(number: n, kind: .ndi, name: name, enabled: true, settings: OutputSettings(source: source, extra: extra)))
        return n
    }

    /// 改分组 / 转换方式 / 来源（setOutputSettings）。运行表（OutputRuntime）按新设置重建 sender（分组 / 来源）或运行时切换（转换方式）；
    /// 名字 = 输出名，走 rename（renameOutput）；开关走 setOutputEnabled。
    func setNDI(_ number: Int, groups: String? = nil, conversion: String? = nil, source: OutputSource? = nil) {
        updateOutput(number) { s in
            if let groups { s.extra[OutputExtras.ndiGroups] = groups.isEmpty ? nil : .string(groups) }
            if let conversion { s.extra[OutputExtras.ndiConversion] = .string(conversion) }
            if let source { s.source = source }
        }
    }

    /// 一路 NDI 发送的状态行：只读 Stats.encoder 里它那一项（铁律 4）。
    func ndiStatus(output number: Int) -> String {
        let entry = OutputRuntime.encoderEntry(encoderStats, forOutput: number)
        return OutputStatusText.ndi(enabled: state.output(number)?.enabled ?? false, entry: entry)
    }

    // MARK: 虚拟摄像头

    var virtualCameraOutput: OutputState? { state.outputs.first { $0.kind == .virtualCamera } }

    /// 开关（setOutputEnabled）；没有虚拟摄像头输出就加一个 source = PGM 的。来源不可选（W3-E4，issue W3E3-virtual-camera-source-picker-ignored 选 2）：
    /// VirtualCameraOutput 只发 PGM 帧（设计方案 §2 / §3：PGM 那块 IOSurface 同时交给编码器 / NDI / 虚拟摄像头 / 录制器），
    /// 已存节目里带别的 source 的虚拟摄像头输出照样当 PGM——这里不动它的 source、也不报错。
    func setVirtualCamera(enabled: Bool) {
        if let o = virtualCameraOutput {
            setOutputEnabled(o.number, on: enabled)
        } else {
            addOutputConfig(OutputState(number: nextOutputNumber(), kind: .virtualCamera, name: L("outputSettings.vcam.name"), enabled: enabled, settings: OutputSettings(source: .program)))
        }
    }

    func refreshVirtualCameraStatus() {
        guard queriesSystemExtensions else { virtualCameraStatus = L("vcam.status.unavailableInTests"); return }
        installer?.refresh()
    }
    func installVirtualCamera() {
        guard queriesSystemExtensions else { return }
        installer?.activate()
    }
    func uninstallVirtualCamera() {
        guard queriesSystemExtensions else { return }
        installer?.deactivate()
    }

    /// 输出来源选项：PGM / PVW / 多画面 / 每路输入。
    var sourceChoices: [OutputSource] { [.program, .preview, .multiview] + state.inputs.map { .input(number: $0.number) } }

    /// 来源下面的说明：选某路输入（Aux）= 该路原始画面，抠像 / 裁切 / 变换不生效（外部显示由本包自己画该路帧，NDI 从该路帧槽分支取帧）；其他来源没有说明。
    func sourceNote(for source: OutputSource) -> String? {
        source.inputNumber == nil ? nil : L("aux.rawPictureNote")
    }

    // MARK: 多画面布局（提案 010：OutputSettings.multiview）

    /// 承载布局的输出：渲染器取第一个 kind = multiview 的输出的布局（不看 enabled）。
    var multiviewOutput: OutputState? { state.outputs.first { $0.kind == .multiview } }

    /// 当前布局（没有多画面输出 = 默认布局）。
    var multiviewLayout: MultiviewLayoutSettings { multiviewOutput?.settings.multiview ?? MultiviewLayoutSettings() }

    /// 改布局：有多画面输出就改它的 settings.multiview（setOutputSettings），没有就加一个只承载布局的——source = multiview、enabled = false
    /// （enabled 且 source = multiview 会让渲染器每拍多转一次 NV12 给下游，App 里没有这个下游；布局本身不看 enabled）。
    func updateMultiview(_ body: (inout MultiviewLayoutSettings) -> Void) {
        var layout = multiviewLayout
        body(&layout)
        if let o = multiviewOutput {
            updateOutput(o.number) { $0.multiview = layout }
        } else {
            addOutputConfig(OutputState(number: nextOutputNumber(), kind: .multiview, name: L("outputSettings.multiview.name"), enabled: false,
                            settings: OutputSettings(source: .multiview, multiview: layout)))
        }
    }

    func setMultiviewPreset(_ preset: String) { updateMultiview { $0.preset = preset } }
    func setMultiviewSafeArea(_ on: Bool) { updateMultiview { $0.safeArea = on } }
    func setMultiviewMeters(_ on: Bool) { updateMultiview { $0.meters = on } }
    /// 清掉自定义格子（回到预设）。格子本身不在这里编辑（prompt 63：只读展示，不做编辑器）。
    func clearMultiviewCustomCells() { updateMultiview { $0.custom = [] } }

    /// 自定义格子的只读列表：来源 + 位置。
    var customCellRows: [(source: String, rect: String)] {
        multiviewLayout.custom.map { c in
            let r = c.rect
            return (c.source.title(in: state), String(format: "x %.3f  y %.3f  w %.3f  h %.3f", r.x, r.y, r.width, r.height))
        }
    }
}

struct OutputSettingsView: View {
    @ObservedObject var model: OutputSettingsModel
    @State private var newNDIName = "PlusMix"   // App 侧的 NDI 源默认名用产品名（W4-D）；包内默认值不动

    var body: some View {
        HStack(spacing: 0) {
            List(OutputSettingsModel.Tab.allCases, selection: tabSelection) { t in Text(t.title).tag(t) }
                .listStyle(.sidebar)
                .frame(width: 150)
                .accessibilityLabel(L("outputSettings.tabList"))
            Divider()
            Form { tabBody }.formStyle(.grouped)
        }
    }

    private var tabSelection: Binding<OutputSettingsModel.Tab?> {
        Binding(get: { model.tab }, set: { if let t = $0 { model.tab = t } })
    }

    @ViewBuilder
    private var tabBody: some View {
        switch model.tab {
        case .overview: OutputOverviewPage(model: model)
        case .record: RecordPage(model: model)
        case .iso: ISOPage(model: model)
        case .stream: StreamPage(model: model)
        case .external: ExternalDisplayPage(model: model)
        case .ndi: ndiTab
        case .virtualCamera: virtualCameraTab
        case .multiview: MultiviewPage(model: model)
        }
    }

    // MARK: 编码表单的绑定与控件（录制页 / 推流页共用）

    static func video(of number: Int, in model: OutputSettingsModel) -> Binding<VideoEncodeSettings> {
        model.outputBinding(number, \.video, default: nil).map(get: { $0 ?? VideoEncodeSettings() }, set: { Optional($0) })
    }
    static func audio(of number: Int, in model: OutputSettingsModel) -> Binding<AudioEncodeSettings> {
        model.outputBinding(number, \.audio, default: nil).map(get: { $0 ?? AudioEncodeSettings() }, set: { Optional($0) })
    }
    static func stream(of number: Int, in model: OutputSettingsModel) -> Binding<StreamSettings> {
        model.outputBinding(number, \.stream, default: nil).map(get: { $0 ?? StreamSettings(url: "") }, set: { Optional($0) })
    }

    static func resolutionPicker(_ video: Binding<VideoEncodeSettings>) -> some View {
        let v = video.wrappedValue
        let index = OutputSettingsModel.resolutionPresets.firstIndex { $0.width == v.width && $0.height == v.height } ?? 0
        return Picker(L("outputSettings.resolution"), selection: Binding(get: { index }, set: { i in
            let p = OutputSettingsModel.resolutionPresets[max(0, min(i, OutputSettingsModel.resolutionPresets.count - 1))]
            var nv = video.wrappedValue
            nv.width = p.width
            nv.height = p.height
            video.wrappedValue = nv
        })) {
            ForEach(Array(OutputSettingsModel.resolutionPresets.enumerated()), id: \.offset) { i, p in Text(p.title).tag(i) }
        }
    }

    static func bitrateField(_ video: Binding<VideoEncodeSettings>) -> some View {
        TextField(L("outputSettings.bitrateKbps"), value: Binding(get: { video.wrappedValue.bitrateBps / 1000 }, set: { kbps in
            var nv = video.wrappedValue
            nv.bitrateBps = max(100, kbps) * 1000
            video.wrappedValue = nv
        }), format: .number)
    }

    static func audioBitrateField(_ audio: Binding<AudioEncodeSettings>) -> some View {
        TextField(L("outputSettings.audioBitrateKbps"), value: Binding(get: { audio.wrappedValue.bitrateBps / 1000 }, set: { kbps in
            var na = audio.wrappedValue
            na.bitrateBps = max(32, kbps) * 1000
            audio.wrappedValue = na
        }), format: .number)
    }

    // MARK: NDI

    private var ndiTab: some View {
        Group {
            ForEach(model.ndiOutputs) { output in
                NDIOutputSection(model: model, output: output)
            }
            Section(L("outputSettings.ndi.add")) {
                TextField(L("outputSettings.ndi.name"), text: $newNDIName)
                Button(L("outputSettings.ndi.addButton")) {
                    guard !newNDIName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    model.addNDI(name: newNDIName.trimmingCharacters(in: .whitespaces), groups: "", conversion: "auto", source: .program)
                }
                Text(L("outputSettings.ndi.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 虚拟摄像头

    private var virtualCameraTab: some View {
        Section {
            Toggle(L("outputSettings.vcam.enabled"), isOn: Binding(get: { model.virtualCameraOutput?.enabled ?? false }, set: { model.setVirtualCamera(enabled: $0) }))
            // 来源不可选：固定送 PGM（W3-E4；设计方案 §2 / §3 的数据流）
            LabeledContent(L("outputSettings.source"), value: L("source.program"))
            Text(L("outputSettings.vcam.sourceNote")).font(.caption).foregroundStyle(.secondary)
            LabeledContent(L("outputSettings.vcam.outputStatus"), value: model.virtualCameraOutputStatus)
            LabeledContent(L("outputSettings.vcam.status"), value: model.virtualCameraStatus)
            HStack {
                Button(L("outputSettings.vcam.check")) { model.refreshVirtualCameraStatus() }
                Button(L("outputSettings.vcam.install")) { model.installVirtualCamera() }
                Button(L("outputSettings.vcam.uninstall")) { model.uninstallVirtualCamera() }
            }
            LabeledContent(L("outputSettings.vcam.bundleID"), value: model.extensionIdentifier)
            Text(L("outputSettings.vcam.hint")).font(.caption).foregroundStyle(.secondary)
        } header: {
            // 标题行带名字框（F9）；还没有虚拟摄像头输出时只有标题
            if let o = model.virtualCameraOutput {
                OutputSectionHeader(model: model, output: o, title: L("outputSettings.vcam.title"), subtitle: L("outputSettings.outputNumber", o.number))
            } else {
                Text(L("outputSettings.vcam.title"))
            }
        }
        .onAppear { if model.queriesSystemExtensions { model.refreshVirtualCameraStatus() } }
    }
}

/// NDI 页的一路（W3-E3：名字 / 源 / 开关生效）。名字（= 输出名 = NDI 源名）和分组定死在发送端里，改了要重建它（接收方重新选源），
/// 所以不跟着每个按键发：回车或点"应用"才发 renameOutput / setOutputSettings；来源 / 转换方式直接走 setOutputSettings（选一次改一次），
/// 开关走 setOutputEnabled。状态行只读 Stats.encoder。
struct NDIOutputSection: View {
    @ObservedObject var model: OutputSettingsModel
    let output: OutputState
    @State private var draftName: String
    @State private var draftGroups: String

    init(model: OutputSettingsModel, output: OutputState) {
        self.model = model
        self.output = output
        _draftName = State(initialValue: output.name)
        _draftGroups = State(initialValue: OutputExtras.string(output, OutputExtras.ndiGroups) ?? "")
    }

    private var savedGroups: String { OutputExtras.string(output, OutputExtras.ndiGroups) ?? "" }
    private var trimmedName: String { draftName.trimmingCharacters(in: .whitespaces) }
    private var edited: Bool { draftName != output.name || draftGroups != savedGroups }

    /// 名字 / 分组一起落：同一轮快照里两样都变了，运行表只重建一次发送端。
    private func commit() {
        if !trimmedName.isEmpty, trimmedName != output.name { model.rename(output.number, trimmedName) }
        if draftGroups != savedGroups { model.setNDI(output.number, groups: draftGroups) }
    }

    var body: some View {
        Section(L("outputSettings.ndi.section", output.number, output.name)) {
            Toggle(L("outputSettings.ndi.enabled"), isOn: Binding(get: { output.enabled }, set: { model.setOutputEnabled(output.number, on: $0) }))
            TextField(L("outputSettings.ndi.name"), text: $draftName).onSubmit(commit)
            TextField(L("outputSettings.ndi.groups"), text: $draftGroups).onSubmit(commit)
            Button(L("outputSettings.ndi.apply")) { commit() }
                .disabled(!edited || trimmedName.isEmpty)
            Picker(L("outputSettings.source"), selection: Binding(get: { output.settings.source }, set: { model.setNDI(output.number, source: $0) })) {
                ForEach(model.sourceChoices, id: \.self) { Text($0.title(in: model.state)).tag($0) }
            }
            if let note = model.sourceNote(for: output.settings.source) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Picker(L("outputSettings.ndi.conversion"), selection: Binding(get: { OutputExtras.string(output, OutputExtras.ndiConversion) ?? "auto" }, set: { model.setNDI(output.number, conversion: $0) })) {
                ForEach(OutputExtras.ndiConversions, id: \.self) { Text(L("outputSettings.ndi.conversion.\($0)")).tag($0) }
            }
            LabeledContent(L("outputSettings.ndi.status"), value: model.ndiStatus(output: output.number))
            Button(L("outputSettings.ndi.remove")) { model.removeOutput(output.number) }
        }
        .onChange(of: output.name) { _, name in draftName = name }
        .onChange(of: savedGroups) { _, groups in draftGroups = groups }
    }
}

extension Binding {
    /// 可选值 ↔ 非可选值的映射（表单里 nil 用默认值显示）。
    func map<T>(get: @escaping (Value) -> T, set: @escaping (T) -> Value) -> Binding<T> {
        Binding<T>(get: { get(self.wrappedValue) }, set: { self.wrappedValue = set($0) })
    }
}

@MainActor
final class OutputSettingsWindowController: PanelWindowController {
    let model: OutputSettingsModel

    init(model: OutputSettingsModel) {
        self.model = model
        super.init(title: L("outputSettings.windowTitle"), size: NSSize(width: 720, height: 560), autosaveName: "OutputSettings", content: OutputSettingsView(model: model))
    }

    func apply(state: MixerState) { model.apply(state: state) }
}
