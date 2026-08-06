import CoreGraphics
import CoreML
import Foundation
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
