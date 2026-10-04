import Foundation
import IOKit
import Darwin

import DisplayProtocol

private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias IOFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

// Immutable handle and metadata; the lock protects complete read/write transactions.
public final class Monitor: Identifiable, @unchecked Sendable {
    public let id: UInt64
    public let name: String
    private let service: CFTypeRef
    private let chip: UInt32
    private let readFn: IOFn
    private let writeFn: IOFn
    private let lock = NSLock()

    fileprivate init(id: UInt64, name: String, service: CFTypeRef, chip: UInt32, read: @escaping IOFn, write: @escaping IOFn) {
        self.id = id; self.name = name; self.service = service; self.chip = chip
        readFn = read; writeFn = write
    }

    private func send(_ packet: [UInt8]) throws {
        var packet = packet
        usleep(50_000)
        let result = packet.withUnsafeMutableBytes {
            writeFn(service, chip, 0x51, $0.baseAddress!, UInt32($0.count))
        }
        guard result == kIOReturnSuccess else { throw ControlError.communication }
    }

    public func brightness() throws -> Brightness {
        lock.lock(); defer { lock.unlock() }
        return try read(.brightness)
    }

    public func volume() throws -> Brightness {
        lock.lock(); defer { lock.unlock() }
        return try read(.volume)
    }

    private func read(_ feature: Feature) throws -> Brightness {
        var lastError: Error = ControlError.communication
        for _ in 0..<3 {
            do {
                try send(Packet.read(feature))
                usleep(60_000)
                var bytes = [UInt8](repeating: 0, count: 12)
                let result = bytes.withUnsafeMutableBytes {
                    readFn(service, chip, 0x51, $0.baseAddress!, UInt32($0.count))
                }
                guard result == kIOReturnSuccess else { throw ControlError.communication }
                return try Packet.parse(bytes, feature: feature)
            } catch { lastError = error }
        }
        throw lastError
    }

    // Every write is checked against a fresh read under the same transaction lock.
    public func setBrightness(percent: Int) throws -> Brightness {
        lock.lock(); defer { lock.unlock() }
        return try set(.brightness, percent: percent)
    }

    public func setVolume(percent: Int) throws -> Brightness {
        lock.lock(); defer { lock.unlock() }
        return try set(.volume, percent: percent)
    }

    private func set(_ feature: Feature, percent: Int) throws -> Brightness {
        let before = try read(feature)
        let bounded = min(100, max(0, percent))
        let raw = Int((Double(bounded) * Double(before.maximum) / 100).rounded())
        try send(Packet.write(UInt16(raw), feature: feature))
        usleep(100_000)
        let after = try read(feature)
        guard after.current == raw else { throw ControlError.rejected(after.percent) }
        return after
    }
}

public enum DisplayDiscovery {
    // IOAVService entry points are exported by IOKit; no third-party runtime.
    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static func property(_ service: io_registry_entry_t, _ key: String, recursive: Bool = false) -> Any? {
        if recursive {
            return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
        }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String {
        var bytes = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &bytes) == KERN_SUCCESS else { return "" }
        return String(cString: bytes)
    }

    private static func productName(for proxy: io_registry_entry_t) -> String {
        // The proxy and framebuffer are in separate branches. Match their display
        // route (e.g. dispext1:dcpav-service-epic:0 ↔ dispext1@14000000).
        var ancestor = proxy
        IOObjectRetain(ancestor)
        var route: String?
        for _ in 0..<16 {
            let name = registryName(ancestor)
            if name.contains(":dcpav-service-epic:") {
                route = name.components(separatedBy: ":").first
                break
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(ancestor, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(ancestor); ancestor = parent
        }
        IOObjectRelease(ancestor)
        guard let route else { return "External display" }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator) == KERN_SUCCESS else { return "External display" }
        defer { IOObjectRelease(iterator) }
        while case let framebuffer = IOIteratorNext(iterator), framebuffer != 0 {
            defer { IOObjectRelease(framebuffer) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(framebuffer, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            let matches = registryName(parent).components(separatedBy: "@").first == route
            IOObjectRelease(parent)
            if matches,
               let attrs = property(framebuffer, "DisplayAttributes", recursive: true) as? [String: Any],
               let product = attrs["ProductAttributes"] as? [String: Any],
               let name = product["ProductName"] as? String { return name }
        }
        return "External display (\(route))"
    }

    public static func monitors() -> [Monitor] {
        guard let handle,
              let c = dlsym(handle, "IOAVServiceCreateWithService"),
              let r = dlsym(handle, "IOAVServiceReadI2C"),
              let w = dlsym(handle, "IOAVServiceWriteI2C") else { return [] }
        let create = unsafeBitCast(c, to: CreateFn.self)
        let read = unsafeBitCast(r, to: IOFn.self)
        let write = unsafeBitCast(w, to: IOFn.self)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var monitors: [Monitor] = []
        while case let proxy = IOIteratorNext(iterator), proxy != 0 {
            defer { IOObjectRelease(proxy) }
            guard property(proxy, "Location") as? String == "External" else { continue }
            var parent: io_registry_entry_t = 0
            var chip: UInt32 = 0x37
            if IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS {
                if property(parent, "EPICProviderClass") as? String == "AppleDCPMCDP29XX" { chip = 0xb7 }
                IOObjectRelease(parent)
            }
            let name = productName(for: proxy)
            guard let ref = create(kCFAllocatorDefault, proxy)?.takeRetainedValue() else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(proxy, &id) == KERN_SUCCESS else { continue }
            monitors.append(Monitor(id: id, name: name, service: ref, chip: chip, read: read, write: write))
        }
        return monitors.sorted { $0.id < $1.id }
    }
}
