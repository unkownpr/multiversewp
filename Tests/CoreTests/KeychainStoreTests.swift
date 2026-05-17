import XCTest
@testable import MultiverseWP

final class KeychainStoreTests: XCTestCase {

    private var store: KeychainStore!
    private let testService = "com.semihsilistre.multiversewp.tests"
    private let testAccount = "unit-test-account"

    override func setUp() {
        super.setUp()
        store = KeychainStore(service: testService)
        try? store.delete(account: testAccount)
    }

    override func tearDown() {
        try? store.delete(account: testAccount)
        super.tearDown()
    }

    func testRoundTripString() throws {
        try store.setString("hello", for: testAccount)
        XCTAssertEqual(try store.string(for: testAccount), "hello")
    }

    func testOverwriteExistingValue() throws {
        try store.setString("first", for: testAccount)
        try store.setString("second", for: testAccount)
        XCTAssertEqual(try store.string(for: testAccount), "second")
    }

    func testMissingItemThrows() {
        XCTAssertThrowsError(try store.string(for: "non-existent-\(UUID())"))
    }

    func testContains() throws {
        XCTAssertFalse(store.contains(account: testAccount))
        try store.setString("x", for: testAccount)
        XCTAssertTrue(store.contains(account: testAccount))
    }

    func testDeleteIsIdempotent() throws {
        try store.setString("x", for: testAccount)
        try store.delete(account: testAccount)
        XCTAssertNoThrow(try store.delete(account: testAccount))
    }
}
