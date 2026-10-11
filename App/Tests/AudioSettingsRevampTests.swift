// W5-K（prompt 97 交付 4）音频设置窗与调音台的其余几条：每页顶部"启用" + 参数 + 复位（J4）、常规页只读格式与推子读数、窗左的表读调音台同一份数（J4 / J5）、
// 调音台布局：Master 常驻、总线组 / 输入组可收起、表头不折行（J6 / X31 / V-04）、Master 条的监听与响度详情（J7 / V08）。主用例（开着窗按空格照样 Cut）在 PanelsRevampTests。
import AppKit
import SwiftUI
import XCTest
import SwitcherContracts
import SwitcherAudio
@testable import Switcher

@MainActor
final class AudioSettingsRevampTests: XCTestCase {
    func testPanels_audioSettingsPagesEnableAndReset() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let w = try XCTUnwrap(panels.showAudioSettings(.bus(.master), page: .eq))
        let m = w.model
        XCTAssertEqual(m.page, .eq, "总线条的'效果 (n)'直达均衡页")
        XCTAssertNil(m.effectsBanner, "总线效果已生效（88）：不挂横幅")
        // 均衡：启用 = 加一段（关着就是旁路、段留着）
        XCTAssertFalse(m.eqEnabled)
        m.setEQEnabled(true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.filter { $0.id == AudioEffectParams.parametricEQID }.count == 1 })
        m.addEQBand()
        m.bandBinding(1, \.gainDb).wrappedValue = 6
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.compactMap { AudioEffectParams.number($0, "gainDb") } == [0, 6] })
        XCTAssertEqual(m.editor.eq.map(\.centerHz), [100, 1000], "新加的段默认低 / 中 / 高")
        m.setEQEnabled(false)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.allSatisfy { !$0.enabled } && session.state.audio.buses[0].effects.count == 2 }, "关 = 旁路、参数留着")
        m.resetEQ()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.compactMap { AudioEffectParams.number($0, "gainDb") } == [0, 0] })
        XCTAssertFalse(m.eqEnabled, "复位不动开关")
        // 压缩：启用 → 一格；关 → enabled false、参数留着；复位 → 默认参数
        m.page = .compressor
        m.setCompressorEnabled(true)
        m.binding(\.dynamics.thresholdDb).wrappedValue = -30
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.first { $0.id == AudioEffectParams.dynamicsProcessorID }.flatMap { AudioEffectParams.number($0, "thresholdDb") } == -30 })
        m.setCompressorEnabled(false)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.first { $0.id == AudioEffectParams.dynamicsProcessorID }?.enabled == false })
        XCTAssertEqual(m.editor.dynamics.thresholdDb, -30, "关着参数留着")
        m.resetCompressor()
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.first { $0.id == AudioEffectParams.dynamicsProcessorID }.flatMap { AudioEffectParams.number($0, "thresholdDb") } == EffectChainEditor.Dynamics().thresholdDb })
        XCTAssertFalse(m.compressorEnabled, "复位不动开关")
        // 限幅（只总线）
        m.setLimiterEnabled(true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.audio.buses[0].effects.contains { $0.id == AudioEffectParams.peakLimiterID && $0.enabled } })
        // 界面范围 ⊆ 引擎钳位（G6 追加 ②）：滑块就是 EffectEditorRanges
        XCTAssertEqual(EffectEditorRanges.limAttackSeconds, 0.001...0.03)

        // 输入的窗：没有限幅页；均衡 / 压缩页挂"效果尚未作用到声音"（每路 102 之前）；改动走 setInputSettings
        let wi = try XCTUnwrap(panels.showAudioSettings(.input(1)))
        XCTAssertEqual(wi.model.pages, [.general, .eq, .compressor])
        XCTAssertNil(wi.model.effectsBanner, "每路效果已接（102）：不挂横幅")
        wi.model.setCompressorEnabled(true)
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.input(1)?.settings.effects.contains { $0.id == AudioEffectParams.dynamicsProcessorID } == true })
        XCTAssertEqual(session.state.input(1)?.settings.audio.gainDb, 0, "只换效果链，别的音频设置不动")
        XCTAssertEqual(session.control.bus.counters.rejected, 0)
    }

    func testPanels_audioSettingsGeneralPageAndPostFaderMeter() throws {
        let session = try AppTest.freshSession()
        session.send(.addInput(config: AppTest.syntheticConfig(number: 1, audio: true)))
        XCTAssertEqual(AppTest.waitLive(session, input: 1, timeout: 10), .live)
        session.send(.busGain(bus: .master, dB: -6))
        let wc = AppTest.controller.windowController
        let panels = AppTest.controller.panels
        defer { panels.closeAll() }
        let w = try XCTUnwrap(panels.showAudioSettings(.bus(.master)))
        XCTAssertEqual(w.model.page, .general)
        XCTAssertEqual(w.model.formatText, "48 kHz · 立体声")
        XCTAssertTrue(AppTest.waitUntil(3) { w.model.faderText == "-6.0 dB" }, "推子读数跟快照：\(w.model.faderText)")
        // 窗左的表 = 调音台同一份 50 ms 读数（推子后）
        let meters = wc.mixerPanel.meters
        XCTAssertTrue(AppTest.waitUntil(5) { (meters.busPeakDb[.master]?.max() ?? -200) > -60 }, "Master 应有读数")
        XCTAssertEqual(w.model.meter(meters).peak, meters.busPeakDb[.master])
        XCTAssertEqual(w.model.meter(meters).rms, meters.busRmsDb[.master])
        let wi = try XCTUnwrap(panels.showAudioSettings(.input(1)))
        XCTAssertEqual(wi.model.meter(meters).peak, meters.inputPeakDb[1])
        // 同一条只开一个；齿轮再点 = 置前并切页
        XCTAssertTrue(panels.showAudioSettings(.bus(.master), page: .limiter) === w)
        XCTAssertEqual(w.model.page, .limiter)
        XCTAssertNil(panels.showAudioSettings(.input(9)), "没有的输入不开窗")
        // 删掉这一路：它的音频设置窗跟着关
        session.send(.removeInput(input: 1))
        XCTAssertTrue(AppTest.waitUntil(3) { panels.audioSettingsWindows[.input(1)] == nil })
    }

    func testPanels_mixerLayoutMasterPinnedGroupsCollapsible() throws {
        _ = try AppTest.freshSession()
        let model = AppTest.controller.windowController.mixerPanel.model
        XCTAssertTrue(model.inputsExpanded, "输入组默认展开")
        XCTAssertFalse(model.busesExpanded, "总线组默认收起（Master 常驻）")
        // Master + 三条总线 + 收起的输入竖条放得下 340 pt 的调音台（X31：总线不再被输入挤出视野）
        let strip = mixerBusStripWidth + 8   // 条宽 + 左右各 4 的内边距
        XCTAssertLessThanOrEqual(4 * strip + 20 + 4 * 4 + 12, Theme.mixerPanelWidth, "Master + Bus A / B / 耳机 + 竖条 + 间距")
        // 表头不折行（V-04）：调音台最窄 216 pt 时也只占一行
        for width in [216.0, 340.0] {
            let host = NSHostingView(rootView: MixerHeaderView(model: model).frame(width: width))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.height, 32, "宽 \(width) 时表头高 \(host.fittingSize.height)：不该折行")
        }
        model.inputsExpanded = false
        model.busesExpanded = true
        XCTAssertFalse(model.inputsExpanded)
        model.inputsExpanded = true
        model.busesExpanded = false
    }

    func testPanels_masterListenAndLoudnessDetails() {
        let model = MixerModel()
        XCTAssertFalse(MixerModel.listenToOtherBusSupported, "耳机听所选总线要音频引擎支持（问题单 W5K-w1-audio-monitor-selected-bus）")
        XCTAssertFalse(model.listen(.master), "引擎不支持：不换")
        XCTAssertEqual(model.listenBus, .headphones)
        XCTAssertTrue(model.listen(.headphones))
        // 响度详情读 Stats（1 Hz）
        let master = Stats.AudioCounters.BusMeter(bus: "master", peakDb: [-6, -7], truePeakDb: [-1.24, -2], lufsM: -21.04, lufsS: -23.0, lufsI: -24.46, lra: 5.2)
        let silent = Stats.AudioCounters.BusMeter(bus: "busA", peakDb: [-120, -120], truePeakDb: [-120, -120], lufsM: -120, lufsS: -120, lufsI: -120, lra: 0)
        let stats = Stats(ts: 1, tick: Tick(60), renderMs: 1, missedRender: 0, jitterMs: 0, perInput: [:], encoder: [],
                          audio: Stats.AudioCounters(dropouts: 0, underruns: 0, meters: Stats.AudioCounters.Meters(buses: [master, silent])), rssMb: 1, cpuPct: 1, gpuPct: 1)
        model.apply(stats: stats)
        let rows = try? XCTUnwrap(model.loudness[.master]).rows
        XCTAssertEqual(rows?.map(\.label), ["瞬时（400 ms）", "短期（3 s）", "积分", "响度范围（LRA）", "真峰值"])
        XCTAssertEqual(rows?.map(\.value), ["-21.0 LUFS", "-23.0 LUFS", "-24.5 LUFS", "5.2 LU", "-1.2 dBTP"])
        XCTAssertEqual(model.loudness[.busA]?.rows.map(\.value), ["—", "—", "—", "0.0 LU", "—"], "静音写 —")
    }
}

@MainActor
final class AudioDeviceRevampTests: XCTestCase {
    /// J8 的细节：声道对不共用（选了别人正用的那一对，原来那条改不输出）、换设备只去掉这台没有的声道、恢复设备默认、存本机（UserDefaults 往返）、
    /// 没改过就存 nil（跟设备默认）、AudioRuntime 建引擎时把它换成 BusChannelMap、2 声道设备给"监听时临时占用 Master 声道"并写明尚未生效。
    func testAudio_busOutputMapStoredLocallyAndFitsDevice() throws {
        XCTAssertEqual(BusOutputMap.standard(outputChannels: 2), BusOutputMap(master: 0), "2 声道：只有 Master 1/2")
        XCTAssertEqual(BusOutputMap.standard(outputChannels: 8), BusOutputMap(master: 0, headphones: 2), "≥ 4 声道：耳机 3/4（与包里 standard 同口径）")
        XCTAssertEqual(BusOutputMap.standard(outputChannels: 8).busChannelMap, BusChannelMap.standard(outputChannels: 8))
        XCTAssertEqual(BusOutputMap(master: 0, busA: 4, busB: 6, headphones: 2).fitting(outputChannels: 6), BusOutputMap(master: 0, busA: 4, headphones: 2))
        XCTAssertEqual(BusOutputMap(master: 0).fitting(outputChannels: 1), BusOutputMap(master: 0), "单声道设备上 1/2 照留")

        let model = AudioOutputSettingsModel(device: .systemDefault, map: nil)
        model.devicesProvider = { [.init(name: "接口", outputChannels: 8), .init(name: "耳机", outputChannels: 2)] }
        model.reloadDevices()
        model.selectDevice(.named("接口"))
        XCTAssertEqual(model.map, .standard(outputChannels: 8), "没改过：跟设备默认")
        XCTAssertNil(model.storedMap, "没改过存 nil")
        model.setPair(.busB, first: 2)
        XCTAssertEqual(model.map, BusOutputMap(master: 0, busB: 2), "耳机原来在 3/4，让给 Bus B 后改不输出")
        XCTAssertEqual(model.lastDisplaced, .headphones)
        model.setPair(.headphones, first: 6)
        XCTAssertEqual(model.storedMap, BusOutputMap(master: 0, busB: 2, headphones: 6))
        model.selectDevice(.named("耳机"))
        XCTAssertEqual(model.map, BusOutputMap(master: 0), "换到 2 声道设备：这台没有的声道对去掉")
        XCTAssertTrue(model.offersBorrowMasterForMonitor)
        XCTAssertTrue(L("audioDevice.borrowMasterPending").contains("W5K-w1-audio-monitor-selected-bus"), "写明尚未生效与问题单")
        model.resetToDeviceDefault()
        XCTAssertNil(model.storedMap)
        model.selectDevice(.null)
        XCTAssertNil(model.outputChannels)
        XCTAssertNil(model.headphonesHint, "空设备不提示")
        XCTAssertEqual(model.pairChoices.map(\.title), ["不输出"])

        // 存本机：AppSettings 往返（JSON 进 UserDefaults）
        let suite = "com.plusmix.switcher.tests.busmap-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var s = AppSettings()
        s.busOutputMap = BusOutputMap(master: 0, busA: 2, busB: nil, headphones: 4)
        s.borrowMasterForMonitor = true
        s.save(to: defaults)
        let loaded = AppSettings.load(arguments: [], defaults: defaults)
        XCTAssertEqual(loaded.busOutputMap, s.busOutputMap)
        XCTAssertTrue(loaded.borrowMasterForMonitor)
        s.busOutputMap = nil
        s.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: AppSettings.Keys.busOutputMap), "nil = 跟设备默认，键删掉")

        // AudioRuntime 建引擎时传进去（空设备也带着，配置里看得到）
        let session = try AppTest.freshSession()
        let runtime = AudioRuntime(stateMachine: SwitcherSession.detachedStateMachine(), device: .null, busOutputMap: BusOutputMap(master: 0, busA: 2))
        XCTAssertEqual(runtime.engine.configuration.outputChannelMap, BusChannelMap(master: (0, 1), busA: (2, 3)))
        XCTAssertNil(runtime.outputChannelCount, "空设备没有声道数")
        XCTAssertNil(session.audio.engine.configuration.outputChannelMap, "测试宿主默认不带映射（跟设备默认）")
    }
}
