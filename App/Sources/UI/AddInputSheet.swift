// 添加输入（最小版，完整版 W3-E）：左边选类型（合成源 / 摄像头 / 屏幕 / 文件 / 图片），右边填参数，底部编号 + 名字 + 确定。
// 只产生 InputConfig 并发 addInput 命令；摄像头 / 屏幕 / 文件 / 图片的运行实现在 W2-A，合并前这些输入建出来是占位（格子上有提示）。
import AppKit
import AVFoundation
import SwitcherContracts

/// 表单内容 → InputConfig 的纯逻辑（可测）。
struct AddInputModel {
    enum Kind: Int, CaseIterable {
        case synthetic, camera, screen, file, image
        var title: String {
            switch self {
            case .synthetic: "合成源"
            case .camera: "摄像头 / 采集卡"
            case .screen: "屏幕"
            case .file: "视频文件"
            case .image: "图片"
            }
        }
    }
    enum ModelError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self { case .missing(let what): "还没填：\(what)" }
        }
    }

    var kind: Kind = .synthetic
    var number: Int = 1
    var name: String = ""
    // 合成源
    var syntheticFrameRate: FrameRate = .fps60
    var syntheticSize: (width: Int, height: Int) = (1920, 1080)
    var syntheticGray: UInt8 = 128
    var syntheticAudio = false
    // 摄像头
    var cameraUniqueID: String?
    // 屏幕
    var displayID: UInt32?
    // 文件 / 图片
    var filePath: String = ""
    var fileEndAction: FileEndAction = .loop
    var imagePath: String = ""

    static let syntheticSizes: [(String, (Int, Int))] = [("1920×1080", (1920, 1080)), ("1280×720", (1280, 720)), ("3840×2160", (3840, 2160))]
    static let syntheticRates: [FrameRate] = [.fps30, .fps5994, .fps60]

    /// 默认名字。
    var defaultName: String {
        switch kind {
        case .synthetic: "合成 \(number) · \(syntheticFrameRate)"
        case .camera: "摄像头 \(number)"
        case .screen: "屏幕 \(number)"
        case .file: filePath.isEmpty ? "文件 \(number)" : (filePath as NSString).lastPathComponent
        case .image: imagePath.isEmpty ? "图片 \(number)" : (imagePath as NSString).lastPathComponent
        }
    }

    func makeConfig() throws -> InputConfig {
        let source: InputSource
        switch kind {
        case .synthetic:
            source = .synthetic(settings: SyntheticSourceSettings(frameRate: syntheticFrameRate, width: syntheticSize.width, height: syntheticSize.height,
                                                                  background: .gray(level: syntheticGray), audio: syntheticAudio))
        case .camera:
            guard let id = cameraUniqueID, !id.isEmpty else { throw ModelError.missing("摄像头") }
            source = .camera(uniqueID: id)
        case .screen:
            guard let id = displayID else { throw ModelError.missing("屏幕") }
            source = .screen(target: .display(id: id), frameRate: nil, captureAudio: false)
        case .file:
            guard !filePath.isEmpty else { throw ModelError.missing("文件路径") }
            source = .file(path: filePath, endAction: fileEndAction, rate: 1)
        case .image:
            guard !imagePath.isEmpty else { throw ModelError.missing("图片路径") }
            source = .image(path: imagePath)
        }
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
        return InputConfig(number: number, name: finalName, source: source)
    }

    /// 空闲编号（1…maxInputs 里最小的没用的）。
    static func nextFreeNumber(in state: MixerState, maxInputs: Int) -> Int {
        let used = Set(state.inputs.map(\.number))
        return (1...max(1, maxInputs)).first { !used.contains($0) } ?? maxInputs
    }

    /// 摄像头列表（uniqueID, 名字）。
    static func cameras() -> [(id: String, name: String)] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified)
        return session.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// 显示器列表。
    @MainActor
    static func displays() -> [(id: UInt32, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, "\(screen.localizedName)（\(Int(screen.frame.width))×\(Int(screen.frame.height))）")
        }
    }
}

/// Sheet 本体。
@MainActor
final class AddInputSheetController: NSWindowController {
    private(set) var model = AddInputModel()
    private let maxInputs: Int
    private let usedNumbers: Set<Int>
    private let onConfirm: (InputConfig) -> Void

    private let kindButtons: [NSButton]
    private let numberPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let formContainer = NSView()
    private var form: NSView?
    private let errorLabel = Theme.label("", size: 11, color: Theme.recording)

    init(state: MixerState, maxInputs: Int, onConfirm: @escaping (InputConfig) -> Void) {
        self.maxInputs = maxInputs
        usedNumbers = Set(state.inputs.map(\.number))
        self.onConfirm = onConfirm
        kindButtons = AddInputModel.Kind.allCases.map { NSButton(radioButtonWithTitle: $0.title, target: nil, action: nil) }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "添加输入"
        super.init(window: panel)
        model.number = AddInputModel.nextFreeNumber(in: state, maxInputs: maxInputs)
        buildUI()
        selectKind(.synthetic)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        for (i, b) in kindButtons.enumerated() {
            b.tag = i
            b.target = self
            b.action = #selector(kindChanged(_:))
        }
        let kinds = NSStackView(views: kindButtons)
        kinds.orientation = .vertical
        kinds.alignment = .leading
        kinds.spacing = 8
        kinds.translatesAutoresizingMaskIntoConstraints = false
        formContainer.translatesAutoresizingMaskIntoConstraints = false

        for n in 1...max(1, maxInputs) where !usedNumbers.contains(n) { numberPopup.addItem(withTitle: "\(n)") }
        numberPopup.selectItem(withTitle: "\(model.number)")
        numberPopup.target = self
        numberPopup.action = #selector(numberChanged)
        nameField.placeholderString = "名字（留空用默认）"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        let ok = Theme.button("添加", target: self, action: #selector(confirm))
        ok.keyEquivalent = "\r"
        let cancel = Theme.button("取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let bottom = NSStackView(views: [Theme.label("编号"), numberPopup, Theme.label("名字"), nameField, errorLabel, cancel, ok])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        bottom.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        content.addSubview(kinds)
        content.addSubview(formContainer)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            kinds.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            kinds.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            kinds.widthAnchor.constraint(equalToConstant: 150),
            formContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            formContainer.leadingAnchor.constraint(equalTo: kinds.trailingAnchor, constant: 16),
            formContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            formContainer.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            nameField.widthAnchor.constraint(equalToConstant: 160),
        ])
    }

    private func selectKind(_ kind: AddInputModel.Kind) {
        model.kind = kind
        for b in kindButtons { b.state = b.tag == kind.rawValue ? .on : .off }
        form?.removeFromSuperview()
        let f = makeForm(for: kind)
        f.translatesAutoresizingMaskIntoConstraints = false
        formContainer.addSubview(f)
        NSLayoutConstraint.activate([
            f.topAnchor.constraint(equalTo: formContainer.topAnchor),
            f.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor),
            f.trailingAnchor.constraint(equalTo: formContainer.trailingAnchor),
        ])
        form = f
        nameField.placeholderString = model.defaultName
        errorLabel.stringValue = ""
    }

    private func labeled(_ label: String, _ control: NSView) -> NSStackView {
        let l = Theme.label(label, size: 12, color: Theme.dimText)
        l.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeForm(for kind: AddInputModel.Kind) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        switch kind {
        case .synthetic:
            let rate = NSPopUpButton()
            for r in AddInputModel.syntheticRates { rate.addItem(withTitle: "\(r)") }
            rate.selectItem(at: AddInputModel.syntheticRates.firstIndex(of: model.syntheticFrameRate) ?? 2)
            rate.target = self; rate.action = #selector(syntheticRateChanged(_:))
            let size = NSPopUpButton()
            for (title, _) in AddInputModel.syntheticSizes { size.addItem(withTitle: title) }
            size.target = self; size.action = #selector(syntheticSizeChanged(_:))
            let gray = NSSlider(value: Double(model.syntheticGray), minValue: 16, maxValue: 235, target: self, action: #selector(syntheticGrayChanged(_:)))
            gray.widthAnchor.constraint(equalToConstant: 200).isActive = true
            let audio = NSButton(checkboxWithTitle: "带合成音频（1 kHz + click）", target: self, action: #selector(syntheticAudioChanged(_:)))
            audio.state = model.syntheticAudio ? .on : .off
            stack.addArrangedSubview(Theme.label("内置测试图案：帧号、时间戳、输入 ID、闪光（测试标准 §2.1）", size: 11, color: Theme.dimText))
            stack.addArrangedSubview(labeled("帧率", rate))
            stack.addArrangedSubview(labeled("尺寸", size))
            stack.addArrangedSubview(labeled("底色灰度", gray))
            stack.addArrangedSubview(audio)
        case .camera:
            let popup = NSPopUpButton()
            let cams = AddInputModel.cameras()
            for c in cams { popup.addItem(withTitle: c.name) }
            popup.target = self; popup.action = #selector(cameraChanged(_:))
            model.cameraUniqueID = cams.first?.id
            stack.addArrangedSubview(labeled("设备", popup))
            stack.addArrangedSubview(Theme.label(cams.isEmpty ? "没有找到摄像头 / 采集卡" : "\(cams.count) 台设备（AVCaptureDevice）", size: 11, color: Theme.dimText))
            stack.addArrangedSubview(Theme.label("采集实现在 W2-A，合并前这一路是占位。", size: 11, color: Theme.dimText))
        case .screen:
            let popup = NSPopUpButton()
            let displays = AddInputModel.displays()
            for d in displays { popup.addItem(withTitle: d.name) }
            popup.target = self; popup.action = #selector(displayChanged(_:))
            model.displayID = displays.first?.id
            stack.addArrangedSubview(labeled("显示器", popup))
            stack.addArrangedSubview(Theme.label("窗口 / 应用过滤在 W3-E；采集实现在 W2-A。", size: 11, color: Theme.dimText))
        case .file:
            let path = NSTextField(string: model.filePath)
            path.placeholderString = "视频文件路径"
            path.widthAnchor.constraint(equalToConstant: 300).isActive = true
            path.target = self; path.action = #selector(filePathChanged(_:))
            path.tag = 1
            let browse = Theme.button("选择…", target: self, action: #selector(browseFile))
            let end = NSPopUpButton()
            end.addItems(withTitles: ["循环", "停在末帧", "黑场"])
            end.target = self; end.action = #selector(fileEndChanged(_:))
            stack.addArrangedSubview(labeled("文件", NSStackView(views: [path, browse])))
            stack.addArrangedSubview(labeled("播完", end))
        case .image:
            let path = NSTextField(string: model.imagePath)
            path.placeholderString = "图片路径"
            path.widthAnchor.constraint(equalToConstant: 300).isActive = true
            path.target = self; path.action = #selector(filePathChanged(_:))
            path.tag = 2
            let browse = Theme.button("选择…", target: self, action: #selector(browseImage))
            stack.addArrangedSubview(labeled("图片", NSStackView(views: [path, browse])))
        }
        return stack
    }

    // MARK: 动作

    @objc private func kindChanged(_ sender: NSButton) {
        guard let kind = AddInputModel.Kind(rawValue: sender.tag) else { return }
        selectKind(kind)
    }
    @objc private func numberChanged() {
        model.number = Int(numberPopup.titleOfSelectedItem ?? "") ?? model.number
        nameField.placeholderString = model.defaultName
    }
    @objc private func syntheticRateChanged(_ sender: NSPopUpButton) {
        model.syntheticFrameRate = AddInputModel.syntheticRates[max(0, sender.indexOfSelectedItem)]
        nameField.placeholderString = model.defaultName
    }
    @objc private func syntheticSizeChanged(_ sender: NSPopUpButton) {
        model.syntheticSize = AddInputModel.syntheticSizes[max(0, sender.indexOfSelectedItem)].1
    }
    @objc private func syntheticGrayChanged(_ sender: NSSlider) { model.syntheticGray = UInt8(sender.doubleValue) }
    @objc private func syntheticAudioChanged(_ sender: NSButton) { model.syntheticAudio = sender.state == .on }
    @objc private func cameraChanged(_ sender: NSPopUpButton) {
        let cams = AddInputModel.cameras()
        let i = sender.indexOfSelectedItem
        model.cameraUniqueID = i >= 0 && i < cams.count ? cams[i].id : nil
    }
    @objc private func displayChanged(_ sender: NSPopUpButton) {
        let displays = AddInputModel.displays()
        let i = sender.indexOfSelectedItem
        model.displayID = i >= 0 && i < displays.count ? displays[i].id : nil
    }
    @objc private func filePathChanged(_ sender: NSTextField) {
        if sender.tag == 1 { model.filePath = sender.stringValue } else { model.imagePath = sender.stringValue }
        nameField.placeholderString = model.defaultName
    }
    @objc private func fileEndChanged(_ sender: NSPopUpButton) {
        model.fileEndAction = [.loop, .holdLastFrame, .black][max(0, min(2, sender.indexOfSelectedItem))]
    }
    @objc private func browseFile() { browse(image: false) }
    @objc private func browseImage() { browse(image: true) }
    private func browse(image: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = image ? [.image] : [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                if image { self.model.imagePath = url.path } else { self.model.filePath = url.path }
                self.selectKind(self.model.kind)   // 重建表单显示路径
            }
        }
    }

    @objc private func confirm() {
        model.name = nameField.stringValue
        do {
            let config = try model.makeConfig()
            onConfirm(config)
            close(returnCode: .OK)
        } catch {
            errorLabel.stringValue = "\(error)"
        }
    }

    @objc private func cancel() { close(returnCode: .cancel) }

    // 测试入口（sheet 里的控件没有公开的 outlet）
    func selectKindForTesting(_ kind: AddInputModel.Kind) { selectKind(kind) }
    func confirmForTesting() { confirm() }
    func cancelForTesting() { cancel() }

    private func close(returnCode: NSApplication.ModalResponse) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: returnCode)
        } else {
            window.close()
        }
    }
}
