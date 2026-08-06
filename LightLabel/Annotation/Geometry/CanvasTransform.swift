import CoreGraphics
import Foundation

public struct CanvasTransform: Hashable, Sendable {
    public enum ContentMode: Sendable { case aspectFit, aspectFill }

    public let imageSize: PixelSize
    public let canvasSize: CGSize
    public let scale: CGFloat
    public let imageFrame: CGRect

    public init(imageSize: PixelSize, canvasSize: CGSize, contentMode: ContentMode = .aspectFit) {
        self.imageSize = imageSize
        self.canvasSize = canvasSize
        guard imageSize.isValid, canvasSize.width > 0, canvasSize.height > 0 else {
            scale = 0
            imageFrame = .zero
            return
        }
        let horizontal = canvasSize.width / CGFloat(imageSize.width)
        let vertical = canvasSize.height / CGFloat(imageSize.height)
        scale = contentMode == .aspectFit ? min(horizontal, vertical) : max(horizontal, vertical)
        let rendered = CGSize(width: CGFloat(imageSize.width) * scale, height: CGFloat(imageSize.height) * scale)
        imageFrame = CGRect(
            x: (canvasSize.width - rendered.width) / 2,
            y: (canvasSize.height - rendered.height) / 2,
            width: rendered.width,
            height: rendered.height
        )
    }

    public func canvasPoint(from normalized: NormalizedPoint) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + CGFloat(normalized.x) * imageFrame.width,
            y: imageFrame.minY + CGFloat(normalized.y) * imageFrame.height
        )
    }

    public func normalizedPoint(from canvas: CGPoint, clamp: Bool = false) -> NormalizedPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .init(x: 0, y: 0) }
        let point = NormalizedPoint(
            x: Double((canvas.x - imageFrame.minX) / imageFrame.width),
            y: Double((canvas.y - imageFrame.minY) / imageFrame.height)
        )
        return clamp ? point.clamped() : point
    }

    public func canvasRect(from box: BoundingBox) -> CGRect {
        CGRect(
            x: imageFrame.minX + CGFloat(box.x) * imageFrame.width,
            y: imageFrame.minY + CGFloat(box.y) * imageFrame.height,
            width: CGFloat(box.width) * imageFrame.width,
            height: CGFloat(box.height) * imageFrame.height
        )
    }

    public func normalizedBox(from canvas: CGRect, clamp: Bool = false) -> BoundingBox {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .init(x: 0, y: 0, width: 0, height: 0) }
        let box = BoundingBox(
            x: Double((canvas.minX - imageFrame.minX) / imageFrame.width),
            y: Double((canvas.minY - imageFrame.minY) / imageFrame.height),
            width: Double(canvas.width / imageFrame.width),
            height: Double(canvas.height / imageFrame.height)
        )
        return clamp ? box.clamped() : box
    }

    public func pixelPoint(from normalized: NormalizedPoint) -> CGPoint {
        CGPoint(x: CGFloat(normalized.x) * CGFloat(imageSize.width), y: CGFloat(normalized.y) * CGFloat(imageSize.height))
    }

    public func normalizedPoint(fromPixel point: CGPoint) -> NormalizedPoint {
        guard imageSize.isValid else { return .init(x: 0, y: 0) }
        return .init(x: Double(point.x) / Double(imageSize.width), y: Double(point.y) / Double(imageSize.height))
    }
}
