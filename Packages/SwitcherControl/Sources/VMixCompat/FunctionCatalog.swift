import Foundation

/// 一个已实现函数的说明（docs/integrations/ 里兼容层文档的覆盖表按它写）。
public struct FunctionDoc: Hashable, Sendable {
    public var name: String
    public var parameters: [String]
    public var summary: String
    public init(_ name: String, _ parameters: [String], _ summary: String) {
        self.name = name
        self.parameters = parameters
        self.summary = summary
    }
}

/// 实现表与"上游有、这里没做"的表。
public enum FunctionCatalog {
    /// 已实现的函数（规范写法；匹配时不分大小写）。
    public static let implemented: [FunctionDoc] = {
        var docs: [FunctionDoc] = [
            FunctionDoc("Cut", ["Input?"], "PGM / PVW 对调；带 Input 先把它放到 PVW 再切（转场进行中带 Input 回 NotConfigured，不带 Input 把当前转场做完）"),
            FunctionDoc("Fade", ["Duration? (ms, 默认 500)", "Input?"], "Fade 转场"),
            FunctionDoc("Wipe", ["Duration?", "Input?"], "Wipe 转场（选类型 + 开始）"),
            FunctionDoc("Zoom", ["Duration?", "Input?"], "Zoom 转场"),
            FunctionDoc("Stinger1", [], "执行第一个选了输入的 Stinger 转场槽（都没选时用当前那组的 stinger 输入；都没有 = NotConfigured）"),
            FunctionDoc("SetFader", ["Value (0–255)"], "T-bar 位置"),
            FunctionDoc("PreviewInput", ["Input"], "选 PVW"),
            FunctionDoc("SetPreviewInput", ["Input"], "同 PreviewInput"),
            FunctionDoc("PreviewInputNext", [], "PVW 选下一路"),
            FunctionDoc("PreviewInputPrevious", [], "PVW 选上一路"),
            FunctionDoc("ActiveInput", ["Input"], "直切 PGM（PVW 不变）"),
            FunctionDoc("CutDirect", ["Input"], "同 ActiveInput（Companion 的 Send Input to Program）"),
            FunctionDoc("SetInputName", ["Input", "Value"], "改输入名"),
            FunctionDoc("StartRecording", [], "开始录制（配置指定的或编号最小的录制输出）"),
            FunctionDoc("StopRecording", [], "停止录制"),
            FunctionDoc("StartStopRecording", [], "录制开关"),
            FunctionDoc("StartStreaming", ["Value? (第几路推流，0 起)"], "开始推流"),
            FunctionDoc("StopStreaming", ["Value?"], "停止推流"),
            FunctionDoc("StartStopStreaming", ["Value?"], "推流开关"),
            FunctionDoc("FadeToBlack", [], "FTB 开关"),
            FunctionDoc("SetMasterVolume", ["Value (0–100)"], "Master 推子"),
            FunctionDoc("SetBusAVolume", ["Value (0–100)"], "Bus A 推子"),
            FunctionDoc("SetBusBVolume", ["Value (0–100)"], "Bus B 推子"),
            FunctionDoc("SetHeadphonesVolume", ["Value (0–100)"], "耳机推子"),
            FunctionDoc("SetVolume", ["Input", "Value (0–100)"], "输入推子"),
            FunctionDoc("Audio", ["Input"], "输入静音开关"),
            FunctionDoc("AudioOn", ["Input"], "取消静音"),
            FunctionDoc("AudioOff", ["Input"], "静音"),
            FunctionDoc("AudioBus", ["Input", "Value (M|A|B)"], "输入到总线的路由开关"),
            FunctionDoc("AudioBusOn", ["Input", "Value (M|A|B)"], "路由开"),
            FunctionDoc("AudioBusOff", ["Input", "Value (M|A|B)"], "路由关"),
            FunctionDoc("Solo", ["Input"], "独听开关"),
            FunctionDoc("SoloOn", ["Input"], "独听开"),
            FunctionDoc("SoloOff", ["Input"], "独听关"),
            FunctionDoc("SetBalance", ["Input", "Value (−1…1)"], "声像"),
            FunctionDoc("MasterAudio", [], "Master 静音开关"),
            FunctionDoc("MasterAudioOn", [], "Master 取消静音（也认 MasterAudioON）"),
            FunctionDoc("MasterAudioOff", [], "Master 静音（也认 MasterAudioOFF）"),
            FunctionDoc("BusAAudio", [], "Bus A 静音开关"),
            FunctionDoc("BusAAudioOn", [], "Bus A 取消静音"),
            FunctionDoc("BusAAudioOff", [], "Bus A 静音"),
            FunctionDoc("BusBAudio", [], "Bus B 静音开关"),
            FunctionDoc("BusBAudioOn", [], "Bus B 取消静音"),
            FunctionDoc("BusBAudioOff", [], "Bus B 静音"),
            FunctionDoc("BusXAudio", ["Value (A|B)"], "按 Value 选总线的静音开关"),
            FunctionDoc("BusXAudioOn", ["Value (A|B)"], "取消静音"),
            FunctionDoc("BusXAudioOff", ["Value (A|B)"], "静音"),
            FunctionDoc("OverlayInputAllOff", [], "关掉全部叠加通道"),
        ]
        // 转场槽 1–4（提案 020，W5-M）
        for k in 1...4 {
            docs += [
                FunctionDoc("Transition\(k)", [], "执行转场 \(k)：选中并开始（之后 T-bar / 回车也用它）"),
                FunctionDoc("SetTransitionEffect\(k)", ["Value (Cut|Fade|Wipe|Zoom|Stinger)"], "改转场 \(k) 的效果（槽里的时长 / Wipe / Stinger 参数不动）"),
                FunctionDoc("SetTransitionDuration\(k)", ["Value (ms)"], "改转场 \(k) 的时长"),
            ]
        }
        for k in 1...4 {
            docs += [
                FunctionDoc("OverlayInput\(k)", ["Input?"], "叠加 \(k) 开关：同一路已开着 → 关，否则开并换成 Input"),
                FunctionDoc("OverlayInput\(k)In", ["Input?"], "叠加 \(k) 开"),
                FunctionDoc("OverlayInput\(k)Out", [], "叠加 \(k) 关"),
                FunctionDoc("OverlayInput\(k)Off", [], "叠加 \(k) 关"),
                FunctionDoc("OverlayInput\(k)Last", [], "叠加 \(k) 用通道当前输入开关"),
            ]
        }
        return docs
    }()

    /// 上游的转场效果名（SetTransitionEffect 的 Value；这里只做 Cut / Fade / Wipe / Zoom / Stinger）。
    public static let upstreamTransitionEffects = [
        "Cut", "Fade", "Zoom", "Wipe", "Slide", "Fly", "CrossZoom", "FlyRotate", "Cube", "CubeZoom", "VerticalWipe", "VerticalSlide", "Merge",
        "WipeReverse", "SlideReverse", "VerticalWipeReverse", "VerticalSlideReverse", "BarnDoor", "RollerDoor", "AlphaFade", "Stinger",
    ]

    /// 上游有、这里明确不做的函数（精确名字；Companion 模块的动作表和常用快捷函数）。调用它们返回 NotImplemented + 文案。
    public static let knownUnimplemented: [String] = {
        var names: [String] = [
            // 转场
            "Slide", "Fly", "CrossZoom", "FlyRotate", "Cube", "CubeZoom", "VerticalWipe", "VerticalSlide", "Merge", "WipeReverse", "SlideReverse",
            "VerticalWipeReverse", "VerticalSlideReverse", "BarnDoor", "RollerDoor", "AlphaFade", "QuickPlay",
            // 输出
            "StartStopMultiCorder", "StartMultiCorder", "StopMultiCorder", "StartStopExternal", "StartExternal", "StopExternal",
            "Fullscreen", "FullscreenOff", "FullscreenOn", "StartSRTOutput", "StopSRTOutput", "StartStopSRTOutput",
            "Snapshot", "SnapshotInput", "WriteDurationToRecordingLog", "StartPlayList", "StopPlayList", "PlayPause", "Play", "Pause", "Restart",
            "NextItem", "PreviousItem", "NextPicture", "PreviousPicture", "SetPosition", "SetCountdown", "StartCountdown", "StopCountdown",
            "PauseCountdown", "AdjustCountdown", "SetOutputFullscreen", "SetOutputFullscreen2", "SetOutputExternal2",
            // 叠加 / 输入
            "SetZoom", "SetCrop", "SetPanX", "SetPanY", "SetAlpha", "SetFrameDelay", "AddInput", "RemoveInput", "SetText", "SetImage", "SetColor",
            "SetInputName2", "SelectTitlePreset", "NextTitlePreset", "PreviousTitlePreset", "TitleBeginAnimation",
            // 音频
            "AudioAuto", "AudioAutoOn", "AudioAutoOff", "BusXSolo", "BusXSoloOn", "BusXSoloOff", "BusXSendToMaster", "BusXSendToMasterOn",
            "BusXSendToMasterOff", "SetGain", "SetGainChannel1", "SetGainChannel2", "SetVolumeFade", "SetMasterVolumeFade", "SetBusAVolumeFade",
            "SetBusBVolumeFade", "SetVolumeChannel1", "SetVolumeChannel2", "SetVolumeChannelMixer", "SetVolumeBusMixer", "AudioPluginOnOff",
            "AudioPluginOn", "AudioPluginOff", "AudioPluginShow", "MasterAudioPluginOnOff", "MasterAudioPluginOn", "MasterAudioPluginOff",
            "MasterAudioPluginShow", "SetHeadphonesVolume2", "SoloPFL", "SoloPFLOn", "SoloPFLOff",
            // 其他
            "ScriptStart", "ScriptStop", "ScriptStopAll", "KeyPress", "SendKeys", "DataSourceNextRow", "DataSourcePreviousRow", "DataSourceSelectRow",
            "DataSourceAutoNextOn", "DataSourceAutoNextOff", "DataSourceAutoNext", "SaveVideoDelay", "Undo", "SetMultiViewOverlay", "SetLayer",
            "MultiViewOverlay", "MultiViewOverlayOn", "MultiViewOverlayOff", "SetOutput2", "SetOutput3", "SetOutput4",
            // X51（W5-O）：上游真有、前缀族又没盖住的 31 个（原来当"不认识"回 400；清单 = docs/ui-study/附录/核对-VF5-动作目录.md §3.2）。
            // 只补精确名字，不加 NDI / Auto / Streaming 这类前缀族：那样编出来的 NDIAnything 也会变成 501（VF5 §3.4）
            "ActivatorRefresh", "AudioChannelMatrixApplyPreset", "AudioMixerShowHide",
            "StreamingSetKey", "StreamingSetURL", "StreamingSetUsername", "StreamingSetPassword",
            "ChangeCountdown", "SuspendCountdown", "ResumeRender",
            "AutoPauseOn", "AutoPauseOff", "AutoPlayOn", "AutoPlayOff", "AutoPlayFirst", "AutoPlayFirstOn", "AutoPlayFirstOff",
            "AutoPlayNext", "AutoPlayNextOn", "AutoPlayNextOff", "AutoRestartOn", "AutoRestartOff",
            "ColourCorrectionAuto", "ColourCorrectionReset", "MoveMultiViewOverlay",
            "NDISelectSourceByName", "NDISelectSourceByIndex", "NDIStartRecording", "NDIStopRecording",
            "OpenPreset", "LastPreset",
        ]
        for k in 1...4 { names += ["OverlayInput\(k)Zoom", "PreviewOverlayInput\(k)"] }
        for k in 5...8 { names += ["OverlayInput\(k)", "OverlayInput\(k)In", "OverlayInput\(k)Out", "OverlayInput\(k)Off", "OverlayInput\(k)Last", "OverlayInput\(k)Zoom", "PreviewOverlayInput\(k)"] }
        for k in 2...8 { names += ["Stinger\(k)"] }
        for k in 1...8 { names += ["SetStingerGTInput\(k)"] }
        for k in 1...4 { names += ["SetDynamicInput\(k)", "SetDynamicValue\(k)", "Effect\(k)", "Effect\(k)On", "Effect\(k)Off", "SetEffect\(k)Strength", "SetOutput\(k)"] }
        return names
    }()

    /// 上游函数族的前缀（Replay*、Title*、List*、PTZ*、Browser*、Call*、VirtualSet*、Zoom* 等）：名字以它们开头的也算"上游有"。
    public static let knownUnimplementedPrefixes = [
        "Replay", "Title", "List", "PTZ", "Browser", "VideoCall", "Call", "VirtualSet", "SetLayer", "Layer", "SetDynamic", "SetVolumeChannel",
        "SetVolumeBus", "MultiCorder", "SetImage", "SetText", "SetColor", "SetCountdown", "SetOutput", "Effect", "SetEffect", "ZoomIn", "ZoomOut",
        "Bus", "MasterAudioPlugin", "AudioPlugin", "SetHeadphones", "SetBus", "Stinger", "Transition", "SetTransition", "OverlayInput", "PreviewOverlayInput",
        "DataSource", "Script", "SetPan", "SetZoom", "SetCrop", "SetAlpha", "SetFrame", "SetGain", "Snapshot", "Fullscreen", "StartStop", "Start", "Stop",
        "Next", "Previous", "Select", "Save", "Load", "Set", "Undo", "Key", "Send", "Play", "Pause", "Restart",
    ]

    /// 是否上游已知的函数名（精确表或前缀族）。
    public static func isKnownUpstream(_ name: String) -> Bool {
        let lower = name.lowercased()
        if knownUnimplemented.contains(where: { $0.lowercased() == lower }) { return true }
        return knownUnimplementedPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }
}
