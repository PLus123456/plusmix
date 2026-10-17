// Codex 2026-10-13 全项目 debug 审查新增的四条 App 回归探针（reports/codex-debug-audit-20261013-DebugAuditTests.swift.txt，报告 §2），
// W5-P（prompt 119）原样搬进来当"先写红测试"：断言一条没改，只把函数名换成带编号的 testD04_ / testD06_ / testD16_ / testK01_；
// D16 那条自己的 UserDefaults suite 换成固定名字、用前先清（reports/w5-app-followups.md §5 第 4 条：UUID 名会在 ~/Library/Preferences 留一堆小 plist）。
// 期望的行为（用户 2026-10-17 定）：ISO 录制中换源跟着新来源继续录、Recorder 不断；开录遇到同名文件自动加后缀、永不删旧文件。
import AppKit
import XCTest
import SwitcherContracts
import SwitcherEngine
import SwitcherISO
@testable import Switcher

/// Debug audit regression probes. The assertions express the intended behavior.
@MainActor
final class DebugAuditTests: XCTestCase {
    func testK01_startRecordingMustPreserveExistingFile() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plusmix-record-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("fixed.mov")
        let priorContents = Data("AUDIT previous recording must survive".utf8)
        try priorContents.write(to: existing)
        var settings = try XCTUnwrap(session.state.output(1)).settings
        settings.record?.directory = directory.path
        settings.record?.fileNamePattern = "fixed"
        session.send(.setOutputSettings(output: 1, settings: settings))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(1)?.settings.record?.directory == directory.path })
        session.send(.startRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[1] != nil })
        let actual = try? Data(contentsOf: existing)
        print("AUDIT record collision: previousBytes=\(priorContents.count), currentBytes=\(actual?.count ?? -1), target=\(session.outputs.recorders[1]?.url.path ?? "nil")")
        XCTAssertEqual(actual, priorContents, "Starting recording must use a unique path or reject, not delete the existing recording")
        session.send(.stopRecord(output: 1))
        XCTAssertTrue(AppTest.waitUntil(10) { session.outputs.recorders[1] == nil })
    }

    func testD06_isoRecordingMustFollowReplacedInputSource() throws {
        let session = try AppTest.freshSession()
        try AppTest.addSynthetics(session, count: 1)
        let input = try XCTUnwrap(session.state.input(1))
        let iso = ISORoutes.makeISOOutput(for: input, in: session.state,
                                         defaultDirectory: AppTest.controller.documents.recordDirectory)
        session.send(.addOutput(config: iso))
        XCTAssertTrue(AppTest.waitUntil(3) { session.state.output(iso.number) != nil })
        session.send(.startRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(5) { session.outputs.recorders[iso.number] != nil })
        let entry = try XCTUnwrap(session.outputs.recorders[iso.number])
        let tap = try XCTUnwrap(entry.consumer as? ISOFrameTap)
        XCTAssertTrue(AppTest.waitUntil(5) { tap.counters.forwarded > 30 })
        let oldInput = try XCTUnwrap(session.inputs.entries[1]?.input)
        session.send(.setInputSource(input: 1, source: AppTest.syntheticConfig(number: 1, gray: 220).source))
        XCTAssertTrue(AppTest.waitUntil(5) { session.inputs.entries[1].map { $0.input !== oldInput } ?? false })
        AppTest.pump(seconds: 0.5)
        let first = tap.counters
        AppTest.pump(seconds: 1)
        let last = tap.counters
        print("AUDIT ISO after source change: lastSequence=\(first.lastSequence)->\(last.lastSequence), forwardedDelta=\(last.forwarded-first.forwarded), repeatedDelta=\(last.repeated-first.repeated)")
        XCTAssertGreaterThan(last.forwarded, first.forwarded, "The output must still be consuming program ticks")
        XCTAssertNotEqual(last.lastSequence, first.lastSequence, "ISO must record new frames after changing the source")
        session.send(.stopRecord(output: iso.number))
        XCTAssertTrue(AppTest.waitUntil(10) { session.outputs.recorders[iso.number] == nil })
    }

    func testD04_overlappingOpenMustNotSaveFirstShowOverSecondFile() throws {
        _ = try AppTest.freshSession()
        let controller = AppTest.controller
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plusmix-open-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("A.switcher.json")
        let b = directory.appendingPathComponent("B.switcher.json")
        var showA = controller.documents.emptyShow(name: "A")
        showA.inputs = [AppTest.syntheticConfig(number: 1, gray: 60)]
        var showB = controller.documents.emptyShow(name: "B")
        showB.inputs = [AppTest.syntheticConfig(number: 2, gray: 180)]
        let store = ShowStore()
        try store.save(showA, to: a)
        try store.save(showB, to: b)
        let first = AppTest.expectationBox(), second = AppTest.expectationBox()
        controller.requestOpenShow(url: a) { first.value = true }
        controller.requestOpenShow(url: b) { second.value = true }
        XCTAssertTrue(AppTest.waitUntil(30) { first.value && second.value && controller.session?.isRunning == true })
        let session = try XCTUnwrap(controller.session)
        let target = try XCTUnwrap(controller.documents.currentURL)
        print("AUDIT overlapping open: session=\(session.name), target=\(target.lastPathComponent), inputs=\(session.state.inputs.map(\.number))")
        XCTAssertEqual(session.name, AppController.showName(for: target), "Loaded show and save destination must stay paired")
        controller.save()
        let after = try store.load(from: b)
        print("AUDIT B after Save: inputs=\(after.inputs.map(\.number))")
        XCTAssertEqual(after.inputs.map(\.number), [2], "Saving A must never overwrite B")
    }

    func testD16_lastSessionMustPreserveRelativeMediaBase() throws {
        let suite = "plusmix.audit.autosave"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plusmix-autosave-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let docs = ShowDocuments(defaults: defaults, recordDirectory: directory.path,
                                 autosaveURL: directory.appendingPathComponent("LastSession.switcher.json"))
        var show = docs.emptyShow(name: "Relative")
        show.inputs = [InputConfig(number: 1, name: "Asset", source: .image(path: "asset.png"))]
        let showURL = directory.appendingPathComponent("Relative.switcher.json")
        try ShowStore().save(show, to: showURL)
        let opened = try docs.load(from: showURL)
        let original = InputRuntime.resolvingMediaPaths(opened.inputs[0], against: docs.mediaBaseDirectory)
        docs.autosave(opened)
        let restored = try XCTUnwrap(docs.loadAutosave())
        docs.startNew() // Same order as requestOpenLastSession.
        let actual = InputRuntime.resolvingMediaPaths(restored.inputs[0], against: docs.mediaBaseDirectory)
        print("AUDIT relative restore: original=\(original.source), restored=\(actual.source)")
        XCTAssertEqual(actual.source, original.source, "LastSession must restore the same media file")
    }
}
