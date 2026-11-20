import Combine
import CryptoKit
import HerdrKit
import Security
import SwiftUI
import UIKit

// iCloud sync of the saved machines. A machine paired on one device is usable on the owner's
// other devices once they have synced. iCloud holds ONE value in iCloud key-value storage: the
// whole copy (the machines, their private keys or passwords, the SSH host key verified for
// each, and the copy's history) sealed with AES-GCM under a key that exists only in iCloud
// Keychain, which is end to end encrypted. Nothing in it can be read or changed without that
// key, and it is written in one go, so its parts cannot disagree. A device takes a credential
// from it only together with the host key it came with. Off until the owner turns it on, per
// device.

/// The saved machines as one device uploaded them: iCloud's copy, sealed whole (`CloudSeal`).
struct CloudMachines: Codable, Equatable {
    /// A machine with the credential and the SSH host key that belong to its address. The
    /// three stay together: a secret is only ever taken with the host key it came with.
    struct Machine: Codable, Equatable {
        var host: SavedHost
        var secret: String?
        /// The host-key fingerprint pinned for `host.host` on the device the secret came from.
        var pin: String?
    }

    /// A new value on every upload: how a device tells whether iCloud's copy changed.
    var revision: String
    /// The revisions this copy was made on top of, oldest first (the last `ancestorLimit`).
    /// A device takes a changed copy without asking only when the copy it last agreed on is
    /// in here. Otherwise the copy was not built on what the device had (two uploads crossed,
    /// or an older copy was put back) and the owner is asked.
    var ancestors: [String] = []
    var machines: [Machine]
    /// The device that uploaded it, for the conflict question.
    var device: String
    var updatedAt: Date

    static let ancestorLimit = 50

    /// The ancestry of a copy made on top of `base` (the copy the upload was decided against).
    static func ancestry(after base: CloudMachines?) -> [String] {
        guard let base else { return [] }
        return Array((base.ancestors + [base.revision]).suffix(ancestorLimit))
    }
}

/// What iCloud key-value storage holds: the sealed copy and the name of its key. Everything a
/// device acts on is inside the seal.
struct CloudEnvelope: Codable, Equatable {
    /// Which sealing key `sealed` was made with (`CloudSeal.id`).
    var keyID: String
    var sealed: Data
}

/// Sealing a copy with a 256-bit key (AES-GCM: encrypted, and any change to it is detected),
/// and opening it.
enum CloudSeal {
    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    /// Names a key without giving it away.
    static func id(_ key: Data) -> String {
        SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func seal(_ copy: CloudMachines, with key: Data) -> CloudEnvelope? {
        guard let plain = try? JSONEncoder().encode(copy),
              let sealed = try? AES.GCM.seal(plain, using: SymmetricKey(data: key)).combined else { return nil }
        return CloudEnvelope(keyID: id(key), sealed: sealed)
    }

    /// Nil unless `envelope` is exactly what a holder of `key` sealed.
    static func open(_ envelope: CloudEnvelope, with key: Data) -> CloudMachines? {
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return try? JSONDecoder().decode(CloudMachines.self, from: plain)
    }
}

/// Where iCloud's copy and the sealing keys live. A protocol so a Debug run can stand a folder
/// in for iCloud.
protocol CloudMachineStore {
    /// False when the device is not signed in to iCloud.
    var available: Bool { get }
    func load() -> CloudEnvelope?
    func save(_ envelope: CloudEnvelope) -> Bool
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

    func load() -> CloudEnvelope? {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        return store.data(forKey: key).flatMap { try? JSONDecoder().decode(CloudEnvelope.self, from: $0) }
    }

    func save(_ envelope: CloudEnvelope) -> Bool {
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
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

    private var copy: URL { folder.appendingPathComponent("machines.json") }
    private func file(_ id: String) -> URL { folder.appendingPathComponent("key-\(id).bin") }

    var available: Bool { true }
    func load() -> CloudEnvelope? {
        (try? Data(contentsOf: copy)).flatMap { try? JSONDecoder().decode(CloudEnvelope.self, from: $0) }
    }
    func save(_ envelope: CloudEnvelope) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        return (try? data.write(to: copy, options: .atomic)) != nil
    }
    func key(_ id: String) -> Data? { try? Data(contentsOf: file(id)) }
    func saveKey(_ key: Data, id: String) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? key.write(to: file(id), options: .atomic)) != nil
    }
    func observe(_ changed: @escaping () -> Void) {
        // ponytail: polls the folder every 2 s; a file-system watcher if a test ever needs it faster.
        var seen = load()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let now = load()
            if now != seen { seen = now; changed() }
        }
    }
}
#endif

/// Keeps this device's machines and iCloud's copy the same, and asks when it cannot tell which
/// side should win.
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
    /// The revision of the copy this device last agreed on.
    private static let revisionKey = "icloud.sync.revision"
    /// This device's machines as they were when it agreed (`Baseline`).
    private static let baselineKey = "icloud.sync.baseline"
    private static let saltKey = "icloud.sync.salt"

    @Published private(set) var status: Status = .off
    /// The conflict question is on screen.
    @Published var choosing = false
    /// iCloud's copy as last read and opened, for the conflict question.
    @Published private(set) var cloud: CloudMachines?
    /// Machines in the last download that have no key or password on this device, because the
    /// one in iCloud's copy came without a host key this device could take it with.
    @Published private(set) var withheld = 0
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
    private let pins = KeychainHostKeyPolicy.shared
    private let defaults = UserDefaults.standard
    private var watching: AnyCancellable?
    private var retry: Task<Void, Never>?
    /// The key `cloud` opened with. An upload on top of that copy is sealed with it, because
    /// the other devices have it already.
    private var sealingKey: Data?
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
        retry?.cancel()
        var cloud: CloudMachines?
        var key: Data?
        if let envelope = store.load() {
            // The copy arrives faster than iCloud Keychain delivers the key it is sealed with.
            guard let delivered = store.key(envelope.keyID) else {
                status = .waitingForKeys
                waitForKeys()
                return
            }
            // A copy that does not open with its own key was damaged or tampered with. Nothing
            // in it is used: it counts as no copy, which a device replaces only when its owner
            // taps Upload.
            if let opened = CloudSeal.open(envelope, with: delivered) {
                cloud = opened
                key = delivered
            }
        }
        self.cloud = cloud
        sealingKey = key
        let synced = defaults.string(forKey: Self.revisionKey)
        // Only from the copy this device had agreed on. A changed copy is for the plan to
        // settle, and a secret this device lacks does not count as a local change (`changed`),
        // so a restored device simply takes the newer copy.
        if let cloud, cloud.revision == synced { restoreMissingSecrets(from: cloud) }
        let local = snapshot()
        let action = CloudSyncPlan.action(
            hasCloud: cloud != nil, everSynced: synced != nil, localEmpty: local.isEmpty,
            localChanged: changed(local),
            cloudChanged: cloud?.revision != synced,
            // iCloud's copy was not built on the one this device last agreed on.
            overwritten: synced.map { cloud?.ancestors.contains($0) == false } ?? false)
        switch action {
        case .none:
            // Keep saying what the last sync did until something else happens.
            switch status {
            case .uploaded, .downloaded: break
            default: status = .upToDate
            }
        case .offerUpload: status = .nothingInCloud
        case .upload: upload(local, onTopOf: cloud)
        case .download: if let cloud { download(cloud) }
        case .conflict:
            // Ask once when the conflict appears; after "Not now" the row offers the question again.
            if status != .conflict { choosing = true }
            status = .conflict
        }
    }

    /// The owner's answer to the conflict question. Both answers are about the copy the
    /// question described, not one read again since.
    func resolve(_ direction: Direction) {
        choosing = false
        guard let cloud else { sync(); return }
        switch direction {
        // The upload records that copy as an ancestor, so the device that uploaded it follows
        // instead of being asked too.
        case .upload: upload(snapshot(), onTopOf: cloud)
        case .download: download(cloud)
        }
    }

    /// The host key this device has pinned for the machine's address.
    private func pin(for host: SavedHost) -> String? {
        HostEndpoint.parse(host.host).flatMap { pins.fingerprint(host: $0.host, port: $0.port) }
    }

    /// This device's machines with the secret and the pinned host key it holds for each, in
    /// one reading: what is uploaded and what is remembered as agreed have to be the same one.
    private func snapshot() -> [CloudMachines.Machine] {
        hosts.hosts.map { .init(host: $0.portable, secret: hosts.secret(for: $0), pin: pin(for: $0)) }
    }

    /// What this device may take of a machine in iCloud's copy: its secret only with the host
    /// key it came with in place for the machine's address. That key is pinned here if the
    /// address has none, and never replaces one this device verified. With no host key in the
    /// copy, or a different one pinned here, the secret is not taken: the next connection
    /// could hand it to a host nobody verified. `pin` is what is in place either way.
    private func accepted(_ theirs: CloudMachines.Machine) -> (secret: String?, pin: String?) {
        guard let endpoint = HostEndpoint.parse(theirs.host.host) else { return (nil, nil) }
        guard let secret = theirs.secret, let verified = theirs.pin else {
            return (nil, pins.fingerprint(host: endpoint.host, port: endpoint.port))
        }
        let pin = pins.adopt(host: endpoint.host, port: endpoint.port, fingerprint: verified)
        return (pin == verified ? secret : nil, pin)
    }

    /// A device restored from a backup has its machines and its sync state but not its
    /// device-only secrets. It takes them back from the copy it had agreed on, under the same
    /// rule as a download.
    private func restoreMissingSecrets(from cloud: CloudMachines) {
        for host in hosts.hosts where hosts.secret(for: host) == nil {
            guard let theirs = cloud.machines.first(where: { $0.host.id == host.id }),
                  theirs.host.host == host.host, theirs.host.auth == host.auth,
                  let secret = accepted(theirs).secret else { continue }
            hosts.restoreSecret(secret, for: host)
        }
    }

    /// What this device uploads: its own machines. For one it holds no secret for, the secret
    /// and host key iCloud's copy has for the same address go up again together, as they came:
    /// an upload must not take a credential away, nor pair a secret with a host key from
    /// somewhere else.
    private func merged(_ local: [CloudMachines.Machine], onto before: CloudMachines?) -> [CloudMachines.Machine] {
        local.map { mine in
            guard mine.secret == nil,
                  let theirs = before?.machines.first(where: { $0.host.id == mine.host.id }),
                  theirs.host.host == mine.host.host, theirs.host.auth == mine.host.auth else { return mine }
            return .init(host: mine.host, secret: theirs.secret, pin: theirs.pin)
        }
    }

    /// The owner's tap on "Upload" while iCloud shows no copy.
    func uploadFirst() {
        guard enabled, status == .nothingInCloud else { return }
        upload(snapshot(), onTopOf: nil)
    }

    /// - Parameters:
    ///   - local: this device's machines as read for the decision to upload.
    ///   - before: iCloud's copy that decision was made against. It is not read again here: a
    ///     copy another device publishes in between was never seen, and must not be recorded
    ///     as an ancestor, or that device would take this upload as built on its own and lose
    ///     its change without a question.
    private func upload(_ local: [CloudMachines.Machine], onTopOf before: CloudMachines?) {
        retry?.cancel()
        // Sealed with the key the copy underneath opened with, which the other devices have
        // already. Without a copy, with a new key, which they wait for.
        var key = before == nil ? nil : sealingKey
        if key == nil {
            let fresh = CloudSeal.newKey()
            guard store.saveKey(fresh, id: CloudSeal.id(fresh)) else { status = .failed; return }
            key = fresh
        }
        let copy = CloudMachines(revision: UUID().uuidString, ancestors: CloudMachines.ancestry(after: before),
                                 machines: merged(local, onto: before), device: UIDevice.current.name, updatedAt: Date())
        // One value, one write: iCloud holds either the new copy or the old one.
        guard let key, let envelope = CloudSeal.seal(copy, with: key), store.save(envelope) else { status = .failed; return }
        cloud = copy
        sealingKey = key
        withheld = 0
        // The reading that was uploaded, not a new one: a host key pinned by a connection in
        // the meantime then shows as a change, and goes up next.
        remember(copy.revision, local)
        status = .uploaded(copy.machines.count)
    }

    private func download(_ cloud: CloudMachines) {
        let local = snapshot()
        var machines: [(host: SavedHost, secret: String?)] = []
        var installed: [CloudMachines.Machine] = []
        var skipped = 0
        for theirs in cloud.machines {
            let taken = accepted(theirs)
            var secret = taken.secret
            if secret == nil,
               let mine = local.first(where: { $0.host.id == theirs.host.id }),
               mine.host.host == theirs.host.host, mine.host.auth == theirs.host.auth,
               theirs.pin == nil || theirs.pin == taken.pin {
                // Not taken from iCloud, but this device holds a credential of its own for the
                // same address and the copy names no other host key for it: that one stays.
                secret = mine.secret
            }
            // Any other credential this device had for the machine is out of reach once the
            // list is replaced (`replaceAll`): it may be for another address, or for a host
            // key this device does not trust.
            if secret == nil, theirs.secret != nil { skipped += 1 }
            machines.append((theirs.host, secret))
            installed.append(.init(host: theirs.host.portable, secret: secret, pin: taken.pin))
        }
        retry?.cancel()
        applying = true
        let replaced = hosts.replaceAll(machines)
        applying = false
        guard replaced else { status = .failed; return }
        withheld = skipped
        // What was installed, not a new reading, for the same reason as after an upload.
        remember(cloud.revision, installed)
        status = .downloaded(cloud.machines.count)
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

    /// What this device's machines were when it last agreed with iCloud, as salted hashes:
    /// enough to notice a change, nothing a reader could use.
    private struct Baseline: Codable {
        /// The machines' ids, in their order.
        var ids: [String] = []
        /// By id: the machine's fields, its secret, its pinned host key. A machine without a
        /// secret or host key has no entry there.
        var hosts: [String: String] = [:]
        var secrets: [String: String] = [:]
        var pins: [String: String] = [:]
    }

    private func baseline(of machines: [CloudMachines.Machine]) -> Baseline {
        let salt = defaults.string(forKey: Self.saltKey) ?? {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Self.saltKey)
            return fresh
        }()
        // Salted with a value that never leaves the device.
        func hash(_ data: Data) -> String {
            SHA256.hash(data: Data(salt.utf8) + data).map { String(format: "%02x", $0) }.joined()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var result = Baseline()
        for machine in machines {
            let id = machine.host.id.uuidString
            result.ids.append(id)
            result.hosts[id] = hash((try? encoder.encode(machine.host)) ?? Data())
            if let secret = machine.secret { result.secrets[id] = hash(Data(secret.utf8)) }
            if let pin = machine.pin { result.pins[id] = hash(Data(pin.utf8)) }
        }
        return result
    }

    private func remember(_ revision: String, _ machines: [CloudMachines.Machine]) {
        defaults.set(revision, forKey: Self.revisionKey)
        defaults.set(try? JSONEncoder().encode(baseline(of: machines)), forKey: Self.baselineKey)
    }

    /// Whether this device's machines are no longer what it last agreed on. A secret or host
    /// key the device does not hold is not a change by itself: a restore from a backup brings
    /// the machines back without them, and that is not an edit. One it holds that differs
    /// from the agreed one, or that the agreed state did not have, is.
    private func changed(_ local: [CloudMachines.Machine]) -> Bool {
        guard let agreed = defaults.data(forKey: Self.baselineKey).flatMap({ try? JSONDecoder().decode(Baseline.self, from: $0) }) else { return true }
        let now = baseline(of: local)
        guard now.ids == agreed.ids, now.hosts == agreed.hosts else { return true }
        return now.secrets.contains { agreed.secrets[$0.key] != $0.value } || now.pins.contains { agreed.pins[$0.key] != $0.value }
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
            Text("Machines you pair are kept in iCloud with their keys and passwords, so your other devices can connect without pairing again. All of it is encrypted with a key only your devices have, kept in iCloud Keychain.")
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
            let one = sync.withheld == 1
            return "Downloaded \(count(machines)) from iCloud. For \(one ? "one" : "\(sync.withheld)") of them no key or password was taken: \(one ? "its host key is" : "their host keys are") not verified yet, or not the one this device trusts. Connect once on the device \(one ? "it was" : "they were") added on, or pair \(one ? "it" : "them") again here."
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
        return here + " iCloud has \(count(cloud.machines.count)), last uploaded from \(cloud.device)."
    }
}
