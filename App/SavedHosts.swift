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

    /// The resolved auth kind for callers — a legacy (nil) host is key-based.
    var auth: SavedAuthKind { authKind ?? .key }

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
        #if DEBUG
        seedHostFromEnvironment()
        #endif
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
                      keychain.save(account: existing.id.uuidString, secret: key) else { return false }
                newKind = .key
            case .password(let password):
                guard !password.isEmpty,
                      passwordKeychain.save(account: existing.id.uuidString, secret: password) else { return false }
                newKind = .password
            }
            // Auth kind changed → best-effort drop the stale secret from the other store.
            if newKind != existing.auth {
                switch existing.auth {
                case .key: _ = keychain.delete(account: existing.id.uuidString)
                case .password: _ = passwordKeychain.delete(account: existing.id.uuidString)
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
    func key(for host: SavedHost) -> String? { keychain.load(account: host.id.uuidString) }

    /// The password for a saved host, from the Keychain. Nil if missing/unreadable.
    func password(for host: SavedHost) -> String? { passwordKeychain.load(account: host.id.uuidString) }

    /// Removes a saved host. Deletes the secret from BOTH stores first and drops the
    /// host record ONLY if both confirm it is gone — a failed Keychain delete must not
    /// leave a secret orphaned while the host vanishes from the UI. Each delete returns
    /// true on errSecItemNotFound, so a host with only one secret still deletes cleanly.
    /// Returns whether it removed; on false the row stays put so the user can retry.
    @discardableResult
    func delete(_ host: SavedHost) -> Bool {
        guard keychain.delete(account: host.id.uuidString),
              passwordKeychain.delete(account: host.id.uuidString) else { return false }
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
        let saved = (host.auth == .key ? keychain : passwordKeychain).save(account: host.id.uuidString, secret: secret)
        if saved { objectWillChange.send() }
        return saved
    }

    /// Replaces every saved machine with `machines` (iCloud's copy, see `ICloudSync`), all or
    /// nothing. Each machine ends up with exactly the credential given: a nil secret removes
    /// the one this device had under that id, which may belong to another address or to a host
    /// key this device does not trust. If a Keychain change does not stick, the ones already
    /// made are undone and the list is left alone.
    @discardableResult
    func replaceAll(_ machines: [(host: SavedHost, secret: String?)]) -> Bool {
        var undo: [(store: KeychainCredentialStore, account: String, before: String?)] = []
        func set(_ store: KeychainCredentialStore, _ account: String, _ secret: String?) -> Bool {
            let before = store.load(account: account)
            if before == secret, secret != nil { return true }
            undo.append((store, account, before))
            if let secret { return store.save(account: account, secret: secret) }
            return store.delete(account: account)
        }
        var done = true
        for machine in machines where done {
            let id = machine.host.id.uuidString
            let (used, unused) = machine.host.auth == .key ? (keychain, passwordKeychain) : (passwordKeychain, keychain)
            done = set(used, id, machine.secret) && set(unused, id, nil)
        }
        let keep = Set(machines.map(\.host.id))
        for old in hosts where done && !keep.contains(old.id) {
            done = set(keychain, old.id.uuidString, nil) && set(passwordKeychain, old.id.uuidString, nil)
        }
        guard done else {
            for step in undo.reversed() {
                if let before = step.before {
                    _ = step.store.save(account: step.account, secret: before)
                } else {
                    _ = step.store.delete(account: step.account)
                }
            }
            return false
        }
        hosts = machines.map(\.host)
        persist()
        return true
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
