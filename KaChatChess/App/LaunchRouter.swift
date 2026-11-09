import Foundation

enum LaunchRoute: Equatable {
    case loading
    case mainApp
    case onboarding
    /// A wallet record is on the device but its keys are not (see `WalletRecoveryView`).
    case recovery
}

enum LaunchRouter {
    static func route(
        isWalletMetadataLoading: Bool,
        hasCurrentWallet: Bool,
        needsKeyRecovery: Bool = false
    ) -> LaunchRoute {
        if hasCurrentWallet {
            return .mainApp
        }
        if isWalletMetadataLoading { return .loading }
        return needsKeyRecovery ? .recovery : .onboarding
    }
}
