/// 声道映射的唯一口径（契约 `InputSource` 顶上"声道映射"一节，提案 014）：纯音频设备（`AudioDeviceInput`）和
/// DeckLink 内嵌音频（`DeckLinkInput`）共用，两边不各写一份。
///
/// 目标声道 d（环的第 d 路）取源的第几路：
/// - 映射为空 = 取前几路：d 取源第 d 路；源是单声道就复制到所有声道，源声道比环少时缺的复制最后一路；
/// - 映射比环的声道数短时，缺的复制最后一项（`[4]` = 所有声道都取第 5 路）；多出来的项忽略；
/// - 越界的下标钳到源的声道范围里。
public enum InputChannelMap {
    /// 不钳范围的"想要源的第几路"。源的声道数还不知道时（建会话之前）先用它算表，用的时候再按实际声道数钳。
    @inline(__always)
    public static func requestedChannel(forDestination destination: Int, map: [Int]) -> Int {
        map.isEmpty ? destination : map[min(destination, map.count - 1)]
    }

    /// 目标声道 `destination` 实际取源的第几路（已钳到 `[0, sourceChannels − 1]`）。
    @inline(__always)
    public static func sourceChannel(forDestination destination: Int, map: [Int], sourceChannels: Int) -> Int {
        clamp(requestedChannel(forDestination: destination, map: map), sourceChannels: sourceChannels)
    }

    /// 把一个想要的下标钳到源的声道范围里。
    @inline(__always)
    public static func clamp(_ channel: Int, sourceChannels: Int) -> Int {
        min(max(channel, 0), max(sourceChannels - 1, 0))
    }

    /// 要取到映射里用得上的所有下标，源至少得开几路。映射为空返回 0（= 没有额外要求，按各输入自己的默认开）。
    public static func requiredSourceChannels(map: [Int], destinationChannels: Int) -> Int {
        guard !map.isEmpty else { return 0 }
        var needed = 0
        var d = 0
        while d < destinationChannels {
            needed = max(needed, requestedChannel(forDestination: d, map: map) + 1)
            d += 1
        }
        return needed
    }
}
