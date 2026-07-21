import Foundation
import CoreGraphics
import CryptoKit

public protocol DisplayTopologyProviding: Sendable {
    func getTopology() throws -> DisplayTopology
}

public struct SystemDisplayTopologyProvider: DisplayTopologyProviding {
    public init() {}

    public func getTopology() throws -> DisplayTopology {
        var displayCount: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countResult == .success, displayCount > 0 else {
            throw ComputerUseError.targetUnreachable(reason: "No active displays found via CGGetActiveDisplayList")
        }

        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listResult = CGGetActiveDisplayList(displayCount, &activeDisplays, &displayCount)
        guard listResult == .success else {
            throw ComputerUseError.targetUnreachable(reason: "Failed to retrieve active display list")
        }

        let primaryId = Int(CGMainDisplayID())
        var displayInfos: [DisplayInfo] = []

        for dID in activeDisplays {
            let bounds = CGDisplayBounds(dID)
            let rotation = Double(CGDisplayRotation(dID))

            var pixelW = Int(bounds.width)
            var pixelH = Int(bounds.height)
            var scale = 1.0

            if let mode = CGDisplayCopyDisplayMode(dID) {
                pixelW = mode.pixelWidth
                pixelH = mode.pixelHeight
                if bounds.width > 0 {
                    scale = Double(mode.pixelWidth) / bounds.width
                }
            }

            let info = DisplayInfo(
                id: Int(dID),
                widthPoints: bounds.width,
                heightPoints: bounds.height,
                scaleFactor: scale,
                originX: bounds.origin.x,
                originY: bounds.origin.y,
                pixelWidth: pixelW,
                pixelHeight: pixelH,
                rotation: rotation
            )
            displayInfos.append(info)
        }

        let sortedDisplays = displayInfos.sorted { $0.id < $1.id }
        let version = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: primaryId, displays: sortedDisplays)

        return DisplayTopology(
            version: version,
            primaryDisplayId: primaryId,
            displays: sortedDisplays
        )
    }

    public static func computeTopologyVersion(primaryId: Int, displays: [DisplayInfo]) -> String {
        let sorted = displays.sorted { $0.id < $1.id }
        var canonicalString = "primary:\(primaryId);"
        for d in sorted {
            canonicalString += "id:\(d.id),w:\(d.widthPoints),h:\(d.heightPoints),s:\(d.scaleFactor),ox:\(d.originX),oy:\(d.originY),pw:\(d.pixelWidth),ph:\(d.pixelHeight),r:\(d.rotation);"
        }
        let digest = SHA256.hash(data: Data(canonicalString.utf8))
        let hexString = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "top-sha256-\(hexString.prefix(16))"
    }
}

public struct FakeDisplayTopologyProvider: DisplayTopologyProviding {
    public let topology: DisplayTopology

    public init(topology: DisplayTopology? = nil) {
        if let t = topology {
            self.topology = t
        } else {
            let defaultDisplays = [
                DisplayInfo(id: 1, widthPoints: 1920, heightPoints: 1080, scaleFactor: 2.0, originX: 0, originY: 0, pixelWidth: 3840, pixelHeight: 2160, rotation: 0.0)
            ]
            let ver = "top-v1"
            self.topology = DisplayTopology(version: ver, primaryDisplayId: 1, displays: defaultDisplays)
        }
    }

    public func getTopology() throws -> DisplayTopology {
        return topology
    }
}
