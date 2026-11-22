@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceMonitorPreferenceTest: XCTestCase {
    private let builtIn = TestMonitor(
        monitorAppKitNsScreenScreensId: 1,
        name: "Built-in",
        rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
        visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
        isMain: true,
    )
    private let external = TestMonitor(
        monitorAppKitNsScreenScreensId: 2,
        name: "External",
        rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
        visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
        isMain: false,
    )

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setMonitorsForTests([builtIn, external])
    }

    func testTemporaryFallbackPreservesPreferenceAfterReconnect() {
        let local = workspace("local", on: builtIn, windowId: 601)
        let remote = workspace("remote", on: external, windowId: 602)
        XCTAssertTrue(builtIn.setActiveWorkspace(local))
        XCTAssertTrue(external.setActiveWorkspace(remote))
        XCTAssertTrue(local.focusWorkspace())

        setMonitorsForTests([builtIn])
        gcMonitors()
        XCTAssertTrue(remote.focusWorkspace())
        XCTAssertTrue(builtIn.activeWorkspace === remote)
        XCTAssertEqual(remote.preferredMonitorPoint, external.rect.topLeftCorner)
        XCTAssertTrue(local.focusWorkspace())

        setMonitorsForTests([builtIn, external])
        gcMonitors()
        XCTAssertTrue(remote.focusWorkspace())
        XCTAssertTrue(external.activeWorkspace === remote)
        XCTAssertTrue(builtIn.activeWorkspace === local)
    }

    func testReconnectDoesNotMoveWorkspaceAlreadyVisibleOnFallbackMonitor() {
        let remote = workspace("remote", on: external, windowId: 603)
        setMonitorsForTests([builtIn])
        gcMonitors()
        XCTAssertTrue(remote.focusWorkspace())

        setMonitorsForTests([builtIn, external])
        gcMonitors()

        XCTAssertTrue(builtIn.activeWorkspace === remote)
        XCTAssertEqual(remote.preferredMonitorPoint, external.rect.topLeftCorner)
    }

    func testSidebarOnRemainingMonitorPreservesDisconnectedPreference() {
        let remote = workspace("remote", on: external, windowId: 604)
        setMonitorsForTests([builtIn])
        gcMonitors()

        XCTAssertTrue(focusWorkspaceFromSidebar(remote, targetMonitorScopeId: workspaceSidebarMonitorScopeId(for: builtIn)))

        XCTAssertTrue(builtIn.activeWorkspace === remote)
        XCTAssertEqual(remote.preferredMonitorPoint, external.rect.topLeftCorner)
    }

    func testAutomaticForceAssignmentDoesNotReplacePreference() {
        let forced = workspace("forced", on: builtIn, windowId: 605)
        XCTAssertTrue(builtIn.setActiveWorkspace(forced))
        config.workspaceToMonitorForceAssignment[forced.name] = [.sequenceNumber(2)]

        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(external.activeWorkspace === forced)
        XCTAssertEqual(forced.preferredMonitorPoint, builtIn.rect.topLeftCorner)
    }

    func testRejectedMovePreservesSourceWorkspaceAndPreference() async throws {
        let forced = workspace("forced", on: builtIn, windowId: 606)
        XCTAssertTrue(builtIn.setActiveWorkspace(forced))
        XCTAssertTrue(forced.focusWorkspace())
        config.workspaceToMonitorForceAssignment[forced.name] = [.sequenceNumber(1)]

        let result = try await parseCommand("move-workspace-to-monitor next").cmdOrDie.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(builtIn.activeWorkspace === forced)
        XCTAssertEqual(forced.preferredMonitorPoint, builtIn.rect.topLeftCorner)
    }

    func testSummonRemembersTargetAfterWorkspaceIsHidden() async throws {
        let local = workspace("local", on: builtIn, windowId: 607)
        let remote = workspace("remote", on: external, windowId: 608)
        XCTAssertTrue(builtIn.setActiveWorkspace(local))
        XCTAssertTrue(external.setActiveWorkspace(remote))
        XCTAssertTrue(local.focusWorkspace())

        let result = try await parseCommand("summon-workspace remote").cmdOrDie.run(.defaultEnv, .emptyStdin)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(local.focusWorkspace())
        XCTAssertTrue(remote.focusWorkspace())
        XCTAssertTrue(builtIn.activeWorkspace === remote)
    }

    func testSidebarOverrideRemembersBothRelocatedWorkspaces() {
        let local = workspace("local", on: builtIn, windowId: 609)
        let remote = workspace("remote", on: external, windowId: 610)
        XCTAssertTrue(builtIn.setActiveWorkspace(local))
        XCTAssertTrue(external.setActiveWorkspace(remote))

        XCTAssertTrue(overrideWorkspaceOnMonitorBySwappingActiveViewports(remote, targetMonitor: builtIn))
        XCTAssertTrue(builtIn.setActiveWorkspace(workspace("other-local", on: builtIn, windowId: 611)))
        XCTAssertTrue(external.setActiveWorkspace(workspace("other-remote", on: external, windowId: 612)))

        XCTAssertTrue(local.focusWorkspace())
        XCTAssertTrue(external.activeWorkspace === local)
        XCTAssertTrue(remote.focusWorkspace())
        XCTAssertTrue(builtIn.activeWorkspace === remote)
    }

    func testFrozenWorldRestorePreservesPreferredMonitor() async throws {
        let remote = Workspace.get(byName: "remote")
        remote.seedMonitorIfNeeded(external)
        let window = TestWindow.new(id: 613, parent: remote.rootTilingContainer)
        XCTAssertTrue(builtIn.setActiveWorkspace(remote))
        // Model a workspace temporarily visible on the laptop while retaining its external preference.
        remote.preferredMonitorPoint = external.rect.topLeftCorner
        let frozenWorld = snapshotCurrentFrozenWorld()
        XCTAssertTrue(builtIn.setActiveWorkspace(workspace("local", on: builtIn, windowId: 614)))

        let restored = try await restoreFrozenWorldIfNeeded(frozenWorld, newlyDetectedWindow: window)

        XCTAssertTrue(restored)
        XCTAssertTrue(builtIn.activeWorkspace === remote)
        XCTAssertEqual(remote.preferredMonitorPoint, external.rect.topLeftCorner)
    }

    private func workspace(_ name: String, on monitor: TestMonitor, windowId: UInt32) -> Workspace {
        let workspace = Workspace.get(byName: name)
        workspace.seedMonitorIfNeeded(monitor)
        _ = TestWindow.new(id: windowId, parent: workspace.rootTilingContainer)
        return workspace
    }
}
