import XCTest

final class PortWeaverUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws { app?.terminate() }

    private func showStatusPanel() {
        if app.buttons["status.open-main"].exists { return }
        let status = app.statusItems.firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
        status.click()
        XCTAssertTrue(app.buttons["status.open-main"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testStoppedRulesAndSwitchesRemainVisible() {
        showStatusPanel()
        for title in ["本地开发服务", "UDP 回显", "IPv6 本地服务"] {
            let toggle = app.checkBoxes["启停 \(title)"]
            XCTAssertTrue(toggle.exists, "Missing stopped rule: \(title)\n\(app.debugDescription)")
            XCTAssertEqual((toggle.value as? NSNumber)?.intValue, 0)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "status-panel-stopped-rules"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureDocumentationScreenshot() {
        let window = app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "documentation-main-window"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWindowAndSettingsReuseSingleMainWindow() {
        for _ in 0..<3 {
            showStatusPanel()
            app.buttons["status.open-main"].click()
            XCTAssertEqual(app.windows.matching(identifier: "main").count, 1)
        }
        showStatusPanel()
        app.buttons["status.open-settings"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.login-at-launch"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(identifier: "main").count, 1)
        app.windows["main"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(app.windows["main"].exists)
        showStatusPanel()
        app.buttons["status.open-main"].click()
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(identifier: "main").count, 1)
    }
}
