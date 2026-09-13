import Foundation
import XCTest
import SwitcherContracts
@testable import SwitcherOutputs

final class RecordFileNamingTests: XCTestCase {
    func testRecordSettings_outputURL_expandsPatternAndSanitizes() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 14; comps.hour = 20; comps.minute = 5; comps.second = 9
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: comps)!
        let s = RecordSettings(directory: "/tmp/rec", fileNamePattern: "{show}-{date}-{time}-{output}")
        let url = s.outputURL(showName: "Sunday: Service/1", outputName: "ISO 2", date: date, calendar: cal)
        XCTAssertEqual(url.path, "/tmp/rec/Sunday- Service-1-2026-09-14-20-05-09-ISO 2.mov")
        let plain = RecordSettings(directory: "/tmp/rec", fileNamePattern: "fixed.mov")
        XCTAssertEqual(plain.outputURL(showName: "x", outputName: "y").lastPathComponent, "fixed.mov")
        let empty = RecordSettings(directory: "/tmp/rec", fileNamePattern: "{show}")
        XCTAssertEqual(empty.outputURL(showName: "  ", outputName: "y").lastPathComponent, "untitled.mov")
    }
}
