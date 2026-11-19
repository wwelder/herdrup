import Foundation

/// What a device does once it has compared its saved machines with iCloud's copy.
public enum CloudSyncAction: Equatable, Sendable {
    case none
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
    public static func action(hasCloud: Bool, everSynced: Bool, localEmpty: Bool,
                              localChanged: Bool, cloudChanged: Bool) -> CloudSyncAction {
        guard hasCloud else { return localEmpty ? .none : .upload }
        // A device that never synced takes iCloud's copy when it has nothing of its own (a new
        // device); with machines of its own there is no telling which side is right.
        guard everSynced else { return localEmpty ? .download : .conflict }
        switch (localChanged, cloudChanged) {
        case (false, false): return .none
        case (true, false): return .upload
        case (false, true): return .download
        case (true, true): return .conflict
        }
    }
}
