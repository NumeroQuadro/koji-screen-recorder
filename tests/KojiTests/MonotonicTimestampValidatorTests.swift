import CoreMedia
import XCTest
@testable import Koji

final class MonotonicTimestampValidatorTests: XCTestCase {
    func testAcceptsOnlyStrictlyIncreasingNumericTimes() {
        var validator = MonotonicTimestampValidator()

        XCTAssertEqual(validator.evaluate(.invalid), .invalid)
        XCTAssertEqual(validator.evaluate(time(1)), .accepted)
        XCTAssertEqual(validator.evaluate(time(1)), .duplicate)
        XCTAssertEqual(validator.evaluate(time(0.9)), .regressing)
        XCTAssertEqual(validator.evaluate(time(1.1)), .accepted)
        XCTAssertEqual(validator.latestAcceptedTime, time(1.1))
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}
