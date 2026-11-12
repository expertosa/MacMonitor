import XCTest
@testable import MacMonitorCore

final class LocalizationTests: XCTestCase {
    func testArabicIsRightToLeft() {
        XCTAssertTrue(InterfaceDirection.isRightToLeft(["ar"]))
        XCTAssertTrue(InterfaceDirection.isRightToLeft(["ar-SA"]))
        XCTAssertFalse(InterfaceDirection.isRightToLeft(["en"]))
        XCTAssertFalse(InterfaceDirection.isRightToLeft(["en-US", "ar"]))
        XCTAssertFalse(InterfaceDirection.isRightToLeft([]))
    }

    func testMissingTranslationKeepsEnglishKey() {
        XCTAssertEqual(localizedUI("Memory"), "Memory")
        XCTAssertEqual(localizedUI("MacMonitor"), "MacMonitor")
    }
}
