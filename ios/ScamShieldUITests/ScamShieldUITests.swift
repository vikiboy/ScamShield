import XCTest

/// Sync folder for UI tests: `SCAMSHIELD_DEMO_FOLDER` (pass `TEST_RUNNER_SCAMSHIELD_DEMO_FOLDER=<path>`
/// to xcodebuild), else the fixtures in ios/Fixtures/ScamShield.
private let demoFolder: String = {
    if let path = ProcessInfo.processInfo.environment["SCAMSHIELD_DEMO_FOLDER"], !path.isEmpty { return path }
    return fixtureFolder
}()

/// The writing test always uses the fixtures, never `SCAMSHIELD_DEMO_FOLDER`, so it can't mark a
/// call done in a real sync folder.
private let fixtureFolder: String = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/ScamShield").path

private func correctionFiles(in folder: String) -> Set<String> {
    let directory = URL(filePath: folder).appending(path: "corrections")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".json") || $0.hasPrefix(".tmp-") })
}

/// Voicemail playback is muted unless `SCAMSHIELD_DEMO_AUDIO=1` (pass `TEST_RUNNER_SCAMSHIELD_DEMO_AUDIO=1`
/// to xcodebuild), so test runs don't play recordings through the Mac's speakers.
private let demoAudio = ProcessInfo.processInfo.environment["SCAMSHIELD_DEMO_AUDIO"] == "1"

@MainActor
private func launchApp(folder: String = demoFolder) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-ScamShieldFolder", folder, "-ScamShieldResetLocalState", "YES"]
        + (demoAudio ? [] : ["-ScamShieldMuteAudio", "YES"])
    app.launch()
    return app
}

@MainActor
private extension XCUIApplication {
    func firstCallRow(in list: XCUIElement) -> XCUIElement {
        list.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'callRow.'"))
            .firstMatch
    }

    func backButton() -> XCUIElement {
        navigationBars.buttons.element(boundBy: 0)
    }
}

/// A read-only tour of the app at a human pace, for screen recordings. It must never mark
/// anything done, block, archive or save a move, so it leaves the sync folder untouched.
@MainActor
final class ScamShieldUITests: XCTestCase {
    nonisolated override func setUp() {
        continueAfterFailure = false
    }

    private func pause(_ seconds: Double = 2) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func testWalkthrough() throws {
        let before = correctionFiles(in: demoFolder)
        let app = launchApp()

        // Attention list
        let attention = app.collectionViews["list.attention"]
        XCTAssertTrue(attention.waitForExistence(timeout: 15))
        let firstRow = app.firstCallRow(in: attention)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        pause(2.5)

        // Detail of the first call: voicemail, transcript, reasons
        firstRow.tap()
        let detail = app.collectionViews["detail.list"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        pause()
        let play = app.buttons["voicemail.playPause"]
        if play.waitForExistence(timeout: 3) {
            let enabled = NSPredicate(format: "isEnabled == true")
            if XCTWaiter().wait(for: [expectation(for: enabled, evaluatedWith: play)], timeout: 10) == .completed {
                play.tap()
                pause(3)
                play.tap()
                pause(1.5)
            }
        }
        let transcriptToggle = app.buttons["transcript.toggle"]
        for _ in 0..<3 where !(transcriptToggle.exists && transcriptToggle.isHittable) {
            detail.swipeUp(velocity: .slow)
            pause(1.5)
        }
        if transcriptToggle.exists, transcriptToggle.isHittable {
            transcriptToggle.tap()
            pause()
        }
        detail.swipeUp(velocity: .slow)
        pause()
        detail.swipeDown(velocity: .fast)
        pause(1.5)
        app.backButton().tap()
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        pause(1.5)

        // Review, with the collapsed "No message left" group opened
        app.tabBars.buttons["Review"].tap()
        let review = app.collectionViews["list.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        pause()
        let noMessage = app.buttons["review.noMessageToggle"]
        if noMessage.waitForExistence(timeout: 3) {
            let rowsBefore = review.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'callRow.'")).count
            noMessage.tap()
            pause()
            let rowsAfter = review.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'callRow.'")).count
            XCTAssertGreaterThan(rowsAfter, rowsBefore, "Expanding “No message left” should show its calls")
            review.swipeUp(velocity: .slow)
            pause()
            review.swipeDown(velocity: .fast)
            pause(1.5)
        }

        // Scams: grouping, Open/Done filter (Archive All is never touched)
        app.tabBars.buttons["Scams"].tap()
        let scams = app.collectionViews["list.scam"]
        XCTAssertTrue(scams.waitForExistence(timeout: 5))
        pause()
        scams.swipeUp(velocity: .slow)
        pause()
        scams.swipeDown(velocity: .fast)
        pause(1.5)
        let filter = app.segmentedControls["scams.filter"].exists
            ? app.segmentedControls["scams.filter"] : app.segmentedControls.firstMatch
        filter.buttons["Done"].tap()
        pause()
        filter.buttons["Open"].tap()
        pause(1.5)

        // A scam call's detail and its Move sheet, cancelled
        let scamRow = app.firstCallRow(in: scams)
        XCTAssertTrue(scamRow.waitForExistence(timeout: 5))
        scamRow.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        pause()
        let move = app.buttons["detail.move"]
        for _ in 0..<4 where !(move.exists && move.isHittable) {
            detail.swipeUp(velocity: .slow)
            pause(1)
        }
        XCTAssertTrue(move.isHittable)
        move.tap()
        let cancel = app.buttons["move.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        pause(2.5)
        cancel.tap()
        pause(1.5)
        app.backButton().tap()
        XCTAssertTrue(scams.waitForExistence(timeout: 5))
        pause(1.5)

        // Settings
        app.tabBars.buttons["Settings"].tap()
        let settings = app.collectionViews["settings.form"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        pause()
        settings.swipeUp(velocity: .slow)
        pause()
        settings.swipeUp(velocity: .slow)
        pause()
        settings.swipeDown(velocity: .fast)
        pause(1.5)

        app.tabBars.buttons["Attention"].tap()
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        pause(2)

        XCTAssertEqual(correctionFiles(in: demoFolder), before, "The walkthrough must not write corrections")
    }
}

/// Marks a call done through the UI and checks the correction file the Mac will consume, then
/// deletes it so the fixtures stay clean. Not part of the walkthrough.
@MainActor
final class CorrectionFlowUITests: XCTestCase {
    nonisolated(unsafe) private var created: Set<String> = []

    nonisolated override func tearDown() {
        let directory = URL(filePath: fixtureFolder).appending(path: "corrections")
        for name in created {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    func testMarkDoneWritesCorrectionFile() throws {
        let before = correctionFiles(in: fixtureFolder)
        let app = launchApp(folder: fixtureFolder)
        let attention = app.collectionViews["list.attention"]
        XCTAssertTrue(attention.waitForExistence(timeout: 15))
        let row = app.firstCallRow(in: attention)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let itemID = String(row.identifier.dropFirst("callRow.".count))
        row.tap()

        let done = app.buttons["detail.done"]
        let detail = app.collectionViews["detail.list"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        for _ in 0..<5 where !(done.exists && done.isHittable) { detail.swipeUp() }
        done.tap()

        var added: Set<String> = []
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            added = correctionFiles(in: fixtureFolder).subtracting(before)
            if added.contains(where: { $0.hasSuffix(".json") }) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        created = added
        let name = try XCTUnwrap(added.first { $0.hasSuffix(".json") }, "No correction file appeared")
        XCTAssertFalse(added.contains { $0.hasPrefix(".tmp-") }, "Temp file left behind")

        let url = URL(filePath: fixtureFolder).appending(path: "corrections").appending(path: name)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "done")
        XCTAssertEqual(json["done"] as? Bool, true)
        XCTAssertEqual(json["itemId"] as? String, itemID)
        XCTAssertEqual("\(json["id"] as? String ?? "").json", name)
        XCTAssertNotNil(json["at"] as? String)
    }
}
