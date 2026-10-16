import XCTest
@testable import AskIslandCore

final class ModelsTests: XCTestCase {
    func testAnswerDisplay() {
        XCTAssertEqual(AskAnswer(selected: ["A", "B"], text: "x").display, "A, B; x")
        XCTAssertEqual(AskAnswer(selected: [], text: "x").display, "x")
    }
}
