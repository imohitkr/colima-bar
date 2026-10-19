import Foundation
import SystemConfiguration
import os

/// Reports when the DNS setup of the Mac changes, for example when a VPN
/// connects or the Mac joins another network. It reads `SCDynamicStore` on
/// the main run loop. It needs no permission. It reports only a change of
/// the fingerprint of `MacDNSConfig`, so a change of an address that does
/// not touch DNS is silent. A normal run creates it, a debug run does not.
@MainActor
final class NetworkObserver {
    /// The Mac DNS setup changed. It does not report the first state: read `current`.
    var onChange: ((MacDNSConfig) -> Void)?
    /// The last setup that the observer read.
    private(set) var current = MacDNSConfig()

    nonisolated static let globalDNSKey = "State:/Network/Global/DNS"
    nonisolated static let globalIPv4Key = "State:/Network/Global/IPv4"
    nonisolated static let serviceDNSPattern = "State:/Network/Service/.*/DNS"

    private let log = Logger(category: "network")
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?

    init() {
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let observer = Unmanaged<NetworkObserver>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { observer.recheck() }
        }
        guard let store = SCDynamicStoreCreate(nil, "ColimaBar" as CFString, callback, &context) else {
            log.error("network observer: SCDynamicStoreCreate failed")
            return
        }
        let keys = [Self.globalDNSKey, Self.globalIPv4Key] as CFArray
        let patterns = [Self.serviceDNSPattern] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, patterns),
            let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        else {
            log.error("network observer: could not watch the network keys")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        self.source = source
        current = Self.read(store)
    }

    /// Reads the setup again and reports it if the fingerprint changed.
    private func recheck() {
        guard let store else { return }
        let now = Self.read(store)
        guard now.fingerprint != current.fingerprint else { return }
        current = now
        onChange?(now)
    }

    /// The DNS setup of the Mac now. It opens its own read-only view of the
    /// store, so it works without an observer (a debug run, the command).
    nonisolated static func readCurrent() -> MacDNSConfig? {
        SCDynamicStoreCreate(nil, "ColimaBar" as CFString, nil, nil).map(read)
    }

    nonisolated private static func read(_ store: SCDynamicStore) -> MacDNSConfig {
        let global = SCDynamicStoreCopyValue(store, globalDNSKey as CFString) as? [String: Any]
        let all =
            SCDynamicStoreCopyMultiple(store, nil, [serviceDNSPattern] as CFArray) as? [String: Any] ?? [:]
        var services: [String: [String: Any]] = [:]
        for (key, value) in all {
            if let dict = value as? [String: Any] { services[key] = dict }
        }
        return MacDNSConfig.parse(global: global, services: services)
    }

    /// Stops the callbacks.
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        store = nil
    }
}
