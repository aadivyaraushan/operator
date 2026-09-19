import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct MediaOpenReceipt: Equatable, Sendable {
    let openedURL: URL
    let actionCompleted: Bool
    let playbackVerified: Bool
}

enum PublicMediaURLPolicy {
    static func isStructurallySafe(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 2_048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              let rawHost = parts.host?.lowercased(),
              !rawHost.isEmpty,
              parts.user == nil,
              parts.password == nil,
              parts.port == nil,
              parts.fragment == nil
        else { return false }

        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        guard host.utf8.count <= 253,
              !host.isEmpty,
              !host.contains("%"),
              !host.contains(".."),
              !host.hasPrefix("."),
              !host.hasSuffix(".")
        else { return false }

        let blockedNames = ["localhost", "local", "internal", "lan", "home", "test", "invalid", "example"]
        guard !blockedNames.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return false }
        if let literalIsPublic = self.literalAddressIsPublic(host) {
            return literalIsPublic
        }
        return host.split(separator: ".").allSatisfy { label in
            !label.isEmpty
                && label.utf8.count <= 63
                && label.first != "-"
                && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func hostResolvesOnlyToPublicAddresses(_ host: String) async -> Bool {
        #if canImport(Darwin)
        return await Task.detached(priority: .utility) {
            if let literalIsPublic = self.literalAddressIsPublic(host) {
                return literalIsPublic
            }
            var hints = addrinfo()
            hints.ai_flags = AI_ADDRCONFIG
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var result: UnsafeMutablePointer<addrinfo>?
            let status = host.withCString { getaddrinfo($0, nil, &hints, &result) }
            guard status == 0, let first = result else { return false }
            defer { freeaddrinfo(first) }

            var sawAddress = false
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let entry = current {
                guard let address = entry.pointee.ai_addr else { return false }
                switch Int32(entry.pointee.ai_family) {
                case AF_INET:
                    let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                    }
                    guard self.ipv4IsPublic(bytes) else { return false }
                    sawAddress = true
                case AF_INET6:
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                    }
                    guard self.ipv6IsPublic(bytes) else { return false }
                    sawAddress = true
                default:
                    return false
                }
                current = entry.pointee.ai_next
            }
            return sawAddress
        }.value
        #else
        return false
        #endif
    }

    static func literalAddressIsPublic(_ host: String) -> Bool? {
        #if canImport(Darwin)
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: ipv4) { self.ipv4IsPublic(Array($0)) }
        }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: ipv6) { self.ipv6IsPublic(Array($0)) }
        }
        #endif
        return nil
    }

    private static func ipv4IsPublic(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100, (64 ... 127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16 ... 31).contains(second) { return false }
        if first == 192, second == 168 { return false }
        if first == 192, second == 0 { return false }
        if first == 192, second == 0, bytes[2] == 2 { return false }
        if first == 198, second == 18 || second == 19 { return false }
        if first == 198, second == 51, bytes[2] == 100 { return false }
        if first == 203, second == 0, bytes[2] == 113 { return false }
        return true
    }

    private static func ipv6IsPublic(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes[0] == 0xFC || bytes[0] == 0xFD || bytes[0] == 0xFF { return false }
        if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return false }
        if Array(bytes.prefix(4)) == [0x20, 0x01, 0x0D, 0xB8] { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return self.ipv4IsPublic(Array(bytes.suffix(4)))
        }
        if Array(bytes.prefix(12)) == [0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] {
            return self.ipv4IsPublic(Array(bytes.suffix(4)))
        }
        return (bytes[0] & 0xE0) == 0x20
    }
}
