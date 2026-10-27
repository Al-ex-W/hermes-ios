import XCTest
@testable import HermesVoice

final class SidebarTests: XCTestCase {
    private func json(_ text: String) throws -> JSON {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)
    }

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func session(_ id: String, hoursAgo: Double, from now: Date) -> SessionInfo {
        SessionInfo(id: id, lastActive: now.addingTimeInterval(-hoursAgo * 3600))
    }

    // MARK: Decoding

    func testSessionRowDecodesFlagsLineageAndCost() throws {
        let row = try json("""
        {"id": "s2", "title": "  ", "preview": "First words", "source": "desktop", "profile": "work",
         "started_at": 1750000000, "last_active": 1750000600.5, "message_count": 4, "input_tokens": 10,
         "output_tokens": 5, "actual_cost_usd": 0, "estimated_cost_usd": 0.25, "archived": 0, "pinned": true,
         "unread": 1, "cwd": "/srv/app", "git_repo_root": "/srv/app", "_lineage_root_id": "s0",
         "_lineage_ids": ["s0", "s1", "s2"]}
        """)
        let session = try XCTUnwrap(SessionInfo(row: row))
        XCTAssertNil(session.title, "a blank title falls back")
        XCTAssertEqual(session.displayTitle, "First words")
        XCTAssertEqual(session.profile, "work")
        XCTAssertEqual(session.lastActive, Date(timeIntervalSince1970: 1750000600.5))
        XCTAssertEqual(session.tokens, 15)
        XCTAssertEqual(session.costUSD, 0.25, "the estimate stands in when no price was reported")
        XCTAssertFalse(session.archived)
        XCTAssertTrue(session.pinned)
        XCTAssertTrue(session.unread)
        XCTAssertEqual(session.allIDs, ["s2", "s0", "s1"])
        XCTAssertEqual(session.summary.id, "s2")
        XCTAssertNil(SessionInfo(row: ["title": "no id"]))
    }

    func testSidebarResponseDropsHiddenRowsAndReadsFailures() throws {
        let response = try json("""
        {"recents": {"sessions": [{"id": "a", "last_active": 2}, {"id": "b", "hidden": true}],
                     "profiles_truncated": {"default": false, "work": true}},
         "messaging": {"sessions": [{"id": "t", "source": "telegram"}]},
         "errors": [{"profile": "broken", "error": "disk"}], "storage": {"old": "corrupt"}}
        """)
        let slices = SidebarSessions(response: response)
        XCTAssertEqual(slices.recents.map(\.id), ["a"])
        XCTAssertEqual(slices.messaging.map(\.id), ["t"])
        XCTAssertTrue(slices.truncated)
        XCTAssertEqual(slices.unreadable, ["broken", "old"])
        XCTAssertFalse(slices.failed)
        XCTAssertTrue(SidebarSessions(response: try json(#"{"recents": {"failed": true, "retry": true}}"#)).failed)
    }

    func testSearchHitStripsMarkersAndKeepsTitle() throws {
        let hit = try XCTUnwrap(SessionSearchHit(row: try json("""
        {"session_id": "tip", "lineage_root": "root", "title": " Fact check ", "snippet": "said >>>MARCO<<< twice",
         "session_started": 100, "last_active": null, "profile": "default"}
        """)))
        XCTAssertEqual(hit.session.id, "tip")
        XCTAssertEqual(hit.session.title, "Fact check")
        XCTAssertEqual(hit.snippet, "said MARCO twice")
        XCTAssertEqual(hit.session.lastActive, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(hit.session.allIDs, ["tip", "root"])
    }

    func testProfileRowsDecode() throws {
        let rows = try json(#"{"profiles": [{"name": "work", "display_name": " Work "}, {"name": "default"}, {"name": ""}]}"#)
        let profiles = (rows["profiles"] as? [JSON] ?? []).compactMap(ProfileInfo.init(row:))
        XCTAssertEqual(profiles.map(\.label), ["Work", "default"])
        XCTAssertEqual(profiles.map(\.isDefault), [false, true], "the root profile is the default when the row doesn't say")
    }

    func testOptionsDecodeLeniently() throws {
        let options = try JSONDecoder().decode(SidebarOptions.self, from: Data(#"{"grouping": "status", "ordering": "bogus"}"#.utf8))
        XCTAssertEqual(options.grouping, .status)
        XCTAssertEqual(options.ordering, .updated)
        XCTAssertEqual(options.profileScope, SidebarOptions.allProfiles)
        XCTAssertFalse(options.filtersActive)
        var archived = SidebarOptions()
        archived.showArchived = true
        XCTAssertTrue(archived.filtersActive)
        XCTAssertTrue(archived.isCustomized)
    }

    // MARK: Date groups

    func testNavigationRowsAndOverlays() {
        // The desktop's SIDEBAR_NAV order; Kanban (a plugin row) and the overlay routes aren't in it.
        XCTAssertEqual(SidebarDestination.screens, [.capabilities, .messaging, .artifacts, .scheduledJobs])
        let overlays: [SidebarDestination] = [.commandCenter, .agents, .webhooks, .memoryGraph]
        XCTAssertTrue(overlays.allSatisfy(\.isOverlay))
        XCTAssertFalse(([.draft, .session("s1"), .kanban] + SidebarDestination.screens).contains(where: \.isOverlay))
        // Screens without a profile stay put when the sidebar's profile changes.
        XCTAssertEqual([SidebarDestination.artifacts, .kanban, .agents, .messaging, .webhooks, .memoryGraph].map(\.followsProfile),
                       [false, false, false, true, true, true])
        XCTAssertEqual(SidebarDestination.kanban.title, "Kanban")
    }

    func testCalendarBuckets() {
        let calendar = calendar()
        let now = date("2026-06-17T12:00:00Z") // a Wednesday; the week starts Monday the 15th
        func bucket(_ text: String) -> String { SessionGroups.calendarBucket(date(text), now: now, calendar: calendar).label }
        XCTAssertEqual(bucket("2026-06-17T10:00:00Z"), "Earlier today")
        XCTAssertEqual(bucket("2026-06-16T15:00:00Z"), "Yesterday")
        XCTAssertEqual(bucket("2026-06-17T02:00:00Z"), "Yesterday", "the small hours belong to the evening before")
        XCTAssertEqual(bucket("2026-06-15T12:00:00Z"), "Earlier this week")
        XCTAssertEqual(bucket("2026-06-10T12:00:00Z"), "Last week")
        XCTAssertEqual(bucket("2026-06-03T12:00:00Z"), "Earlier this month")
        XCTAssertEqual(bucket("2026-05-05T12:00:00Z"), "May")
        XCTAssertEqual(bucket("2025-12-01T12:00:00Z"), "December 2025")
    }

    func testDayRolloverFollowsTheWallClockAcrossDST() {
        let calendar = calendar("Europe/Stockholm")
        let now = date("2026-10-25T02:38:00Z") // 03:38 CET, the night the clocks went back
        func bucket(_ text: String) -> String { SessionGroups.calendarBucket(date(text), now: now, calendar: calendar).label }
        XCTAssertEqual(bucket("2026-10-23T19:38:00Z"), "Yesterday", "21:38 two evenings ago, before this night's rollover")
        XCTAssertEqual(bucket("2026-10-24T22:30:00Z"), "Earlier today", "00:30 CEST is still the same night")
    }

    func testRecencyGroupsLeaveTheNewestRunUnlabelled() {
        let calendar = calendar()
        let now = date("2026-06-17T12:00:00Z")
        let rows = [0.1, 0.2, 0.3, 0.4, 0.5, 3, 3.1, 30, 50].enumerated().map { session("s\($0.offset)", hoursAgo: $0.element, from: now) }
        let groups = SessionGroups.byRecency(rows, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), [nil, "Earlier today", "Yesterday", "Earlier this week"])
        XCTAssertEqual(groups.map(\.sessions.count), [5, 2, 1, 1])
    }

    func testOneRunHasNoDividers() {
        let now = date("2026-06-17T12:00:00Z")
        let rows = (0..<8).map { session("s\($0)", hoursAgo: Double($0) * 0.1, from: now) }
        let groups = SessionGroups.byRecency(rows, now: now, calendar: calendar())
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].title)
        XCTAssertEqual(groups[0].sessions.count, 8)
    }

    func testAHeadInTheSameBucketAsTheRowsBelowDissolves() {
        let now = date("2026-06-17T23:00:00Z")
        let rows = [session("a", hoursAgo: 0.1, from: now), session("b", hoursAgo: 9.5, from: now)]
        let groups = SessionGroups.byRecency(rows, now: now, calendar: calendar())
        XCTAssertEqual(groups.map(\.title), [nil])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["a", "b"])
    }

    // MARK: Ordering and other groupings

    func testOrderings() {
        let now = date("2026-06-17T12:00:00Z")
        var cheap = session("cheap", hoursAgo: 1, from: now)
        cheap.costUSD = 0.1
        cheap.inputTokens = 900
        var pricey = session("pricey", hoursAgo: 5, from: now)
        pricey.costUSD = 2
        pricey.inputTokens = 10
        var waiting = session("waiting", hoursAgo: 9, from: now)
        waiting.startedAt = now
        let rows = [pricey, waiting, cheap]
        let status: (SessionInfo) -> SessionStatus = { $0.id == "waiting" ? .needsInput : .idle }
        XCTAssertEqual(SessionGroups.sorted(rows, by: .updated, status: status).map(\.id), ["cheap", "pricey", "waiting"])
        XCTAssertEqual(SessionGroups.sorted(rows, by: .created, status: status).first?.id, "waiting")
        XCTAssertEqual(SessionGroups.sorted(rows, by: .status, status: status).map(\.id), ["waiting", "cheap", "pricey"])
        XCTAssertEqual(SessionGroups.sorted(rows, by: .tokens, status: status).first?.id, "cheap")
        XCTAssertEqual(SessionGroups.sorted(rows, by: .cost, status: status).first?.id, "pricey")
    }

    func testProjectProfileAndStatusGroups() {
        let now = Date()
        var a = session("a", hoursAgo: 1, from: now)
        a.gitRepoRoot = "/srv/app"
        a.cwd = "/srv/app/sub"
        var b = session("b", hoursAgo: 2, from: now)
        b.cwd = "/tmp/scratch"
        b.profile = "work"
        let c = session("c", hoursAgo: 3, from: now)
        var d = session("d", hoursAgo: 4, from: now)
        d.gitRepoRoot = "/srv/app"
        d.profile = "default"

        let projects = SessionGroups.byProject([a, b, c, d])
        XCTAssertEqual(projects.map(\.title), ["app", "scratch", "Home"])
        XCTAssertEqual(projects[0].sessions.map(\.id), ["a", "d"])

        let profiles = SessionGroups.byProfile([b, a, d]) { $0 == "work" ? "Work" : $0 }
        XCTAssertEqual(profiles.map(\.title), ["default", "Work"])
        XCTAssertEqual(profiles[0].sessions.map(\.id), ["a", "d"])

        let status = SessionGroups.byStatus([a, b, c]) { $0.id == "b" }
        XCTAssertEqual(status.map(\.title), ["Working", "Done"])
        XCTAssertEqual(status[1].sessions.map(\.id), ["a", "c"])
        XCTAssertEqual(SessionGroups.byStatus([a]) { _ in false }.map(\.title), ["Done"])
    }

    func testAgeAndSearchMatching() {
        let now = date("2026-06-17T12:00:00Z")
        XCTAssertEqual(SessionGroups.age(now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(SessionGroups.age(now.addingTimeInterval(-5 * 60), now: now), "5m")
        XCTAssertEqual(SessionGroups.age(now.addingTimeInterval(-3 * 3600), now: now), "3h")
        XCTAssertEqual(SessionGroups.age(now.addingTimeInterval(-50 * 3600), now: now), "2d")
        XCTAssertEqual(SessionGroups.age(nil, now: now), "")

        var row = SessionInfo(id: "20260617_abc", title: "Gateway work")
        row.gitBranch = "feature/sidebar"
        XCTAssertTrue(SessionGroups.matches(row, query: "gateway"))
        XCTAssertTrue(SessionGroups.matches(row, query: "abc"))
        XCTAssertTrue(SessionGroups.matches(row, query: "SIDEBAR"))
        XCTAssertFalse(SessionGroups.matches(row, query: "  "))
        XCTAssertFalse(SessionGroups.matches(row, query: "nothing"))
    }
}
