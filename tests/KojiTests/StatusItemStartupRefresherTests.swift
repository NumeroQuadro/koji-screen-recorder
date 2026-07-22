import XCTest
@testable import Koji

@MainActor
final class StatusItemStartupRefresherTests: XCTestCase {
    func testLaunchRefreshRunsRecoveryMicrophoneAndPersistedFacecamWork() async {
        var actions: [String] = []
        let refresher = StatusItemStartupRefresher(
            recoverManagedRecordings: {
                actions.append("recover-managed-recordings")
            },
            refreshMicrophones: {
                actions.append("refresh-microphones")
            },
            restoreFacecam: {
                actions.append("restore-facecam")
            }
        )

        await refresher.run()

        XCTAssertEqual(
            actions,
            ["recover-managed-recordings", "refresh-microphones", "restore-facecam"]
        )
    }
}
