import XCTest
import StoreKitTest

/// Run on a dedicated simulator: every test owns and resets its local StoreKit history.
/// Purchases and restores go through the app's real StoreKit service and local backend.
final class LocalStoreKitUITests: XCTestCase {
    @MainActor
    func testWeeklyPurchaseRestoreAndRefundSynchronizeBothPages() throws {
        try verifyLifecycle(category: "weekly", productID: "fixture.week", ending: .refund, foreground: .membership)
    }

    @MainActor
    func testYearlyPurchaseRestoreAndRefundSynchronizeBothPages() throws {
        try verifyLifecycle(category: "yearly", productID: "fixture.year", ending: .refund, foreground: .profile)
    }

    @MainActor
    func testWeeklyPurchaseRestoreAndExpirationSynchronizeBothPages() throws {
        try verifyLifecycle(category: "weekly", productID: "fixture.week", ending: .expiration, foreground: .profile)
    }

    @MainActor
    func testYearlyPurchaseRestoreAndExpirationSynchronizeBothPages() throws {
        try verifyLifecycle(category: "yearly", productID: "fixture.year", ending: .expiration, foreground: .membership)
    }

    private enum Ending: String { case refund, expiration }
    private enum ForegroundPage { case membership, profile }

    @MainActor
    private func verifyLifecycle(category: String, productID: String, ending: Ending, foreground: ForegroundPage) throws {
        continueAfterFailure = false
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LocalPurchases", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        // Use a real accelerated expiration. On iOS 27, expireSubscription can
        // change the test record while leaving the signed subscription active.
        session.timeRate = ending == .expiration ? .oneRenewalEveryMinute : .realTime
        let app = XCUIApplication()
        app.launchArguments = ["-LocalStoreKitTesting", "-ResetLocalStoreKitState",
                               "-profile.language.v1", "zh-Hant", "-AppleLanguages", "(zh-Hant)"]
        defer {
            app.terminate()
            session.clearTransactions()
            session.resetToDefaultState()
        }
        app.launch()
        openMembership(app, category: category)
        assertMembership(app, category: category, active: false)
        let buy = page(app, category: category).buttons["membership-buy-\(category)"]
        reveal(buy, in: page(app, category: category))
        buy.tap()
        assertMembership(app, category: category, active: true)
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == productID })
        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        let expiration = try XCTUnwrap(transaction.expirationDate)
        let date = expiration.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        XCTAssertTrue(hero(app, category: category, active: true).label.contains(date))
        screenshot(app, "\(category)-purchased-membership")
        openProfile(app)
        assertProfile(app, active: true, date: date)
        screenshot(app, "\(category)-purchased-profile")

        // Recreate the app process; the entitlement must come from StoreKit, not view state.
        app.terminate()
        app.launch()
        openMembership(app, category: category)
        restore(app, category: category)
        assertMessage(app, equals: "已恢復會員權益")
        assertMembership(app, category: category, active: true)
        XCTAssertTrue(hero(app, category: category, active: true).label.contains(date))
        screenshot(app, "\(category)-restored-membership")
        openProfile(app)
        assertProfile(app, active: true, date: date)
        screenshot(app, "\(category)-restored-profile")

        if foreground == .membership {
            openMembership(app, category: category)
            // Preserve the successful restore message while the entitlement is revoked.
            restore(app, category: category)
            assertMessage(app, equals: "已恢復會員權益")
        }
        switch ending {
        case .refund:
            try session.refundTransaction(identifier: transaction.identifier)
        case .expiration:
            let current = try XCTUnwrap(session.allTransactions().first { $0.identifier == transaction.identifier })
            XCTAssertFalse(current.autoRenewingEnabled, "Expiration requires auto-renewal to remain disabled after restore")
            waitUntil("The accelerated subscription must reach its actual expiration date", timeout: 90) {
                guard let date = session.allTransactions().first(where: { $0.identifier == transaction.identifier })?.expirationDate else { return false }
                return date <= Date()
            }
            XCTAssertEqual(session.allTransactions().filter { $0.productIdentifier == productID }.count, 1,
                           "Expiration must not create a renewal transaction")
        }
        // Both types of revocation are checked live on each page across the four tests.
        // No tab change, refresh gesture or restore may mask a missing observer update.
        switch foreground {
        case .membership:
            assertMembership(app, category: category, active: false)
            assertNoStaleSuccessMessage(app)
            screenshot(app, "\(category)-\(ending.rawValue)-membership-live")
            openProfile(app)
            assertProfile(app, active: false)
            screenshot(app, "\(category)-\(ending.rawValue)-profile")
        case .profile:
            assertProfile(app, active: false)
            screenshot(app, "\(category)-\(ending.rawValue)-profile-live")
            openMembership(app, category: category)
            assertMembership(app, category: category, active: false)
            screenshot(app, "\(category)-\(ending.rawValue)-membership")
        }
        openMembership(app, category: category)
        restore(app, category: category)
        assertMessage(app, equals: "購買同步完成，未找到有效的會員訂閱")
        assertMembership(app, category: category, active: false)
        screenshot(app, "\(category)-\(ending.rawValue)-restore-does-not-revive")
        openProfile(app)
        assertProfile(app, active: false)
    }

    @MainActor
    private func openMembership(_ app: XCUIApplication, category: String) {
        let tab = app.tabBars.buttons["會員"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        let categoryTab = app.buttons["membership-tab-\(category)"]
        XCTAssertTrue(categoryTab.waitForExistence(timeout: 10))
        categoryTab.tap()
        XCTAssertTrue(page(app, category: category).waitForExistence(timeout: 10))
    }

    @MainActor
    private func openProfile(_ app: XCUIApplication) {
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.buttons["profile-membership"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func page(_ app: XCUIApplication, category: String) -> XCUIElement {
        app.scrollViews["membership-page-\(category)"]
    }

    @MainActor
    private func hero(_ app: XCUIApplication, category: String, active: Bool) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "membership-hero-\(category)-\(active ? "active" : "inactive")").firstMatch
    }

    @MainActor
    private func assertMembership(_ app: XCUIApplication, category: String, active: Bool) {
        let card = hero(app, category: category, active: active)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Membership must update without refreshing the page")
        let buy = page(app, category: category).buttons["membership-buy-\(category)"]
        waitUntil("Purchase button should reflect membership") { buy.exists && buy.isEnabled == !active }
        if !active { XCTAssertFalse(card.label.contains("有效期")) }
    }

    @MainActor
    private func assertProfile(_ app: XCUIApplication, active: Bool, date: String? = nil) {
        let card = app.buttons["profile-membership"]
        waitUntil("Profile VIP should synchronize") {
            card.label == (active ? "VIP會員，已開通" : "VIP會員，未開通")
                && (active ? (card.value as? String)?.contains(date ?? "") == true : (card.value as? String ?? "").isEmpty)
        }
    }

    @MainActor
    private func restore(_ app: XCUIApplication, category: String) {
        let restore = page(app, category: category).buttons["membership-restore"]
        reveal(restore, in: page(app, category: category))
        waitUntil("Restore must be available") { restore.isEnabled }
        restore.tap()
    }

    @MainActor
    private func assertMessage(_ app: XCUIApplication, equals text: String) {
        waitUntil("Expected status: \(text)") {
            let message = app.staticTexts["membership-message"]
            return message.exists && message.label == text
        }
    }

    @MainActor
    private func assertNoStaleSuccessMessage(_ app: XCUIApplication) {
        waitUntil("Revoked entitlement must not retain a success message") {
            let message = app.staticTexts["membership-message"]
            return !message.exists || !["已恢復會員權益", "會員已開通"].contains(message.label)
        }
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<5 where !element.isHittable { scrollView.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func waitUntil(_ description: String, timeout: TimeInterval = 15, condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, description)
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
