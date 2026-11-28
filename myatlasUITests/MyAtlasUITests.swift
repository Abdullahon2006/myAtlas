import XCTest

final class MyAtlasUITests: XCTestCase {
    func testAtlasHomeLoadsAndOpensTabsAndCaptureSheet() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["myatlas"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Offline atlas"].exists)
        XCTAssertTrue(app.buttons["save-place-button"].exists)

        app.buttons["save-place-button"].tap()
        XCTAssertTrue(app.navigationBars["Save Place"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Offline"].tap()
        XCTAssertTrue(app.navigationBars["Offline & Vault"].waitForExistence(timeout: 3))
    }

    func testInteractiveDemoWalkthrough() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["myatlas"].waitForExistence(timeout: 6))
        pause(1.0)

        // 1. Toggle Satellite Map & back
        let satelliteButton = app.buttons["Switch to Satellite Map"]
        if satelliteButton.waitForExistence(timeout: 2) {
            satelliteButton.tap()
            pause(0.9)
            let standardButton = app.buttons["Switch to Standard Map"]
            if standardButton.waitForExistence(timeout: 2) {
                standardButton.tap()
                pause(0.6)
            }
        }

        // 2. Category filter -> back to All, then Explore drawer expand & collapse
        let viewpointChip = app.buttons["Viewpoint"]
        if viewpointChip.exists {
            viewpointChip.tap()
            pause(0.6)
            viewpointChip.tap()
            pause(0.5)
        }
        let exploreButton = app.buttons["Show Places and Regions Panel"]
        if exploreButton.waitForExistence(timeout: 2) {
            exploreButton.tap()
            pause(0.9)
            let hideButton = app.buttons["Hide Places and Regions Panel"]
            if hideButton.waitForExistence(timeout: 2) {
                hideButton.tap()
                pause(0.5)
            }
        }

        // 3. Record Walk HUD -> Pause -> Finish sheet preview -> Resume -> Discard
        let walkButton = app.buttons["Record Walk"]
        if walkButton.waitForExistence(timeout: 2) {
            walkButton.tap()
            XCTAssertTrue(app.staticTexts["Recording Walk"].waitForExistence(timeout: 3))
            pause(0.9)

            if app.buttons["Pause"].exists {
                app.buttons["Pause"].tap()
                pause(0.6)
            }
            if app.buttons["Finish"].exists {
                app.buttons["Finish"].tap()
                if app.navigationBars["Save Walk"].waitForExistence(timeout: 2) {
                    pause(0.7)
                    if app.buttons["Resume"].exists {
                        app.buttons["Resume"].tap()
                        pause(0.5)
                    }
                }
            }
            if app.buttons["Discard Walk"].exists {
                app.buttons["Discard Walk"].tap()
                pause(0.4)
                let confirmButton = app.buttons.matching(identifier: "Discard Walk").allElementsBoundByIndex.last
                if let confirmButton, confirmButton.exists {
                    confirmButton.tap()
                    pause(0.5)
                }
            }
        }

        // 4. Interactive Save Place flow (scroll to Details, type Place Name + City + Note, toggle Favorite, Save)
        app.buttons["save-place-button"].tap()
        XCTAssertTrue(app.navigationBars["Save Place"].waitForExistence(timeout: 4))
        pause(0.7)

        let nameField = app.textFields["Place name (e.g. Miradouro)"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Alfama Overlook")

        let cityField = app.textFields["City or region"]
        if cityField.exists {
            cityField.tap()
            cityField.typeText("Lisbon, Portugal")
        }

        let favSwitch = app.switches["Favorite Place"]
        if favSwitch.exists {
            favSwitch.tap()
        }

        app.swipeUp()
        pause(0.4)

        let noteTextView = app.textViews.firstMatch
        let noteTextField = app.textFields["What do you want to remember about this place?"]
        if noteTextView.waitForExistence(timeout: 1) {
            noteTextView.tap()
            noteTextView.typeText("Terracotta rooftops over the Tagus.")
        } else if noteTextField.exists {
            noteTextField.tap()
            noteTextField.typeText("Terracotta rooftops over the Tagus.")
        }

        pause(0.5)
        app.buttons["confirm-save-place-button"].tap()
        XCTAssertTrue(app.buttons["Show Places and Regions Panel"].waitForExistence(timeout: 4))
        pause(0.8)

        // 5. Open newly saved place detail via Explore panel
        app.buttons["Show Places and Regions Panel"].tap()
        pause(0.7)
        let savedRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Alfama Overlook")).firstMatch
        if savedRow.waitForExistence(timeout: 3) {
            savedRow.tap()
            XCTAssertTrue(app.navigationBars["Alfama Overlook"].waitForExistence(timeout: 4))
            pause(0.9)
            app.swipeUp()
            pause(0.8)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            pause(0.5)
        }

        // 6. History tab (Places / Routes toggle) & Offline tab
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
        pause(0.9)
        let routesButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Routes")).firstMatch
        if routesButton.exists {
            routesButton.tap()
            pause(0.7)
            let placesButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Places")).firstMatch
            if placesButton.exists {
                placesButton.tap()
                pause(0.6)
            }
        }

        app.tabBars.buttons["Offline"].tap()
        XCTAssertTrue(app.navigationBars["Offline & Vault"].waitForExistence(timeout: 3))
        pause(1.0)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
