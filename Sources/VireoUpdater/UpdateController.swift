import Foundation
import os
@preconcurrency import Sparkle

/// Owns the Sparkle `SPUUpdater` and the custom ``UpdateDriver``, and exposes the
/// observable ``UpdateModel`` the pill renders from.
///
/// Construct one at app launch, call ``start()`` once, and hand `model` to the UI.
/// Scheduled background checks (enabled via Info.plist) make the pill appear on
/// their own when a new version is published; ``checkForUpdates()`` backs a
/// "Check for Updates…" menu item.
///
/// The updater stays **dormant** unless the running bundle is properly configured
/// for updates (a feed URL and an EdDSA public key are present). That keeps ad-hoc
/// dev builds — which have no signing key baked in — from ever surfacing a pill or
/// attempting an install.
@MainActor
public final class UpdateController: ObservableObject {

    /// The state the UI observes.
    public let model = UpdateModel()

    private let hostBundle: Bundle
    private let log = Logger(subsystem: "com.materauscher.vireo", category: "updater")

    private var updater: SPUUpdater?
    private var driver: UpdateDriver?
    private var started = false

    public init(hostBundle: Bundle = .main) {
        self.hostBundle = hostBundle
    }

    /// Whether this build carries the configuration Sparkle needs to operate: a
    /// feed URL to poll and an EdDSA public key to verify downloads against. Dev
    /// builds ship an empty `SUPublicEDKey`, so they read as unconfigured.
    public var isConfigured: Bool {
        guard let key = infoString("SUPublicEDKey"), !key.isEmpty,
              let feed = infoString("SUFeedURL"), !feed.isEmpty,
              URL(string: feed) != nil
        else { return false }
        return true
    }

    /// Start the updater. Safe to call once; a no-op on unconfigured builds.
    public func start() {
        guard !started else { return }
        started = true

        guard isConfigured else {
            log.notice("updater dormant: no SUFeedURL / SUPublicEDKey configured (dev build)")
            return
        }

        let driver = UpdateDriver(model: model)
        self.driver = driver

        let updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: driver,
            delegate: nil
        )
        self.updater = updater

        // Retry after an error re-runs a check.
        model.onRetry = { [weak updater] in updater?.checkForUpdates() }

        do {
            try updater.start()
            log.notice("updater started; feed=\(self.infoString("SUFeedURL") ?? "?", privacy: .public)")
        } catch {
            self.updater = nil
            self.driver = nil
            log.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Manually check for updates (menu item). Silent if unconfigured.
    public func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Whether a manual check can run right now (drives menu enablement).
    public var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    private func infoString(_ key: String) -> String? {
        hostBundle.object(forInfoDictionaryKey: key) as? String
    }
}
