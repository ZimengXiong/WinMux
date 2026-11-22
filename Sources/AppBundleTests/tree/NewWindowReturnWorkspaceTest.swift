@testable import AppBundle
import Common
import XCTest

@MainActor
final class NewWindowReturnWorkspaceTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// Empty workspace 2 is focused, the user activates an app whose window lives on workspace 1
    /// (focus follows it), then the app opens a new window: it must land on workspace 2.
    func testNewWindowAfterActivationJumpFromEmptyWorkspaceReturnsToIt() {
        let first = Workspace.get(byName: "1")
        let existing = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        let empty = Workspace.get(byName: "2")
        XCTAssertTrue(empty.focusWorkspace())

        updateFocusCache(existing) // native activation of the app focuses its window on workspace 1
        XCTAssertTrue(focus.workspace === first)

        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(Workspace.existing(byName: "2") === empty, "remembered empty workspace must survive pruning")
        XCTAssertTrue(newWindowReturnWorkspace(appPid: existing.app.pid) === empty)

        let newWindow = TestWindow.new(id: 2, parent: empty.rootTilingContainer)
        consumeNewWindowReturnWorkspace()
        updateFocusCache(newWindow)

        XCTAssertTrue(focus.workspace === empty)
        XCTAssertTrue(focus.windowOrNil === newWindow)
        XCTAssertNil(newWindowReturnWorkspace(appPid: existing.app.pid))
    }

    func testReturnTargetExpires() {
        let first = Workspace.get(byName: "1")
        let existing = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        let empty = Workspace.get(byName: "2")
        XCTAssertTrue(empty.focusWorkspace())
        let now = Date()

        recordNativeActivationFocusJump(from: focus, to: existing, now: now)
        _ = existing.focusWindow()

        XCTAssertTrue(newWindowReturnWorkspace(appPid: existing.app.pid, now: now) === empty)
        XCTAssertNil(newWindowReturnWorkspace(appPid: existing.app.pid, now: now.addingTimeInterval(newWindowReturnGracePeriod + 1)))
        XCTAssertFalse(isPendingNewWindowReturnWorkspace(empty))
    }

    func testNoReturnTargetWhenLeavingNonEmptyWorkspace() {
        let first = Workspace.get(byName: "1")
        let existing = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        let second = Workspace.get(byName: "2")
        let other = TestWindow.new(id: 2, parent: second.rootTilingContainer)
        XCTAssertTrue(other.focusWindow())

        updateFocusCache(existing)

        XCTAssertTrue(focus.workspace === first)
        XCTAssertNil(newWindowReturnWorkspace(appPid: existing.app.pid))
    }

    func testNoReturnTargetForOtherAppsOrAfterUserMovedOn() {
        let first = Workspace.get(byName: "1")
        let existing = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        let empty = Workspace.get(byName: "2")
        XCTAssertTrue(empty.focusWorkspace())
        updateFocusCache(existing)

        XCTAssertNil(newWindowReturnWorkspace(appPid: existing.app.pid + 1))

        let third = Workspace.get(byName: "3")
        _ = TestWindow.new(id: 3, parent: third.rootTilingContainer)
        XCTAssertTrue(third.focusWorkspace())
        XCTAssertNil(newWindowReturnWorkspace(appPid: existing.app.pid))
    }
}
