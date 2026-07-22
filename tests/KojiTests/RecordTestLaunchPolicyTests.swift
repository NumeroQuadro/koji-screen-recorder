#if DEBUG
import XCTest
@testable import Koji

final class RecordTestLaunchPolicyTests: XCTestCase {
    func testMissingRecordTestArgumentDoesNotEnableTestMode() {
        XCTAssertNil(
            RecordTestLaunchPolicy.configuration(
                arguments: ["Koji"],
                environment: [RecordTestLaunchPolicy.optInEnvironmentKey: "1"]
            )
        )
    }

    func testRecordTestArgumentWithoutEnvironmentOptInDoesNotEnableTestMode() {
        XCTAssertNil(
            RecordTestLaunchPolicy.configuration(
                arguments: ["Koji", "--record-test"],
                environment: [:]
            )
        )
    }

    func testEnvironmentOptInMustEqualOneExactly() {
        for value in ["", "0", "true", "YES"] {
            XCTAssertNil(
                RecordTestLaunchPolicy.configuration(
                    arguments: ["Koji", "--record-test"],
                    environment: [RecordTestLaunchPolicy.optInEnvironmentKey: value]
                ),
                value
            )
        }
    }

    func testExplicitDebugOptInEnablesRecordTestWithMicrophone() {
        XCTAssertEqual(
            RecordTestLaunchPolicy.configuration(
                arguments: ["Koji", "--record-test"],
                environment: [RecordTestLaunchPolicy.optInEnvironmentKey: "1"]
            ),
            .init(disablesMicrophone: false)
        )
    }

    func testNoMicrophoneModifierAppliesOnlyToEnabledRecordTest() {
        XCTAssertNil(
            RecordTestLaunchPolicy.configuration(
                arguments: ["Koji", "--record-test-no-mic"],
                environment: [RecordTestLaunchPolicy.optInEnvironmentKey: "1"]
            )
        )

        XCTAssertEqual(
            RecordTestLaunchPolicy.configuration(
                arguments: ["Koji", "--record-test", "--record-test-no-mic"],
                environment: [RecordTestLaunchPolicy.optInEnvironmentKey: "1"]
            ),
            .init(disablesMicrophone: true)
        )
    }
}
#endif
