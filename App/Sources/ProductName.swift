// 产品显示名（W4-D，用户 2026-09-28 定名 PlusMix）：界面上给人看的名字只从这里和 Localizable.strings 出；代码名 Switcher（模块、target、scheme、
// SwitcherVersion、switcher-headless / frameprobe、Stats 字段、bundle id com.plusmix.switcher）一律不动，也不进界面。
// 名字的来源是 Info.plist 的 CFBundleName（= project.yml 里 App target 的 PRODUCT_NAME），所以产品名只在 project.yml 一处定义；
// 拿不到时（理论上只有非 bundle 的进程）退到字面量。
import Foundation

enum ProductName {
    /// "PlusMix"。菜单标题、窗口标题、诊断包目录名等写死的显示字符串都用它。
    static let display: String = {
        if let name = Bundle.main.infoDictionary?["CFBundleName"] as? String, !name.isEmpty { return name }
        return "PlusMix"
    }()

    /// 可执行名（Contents/MacOS/ 下那个文件 = 进程名 = 崩溃报告文件名的前缀）；跟 PRODUCT_NAME 走。
    static let executable: String = {
        if let name = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String, !name.isEmpty { return name }
        return "PlusMix"
    }()
}
