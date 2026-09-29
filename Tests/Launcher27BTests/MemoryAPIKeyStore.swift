import Foundation
@testable import Launcher27B

final class MemoryAPIKeyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var store: ApiKeyStore {
        ApiKeyStore(read: { self.lock.withLock { self.value } }, write: { key in self.lock.withLock { self.value = key } })
    }
}
