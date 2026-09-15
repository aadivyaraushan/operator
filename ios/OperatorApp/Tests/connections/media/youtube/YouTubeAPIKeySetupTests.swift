import XCTest
@testable import OperatorApp

@MainActor
final class YouTubeAPIKeySetupTests: XCTestCase {
    func testSavingValidKeyStoresBoundedUTF8AndMarksKeySaved() async {
        let storage = YouTubeAPIKeyStorageFixture()
        let model = YouTubeAPIKeySetupModel(storage: storage.value)

        let saved = await model.save("  test-key  ")

        XCTAssertTrue(saved)
        XCTAssertEqual(model.state, .keySaved)
        XCTAssertNil(model.message)
        let stored = await storage.savedData()
        XCTAssertEqual(stored, Data("test-key".utf8))
    }

    func testInvalidKeyDoesNotReplaceExistingStoredKey() async {
        let storage = YouTubeAPIKeyStorageFixture(saved: Data("kept-key".utf8))
        let model = YouTubeAPIKeySetupModel(storage: storage.value)
        await model.check()

        let saved = await model.save(String(repeating: "é", count: 2_049))

        XCTAssertFalse(saved)
        XCTAssertEqual(model.state, .keySaved)
        let stored = await storage.savedData()
        XCTAssertEqual(stored, Data("kept-key".utf8))
    }

    func testSavingExactlyFourKiBOfUTF8IsAllowed() async {
        let storage = YouTubeAPIKeyStorageFixture()
        let model = YouTubeAPIKeySetupModel(storage: storage.value)
        let key = String(repeating: "é", count: 2_048)

        let saved = await model.save(key)

        XCTAssertTrue(saved)
        let stored = await storage.savedData()
        XCTAssertEqual(stored?.count, 4_096)
    }

    func testClearRemovesSavedKeyAndReturnsToSetupRequired() async {
        let storage = YouTubeAPIKeyStorageFixture(saved: Data("configured-key".utf8))
        let model = YouTubeAPIKeySetupModel(storage: storage.value)
        await model.check()

        let cleared = await model.clear()

        XCTAssertTrue(cleared)
        XCTAssertEqual(model.state, .setupRequired)
        let stored = await storage.savedData()
        XCTAssertNil(stored)
    }

    func testCheckTreatsEmptyOversizedAndInvalidUTF8StorageAsSetupRequired() async {
        for data in [Data(), Data(repeating: 0x61, count: 4_097), Data([0xFF])] {
            let storage = YouTubeAPIKeyStorageFixture(saved: data)
            let model = YouTubeAPIKeySetupModel(storage: storage.value)

            await model.check()

            XCTAssertEqual(model.state, .setupRequired)
        }
    }

    func testCheckDoesNotExposeTheStoredKeyInVisibleStatus() async {
        let storage = YouTubeAPIKeyStorageFixture(saved: Data("stored-secret-key".utf8))
        let model = YouTubeAPIKeySetupModel(storage: storage.value)

        await model.check()

        XCTAssertEqual(model.statusText, "Key saved")
        XCTAssertNil(model.message)
        XCTAssertFalse(model.statusText.contains("stored-secret-key"))
    }

    func testLoadFailureShowsAnHonestSetupError() async {
        let storage = YouTubeAPIKeyStorageFixture(failure: .load)
        let model = YouTubeAPIKeySetupModel(storage: storage.value)

        await model.check()

        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.message, "The saved YouTube key could not be checked.")
    }

    func testFailedReplacementPreservesExistingKeyAndSavedState() async {
        let storage = YouTubeAPIKeyStorageFixture(saved: Data("kept-key".utf8))
        let model = YouTubeAPIKeySetupModel(storage: storage.value)
        await model.check()
        await storage.setFailure(.save)

        let saved = await model.save("replacement-key")

        XCTAssertFalse(saved)
        XCTAssertEqual(model.state, .keySaved)
        XCTAssertEqual(model.message, "The YouTube key could not be saved.")
        let stored = await storage.savedData()
        XCTAssertEqual(stored, Data("kept-key".utf8))
    }

    func testFailedClearPreservesExistingKeyAndSavedState() async {
        let storage = YouTubeAPIKeyStorageFixture(saved: Data("kept-key".utf8))
        let model = YouTubeAPIKeySetupModel(storage: storage.value)
        await model.check()
        await storage.setFailure(.clear)

        let cleared = await model.clear()

        XCTAssertFalse(cleared)
        XCTAssertEqual(model.state, .keySaved)
        XCTAssertEqual(model.message, "The saved YouTube key could not be removed.")
        let stored = await storage.savedData()
        XCTAssertEqual(stored, Data("kept-key".utf8))
    }
}

private actor YouTubeAPIKeyStorageFixture {
    private var data: Data?
    private var failure: Failure?

    init(saved: Data? = nil, failure: Failure? = nil) {
        self.data = saved
        self.failure = failure
    }

    nonisolated var value: YouTubeAPIKeyStorage {
        .init(
            load: { [self] in try await self.read() },
            save: { [self] data in try await self.write(data) },
            clear: { [self] in try await self.remove() })
    }

    func read() throws -> Data? { if self.failure == .load { throw FixtureError.failed }; return self.data }
    func write(_ data: Data) throws { if self.failure == .save { throw FixtureError.failed }; self.data = data }
    func remove() throws { if self.failure == .clear { throw FixtureError.failed }; self.data = nil }
    func savedData() -> Data? { self.data }
    func setFailure(_ failure: Failure?) { self.failure = failure }

    enum Failure: Equatable, Sendable { case load, save, clear }
    private enum FixtureError: Error { case failed }
}
