import XCTest
@testable import CapacitorMediastorePlugin

class CapacitorMediastoreTests: XCTestCase {
    func testPermissionsShape() {
        let implementation = CapacitorMediastore()
        let perms = implementation.checkPermissions()
        // Все три ключа должны присутствовать с одним из ожидаемых статусов.
        let expected: Set<String> = ["granted", "limited", "denied", "prompt"]
        for key in ["photos", "videos", "audio"] {
            XCTAssertNotNil(perms[key])
            XCTAssertTrue(expected.contains(perms[key] ?? ""))
        }
    }
}
