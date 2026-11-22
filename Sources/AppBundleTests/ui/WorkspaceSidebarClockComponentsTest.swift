@testable import AppBundle
import Foundation
import XCTest

final class WorkspaceSidebarClockComponentsTest: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var thursdayJanuary31: Date {
        calendar.date(from: DateComponents(year: 2030, month: 1, day: 31, hour: 12, minute: 34, second: 56))!
    }

    func testCompactClockHourFollowsLocaleHourCycle() {
        let afternoon = calendar.date(from: DateComponents(year: 2030, month: 1, day: 31, hour: 21, minute: 24, second: 44))!
        let us = WorkspaceSidebarClockComponents(date: afternoon, locale: Locale(identifier: "en_US"), calendar: calendar)
        let de = WorkspaceSidebarClockComponents(date: afternoon, locale: Locale(identifier: "de_DE"), calendar: calendar)

        let usNoon = WorkspaceSidebarClockComponents(
            date: calendar.date(from: DateComponents(year: 2030, month: 1, day: 31, hour: 12, minute: 0))!,
            locale: Locale(identifier: "en_US"),
            calendar: calendar,
        )

        XCTAssertEqual(us.hour, "09")
        XCTAssertEqual(usNoon.hour, "12")
        XCTAssertEqual(de.hour, "21")
        XCTAssertEqual(us.minute, "24")
        XCTAssertEqual(us.second, "44")
    }

    func testExpandedClockUsesSeparateFullEnglishWeekdayAndMonthDayLines() {
        let lines = WorkspaceSidebarExpandedClockDateLines(
            date: thursdayJanuary31,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )

        XCTAssertEqual(lines.weekday, "Thursday")
        XCTAssertEqual(lines.monthAndDay, "January 31")
    }

    func testExpandedClockKeepsLongLocalizedDateTextUnabbreviated() {
        let lines = WorkspaceSidebarExpandedClockDateLines(
            date: thursdayJanuary31,
            locale: Locale(identifier: "de_DE"),
            calendar: calendar
        )

        XCTAssertEqual(lines.weekday, "Donnerstag")
        XCTAssertEqual(lines.monthAndDay, "31. Januar")
    }

    func testExpandedClockDateAndWeekdayLinesAreIndependent() {
        XCTAssertEqual(workspaceSidebarExpandedClockDateLineCount(showsDate: false, showsWeekday: false), 0)
        XCTAssertEqual(workspaceSidebarExpandedClockDateLineCount(showsDate: true, showsWeekday: false), 1)
        XCTAssertEqual(workspaceSidebarExpandedClockDateLineCount(showsDate: false, showsWeekday: true), 1)
        XCTAssertEqual(workspaceSidebarExpandedClockDateLineCount(showsDate: true, showsWeekday: true), 2)
    }

    func testExpandedClockGrowsForEachVisibleDateLine() {
        XCTAssertEqual(workspaceSidebarExpandedClockCardHeight(showsDate: false, showsWeekday: false), 68)
        XCTAssertEqual(workspaceSidebarExpandedClockCardHeight(showsDate: true, showsWeekday: false), 87)
        XCTAssertEqual(workspaceSidebarExpandedClockCardHeight(showsDate: true, showsWeekday: true), 106)
    }

    func testExpandedClockAccessibilityKeepsDateAndWeekdayIndependent() {
        let weekdayOnly = workspaceSidebarExpandedClockAccessibilitySummary(
            date: thursdayJanuary31,
            showsSeconds: false,
            showsDate: false,
            showsWeekday: true,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )
        let dateOnly = workspaceSidebarExpandedClockAccessibilitySummary(
            date: thursdayJanuary31,
            showsSeconds: false,
            showsDate: true,
            showsWeekday: false,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )

        XCTAssertTrue(weekdayOnly.contains("Thursday"))
        XCTAssertFalse(weekdayOnly.contains("January"))
        XCTAssertTrue(dateOnly.contains("January 31"))
        XCTAssertFalse(dateOnly.contains("Thursday"))
    }
}
