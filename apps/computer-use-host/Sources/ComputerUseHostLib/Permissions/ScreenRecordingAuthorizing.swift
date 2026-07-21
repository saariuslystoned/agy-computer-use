import Foundation
import CoreGraphics

public protocol ScreenRecordingAuthorizing: Sendable {
    var isScreenCaptureAccessGranted: Bool { get }
}

public struct CGScreenRecordingAuthorizer: ScreenRecordingAuthorizing {
    public init() {}

    public var isScreenCaptureAccessGranted: Bool {
        return CGPreflightScreenCaptureAccess()
    }
}

public struct FakeScreenRecordingAuthorizer: ScreenRecordingAuthorizing {
    public let granted: Bool

    public init(granted: Bool = true) {
        self.granted = granted
    }

    public var isScreenCaptureAccessGranted: Bool {
        return granted
    }
}
