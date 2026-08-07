import Foundation
import ImageIO
import CoreGraphics

public enum ImageLoaderError: LocalizedError, Sendable { case unreadable(URL); case noImage(URL)
    public var errorDescription: String? { switch self { case let .unreadable(url): "Could not read image at \(url.path)."; case let .noImage(url): "No image frame exists at \(url.path)." } }
}

public actor ImageLoader {
    public static let shared = ImageLoader()

    public let maximumConcurrentLoads: Int
    private var activeLoads = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private let cache = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage, Error>] = [:]

    public init(maximumConcurrentLoads: Int = 3) {
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        cache.countLimit = 300
        cache.totalCostLimit = 256 * 1_024 * 1_024
    }

    public func thumbnail(at url: URL, maximumPixelSize: Int, appliesOrientation: Bool = true) async throws -> CGImage {
        let pixelSize = Self.sizeBucket(maximumPixelSize)
        let key = Self.cacheKey(url: url, maximumPixelSize: pixelSize, appliesOrientation: appliesOrientation)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return try await task.value }

        let task = Task { try await loadThumbnail(at: url, maximumPixelSize: pixelSize, appliesOrientation: appliesOrientation) }
        inFlight[key] = task
        do {
            let image = try await task.value
            cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
            inFlight[key] = nil
            return image
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    public func fullImage(at url: URL) async throws -> CGImage {
        try await acquire()
        defer { release() }
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageLoaderError.unreadable(url) }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { throw ImageLoaderError.noImage(url) }
            return image
        }.value
    }

    public func prefetch(_ urls: [URL], maximumPixelSize: Int, appliesOrientation: Bool = true) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { _ = try? await self.thumbnail(at: url, maximumPixelSize: maximumPixelSize, appliesOrientation: appliesOrientation) }
            }
        }
    }

    private func loadThumbnail(at url: URL, maximumPixelSize: Int, appliesOrientation: Bool) async throws -> CGImage {
        try await acquire()
        defer { release() }
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { throw ImageLoaderError.unreadable(url) }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: appliesOrientation,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageLoaderError.noImage(url) }
            return image
        }.value
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeLoads < maximumConcurrentLoads { activeLoads += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        activeLoads += 1
    }

    private func release() {
        activeLoads -= 1
        if !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private static func sizeBucket(_ maximumPixelSize: Int) -> Int {
        let size = max(1, maximumPixelSize)
        // List thumbnails are 64 px wide. Rounding those requests to 256 px
        // quadrupled decode area and made fast scrolling needlessly expensive.
        let bucket = 128
        return ((size + bucket - 1) / bucket) * bucket
    }

    private static func cacheKey(url: URL, maximumPixelSize: Int, appliesOrientation: Bool) -> String {
        "\(url.standardizedFileURL.path)#\(maximumPixelSize)#\(appliesOrientation ? "o" : "r")"
    }
}
