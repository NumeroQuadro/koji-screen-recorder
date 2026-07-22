import CoreMedia

enum MonotonicTimestampDecision: Equatable, Sendable {
    case accepted
    case invalid
    case duplicate
    case regressing
}

/// Writer policy: accept only valid, numeric, strictly increasing presentation timestamps.
/// Duplicate and regressing samples are dropped before they reach AVAssetWriter.
struct MonotonicTimestampValidator: Sendable {
    private(set) var latestAcceptedTime: CMTime?

    mutating func evaluate(_ time: CMTime) -> MonotonicTimestampDecision {
        guard CMTIME_IS_VALID(time), CMTIME_IS_NUMERIC(time), time.timescale > 0 else {
            return .invalid
        }

        guard let latestAcceptedTime else {
            self.latestAcceptedTime = time
            return .accepted
        }

        switch CMTimeCompare(time, latestAcceptedTime) {
        case ..<0:
            return .regressing
        case 0:
            return .duplicate
        default:
            self.latestAcceptedTime = time
            return .accepted
        }
    }
}
