import CoreGraphics
import Foundation

public struct NormalizedPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }
    public var isNormalized: Bool { isFinite && (0...1).contains(x) && (0...1).contains(y) }
    public func clamped() -> Self { .init(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }
}

public struct BoundingBox: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.init(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: NormalizedPoint { .init(x: x + width / 2, y: y + height / 2) }
    public var area: Double { max(0, width) * max(0, height) }
    public var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }
    public var isValid: Bool { isFinite && width > 0 && height > 0 }
    public var isNormalized: Bool {
        isValid && minX >= 0 && minY >= 0 && maxX <= 1 && maxY <= 1
    }

    public func clamped() -> Self {
        let left = min(max(minX, 0), 1)
        let top = min(max(minY, 0), 1)
        let right = min(max(maxX, 0), 1)
        let bottom = min(max(maxY, 0), 1)
        return .init(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    public func intersectionOverUnion(with other: Self) -> Double {
        let intersectionWidth = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let intersectionHeight = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        let intersection = intersectionWidth * intersectionHeight
        let union = area + other.area - intersection
        return union > 0 ? intersection / union : 0
    }
}

public struct Polygon: Codable, Hashable, Sendable {
    public var points: [NormalizedPoint]

    public init(points: [NormalizedPoint]) {
        self.points = points
    }

    public var signedArea: Double {
        guard points.count >= 3 else { return 0 }
        return zip(points, Array(points.dropFirst()) + Array(points.prefix(1))).reduce(0) { result, pair in
            result + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        } / 2
    }

    public var area: Double { abs(signedArea) }

    public var bounds: BoundingBox? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var validationIssues: [PolygonValidationIssue] {
        var issues: [PolygonValidationIssue] = []
        if points.count < 3 { issues.append(.tooFewPoints) }
        if points.contains(where: { !$0.isFinite }) { issues.append(.nonFinitePoint) }
        if points.contains(where: { !$0.isNormalized }) { issues.append(.outOfBounds) }
        if area <= 1e-12 { issues.append(.zeroArea) }
        if hasSelfIntersection { issues.append(.selfIntersecting) }
        return issues
    }

    public var isValid: Bool { validationIssues.isEmpty }

    public func simplified(tolerance: Double) -> Self {
        guard points.count > 3, tolerance > 0 else { return self }
        let closed = points + [points[0]]
        var simplified = Self.douglasPeucker(closed, tolerance: tolerance)
        if simplified.first == simplified.last { simplified.removeLast() }
        return simplified.count >= 3 ? .init(points: simplified) : self
    }

    private var hasSelfIntersection: Bool {
        guard points.count >= 4 else { return false }
        for firstIndex in points.indices {
            let firstNext = (firstIndex + 1) % points.count
            for secondIndex in points.indices where secondIndex > firstIndex {
                let secondNext = (secondIndex + 1) % points.count
                if firstIndex == secondNext || firstNext == secondIndex { continue }
                if firstIndex == 0 && secondNext == 0 { continue }
                if Self.segmentsIntersect(points[firstIndex], points[firstNext], points[secondIndex], points[secondNext]) {
                    return true
                }
            }
        }
        return false
    }

    private static func segmentsIntersect(
        _ a: NormalizedPoint, _ b: NormalizedPoint,
        _ c: NormalizedPoint, _ d: NormalizedPoint
    ) -> Bool {
        func cross(_ p: NormalizedPoint, _ q: NormalizedPoint, _ r: NormalizedPoint) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let values = (cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b))
        return values.0 * values.1 < 0 && values.2 * values.3 < 0
    }

    private static func douglasPeucker(_ points: [NormalizedPoint], tolerance: Double) -> [NormalizedPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maximumDistance = 0.0
        var index = 0
        for candidateIndex in 1..<(points.count - 1) {
            let distance = perpendicularDistance(points[candidateIndex], from: first, to: last)
            if distance > maximumDistance {
                maximumDistance = distance
                index = candidateIndex
            }
        }
        guard maximumDistance > tolerance else { return [first, last] }
        let left = douglasPeucker(Array(points[0...index]), tolerance: tolerance)
        let right = douglasPeucker(Array(points[index...]), tolerance: tolerance)
        return Array(left.dropLast()) + right
    }

    private static func perpendicularDistance(
        _ point: NormalizedPoint, from start: NormalizedPoint, to end: NormalizedPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }
}

public enum PolygonValidationIssue: String, Codable, Sendable {
    case tooFewPoints
    case nonFinitePoint
    case outOfBounds
    case zeroArea
    case selfIntersecting
}

public enum AnnotationGeometry: Codable, Hashable, Sendable {
    case boundingBox(BoundingBox)
    case polygon(Polygon)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case boundingBox, polygon }

    public var bounds: BoundingBox? {
        switch self {
        case let .boundingBox(box): box
        case let .polygon(polygon): polygon.bounds
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .boundingBox: self = .boundingBox(try container.decode(BoundingBox.self, forKey: .value))
        case .polygon: self = .polygon(try container.decode(Polygon.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boundingBox(box):
            try container.encode(Kind.boundingBox, forKey: .type)
            try container.encode(box, forKey: .value)
        case let .polygon(polygon):
            try container.encode(Kind.polygon, forKey: .type)
            try container.encode(polygon, forKey: .value)
        }
    }
}
