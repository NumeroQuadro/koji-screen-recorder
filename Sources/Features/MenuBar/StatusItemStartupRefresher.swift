import Foundation

@MainActor
struct StatusItemStartupRefresher {
    private let recoverManagedRecordings: () async -> Void
    private let refreshMicrophones: () async -> Void
    private let restoreFacecam: () async -> Void

    init(
        recoverManagedRecordings: @escaping () async -> Void,
        refreshMicrophones: @escaping () async -> Void,
        restoreFacecam: @escaping () async -> Void
    ) {
        self.recoverManagedRecordings = recoverManagedRecordings
        self.refreshMicrophones = refreshMicrophones
        self.restoreFacecam = restoreFacecam
    }

    func run() async {
        await recoverManagedRecordings()
        await refreshMicrophones()
        await restoreFacecam()
    }
}
