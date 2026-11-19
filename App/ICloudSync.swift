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
    /// The revision the uploading device had last agreed on: tells a device whose own upload
    /// was replaced whether the replacement had seen it.
    var parent: String?
    var hosts: [SavedHost]
    /// Per machine id, the version of its secret that goes with this revision. A machine whose
    /// device held no secret has no entry.
    var secretVersions: [String: String]
    /// The device that uploaded it, for the conflict question.
    var device: String
    var updatedAt: Date

    /// How a store names one version of one machine's secret.
    static func secretKey(_ id: String, _ version: String) -> String { id + "|" + version }
    var secretKeys: Set<String> { Set(secretVersions.map { Self.secretKey($0.key, $0.value) }) }
}

/// Where iCloud's copy lives. A protocol so a Debug run can stand a folder in for iCloud.
protocol CloudMachineStore {
    /// False when the device is not signed in to iCloud.
    var available: Bool { get }
    func load() -> CloudMachines?
    func save(_ machines: CloudMachines) -> Bool
    /// One version of a machine's secret. A version is never rewritten: an upload adds the new
    /// ones, publishes the list, and only then drops what the list no longer names, so the
    /// published list always names secrets that exist.
    func secret(for id: String, version: String) -> String?
    func saveSecret(_ secret: String, for id: String, version: String) -> Bool
    /// `keep` holds `CloudMachines.secretKey` values.
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

    /// The Keychain account is `CloudMachines.secretKey`: one item per version of a secret.
    private func query(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func secret(for id: String, version: String) -> String? {
        var query = query(CloudMachines.secretKey(id, version))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveSecret(_ secret: String, for id: String, version: String) -> Bool {
        var add = query(CloudMachines.secretKey(id, version))
        add[kSecValueData as String] = Data(secret.utf8)
        // Not "this device only": the item has to leave the device to sync.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    func deleteSecrets(except keep: Set<String>) {
        var all = query(nil)
        all[kSecReturnAttributes as String] = true
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(all as CFDictionary, &items) == errSecSuccess,
              let found = items as? [[String: Any]] else { return }
        for item in found {
            guard let account = item[kSecAttrAccount as String] as? String, !keep.contains(account) else { continue }
            SecItemDelete(query(account) as CFDictionary)
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
    private func file(_ key: String) -> URL { folder.appendingPathComponent("secret-\(key).txt") }

    var available: Bool { true }
    func load() -> CloudMachines? {
        (try? Data(contentsOf: list)).flatMap { try? JSONDecoder().decode(CloudMachines.self, from: $0) }
    }
    func save(_ machines: CloudMachines) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(machines) else { return false }
        return (try? data.write(to: list, options: .atomic)) != nil
    }
    func secret(for id: String, version: String) -> String? {
        try? String(contentsOf: file(CloudMachines.secretKey(id, version)), encoding: .utf8)
    }
    func saveSecret(_ secret: String, for id: String, version: String) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? secret.write(to: file(CloudMachines.secretKey(id, version)), atomically: true, encoding: .utf8)) != nil
    }
    func deleteSecrets(except keep: Set<String>) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("secret-") && !keep.contains(String(name.dropFirst(7).dropLast(4))) {
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
        /// iCloud shows no copy and this device has machines: the upload waits for the owner.
        case nothingInCloud
        /// iCloud's list is here but iCloud Keychain has not delivered every secret yet.
        case waitingForKeys
        case conflict, failed
    }

    enum Direction { case upload, download }

    private static let enabledKey = "icloud.sync.machines"
    private static let revisionKey = "icloud.sync.revision"
    private static let digestKey = "icloud.sync.digest"
    /// The revision this device last uploaded itself, if that is what it last agreed on.
    private static let uploadedKey = "icloud.sync.uploaded"
    /// "revision|local digest" of a download the owner chose that still waits for its keys.
    private static let pendingKey = "icloud.sync.pendingDownload"
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
                defaults.removeObject(forKey: Self.pendingKey)
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
        // While the device is locked the Keychain reads nothing, which would look like every
        // secret had gone.
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        guard store.available else { status = .unavailable; return }
        let cloud = store.load()
        self.cloud = cloud
        // The owner chose Download and the keys had not arrived: carry on with that choice
        // rather than asking again, unless either side has changed since.
        if let pending = defaults.string(forKey: Self.pendingKey) {
            if let cloud, pending == cloud.revision + "|" + localDigest() {
                download(cloud)
                return
            }
            defaults.removeObject(forKey: Self.pendingKey)
        }
        let synced = defaults.string(forKey: Self.revisionKey)
        let mine = defaults.string(forKey: Self.uploadedKey)
        let action = CloudSyncPlan.action(
            hasCloud: cloud != nil, everSynced: synced != nil, localEmpty: hosts.hosts.isEmpty,
            localChanged: localDigest() != defaults.string(forKey: Self.digestKey),
            cloudChanged: cloud?.revision != synced,
            overwritten: mine != nil && mine == synced && cloud?.parent != synced)
        switch action {
        case .none:
            // Keep saying what the last sync did until something else happens.
            switch status {
            case .uploaded, .downloaded: break
            default: status = .upToDate
            }
        case .offerUpload: status = .nothingInCloud
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
        // The owner has seen iCloud's copy and replaces it on purpose: the new copy counts as
        // made from it, so the device that uploaded that one follows instead of being asked too.
        case .upload: upload(replacing: store.load()?.revision)
        case .download:
            guard let cloud = store.load() else { status = .failed; return }
            defaults.set(cloud.revision + "|" + localDigest(), forKey: Self.pendingKey)
            download(cloud)
        }
    }

    /// The owner's tap on "Upload" while iCloud shows no copy.
    func uploadFirst() {
        guard enabled, status == .nothingInCloud else { return }
        upload()
    }

    /// - Parameter replacing: the revision in iCloud this upload knowingly replaces, when it
    ///   is not the one this device last agreed on.
    private func upload(replacing: String? = nil) {
        retry?.cancel()
        let before = store.load()
        var versions: [String: String] = [:]
        for host in hosts.hosts {
            let id = host.id.uuidString
            let published = before?.secretVersions[id]
            guard let secret = hosts.secret(for: host) else {
                // This device holds no secret for the machine (a restored phone, say). Leave
                // whatever iCloud has for it: uploading must never take a secret away.
                if let published { versions[id] = published }
                continue
            }
            // An unchanged secret keeps its version, so a rename does not make every other
            // device wait for iCloud Keychain again.
            if let published, store.secret(for: id, version: published) == secret {
                versions[id] = published
                continue
            }
            let version = UUID().uuidString
            guard store.saveSecret(secret, for: id, version: version) else { status = .failed; return }
            versions[id] = version
        }
        let copy = CloudMachines(revision: UUID().uuidString, parent: replacing ?? defaults.string(forKey: Self.revisionKey),
                                 hosts: hosts.hosts, secretVersions: versions,
                                 device: UIDevice.current.name, updatedAt: Date())
        // If this fails the list in iCloud still names the old versions, which are untouched.
        guard store.save(copy) else { status = .failed; return }
        store.deleteSecrets(except: copy.secretKeys)
        defaults.removeObject(forKey: Self.pendingKey)
        cloud = copy
        remember(copy.revision, uploadedHere: true)
        status = .uploaded(copy.hosts.count)
    }

    private func download(_ cloud: CloudMachines) {
        var machines: [(host: SavedHost, secret: String?)] = []
        for host in cloud.hosts {
            let id = host.id.uuidString
            guard let version = cloud.secretVersions[id] else { machines.append((host, nil)); continue }
            // The list syncs faster than iCloud Keychain: wait for every secret of this revision.
            guard let secret = store.secret(for: id, version: version) else {
                status = .waitingForKeys
                waitForKeys()
                return
            }
            machines.append((host, secret))
        }
        retry?.cancel()
        applying = true
        let replaced = hosts.replaceAll(machines)
        applying = false
        guard replaced else { status = .failed; return }
        defaults.removeObject(forKey: Self.pendingKey)
        remember(cloud.revision, uploadedHere: false)
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

    private func remember(_ revision: String, uploadedHere: Bool) {
        defaults.set(revision, forKey: Self.revisionKey)
        defaults.set(localDigest(), forKey: Self.digestKey)
        defaults.set(uploadedHere ? revision : nil, forKey: Self.uploadedKey)
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
    @ObservedObject private var hosts = SavedHostsStore.shared

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
                    if sync.status == .nothingInCloud {
                        Button("Upload") { sync.uploadFirst() }
                            .font(Typography.app(14, .semibold))
                            .accessibilityIdentifier("icloud-sync-upload")
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
        case .nothingInCloud:
            return "iCloud shows no machines yet. If another device has already uploaded, wait a moment; otherwise upload this device's \(count(hosts.hosts.count))."
        case .waitingForKeys: return "Waiting for iCloud Keychain to deliver the keys. iCloud Keychain has to be on."
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
