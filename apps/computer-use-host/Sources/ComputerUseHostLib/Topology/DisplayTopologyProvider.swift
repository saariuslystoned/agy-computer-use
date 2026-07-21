import Foundation
import CoreGraphics
import CryptoKit

public protocol DisplayListEnumerating: Sendable {
    func getActiveDisplays() throws -> (primaryId: Int, displayIDs: [Int])
}

public struct CGDisplayListEnumerator: DisplayListEnumerating {
    public init() {}

    public func getActiveDisplays() throws -> (primaryId: Int, displayIDs: [Int]) {
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            var maxCount: UInt32 = 0
            let countRes = CGGetActiveDisplayList(0, nil, &maxCount)
            guard countRes == .success, maxCount > 0 else {
                if attempts < 3 { continue }
                throw ComputerUseError.targetUnreachable(reason: "No active displays reported by CGGetActiveDisplayList")
            }

            var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxCount))
            var actualCount: UInt32 = 0
            let listRes = CGGetActiveDisplayList(maxCount, &activeDisplays, &actualCount)
            guard listRes == .success, actualCount > 0 else {
                if attempts < 3 { continue }
                throw ComputerUseError.targetUnreachable(reason: "Failed to fetch active display list")
            }

            let validCount = Int(actualCount)
            guard validCount > 0, validCount <= activeDisplays.count else {
                if attempts < 3 { continue }
                throw ComputerUseError.targetUnreachable(reason: "Display count mismatch or invalid count (\(validCount))")
            }

            let slice = activeDisplays.prefix(validCount)
            let validIDs = slice.map { Int($0) }
            let primaryId = Int(CGMainDisplayID())

            return (primaryId, validIDs)
        }
        throw ComputerUseError.targetUnreachable(reason: "Exhausted retries on display list enumeration")
    }
}

public protocol DisplayDescriptorProviding: Sendable {
    func getDisplayDescriptor(id: Int) throws -> (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double)
}

public struct CGDisplayDescriptorProvider: DisplayDescriptorProviding {
    public init() {}

    public func getDisplayDescriptor(id: Int) throws -> (bounds: CGRect, rotation: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        let dID = CGDirectDisplayID(id)
        let bounds = CGDisplayBounds(dID)
        let rotation = Double(CGDisplayRotation(dID))

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

        return (bounds, rotation, pixelW, pixelH, scale)
    }
}

public protocol DisplayTopologyProviding: Sendable {
    func getTopology() throws -> DisplayTopology
}

public struct SystemDisplayTopologyProvider: DisplayTopologyProviding {
    private let enumerator: DisplayListEnumerating
    private let descriptorProvider: DisplayDescriptorProviding

    public init(
        enumerator: DisplayListEnumerating = CGDisplayListEnumerator(),
        descriptorProvider: DisplayDescriptorProviding = CGDisplayDescriptorProvider()
    ) {
        self.enumerator = enumerator
        self.descriptorProvider = descriptorProvider
    }

    public func getTopology() throws -> DisplayTopology {
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            do {
                // Pass 1: Count & fill list 1
                let (primary1, list1) = try enumerator.getActiveDisplays()
                let infosA = try fetchDescriptors(validIDs: list1, primaryId: primary1)

                // Pass 2: Count & fill list 2
                let (primary2, list2) = try enumerator.getActiveDisplays()
                guard primary1 == primary2 && list1 == list2 else {
                    if attempts < 3 { continue }
                    throw ComputerUseError.targetUnreachable(reason: "Topology unstable: display list changed between pass 1 and pass 2")
                }

                let infosB = try fetchDescriptors(validIDs: list2, primaryId: primary2)
                guard fingerprintsMatch(infosA, infosB) else {
                    if attempts < 3 { continue }
                    throw ComputerUseError.targetUnreachable(reason: "Topology unstable: display descriptors changed between set A and set B")
                }

                // Pass 3: Final list pass 3
                let (primary3, list3) = try enumerator.getActiveDisplays()
                guard primary1 == primary3 && list1 == list3 else {
                    if attempts < 3 { continue }
                    throw ComputerUseError.targetUnreachable(reason: "Topology unstable: display list changed on final pass 3")
                }

                let sortedDisplays = infosB.sorted { $0.id < $1.id }
                let version = SystemDisplayTopologyProvider.computeTopologyVersion(primaryId: primary1, displays: sortedDisplays)

                return DisplayTopology(
                    version: version,
                    primaryDisplayId: primary1,
                    displays: sortedDisplays
                )
            } catch {
                if attempts < 3 { continue }
                throw error
            }
        }
        throw ComputerUseError.targetUnreachable(reason: "Exhausted retries due to topology instability")
    }

    private func fetchDescriptors(validIDs: [Int], primaryId: Int) throws -> [DisplayInfo] {
        guard !validIDs.isEmpty else {
            throw ComputerUseError.targetUnreachable(reason: "Display list is empty")
        }

        var seen = Set<Int>()
        for id in validIDs {
            guard id != 0 else {
                throw ComputerUseError.targetUnreachable(reason: "Display list contained invalid zero ID")
            }
            guard !seen.contains(id) else {
                throw ComputerUseError.targetUnreachable(reason: "Display list contained duplicate display ID \(id)")
            }
            seen.insert(id)
        }

        guard primaryId != 0, validIDs.contains(primaryId) else {
            throw ComputerUseError.targetUnreachable(reason: "Primary display ID \(primaryId) missing from active display list")
        }

        var displayInfos: [DisplayInfo] = []
        for id in validIDs {
            let (bounds, rotation, pixelW, pixelH, scale) = try descriptorProvider.getDisplayDescriptor(id: id)

            guard bounds.width.isFinite, bounds.height.isFinite, bounds.origin.x.isFinite, bounds.origin.y.isFinite, rotation.isFinite else {
                throw ComputerUseError.targetUnreachable(reason: "Display ID \(id) has non-finite geometry or rotation")
            }
            guard bounds.width > 0, bounds.height > 0 else {
                throw ComputerUseError.targetUnreachable(reason: "Display ID \(id) has non-positive logical dimensions (\(bounds.width)x\(bounds.height))")
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
        return displayInfos
    }

    private func fingerprintsMatch(_ setA: [DisplayInfo], _ setB: [DisplayInfo]) -> Bool {
        guard setA.count == setB.count else { return false }
        let mapA = Dictionary(uniqueKeysWithValues: setA.map { ($0.id, $0) })
        for b in setB {
            guard let a = mapA[b.id] else { return false }
            if a.originX.bitPattern != b.originX.bitPattern ||
               a.originY.bitPattern != b.originY.bitPattern ||
               a.widthPoints.bitPattern != b.widthPoints.bitPattern ||
               a.heightPoints.bitPattern != b.heightPoints.bitPattern ||
               a.scaleFactor.bitPattern != b.scaleFactor.bitPattern ||
               a.rotation.bitPattern != b.rotation.bitPattern ||
               a.pixelWidth != b.pixelWidth ||
               a.pixelHeight != b.pixelHeight {
                return false
            }
        }
        return true
    }

    public static func hexUInt64(_ val: UInt64) -> String {
        let hex = String(val, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    public static func normalizeZero(_ val: Double) -> Double {
        if val == 0.0 { return 0.0 }
        return val
    }

    public static func computeTopologyVersion(primaryId: Int, displays: [DisplayInfo]) -> String {
        let sorted = displays.sorted { $0.id < $1.id }
        var canonicalString = "primary:\(primaryId);"
        for d in sorted {
            let oxHex = hexUInt64(normalizeZero(d.originX).bitPattern)
            let oyHex = hexUInt64(normalizeZero(d.originY).bitPattern)
            let wHex = hexUInt64(normalizeZero(d.widthPoints).bitPattern)
            let hHex = hexUInt64(normalizeZero(d.heightPoints).bitPattern)
            let sHex = hexUInt64(normalizeZero(d.scaleFactor).bitPattern)
            let rHex = hexUInt64(normalizeZero(d.rotation).bitPattern)
            canonicalString += "id:\(d.id),ox:\(oxHex),oy:\(oyHex),w:\(wHex),h:\(hHex),s:\(sHex),pw:\(d.pixelWidth),ph:\(d.pixelHeight),r:\(rHex);"
        }
        let digest = SHA256.hash(data: Data(canonicalString.utf8))
        let hexString = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "top-sha256-\(hexString)"
    }
}
