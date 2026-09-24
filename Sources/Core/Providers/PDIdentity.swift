import Foundation
import IOKit

/// USB-PD 对端身份：拿 `Vendor ID` / `Product ID` / `Specification Revision`（= PD 版本）。
///
/// 节点类名是 `IOPortTransportComponentCCUSBPDSOP`（本机实测可直接匹配；注意
/// `AppleHPMInterface` 在本机是 0 个实例，从它走不通）。读一次缓存住，默认 60 秒才重读。
enum PDIdentity {
    struct Info: Codable {
        var vendorID: Int?
        var productID: Int?
        var specRevision: Int?
        var port: Int?

        var revisionText: String? {
            guard let rev = specRevision else { return nil }
            return "PD \(rev).0"
        }
    }

    private static var cached: Info?
    private static var cachedAt = Date.distantPast

    static func read(maxAge: TimeInterval = 60) -> Info? {
        if let cached, Date().timeIntervalSince(cachedAt) < maxAge { return cached }
        var found: Info?
        // 主路径：直接匹配 SOP 节点类；备选：从 AppleHPMDevice 子树里找
        for serviceClass in ["IOPortTransportComponentCCUSBPDSOP", "AppleHPMDevice"] {
            if let info = scan(serviceClass) { found = info; break }
        }
        if let found {
            cached = found
            cachedAt = Date()
        }
        return found ?? cached
    }

    private static func scan(_ serviceClass: String) -> Info? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(serviceClass),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var fallback: Info?
        while true {
            let service = IOIteratorNext(iter)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            let identity = readIdentity(service) ?? walkForSOP(service, depth: 0)
            guard let identity, identity.vendorID != nil else { continue }
            // 优先取端口对端（SOP）而不是线缆（SOP' / SOP''）
            let address = stringProperty(service, "AddressDescription") ?? stringProperty(service, "Description") ?? ""
            if address.hasSuffix("SOP") { return identity }
            if fallback == nil { fallback = identity }
        }
        return fallback
    }

    private static func readIdentity(_ entry: io_registry_entry_t) -> Info? {
        var info = Info()
        info.vendorID = intProperty(entry, "Vendor ID")
        info.productID = intProperty(entry, "Product ID")
        info.specRevision = intProperty(entry, "Specification Revision")
        info.port = intProperty(entry, "ParentBuiltInPortNumber")
        return info.vendorID == nil ? nil : info
    }

    private static func walkForSOP(_ entry: io_registry_entry_t, depth: Int) -> Info? {
        guard depth <= 6 else { return nil }
        if let className = classOf(entry), className.contains("USBPDSOP"), let info = readIdentity(entry) {
            return info
        }
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(childIter) }
        while true {
            let child = IOIteratorNext(childIter)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }
            if let found = walkForSOP(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func classOf(_ entry: io_registry_entry_t) -> String? {
        guard let raw = IOObjectCopyClass(entry) else { return nil }
        return raw.takeRetainedValue() as String
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
