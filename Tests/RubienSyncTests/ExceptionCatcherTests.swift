#if os(macOS)
import XCTest
import RubienExceptionCatcher

final class ExceptionCatcherTests: XCTestCase {

    func testReturnsNilWhenBlockDoesNotRaise() {
        let ex = ExceptionCatcher.catchException { }
        XCTAssertNil(ex)
    }

    func testReturnsExceptionWhenBlockRaises() {
        let ex = ExceptionCatcher.catchException {
            NSException(name: .genericException, reason: "test", userInfo: nil).raise()
        }
        XCTAssertNotNil(ex, "catchException must capture NSException so Swift callers can detect the failure")
        XCTAssertEqual(ex?.name, .genericException)
    }
}
#endif
