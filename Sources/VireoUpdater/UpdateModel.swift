import Foundation
import Combine

/// The observable state the update pill renders from.
///
/// This is the single UI-facing surface of the updater: the ``UpdateDriver``
/// (a Sparkle `SPUUserDriver`) writes transitions here, and SwiftUI reads them.
/// Keeping the model UI-agnostic (Combine `ObservableObject`, no SwiftUI import)
/// lets the Sparkle plumbing stay in this package while the pill view lives in
/// the app target.
///
/// All access is main-actor: every `SPUUserDriver` callback is delivered on the
/// main thread, and SwiftUI reads on the main actor.
@MainActor
public final class UpdateModel: ObservableObject {

    /// Where the update flow currently sits. The pill maps each phase to an
    /// icon / progress ring / label.
    public enum Phase: Equatable, Sendable {
        /// No update activity. Pill hidden.
        case idle
        /// A check is in flight (kept silent for scheduled checks — the pill
        /// only surfaces this for a *user-initiated* check).
        case checking
        /// A newer version was found and is waiting for the user to act.
        case available
        /// The update package is downloading.
        case downloading
        /// The downloaded package is being extracted / prepared.
        case extracting
        /// The update is being installed; the app is about to relaunch.
        case installing
        /// Something went wrong. `errorMessage` carries the detail.
        case error
    }

    /// The current phase.
    @Published public private(set) var phase: Phase = .idle

    /// Human-readable version string of the available update (e.g. "0.2.0"),
    /// when known.
    @Published public private(set) var availableVersion: String?

    /// Fractional progress `0...1` for `.downloading` / `.extracting`, or `nil`
    /// when the length is unknown (show an indeterminate indicator).
    @Published public private(set) var progress: Double?

    /// Detail for the `.error` phase.
    @Published public private(set) var errorMessage: String?

    /// The user hid the pill for the currently-offered version. Reset whenever a
    /// *new* version is offered so a later release resurfaces it.
    @Published public private(set) var dismissedVersion: String?

    // Actions wired by the driver/controller for the current phase. Non-Sendable
    // closures are fine: everything here runs on the main actor.
    var onInstall: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onRetry: (() -> Void)?

    public init() {}

    /// Whether the pill should currently be on screen. Silent phases (`idle`,
    /// scheduled `checking`) and a dismissed "available" offer stay hidden.
    public var isPillVisible: Bool {
        switch phase {
        case .idle:
            return false
        case .checking:
            // Only shown when the user explicitly asked (see `beginChecking`).
            return userInitiatedCheck
        case .available:
            return dismissedVersion == nil || dismissedVersion != availableVersion
        case .downloading, .extracting, .installing, .error:
            return true
        }
    }

    /// True while a check that the *user* started is running (so the pill can
    /// show a transient "Checking…" for that case only).
    private(set) var userInitiatedCheck = false

    /// Whether the pill exposes a dismiss affordance in the current phase.
    /// Active install work isn't dismissable; an offer or an error is.
    public var isDismissable: Bool {
        switch phase {
        case .available, .error: return true
        default: return false
        }
    }

    // MARK: Driver-facing transitions

    func beginChecking(userInitiated: Bool) {
        userInitiatedCheck = userInitiated
        set(.checking)
    }

    func offerUpdate(version: String?, install: @escaping () -> Void, dismiss: @escaping () -> Void) {
        // A brand-new version clears any earlier dismissal.
        if version != availableVersion { dismissedVersion = nil }
        availableVersion = version
        progress = nil
        errorMessage = nil
        onInstall = install
        onDismiss = dismiss
        set(.available)
    }

    func beginDownloading() {
        progress = nil
        onDismiss = nil
        set(.downloading)
    }

    func setDownloadProgress(_ fraction: Double?) {
        progress = fraction.map { min(1, max(0, $0)) }
        if phase != .downloading { set(.downloading) }
    }

    func beginExtracting() {
        progress = nil
        set(.extracting)
    }

    func setExtractionProgress(_ fraction: Double) {
        progress = min(1, max(0, fraction))
        if phase != .extracting { set(.extracting) }
    }

    func beginInstalling() {
        progress = nil
        onDismiss = nil
        set(.installing)
    }

    func setError(_ message: String, retry: (() -> Void)?) {
        errorMessage = message
        onRetry = retry
        progress = nil
        set(.error)
    }

    /// Return to the resting state (no pill).
    func reset() {
        availableVersion = nil
        progress = nil
        errorMessage = nil
        onInstall = nil
        onDismiss = nil
        onRetry = nil
        userInitiatedCheck = false
        set(.idle)
    }

    // MARK: UI-facing intents

    /// The user clicked the pill: begin (or resume) installing.
    public func install() { onInstall?() }

    /// The user dismissed the offer or error.
    public func dismiss() {
        if phase == .available { dismissedVersion = availableVersion }
        onDismiss?()
        // For an error, just clear the pill; for an offer, Sparkle is told to
        // dismiss (it reminds again on the next scheduled check).
        if phase == .error { reset() }
    }

    /// Retry after an error.
    public func retry() {
        let retry = onRetry
        reset()
        retry?()
    }

    private func set(_ newPhase: Phase) {
        guard phase != newPhase else { return }
        phase = newPhase
    }

    /// Build a model pinned to a given visual state, for SwiftUI previews and the
    /// pill snapshot harness. Not used in the live update flow.
    public static func preview(
        _ phase: Phase,
        version: String? = nil,
        progress: Double? = nil,
        error: String? = nil
    ) -> UpdateModel {
        let model = UpdateModel()
        model.availableVersion = version
        model.progress = progress
        model.errorMessage = error
        model.onInstall = {}
        model.onDismiss = {}
        model.onRetry = {}
        model.userInitiatedCheck = (phase == .checking)
        model.phase = phase
        return model
    }
}
