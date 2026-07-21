import Foundation
import CoreGraphics
import CryptoKit

public protocol DisplayListEnumerating: Sendable {
    func getActiveDisplays() throws -> (primaryId: Int, displayIDs: [Int])
}

public struct CGDisplayListEnumerator: DisplayListEnumerating {
    public init() {}

    public func getActiveDisplays() throws -> (primaryId: Int, displayIDs: [Int]) {
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

        let validCount = Int(actualCount)
        guard validCount > 0, validCount <= activeDisplays.count else {
            throw ComputerUseError.targetUnreachable(reason: "Display count mismatch or invalid count (\(validCount))")
        }

        let slice = activeDisplays.prefix(validCount)
        var seen = Set<Int>()
        var validIDs: [Int] = []

        for rawId in slice {
            let id = Int(rawId)
            guard id != 0 else {
                throw ComputerUseError.targetUnreachable(reason: "Display list contained invalid zero ID")
            }
            guard !seen.contains(id) else {
                throw ComputerUseError.targetUnreachable(reason: "Display list contained duplicate display ID \(id)")
            }
            seen.insert(id)
            validIDs.append(id)
        }

        let primaryCGId = CGMainDisplayID()
        let primaryId = Int(primaryCGId)
        guard primaryId != 0, validIDs.contains(primaryId) else {
            throw ComputerUseError.targetUnreachable(reason: "Primary display ID \(primaryId) missing from active display list")
        }

        return (primaryId, validIDs)
    }
}

public protocol DisplayTopologyProviding: Sendable {
    func getTopology() throws -> DisplayTopology
}

public struct SystemDisplayTopologyProvider: DisplayTopologyProviding {
    private let enumerator: DisplayListEnumerating

    public init(enumerator: DisplayListEnumerating = CGDisplayListEnumerator()) {
        self.enumerator = enumerator
    }

    public func getTopology() throws -> DisplayTopology {
        let (primaryId, validIDs) = try enumerator.getActiveDisplays()
        var displayInfos: [DisplayInfo] = []

        for id in validIDs {
            let dID = CGDirectDisplayID(id)
            let bounds = CGDisplayBounds(dID)
            let rotation = Double(CGDisplayRotation(dID))

            guard bounds.width.isFinite, bounds.height.isFinite, bounds.origin.x.isFinite, bounds.origin.y.isFinite, rotation.isFinite else {
                throw ComputerUseError.targetUnreachable(reason: "Display ID \(id) has non-finite geometry or rotation")
            }
            guard bounds.width > 0, bounds.height > 0 else {
                throw ComputerUseError.targetUnreachable(reason: "Display ID \(id) has non-positive logical dimensions (\(bounds.width)x\(bounds.height))")
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
                throw ComputerUseError.targetUnreachable(reason: "Display ID \(id) has invalid scale or pixel dimensions")
            }

            let info = DisplayInfo(
                id: id,
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
            let oxHex = String(format: "%016x", d.originX.bitPattern)
            let oyHex = String(format: "%016x", d.originY.bitPattern)
            let wHex = String(format: "%016x", d.widthPoints.bitPattern)
            let hHex = String(format: "%016x", d.heightPoints.bitPattern)
            let sHex = String(format: "%016x", d.scaleFactor.bitPattern)
            let rHex = String(format: "%016x", d.rotation.bitPattern)
            canonicalString += "id:\(d.id),ox:\(oxHex),oy:\(oyHex),w:\(wHex),h:\(hHex),s:\(sHex),pw:\(d.pixelWidth),ph:\(d.pixelHeight),r:\(rHex);"
        }
        let digest = SHA256.hash(data: Data(canonicalString.utf8))
        let hexString = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "top-sha256-\(hexString)"
    }
}
