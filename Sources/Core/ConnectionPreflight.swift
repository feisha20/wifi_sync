import Foundation
import Darwin

enum ConnectionPreflight {
    static var cameraSubnetAvailable: Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        var cursor = head
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET), interface.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil,
               String(cString: buffer).hasPrefix("192.168.2.") { return true }
        }
        return false
    }
}
