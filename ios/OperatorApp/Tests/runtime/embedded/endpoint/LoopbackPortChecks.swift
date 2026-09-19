import Foundation

@main struct LoopbackPortChecks {
    static func main() throws {
        let port = try LoopbackPort.allocate()
        precondition(port > 0, "OS must allocate a concrete local port")
        print("PASS: allocated loopback port \(port)")
    }
}
