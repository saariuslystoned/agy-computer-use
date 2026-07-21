import Foundation

public struct DisplayInfo: Codable, Equatable {
    public let id: Int
    public let widthPoints: Double
    public let heightPoints: Double
    public let scaleFactor: Double
    public let originX: Double
    public let originY: Double

    public init(id: Int, widthPoints: Double, heightPoints: Double, scaleFactor: Double, originX: Double, originY: Double) {
        self.id = id
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.scaleFactor = scaleFactor
        self.originX = originX
        self.originY = originY
    }
}

public struct DisplayTopology: Codable, Equatable {
    public let version: String
    public let primaryDisplayId: Int
    public let displays: [DisplayInfo]

    public init(version: String, primaryDisplayId: Int, displays: [DisplayInfo]) {
        self.version = version
        self.primaryDisplayId = primaryDisplayId
        self.displays = displays
    }
}

public struct Point2D: Codable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CoordinateMapper {
    public static let gridMin = 0
    public static let gridMax = 999
    public static let gridDivisor = 1000.0

    public static func validateGridCoordinates(x: Int, y: Int) throws {
        guard x >= gridMin && x <= gridMax && y >= gridMin && y <= gridMax else {
            throw ComputerUseError.outOfBounds(x: x, y: y, limitX: gridMax, limitY: gridMax)
        }
    }

    /// Maps normalized [0...999] integer coordinates to logical points in screen space.
    /// Uses floor(grid / 1000.0 * dimension) so that grid 999 strictly remains inside half-open display bounds [origin, origin + dimension).
    public static func gridToLogicalPoint(gridX: Int, gridY: Int, display: DisplayInfo) throws -> Point2D {
        try validateGridCoordinates(x: gridX, y: gridY)

        let offsetX = floor(Double(gridX) / gridDivisor * display.widthPoints)
        let offsetY = floor(Double(gridY) / gridDivisor * display.heightPoints)

        let pointX = display.originX + offsetX
        let pointY = display.originY + offsetY

        return Point2D(x: pointX, y: pointY)
    }

    /// Inverse mapping from logical screen points to normalized [0...999] grid coordinates.
    public static func logicalPointToGrid(pointX: Double, pointY: Double, display: DisplayInfo) -> Point2D {
        let relX = pointX - display.originX
        let relY = pointY - display.originY

        let gridX = max(0.0, min(Double(gridMax), round(relX / display.widthPoints * gridDivisor)))
        let gridY = max(0.0, min(Double(gridMax), round(relY / display.heightPoints * gridDivisor)))

        return Point2D(x: gridX, y: gridY)
    }

    public static func logicalPointToPhysicalPixels(point: Point2D, display: DisplayInfo) -> Point2D {
        return Point2D(
            x: (point.x - display.originX) * display.scaleFactor,
            y: (point.y - display.originY) * display.scaleFactor
        )
    }
}
