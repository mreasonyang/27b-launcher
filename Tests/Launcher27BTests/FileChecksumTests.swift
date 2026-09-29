import Foundation
import Testing
@testable import Launcher27B

struct FileChecksumTests {
    @Test
    func hashesFilesIncrementally() throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(
            path: "BonsaiChecksumTests-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try Data("abc".utf8).write(to: fileURL)

        #expect(
            try FileChecksum().sha256(at: fileURL)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
