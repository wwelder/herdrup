import Combine
import CryptoKit
import HerdrKit
import Security
import SwiftUI
import UIKit

// iCloud sync of the saved machines. A machine paired on one device is usable on the owner's
// other devices once they have synced. iCloud's copy is ONE value in iCloud key-value storage:
// the list in the clear, and every machine's private key or password sealed (AES-GCM) with a
// key that exists only in iCloud Keychain, which is end to end encrypted. One value, written in
// one go, so the list and its secrets cannot disagree. Sealed with each secret is the SSH host
// key its device has pinned, and a device takes a secret only together with that pin, so a
// synced credential is never offered to a host nobody verified. It is off until the owner turns
// it on, per device.

/// iCloud's copy of the saved machines.
struct CloudMachines: Codable, Equatable {
    /// A new value on every upload: how a device tells whether iCloud's copy changed.
    var revision: String
    /// The revisions this copy was made on top of, oldest first (the last `ancestorLimit`).
    /// A device whose own upload is no longer iCloud's copy looks for it here: if it is
    /// there, the newer copy was built on it and can simply be taken; if not, the two
    /// uploads crossed.
    var ancestors: [String] = []
    var hosts: [SavedHost]
    /// Which sealing key `sealed` was made with (`CloudSeal.id`).
    var keyID: String
    /// What is sealed for each machine, by machine id (`CloudSeal.Entry`): its secret and the
    /// SSH host key the uploading device has pinned for it.
    var sealed: Data
    /// The device that uploaded it, for the conflict question.
    var device: String
    var updatedAt: Date

    static let ancestorLimit = 50

    /// The ancestry of a copy made on top of `base` (iCloud's copy when the upload started).
    static func ancestry(after base: CloudMachines?) -> [String] {
        guard let base else { return [] }
        return Array((base.ancestors + [base.revision]).suffix(ancestorLimit))
    }
}

/// Sealing the secrets with a 256-bit key, and opening them.
enum CloudSeal {
    /// One machine's sealed part. The host-key pin travels with the credential because a
    /// device that received only the credential would trust whatever key it met on its first
    /// connection, and hand a password to whoever answered.
    struct Entry: Codable, Equatable {
        var secret: String?
        /// The SSH host-key fingerprint the uploading device has pinned for `pinnedHost`.
        var pin: String?
        /// The machine's address (`SavedHost.host`) the pin was read for. A pin counts only
        /// while the machine still has that address.
        var pinnedHost: String?

        /// The pin, if it belongs to `host`'s current address.
        func pin(for host: SavedHost) -> String? { pinnedHost == host.host ? pin : nil }
    }

    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    /// Names a key without giving it away.
    static func id(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func seal(_ secrets: [String: Entry], with key: Data) -> Data? {
        guard let plain = try? JSONEncoder().encode(secrets) else { return nil }
        return try? AES.GCM.seal(plain, using: SymmetricKey(data: key)).combined
    }

    static func open(_ sealed: Data, with key: Data) -> [String: Entry]? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return try? JSONDecoder().decode([String: Entry].self, from: plain)
    }
}

/// Where iCloud's copy and the sealing keys live. A protocol so a Debug run can stand a folder
/// in for iCloud.
protocol CloudMachineStore {
    /// False when the device is not signed in to iCloud.
    var available: Bool { get }
    func load() -> CloudMachines?
    func save(_ machines: CloudMachines) -> Bool
    /// A sealing key by its id. Keys are only ever added: one that exists is never rewritten
    /// or removed, so nothing a device does can make a published copy unreadable.
    func key(_ id: String) -> Data?
    func saveKey(_ key: Data, id: String) -> Bool
    /// Calls `changed` on the main queue when another device changed the copy.
    func observe(_ changed: @escaping () -> Void)
}

/// The real thing: `NSUbiquitousKeyValueStore` for the copy, synchronizable Keychain items in
/// the app's access group for the sealing keys.
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

    private func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
    }

    func key(_ id: String) -> Data? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func saveKey(_ key: Data, id: String) -> Bool {
        var add = query(id)
        add[kSecValueData as String] = key
        // Not "this device only": the key has to leave the device to reach the others.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
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
    private func file(_ id: String) -> URL { folder.appendingPathComponent("key-\(id).bin") }

    var available: Bool { true }
    func load() -> CloudMachines? {
        (try? Data(contentsOf: list)).flatMap { try? JSONDecoder().decode(CloudMachines.self, from: $0) }
    }
    func save(_ machines: CloudMachines) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(machines) else { return false }
        return (try? data.write(to: list, options: .atomic)) != nil
    }
    func key(_ id: String) -> Data? { try? Data(contentsOf: file(id)) }
    func saveKey(_ key: Data, id: String) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? key.write(to: file(id), options: .atomic)) != nil
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
        /// iCloud's copy is here but iCloud Keychain has not delivered the key it is sealed with.
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
    /// Machines in the last download whose credential was not taken, because iCloud's copy
    /// had no verified host key for them.
    @Published private(set) var withheld = 0
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
    private let pins = KeychainHostKeyPolicy.shared
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
    /// machines or a pinned host key change here, and when the app comes back to the front.
    func start() {
        guard !started else { return }
        started = true
        store.observe { [weak self] in Task { @MainActor in self?.sync() } }
        watching = hosts.$hosts.dropFirst().sink { [weak self] _ in
            // The store publishes before it has written; look after it has.
            DispatchQueue.main.async { self?.sync() }
        }
        for name in [UIApplication.didBecomeActiveNotification, KeychainHostKeyPolicy.pinned] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
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
        // A device restored from a backup has its machines and its sync state but not the
        // device-only secrets. Take them back from iCloud before anything is compared, or the
        // state without them would be recorded as agreed.
        if let cloud, !restoreMissingSecrets(from: cloud) {
            status = .waitingForKeys
            waitForKeys()
            return
        }
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
            // This device's own upload is what it last agreed on, and iCloud's copy was not
            // built on it, however many revisions later: the uploads crossed.
            overwritten: mine != nil && mine == synced && !(cloud?.ancestors.contains(mine ?? "") ?? true))
        switch action {
        case .none:
            // Keep saying what the last sync did until something else happens.
            switch status {
            case .uploaded, .downloaded: break
            default: status = .upToDate
            }
        case .offerUpload: status = .nothingInCloud
        case .upload: upload(onTopOf: cloud)
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
        // The owner has seen iCloud's copy and replaces it on purpose. The upload records the
        // copy the question was about as an ancestor, so the device that uploaded that one
        // follows instead of being asked too.
        case .upload: upload(onTopOf: cloud)
        case .download:
            guard let cloud = store.load() else { status = .failed; return }
            defaults.set(cloud.revision + "|" + localDigest(), forKey: Self.pendingKey)
            download(cloud)
        }
    }

    /// What is sealed in `cloud`, or nil while iCloud Keychain has not delivered its key.
    private func open(_ cloud: CloudMachines) -> [String: CloudSeal.Entry]? {
        store.key(cloud.keyID).flatMap { CloudSeal.open(cloud.sealed, with: $0) }
    }

    /// The host key this device has pinned for the machine's address.
    private func pin(for host: SavedHost) -> String? {
        HostEndpoint.parse(host.host).flatMap { pins.fingerprint(host: $0.host, port: $0.port) }
    }

    /// The machine's secret from iCloud's copy, once the host key that came with it is pinned
    /// (a pin this device already has stays). Nil when the copy has no verified host key for
    /// the machine's address: a credential is never taken without one, or this device's first
    /// connection would trust whatever key it met and hand the credential to it.
    private func accept(_ entry: CloudSeal.Entry?, for host: SavedHost) -> String? {
        guard let entry, let secret = entry.secret, let pin = entry.pin(for: host),
              let endpoint = HostEndpoint.parse(host.host),
              pins.pinIfAbsent(host: endpoint.host, port: endpoint.port, fingerprint: pin) else { return nil }
        return secret
    }

    /// False while this device lacks a secret iCloud's copy may hold and the copy cannot be
    /// opened yet.
    private func restoreMissingSecrets(from cloud: CloudMachines) -> Bool {
        // Only for the same machine with the same kind of credential; a machine iCloud
        // describes differently is settled by the upload or download that follows.
        let missing = hosts.hosts.filter { host in
            hosts.secret(for: host) == nil && cloud.hosts.first(where: { $0.id == host.id }).map { $0.auth == host.auth && $0.host == host.host } == true
        }
        guard !missing.isEmpty else { return true }
        guard let entries = open(cloud) else { return false }
        for host in missing {
            if let secret = accept(entries[host.id.uuidString], for: host) { hosts.restoreSecret(secret, for: host) }
        }
        return true
    }

    /// The owner's tap on "Upload" while iCloud shows no copy.
    func uploadFirst() {
        guard enabled, status == .nothingInCloud else { return }
        upload(onTopOf: nil)
    }

    /// - Parameter before: iCloud's copy as this device last read it, the one the decision to
    ///   upload was made against. It is not read again here: a copy another device publishes
    ///   in between was never seen, and must not be recorded as an ancestor, or that device
    ///   would take this upload as built on its own and lose its change without a question.
    private func upload(onTopOf before: CloudMachines?) {
        retry?.cancel()
        // Seal with the key iCloud's copy already uses when this device has it, because the
        // other devices then have it too. Otherwise with a new one, which they wait for.
        var key = before.flatMap { store.key($0.keyID) }
        let known = key.flatMap { key in before.flatMap { CloudSeal.open($0.sealed, with: key) } }
        if key == nil {
            let fresh = CloudSeal.newKey()
            guard store.saveKey(fresh, id: CloudSeal.id(fresh)) else { status = .failed; return }
            key = fresh
        }
        guard let key else { status = .failed; return }
        var entries: [String: CloudSeal.Entry] = [:]
        for host in hosts.hosts {
            let id = host.id.uuidString
            let old = known?[id]
            // What this device does not hold, the secret or the pin, stays as iCloud has it:
            // uploading must never take either away.
            let secret = hosts.secret(for: host) ?? old?.secret
            let pin = pin(for: host) ?? old?.pin(for: host)
            if secret != nil || pin != nil {
                entries[id] = CloudSeal.Entry(secret: secret, pin: pin, pinnedHost: pin == nil ? nil : host.host)
            }
        }
        guard let sealed = CloudSeal.seal(entries, with: key) else { status = .failed; return }
        let copy = CloudMachines(revision: UUID().uuidString, ancestors: CloudMachines.ancestry(after: before),
                                 hosts: hosts.hosts, keyID: CloudSeal.id(key), sealed: sealed,
                                 device: UIDevice.current.name, updatedAt: Date())
        // One value, one write: either iCloud holds the new list with its secrets, or the old.
        guard store.save(copy) else { status = .failed; return }
        defaults.removeObject(forKey: Self.pendingKey)
        cloud = copy
        withheld = 0
        remember(copy.revision, uploadedHere: true)
        status = .uploaded(copy.hosts.count)
    }

    private func download(_ cloud: CloudMachines) {
        // The copy arrives faster than iCloud Keychain delivers the key it is sealed with.
        guard let entries = open(cloud) else {
            status = .waitingForKeys
            waitForKeys()
            return
        }
        var skipped = 0
        let machines: [(host: SavedHost, secret: String?)] = cloud.hosts.map { host in
            let entry = entries[host.id.uuidString]
            let secret = accept(entry, for: host)
            if secret == nil, entry?.secret != nil { skipped += 1 }
            return (host, secret)
        }
        retry?.cancel()
        applying = true
        let replaced = hosts.replaceAll(machines)
        applying = false
        guard replaced else { status = .failed; return }
        defaults.removeObject(forKey: Self.pendingKey)
        withheld = skipped
        remember(cloud.revision, uploadedHere: false)
        status = .downloaded(cloud.hosts.count)
    }

    /// iCloud Keychain announces nothing when the key arrives, so look again every few seconds.
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
            // A host key pinned by the first connection is a change worth uploading: the
            // other devices only take the credential together with it.
            hasher.update(data: Data((pin(for: host) ?? "").utf8))
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
            Text("Machines you pair are kept in iCloud with their keys and passwords, so your other devices can connect without pairing again. The keys and passwords are encrypted with a key only your devices have, kept in iCloud Keychain.")
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
        case .downloaded(let machines):
            guard sync.withheld > 0 else { return "Downloaded \(count(machines)) from iCloud." }
            // ponytail: the note is not kept across launches; persist `withheld` if it is missed.
            return "Downloaded \(count(machines)) from iCloud. \(sync.withheld == 1 ? "One has" : "\(sync.withheld) have") no verified host key yet, so no key or password was taken for \(sync.withheld == 1 ? "it" : "them"). Connect once on the device \(sync.withheld == 1 ? "it was" : "they were") added on."
        case .nothingInCloud:
            return "iCloud shows no machines yet. If another device has already uploaded, wait a moment; otherwise upload this device's \(count(hosts.hosts.count))."
        case .waitingForKeys: return "Waiting for iCloud Keychain to deliver the encryption key. iCloud Keychain has to be on."
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
