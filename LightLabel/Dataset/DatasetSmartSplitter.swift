import Foundation
import CoreGraphics

public struct SmartSplitConfiguration: Hashable, Sendable {
    public var trainRatio: Double
    public var validationRatio: Double
    public var testRatio: Double

    public init(trainRatio: Double = 0.8, validationRatio: Double = 0.1) {
        let train = min(max(trainRatio, 0.05), 0.95)
        let validation = min(max(validationRatio, 0), 0.9)
        let remaining = max(0, 1 - train)
        self.trainRatio = train
        self.validationRatio = min(validation, remaining)
        self.testRatio = max(0, 1 - self.trainRatio - self.validationRatio)
    }

    public var ratios: [(DatasetSplit, Double)] {
        [(.train, trainRatio), (.validation, validationRatio), (.test, testRatio)]
    }
}

public struct SmartSplitPlanner: Sendable {
    public init() {}

    public func assignments(
        images: [DatasetImage],
        annotations: [DatasetAnnotation],
        signatures: [UUID: UInt64] = [:],
        configuration: SmartSplitConfiguration = .init()
    ) -> [UUID: DatasetSplit] {
        guard !images.isEmpty else { return [:] }
        let annotationsByImage = Dictionary(grouping: annotations, by: \.imageID)
        let groups = makeGroups(images: images, signatures: signatures).map { imageIDs in
            let counts = imageIDs.reduce(into: [UUID: Int]()) { result, imageID in
                for annotation in annotationsByImage[imageID, default: []] {
                    result[annotation.categoryID, default: 0] += 1
                }
            }
            return Group(imageIDs: imageIDs, categoryCounts: counts)
        }.sorted { lhs, rhs in
            let leftWeight = lhs.imageIDs.count + lhs.categoryCounts.values.reduce(0, +) * 2
            let rightWeight = rhs.imageIDs.count + rhs.categoryCounts.values.reduce(0, +) * 2
            return leftWeight == rightWeight ? lhs.imageIDs.count > rhs.imageIDs.count : leftWeight > rightWeight
        }

        let totalCategoryCounts = groups.reduce(into: [UUID: Int]()) { result, group in
            for (categoryID, count) in group.categoryCounts { result[categoryID, default: 0] += count }
        }
        let totalImages = Double(images.count)
        let targets = configuration.ratios.map { split, ratio in (split, totalImages * ratio) }
        var imageCounts: [DatasetSplit: Int] = [:]
        var categoryCounts: [DatasetSplit: [UUID: Int]] = [:]
        var result: [UUID: DatasetSplit] = [:]

        for group in groups {
            let split = targets.min { lhs, rhs in
                score(
                    split: lhs.0,
                    targetImages: lhs.1,
                    group: group,
                    imageCounts: imageCounts,
                    categoryCounts: categoryCounts,
                    totalCategoryCounts: totalCategoryCounts,
                    configuration: configuration
                ) < score(
                    split: rhs.0,
                    targetImages: rhs.1,
                    group: group,
                    imageCounts: imageCounts,
                    categoryCounts: categoryCounts,
                    totalCategoryCounts: totalCategoryCounts,
                    configuration: configuration
                )
            }?.0 ?? .train
            imageCounts[split, default: 0] += group.imageIDs.count
            for (categoryID, count) in group.categoryCounts { categoryCounts[split, default: [:]][categoryID, default: 0] += count }
            for imageID in group.imageIDs { result[imageID] = split }
        }
        return result
    }

    public static func perceptualSignature(_ image: CGImage) -> UInt64? {
        guard let provider = image.dataProvider, let data = provider.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let rowStride = image.bytesPerRow
        var values: [Double] = []
        values.reserveCapacity(64)
        for row in 0..<8 {
            for column in 0..<8 {
                let x = min(image.width - 1, column * image.width / 8)
                let y = min(image.height - 1, row * image.height / 8)
                let offset = y * rowStride + x * bytesPerPixel
                guard offset + bytesPerPixel <= CFDataGetLength(data) else { return nil }
                let red = Double(bytes[offset])
                let green = Double(bytes[offset + min(1, bytesPerPixel - 1)])
                let blue = Double(bytes[offset + min(2, bytesPerPixel - 1)])
                values.append(0.299 * red + 0.587 * green + 0.114 * blue)
            }
        }
        let average = values.reduce(0, +) / Double(values.count)
        return values.enumerated().reduce(UInt64(0)) { result, item in
            result | (item.element >= average ? UInt64(1) << UInt64(item.offset) : 0)
        }
    }

    private struct Group: Sendable {
        let imageIDs: [UUID]
        let categoryCounts: [UUID: Int]
    }

    private func makeGroups(images: [DatasetImage], signatures: [UUID: UInt64]) -> [[UUID]] {
        var parent = Array(images.indices)
        func find(_ value: Int) -> Int {
            var value = value
            while parent[value] != value {
                parent[value] = parent[parent[value]]
                value = parent[value]
            }
            return value
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let left = find(lhs), right = find(rhs)
            if left != right { parent[right] = left }
        }
        var buckets: [UInt16: [Int]] = [:]
        for index in images.indices {
            guard let signature = signatures[images[index].id] else { continue }
            buckets[UInt16(signature >> 48), default: []].append(index)
        }
        for indexes in buckets.values {
            for leftOffset in indexes.indices {
                for rightOffset in indexes.index(after: leftOffset)..<indexes.endIndex {
                    let left = indexes[leftOffset], right = indexes[rightOffset]
                    if let lhs = signatures[images[left].id], let rhs = signatures[images[right].id], (lhs ^ rhs).nonzeroBitCount <= 8 { union(left, right) }
                }
            }
        }
        var grouped: [Int: [UUID]] = [:]
        for index in images.indices { grouped[find(index), default: []].append(images[index].id) }
        return Array(grouped.values)
    }

    private func score(
        split: DatasetSplit,
        targetImages: Double,
        group: Group,
        imageCounts: [DatasetSplit: Int],
        categoryCounts: [DatasetSplit: [UUID: Int]],
        totalCategoryCounts: [UUID: Int],
        configuration: SmartSplitConfiguration
    ) -> Double {
        let nextImages = Double(imageCounts[split, default: 0] + group.imageIDs.count)
        let underfill = max(0, targetImages - nextImages)
        let overflow = max(0, nextImages - targetImages)
        let ratio = configuration.ratios.first(where: { $0.0 == split })?.1 ?? 0
        let existing = categoryCounts[split, default: [:]]
        let categoryError = totalCategoryCounts.reduce(0.0) { partial, item in
            let target = Double(item.value) * ratio
            let next = Double(existing[item.key, default: 0] + group.categoryCounts[item.key, default: 0])
            return partial + abs(next - target) / max(1, Double(item.value))
        }
        return overflow * 1000 - underfill + categoryError * 0.5
    }
}
