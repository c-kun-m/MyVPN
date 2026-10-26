import XCTest

final class SimulatorFlowTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate() }

    private func launch(_ scenario: String = "normal") {
        app = XCUIApplication()
        app.launchEnvironment["NPV_SIM_SCENARIO"] = scenario
        app.launch()
        XCTAssertTrue(app.staticTexts["simulation.banner"].waitForExistence(timeout: 10))
    }
    private func openEditor() {
        app.tabBars.buttons["配置"].tap()
        let generate = app.buttons["identity.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()
        XCTAssertTrue(app.staticTexts["identity.publicKey"].waitForExistence(timeout: 5))
        app.buttons["profile.edit"].tap()
        XCTAssertTrue(app.buttons["profile.example"].waitForExistence(timeout: 5))
    }
    private func configure() {
        openEditor()
        app.buttons["profile.example"].tap()
        app.buttons["profile.save"].tap()
        XCTAssertTrue(app.buttons["profile.edit"].waitForExistence(timeout: 5))
        app.tabBars.buttons["连接"].tap()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFirstUseConnectDisconnectAndEdit() {
        launch()
        XCTAssertFalse(app.buttons["connection.start"].isEnabled)
        capture("first-use")
        configure()
        app.buttons["connection.start"].tap()
        XCTAssertTrue(app.staticTexts["模拟连接已建立"].waitForExistence(timeout: 5))
        capture("simulated-connected")
        app.buttons["connection.stop"].tap()
        XCTAssertTrue(app.buttons["connection.start"].waitForExistence(timeout: 5))
        app.tabBars.buttons["配置"].tap()
        app.buttons["profile.edit"].tap()
        XCTAssertEqual(app.textFields["profile.host"].value as? String, "vpn.example.invalid")
        let name = app.textFields["profile.name"]
        name.tap()
        // A newly created simulator may present Apple's keyboard introduction.
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        let old = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Edited Lab")
        app.buttons["完成"].tap()
        app.buttons["profile.save"].tap()
        XCTAssertTrue(app.buttons["profile.edit"].waitForExistence(timeout: 5))
        capture("edited-profile")
        app.buttons["profile.edit"].tap()
        XCTAssertEqual(app.textFields["profile.name"].value as? String, "Edited Lab")
        app.buttons["取消"].tap()
        app.tabBars.buttons["诊断"].tap()
        XCTAssertTrue(app.staticTexts["已请求断开"].exists)
        capture("diagnostics")
    }

    func testInvalidAddressKeepsEditorOpen() {
        launch(); openEditor()
        app.buttons["profile.save"].tap()
        let error = app.staticTexts["profile.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("服务器地址"))
        XCTAssertTrue(app.buttons["profile.save"].exists)
        capture("validation-error")
    }

    func testSaveDenialKeepsEditorAndShowsActionableError() {
        launch("saveDenied"); openEditor()
        app.buttons["profile.example"].tap()
        app.buttons["profile.save"].tap()
        let error = app.staticTexts["profile.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("授权"))
        XCTAssertTrue(app.buttons["profile.save"].isEnabled)
        capture("save-denied")
    }

    func testStartupFailureAllowsRetry() {
        launch("startFailure"); configure()
        app.buttons["connection.start"].tap()
        XCTAssertTrue(app.staticTexts["operation.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connection.start"].isEnabled)
        XCTAssertFalse(app.staticTexts["模拟连接已建立"].exists)
        capture("start-failure")
    }

    func testKeyUnavailableCanRecoverByChangingScenario() {
        launch("keyUnavailable")
        XCTAssertTrue(app.staticTexts["operation.error"].waitForExistence(timeout: 5))
        app.buttons["simulation.scenarios"].tap()
        app.buttons["scenario.normal"].tap()
        app.tabBars.buttons["配置"].tap()
        XCTAssertTrue(app.buttons["identity.generate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["identity.generate"].isEnabled)
        app.buttons["identity.generate"].tap()
        XCTAssertTrue(app.staticTexts["identity.publicKey"].waitForExistence(timeout: 5))
    }

    func testStartedWithoutHandshakeDoesNotShowHandshakeSuccess() {
        launch("noHandshake"); configure()
        app.buttons["connection.start"].tap()
        XCTAssertTrue(app.staticTexts["模拟连接已建立"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["statistics.noHandshake"].waitForExistence(timeout: 8))
        capture("no-handshake")
        app.buttons["connection.stop"].tap()
    }

    func testCancelWhileConnectingReturnsToDisconnected() {
        launch("timeout"); configure()
        app.buttons["connection.start"].tap()
        XCTAssertTrue(app.buttons["connection.stop"].waitForExistence(timeout: 5))
        app.buttons["connection.stop"].tap()
        XCTAssertTrue(app.buttons["connection.start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connection.start"].isEnabled)
        XCTAssertEqual(app.staticTexts["connection.status"].label, "已断开")
    }
}
