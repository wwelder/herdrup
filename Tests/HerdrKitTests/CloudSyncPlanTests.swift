import XCTest
@testable import HerdrKit

/// Which way saved machines move between a device and iCloud.
final class CloudSyncPlanTests: XCTestCase {
    private func action(cloud: Bool = true, synced: Bool = true, empty: Bool = false,
                        local: Bool = false, remote: Bool = false) -> CloudSyncAction {
        CloudSyncPlan.action(hasCloud: cloud, everSynced: synced, localEmpty: empty,
                             localChanged: local, cloudChanged: remote)
    }

    func testTheFirstDeviceUploadsAndANewDeviceDownloads() {
        XCTAssertEqual(action(cloud: false, synced: false), .upload, "nothing in iCloud yet: this device's machines go up")
        XCTAssertEqual(action(cloud: false, synced: false, empty: true), .none, "nothing anywhere")
        XCTAssertEqual(action(synced: false, empty: true, remote: true), .download,
                       "a new device takes iCloud's machines without asking")
    }

    func testOneSidedChangesFollowTheSideThatChanged() {
        XCTAssertEqual(action(), .none)
        XCTAssertEqual(action(local: true), .upload)
        XCTAssertEqual(action(remote: true), .download)
        XCTAssertEqual(action(empty: true, local: true), .upload, "removing the last machine here is a change like any other")
    }

    func testTheOwnerChoosesWhenBothSidesHoldDifferentMachines() {
        XCTAssertEqual(action(local: true, remote: true), .conflict)
        XCTAssertEqual(action(synced: false, local: true, remote: true), .conflict,
                       "two devices that each paired on their own, turned on for the first time")
    }
}
