import CoreGraphics
import Foundation

@MainActor
var shouldSuppressChromeForNativeFullscreenContent = false

@MainActor
var nativeFullscreenSuppressedMonitorIds: Set<Int> = []

@MainActor
func updateNativeFullscreenChromeSuppression() {
    nativeFullscreenSuppressedMonitorIds = onScreenNativeFullscreenMonitorIds()
    shouldSuppressChromeForNativeFullscreenContent = !nativeFullscreenSuppressedMonitorIds.isEmpty
}

/// A natively fullscreen window keeps covering its display no matter what is focused: the
/// frontmost app can live on another Space (an all-spaces panel, a cmd-tab, a CLI command) while
/// the fullscreen video still fills the screen underneath. Deriving the suppression from the
/// focused window therefore put the sidebar back on top of the video the moment focus moved off
/// the fullscreen window -- and it never moved back on its own, so it stayed there.
///
/// Ask the window server what is actually displayed instead: `.optionOnScreenOnly` lists only
/// windows belonging to the Spaces currently on screen, so a fullscreen window shows up exactly
/// while its Space is the one being displayed. Scope suppression to the monitor containing each
/// on-screen fullscreen window so other displays keep their sidebar and tab bars.
@MainActor
private func onScreenNativeFullscreenMonitorIds() -> Set<Int> {
    let fullscreenWindowIds = Set(
        Workspace.all
            .compactMap(\.existingMacOsNativeFullscreenWindowsContainer)
            .flatMap { $0.children.filterIsInstance(of: Window.self) }
            .map(\.windowId)
    )
    // Nothing is natively fullscreen, so skip the CGWindowList snapshot entirely. This is the
    // common case and it runs once per refresh session.
    guard !fullscreenWindowIds.isEmpty else { return [] }

    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let windowInfos = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] else { return [] }
    let allMonitors = monitors
    var suppressedIds: Set<Int> = []
    for dict in windowInfos {
        guard let rawWindowId = dict[kCGWindowNumber as String] as? NSNumber,
              fullscreenWindowIds.contains(rawWindowId.uint32Value)
        else { continue }
        if let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
           let bounds = CGRect(dictionaryRepresentation: boundsDict)
        {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            if let monitor = allMonitors.first(where: { $0.rect.contains(center) }) {
                suppressedIds.insert(monitor.monitorAppKitNsScreenScreensId)
                continue
            }
        }
        // Fallback if bounds are unavailable or outside known monitor rects.
        for monitor in allMonitors {
            suppressedIds.insert(monitor.monitorAppKitNsScreenScreensId)
        }
    }
    return suppressedIds
}

@MainActor
func shouldSuppressChromeForFullscreenContent(on monitor: Monitor) -> Bool {
    if !nativeFullscreenSuppressedMonitorIds.isEmpty {
        return nativeFullscreenSuppressedMonitorIds.contains(monitor.monitorAppKitNsScreenScreensId)
    }
    return shouldSuppressChromeForNativeFullscreenContent
}

@MainActor
func shouldSuppressWorkspaceSidebarForFullscreenContent() -> Bool {
    shouldSuppressChromeForNativeFullscreenContent
}
