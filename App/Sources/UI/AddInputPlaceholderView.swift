// 输入条末尾的虚线"＋ 添加输入"占位格（W5-H，01a D10 / 03 V-09）。红灯轮：只给签名。
import AppKit

@MainActor
final class AddInputPlaceholderView: NSView {
    var onClick: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var titleText: String { "" }
    var hintText: String { "" }
    var isHintHidden: Bool { true }
    var hasDashedBorder: Bool { false }
    func performClick() {}
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
}
