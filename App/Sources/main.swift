// 入口。不用 @main：没有 nib / storyboard 时 NSApplicationMain 不会替我们实例化 delegate，
// 所以显式建 NSApplication 并挂上 AppDelegate（全局变量持有，delegate 属性是弱引用）。
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
