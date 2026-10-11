// 输出设置窗各页的模型逻辑（W5-I，prompt 95）：输出总览（F8）、录制输出列表（K4 / K6–K8 / K10）、ISO 表（K9）、推流页（L3 / L5–L10 / L12）、
// 外部显示每屏单选（M2 / M5）、多画面格子编辑（M7）。全部只发命令（addOutput / removeOutput / setOutputSettings / renameOutput /
// setOutputEnabled / startStream / stopStream），状态与读数读快照与 Stats.encoder / Stats.display（铁律 4）。
// 跟随（ISO 跟录制 1、推流跟推流 1）的规则在 OutputLinkage；这里在新建 / 勾上跟随的那一刻抄一次，之后由 PanelCoordinator 的 OutputLinkageSync 跟。
import AppKit
import SwitcherContracts
import SwitcherExternal
import SwitcherRender
import SwitcherStreaming

extension OutputSettingsModel {
    var format: ProgramFormat { state.format }

    /// 码率写成 "18" / "4.5"（Mb/s）。
    static func mbps(_ bps: Double) -> String {
        let v = bps / 1_000_000
        return abs(v - v.rounded()) < 0.05 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }

    // MARK: 输出总览（F8）

    struct OverviewRow: Identifiable, Equatable {
        let number: Int
        let kind: OutputKind
        let kindTitle: String
        let name: String
        let source: String
        let on: Bool
        let status: String
        let tab: Tab
        var id: Int { number }
    }

    /// 某个输出的详情在哪一页。
    func detailTab(for o: OutputState) -> Tab {
        switch o.kind {
        case .record: OutputLinkage.followsRecordMaster(o, in: state) ? .iso : .record
        case .stream: .stream
        case .ndi: .ndi
        case .externalDisplay: .external
        case .virtualCamera: .virtualCamera
        case .multiview: .multiview
        }
    }

    /// 每个输出一行：种类、名字、来源、开 / 关、状态（状态读 Stats，与各页同一套文字）。
    var overviewRows: [OverviewRow] {
        state.outputs.map { o in
            OverviewRow(number: o.number, kind: o.kind, kindTitle: L("outputSettings.overview.kind.\(o.kind.rawValue)"), name: o.name,
                        source: o.settings.source.title(in: state), on: o.enabled, status: overviewStatus(o), tab: detailTab(for: o))
        }
    }

    private func overviewStatus(_ o: OutputState) -> String {
        switch o.kind {
        case .record: recordStatus(output: o.number)
        case .stream: streamStatus(output: o.number)
        case .ndi: ndiStatus(output: o.number)
        case .externalDisplay: displayStatus(output: o.number, kind: "externalDisplay") ?? (o.enabled ? L("outputSettings.overview.starting") : L("output.state.off"))
        case .virtualCamera: virtualCameraOutputStatus
        case .multiview: L("outputSettings.overview.multiviewLayout", L("outputSettings.multiview.preset.\(o.settings.multiview?.preset ?? MultiviewLayoutSettings.defaultPreset)"))
        }
    }

    /// 点一行：跳到它的详情页（并记下是哪一路，页上滚到它）。
    func openDetail(_ number: Int) {
        guard let o = state.output(number) else { return }
        focusedOutput = number
        tab = detailTab(for: o)
    }

    // MARK: 录制输出列表（K4 / K6–K8 / K10）

    /// 录制页列的路：录制 1 + 自己定格式的录制输出（跟录制 1 的 ISO 路在 ISO 页）。
    var recordList: [OutputState] { state.outputs.filter { $0.kind == .record && !OutputLinkage.followsRecordMaster($0, in: state) } }

    /// "录制 k"：在录制页列表里的序号。
    func recordTitle(_ number: Int) -> String {
        L("outputSettings.record.title", (recordList.firstIndex { $0.number == number } ?? 0) + 1)
    }

    /// 来源选项：PGM / 某路输入（PVW / 多画面运行时照录 PGM，界面上不给，UIA-w1-outputs-record-container-and-source）。
    var recordSourceChoices: [OutputSource] { [.program] + state.inputs.map { .input(number: $0.number) } }

    /// 加一路录制输出：来源 PGM、参与录制、编码按节目格式（Q30）、文件一节同录制 1（文件名模板带 {output}）。
    @discardableResult
    func addRecordOutput() -> Int {
        let number = nextOutputNumber()
        let master = OutputLinkage.recordMaster(in: state)
        let directory = master?.settings.record?.directory ?? defaultRecordDirectory
        var output = RecordDefaults.output(number: number, name: L("outputSettings.record.defaultName", recordList.count + 1), format: format, directory: directory)
        if let master, let file = OutputLinkage.sharedRecordFile(from: master) {
            output.settings.record = file
        } else if master != nil || !recordList.isEmpty {
            output.settings.record?.fileNamePattern += "-{output}"
        }
        addOutputConfig(output)
        return number
    }

    /// 参与录制（底栏"录制"起不起这一路）。
    func isRecordArmed(_ number: Int) -> Bool { state.output(number).map(OutputLinkage.isArmed) ?? false }

    func setRecordArmed(_ number: Int, on: Bool) {
        updateOutput(number) { $0.extra[OutputLinkage.armedKey] = on ? nil : .bool(false) }
    }

    /// 改来源：选某路输入的路标"自己的格式"，留在录制页（不变成跟录制 1 的 ISO 路）。
    func setRecordSource(_ number: Int, _ source: OutputSource) {
        updateOutput(number) { s in
            s.source = source
            s.extra[OutputLinkage.ownFormatKey] = source.inputNumber == nil ? nil : .bool(true)
        }
    }

    /// 改录制页"文件"一节（目录 / 模板 / 片段 / 文件格式）：改录制 1 的，其余录制路由 OutputLinkageSync 跟。
    func updateRecordFiles(_ body: (inout RecordSettings) -> Void) {
        updateRecord { s in
            var r = s.record ?? RecordSettings(directory: self.defaultRecordDirectory)
            body(&r)
            s.record = r
        }
    }

    /// 某一路录制的状态："未录" / "录制中" / "起不来"……（与底栏同一套文字，读 Stats.encoder）。
    func recordStatus(output number: Int) -> String {
        guard let o = state.output(number) else { return "" }
        let entry = OutputRuntime.encoderEntry(encoderStats, forOutput: number)
        let route = OutputRouteStatus(number: number, name: o.name, enabled: o.enabled, state: entry?.state, frames: entry?.frames ?? 0, failure: failures[number])
        return OutputButtonSummary.routeState(route, kind: .record).text
    }

    /// K7：按底栏"录制"会一起录哪几路。
    var recordPlanLine: String {
        let armed = OutputLinkage.armedRecords(in: state)
        guard !armed.isEmpty else { return L("outputSettings.record.planNone") }
        return L("outputSettings.record.plan", armed.count, armed.map(\.name).joined(separator: L("outputSettings.listSeparator")))
    }

    /// 在录、停了才跟上录制 1 的路（K10："在录的下次起录生效"）。
    var recordDeferredNote: String? {
        let list = OutputLinkage.deferred(in: state).filter { $0.kind == .record }
        guard !list.isEmpty else { return nil }
        return L("outputSettings.record.deferredNote", list.map(\.name).joined(separator: L("outputSettings.listSeparator")))
    }

    /// 录制目录（录制 1 的）。
    var recordDirectory: String { OutputLinkage.recordMaster(in: state)?.settings.record?.directory ?? defaultRecordDirectory }

    // MARK: ISO 表（K9 / K10）

    struct ISORow: Identifiable, Equatable {
        /// "pgm" / "input-n"。
        let id: String
        /// 这一行对应的录制输出（输入行没勾 = nil）。
        let output: Int?
        let input: Int?
        let title: String
        let checked: Bool
        let locked: Bool
        let status: String
        let dropped: String
        var duration: String = "—"
        let directory: String
    }

    /// 纯音频 / 图片输入：表里默认收起（勾"显示全部输入"才列；已经有 ISO 路的照列）。
    static func isCollapsedByDefault(_ input: InputConfig) -> Bool {
        let kind = input.source.kind
        return kind == .audio || kind == .image
    }

    /// 行 = PGM 录制（录制 1）+ 每路输入。
    var isoRows: [ISORow] {
        var rows: [ISORow] = []
        if let m = OutputLinkage.recordMaster(in: state) {
            rows.append(ISORow(id: "pgm", output: m.number, input: nil, title: L("outputSettings.iso.pgmRow", m.name), checked: OutputLinkage.isArmed(m),
                               locked: m.enabled, status: recordStatus(output: m.number), dropped: droppedText(m.number), directory: m.settings.record?.directory ?? ""))
        }
        for input in state.inputs {
            let iso = ISORoutes.isoRecord(in: state, input: input.number)
            if iso == nil, !isoShowAllInputs, Self.isCollapsedByDefault(input) { continue }
            rows.append(ISORow(id: "input-\(input.number)", output: iso?.number, input: input.number, title: L("outputSettings.iso.input", input.number, input.name),
                               checked: iso != nil, locked: iso?.enabled ?? false, status: iso.map { recordStatus(output: $0.number) } ?? "—",
                               dropped: iso.map { droppedText($0.number) } ?? "—", directory: iso?.settings.record?.directory ?? ""))
        }
        return rows
    }

    /// 收起了几路（纯音频 / 图片、没有 ISO 路）。
    var isoHiddenInputCount: Int {
        state.inputs.filter { Self.isCollapsedByDefault($0) && ISORoutes.isoRecord(in: state, input: $0.number) == nil }.count
    }

    private func droppedText(_ number: Int) -> String {
        OutputRuntime.encoderEntry(encoderStats, forOutput: number).map { String($0.dropped) } ?? "—"
    }

    /// 勾 / 取消一行：PGM 行 = 录制 1 参不参与（取消 = 只录 ISO）；输入行 = 加 / 删这路的 ISO 录制。录着的行锁住。
    func setISORow(_ id: String, on: Bool) {
        guard let row = isoRows.first(where: { $0.id == id }), !row.locked else { return }
        if let input = row.input {
            setISO(input: input, on: on)
        } else if let n = row.output {
            setRecordArmed(n, on: on)
        }
    }

    /// 页顶一行："格式 H.264 · 18 Mb/s · .mov · 目录 …"。
    var isoFormatLine: String {
        guard let m = OutputLinkage.recordMaster(in: state) else { return L("outputSettings.iso.formatNone") }
        let video = m.settings.video ?? VideoEncodeSettings()
        let codec = L("codec.\(video.codec.rawValue)")
        let file = m.settings.record?.remuxToMP4 == true ? RecordFileFormat.movThenMP4.shortTitle : RecordFileFormat.mov.shortTitle
        return L("outputSettings.iso.formatLine", codec, Self.mbps(Double(video.bitrateBps)), file)
    }

    // MARK: 推流（L3 / L5–L10 / L12）

    /// "推流 k"：推流自己的序号（L5）；输出编号放副标题。
    func streamTitle(_ number: Int) -> String {
        L("outputSettings.stream.title", (streamOutputs.firstIndex { $0.number == number } ?? 0) + 1)
    }

    func streamSubtitle(_ number: Int) -> String { L("outputSettings.stream.subtitle", number) }

    /// 状态行（L3）：状态 · 码率 · 丢帧 · 重连 n 次（读 Stats.encoder 里按输出编号对上的那一项）。
    func streamStatusLine(output number: Int) -> String {
        let base = streamStatus(output: number)
        guard let o = state.output(number), o.enabled, failures[number] == nil, let e = OutputRuntime.encoderEntry(encoderStats, forOutput: number) else { return base }
        return L("outputSettings.stream.statusLine", base, Self.mbps(e.bitrate), Int(clamping: e.dropped), Int(clamping: e.reconnects))
    }

    func canStartStream(_ number: Int) -> Bool { !(state.output(number)?.settings.stream?.url.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }

    /// 段首开关：开 = startStream；关 = 先确认再 stopStream（同底栏，W5-B）。
    func setStreamRunning(_ number: Int, on: Bool) {
        guard let o = state.output(number), o.kind == .stream, o.enabled != on else { return }
        if on {
            guard canStartStream(number) else { return }
            send?(.startStream(output: number))
        } else {
            askStop(.stopStream, [o]) { [weak self] in self?.send?(.stopStream(output: number)) }
        }
    }

    /// 页顶"全部开始"：有地址、没开的都开。
    func startAllStreams() {
        for s in streamOutputs where !s.enabled && canStartStream(s.number) { send?(.startStream(output: s.number)) }
    }

    /// 页顶"全部停止"：开着的都停（先确认一次）。
    func stopAllStreams() {
        let running = streamOutputs.filter(\.enabled)
        guard !running.isEmpty else { return }
        askStop(.stopStream, running) { [weak self] in
            guard let self else { return }
            for s in self.state.outputs where s.kind == .stream && s.enabled { self.send?(.stopStream(output: s.number)) }
        }
    }

    private func askStop(_ kind: ConfirmationCenter.Kind, _ routes: [OutputState], _ perform: @escaping @MainActor () -> Void) {
        if let confirmStop { confirmStop(kind, routes, perform) } else { perform() }
    }

    // 服务（L6 / Q31）

    static var streamServices: [StreamService] { StreamServiceCatalog.all }

    /// 这一路的服务：刚在下拉里选过、地址也还对得上的（每场发地址的平台从地址认不出来）优先，否则按地址认。
    func streamService(_ number: Int) -> StreamService {
        let url = state.output(number)?.settings.stream?.url ?? ""
        let detected = StreamServiceCatalog.service(forURL: url)
        guard let id = chosenServices[number], let chosen = StreamServiceCatalog.service(id: id) else { return detected }
        switch chosen.kind {
        case .fixed: return chosen.matches(url: url) ? chosen : detected
        case .custom: return url.isEmpty || chosen.matches(url: url) ? chosen : detected
        case .perSession: return detected.kind == .fixed ? detected : chosen
        }
    }

    /// 选服务：固定入口的填好地址（可改）；自定义 / 每场发地址的平台不填——当前是别家固定入口（或协议对不上的自定义）就清空让用户填。
    /// 节目里只存完整地址，不存服务 id。
    func applyStreamService(_ number: Int, id: String) {
        guard let service = StreamServiceCatalog.service(id: id), !isStreamLocked(number) else { return }
        chosenServices[number] = id
        let current = state.output(number)?.settings.stream?.url ?? ""
        let ownerIsFixed = StreamServiceCatalog.service(forURL: current).kind == .fixed
        let next: String = switch service.kind {
        case .fixed: service.url ?? current
        case .custom: ownerIsFixed || (!current.isEmpty && !service.matches(url: current)) ? "" : current
        case .perSession: ownerIsFixed ? "" : current
        }
        guard next != current else { return }
        updateOutput(number) { s in
            var stream = s.stream ?? StreamSettings(url: "")
            stream.url = next
            s.stream = stream
        }
    }

    // 质量（L7 / Q30）

    static let customQualityID = "custom"

    /// 当前对得上的质量档 id；对不上 = "custom"。
    func streamQualityID(_ number: Int) -> String {
        guard let o = state.output(number) else { return Self.customQualityID }
        return StreamQualityTier.matching(video: o.settings.video, audio: o.settings.audio, format: format)?.id ?? Self.customQualityID
    }

    /// 选质量档：写编码字段（H.264、尺寸、码率、关键帧 2 s、AAC）；"自定义"不改字段、展开"编码详情…"。
    func applyStreamQuality(_ number: Int, id: String) {
        guard let tier = StreamQualityTier.tier(id: id) else { expandedEncodeDetails.insert(number); return }
        updateOutput(number) { s in
            s.video = tier.video(for: self.format)
            s.audio = tier.audio()
        }
    }

    // 关键帧（L8）

    func keyframeText(_ number: Int) -> String {
        KeyframeInterval.text(frames: state.output(number)?.settings.video?.keyframeIntervalFrames ?? VideoEncodeSettings().keyframeIntervalFrames, rate: format.frameRate)
    }

    func keyframeSeconds(_ number: Int) -> Double {
        KeyframeInterval.seconds(frames: state.output(number)?.settings.video?.keyframeIntervalFrames ?? VideoEncodeSettings().keyframeIntervalFrames, rate: format.frameRate)
    }

    func setKeyframeSeconds(_ number: Int, _ seconds: Double) {
        let frames = KeyframeInterval.frames(seconds: seconds, rate: format.frameRate)
        updateOutput(number) { s in
            var v = s.video ?? VideoEncodeSettings()
            v.keyframeIntervalFrames = frames
            s.video = v
        }
    }

    // 与推流 1 相同（L9）

    func streamFollowsFirst(_ number: Int) -> Bool { state.output(number).map { OutputLinkage.followsFirstStream($0, in: state) } ?? false }

    /// 是不是推流 1（推流 1 没有"与推流 1 相同"）。
    func isStreamLeader(_ number: Int) -> Bool { OutputLinkage.streamLeader(in: state)?.number == number }

    /// 勾上 = 马上抄一次推流 1 的编码，之后跟着它；取消 = 留着现在的值、自己改。
    func setStreamFollowsFirst(_ number: Int, on: Bool) {
        let leader = OutputLinkage.streamLeader(in: state)
        updateOutput(number) { s in
            s.extra[OutputLinkage.streamFollowKey] = .bool(on)
            if on, let leader, leader.number != number {
                s.video = leader.settings.video
                s.audio = leader.settings.audio
            }
        }
    }

    // 鉴权（L10）

    func streamAuthStyle(_ number: Int) -> StreamAddress.AuthStyle { .adobe }

    @discardableResult
    func setStreamAuth(_ number: Int, user: String, password: String, style: StreamAddress.AuthStyle) -> String? {
        setStreamAuth(number, user: user, password: password)
    }

    func streamCredentials(_ number: Int) -> StreamDestination.Credentials? {
        state.output(number)?.settings.stream.flatMap(StreamAddress.credentials(of:))
    }

    /// 地址框显示的地址（user:pass@ 打码）。
    func maskedStreamURL(_ number: Int) -> String { StreamAddress.masked(state.output(number)?.settings.stream?.url ?? "") }

    /// "鉴权…"写回：RTMP / RTMPS 写 userinfo，SRT 写 passphrase。返回错误文案（nil = 写好了）。
    @discardableResult
    func setStreamAuth(_ number: Int, user: String, password: String) -> String? {
        guard !isStreamLocked(number), let url = state.output(number)?.settings.stream?.url else { return L("outputSettings.stream.lockedNote") }
        let next: String
        do {
            if StreamAddress.scheme(of: url) == "srt" {
                next = try StreamAddress.withSRTPassphrase(url, passphrase: password)
            } else {
                next = try StreamAddress.withCredentials(url, user: user, password: password)
            }
        } catch {
            switch error {
            case .invalidPassphrase: return L("outputSettings.stream.auth.badPassphrase")
            case .notRTMP, .invalidURL: return L("outputSettings.stream.auth.badURL")
            }
        }
        guard next != url else { return nil }
        updateOutput(number) { s in s.stream?.url = next }
        return nil
    }

    // 合计上行（Q30）

    /// 全部目的地的视频 + 音频码率之和（每个目的地各起一路编码、各占一份上行）。
    var totalUplinkBps: Int {
        streamOutputs.reduce(0) { $0 + ($1.settings.video?.bitrateBps ?? VideoEncodeSettings().bitrateBps) + ($1.settings.audio?.bitrateBps ?? AudioEncodeSettings().bitrateBps) }
    }

    var totalUplinkText: String {
        L("outputSettings.stream.totalUplink", Self.mbps(Double(totalUplinkBps)), streamOutputs.count)
    }

    /// 新建目的地的设置：质量 = 默认档（封顶 1080p，不放大）；第 2 个起默认"与推流 1 相同"并抄推流 1 的编码。
    func newStreamSettings(url: String, key: String) -> OutputSettings {
        let tier = StreamQualityTier.defaultTier(for: format)
        var settings = OutputSettings(source: .program, video: tier.video(for: format), audio: tier.audio(), stream: StreamSettings(url: url, streamKey: key))
        if let leader = OutputLinkage.streamLeader(in: state) {
            settings.video = leader.settings.video ?? settings.video
            settings.audio = leader.settings.audio ?? settings.audio
            settings.extra[OutputLinkage.streamFollowKey] = .bool(true)
        }
        return settings
    }

    // MARK: 外部显示：每块屏单选（M2 / M5，与底栏菜单同一份数据）

    struct ScreenRow: Identifiable, Equatable {
        let id: UInt32
        let title: String
        /// 现在送的源；nil = 关闭。
        let source: OutputSource?
        /// 这块屏的"那一路"（没配 = nil）。
        let output: Int?
    }

    var screenRows: [ScreenRow] {
        displays().map { d in
            let primary = ExternalDisplayRouting.primaryOutput(on: d, in: state)
            let title = d.isMain ? L("outputSettings.external.screenMain", d.name) : d.name
            return ScreenRow(id: d.id, title: title, source: ExternalDisplayRouting.currentSource(on: d, in: state), output: primary?.number)
        }
    }

    /// 某块屏选源（nil = 关闭）。
    func pickScreen(_ id: UInt32, source: OutputSource?) {
        guard let d = displays().first(where: { $0.id == id }) else { return }
        for c in ExternalDisplayRouting.pick(display: d, source: source, in: state) {
            applyLocally(c)
            send?(c)
        }
    }

    // MARK: 多画面格子编辑（M7）

    /// 格子的来源选项：PGM / PVW / 各输入（多画面不能套自己）。
    var multiviewCellSources: [OutputSource] { [.program, .preview] + state.inputs.map { .input(number: $0.number) } }

    /// 把当前预设的格子摆法抄成自定义格子（之后逐格改）。
    func convertMultiviewPresetToCustom() {
        var preset = multiviewLayout
        preset.custom = []
        let placements = MultiviewLayout.placements(settings: preset, inputs: state.inputs.map(\.number), width: format.width, height: format.height)
        let cells = placements.map { MultiviewCell(source: $0.source, rect: $0.outer) }
        updateMultiview { $0.custom = cells }
    }

    func addMultiviewCell() {
        updateMultiview { $0.custom.append(MultiviewCell(source: .program, rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))) }
    }

    func removeMultiviewCell(at index: Int) {
        updateMultiview { l in if l.custom.indices.contains(index) { l.custom.remove(at: index) } }
    }

    func setMultiviewCell(at index: Int, source: OutputSource) {
        updateMultiview { l in if l.custom.indices.contains(index) { l.custom[index].source = source } }
    }

    /// 改格子位置尺寸（归一化，钳到画面内）。
    func setMultiviewCell(at index: Int, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil) {
        updateMultiview { l in
            guard l.custom.indices.contains(index) else { return }
            var r = l.custom[index].rect
            if let x { r.x = min(max(x, 0), 1) }
            if let y { r.y = min(max(y, 0), 1) }
            if let width { r.width = min(max(width, 0.01), 1) }
            if let height { r.height = min(max(height, 0.01), 1) }
            l.custom[index].rect = r
        }
    }
}

extension OutputSettingsModel.RecordFileFormat {
    /// ISO 页顶那一行用的短名（".mov" / ".mov → .mp4"）。
    var shortTitle: String { L("outputSettings.record.fileFormat.short.\(rawValue)") }
}
