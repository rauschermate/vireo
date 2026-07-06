import XCTest
@testable import VireoUpdater

@MainActor
final class UpdateModelTests: XCTestCase {

    func testIdleHidesPill() {
        let model = UpdateModel()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isPillVisible)
    }

    func testScheduledCheckStaysHiddenButUserCheckShows() {
        let model = UpdateModel()
        model.beginChecking(userInitiated: false)
        XCTAssertEqual(model.phase, .checking)
        XCTAssertFalse(model.isPillVisible, "background checks must not flash the pill")

        model.beginChecking(userInitiated: true)
        XCTAssertTrue(model.isPillVisible, "a user-initiated check should surface the pill")
    }

    func testOfferShowsDismissablePill() {
        let model = UpdateModel()
        var installed = false
        model.offerUpdate(version: "0.2.0", install: { installed = true }, dismiss: {})
        XCTAssertEqual(model.phase, .available)
        XCTAssertEqual(model.availableVersion, "0.2.0")
        XCTAssertTrue(model.isPillVisible)
        XCTAssertTrue(model.isDismissable)

        model.install()
        XCTAssertTrue(installed)
    }

    func testDismissHidesOfferUntilANewerVersionArrives() {
        let model = UpdateModel()
        model.offerUpdate(version: "0.2.0", install: {}, dismiss: {})
        model.dismiss()
        XCTAssertFalse(model.isPillVisible, "dismissed offer stays hidden")
        XCTAssertEqual(model.phase, .available)

        // Re-offering the same version stays dismissed…
        model.offerUpdate(version: "0.2.0", install: {}, dismiss: {})
        XCTAssertFalse(model.isPillVisible)

        // …but a newer version resurfaces the pill.
        model.offerUpdate(version: "0.3.0", install: {}, dismiss: {})
        XCTAssertTrue(model.isPillVisible)
    }

    func testDismissInvokesSparkleDismissCallback() {
        let model = UpdateModel()
        var dismissed = false
        model.offerUpdate(version: "0.2.0", install: {}, dismiss: { dismissed = true })
        model.dismiss()
        XCTAssertTrue(dismissed, "dismissing the pill must tell Sparkle to dismiss")
    }

    func testDownloadProgressClampsAndIsNotDismissable() {
        let model = UpdateModel()
        model.beginDownloading()
        XCTAssertEqual(model.phase, .downloading)
        XCTAssertFalse(model.isDismissable, "active download can't be dismissed")

        model.setDownloadProgress(2.0)
        XCTAssertEqual(model.progress, 1.0)
        model.setDownloadProgress(-1.0)
        XCTAssertEqual(model.progress, 0.0)
        model.setDownloadProgress(nil)
        XCTAssertNil(model.progress)
    }

    func testExtractionProgressClamps() {
        let model = UpdateModel()
        model.beginExtracting()
        XCTAssertEqual(model.phase, .extracting)
        model.setExtractionProgress(0.5)
        XCTAssertEqual(model.progress, 0.5)
        model.setExtractionProgress(9)
        XCTAssertEqual(model.progress, 1.0)
    }

    func testErrorIsDismissableAndResetsOnDismiss() {
        let model = UpdateModel()
        model.setError("boom", retry: nil)
        XCTAssertEqual(model.phase, .error)
        XCTAssertEqual(model.errorMessage, "boom")
        XCTAssertTrue(model.isPillVisible)
        XCTAssertTrue(model.isDismissable)

        model.dismiss()
        XCTAssertEqual(model.phase, .idle, "dismissing an error clears the pill")
    }

    func testRetryRunsCallbackAndResets() {
        let model = UpdateModel()
        var retried = false
        model.setError("boom", retry: { retried = true })
        model.retry()
        XCTAssertTrue(retried)
        XCTAssertEqual(model.phase, .idle)
    }

    func testPreviewFactoryPinsVisualState() {
        let model = UpdateModel.preview(.downloading, progress: 0.62)
        XCTAssertEqual(model.phase, .downloading)
        XCTAssertEqual(model.progress, 0.62)
        XCTAssertTrue(model.isPillVisible)
    }
}
