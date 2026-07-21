import Foundation
#if canImport(XCTest)
import XCTest
import ComputerUseHostLib
import ComputerUseHostTestRunner

final class ComputerUseHostTests: XCTestCase {
    func testPortableNativeSuite() async throws {
        try await ComputerUseHostTestRunner.main()
    }
}
#endif
