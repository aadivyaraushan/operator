import Foundation

let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("operator-whatsapp-unlinked-\(UUID().uuidString)")
let client = NativeWhatsAppReadClient(supportDirectory: support)
Task {
    do {
        _ = try await client.chats(limit: 1)
        preconditionFailure("an unused store must not appear linked")
    } catch let error as NativeWhatsAppReadError {
        precondition(error == .notLinked)
        print("NATIVE_WHATSAPP_ACTUAL_ABI_PASS")
        exit(0)
    } catch {
        exit(2)
    }
}
dispatchMain()
