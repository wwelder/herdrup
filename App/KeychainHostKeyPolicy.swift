import Foundation
import Security
import Darwin
import HerdrKit

/// Cross-launch TOFU: the persistent `HostKeyPolicy` the transport contract
/// assigns to the app (HerdrKit's `PinStore` is in-memory only and cannot be
/// Keychain-backed). Fingerprints are stored in the iOS Keychain keyed by
/// host:port; compare-and-pin is one locked operation, so a changed key is
/// hard-stopped ACROSS launches, not just within a process. Lives in the app
/// target because the Security framework is not available on Linux, where
/// HerdrKit still builds.
final class KeychainHostKeyPolicy: HostKeyPolicy, @unchecked Sendable {
    /// Shared so all transports enforce one lock/pin set (SwiftUI re-inits View
    /// structs, so a per-view instance would churn and split the lock).
    static let shared = KeychainHostKeyPolicy()

    private let lock = NSLock()
    private let service = "dev.herdr.hostkey.pins"

    /// Posted on the main queue after this device pinned or re-pinned a host key itself (a
    /// first connection, a pairing, the owner accepting a changed key). `ICloudSync` uploads it.
    static let pinned = Notification.Name("dev.herdr.hostkey.pinned")

    /// Asynchronously: the caller holds `lock`, and the main thread may be waiting for it.
    private func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.pinned, object: nil) }
    }

    func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision {
        lock.lock(); defer { lock.unlock() }
        let account = accountKey(host: host, port: port)
        switch lookup(account: account) {
        case .found(let existing):
            return existing == presented ? .trust : .reject
        case .notFound:
            // First contact: trust ONLY if the pin actually persists; a failed
            // write must not read as "trusted but unpinned" next launch.
            guard store(account: account, fingerprint: presented) else { return .reject }
            announce()
            return .trust
        case .error:
            // A Keychain read error is NOT the absence of a pin. Fail CLOSED —
            // reading it as "no pin" would trust any key on a transient failure.
            return .reject
        }
    }

    /// Binds a host to an EXACT fingerprint the user verified out of band. Used
    /// for a verified key rotation: an atomic replace (delete + add under the
    /// lock), so there is no delete-then-TOFU window where a substituted key
    /// could be pinned — only the fingerprint passed here is trusted next connect.
    /// Returns whether the fingerprint was actually persisted. The caller MUST
    /// NOT reconnect on false — reconnecting without a stored pin would treat the
    /// next key as first contact (a TOFU window).
    /// The fingerprint pinned for this endpoint, if there is one. For `ICloudSync`, which
    /// carries a verified pin to the owner's other devices along with the credential.
    func fingerprint(host: String, port: UInt16) -> String? {
        lock.lock(); defer { lock.unlock() }
        if case .found(let fingerprint) = lookup(account: accountKey(host: host, port: port)) { return fingerprint }
        return nil
    }

    @discardableResult
    func pin(host: String, port: UInt16, fingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let account = accountKey(host: host, port: port)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // One checked SecItemUpdate replaces the value IN PLACE (no window where
        // the pin is absent). Only if there is nothing to update do we add. Under
        // the lock, there is no check-then-act race. Every status is checked, so
        // a failed persist is reported rather than silently trusted later.
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(fingerprint.utf8)] as CFDictionary)
        if updated == errSecSuccess { announce(); return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = Data(fingerprint.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        announce()
        return true
    }

    /// For a host key that reached this device through iCloud (`ICloudSync`): pins it when the
    /// endpoint has no pin, as a first connection would, and never replaces one, so sync cannot
    /// change a key this device verified itself. Returns the fingerprint in place afterwards;
    /// the caller takes the credential only if that is the one it came with. Nil when the
    /// Keychain could not be read or written.
    func adopt(host: String, port: UInt16, fingerprint: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let account = accountKey(host: host, port: port)
        switch lookup(account: account) {
        case .found(let existing): return existing
        case .notFound: return store(account: account, fingerprint: fingerprint) ? fingerprint : nil
        case .error: return nil
        }
    }

    /// Canonicalizes the pin key so spellings that reach the same host share one
    /// pin — otherwise a different spelling is a fresh first-contact that bypasses
    /// the pin. IPv6 literals have many textual forms (RFC 5952), so they are
    /// normalized through inet_pton/inet_ntop; DNS names are case-insensitive
    /// (RFC 4343) and may carry a trailing dot.
    private func accountKey(host: String, port: UInt16) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let canonicalIP = canonicalIPv6(h) {
            h = canonicalIP
        } else {
            h = h.lowercased()
            while h.hasSuffix(".") { h.removeLast() }
        }
        return "\(h):\(port)"
    }

    /// Canonical IPv6 text (compressed, lowercase) via the resolver, or nil if
    /// `s` is not an IPv6 literal. A scoped address keeps its zone id (`%en0`)
    /// lowercased so `fe80::1%EN0` and `fe80::1%en0` share a pin — the zone is
    /// canonicalized alongside the address rather than left to split the pin.
    private func canonicalIPv6(_ s: String) -> String? {
        let parts = s.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0])
        var addr = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        var canonical = String(cString: buffer)
        if parts.count == 2 {
            // Lowercase the zone id — a STABLE canonicalization. An earlier
            // version mapped the zone through if_nametoindex, but that was a
            // fail-open (backfill review): if_nametoindex is a case-sensitive
            // exact-match lookup (so `%EN0` and `%en0` took different branches
            // and split the pin), and worse it embedded the kernel-assigned
            // interface INDEX, which is runtime state that changes across
            // reboots — a moved index no longer matches the pin and the next key
            // is trusted as first contact. Lowercasing is stable and closes the
            // realistic (case) variation; a name-vs-numeric-zone difference is a
            // theoretical link-local-only edge, not worth an unstable key.
            canonical += "%" + parts[1].lowercased()
        }
        return canonical
    }

    private enum Lookup { case found(String), notFound, error }

    private func lookup(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let fingerprint = String(data: data, encoding: .utf8) else { return .error }
            return .found(fingerprint)
        case errSecItemNotFound:
            return .notFound
        default:
            return .error   // transient/availability/auth error — not an absence
        }
    }

    private func store(account: String, fingerprint: String) -> Bool {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(fingerprint.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
