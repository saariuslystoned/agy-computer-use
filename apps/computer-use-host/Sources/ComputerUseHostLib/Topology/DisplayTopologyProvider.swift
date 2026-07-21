import Foundation
import CoreGraphics
import CryptoKit

public protocol DisplayTopologyProviding: Sendable {
    func getTopology() throws -> DisplayTopology
}

public struct SystemDisplayTopologyProvider: DisplayTopologyProviding {
    public init() {}

    public func getTopology() throws -> DisplayTopology {
        var maxCount: UInt32 = 0
        let countRes = CGGetActiveDisplayList(0, nil, &maxCount)
        guard countRes == .success, maxCount > 0 else {
            throw ComputerUseError.targetUnreachable(reason: "No active displays reported by CGGetActiveDisplayList")
        }

        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxCount))
        var actualCount: UInt32 = 0
        let listRes = CGGetActiveDisplayList(maxCount, &activeDisplays, &actualCount)
        guard listRes == .success, actualCount > 0 else {
            throw ComputerUseError.targetUnreachable(reason: "Failed to fetch active display list")
        }

        let validCount = min(Int(actualCount), activeDisplays.count)
        let validDisplayIDs = activeDisplays.prefix(validCount).filter { $0 != 0 }
        guard !validDisplayIDs.isEmpty else {
            throw ComputerUseError.targetUnreachable(reason: "Active display list contains zero valid display IDs")
        }

        let primaryCGId = CGMainDisplayID()
        guard primaryCGId != 0, validDisplayIDs.contains(primaryCGId) else {
            throw ComputerUseError.targetUnreachable(reason: "Primary display ID \(primaryCGId) missing from active display list")
        }

        let primaryId = Int(primaryCGId)
        var displayInfos: [DisplayInfo] = []

        for dID in validDisplayIDs {
            let bounds = CGDisplayBounds(dID)
            let rotation = Double(CGDisplayRotation(dID))

            guard bounds.width.isFinite, bounds.height.isFinite, bounds.origin.x.isFinite, bounds.origin.y.isFinite, rotation.isFinite else {
                throw ComputerUseError.targetUnreachable(reason: "Display ID \(dID) has non-finite geometry or rotation")
            }
            guard bounds.width > 0, bounds.height > 0 else {
                throw ComputerUseError.targetUnreachable(reason: "Display ID \(dID) has non-positive logical dimensions (\(bounds.width)x\(bounds.height))")
            }

            var pixelW = Int(bounds.width)
            var pixelH = Int(bounds.height)
            var scale = 1.0

            if let mode = CGDisplayCopyDisplayMode(dID) {
                let mw = mode.pixelWidth
                let mh = mode.pixelHeight
                if mw > 0 && mh > 0 {
                    pixelW = mw
                    pixelH = mh
                    scale = Double(mw) / bounds.width
                }
            }

            guard scale.isFinite, scale > 0, pixelW > 0, pixelH > 0 else {
                throw ComputerUseError.targetUnreachable(reason: "Display ID \(dID) has invalid scale or pixel dimensions")
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
            let ox = String(format: "%.4f", d.originX)
            let oy = String(format: "%.4f", d.originY)
            let w = String(format: "%.4f", d.widthPoints)
            let h = String(format: "%.4f", d.heightPoints)
            let s = String(format: "%.4f", d.scaleFactor)
            let r = String(format: "%.4f", d.rotation)
            canonicalString += "id:\(d.id),ox:\(ox),oy:\(oy),w:\(w),h:\(h),s:\(s),pw:\(d.pixelWidth),ph:\(d.pixelHeight),r:\(r);"
        }
        let digest = SHA256.hash(data: Data(canonicalString.utf8))
        let hexString = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "top-sha256-\(hexString)"
    }
}
