import Foundation
import AppKit
@preconcurrency import Sparkle

/// A Sparkle `SPUUserDriver` that shows **none** of Sparkle's stock windows and
/// instead drives ``UpdateModel`` — Vireo renders the whole update surface as a
/// small pill (mirrors how cmux drives Sparkle).
///
/// Sparkle marks `SPUUserDriver` as running on the main actor, so every callback
/// here is already on the main thread and writes the model directly.
@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
    let model: UpdateModel

    /// The reply Sparkle handed us for the current "update found" / "ready to
    /// install" prompt. We invoke it when the user clicks the pill (install) or
    /// dismisses it. Non-Sendable but only ever touched on the main actor.
    private var updateChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    /// Accumulated bytes / expected length for download progress.
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    init(model: UpdateModel) {
        self.model = model
        super.init()
    }

    // MARK: Permission

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        // Never show Sparkle's permission dialog. Vireo always enables scheduled
        // checks and keeps automatic downloads off, so installs stay user-driven.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.beginChecking(userInitiated: true)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        updateChoiceReply = reply
        let version = appcastItem.displayVersionString
        model.offerUpdate(
            version: version.isEmpty ? nil : version,
            install: { [weak self] in
                guard let reply = self?.updateChoiceReply else { return }
                self?.updateChoiceReply = nil
                self?.model.beginDownloading()
                reply(.install)
            },
            dismiss: { [weak self] in
                guard let reply = self?.updateChoiceReply else { return }
                self?.updateChoiceReply = nil
                reply(.dismiss)
            }
        )
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes are surfaced via the appcast link, not inline.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        // Silent: no "you're up to date" pill. Just settle back to idle.
        model.reset()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        model.setError(shortMessage(for: error), retry: nil)
        acknowledgement()
    }

    // MARK: Downloading

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        model.beginDownloading()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        if expectedLength > 0 {
            model.setDownloadProgress(Double(receivedLength) / Double(expectedLength))
        } else {
            model.setDownloadProgress(nil)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        model.beginExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.setExtractionProgress(progress)
    }

    // MARK: Installing

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        // The user already asked to update by clicking the pill — proceed straight
        // to install + relaunch, no second confirmation. Smooth and fast.
        model.beginInstalling()
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        model.beginInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
                                          acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        // Sparkle tore the flow down. Only reset if we're not mid-install (an
        // install that's proceeding to relaunch should keep showing progress).
        if model.phase != .installing { model.reset() }
    }

    // MARK: Optional

    func showUpdateInFocus() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Helpers

    private func shortMessage(for error: any Error) -> String {
        let ns = error as NSError
        return ns.localizedDescription
    }
}
