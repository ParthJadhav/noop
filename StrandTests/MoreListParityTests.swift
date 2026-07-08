import XCTest
@testable import Strand

/// Guards the #805/#811 regression: the v7.3.1 #766 alarm consolidation folded Smart Alarm under a
/// single "Alarms" entry in the macOS/iPad sidebar (`NavItem.smartAlarm`), but the iPhone `RootTabView`
/// More list dropped the row, leaving Alarms unreachable on iPhone.
///
/// The iPhone More list is a `@ViewBuilder` (not directly introspectable), so this pins the *contract*
/// it must mirror: the shared sidebar exposes the `smartAlarm` destination with the exact SF Symbol the
/// restored `MoreRow("Alarms", "alarm.fill")` row uses. A future icon rename then fails here so the two
/// shells get fixed in lockstep rather than silently drifting apart again.
///
/// Notifications (`NavItem.notifications`) is deliberately NOT mirrored on iPhone: its screen
/// (`NotificationSettingsView`) is macOS-only (NSWorkspace app picker, imports AppKit, excluded from the
/// iOS target in project.yml), so the iPhone More list correctly omits it. The enum case still exists for
/// the macOS sidebar; that's all this asserts about it.
final class MoreListParityTests: XCTestCase {

    /// Alarms is the destination the iPhone More list had been missing; it must exist in the shared
    /// sidebar enum (the iPhone `MoreRow("Alarms")` routes to the same `SmartAlarmView`).
    func testSidebarExposesAlarms() {
        XCTAssertTrue(NavItem.allCases.contains(.smartAlarm),
                      "Alarms (smartAlarm) must stay a sidebar destination the iPhone More list mirrors.")
    }

    /// The restored iPhone Alarms row pins this exact SF Symbol; keep it identical to the sidebar so the
    /// two shells read the same.
    func testAlarmsIconMatchesTheRestorediPhoneRow() {
        XCTAssertEqual(NavItem.smartAlarm.icon, "alarm.fill")
    }

    /// Notifications stays a (macOS-only) sidebar destination. It is intentionally absent from the iPhone
    /// More list, so this only documents that the enum case is still the macOS home for it.
    func testNotificationsRemainsAMacOSSidebarDestination() {
        XCTAssertTrue(NavItem.allCases.contains(.notifications))
    }

    // MARK: - M5 gate (S1 grouping): every destination stays reachable after grouping

    /// The S1 macOS sidebar grouping (#805) folds the 28 flat `NavItem` cases into ~5 collapsible
    /// `NavGroup`s. The regression it guards against is a destination silently vanishing during a
    /// consolidation (the way the iPhone Smart-Alarm row did). This pins the contract: EVERY `NavItem`
    /// case must appear in exactly one group, so nothing is dropped and nothing is double-listed.
    func testEveryNavItemIsReachableInExactlyOneGroup() {
        let grouped = NavGroup.all.flatMap(\.items)

        // 1. No destination lost: every enum case is somewhere in the grouped layout.
        for item in NavItem.allCases {
            XCTAssertTrue(grouped.contains(item),
                          "NavItem.\(item.rawValue) is not reachable in any sidebar group after S1 grouping.")
        }

        // 2. No destination duplicated: a case must live in exactly one group (count == cases).
        XCTAssertEqual(grouped.count, NavItem.allCases.count,
                       "Sidebar groups list \(grouped.count) rows for \(NavItem.allCases.count) destinations; a case is duplicated or stray.")
        XCTAssertEqual(Set(grouped).count, NavItem.allCases.count,
                       "A NavItem appears in more than one sidebar group.")
    }

    /// Smart Alarm (the #805 casualty) must survive the S1 grouping too: it has to resolve to a group, so
    /// it is reachable in the collapsible sidebar, not just present as an orphaned enum case.
    func testSmartAlarmResolvesToAGroupAfterGrouping() {
        XCTAssertNotNil(NavGroup.group(containing: .smartAlarm),
                        "Alarms (smartAlarm) must belong to a sidebar group so it stays reachable post-S1.")
    }

    /// S6: the four overlapping insight surfaces (Intelligence / What Moves You / Insights / Insights Hub)
    /// collapse under one Insights group rather than scattering across the flat list. Pin that they share a
    /// single group so a future edit can't re-scatter them.
    func testInsightSurfacesShareOneGroup() {
        let insightItems: [NavItem] = [.intelligence, .insightsHub, .insights]
        let groups = Set(insightItems.compactMap { NavGroup.group(containing: $0)?.id })
        XCTAssertEqual(groups.count, 1,
                       "The overlapping insight surfaces must collapse under a single sidebar group (S6).")
    }

    /// The initial expanded set keeps the sidebar to "headers + the active group": every single-item group
    /// plus the group owning the launch selection, and nothing more (the heavy groups stay collapsed).
    func testInitialExpansionShowsActiveGroupPlusSingletons() {
        let open = RootView.initialExpandedGroups(for: .today)
        // Today's own group is expanded.
        XCTAssertTrue(open.contains("today"))
        // Single-item groups are expanded so their lone row is visible.
        XCTAssertTrue(open.contains("sleep"))
        // A heavy group the user hasn't entered stays collapsed at rest.
        XCTAssertFalse(open.contains("data_app"))
    }
}
