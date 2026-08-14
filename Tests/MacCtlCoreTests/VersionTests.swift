import XCTest
@testable import MacCtlCore

final class VersionTests: XCTestCase {
    func testCurrentVersionIsSemantic() {
        XCTAssertNotNil(MacCtlVersion.current.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }
}
