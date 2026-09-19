// ISO 选路面板（底栏"ISO…"弹出，W3-C 交付 3）：每路输入一个开关 = 节目里有没有这路的视频 ISO 录制输出（kind = .record、source = .input(n)），
// 开 / 关就是 addOutput / removeOutput 命令；录制目录、剩余空间和"还能录多久"（按 PGM + 所选 ISO 路的码率之和）显示在下面。
// 起 / 停由底栏的录制按钮一起做（同一拍起多条 startRecord）。
import AppKit
import SwitcherContracts
import SwitcherISO

/// 纯逻辑：从快照里找 ISO 路、生成 addOutput 的配置（测试对着它写）。
@MainActor
enum ISORoutes {
    /// PGM 的录制输出（第一个 source = .program 的 record）。
    static func programRecord(in state: MixerState) -> OutputState? {
        state.outputs.first { $0.kind == .record && $0.settings.source == .program }
    }

    /// 输入 n 的 ISO 录制输出。
    static func isoRecord(in state: MixerState, input number: Int) -> OutputState? {
        state.outputs.first { $0.kind == .record && $0.settings.source == .input(number: number) }
    }

    /// 全部录制输出（PGM + ISO），按编号。
    static func allRecords(in state: MixerState) -> [OutputState] { state.outputs.filter { $0.kind == .record } }

    /// 给输入 n 建一个 ISO 录制输出：编码 / 目录抄 PGM 录制输出（没有就默认），文件名模板带 {output} 免得同一秒同名，名字 "ISO n"。
    static func makeISOOutput(for input: InputConfig, in state: MixerState, defaultDirectory: String) -> OutputState {
        let number = (state.outputs.map(\.number).max() ?? 0) + 1
        let pgm = programRecord(in: state)
        var record = pgm?.settings.record ?? RecordSettings(directory: defaultDirectory)
        if !record.fileNamePattern.contains("{output}") { record.fileNamePattern += "-{output}" }
        let settings = OutputSettings(source: .input(number: input.number), video: pgm?.settings.video ?? VideoEncodeSettings(),
                                      audio: pgm?.settings.audio ?? AudioEncodeSettings(), record: record)
        return OutputState(number: number, kind: .record, name: "ISO \(input.number)", enabled: false, settings: settings)
    }

    /// 录制目录 + 剩余空间 + 按所有录制输出码率估的时长。
    static func estimateText(state: MixerState, defaultDirectory: String, reserveBytes: UInt64) -> String {
        let records = allRecords(in: state)
        let directory = programRecord(in: state)?.settings.record?.directory ?? records.first?.settings.record?.directory ?? defaultDirectory
        let (free, seconds) = OutputRuntime.estimate(directory: directory, outputs: records, reserveBytes: reserveBytes)
        let freeGB = Double(free) / 1_073_741_824
        let bps = records.reduce(0.0) { $0 + DiskEstimate.bytesPerSecond(video: $1.settings.video ?? VideoEncodeSettings(), audio: $1.settings.audio ?? AudioEncodeSettings()) }
        return "目录 \(directory)\n剩余 \(String(format: "%.1f", freeGB)) GB；\(records.count) 路共 \(String(format: "%.1f", bps * 8 / 1_000_000)) Mbps → \(DiskEstimate.describe(seconds: seconds))"
    }
}

@MainActor
final class ISOPanelController: NSViewController {
    var send: ((Command) -> Void)?
    private var state: MixerState
    private let defaultDirectory: String
    private let reserveBytes: UInt64
    private var toggles: [Int: NSButton] = [:]
    private let list = NSStackView()
    private let estimateLabel = Theme.label("", size: 11, color: Theme.dimText)
    private let hint = Theme.label("勾选的输入各录一个文件（与 PGM 同一拍起停、共用起点）；用底栏的「录制」一起起停。", size: 11, color: Theme.dimText)

    init(state: MixerState, defaultDirectory: String, reserveBytes: UInt64) {
        self.state = state
        self.defaultDirectory = defaultDirectory
        self.reserveBytes = reserveBytes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.addArrangedSubview(Theme.label("ISO 分路录制", size: 13, weight: .semibold))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        stack.addArrangedSubview(list)
        estimateLabel.maximumNumberOfLines = 3
        estimateLabel.lineBreakMode = .byWordWrapping
        estimateLabel.preferredMaxLayoutWidth = 360
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(estimateLabel)
        stack.addArrangedSubview(hint)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        view = stack
        apply(state: state)
    }

    func apply(state: MixerState) {
        self.state = state
        guard isViewLoaded else { return }
        let wanted = state.inputs.map(\.number)
        if Array(toggles.keys.sorted()) != wanted {
            for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
            toggles.removeAll()
            for input in state.inputs {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(togglePressed(_:)))
                b.tag = input.number
                toggles[input.number] = b
                list.addArrangedSubview(b)
            }
            if state.inputs.isEmpty { list.addArrangedSubview(Theme.label("（没有输入）", size: 11, color: Theme.dimText)) }
        }
        for input in state.inputs {
            guard let b = toggles[input.number] else { continue }
            let iso = ISORoutes.isoRecord(in: state, input: input.number)
            b.title = "输入 \(input.number) \(input.name)" + (iso.map { "  →  \($0.name)\($0.enabled ? "（录制中）" : "")" } ?? "")
            b.state = iso == nil ? .off : .on
            b.isEnabled = !(iso?.enabled ?? false)   // 录着的路不许在这里删
        }
        estimateLabel.stringValue = ISORoutes.estimateText(state: state, defaultDirectory: defaultDirectory, reserveBytes: reserveBytes)
    }

    /// 某路的开关（测试用）。
    func toggle(for input: Int) -> NSButton? { toggles[input] }

    @objc private func togglePressed(_ sender: NSButton) {
        let number = sender.tag
        if let iso = ISORoutes.isoRecord(in: state, input: number) {
            guard !iso.enabled else { return }
            send?(.removeOutput(output: iso.number))
        } else if let input = state.input(number) {
            send?(.addOutput(config: ISORoutes.makeISOOutput(for: input, in: state, defaultDirectory: defaultDirectory)))
        }
    }
}
