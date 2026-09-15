// switcher-headless —— 无界面模式入口（测试标准 §2.4）。
//
//   switcher-headless run --show show.json --script scenario.json --duration 600 --stats stats.jsonl --record out.mov [--preview] [--audio-device null]
//   switcher-headless make-show --out scenarios/m0-show.json          M0 标准负载的节目文件（8 路合成源）
//   switcher-headless make-scenario --out scenarios/m0.json           每 30 s Cut、每 5 min Fade 的场景
//   switcher-headless summarize --stats stats.jsonl [--baseline b.json] [--write-baseline out.json]
//
// 无参数 / --version 只打印版本（make test 的冒烟）。
import Foundation
import SwitcherContracts

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["--version"] || arguments == ["-v"] {
    print("switcher-headless \(SwitcherVersion.current)")
    if arguments.isEmpty { print(HeadlessCLI.usage) }
    exit(0)
}
do {
    try HeadlessCLI.dispatch(arguments)   // run 子命令自己进 run loop，结束时 exit；其他子命令返回
} catch {
    FileHandle.standardError.write(Data("switcher-headless: \(error)\n".utf8))
    exit(2)
}
