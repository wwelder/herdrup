import Foundation

/// What a device does once it has compared its saved machines with iCloud's copy.
public enum CloudSyncAction: Equatable, Sendable {
    case none
    /// iCloud shows no copy and this device has machines: offer to upload them, never do it
    /// unasked. "No copy" can also mean iCloud has not delivered one yet, and an upload would
    /// then replace machines this device has never seen.
    case offerUpload
    /// This device's machines replace iCloud's copy.
    case upload
    /// iCloud's copy replaces this device's machines.
    case download
    /// Both changed since they last agreed, or they never agreed and both hold machines: the
    /// owner picks which one wins.
    case conflict
}

public enum CloudSyncPlan {
    /// - Parameters:
    ///   - hasCloud: iCloud holds a copy at all.
    ///   - everSynced: this device and iCloud have agreed before.
    ///   - localEmpty: this device has no machines.
    ///   - localChanged: this device's machines are not what it last agreed on.
    ///   - cloudChanged: iCloud's copy is not the one this device last agreed on.
    ///   - overwritten: iCloud's copy was not made on top of the copy this device last
    ///     agreed on: another device uploaded at about the same time, or an older copy was
    ///     put back.
    public static func action(hasCloud: Bool, everSynced: Bool, localEmpty: Bool,
                              localChanged: Bool, cloudChanged: Bool, overwritten: Bool = false) -> CloudSyncAction {
        guard hasCloud else { return localEmpty ? .none : .offerUpload }
        // A device that never synced takes iCloud's copy when it has nothing of its own (a new
        // device); with machines of its own there is no telling which side is right.
        guard everSynced else { return localEmpty ? .download : .conflict }
        switch (localChanged, cloudChanged) {
        case (false, false): return .none
        case (true, false): return .upload
        case (false, true): return overwritten ? .conflict : .download
        case (true, true): return .conflict
        }
    }
}
