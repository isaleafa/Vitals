import Darwin
import Foundation

struct NetIfaceRaw {
    var name = ""
    var up = false
    var addrs: [String] = []      // IP/CIDR
    var peer: String?             // 点对点对端
    var mac: String?
    var mtu = 0
    var rx: UInt32 = 0            // struct if_data 是 32 位计数器（4GiB 回绕）
    var tx: UInt32 = 0
}

/// 网络接口：`getifaddrs`（AF_LINK 给计数器/MTU/MAC，AF_INET[6] 给地址+前缀）。
enum NetworkProvider {
    static func read() -> [String: NetIfaceRaw] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var out: [String: NetIfaceRaw] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr?.pointee {
            let name = String(cString: ifa.ifa_name)
            var rec = out[name] ?? NetIfaceRaw(name: name, up: (ifa.ifa_flags & UInt32(IFF_UP)) != 0)

            if let sa = ifa.ifa_addr {
                let family = sa.pointee.sa_family
                let len = Int(sa.pointee.sa_len)

                if family == UInt8(AF_LINK), let data = ifa.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    rec.mtu = Int(d.ifi_mtu)
                    rec.rx = d.ifi_ibytes
                    rec.tx = d.ifi_obytes
                    // MAC 在 sockaddr_dl 原始字节里：name 之后 alen 个字节
                    if len >= 8 {
                        let raw = UnsafeRawBufferPointer(start: sa, count: len)
                        let nlen = Int(raw[5]), alen = Int(raw[6])
                        if alen > 0, 8 + nlen + alen <= len {
                            rec.mac = (0..<alen)
                                .map { String(format: "%02x", raw[8 + nlen + $0]) }
                                .joined(separator: ":")
                        }
                    }
                } else if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                    let isV4 = family == UInt8(AF_INET)
                    let addrOffset = isV4 ? 4 : 8
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    let src = UnsafeRawPointer(sa).advanced(by: addrOffset)
                    if inet_ntop(Int32(family), src, &buf, socklen_t(buf.count)) != nil {
                        var prefix = isV4 ? 32 : 128
                        if let nm = ifa.ifa_netmask {
                            let mlen = Int(nm.pointee.sa_len)
                            let mraw = UnsafeRawBufferPointer(start: nm, count: mlen)
                            let width = isV4 ? 4 : 16
                            let start = addrOffset
                            let end = min(mlen, start + width)
                            if start < end {
                                prefix = (start..<end).reduce(0) { $0 + mraw[$1].nonzeroBitCount }
                            }
                        }
                        rec.addrs.append("\(String(cString: buf))/\(prefix)")
                        // 点对点接口（隧道）的对端地址
                        if (ifa.ifa_flags & UInt32(IFF_POINTOPOINT)) != 0, let dst = ifa.ifa_dstaddr,
                           dst.pointee.sa_family == family {
                            var peerBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                            let peerSrc = UnsafeRawPointer(dst).advanced(by: addrOffset)
                            if inet_ntop(Int32(family), peerSrc, &peerBuf, socklen_t(peerBuf.count)) != nil {
                                rec.peer = String(cString: peerBuf)
                            }
                        }
                    }
                }
            }

            out[name] = rec
            ptr = ifa.ifa_next
        }
        return out
    }
}
