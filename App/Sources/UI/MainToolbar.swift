// 主窗口顶部工具条（W5-G，01a A1 / A2 / F2 / M1，04 Q28）。
import AppKit

@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    enum Item: String, CaseIterable {
        case newShow, openShow, saveShow, saveShowAs, external, outputStatus, settings, help
        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("plusmix.toolbar.\(rawValue)") }
    }

    let toolbar = NSToolbar(identifier: "PlusMixMainToolbar")
    let newButton = Theme.button(L("menu.show.new"), target: nil, action: nil)
    let open = SplitBarButton(name: L("menu.show.open"), title: L("menu.show.open"))
    let saveButton = Theme.button(L("menu.show.save"), target: nil, action: nil)
    let saveAsButton = Theme.button(L("menu.show.saveAs"), target: nil, action: nil)
    let external = SplitBarButton(name: L("bottom.external"), title: L("bottom.external"))
    let settings = SplitBarButton(name: L("menu.preferences"), title: L("menu.preferences"))
    let helpButton = Theme.button("?", target: nil, action: nil)

    var allButtons: [NSButton] { [] }
    private(set) var isExternalHighlighted = false

    func openMenu() -> NSMenu { NSMenu() }
    func settingsMenu() -> NSMenu { NSMenu() }
    func helpMenu() -> NSMenu { NSMenu() }
}
