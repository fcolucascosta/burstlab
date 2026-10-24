import XCTest
@testable import BurstCore

final class BurstRAWDecoderSelectionTests: XCTestCase {
    func testActualAscendingDeviceListSelectsNineDNGInsteadOfSix() {
        let actual = ["6.dng", "7", "7.dng", "8", "8.dng", "9.dng"]
        XCTAssertEqual(BurstRAWDecoderSelection.newest(supported: actual, current: "8"), "9.dng")
        XCTAssertEqual(BurstRAWDecoderSelection.newest(supported: Array(actual.reversed()), current: "8"), "9.dng")
    }
    func testNumericOrderingHandlesTenAndMinorVersionsAndKeepsNewerDefault() {
        XCTAssertEqual(BurstRAWDecoderSelection.newest(supported: ["9.dng", "10.dng", "9.2.dng"], current: "8"), "10.dng")
        XCTAssertEqual(BurstRAWDecoderSelection.newest(supported: ["8", "6.dng"], current: "9.dng"), "9.dng")
        XCTAssertEqual(BurstRAWDecoderSelection.newest(supported: ["9.1.dng", "9.2.dng"], current: "9"), "9.2.dng")
    }
    func testUnknownVersionsAndUnsupportedGuessesAreNotForced() {
        XCTAssertEqual(BurstRAWDecoderSelection.newest(supported: ["9.dng"], current: "future-decoder"), "future-decoder")
        XCTAssertEqual(BurstRAWDecoderSelection.newest(supported: ["future", "", ".dng", "9..1", "-1"], current: "8"), "8")
        XCTAssertEqual(BurstRAWDecoderSelection.newest(supported: [], current: "8"), "8")
    }
}
