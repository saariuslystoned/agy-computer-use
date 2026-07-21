import Foundation
#if canImport(XCTest)
import XCTest
import ComputerUseHostLib
import ComputerUseHostTestRunner

private final class ErrorBox: @unchecked Sendable {
    private var err: Error? = nil
    private let lock = NSLock()
    func set(_ error: Error) {
        lock.lock()
        err = error
        lock.unlock()
    }
    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return err
    }
}

private func runSync(_ block: @Sendable @escaping () async throws -> Void) throws {
    let sem = DispatchSemaphore(value: 0)
    let box = ErrorBox()
    Task {
        do {
            try await block()
        } catch {
            box.set(error)
        }
        sem.signal()
    }
    let res = sem.wait(timeout: .now() + .seconds(15))
    if res == .timedOut {
        fputs("[FAIL] XCTest runner hard timeout\n", stderr)
        _exit(1)
    }
    if let err = box.value { throw err }
}

@objcMembers
public final class ComputerUseHostTests: XCTestCase {
    public func test01_LengthPrefixedFraming() throws {
        try runSync { try await ComputerUseHostTestRunner.run01_LengthPrefixedFraming() }
    }

    public func test02_OversizedFramingHeaderRejection() throws {
        try runSync { try await ComputerUseHostTestRunner.run02_OversizedFramingHeaderRejection() }
    }

    public func test03_DirectoryPreparation() throws {
        try runSync { try await ComputerUseHostTestRunner.run03_DirectoryPreparation() }
    }

    public func test04_UDSClientServerRoundTrip() throws {
        try runSync { try await ComputerUseHostTestRunner.run04_UDSClientServerRoundTrip() }
    }

    public func test05_PostTimeoutUDSRecovery() throws {
        try runSync { try await ComputerUseHostTestRunner.run05_PostTimeoutUDSRecovery() }
    }

    public func test06_SlowDripHeaderTimeout() throws {
        try runSync { try await ComputerUseHostTestRunner.run06_SlowDripHeaderTimeout() }
    }

    public func test07_SlowDripBodyTimeout() throws {
        try runSync { try await ComputerUseHostTestRunner.run07_SlowDripBodyTimeout() }
    }

    public func test08_BlockedResponseWriteTimeout() throws {
        try runSync { try await ComputerUseHostTestRunner.run08_BlockedResponseWriteTimeout() }
    }

    public func test09_PeerCloseAndPartialIO() throws {
        try runSync { try await ComputerUseHostTestRunner.run09_PeerCloseAndPartialIO() }
    }

    public func test10_EINTRRetryPath() throws {
        try runSync { try await ComputerUseHostTestRunner.run10_EINTRRetryPath() }
    }

    public func test11_TimeoutResponseFollowedByNextClient() throws {
        try runSync { try await ComputerUseHostTestRunner.run11_TimeoutResponseFollowedByNextClient() }
    }

    public func test12_LiveSocketCollisionProbe() throws {
        try runSync { try await ComputerUseHostTestRunner.run12_LiveSocketCollisionProbe() }
    }

    public func test13_VerifiedStaleSocketRecovery() throws {
        try runSync { try await ComputerUseHostTestRunner.run13_VerifiedStaleSocketRecovery() }
    }

    public func test14_ForeignSymlinkNonSocketRefusal() throws {
        try runSync { try await ComputerUseHostTestRunner.run14_ForeignSymlinkNonSocketRefusal() }
    }

    public func test15_StopNeverUnlinksReplacementInode() throws {
        try runSync { try await ComputerUseHostTestRunner.run15_StopNeverUnlinksReplacementInode() }
    }

    public func test16_IEEE754BitPatternTopologyGoldenVectorAndMutations() throws {
        try runSync { try await ComputerUseHostTestRunner.run16_IEEE754BitPatternTopologyGoldenVectorAndMutations() }
    }

    public func test17_HotPlugSafeDisplayEnumerator() throws {
        try runSync { try await ComputerUseHostTestRunner.run17_HotPlugSafeDisplayEnumerator() }
    }

    public func test18_PermissionPreflightDeniedZeroLoaderCalls() throws {
        try runSync { try await ComputerUseHostTestRunner.run18_PermissionPreflightDeniedZeroLoaderCalls() }
    }

    public func test19_PureJPEGValidatorExactAndNear10MiBBoundaries() throws {
        try runSync { try await ComputerUseHostTestRunner.run19_PureJPEGValidatorExactAndNear10MiBBoundaries() }
    }

    public func test20_SOF0AndSOF2MarkerValidation() throws {
        try runSync { try await ComputerUseHostTestRunner.run20_SOF0AndSOF2MarkerValidation() }
    }

    public func test21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection() throws {
        try runSync { try await ComputerUseHostTestRunner.run21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection() }
    }

    public func test22_NoncooperativeLateCompletionGenerationFence() throws {
        try runSync { try await ComputerUseHostTestRunner.run22_NoncooperativeLateCompletionGenerationFence() }
    }

    public func test23_StaleOperationGenerationFence() throws {
        try runSync { try await ComputerUseHostTestRunner.run23_StaleOperationGenerationFence() }
    }

    public func test24_RequesterCancellation() throws {
        try runSync { try await ComputerUseHostTestRunner.run24_RequesterCancellation() }
    }

    public func test25_TimedOutOrphanCapacity() throws {
        try runSync { try await ComputerUseHostTestRunner.run25_TimedOutOrphanCapacity() }
    }

    public func test26_TopologyChangeDuringCaptureDiscarded() throws {
        try runSync { try await ComputerUseHostTestRunner.run26_TopologyChangeDuringCaptureDiscarded() }
    }

    public func test27_DisabledActionsAndAXTreeRejection() throws {
        try runSync { try await ComputerUseHostTestRunner.run27_DisabledActionsAndAXTreeRejection() }
    }

    public func test28_DisplayIdParameterValidation() throws {
        try runSync { try await ComputerUseHostTestRunner.run28_DisplayIdParameterValidation() }
    }

    public func test29_CancellationErrorMappedToCancelledCode() throws {
        try runSync { try await ComputerUseHostTestRunner.run29_CancellationErrorMappedToCancelledCode() }
    }

    public func test30_PartialStartRollback() throws {
        try runSync { try await ComputerUseHostTestRunner.run30_PartialStartRollback() }
    }

    public func test31_AcceptEINTRRetry() throws {
        try runSync { try await ComputerUseHostTestRunner.run31_AcceptEINTRRetry() }
    }

    public func test32_ReadHeaderBodyEINTRRetry() throws {
        try runSync { try await ComputerUseHostTestRunner.run32_ReadHeaderBodyEINTRRetry() }
    }

    public func test33_WriteResponseEAGAINDeadlineAndSingleAttempt() throws {
        try runSync { try await ComputerUseHostTestRunner.run33_WriteResponseEAGAINDeadlineAndSingleAttempt() }
    }

    public func test34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout() throws {
        try runSync { try await ComputerUseHostTestRunner.run34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout() }
    }

    public func test35_InjectedListenFailurePostBindRollback() throws {
        try runSync { try await ComputerUseHostTestRunner.run35_InjectedListenFailurePostBindRollback() }
    }

    public static let __allTests = [
        ("test01_LengthPrefixedFraming", test01_LengthPrefixedFraming),
        ("test02_OversizedFramingHeaderRejection", test02_OversizedFramingHeaderRejection),
        ("test03_DirectoryPreparation", test03_DirectoryPreparation),
        ("test04_UDSClientServerRoundTrip", test04_UDSClientServerRoundTrip),
        ("test05_PostTimeoutUDSRecovery", test05_PostTimeoutUDSRecovery),
        ("test06_SlowDripHeaderTimeout", test06_SlowDripHeaderTimeout),
        ("test07_SlowDripBodyTimeout", test07_SlowDripBodyTimeout),
        ("test08_BlockedResponseWriteTimeout", test08_BlockedResponseWriteTimeout),
        ("test09_PeerCloseAndPartialIO", test09_PeerCloseAndPartialIO),
        ("test10_EINTRRetryPath", test10_EINTRRetryPath),
        ("test11_TimeoutResponseFollowedByNextClient", test11_TimeoutResponseFollowedByNextClient),
        ("test12_LiveSocketCollisionProbe", test12_LiveSocketCollisionProbe),
        ("test13_VerifiedStaleSocketRecovery", test13_VerifiedStaleSocketRecovery),
        ("test14_ForeignSymlinkNonSocketRefusal", test14_ForeignSymlinkNonSocketRefusal),
        ("test15_StopNeverUnlinksReplacementInode", test15_StopNeverUnlinksReplacementInode),
        ("test16_IEEE754BitPatternTopologyGoldenVectorAndMutations", test16_IEEE754BitPatternTopologyGoldenVectorAndMutations),
        ("test17_HotPlugSafeDisplayEnumerator", test17_HotPlugSafeDisplayEnumerator),
        ("test18_PermissionPreflightDeniedZeroLoaderCalls", test18_PermissionPreflightDeniedZeroLoaderCalls),
        ("test19_PureJPEGValidatorExactAndNear10MiBBoundaries", test19_PureJPEGValidatorExactAndNear10MiBBoundaries),
        ("test20_SOF0AndSOF2MarkerValidation", test20_SOF0AndSOF2MarkerValidation),
        ("test21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection", test21_JPEGInvalidMagicTruncatedSegmentAndMismatchRejection),
        ("test22_NoncooperativeLateCompletionGenerationFence", test22_NoncooperativeLateCompletionGenerationFence),
        ("test23_StaleOperationGenerationFence", test23_StaleOperationGenerationFence),
        ("test24_RequesterCancellation", test24_RequesterCancellation),
        ("test25_TimedOutOrphanCapacity", test25_TimedOutOrphanCapacity),
        ("test26_TopologyChangeDuringCaptureDiscarded", test26_TopologyChangeDuringCaptureDiscarded),
        ("test27_DisabledActionsAndAXTreeRejection", test27_DisabledActionsAndAXTreeRejection),
        ("test28_DisplayIdParameterValidation", test28_DisplayIdParameterValidation),
        ("test29_CancellationErrorMappedToCancelledCode", test29_CancellationErrorMappedToCancelledCode),
        ("test30_PartialStartRollback", test30_PartialStartRollback),
        ("test31_AcceptEINTRRetry", test31_AcceptEINTRRetry),
        ("test32_ReadHeaderBodyEINTRRetry", test32_ReadHeaderBodyEINTRRetry),
        ("test33_WriteResponseEAGAINDeadlineAndSingleAttempt", test33_WriteResponseEAGAINDeadlineAndSingleAttempt),
        ("test34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout", test34_PositiveByteAdvancesClockPastDeadlineReturnsTimeout),
    ]
}
#endif
