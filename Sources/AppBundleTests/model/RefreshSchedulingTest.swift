@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class RefreshSchedulingTest: XCTestCase {
    override func tearDown() async throws { setScheduledRefreshOverrideForTests(nil) }

    /// A geometry event that arrives while a geometry session is already running must still get
    /// a follow-up session: the running one may be past its layout pass and won't see the move.
    func testGeometryEventDuringActiveGeometrySessionIsNotLost() async throws {
        let moved = RefreshSessionEvent.ax(kAXMovedNotification as String)
        let resized = RefreshSessionEvent.ax(kAXResizedNotification as String)
        var delivered: [String] = []
        let gate = AwaitableOneTimeBroadcastLatch()
        setScheduledRefreshOverrideForTests { event, _ in
            delivered.append(event.description)
            if delivered.count == 1 { try await gate.await() } // keep the first session in flight
        }

        scheduleRefreshSession(moved)
        await Task.yield() // let the first session start and park on the gate
        scheduleRefreshSession(resized) // arrives mid-session
        scheduleRefreshSession(moved) // redundant with the pending follow-up
        await gate.signalToAll()
        try await waitForScheduledRefreshForTests()

        XCTAssertEqual(delivered.count, 2, "\(delivered)")
        XCTAssertEqual(delivered.first, moved.description)
    }
}
