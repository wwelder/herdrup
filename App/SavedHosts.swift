import Foundation
import HerdrKit
import Security

/// Which credential a saved host authenticates with.
enum SavedAuthKind: String, Codable {
    case key
    case password
}

/// The secret half of a saved host, routed to the matching Keychain store by the
/// store's add/update. Keeps one code path for both auth kinds.
enum HostSecret {
    case key(String)
    case password(String)
}

/// A saved connection target for one-tap reconnect. Holds ONLY the non-secret
/// fields (host — which may include ":port" — and username). The private key or
/// password is NEVER stored here; it lives in the Keychain (`KeychainCredentialStore`),
/// keyed by `id`. So the on-disk (UserDefaults) list can be read without exposing a secret.
struct SavedHost: Codable, Identifiable, Hashable {
    let id: UUID
    var host: String
    var username: String
    /// Optional friendly label ("My Mac"). Legacy saved hosts predate this field, so it
    /// is OPTIONAL — old JSON without the key decodes to `nil` (no migration needed).
    var nickname: String?
    /// Which credential this host uses. OPTIONAL for migration exactly like `nickname`:
    /// JSON written before password auth has no `authKind`, decodes to nil, and resolves
    /// to `.key` via `auth` — so every legacy host stays key-based.
    var authKind: SavedAuthKind?
    /// The Keychain account this machine's secret is under on THIS device. OPTIONAL for
    /// migration like the fields above: nil means the machine's `id`, where every secret
    /// was before the field existed. Only a download from iCloud sets it (`replaceAll`).
    var secretAccount: String?

    /// The resolved auth kind for callers — a legacy (nil) host is key-based.
    var auth: SavedAuthKind { authKind ?? .key }

    /// The Keychain account to look this machine's secret up under.
    var account: String { secretAccount ?? id.uuidString }

    /// The machine as it travels to other devices: without this device's Keychain account.
    var portable: SavedHost {
        var copy = self
        copy.secretAccount = nil
        return copy
    }

    /// The primary display label: the nickname if set, else the host itself.
    var label: String {
        if let n = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return host
    }
}

/// Persists saved hosts: the host+username list in UserDefaults, each host's
/// private key in the Keychain (device-local, unlock-gated). The two are kept in
/// lockstep — `save` only records a host once its key persists, and `delete`
/// removes both — so a listed host is always one-tap reconnectable.
final class SavedHostsStore: ObservableObject {
    static let shared = SavedHostsStore()

    private let defaultsKey = ShareStorage.hostsKey
    /// Keychain accounts a download from iCloud stopped using, each with when: see
    /// `replaceAll` and `removeRetiredAccounts`. Kept beside the list, in the same defaults.
    private let retiredKey = "dev.herdr.savedHosts.retiredAccounts.v1"
    private let keychain = KeychainCredentialStore(service: "dev.herdr.credentials")
    /// A host's password lives in its own Keychain service so a host's key and
    /// password never collide on the same account id. Same device-only discipline.
    private let passwordKeychain = KeychainCredentialStore(service: "dev.herdr.credentials.password")

    @Published private(set) var hosts: [SavedHost]

    init() {
        if let data = ShareStorage.defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = decoded
        } else {
            hosts = []
        }
        // Only the app does this. An extension that starts in the middle of a download would
        // take the accounts being staged for unused.
        if Bundle.main.bundleURL.pathExtension != "appex" { removeRetiredAccounts() }
        #if DEBUG
        seedHostFromEnvironment()
        #endif
    }

    /// Reads the list again. For the Share extension, whose process can outlive a change the
    /// app made to the machines or to where their secrets are kept.
    func reload() {
        guard let data = ShareStorage.defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedHost].self, from: data), decoded != hosts else { return }
        hosts = decoded
    }

    #if DEBUG
    /// For a live check in the simulator: `HERDR_DEBUG_SEED_HOST="label|user|host|/path/to/key"`
    /// saves that machine once, so a simulator can reach a real herdr without a private key
    /// being typed into the host editor. A simulator reads the Mac's files, so the path is a
    /// Mac path to an ed25519 private key.
    private func seedHostFromEnvironment() {
        guard let spec = ProcessInfo.processInfo.environment["HERDR_DEBUG_SEED_HOST"] else { return }
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return }
        // `HERDR_DEBUG_SEED_PIN=<fingerprint>` also pins that host key: before the machine is
        // saved, as pairing does, or for a machine saved earlier, as its first connection
        // would. For the iCloud sync test, whose machines are never dialled.
        if let pin = ProcessInfo.processInfo.environment["HERDR_DEBUG_SEED_PIN"], let endpoint = HostEndpoint.parse(parts[2]) {
            KeychainHostKeyPolicy.shared.pin(host: endpoint.host, port: endpoint.port, fingerprint: pin)
        }
        guard !hosts.contains(where: { $0.host == parts[2] && $0.username == parts[1] }),
              let key = try? String(contentsOfFile: parts[3], encoding: .utf8) else { return }
        add(nickname: parts[0], host: parts[2], username: parts[1], secret: .key(key))
    }
    #endif

    /// Adds a NEW saved host (its own id) and stores its secret (key or password) in
    /// the Keychain. Returns false — WITHOUT recording the host — if a required field
    /// is missing or the secret could not be persisted, so the UI never offers a
    /// one-tap host it cannot open.
    @discardableResult
    func add(nickname: String, host: String, username: String, secret: HostSecret) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !u.isEmpty else { return false }
        let id = UUID()
        // Persist the secret FIRST; only record the host if it actually stuck.
        let kind: SavedAuthKind
        switch secret {
        case .key(let pem):
            let key = pem.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, keychain.save(account: id.uuidString, secret: key) else { return false }
            kind = .key
        case .password(let password):
            // A password is NOT trimmed — leading/trailing spaces can be significant.
            guard !password.isEmpty,
                  passwordKeychain.save(account: id.uuidString, secret: password) else { return false }
            kind = .password
        }
        hosts.insert(
            SavedHost(id: id, host: h, username: u, nickname: n.isEmpty ? nil : n, authKind: kind),
            at: 0)
        persist()
        return true
    }

    /// Updates an existing saved host IN PLACE (by id): host / username / nickname, and
    /// the secret only when `secret` is non-nil (nil = keep the current one, so an edit
    /// never forces re-entering it). Switching auth kind drops the now-stale other
    /// secret. Returns false without changing anything if a required field is missing
    /// or a provided secret fails to persist.
    @discardableResult
    func update(_ existing: SavedHost, nickname: String, host: String, username: String, secret: HostSecret?) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !u.isEmpty else { return false }
        guard let i = hosts.firstIndex(where: { $0.id == existing.id }) else { return false }
        var newKind = existing.auth
        // Replace the secret only if a new one was entered; a failed persist aborts the
        // whole update so the record never drifts out of lockstep with the Keychain.
        if let secret {
            switch secret {
            case .key(let pem):
                let key = pem.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty,
                      keychain.save(account: hosts[i].account, secret: key) else { return false }
                newKind = .key
            case .password(let password):
                guard !password.isEmpty,
                      passwordKeychain.save(account: hosts[i].account, secret: password) else { return false }
                newKind = .password
            }
            // Auth kind changed → best-effort drop the stale secret from the other store.
            if newKind != existing.auth {
                switch existing.auth {
                case .key: _ = keychain.delete(account: hosts[i].account)
                case .password: _ = passwordKeychain.delete(account: hosts[i].account)
                }
            }
        }
        hosts[i].host = h
        hosts[i].username = u
        hosts[i].nickname = n.isEmpty ? nil : n
        hosts[i].authKind = newKind
        persist()
        return true
    }

    /// What it takes to connect to a saved host's default herdr session, with its secret from
    /// the Keychain. Nil when the host is malformed or this phone holds no secret for it.
    func credentials(for saved: SavedHost) -> SSHCredentials? {
        guard let endpoint = HostEndpoint.parse(saved.host) else { return nil }
        switch saved.auth {
        case .key:
            guard let key = key(for: saved)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { return nil }
            return SSHCredentials(host: endpoint.host, port: endpoint.port, username: saved.username,
                                  privateKeyPEM: key, remoteSocketPath: "")
        case .password:
            guard let password = password(for: saved), !password.isEmpty else { return nil }
            return SSHCredentials(host: endpoint.host, port: endpoint.port, username: saved.username,
                                  password: password, remoteSocketPath: "")
        }
    }

    /// The private key for a saved host, from the Keychain. Nil if missing/unreadable
    /// — the caller must treat that as "cannot reconnect", not "empty key".
    func key(for host: SavedHost) -> String? { keychain.load(account: host.account) }

    /// The password for a saved host, from the Keychain. Nil if missing/unreadable.
    func password(for host: SavedHost) -> String? { passwordKeychain.load(account: host.account) }

    /// Removes a saved host. Deletes the secret from BOTH stores first and drops the
    /// host record ONLY if both confirm it is gone — a failed Keychain delete must not
    /// leave a secret orphaned while the host vanishes from the UI. Each delete returns
    /// true on errSecItemNotFound, so a host with only one secret still deletes cleanly.
    /// Returns whether it removed; on false the row stays put so the user can retry.
    @discardableResult
    func delete(_ host: SavedHost) -> Bool {
        guard keychain.delete(account: host.account),
              passwordKeychain.delete(account: host.account) else { return false }
        hosts.removeAll { $0.id == host.id }
        persist()
        return true
    }

    /// The secret this device holds for `host`, whichever kind it is.
    func secret(for host: SavedHost) -> String? {
        host.auth == .key ? key(for: host) : password(for: host)
    }

    /// Puts back a secret this device lost: a restore from a backup brings the machines but
    /// not their device-only secrets (see `ICloudSync`).
    @discardableResult
    func restoreSecret(_ secret: String, for host: SavedHost) -> Bool {
        let saved = (host.auth == .key ? keychain : passwordKeychain).save(account: host.account, secret: secret)
        if saved { objectWillChange.send() }
        return saved
    }

    /// Replaces every saved machine with `machines` (iCloud's copy, see `ICloudSync`), all or
    /// nothing, so that a Keychain failure or a shutdown at any point leaves no machine with a
    /// credential that is not its own, and none without the one it had:
    /// 1. A machine whose secret is the one this device already holds for it keeps its Keychain
    ///    account. Nothing is written for it.
    /// 2. Stage. Every other incoming secret is saved under a new account nothing uses. If one
    ///    does not stick, nothing in use has been touched.
    /// 3. Commit. The one write of the list switches those machines to their new accounts. A
    ///    machine given no secret points at an account that holds none, so the credential it
    ///    had (perhaps for another address, or a host key this device does not trust) is out
    ///    of reach from that moment.
    /// Nothing is deleted here. The accounts this call may leave unused are written down
    /// first and removed at a later launch (`removeRetiredAccounts`).
    @discardableResult
    func replaceAll(_ machines: [(host: SavedHost, secret: String?)]) -> Bool {
        func store(_ host: SavedHost) -> KeychainCredentialStore { host.auth == .key ? keychain : passwordKeychain }
        var staged: [SavedHost] = []
        var fresh: [(host: SavedHost, secret: String?)] = []
        for machine in machines {
            var host = machine.host
            // Kept only when this device holds the very same secret, byte for byte. A machine
            // given no secret always moves to a new, empty account: a Keychain read that fails
            // also reads as "no secret", and must not leave it on an account that holds one.
            if let incoming = machine.secret, let mine = hosts.first(where: { $0.id == host.id }), mine.auth == host.auth,
               let held = secret(for: mine), held.utf8.elementsEqual(incoming.utf8) {
                host.secretAccount = mine.secretAccount
            } else {
                host.secretAccount = "\(host.id.uuidString).\(UUID().uuidString)"
                fresh.append((host, machine.secret))
            }
            staged.append(host)
        }
        // Either the new accounts end up unused (the switch never happens) or some of the
        // ones in use now do (it does). Both are written down before anything is saved.
        var retired = ShareStorage.defaults.dictionary(forKey: retiredKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        for account in fresh.map(\.host.account) + hosts.map(\.account) { retired[account] = now }
        ShareStorage.defaults.set(retired, forKey: retiredKey)
        for machine in fresh {
            if let secret = machine.secret, !store(machine.host).save(account: machine.host.account, secret: secret) { return false }
        }
        hosts = staged
        persist()
        return true
    }

    /// Removes the Keychain items of accounts a download stopped using. Not at the download:
    /// the write of the list that stops naming them reaches disk a moment later, and a
    /// shutdown before that brings back the old list, which still needs them. So only at a
    /// launch at least a day after the account was written down, and only if no saved machine
    /// names it by then. An account that is in use again is simply forgotten.
    private func removeRetiredAccounts() {
        guard var retired = ShareStorage.defaults.dictionary(forKey: retiredKey) as? [String: Double], !retired.isEmpty else { return }
        var wait: TimeInterval = 24 * 60 * 60
        #if DEBUG
        // `HERDR_DEBUG_RETIRE_AFTER=<seconds>`: for the iCloud sync test, which cannot wait a day.
        if let seconds = ProcessInfo.processInfo.environment["HERDR_DEBUG_RETIRE_AFTER"].flatMap(TimeInterval.init) { wait = seconds }
        #endif
        let inUse = Set(hosts.map(\.account))
        let due = Date().timeIntervalSince1970 - wait
        for (account, since) in retired {
            if inUse.contains(account) {
                retired[account] = nil
            } else if since <= due, keychain.delete(account: account), passwordKeychain.delete(account: account) {
                retired[account] = nil
            }
        }
        ShareStorage.defaults.set(retired, forKey: retiredKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        ShareStorage.defaults.set(data, forKey: defaultsKey)
    }
}

/// A Keychain store for per-host secrets (the private SSH key). Mirrors
/// `KeychainHostKeyPolicy`'s storage discipline — checked statuses, update-in-place
/// rather than delete-then-add — but is its own service and uses
/// `WhenUnlockedThisDeviceOnly`: a private key is more sensitive than a host-key
/// pin, so it is reachable only while the device is unlocked, and these items never
/// sync. When the owner turns iCloud sync on, `ICloudSync` keeps a sealed copy in
/// iCloud, readable only with a key in iCloud Keychain. The secret is only ever returned
/// by `load`; it is never logged or surfaced elsewhere.
struct KeychainCredentialStore {
    let service: String

    @discardableResult
    func save(account: String, secret: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update the value IN PLACE if the item exists (no window where the key is
        // absent); only add when there is nothing to update. Every status checked.
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else { return nil }
        return secret
    }

    /// Deletes the secret. Returns true only when it is actually GONE — errSecSuccess
    /// (deleted) or errSecItemNotFound (already absent). Any other OSStatus (e.g. the
    /// Keychain temporarily unavailable) returns false, so the caller does not drop the
    /// host record while the key still lives here.
    @discardableResult
    func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
