import AppKit
import Common

@MainActor private var moveWithMouseSessionWindowIdsInFlight: Set<UInt32> = []
@MainActor private var moveWithMouseTrailingRerunWindowIds: Set<UInt32> = []
@MainActor private var floatingWindowDragRebindTask: Task<Void, Never>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task { @MainActor in
        await handleMovedEvent(windowId: windowId, notif: notif)
    }
}

@MainActor
private func handleMovedEvent(windowId: UInt32?, notif: String) async {
    if shouldIgnoreMovedObsForCurrentDragSession(windowId: windowId) ||
        WindowMouseInteractionOpacityController.shared.shouldSuppressObserverEvent(windowId: windowId)
    {
        // Suppressed events are our own parking/restore moves: the parked window's cache
        // deliberately holds its logical (pre-park) rect, so invalidating here would wipe it.
        return
    }
    // The cached native state (rect, fullscreen) is stale the moment the window reports
    // movement. Consumers fall back to an on-demand AX fetch (or the last applied layout
    // rect), so invalidating keeps the caches honest without polling every window on every
    // refresh barrier.
    if let windowId {
        Window.get(byId: windowId)?.invalidateLastKnownNativeState()
    }
    // Post-drag suppression only skips the refresh / drag start. The drop's relayout (swap,
    // split, new resize weights) moves windows via setAxFrame without recording their rects,
    // so the cache must still be invalidated above or it keeps the pre-drop rect indefinitely
    // and the next drag previews / hit-tests against stale geometry.
    if shouldIgnoreAxObserverEventForPostDragSuppression(windowId: windowId, notif: notif) {
        return
    }
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    guard let windowId, let window = Window.get(byId: windowId) else {
        scheduleRefreshSession(.ax(notif))
        return
    }
    if isContinuingManagedDragSessionForMovedEvent(window) { return }
    // Coalesce: kAXMoved arrives per frame during drags, and each session reads the mouse
    // and window state fresh when it runs, so events arriving while a session for this
    // window is queued or running add no information — they only pile up main-actor work
    // that keeps running long after the drag under CPU load. The trailing-rerun mark
    // guarantees the burst's final position is still processed once the session finishes
    // (a floating drag's workspace rebind depends on the last event).
    if moveWithMouseSessionWindowIdsInFlight.contains(windowId) {
        moveWithMouseTrailingRerunWindowIds.insert(windowId)
        return
    }
    // Reserve before the isManipulatedWithMouse suspension point: two queued events for the
    // same window must not both pass the in-flight check and spawn concurrent sessions.
    moveWithMouseSessionWindowIdsInFlight.insert(windowId)
    guard (try? await isManipulatedWithMouse(window)) == true else {
        moveWithMouseSessionWindowIdsInFlight.remove(windowId)
        moveWithMouseTrailingRerunWindowIds.remove(windowId)
        scheduleRefreshSession(.ax(notif))
        return
    }
    Task {
        defer {
            moveWithMouseSessionWindowIdsInFlight.remove(windowId)
            if moveWithMouseTrailingRerunWindowIds.remove(windowId) != nil {
                Task { @MainActor in
                    await handleMovedEvent(windowId: windowId, notif: notif)
                }
            }
        }
        do {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        } catch is CancellationError {
            // A newer interaction/session superseded this coalesced event.
        } catch {
            debugFocusLog("moveWithMouse coalesced session failed windowId=\(windowId) error=\(error)")
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    syncClosedWindowsCacheToCurrentWorld()
    // handleMovedEvent checked for a running resize before suspending on AX (isManipulatedWithMouse,
    // then runLightSession's focused-window query). A left/top-edge resize emits kAXMoved and
    // kAXResized together, so resizedObs may have started the resize session meanwhile; going on
    // would flip it into a move (resize preview lost, the release applies a swap/split instead).
    if getCurrentMouseManipulationKind() == .resize,
       WindowMouseInteractionDriver.shared.resizeSession?.windowId == window.windowId
    {
        return
    }
    guard let parent = window.parent else { return }
    switch parent.cases {
        case .workspace:
            moveFloatingWindowWithMouse(window)
        case .tilingContainer:
            moveTilingWindow(window)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
    }
}

@MainActor
func moveFloatingWindowWithMouse(_ window: Window) {
    if WindowMouseInteractionDriver.shared.moveSession?.windowId != window.windowId {
        let subject = resolvedMouseDragSubject(for: window)
        _ = beginWindowMoveWithMouseSessionIfNeeded(
            windowId: window.windowId,
            subject: subject,
            detachOrigin: .window,
            startedInSidebar: false,
            anchorRect: window.lastKnownActualRect ?? window.lastAppliedLayoutPhysicalRect,
            refreshActualRects: false,
        )
        WindowMouseInteractionDriver.shared.startMove(
            windowId: window.windowId,
            subject: subject,
            detachOrigin: .window,
            startedInSidebar: false,
        )
    }
    // Rebind by the window's center, as upstream does: layoutFloatingWindow decides by the center
    // too, so binding by the pointer while the center is still on the other monitor made the next
    // layout pass (at the latest the mouse-up refresh) teleport the window across monitors.
    // Called per display frame, so keep at most one AX lookup in flight.
    guard floatingWindowDragRebindTask == nil else { return }
    floatingWindowDragRebindTask = Task { @MainActor in
        defer { floatingWindowDragRebindTask = nil }
        guard let center = try? await window.getCenter(),
              let parent = window.parent,
              parent is Workspace
        else { return }
        let targetWorkspace = center.monitorApproximation.activeWorkspace
        if targetWorkspace != parent {
            window.bindAsFloatingWindow(to: targetWorkspace)
        }
    }
}

@MainActor
private func moveTilingWindow(_ window: Window) {
    let subject = resolvedMouseDragSubject(for: window)
    let didStartSession = beginWindowMoveWithMouseSessionIfNeeded(
        windowId: window.windowId,
        subject: subject,
        detachOrigin: .window,
        startedInSidebar: false,
        anchorRect: resolvedDraggedWindowAnchorRect(for: window, subject: subject),
        refreshActualRects: subject == .window,
    )
    if didStartSession, subject == .window {
        window.lastAppliedLayoutPhysicalRect = nil
    }
    WindowMouseInteractionDriver.shared.startMove(
        windowId: window.windowId,
        subject: subject,
        detachOrigin: .window,
        startedInSidebar: false,
    )
}

@MainActor
func swapWindows(_ window1: Window, _ window2: Window) {
    swapNodes(window1.moveNode, window2.moveNode)
}

@MainActor
func swapNodes(_ node1: TreeNode, _ node2: TreeNode) {
    if node1 == node2 { return }
    guard let index1 = node1.ownIndex else { return }
    guard let index2 = node2.ownIndex else { return }

    if index1 < index2 {
        let binding2 = node2.unbindFromParent()
        let binding1 = node1.unbindFromParent()

        node2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
        node1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
    } else {
        let binding1 = node1.unbindFromParent()
        let binding2 = node2.unbindFromParent()

        node1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
        node2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    }
    node1.markAsMostRecentChild()
}

extension CGPoint {
    @MainActor
    func findIn(tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .tabGroup:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): findIn(tree: container, virtual: virtual)
        }
    }
}
