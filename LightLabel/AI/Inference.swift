import CoreGraphics
import CoreML
import Foundation
import SAMKit
import Vision

public struct InferenceDetection: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var categoryIndex: Int
    public var label: String?
    public var confidence: Double
    public var boundingBox: BoundingBox

    public init(id: UUID = UUID(), categoryIndex: Int, label: String? = nil, confidence: Double, boundingBox: BoundingBox) {
        self.id = id; self.categoryIndex = categoryIndex; self.label = label; self.confidence = confidence; self.boundingBox = boundingBox
    }
}

public protocol ImageInferenceEngine: Sendable {
    func infer(image: CGImage) async throws -> [InferenceDetection]
}

public enum InferenceError: LocalizedError, Sendable {
    case modelLoading(String)
    case unsupportedOutput(String)
    case invalidTensorShape([Int])
    case vision(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .modelLoading(reason): "Could not load model: \(reason)"
        case let .unsupportedOutput(reason): "Unsupported model output: \(reason)"
        case let .invalidTensorShape(shape): "Invalid output tensor shape: \(shape)."
        case let .vision(reason): "Vision inference failed: \(reason)"
        case .cancelled: "Inference was cancelled."
        }
    }
}

/// Click-guided SAM segmentation for the Smart Polygon tool.
///
/// SAM2 Tiny is kept behind a small actor so Core ML sessions and their image
/// embeddings are reused safely across clicks. A prompt-centered crop is
/// tried first: this gives small objects more of the model's 1024px input
/// instead of making them compete with the full image. Vision remains a
/// fallback for machines where the bundled Core ML models cannot initialize.
public struct SmartPolygonSegmenter: Sendable {
    private static let sam2 = SAM2SegmentationService()

    public init() {}

    public func segment(image: CGImage, at point: NormalizedPoint) async throws -> Polygon {
        // The crop-first order is intentional for tiny objects. If the mask
        // touches the crop edge, the wider context prevents cutting off a
        // large object that happens to contain the prompt point.
        let cropFractions: [Double] = [0.38, 0.64, 1.0]
        let imageSize = CGSize(width: image.width, height: image.height)
        var fallback: Polygon?

        for fraction in cropFractions {
            let crop = Self.promptCrop(for: point, fraction: fraction, imageSize: imageSize)
            guard let croppedImage = image.cropping(to: crop), crop.width > 1, crop.height > 1 else { continue }
            let localPoint = NormalizedPoint(
                x: (point.x * Double(image.width) - crop.minX) / crop.width,
                y: (point.y * Double(image.height) - crop.minY) / crop.height
            )
            guard let localPolygon = try? await Self.sam2.segment(image: croppedImage, at: localPoint) else { continue }
            let polygon = Self.map(localPolygon, from: crop, imageSize: imageSize)
            fallback = polygon
            if fraction == 1 || !Self.touchesBoundary(localPolygon) { return polygon }
        }

        if let fallback { return fallback }
        // Keep a functional fallback if Core ML model resources are missing
        // or the current macOS Vision/Core ML stack rejects the model.
        return try await Task.detached(priority: .userInitiated) {
            guard let polygon = try? await Self.segmentVision(image, at: point) else {
                throw InferenceError.unsupportedOutput("SAM2 did not find an object at that point")
            }
            return polygon
        }.value
    }

    private static func segmentVision(_ image: CGImage, at point: NormalizedPoint) async throws -> Polygon {
        let handler = Vision.ImageRequestHandler(image)
        let request = Vision.GenerateForegroundInstanceMaskRequest()
        guard let observation = try await handler.perform(request) else {
            throw InferenceError.unsupportedOutput("Vision did not find a foreground object at that point")
        }

        // Vision's normalized coordinates use a lower-left origin while
        // LightLabel's geometry uses a top-left origin.
        let visionPoint = Vision.NormalizedPoint(x: CGFloat(point.x), y: CGFloat(1 - point.y))
        let instances = observation.instanceAtPoint(visionPoint)
        guard !instances.isEmpty else {
            throw InferenceError.unsupportedOutput("Click on the object you want to outline")
        }

        let mask = try observation.generateScaledMask(for: instances, scaledToImageFrom: handler)
        let maskHandler = Vision.ImageRequestHandler(mask)
        var contourRequest = Vision.DetectContoursRequest()
        contourRequest.contrastAdjustment = 1
        contourRequest.detectsDarkOnLight = false
        contourRequest.maximumImageDimension = 2048
        let contours = try await maskHandler.perform(contourRequest)
        guard let contour = contours.topLevelContours.max(by: { $0.calculateArea() < $1.calculateArea() }) else {
            throw InferenceError.unsupportedOutput("Vision returned an empty object mask")
        }

        let simplified = (try? contour.polygonApproximation(epsilon: 0.0025)) ?? contour
        let points = simplified.normalizedPoints.map {
            NormalizedPoint(x: Double($0.x), y: Double(1 - $0.y))
        }
        let polygon = Polygon(points: points).simplified(tolerance: 0.0005)
        guard polygon.isValid else {
            throw InferenceError.unsupportedOutput("Vision returned an invalid object mask")
        }
        return polygon
    }

    private static func promptCrop(for point: NormalizedPoint, fraction: Double, imageSize: CGSize) -> CGRect {
        let width = imageSize.width * fraction
        let height = imageSize.height * fraction
        let originX = min(max(point.x * imageSize.width - width / 2, 0), imageSize.width - width)
        let originY = min(max(point.y * imageSize.height - height / 2, 0), imageSize.height - height)
        return CGRect(x: originX, y: originY, width: width, height: height).integral
    }

    private static func map(_ polygon: Polygon, from crop: CGRect, imageSize: CGSize) -> Polygon {
        Polygon(points: polygon.points.map {
            .init(
                x: (crop.minX + $0.x * crop.width) / imageSize.width,
                y: (crop.minY + $0.y * crop.height) / imageSize.height
            )
        })
    }

    private static func touchesBoundary(_ polygon: Polygon) -> Bool {
        guard let bounds = polygon.bounds else { return true }
        let margin = 0.015
        return bounds.minX <= margin || bounds.minY <= margin || bounds.maxX >= 1 - margin || bounds.maxY >= 1 - margin
    }
}

private actor SAM2SegmentationService {
    private var session: Sam2Session?
    private var cachedImage: CGImage?
    private var cachedImageKey: String?

    func segment(image: CGImage, at point: NormalizedPoint) async throws -> Polygon {
        if session == nil {
            // SAMKit's `.bestAvailable` enables the Metal GPU path. On some
            // macOS/Apple GPU + FP16 combinations MPSGraph aborts the process
            // instead of returning an error. The Neural Engine path keeps SAM
            // responsive while avoiding that uncatchable driver failure.
            let config = RuntimeConfig(computeUnits: .neuralEnginePreferred, enableFP16: true)
            session = try Sam2Session(modelName: "SAM2Tiny", config: config)
        }

        let imageKey = "\(ObjectIdentifier(image as AnyObject)):\(image.width)x\(image.height)"
        if cachedImageKey != imageKey {
            try session?.setImage(image)
            // Retain the image while its embedding is cached. This prevents
            // allocator address reuse from making a later CGImage look like
            // the same embedding.
            cachedImage = image
            cachedImageKey = imageKey
        }

        guard let session else {
            throw InferenceError.modelLoading("SAM2 Tiny session could not be created")
        }
        let result = try session.predict(
            points: [SamPoint(x: CGFloat(point.x * Double(image.width)), y: CGFloat(point.y * Double(image.height)), label: .positive)],
            options: SamOptions(multimaskOutput: true, returnLogits: false, maskThreshold: 0, maxMasks: 3)
        )
        guard let mask = result.masks.max(by: { $0.score < $1.score }) else {
            throw InferenceError.unsupportedOutput("SAM2 returned no masks")
        }
        let payload = MaskPayload(width: mask.width, height: mask.height, alpha: mask.alpha)
        return try await Self.polygon(from: payload)
    }

    private static func polygon(from mask: MaskPayload) async throws -> Polygon {
        guard let maskImage = binaryMaskImage(mask) else {
            throw InferenceError.unsupportedOutput("SAM2 returned an invalid mask")
        }
        let handler = Vision.ImageRequestHandler(maskImage)
        var request = Vision.DetectContoursRequest()
        request.contrastAdjustment = 1
        request.detectsDarkOnLight = false
        request.maximumImageDimension = 2048
        let contours = try await handler.perform(request)
        guard let contour = contours.topLevelContours.max(by: { $0.calculateArea() < $1.calculateArea() }) else {
            throw InferenceError.unsupportedOutput("SAM2 returned an empty mask")
        }
        let simplified = (try? contour.polygonApproximation(epsilon: 0.0025)) ?? contour
        let polygon = Polygon(points: simplified.normalizedPoints.map {
            // Vision contours use a lower-left origin; dataset geometry uses
            // a top-left origin.
            NormalizedPoint(x: Double($0.x), y: Double(1 - $0.y))
        }).simplified(tolerance: 0.0005)
        guard polygon.isValid else {
            throw InferenceError.unsupportedOutput("SAM2 returned an invalid polygon")
        }
        return polygon
    }

    private struct MaskPayload: Sendable {
        let width: Int
        let height: Int
        let alpha: Data
    }

    private static func binaryMaskImage(_ mask: MaskPayload) -> CGImage? {
        var alpha = Data(count: mask.width * mask.height)
        alpha.withUnsafeMutableBytes { destination in
            guard let destination = destination.bindMemory(to: UInt8.self).baseAddress else { return }
            mask.alpha.withUnsafeBytes { source in
                guard let source = source.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<min(mask.width * mask.height, mask.alpha.count) {
                    destination[index] = source[index] >= 128 ? 255 : 0
                }
            }
        }
        guard let provider = CGDataProvider(data: alpha as CFData) else { return nil }
        return CGImage(
            width: mask.width,
            height: mask.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: mask.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

public struct NonMaximumSuppression: Sendable {
    public var intersectionOverUnionThreshold: Double
    public var classAgnostic: Bool

    public init(intersectionOverUnionThreshold: Double = 0.45, classAgnostic: Bool = false) {
        self.intersectionOverUnionThreshold = intersectionOverUnionThreshold; self.classAgnostic = classAgnostic
    }

    public func apply(to detections: [InferenceDetection]) -> [InferenceDetection] {
        var candidates = detections.sorted { $0.confidence > $1.confidence }
        var selected: [InferenceDetection] = []
        while !candidates.isEmpty {
            let best = candidates.removeFirst()
            selected.append(best)
            candidates.removeAll {
                (classAgnostic || $0.categoryIndex == best.categoryIndex) &&
                $0.boundingBox.intersectionOverUnion(with: best.boundingBox) > intersectionOverUnionThreshold
            }
        }
        return selected
    }
}

public struct RawYOLODecoder: Sendable {
    public enum TensorLayout: Sendable { case candidatesByChannels, channelsByCandidates }
    public enum BoxEncoding: Sendable { case centerXYWH, cornerXYXY }

    public var classCount: Int
    public var confidenceThreshold: Double
    public var layout: TensorLayout
    public var boxEncoding: BoxEncoding
    public var includesObjectness: Bool
    public var coordinatesAreNormalized: Bool
    public var inputSize: PixelSize?
    public var labels: [String]
    public var nms: NonMaximumSuppression

    public init(classCount: Int, confidenceThreshold: Double = 0.25, layout: TensorLayout = .channelsByCandidates, boxEncoding: BoxEncoding = .centerXYWH, includesObjectness: Bool = false, coordinatesAreNormalized: Bool = true, inputSize: PixelSize? = nil, labels: [String] = [], nms: NonMaximumSuppression = .init()) {
        self.classCount = classCount; self.confidenceThreshold = confidenceThreshold; self.layout = layout; self.boxEncoding = boxEncoding; self.includesObjectness = includesObjectness; self.coordinatesAreNormalized = coordinatesAreNormalized; self.inputSize = inputSize; self.labels = labels; self.nms = nms
    }

    public func decode(_ tensor: MLMultiArray) throws -> [InferenceDetection] {
        let shape = tensor.shape.map(\.intValue)
        let dimensions = shape.filter { $0 != 1 }
        guard dimensions.count == 2 else { throw InferenceError.invalidTensorShape(shape) }
        let channelCount = 4 + (includesObjectness ? 1 : 0) + classCount
        let candidates: Int
        switch layout {
        case .candidatesByChannels:
            guard dimensions[1] == channelCount else { throw InferenceError.invalidTensorShape(shape) }
            candidates = dimensions[0]
        case .channelsByCandidates:
            guard dimensions[0] == channelCount else { throw InferenceError.invalidTensorShape(shape) }
            candidates = dimensions[1]
        }
        let effectiveShape = shape
        let nonUnitIndices = effectiveShape.indices.filter { effectiveShape[$0] != 1 }
        func value(candidate: Int, channel: Int) -> Double {
            let row = layout == .candidatesByChannels ? candidate : channel
            let column = layout == .candidatesByChannels ? channel : candidate
            var indices = Array(repeating: NSNumber(value: 0), count: effectiveShape.count)
            indices[nonUnitIndices[0]] = NSNumber(value: row)
            indices[nonUnitIndices[1]] = NSNumber(value: column)
            return tensor[indices].doubleValue
        }
        var detections: [InferenceDetection] = []
        let classOffset = includesObjectness ? 5 : 4
        for candidate in 0..<candidates {
            let objectness = includesObjectness ? value(candidate: candidate, channel: 4) : 1
            var bestClass = 0
            var bestScore = -Double.infinity
            for classIndex in 0..<classCount {
                let score = value(candidate: candidate, channel: classOffset + classIndex) * objectness
                if score > bestScore { bestScore = score; bestClass = classIndex }
            }
            guard bestScore >= confidenceThreshold else { continue }
            var coordinates = (0..<4).map { value(candidate: candidate, channel: $0) }
            if !coordinatesAreNormalized {
                guard let inputSize, inputSize.isValid else { throw InferenceError.unsupportedOutput("Pixel coordinates require a valid model input size") }
                coordinates[0] /= Double(inputSize.width); coordinates[2] /= Double(inputSize.width)
                coordinates[1] /= Double(inputSize.height); coordinates[3] /= Double(inputSize.height)
            }
            let box: BoundingBox
            switch boxEncoding {
            case .centerXYWH: box = .init(centerX: coordinates[0], centerY: coordinates[1], width: coordinates[2], height: coordinates[3])
            case .cornerXYXY: box = .init(x: coordinates[0], y: coordinates[1], width: coordinates[2] - coordinates[0], height: coordinates[3] - coordinates[1])
            }
            guard box.isValid else { continue }
            detections.append(.init(categoryIndex: bestClass, label: labels.indices.contains(bestClass) ? labels[bestClass] : nil, confidence: bestScore, boundingBox: box.clamped()))
        }
        return nms.apply(to: detections)
    }
}

public final class VisionCoreMLInferenceEngine: ImageInferenceEngine, @unchecked Sendable {
    private let model: VNCoreMLModel
    private let rawDecoder: RawYOLODecoder?
    private let cropAndScaleOption: VNImageCropAndScaleOption

    public init(model: MLModel, rawDecoder: RawYOLODecoder? = nil, cropAndScaleOption: VNImageCropAndScaleOption = .scaleFit) throws {
        do { self.model = try VNCoreMLModel(for: model) }
        catch { throw InferenceError.modelLoading(error.localizedDescription) }
        self.rawDecoder = rawDecoder; self.cropAndScaleOption = cropAndScaleOption
    }

    public func infer(image: CGImage) async throws -> [InferenceDetection] {
        if Task.isCancelled { throw InferenceError.cancelled }
        return try await Task.detached(priority: .userInitiated) { [model, rawDecoder, cropAndScaleOption] in
            let request = VNCoreMLRequest(model: model); request.imageCropAndScaleOption = cropAndScaleOption
            do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
            catch { throw InferenceError.vision(error.localizedDescription) }
            if let recognized = request.results as? [VNRecognizedObjectObservation] {
                return recognized.compactMap { observation in
                    guard let label = observation.labels.first else { return nil }
                    let box = BoundingBox(x: observation.boundingBox.minX, y: 1 - observation.boundingBox.maxY, width: observation.boundingBox.width, height: observation.boundingBox.height)
                    return .init(categoryIndex: 0, label: label.identifier, confidence: Double(label.confidence), boundingBox: box)
                }
            }
            guard let rawDecoder else { throw InferenceError.unsupportedOutput("Expected recognized objects or a configured raw YOLO decoder") }
            guard let feature = request.results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first(where: { $0.featureValue.multiArrayValue != nil }), let tensor = feature.featureValue.multiArrayValue else {
                throw InferenceError.unsupportedOutput("No MLMultiArray output was produced")
            }
            return try rawDecoder.decode(tensor)
        }.value
    }
}
