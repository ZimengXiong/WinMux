import Foundation

/// Opening a window from an empty workspace usually starts by activating the app (Dock click,
/// Cmd-Tab, Dock "New Window"). macOS then focuses that app's existing window, which lives on
/// some other workspace, so focus follows it there and the window the user actually asked for
/// opens on that other workspace instead of the empty one they were on.
///
/// This is common in WinMux because clicking the sidebar activates WinMux itself, so the previous
/// app loses native focus and has to be re-activated before it receives Cmd-N.
///
/// When focus is pulled away from an empty workspace by a native app activation, remember the
/// empty workspace for a short grace period. If that app creates a new window within it, the
/// window is placed back on the empty workspace (and focusing it brings that workspace back).
@MainActor private struct NewWindowReturnTarget {
    let workspaceId: WorkspaceId
    let appPid: Int32
    let jumpedToWorkspaceId: WorkspaceId
    let expiresAt: Date
}

@MainActor private var newWindowReturnTarget: NewWindowReturnTarget? = nil

let newWindowReturnGracePeriod: TimeInterval = 4

@MainActor
func recordNativeActivationFocusJump(from source: LiveFocus, to window: Window, now: Date = .now) {
    guard source.windowOrNil == nil,
          source.workspace.isEffectivelyEmpty,
          !source.workspace.isArchived,
          let targetWorkspace = window.nodeWorkspace,
          targetWorkspace != source.workspace
    else { return }
    newWindowReturnTarget = NewWindowReturnTarget(
        workspaceId: source.workspace.id,
        appPid: window.app.pid,
        jumpedToWorkspaceId: targetWorkspace.id,
        expiresAt: now.addingTimeInterval(newWindowReturnGracePeriod),
    )
}

/// The workspace a new window of `appPid` should open on instead of the focused one, if any.
/// Doesn't consume the target: call `consumeNewWindowReturnWorkspace` once the window is bound.
@MainActor
func newWindowReturnWorkspace(appPid: Int32, now: Date = .now) -> Workspace? {
    guard let target = liveNewWindowReturnTarget(now: now),
          target.appPid == appPid,
          // The user hasn't moved on from where the activation took them
          focus.workspace.id == target.jumpedToWorkspaceId,
          let workspace = winMuxWorkspaceState.workspaceById[target.workspaceId],
          !workspace.isArchived,
          workspace.isEffectivelyEmpty
    else { return nil }
    return workspace
}

@MainActor
func consumeNewWindowReturnWorkspace() {
    newWindowReturnTarget = nil
}

/// Keeps the remembered empty workspace from being pruned while the grace period runs.
@MainActor
func isPendingNewWindowReturnWorkspace(_ workspace: Workspace, now: Date = .now) -> Bool {
    liveNewWindowReturnTarget(now: now)?.workspaceId == workspace.id
}

@MainActor
func resetNewWindowReturnTargetForTests() {
    newWindowReturnTarget = nil
}

@MainActor
private func liveNewWindowReturnTarget(now: Date) -> NewWindowReturnTarget? {
    guard let target = newWindowReturnTarget else { return nil }
    if target.expiresAt <= now {
        newWindowReturnTarget = nil
        return nil
    }
    return target
}
