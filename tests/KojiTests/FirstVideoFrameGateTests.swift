import XCTest
@testable import Koji

final class FirstVideoFrameGateTests: XCTestCase {
    func testWaitReturnsTrueWhenFrameIsSignaled() async {
        let gate = FirstVideoFrameGate()

        Task {
            try? await Task.sleep(nanoseconds: 10_000_000)
            gate.signal()
        }

        let result = await gate.wait(timeout: 1)
        XCTAssertTrue(result)
    }

    func testWaitReturnsFalseAtStartupBoundWithoutFrame() async {
        let gate = FirstVideoFrameGate()

        let result = await gate.wait(timeout: 0.02)
        XCTAssertFalse(result)
    }

    func testSignalIsStickyAndResumesEveryWaiterOnce() async {
        let gate = FirstVideoFrameGate()

        async let first = gate.wait(timeout: 1)
        async let second = gate.wait(timeout: 1)
        gate.signal()
        gate.signal()

        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        let stickyResult = await gate.wait(timeout: 0)
        XCTAssertTrue(stickyResult)
    }
}
