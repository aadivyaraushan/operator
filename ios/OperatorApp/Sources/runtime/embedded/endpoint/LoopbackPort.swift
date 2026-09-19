import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum LoopbackPort {
    enum AllocationError: Error { case socket, bind, address }

    static func allocate() throws -> UInt16 {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AllocationError.socket }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw AllocationError.bind }

        var allocated = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &allocated) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0, allocated.sin_port != 0 else { throw AllocationError.address }
        return UInt16(bigEndian: allocated.sin_port)
        #else
        throw AllocationError.socket
        #endif
    }
}
