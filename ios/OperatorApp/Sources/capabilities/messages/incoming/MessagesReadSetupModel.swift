import Combine
import Foundation

@MainActor
final class MessagesReadSetupModel: ObservableObject {
    @Published private(set) var lastReceived: IncomingMessage?
    @Published private(set) var recordedCount = 0
    private let store: IncomingMessageStore

    init(store: IncomingMessageStore) { self.store = store }

    func refresh() {
        let status = self.store.status()
        self.lastReceived = status.last
        self.recordedCount = status.count
    }
}
