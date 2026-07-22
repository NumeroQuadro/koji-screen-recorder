#if DEBUG
import Foundation

enum RecordTestLaunchPolicy {
    static let optInEnvironmentKey = "KOJI_ENABLE_RECORD_TEST"

    struct Configuration: Equatable {
        let disablesMicrophone: Bool
    }

    static func configuration(
        arguments: [String],
        environment: [String: String]
    ) -> Configuration? {
        guard environment[optInEnvironmentKey] == "1" else { return nil }
        guard arguments.contains("--record-test") else { return nil }

        return Configuration(
            disablesMicrophone: arguments.contains("--record-test-no-mic")
        )
    }
}
#endif
