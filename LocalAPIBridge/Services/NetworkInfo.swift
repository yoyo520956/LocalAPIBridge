import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import UIKit

/// 获取本机 IPv4 地址、生成二维码。
enum NetworkInfo {
    struct InterfaceAddress {
        let name: String
        let address: String
    }

    /// 列出已启用、非回环的 IPv4 接口地址。
    static func ipv4Addresses() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return result
        }
        defer { freeifaddrs(pointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard let addressPointer = interface.ifa_addr else { continue }
            let family = addressPointer.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let flags = interface.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            var address = addressPointer.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.sa_len)
            let status = getnameinfo(&address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty else { continue }
            result.append(InterfaceAddress(name: name, address: ip))
        }
        return result
    }

    /// 优先选择 Wi-Fi（en0），其次私有网段；排除蜂窝、VPN 和链路本地地址，
    /// 避免把同一 Wi-Fi 下根本访问不到的地址展示给用户。
    static func preferredLANAddress() -> String? {
        let candidates = ipv4Addresses().filter { item in
            !item.address.hasPrefix("169.254.")
                && !item.name.hasPrefix("pdp_ip")
                && !item.name.hasPrefix("utun")
                && !item.name.hasPrefix("ipsec")
        }
        if let wifi = candidates.first(where: { $0.name == "en0" && isPrivateAddress($0.address) }) {
            return wifi.address
        }
        if let wifi = candidates.first(where: { $0.name == "en0" }) {
            return wifi.address
        }
        if let privateAddress = candidates.first(where: { isPrivateAddress($0.address) }) {
            return privateAddress.address
        }
        return nil
    }

    private static func isPrivateAddress(_ ip: String) -> Bool {
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") {
            return true
        }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    /// 生成二维码图片（缩放后的位图，适合直接放进 SwiftUI）。
    static func qrCodeImage(from string: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}