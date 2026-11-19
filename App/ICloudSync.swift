import Combine
import CryptoKit
import HerdrKit
import Security
import SwiftUI
import UIKit

// iCloud sync of the saved machines. A machine paired on one device is usable on the owner's
// other devices once they have synced: the list travels in iCloud key-value storage, and each
// machine's private key or password in iCloud Keychain (end to end encrypted), never in the
// list. It is off until the owner turns it on, per device.

/// iCloud's copy of the machine list.
struct CloudMachines: Codable, Equatable {
    /// A new value on every upload: how a device tells whether iCloud's copy changed.
    var revision: String
    var hosts: [SavedHost]
    /// Per machine id, the version of its secret that goes with this revision. A machine whose
    /// device held no secret has no entry.
    var secretVersions: [String: String]
    /// The device that uploaded it, for the conflict question.
    var device: String
    var updatedAt: Date
}

/// One machine's secret as iCloud Keychain holds it.
struct CloudSecret: Codable, Equatable {
    var version: String
    var secret: String
}

/// Where iCloud's copy lives. A protocol so a Debug run can stand a folder in for iCloud.
protocol CloudMachineStore {
    /// False when the device is not signed in to iCloud.
    var available: Bool { get }
    func load() -> CloudMachines?
    func save(_ machines: CloudMachines) -> Bool
    func secret(for id: String) -> CloudSecret?
    func saveSecret(_ secret: CloudSecret, for id: String) -> Bool
    func deleteSecrets(except keep: Set<String>)
    /// Calls `changed` on the main queue when another device changed the copy.
    func observe(_ changed: @escaping () -> Void)
}

/// The real thing: `NSUbiquitousKeyValueStore` for the list, synchronizable Keychain items in
/// the app's access group for the secrets.
struct ICloudMachineStore: CloudMachineStore {
    private let key = "dev.herdr.savedHosts.cloud.v1"
    private let service = "dev.herdr.credentials.sync"

    var available: Bool { FileManager.default.ubiquityIdentityToken != nil }

    func load() -> CloudMachines? {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        return store.data(forKey: key).flatMap { try? JSONDecoder().decode(CloudMachines.self, from: $0) }
    }

    func save(_ machines: CloudMachines) -> Bool {
        guard let data = try? JSONEncoder().encode(machines) else { return false }
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
        return NSUbiquitousKeyValueStore.default.synchronize()
    }

    private func query(_ id: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }

    func secret(for id: String) -> CloudSecret? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CloudSecret.self, from: data)
    }

    func saveSecret(_ secret: CloudSecret, for id: String) -> Bool {
        guard let data = try? JSONEncoder().encode(secret) else { return false }
        let updated = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query(id)
        add[kSecValueData as String] = data
        // Not "this device only": the item has to leave the device to sync.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func deleteSecrets(except keep: Set<String>) {
        var all = query(nil)
        all[kSecReturnAttributes as String] = true
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(all as CFDictionary, &items) == errSecSuccess,
              let found = items as? [[String: Any]] else { return }
        for item in found {
            guard let id = item[kSecAttrAccount as String] as? String, !keep.contains(id) else { continue }
            SecItemDelete(query(id) as CFDictionary)
        }
    }

    func observe(_ changed: @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main) { _ in changed() }
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

#if DEBUG
/// A folder standing in for iCloud, so two simulators (which read the Mac's files) can sync
/// with each other without an Apple ID: `HERDR_DEBUG_FAKE_ICLOUD=<folder>`.
struct FolderCloudStore: CloudMachineStore {
    let folder: URL

    static var fromEnvironment: FolderCloudStore? {
        ProcessInfo.processInfo.environment["HERDR_DEBUG_FAKE_ICLOUD"].map { FolderCloudStore(folder: URL(fileURLWithPath: $0)) }
    }

    private var list: URL { folder.appendingPathComponent("machines.json") }
    private func file(_ id: String) -> URL { folder.appendingPathComponent("secret-\(id).json") }

    var available: Bool { true }
    func load() -> CloudMachines? {
        (try? Data(contentsOf: list)).flatMap { try? JSONDecoder().decode(CloudMachines.self, from: $0) }
    }
    func save(_ machines: CloudMachines) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(machines) else { return false }
        return (try? data.write(to: list, options: .atomic)) != nil
    }
    func secret(for id: String) -> CloudSecret? {
        (try? Data(contentsOf: file(id))).flatMap { try? JSONDecoder().decode(CloudSecret.self, from: $0) }
    }
    func saveSecret(_ secret: CloudSecret, for id: String) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(secret) else { return false }
        return (try? data.write(to: file(id), options: .atomic)) != nil
    }
    func deleteSecrets(except keep: Set<String>) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("secret-") && !keep.contains(String(name.dropFirst(7).dropLast(5))) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
    func observe(_ changed: @escaping () -> Void) {
        // ponytail: polls the folder every 2 s; a file-system watcher if a test ever needs it faster.
        var seen = load()?.revision
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let now = load()?.revision
            if now != seen { seen = now; changed() }
        }
    }
}
#endif

/// Keeps this device's machines and iCloud's copy the same, and asks the owner which one wins
/// when both changed. A singleton like `SavedHostsStore`, which it reads and rewrites.
@MainActor
final class ICloudSync: ObservableObject {
    static let shared = ICloudSync()

    enum Status: Equatable {
        case off, unavailable, upToDate, uploaded(Int), downloaded(Int)
        /// iCloud's list is here but iCloud Keychain has not delivered every secret yet.
        case waitingForKeys
        case conflict, failed
    }

    enum Direction { case upload, download }

    private static let enabledKey = "icloud.sync.machines"
    private static let revisionKey = "icloud.sync.revision"
    private static let digestKey = "icloud.sync.digest"
    private static let saltKey = "icloud.sync.salt"

    @Published private(set) var status: Status = .off
    /// The conflict question is on screen.
    @Published var choosing = false
    /// iCloud's copy as last read, for the conflict question.
    @Published private(set) var cloud: CloudMachines?
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled {
                sync()
            } else {
                retry?.cancel()
                status = .off
                choosing = false
            }
        }
    }

    private let store: CloudMachineStore
    private let hosts = SavedHostsStore.shared
    private let defaults = UserDefaults.standard
    private var watching: AnyCancellable?
    private var retry: Task<Void, Never>?
    /// True while a download rewrites the saved machines, so that rewrite is not read as a local change.
    private var applying = false
    private var started = false

    private init() {
        #if DEBUG
        store = FolderCloudStore.fromEnvironment ?? ICloudMachineStore()
        #else
        store = ICloudMachineStore()
        #endif
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Once, at launch: syncs now, whenever another device changes iCloud's copy, whenever the
    /// machines change here, and when the app comes back to the front.
    func start() {
        guard !started else { return }
        started = true
        store.observe { [weak self] in Task { @MainActor in self?.sync() } }
        watching = hosts.$hosts.dropFirst().sink { [weak self] _ in
            // The store publishes before it has written; look after it has.
            DispatchQueue.main.async { self?.sync() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        sync()
    }

    func sync() {
        guard enabled, !applying else { return }
        guard store.available else { status = .unavailable; return }
        let cloud = store.load()
        self.cloud = cloud
        let synced = defaults.string(forKey: Self.revisionKey)
        let action = CloudSyncPlan.action(
            hasCloud: cloud != nil, everSynced: synced != nil, localEmpty: hosts.hosts.isEmpty,
            localChanged: localDigest() != defaults.string(forKey: Self.digestKey),
            cloudChanged: cloud?.revision != synced)
        switch action {
        case .none:
            // Keep saying what the last sync did until something else happens.
            switch status {
            case .uploaded, .downloaded: break
            default: status = .upToDate
            }
        case .upload: upload()
        case .download: if let cloud { download(cloud) }
        case .conflict:
            // Ask once when the conflict appears; after "Not now" the row offers the question again.
            if status != .conflict { choosing = true }
            status = .conflict
        }
    }

    /// The owner's answer to the conflict question.
    func resolve(_ direction: Direction) {
        choosing = false
        switch direction {
        case .upload: upload()
        case .download:
            guard let cloud = store.load() else { status = .failed; return }
            download(cloud)
        }
    }

    private func upload() {
        retry?.cancel()
        var versions: [String: String] = [:]
        for host in hosts.hosts {
            // A machine this device holds no secret for goes up as a list entry only.
            guard let secret = hosts.secret(for: host) else { continue }
            let version = UUID().uuidString
            guard store.saveSecret(CloudSecret(version: version, secret: secret), for: host.id.uuidString) else {
                status = .failed
                return
            }
            versions[host.id.uuidString] = version
        }
        let copy = CloudMachines(revision: UUID().uuidString, hosts: hosts.hosts, secretVersions: versions,
                                 device: UIDevice.current.name, updatedAt: Date())
        guard store.save(copy) else { status = .failed; return }
        store.deleteSecrets(except: Set(versions.keys))
        cloud = copy
        remember(copy.revision)
        status = .uploaded(copy.hosts.count)
    }

    private func download(_ cloud: CloudMachines) {
        var machines: [(host: SavedHost, secret: String?)] = []
        for host in cloud.hosts {
            let id = host.id.uuidString
            guard let version = cloud.secretVersions[id] else { machines.append((host, nil)); continue }
            // The list syncs faster than iCloud Keychain: wait for every secret of this revision.
            guard let item = store.secret(for: id), item.version == version else {
                status = .waitingForKeys
                waitForKeys()
                return
            }
            machines.append((host, item.secret))
        }
        retry?.cancel()
        applying = true
        let replaced = hosts.replaceAll(machines)
        applying = false
        guard replaced else { status = .failed; return }
        remember(cloud.revision)
        status = .downloaded(cloud.hosts.count)
    }

    /// iCloud Keychain announces nothing when an item arrives, so look again every few seconds.
    private func waitForKeys() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.status == .waitingForKeys else { return }
            self.sync()
        }
    }

    private func remember(_ revision: String) {
        defaults.set(revision, forKey: Self.revisionKey)
        defaults.set(localDigest(), forKey: Self.digestKey)
    }

    /// A fingerprint of this device's machines and secrets, to notice a local change. Salted
    /// with a value that never leaves the device, and never uploaded.
    private func localDigest() -> String {
        let salt = defaults.string(forKey: Self.saltKey) ?? {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Self.saltKey)
            return fresh
        }()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hasher = SHA256()
        hasher.update(data: Data(salt.utf8))
        for host in hosts.hosts {
            hasher.update(data: (try? encoder.encode(host)) ?? Data())
            hasher.update(data: Data((hosts.secret(for: host) ?? "").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The iCloud switch with what it last did. On Settings → Machines and on the connect screen
/// (a new device has no machine yet, so no Settings).
struct ICloudSyncSection: View {
    @ObservedObject private var sync = ICloudSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $sync.enabled) {
                Text("Sync machines with iCloud").font(Typography.app(17)).foregroundStyle(Palette.text)
            }
            .tint(Palette.brand)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .frame(minHeight: 52)
            .accessibilityIdentifier("icloud-sync-toggle")
            if let line = statusLine {
                divider
                HStack(spacing: 12) {
                    Text(verbatim: line)
                        .font(Typography.app(14)).foregroundStyle(sync.status == .conflict ? Palette.waiting : Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("icloud-sync-status")
                    Spacer(minLength: 8)
                    if sync.status == .conflict {
                        Button("Choose…") { sync.choosing = true }
                            .font(Typography.app(14, .semibold))
                            .accessibilityIdentifier("icloud-sync-choose")
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            divider
            Text("Machines you pair are kept in iCloud with their keys and passwords, so your other devices can connect without pairing again. The keys and passwords travel through iCloud Keychain, which is end-to-end encrypted.")
                .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.vertical, 12)
        }
        // `settingsGroup()` is private to HerdrApp.swift: the same group, drawn here.
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.hairlineQuiet, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 18)
    }

    private func count(_ machines: Int) -> String { machines == 1 ? "1 machine" : "\(machines) machines" }

    private var statusLine: String? {
        switch sync.status {
        case .off: return nil
        case .unavailable: return "Sign in to iCloud on this device to sync."
        case .upToDate: return "Up to date."
        case .uploaded(let machines): return "Uploaded \(count(machines)) to iCloud."
        case .downloaded(let machines): return "Downloaded \(count(machines)) from iCloud."
        case .waitingForKeys: return "Waiting for iCloud Keychain to deliver the keys…"
        case .conflict: return "This device and iCloud hold different machines."
        case .failed: return "Couldn't sync. It will try again."
        }
    }

}

/// The question when this device and iCloud hold different machines: upload, or download. On
/// the app's root view, so it is asked wherever the owner is when the conflict turns up, and
/// a page covering Settings cannot swallow it.
struct ICloudConflictQuestion: ViewModifier {
    @ObservedObject private var sync = ICloudSync.shared
    @ObservedObject private var hosts = SavedHostsStore.shared

    func body(content: Content) -> some View {
        content.confirmationDialog("This device and iCloud hold different machines",
                                   isPresented: $sync.choosing, titleVisibility: .visible) {
            Button("Upload: replace iCloud with this device") { sync.resolve(.upload) }
            Button("Download: replace this device with iCloud", role: .destructive) { sync.resolve(.download) }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(verbatim: question)
        }
    }

    private func count(_ machines: Int) -> String { machines == 1 ? "1 machine" : "\(machines) machines" }

    private var question: String {
        let here = "This device has \(count(hosts.hosts.count))."
        guard let cloud = sync.cloud else { return here }
        return here + " iCloud has \(count(cloud.hosts.count)), last uploaded from \(cloud.device)."
    }
}
