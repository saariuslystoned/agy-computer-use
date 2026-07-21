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
