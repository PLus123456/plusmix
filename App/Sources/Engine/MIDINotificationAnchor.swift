// reports/issues/W3E-w2-control-midi-hotplug-after-restart.md 的 App 侧绕法（W3-E2 交付第 5 条；W2-C 的 MIDIController 还没改）。
// CoreMIDI 把进程里**所有**客户端的通知（源增删 = 热插拔）派到"进程里第一次 MIDIClientCreate 时的那条 run loop"上。
// 每个 session 的 MIDIController 在自己的线程上建客户端，第一个 session 停了、那条线程退出，之后换节目起的控制器再也收不到
// msgObjectAdded：换过节目后插的 MIDI 设备要重开 App 才能用。
// 绕法：App 启动时（第一个 session 之前）先在主线程建一个不干活的锚客户端，主 run loop 一直在跑，之后每个控制器的通知块都在主线程上被调；
// MIDIController 的通知处理只动带锁的源表和 MIDI API，在哪条线程上调都行。客户端整个进程只建这一个，不销毁（CoreMIDI 本来就是每进程一份）。
// 探针（reports/w3-app-3.md §1）：第一个客户端的线程退出后新客户端收到 0 次 msgObjectAdded；先在主线程建锚后收到 1 次，回调线程 = main。
import CoreMIDI
import Foundation

@MainActor
enum MIDINotificationAnchor {
    private static var client = MIDIClientRef()

    /// 建锚客户端（重复调无害）。要在第一个 MIDIController.start() 之前、在主线程上调。
    static func install() {
        guard client == 0 else { return }
        let status = MIDIClientCreateWithBlock("Switcher MIDI anchor" as CFString, &client) { _ in }
        if status != noErr {
            client = 0
            NSLog("MIDI 锚客户端建不起来（OSStatus %d）：换节目之后新插的 MIDI 设备要重开 App 才能用", status)
        }
    }

    static var isInstalled: Bool { client != 0 }
}
